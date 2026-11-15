import AppKit

/// 画面収録なしで解析と描画を確かめるためのコマンド。
enum CLI {
    static let sampleText = """
        Although the committee, which had been formed in response to mounting public pressure over the handling of the crisis, initially promised a swift and transparent investigation, its final report, released nearly two years later, left many of the central questions unanswered.

        The extent to which models trained on data scraped from the public internet can be said to understand the text they produce remains a matter that researchers who study language have debated without reaching anything resembling consensus.

        The cat sat on the mat. Central banks around the world have struggled to bring inflation back to their targets without tipping their economies into recession, a balancing act that has become harder as energy prices have risen again. Critics argue the policy is perfunctory and will exacerbate the problem.
        """

    static func writeSample(to path: String) {
        let size = CGSize(width: 900, height: 560)
        let rep = bitmap(size: size, scale: 2)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 9
        let text = NSAttributedString(
            string: sampleText,
            attributes: [
                .font: NSFont(name: "Georgia", size: 17) ?? NSFont.systemFont(ofSize: 17),
                .foregroundColor: NSColor(white: 0.1, alpha: 1), .paragraphStyle: style,
            ])
        text.draw(in: CGRect(x: 50, y: 30, width: size.width - 100, height: size.height - 60))
        ctx.flushGraphics()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    static func annotate(input: String, output: String, theta: Double?, level: Int?, state: String?) {
        guard let nsImage = NSImage(contentsOfFile: input),
            let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("画像を読めません: \(input)")
            return
        }
        // 2 倍解像度の画面を取り込んだものとして扱う。
        let size = CGSize(width: image.width / 2, height: image.height / 2)
        let stateURL = URL(fileURLWithPath: state ?? NSTemporaryDirectory() + "hodoku-cli-\(getpid()).json")
        let learner = Learner(url: stateURL)
        if let theta {
            // 指定の語彙レベルで見たいとき用（記録ファイルには触れない）
            learner.overrideTheta(theta)
        }
        let session = ReadingSession(learner: learner)
        let start = Date()
        let page = Analyzer.analyze(image: image, viewSize: size)
        print(String(format: "解析 %.2f 秒: %d 語 / %d 文", Date().timeIntervalSince(start), page.words.count, page.sentences.count))
        session.setPage(page)
        var render = session.renderState()
        if let level {
            for (i, s) in page.sentences.enumerated() where s.words.count >= 12 { render.sentenceLevel[i] = level }
        }
        for (i, entry) in render.words.sorted(by: { $0.key < $1.key }) {
            let w = page.words[i]
            print(String(format: "  %@ [%.2f] %@ → %@", entry.display == .hint ? "…" : "＋", w.difficulty ?? 0, w.text, entry.gloss))
        }
        for (i, s) in page.sentences.enumerated() where s.words.count >= 12 {
            let words = s.words.map { page.words[$0].text }
            var line = ""
            for (k, w) in words.enumerated() {
                if s.structure.chunkStarts.contains(k) { line += "/ " }
                line += w + " "
            }
            print("  文\(i) (\(words.count)語, 段階 \(render.sentenceLevel[i] ?? 0)): \(line)")
            print("     S:", s.structure.subject.map { words[$0].joined(separator: " ") } ?? "-", "| V:", s.structure.verb.map { words[$0].joined(separator: " ") } ?? "-")
        }

        let rep = bitmap(size: size, scale: 2)
        let base = NSGraphicsContext(bitmapImageRep: rep)!
        base.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        base.cgContext.translateBy(x: 0, y: size.height)
        base.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
        Renderer.draw(page: page, state: render, bounds: CGRect(origin: .zero, size: size))
        base.flushGraphics()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        print("書き出し: \(output)")
    }

