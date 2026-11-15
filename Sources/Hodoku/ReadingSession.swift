import Foundation

/// 読んでいる間の状態。画面の内容（Page）と理解度（Learner）から、何を出すかを決める。
final class ReadingSession {
    let learner: Learner
    private(set) var page: Page?
    private var shownAt = Date()

    /// この読書の間だけ意味を開いている語
    private var revealed = Set<String>()
    /// 文ごとに使う人が選んだ段階（文の文字列がキー。スクロールして読み直しても保つ）
    private var chosenLevel: [String: Int] = [:]
    /// 端末内モデルが文脈から選んだ語義（"語|文" → 語義）
    var refinedGloss: [String: String] = [:]

    init(learner: Learner) {
        self.learner = learner
    }

    func setPage(_ new: Page?) {
        creditCurrentPage()
        page = new
        shownAt = Date()
    }

    func end() {
        creditCurrentPage()
        page = nil
        revealed.removeAll()
        chosenLevel.removeAll()
    }

    // MARK: - 何を出すか

    func display(of word: WordAnn) -> WordDisplay {
        guard let difficulty = word.difficulty, !word.glosses.isEmpty else { return .none }
        let d = learner.display(key: word.key, difficulty: difficulty)
        if revealed.contains(word.key), d != .none { return .gloss }
        return d
    }

    func gloss(of word: WordAnn, in page: Page) -> String {
        if word.sentence < page.sentences.count,
            let refined = refinedGloss[word.key + "|" + page.sentences[word.sentence].id]
        {
            return refined
        }
        return word.glosses.first ?? ""
    }

    private func autoLevel(_ sentence: SentAnn) -> Int {
        learner.isLong(wordCount: sentence.words.count) && !sentence.structure.chunkStarts.isEmpty ? learner.startLevel : 0
    }

    func level(of sentence: SentAnn) -> Int {
        chosenLevel[sentence.id] ?? autoLevel(sentence)
    }

    func renderState() -> RenderState {
        var state = RenderState()
        guard let page else { return state }
        for (i, word) in page.words.enumerated() {
            let d = display(of: word)
            if d != .none { state.words[i] = (d, gloss(of: word, in: page)) }
        }
        for (i, sentence) in page.sentences.enumerated() {
            let l = level(of: sentence)
            if l > 0 { state.sentenceLevel[i] = l }
        }
        return state
    }

    // MARK: - 使う人の操作

    func wordIndex(at point: CGPoint) -> Int? {
        page?.words.firstIndex { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }
    }

    /// ⌥クリック: 単語の助けを切り替える。
    func toggleWord(_ index: Int) {
        guard let page, index < page.words.count else { return }
        let word = page.words[index]
        guard let difficulty = word.difficulty, !word.glosses.isEmpty else { return }
        switch display(of: word) {
        case .gloss:
            revealed.remove(word.key)
            learner.markKnown(key: word.key, difficulty: difficulty)
        case .hint:
            revealed.insert(word.key)
            learner.lapse(key: word.key)
        case .none:
            learner.markUnknown(key: word.key, difficulty: difficulty)
        }
    }

    /// ⌥⇧クリック: その語を含む文の助けを一段進める（区切り → 主語・動詞 → 修飾部を薄く → なし）。
    func cycleSentence(containing index: Int) {
        guard let page, index < page.words.count else { return }
        let si = page.words[index].sentence
        guard si < page.sentences.count else { return }
        let sentence = page.sentences[si]
        let auto = autoLevel(sentence)
        let current = level(of: sentence)
        let next = current >= 3 ? 0 : current + 1
        chosenLevel[sentence.id] = next
        let n = sentence.words.count
        if current == 0, auto == 0 { learner.requestedHelp(wordCount: n) }
        if next == 0 {
            if auto > 0 { learner.dismissedAuto(wordCount: n) }
        } else if next > max(auto, 1) {
            learner.escalated(to: next)
        }
    }

    // MARK: - 読み終えたページから学ぶ

    private func creditCurrentPage() {
        guard let page, Date().timeIntervalSince(shownAt) >= 4 else { return }
        var glossed: [String] = []
        var held: [(key: String, difficulty: Double)] = []
        for word in page.words {
            guard let difficulty = word.difficulty else { continue }
            switch display(of: word) {
            case .gloss: if !revealed.contains(word.key) { glossed.append(word.key) }
            case .hint: held.append((word.key, difficulty))
            case .none: break
            }
        }
        let auto = page.sentences.filter { chosenLevel[$0.id] == nil && autoLevel($0) > 0 }.map(\.id)
        learner.credit(glossed: glossed, hintsHeld: held, autoSentences: auto)
    }
}
