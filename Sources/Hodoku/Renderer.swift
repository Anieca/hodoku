import AppKit

/// 今この瞬間に何を出すか。Page（画面の内容）と Learner（理解度）から決まる。
struct RenderState {
    /// 語の添字 → 表示。none の語は入れない。
    var words: [Int: (display: WordDisplay, gloss: String)] = [:]
    /// 文の添字 → 助けの段階（1: 区切り / 2: +主語・動詞 / 3: +修飾部を薄く）
    var sentenceLevel: [Int: Int] = [:]
    struct PhraseItem {
        var words: [Int]
        var display: WordDisplay
        var gloss: String
    }
    /// 熟語や、使う人が選んだ句
    var phrases: [PhraseItem] = []
    /// ⌥ドラッグで選んでいる途中の語
    var selection: [Int] = []
    var hover: Int?
    var optionHeld = false
    var message: String?
}

/// 注釈の描画。左上原点（flipped）の描画コンテキストに描く。
enum Renderer {
    static func draw(page: Page, state: RenderState, bounds: CGRect) {
        if state.optionHeld {
            // ⌥ を押している間は全面でクリックを受ける。うっすら色を付けて、それと分かるようにする。
            NSColor(white: 0, alpha: 0.06).setFill()
            bounds.fill()
        }

        for (si, level) in state.sentenceLevel.sorted(by: { $0.key < $1.key }) where level > 0 && si < page.sentences.count {
            drawStructure(page: page, sentence: page.sentences[si], level: level)
        }
        drawWords(page: page, state: state, bounds: bounds)

        if !state.selection.isEmpty {
            NSColor.systemBlue.withAlphaComponent(0.22).setFill()
            for index in state.selection where index < page.words.count {
                NSBezierPath(roundedRect: page.words[index].rect.insetBy(dx: -3, dy: -2), xRadius: 3, yRadius: 3).fill()
            }
        } else if let h = state.hover, h < page.words.count {
            let r = page.words[h].rect.insetBy(dx: -3, dy: -2)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            NSColor.systemBlue.setStroke()
            path.stroke()
        }
        if let message = state.message { drawMessage(message, bounds: bounds) }
    }

    private static func isDark(_ c: NSColor) -> Bool {
        0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }

    // MARK: - 単語

    private static func drawWords(page: Page, state: RenderState, bounds: CGRect) {
        // 語も句も「いくつかの語にまたがる 1 つの注釈」として同じように描く。
        var items: [(words: [Int], display: WordDisplay, gloss: String)] = []
        for (i, entry) in state.words.sorted(by: { $0.key < $1.key }) where i < page.words.count {
            items.append(([i], entry.display, entry.gloss))
        }
        for phrase in state.phrases where phrase.words.allSatisfy({ $0 < page.words.count }) && !phrase.words.isEmpty {
            items.append((phrase.words, phrase.display, phrase.gloss))
        }

        var pills: [(rect: CGRect, text: NSAttributedString, bg: NSColor)] = []
        for item in items {
            let first = page.words[item.words[0]]
            let dark = isDark(first.bg)
            let color = dark ? NSColor(srgbRed: 1.0, green: 0.74, blue: 0.42, alpha: 1) : NSColor(srgbRed: 0.72, green: 0.16, blue: 0.10, alpha: 1)

            // 下線（意味を出しているものは実線、思い出す練習中のものは点線）。句は隣り合う語をつなげて引く。
            color.withAlphaComponent(item.display == .hint ? 0.9 : 0.55).setStroke()
            for (k, index) in item.words.enumerated() {
                let rect = page.words[index].rect
                var from = rect.minX
                if k > 0, item.words[k - 1] == index - 1 {
                    let prev = page.words[index - 1].rect
                    if abs(prev.midY - rect.midY) < rect.height * 0.5 { from = prev.maxX }
                }
                let line = NSBezierPath()
                let y = rect.maxY + 1.5
                line.move(to: CGPoint(x: from, y: y))
                line.line(to: CGPoint(x: rect.maxX, y: y))
                line.lineWidth = item.words.count > 1 ? 1.6 : 1.2
                if item.display == .hint { line.setLineDash([2, 2.5], count: 2, phase: 0) }
                line.stroke()
            }

            guard item.display == .gloss, !item.gloss.isEmpty else { continue }
            let fontSize = min(13, max(9, first.rect.height * 0.55))
            let text = NSAttributedString(
                string: item.gloss,
                attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color])
            let size = text.size()
            let w = size.width + 6, h = size.height + 1
            // 語（句なら最初の行にある部分）のすぐ上、行間に置く。
            var span = first.rect
            for index in item.words.dropFirst() {
                let r = page.words[index].rect
                if abs(r.midY - first.rect.midY) < first.rect.height * 0.5 { span = span.union(r) }
            }
            let rect = CGRect(x: span.midX - w / 2, y: span.minY - h + 1, width: w, height: h)
            pills.append((rect, text, first.bg))
        }