    /// 理解度モデルが意図どおりに動くかを確かめる。
    static func selfTest() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "hodoku-selftest-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let learner = Learner(url: url)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok  " : "  NG  ", name)
            if !ok { failures += 1 }
        }
        let t0 = learner.data.theta
        check("難しい語は最初から意味を出す", learner.display(key: "exacerbate", difficulty: 0.91) == .gloss)
        check("易しい語には何も出さない", learner.display(key: "develop", difficulty: 0.37) == .none)

        learner.markUnknown(key: "develop", difficulty: 0.37)
        check("知らないと伝えた語は意味を出す", learner.display(key: "develop", difficulty: 0.37) == .gloss)
        check("易しい語を知らなかった → 語彙レベルが下がる", learner.data.theta < t0)

        let t1 = learner.data.theta
        learner.markKnown(key: "exacerbate", difficulty: 0.91)
        check("知っていると伝えた語は出さない", learner.display(key: "exacerbate", difficulty: 0.91) == .none)
        check("難しい語を知っていた → 語彙レベルが上がる", learner.data.theta > t1)

        // 意味を 2 回見せたら下線だけになり、下線だけで 2 回読めたら卒業する。
        func ageCredits() { learner.ageForTesting(by: Learner.creditInterval + 1) }
        learner.credit(glossed: ["merger"], hintsHeld: [], autoSentences: [])
        learner.credit(glossed: ["merger"], hintsHeld: [], autoSentences: [])
        check("すぐの読み直しは回数に数えない", learner.display(key: "merger", difficulty: 0.77) == .gloss)
        ageCredits()
        learner.credit(glossed: ["merger"], hintsHeld: [], autoSentences: [])
        check("2 回見せた語は下線だけになる", learner.display(key: "merger", difficulty: 0.77) == .hint)
        ageCredits()
        learner.credit(glossed: [], hintsHeld: [("merger", 0.77)], autoSentences: [])
        check("1 回読めただけではまだ下線", learner.display(key: "merger", difficulty: 0.77) == .hint)
        ageCredits()
        learner.credit(glossed: [], hintsHeld: [("merger", 0.77)], autoSentences: [])
        check("下線だけで 2 回読めたら卒業", learner.display(key: "merger", difficulty: 0.77) == .none)

        learner.markUnknown(key: "tariff", difficulty: 0.6)
        learner.ageForTesting(by: Learner.creditInterval + 1)
        learner.credit(glossed: ["tariff"], hintsHeld: [], autoSentences: [])
        ageCredits()
        learner.credit(glossed: ["tariff"], hintsHeld: [], autoSentences: [])
        learner.lapse(key: "tariff")
        check("下線の語で意味を見たら、また意味を出す", learner.display(key: "tariff", difficulty: 0.6) == .gloss)

        check("28 語未満の文は自動では区切らない", !learner.isLong(wordCount: 20) && learner.isLong(wordCount: 30))
        learner.requestedHelp(wordCount: 18)
        check("短めの文で助けを求めた → 次からその長さでも区切る", learner.isLong(wordCount: 24))
        let before = learner.data.longThreshold
        learner.dismissedAuto(wordCount: 26)
        check("自動の助けを消した → 基準が上がる", learner.data.longThreshold > before)
        learner.escalated(to: 3)
        learner.escalated(to: 3)
        check("もう一段を何度も求めた → 最初から主語・動詞も出す", learner.startLevel >= 2)
        let l = learner.data.longThreshold
        learner.credit(glossed: [], hintsHeld: [], autoSentences: ["a", "b", "c"])
        check("助けを足さずに読めた → 基準が少し上がる", learner.data.longThreshold > l)

        // 操作（⌥クリック / ⌥⇧クリック）が表示に反映されるか
        let sampleURL = NSTemporaryDirectory() + "hodoku-selftest-\(getpid()).png"
        defer { try? FileManager.default.removeItem(atPath: sampleURL) }
        writeSample(to: sampleURL)
        if let image = NSImage(contentsOfFile: sampleURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let fresh = Learner(url: URL(fileURLWithPath: NSTemporaryDirectory() + "hodoku-selftest2-\(getpid()).json"))
            let session = ReadingSession(learner: fresh)
            let page = Analyzer.analyze(image: image, viewSize: CGSize(width: image.width / 2, height: image.height / 2))
            session.setPage(page)
            if let hard = page.words.firstIndex(where: { $0.text == "exacerbate" }),
                let easy = page.words.firstIndex(where: { $0.text == "struggled" }),
                let short = page.words.firstIndex(where: { $0.text == "cat" })
            {
                check("画像から読んだ難しい語に意味が出る", session.renderState().words[hard]?.display == .gloss)
                check("位置から語が引ける", session.wordIndex(at: CGPoint(x: page.words[hard].rect.midX, y: page.words[hard].rect.midY)) == hard)
                session.toggleWord(hard)
                check("意味の出ている語を⌥クリック → 消える", session.renderState().words[hard] == nil)
                check("何も出ていない語は表示なし", session.renderState().words[easy] == nil)
                session.toggleWord(easy)
                check("何も出ていない語を⌥クリック → 意味が出る", session.renderState().words[easy]?.display == .gloss)
                let long = page.words[easy].sentence, brief = page.words[short].sentence
                check("長い文は自動で区切る", session.renderState().sentenceLevel[long] == 1)
                check("短い文は区切らない", session.renderState().sentenceLevel[brief] == nil)
                session.cycleSentence(containing: easy)
                check("⌥⇧クリックで主語・動詞まで出る", session.renderState().sentenceLevel[long] == 2)
                session.cycleSentence(containing: easy)
                session.cycleSentence(containing: easy)
                check("3 段の次は助けなしに戻る", session.renderState().sentenceLevel[long] == nil)
            } else {
                check("確認用の画像から語を読み取れる", false)
            }
        }

        check("記録がファイルから復元できる", Learner(url: url).data.words["merger"]?.known == true)
        print(failures == 0 ? "すべて通過" : "\(failures) 件失敗")
    }

    private static func bitmap(size: CGSize, scale: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }
}
