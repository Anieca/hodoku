import AppKit
import Carbon.HIToolbox

// MARK: - 注釈を描く透明なウインドウ

final class OverlayView: NSView {
    var page: Page?
    var state = RenderState()
    var onClick: ((CGPoint, Bool) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let page else {
            if let message = state.message {
                Renderer.draw(page: Page(size: bounds.size), state: RenderState(message: message), bounds: bounds)
            }
            return
        }
        Renderer.draw(page: page, state: state, bounds: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), event.modifierFlags.contains(.shift))
    }
}

// MARK: - グローバルホットキー（⌃⌥R）

final class HotKey {
    private static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                DispatchQueue.main.async { HotKey.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x484F_444B), id: 1)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - アプリ本体（メニューバー常駐）

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let learner = Learner()
    private lazy var session = ReadingSession(learner: learner)
    private let capturer = ScreenCapturer()
    private let refiner = SenseRefiner()
    private let analysisQueue = DispatchQueue(label: "hodoku.analysis", qos: .userInitiated)

    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var panel: NSPanel?
    private var view: OverlayView?
    private var screen: NSScreen?

    private var active = false
    private var analyzing = false
    private var needsRefresh = false
    private var lastChange = Date.distantPast
    /// スクロールなど、今の注釈が使えなくなる大きな変化があった時刻
    private var lastBigChange = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var lastSignature: [UInt8] = []
    private var watchTimer: Timer?
    private var inputTimer: Timer?
    private var scrollMonitor: Any?
    private var messageUntil = Date.distantPast
    private var generation = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "解"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey) { [weak self] in self?.toggle() }
        if !ScreenCapturer.hasPermission { ScreenCapturer.requestPermission() }
        // 文字認識と辞書は初回の読み込みに時間がかかるので、先に温めておく。
        analysisQueue.async {
            let size = CGSize(width: 320, height: 60)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                ("The quick brown fox jumps over the lazy dog." as NSString).draw(at: CGPoint(x: 8, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 13)])
                return true
            }
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                _ = Analyzer.analyze(image: cg, viewSize: size)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggleItem = NSMenuItem(title: active ? "読むのをやめる" : "読みはじめる", action: #selector(toggleFromMenu), keyEquivalent: "r")
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.target = self
        menu.addItem(toggleItem)
        if !ScreenCapturer.hasPermission {
            let open = NSMenuItem(title: "⚠︎ 画面収録が未許可 — システム設定を開く", action: #selector(openPrivacySettings), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let again = NSMenuItem(title: "許可したら: Hodoku を再起動", action: #selector(relaunch), keyEquivalent: "")
            again.target = self
            menu.addItem(again)
        }
        menu.addItem(.separator())
        let s = learner.stats
        for line in [
            "⌥クリック: 単語の意味を出す / もう知っている",
            "⌥⇧クリック: 文の構造（区切り → 主語・動詞 → 骨組み）",
            "—",
            String(format: "語彙レベル %.0f / 100", s.theta * 100),
            "意味を見せている語 \(s.learning) ・ 思い出す練習中 \(s.recalling) ・ 卒業 \(s.graduated)",
            "\(s.longThreshold) 語以上の文を自動で区切る（段階 \(s.startLevel)）",
        ] {
            if line == "—" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if !EJDictionary.shared.isAvailable {
            let item = NSMenuItem(title: "⚠︎ 英和辞典が見つかりません（辞書.app の設定で「ウィズダム英和辞典」を有効に）", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "学習の記録を消す…", action: #selector(resetLearner), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let quit = NSMenuItem(title: "Hodoku を終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleFromMenu() { toggle() }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    @objc private func quit() {
        stop()
        NSApp.terminate(nil)
    }

    @objc private func resetLearner() {
        let alert = NSAlert()
        alert.messageText = "学習の記録を消しますか？"
        alert.informativeText = "語彙レベルと、単語ごとの記録が最初の状態に戻ります。"
        alert.addButton(withTitle: "消す")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            learner.reset()
            redraw()
        }
    }

    // MARK: - 読むモード

    private func toggle() { active ? stop() : start() }

    private func start() {
        guard ScreenCapturer.hasPermission else {
            ScreenCapturer.requestPermission()
            let alert = NSAlert()
            alert.messageText = "画面収録の許可が必要です"
            alert.informativeText = "1. 「システム設定を開く」を押し、一覧の Hodoku をオンにする\n2. もう一度 ⌃⌥R を押し、「Hodoku を再起動」を押す\n\n許可は再起動するまで反映されません。画面の内容はこの Mac の中だけで処理されます。"
            alert.addButton(withTitle: "システム設定を開く")
            alert.addButton(withTitle: "Hodoku を再起動")
            alert.addButton(withTitle: "閉じる")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: openPrivacySettings()
            case .alertSecondButtonReturn: relaunch()
            default: break
            }
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        self.screen = screen

        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onClick = { [weak self] point, shift in self?.clicked(at: point, shift: shift) }
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.view = view

        active = true
        statusItem.button?.title = "解●"
        generation += 1
        lastSignature = []
        needsRefresh = true
        lastChange = .distantPast
        showMessage("Hodoku  ⌥クリック: 単語 ／ ⌥⇧クリック: 文の構造 ／ ⌃⌥R: 終了", seconds: 5)

        let gen = generation
        Task { @MainActor in
            do {
                try await capturer.prepare(screen: screen)
                guard gen == generation, active else { return }
                watchTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in self?.watch() }
                watch()
            } catch {
                showMessage("画面を取り込めませんでした: \(error.localizedDescription)", seconds: 6)
            }
        }
        inputTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.pollInput() }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            // スクロール中は古い位置の注釈を消し、止まってから読み直す。
            guard let self, self.active else { return }
            self.lastChange = Date()
            self.lastBigChange = Date()
            self.needsRefresh = true
            if self.session.page != nil { self.setPage(nil) }
        }
    }

    private func stop() {
        guard active else { return }
        active = false
        generation += 1
        watchTimer?.invalidate()
        inputTimer?.invalidate()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        session.end()
        panel?.orderOut(nil)
        panel = nil
        view = nil
        statusItem.button?.title = "解"
    }

    /// 画面が変わったら（変化が落ち着いてから）読み直す。
    private func watch() {
        guard active else { return }
        let gen = generation
        Task { @MainActor in
            guard let signature = try? await capturer.captureSignature(), gen == generation else { return }
            let diff = ScreenCapturer.difference(signature, lastSignature)
            lastSignature = signature
            if diff > 0.4 {
                lastChange = Date()
                needsRefresh = true
                if diff > 4 {
                    lastBigChange = Date()
                    if session.page != nil { setPage(nil) }
                }
            }
            // 大きく変わったら落ち着きしだい読み直す。小さな変化（動画やアニメーションなど）が続くだけなら 3 秒に 1 回まで。
            let settled = Date().timeIntervalSince(lastChange) >= 0.5
            let urgent = session.page == nil || Date().timeIntervalSince(lastRefresh) >= 3
            if needsRefresh, !analyzing, urgent, settled || Date().timeIntervalSince(lastBigChange) >= 3 { refresh() }
        }
    }

    private func refresh() {
        guard let screen else { return }
        analyzing = true
        needsRefresh = false
        let gen = generation
        let size = screen.frame.size
        let started = Date()
        lastRefresh = started
        Task { @MainActor in
            defer { analyzing = false }
            guard let image = try? await capturer.captureFull() else { return }
            let page = await withCheckedContinuation { (c: CheckedContinuation<Page, Never>) in
                analysisQueue.async { c.resume(returning: Analyzer.analyze(image: image, viewSize: size)) }
            }
            // 解析中に画面が動いていたら、この結果は捨てて次の読み直しに任せる。
            guard gen == generation, active else { return }
            guard lastBigChange < started else {
                needsRefresh = true
                return
            }
            setPage(page)
            refineSenses(for: page, generation: gen)
        }
    }

    private func setPage(_ page: Page?) {
        session.setPage(page)
        view?.page = page
        redraw()
    }

    private func redraw() {
        guard let view else { return }
        var state = session.renderState()
        state.optionHeld = view.state.optionHeld
        state.hover = view.state.hover
        state.message = Date() < messageUntil ? view.state.message : nil
        view.state = state
        view.needsDisplay = true
    }

    private func showMessage(_ text: String, seconds: TimeInterval) {
        messageUntil = Date().addingTimeInterval(seconds)
        view?.state.message = text
        view?.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.redraw() }
    }

    /// ⌥ を押している間だけクリックを受け取る。それ以外は下のアプリをそのまま操作できる。
    private func pollInput() {
        guard active, let view, let panel, let screen else { return }
        let option = NSEvent.modifierFlags.contains(.option)
        var hover: Int?
        if option {
            let m = NSEvent.mouseLocation
            hover = session.wordIndex(at: CGPoint(x: m.x - screen.frame.minX, y: screen.frame.maxY - m.y))
        }
        guard option != view.state.optionHeld || hover != view.state.hover else { return }
        panel.ignoresMouseEvents = !option
        view.state.optionHeld = option
        view.state.hover = hover
        view.needsDisplay = true
    }

    private func clicked(at point: CGPoint, shift: Bool) {
        guard let index = session.wordIndex(at: point) else { return }
        if shift {
            session.cycleSentence(containing: index)
        } else {
            session.toggleWord(index)
            if let page = session.page { refineSenses(for: page, generation: generation) }
        }
        redraw()
    }

    /// 意味を出している多義語について、文脈に合う語義を選び直す（端末内モデル。失敗しても辞書の先頭の語義が出ている）。
    private func refineSenses(for page: Page, generation gen: Int) {
        var jobs: [(key: String, word: String, sentence: String, candidates: [String])] = []
        for word in page.words where word.glosses.count > 1 && session.display(of: word) == .gloss {
            guard word.sentence < page.sentences.count else { continue }
            let sentence = page.sentences[word.sentence].id
            let key = word.key + "|" + sentence
            if session.refinedGloss[key] == nil, !jobs.contains(where: { $0.key == key }) {
                jobs.append((key, word.text, sentence, word.glosses))
            }
            if jobs.count >= 10 { break }
        }
        guard !jobs.isEmpty else { return }
        Task { @MainActor in
            for job in jobs {
                guard gen == generation, active else { return }
                if let pick = await refiner.pick(word: job.word, sentence: job.sentence, candidates: job.candidates) {
                    session.refinedGloss[job.key] = job.candidates[pick]
                    redraw()
                }
            }
        }
    }
}