        // 同じ行で重なるものは右へずらす。
        pills.sort { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        var placed: [CGRect] = []
        for var pill in pills {
            pill.rect.origin.x = max(bounds.minX + 2, min(bounds.maxX - pill.rect.width - 2, pill.rect.minX))
            for p in placed where abs(p.midY - pill.rect.midY) < pill.rect.height * 0.6 && p.maxX + 2 > pill.rect.minX && p.minX < pill.rect.maxX {
                pill.rect.origin.x = p.maxX + 2
            }
            placed.append(pill.rect)
            pill.bg.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: pill.rect, xRadius: 3, yRadius: 3).fill()
            pill.text.draw(at: CGPoint(x: pill.rect.minX + 3, y: pill.rect.minY))
        }
    }

    // MARK: - 文の構造

    private static func drawStructure(page: Page, sentence: SentAnn, level: Int) {
        let st = sentence.structure
        let words = sentence.words.map { page.words[$0] }
        guard !words.isEmpty else { return }
        let dark = isDark(words[0].bg)

        if level >= 3 {
            // 修飾部（従属節・挿入句）を薄くして、主節だけを浮かび上がらせる。
            for (k, word) in words.enumerated() where k < st.isMain.count && !st.isMain[k] {
                word.bg.withAlphaComponent(0.62).setFill()
                word.rect.insetBy(dx: -2, dy: -1).fill()
            }
        }

        // 区切り
        let slash = dark ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.80, alpha: 1) : NSColor(srgbRed: 0.0, green: 0.50, blue: 0.48, alpha: 1)
        slash.setStroke()
        for start in st.chunkStarts where start > 0 && start < words.count {
            let cur = words[start].rect, prev = words[start - 1].rect
            let sameLine = abs(cur.midY - prev.midY) < cur.height * 0.5
            let x = sameLine ? max((prev.maxX + cur.minX) / 2, cur.minX - 3.5) : cur.minX - 4
            let path = NSBezierPath()
            path.move(to: CGPoint(x: x + 2, y: cur.minY - 1))
            path.line(to: CGPoint(x: x - 2, y: cur.maxY + 1))
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.stroke()
        }

        guard level >= 2 else { return }
        func mark(_ range: Range<Int>?, label: String, color: NSColor) {
            guard let range, range.upperBound <= words.count, !range.isEmpty else { return }
            color.setStroke()
            for k in range {
                let r = words[k].rect
                let path = NSBezierPath()
                path.move(to: CGPoint(x: r.minX - 1, y: r.maxY + 2))
                path.line(to: CGPoint(x: r.maxX + 1, y: r.maxY + 2))
                path.lineWidth = 2.2
                path.stroke()
            }
            let first = words[range.lowerBound].rect
            let size = min(10, max(7.5, first.height * 0.45))
            let text = NSAttributedString(
                string: label,
                attributes: [.font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: NSColor.white])
            let ts = text.size()
            let badge = CGRect(x: first.minX - ts.width - 5, y: first.maxY - ts.height + 2, width: ts.width + 4, height: ts.height)
            color.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 2, yRadius: 2).fill()
            text.draw(at: CGPoint(x: badge.minX + 2, y: badge.minY))
        }
        mark(st.subject, label: "S", color: NSColor(srgbRed: 0.15, green: 0.45, blue: 0.95, alpha: 1))
        mark(st.verb, label: "V", color: NSColor(srgbRed: 0.90, green: 0.25, blue: 0.30, alpha: 1))
    }

    // MARK: - 案内

    private static func drawMessage(_ message: String, bounds: CGRect) {
        let text = NSAttributedString(
            string: message,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        let size = text.size()
        let rect = CGRect(x: bounds.maxX - size.width - 36, y: bounds.minY + 34, width: size.width + 20, height: size.height + 10)
        NSColor(white: 0.1, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 5))
    }
}
