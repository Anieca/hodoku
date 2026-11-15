import Foundation

/// 辞書では答えられず、端末内モデルに意味を聞く必要がある語句
struct MeaningRequest {
    let key: String
    let phrase: String
    let sentence: String
}

/// 読んでいる間の状態。画面の内容（Page）と理解度（Learner）から、何を出すかを決める。
final class ReadingSession {
    static let maxPhraseWords = 6

    let learner: Learner
    private(set) var page: Page?
    private var shownAt = Date()

    /// この読書の間だけ意味を開いている語句
    private var revealed = Set<String>()
    /// 端末内モデルの答えを待っている語句
    private var pending = Set<String>()
    /// ⌥クリックで今しがた開いた熟語。もう一度クリックされたら「知りたいのは語のほう」とみなす。
    private var justOpened = Set<String>()
    /// この読書の間は熟語として扱わないもの
    private var skipped = Set<String>()
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
        pending.removeAll()
        justOpened.removeAll()
        skipped.removeAll()
        chosenLevel.removeAll()
    }

    // MARK: - 何を出すか

    private func resolve(key: String, difficulty: Double?) -> WordDisplay {
        if pending.contains(key) { return .gloss }
        let d = learner.display(key: key, difficulty: difficulty)
        if revealed.contains(key), d != .none { return .gloss }
        return d
    }

    func display(of word: WordAnn) -> WordDisplay {
        guard !word.glosses.isEmpty || learner.customGloss(word.key) != nil || pending.contains(word.key) else { return .none }
        return resolve(key: word.key, difficulty: word.auto ? word.difficulty : nil)
    }

    func display(of phrase: PhraseAnn) -> WordDisplay {
        skipped.contains(phrase.key) ? .none : resolve(key: phrase.key, difficulty: phrase.difficulty)
    }

    func gloss(of word: WordAnn, in page: Page) -> String {
        if pending.contains(word.key) { return "…" }
        if word.sentence < page.sentences.count,
            let refined = refinedGloss[word.key + "|" + page.sentences[word.sentence].id]
        {
            return refined
        }
        if let first = word.glosses.first { return first }
        // 辞書にない語は端末内モデルの答え。辞書の語義と区別できるよう ≈ を付ける。
        return learner.customGloss(word.key).map { "≈" + $0 } ?? ""
    }

    func gloss(of phrase: PhraseAnn) -> String {
        if pending.contains(phrase.key) { return "…" }
        if !phrase.custom { return phrase.gloss }
        // 自分で選んだ句は端末内モデルの答え。辞書の語義と区別できるよう ≈ を付ける。
        let text = learner.customGloss(phrase.key) ?? phrase.gloss
        return text.isEmpty ? "" : "≈" + text
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
        // 句として助けている語には、語ごとの助けを重ねない。
        var covered = Set<Int>()
        for phrase in page.phrases {
            let d = display(of: phrase)
            guard d != .none else { continue }
            state.phrases.append(RenderState.PhraseItem(words: phrase.words, display: d, gloss: gloss(of: phrase)))
            covered.formUnion(phrase.words)
        }
        for (i, word) in page.words.enumerated() where !covered.contains(i) {
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

    /// 辞書の成句は、語彙レベルへの影響を控えめにする（難しさの推定が語より粗いため）。
    private static let phraseWeight = 0.3

    private func toggle(phrase: PhraseAnn) {
        switch display(of: phrase) {
        case .gloss:
            revealed.remove(phrase.key)
            learner.markKnown(key: phrase.key, difficulty: phrase.difficulty, weight: Self.phraseWeight)
        case .hint:
            revealed.insert(phrase.key)
            learner.lapse(key: phrase.key)
        case .none:
            learner.markUnknown(key: phrase.key, difficulty: phrase.difficulty, weight: Self.phraseWeight)
        }
    }

    /// ⌥クリック: 語（その語が熟語の一部なら熟語）の助けを切り替える。
    /// 辞書で答えられないときは、端末内モデルへの問い合わせを返す。
    func toggleWord(_ index: Int) -> MeaningRequest? {
        guard let page, index < page.words.count else { return nil }
        let word = page.words[index]
        let phrase = page.phrases.first { $0.words.contains(index) }

        if let phrase, display(of: phrase) != .none {
            if justOpened.remove(phrase.key) != nil {
                // 今しがた自分で開いた熟語をもう一度クリック → 熟語ではなかった。語のほうを助ける。
                learner.forget(key: phrase.key)
                skipped.insert(phrase.key)
            } else {
                // 句として出ているなら、その句を「もう知っている／意味を見る」。
                toggle(phrase: phrase)
                return nil
            }
        }
        let shown = display(of: word)
        // 何も出ていない語が熟語の一部なら、まず熟語として助ける（知らないのは語より言い回しのことが多い）。
        if shown == .none, let phrase, !skipped.contains(phrase.key), !(learner.data.words[phrase.key]?.known ?? false) {
            toggle(phrase: phrase)
            justOpened.insert(phrase.key)
            return nil
        }
        let difficulty = word.auto ? word.difficulty : nil
        switch shown {
        case .gloss:
            guard !pending.contains(word.key) else { return nil }
            revealed.remove(word.key)
            learner.markKnown(key: word.key, difficulty: difficulty)
        case .hint:
            revealed.insert(word.key)
            learner.lapse(key: word.key)
        case .none:
            if word.glosses.isEmpty, learner.customGloss(word.key) == nil {
                guard word.text.count >= 2, word.sentence < page.sentences.count else { return nil }
                pending.insert(word.key)
                return MeaningRequest(key: word.key, phrase: word.text, sentence: page.sentences[word.sentence].text)
            }
            learner.markUnknown(key: word.key, difficulty: difficulty)
        }
        return nil
    }

    /// ⌥ドラッグで選べる範囲。同じ文の中の 2〜6 語で、文全体は選べない（全文訳はしない）。
    func selection(from a: Int, to b: Int) -> [Int] {
        guard let page, a != b, a < page.words.count, b < page.words.count else { return [] }
        let lo = min(a, b), hi = max(a, b)
        let si = page.words[lo].sentence
        guard si == page.words[hi].sentence, si < page.sentences.count else { return [] }
        let count = hi - lo + 1
        guard count <= Self.maxPhraseWords, count < page.sentences[si].words.count else { return [] }
        return Array(lo...hi)
    }

    /// ⌥ドラッグ: 選んだ句の意味を出す。
    func selectPhrase(from a: Int, to b: Int) -> MeaningRequest? {
        let indices = selection(from: a, to: b)
        guard var page = page, !indices.isEmpty else { return nil }
        // 辞書の成句とほぼ同じ範囲（はみ出しても 1 語）なら、辞書の意味を使う。
        if let existing = page.phrases.first(where: {
            Set($0.words).isSubset(of: indices) && indices.count - $0.words.count <= 1 && $0.words.count >= 2
        }) {
            skipped.remove(existing.key)
            if display(of: existing) == .none { toggle(phrase: existing) }
            return nil
        }
        let key = indices.map { page.words[$0].text.lowercased() }.joined(separator: " ")
        // 重なる句は、新しく選んだ範囲に置き換える。
        page.phrases.removeAll { !Set($0.words).isDisjoint(with: indices) }
        page.phrases.append(PhraseAnn(words: indices, key: key, gloss: "", difficulty: nil, custom: true))
        self.page = page
        if learner.customGloss(key) != nil {
            learner.markUnknown(key: key, difficulty: nil)
            return nil
        }
        pending.insert(key)
        let sentence = page.sentences[page.words[indices[0]].sentence].text
        let phrase = indices.map { page.words[$0].text }.joined(separator: " ")
        return MeaningRequest(key: key, phrase: phrase, sentence: sentence)
    }

    /// 端末内モデルの答えが返ってきた（nil は失敗）。
    func resolve(_ request: MeaningRequest, gloss: String?) {
        pending.remove(request.key)
        if let gloss {
            learner.markUnknown(key: request.key, difficulty: nil, gloss: gloss)
        } else {
            page?.phrases.removeAll { $0.key == request.key && $0.custom }
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
        var held: [(key: String, difficulty: Double?)] = []
        var covered = Set<Int>()
        for phrase in page.phrases {
            switch display(of: phrase) {
            case .gloss:
                covered.formUnion(phrase.words)
                if !revealed.contains(phrase.key), !pending.contains(phrase.key) { glossed.append(phrase.key) }
            case .hint:
                covered.formUnion(phrase.words)
                held.append((phrase.key, phrase.difficulty))
            case .none: break
            }
        }
        for (i, word) in page.words.enumerated() where !covered.contains(i) {
            switch display(of: word) {
            case .gloss: if !revealed.contains(word.key), !pending.contains(word.key) { glossed.append(word.key) }
            case .hint: held.append((word.key, word.auto ? word.difficulty : nil))
            case .none: break
            }
        }
        let auto = page.sentences.filter { chosenLevel[$0.id] == nil && autoLevel($0) > 0 }.map(\.id)
        learner.credit(glossed: glossed, hintsHeld: held, autoSentences: auto)
    }
}
