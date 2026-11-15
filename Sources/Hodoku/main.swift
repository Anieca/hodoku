import AppKit

// 引数なし: メニューバーに常駐するアプリとして起動する。
// 引数あり: 画面収録なしで動作を確かめるためのコマンド。
//   --parse "<英文>"                        文の区切り・主語・動詞を表示
//   --sample <out.png>                      確認用の英文画像を作る
//   --image <in.png> --out <out.png>        画像を解析し、注釈を重ねた画像を書き出す
//       [--theta 0.6] [--level 2] [--state <learner.json>]
//   --screen                                今の画面で取り込みと解析を試す（件数だけ表示）
//   --selftest                              理解度モデルの動きを確かめる

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let sentence = value("--parse") {
    let (words, st) = Analyzer.structure(of: sentence)
    var out = ""
    for (i, w) in words.enumerated() {
        if st.chunkStarts.contains(i) { out += "/ " }
        out += (st.isMain[i] ? w : "(\(w))") + " "
    }
    print(out)
    print("S:", st.subject.map { words[$0].joined(separator: " ") } ?? "-", "| V:", st.verb.map { words[$0].joined(separator: " ") } ?? "-")
    exit(0)
}

if let out = value("--sample") {
    CLI.writeSample(to: out)
    exit(0)
}

if let input = value("--image"), let out = value("--out") {
    CLI.annotate(
        input: input, output: out, theta: value("--theta").flatMap(Double.init),
        level: value("--level").flatMap(Int.init), state: value("--state"))
    exit(0)
}

if let q = value("--idiom") {
    for query in q.split(separator: ",").map(String.init) {
        if let e = EJDictionary.shared.idiom(query) {
            print(String(format: "%.2f  %@ → %@", e.difficulty, e.headword, e.gloss))
        } else {
            print(" -    \(query)")
        }
    }
    exit(0)
}

if args.contains("--selftest") {
    CLI.selfTest()
    exit(0)
}

if args.contains("--screen") {
    // 実際の画面で取り込み〜解析が動くかだけを確かめる（内容は表示せず、件数のみ）。
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let capturer = ScreenCapturer()
            try await capturer.prepare(screen: NSScreen.main!)
            let image = try await capturer.captureFull()
            let start = Date()
            let page = Analyzer.analyze(image: image, viewSize: NSScreen.main!.frame.size)
            let session = ReadingSession(learner: Learner(url: URL(fileURLWithPath: NSTemporaryDirectory() + "hodoku-screen-test.json")))
            session.setPage(page)
            let state = session.renderState()
            print(String(format: "取り込み %dx%d / 解析 %.2f 秒 / %d 語 / %d 文 / 意味を出す語 %d / 区切る文 %d",
                image.width, image.height, Date().timeIntervalSince(start), page.words.count, page.sentences.count,
                state.words.count, state.sentenceLevel.count))
        } catch {
            print("取り込み失敗: \(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
