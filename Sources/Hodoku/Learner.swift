import Foundation

enum WordDisplay: Equatable {
    case none  // 助けなし
    case gloss  // 意味を表示
    case hint  // 下線だけ。思い出せなければ ⌥クリックで意味を見る
}

/// 使う人ひとりの理解度。すべて手元の JSON ファイルにだけ保存する。
final class Learner {
    struct WordState: Codable {
        var known = false
        /// 0: 意味を見せる / 1以上: 下線だけ（思い出す練習）/ 3: 卒業
        var strength = 0
        var shows = 0
        var lastCredit: Date?
    }

    struct Data: Codable {
        /// 語彙レベル。難しさがこれを超える語を「たぶん知らない」とみなす。
        var theta = 0.72
        var observations = 0
        var words: [String: WordState] = [:]
        /// これ以上の語数の文に、頼まれなくても区切りを入れる。
        var longThreshold = 28.0
        /// 文の助けを最初にどこまで出すか（1: 区切り / 2: +主語・動詞 / 3: +修飾部を薄く）
        var levelEMA = 1.0
        var creditedSentences: [String: Date] = [:]
    }

    static let graduateStrength = 3
    static let creditInterval: TimeInterval = 30 * 60

    private(set) var data = Data()
    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Hodoku", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("learner.json")
        }
        if let raw = try? Foundation.Data(contentsOf: self.url),
            let decoded = try? JSONDecoder.iso.decode(Data.self, from: raw)
        {
            data = decoded
        }
    }

    func save() {
        guard let raw = try? JSONEncoder.iso.encode(data) else { return }
        try? raw.write(to: url, options: .atomic)
    }

    /// 確認用コマンドで、記録を変えずに語彙レベルだけ差し替える。
    func overrideTheta(_ theta: Double) { data.theta = theta }

    /// 確認用: 記録の時刻を過去にずらし、時間が経ったことにする。
    func ageForTesting(by seconds: TimeInterval) {
        for key in data.words.keys { data.words[key]?.lastCredit?.addTimeInterval(-seconds) }
        for key in data.creditedSentences.keys { data.creditedSentences[key]?.addTimeInterval(-seconds) }
    }

    func reset() {
        data = Data()
        save()
    }

    // MARK: - 単語

    private func pKnown(_ difficulty: Double) -> Double {
        1 / (1 + exp(-(data.theta - difficulty) / 0.08))
    }

    func display(key: String, difficulty: Double) -> WordDisplay {
        if let s = data.words[key] {
            if s.known { return .none }
            return s.strength == 0 ? .gloss : .hint
        }
        return difficulty > data.theta ? .gloss : .none
    }

    /// はっきりした反応（クリック）があったときだけ語彙レベルを大きく動かす。使い始めほど大きく。
    private func observe(known: Bool, difficulty: Double, weight: Double = 1) {
        let k = max(0.025, 0.12 / (1 + Double(data.observations)).squareRoot()) * weight
        data.theta += k * ((known ? 1 : 0) - pKnown(difficulty))
        data.theta = min(1.05, max(0.05, data.theta))
        data.observations += 1
    }

    /// 助けが出ていなかった語を ⌥クリックした＝知らなかった。
    func markUnknown(key: String, difficulty: Double) {
        let wasPredictedKnown = display(key: key, difficulty: difficulty) == .none
        var s = data.words[key] ?? WordState()
        s.known = false
        s.strength = 0
        s.shows = 0
        data.words[key] = s
        if wasPredictedKnown { observe(known: false, difficulty: difficulty) }
        save()
    }

    /// 意味が出ている語を ⌥クリックした＝もう知っている。
    func markKnown(key: String, difficulty: Double) {
        var s = data.words[key] ?? WordState()
        let fresh = data.words[key] == nil
        s.known = true
        s.strength = Self.graduateStrength
        data.words[key] = s
        observe(known: true, difficulty: difficulty, weight: fresh ? 1 : 0.5)
        save()
    }

    /// 下線だけの語を ⌥クリックして意味を見た＝まだ思い出せない。
    func lapse(key: String) {
        var s = data.words[key] ?? WordState()
        s.strength = 0
        s.shows = 1
        s.lastCredit = Date()
        data.words[key] = s
        save()
    }

    /// しばらく表示されていたページを読み終えたとみなして進める。
    /// - 意味を見せた語: 2 回見せたら次からは下線だけにする。
    /// - 下線だけで済んだ語: 間隔を空けて 2 回続けば卒業（助けを出さない）。
    func credit(glossed: [String], hintsHeld: [(key: String, difficulty: Double)], autoSentences: [String]) {
        let now = Date()
        func due(_ s: WordState) -> Bool {
            s.lastCredit.map { now.timeIntervalSince($0) >= Self.creditInterval } ?? true
        }
        for key in Set(glossed) {
            var s = data.words[key] ?? WordState()
            guard !s.known, s.strength == 0, due(s) else { continue }
            s.shows += 1
            if s.shows >= 2 { s.strength = 1 }
            s.lastCredit = now
            data.words[key] = s
        }
        var seen = Set<String>()
        for (key, difficulty) in hintsHeld where seen.insert(key).inserted {
            guard var s = data.words[key], !s.known, s.strength >= 1, due(s) else { continue }
            s.strength += 1
            s.lastCredit = now
            if s.strength >= Self.graduateStrength {
                s.known = true
                observe(known: true, difficulty: difficulty, weight: 0.4)
            }
            data.words[key] = s
        }
        // 自動で区切った文をそのまま読めた → 少しずつ助けを引いていく。
        for id in Set(autoSentences) {
            if let last = data.creditedSentences[id], now.timeIntervalSince(last) < Self.creditInterval { continue }
            data.creditedSentences[id] = now
            data.longThreshold = min(60, data.longThreshold + 0.1)
            data.levelEMA = max(1, data.levelEMA - 0.02)
        }
        if data.creditedSentences.count > 2000 {
            data.creditedSentences = data.creditedSentences.filter { now.timeIntervalSince($0.value) < 86_400 }
        }
        save()
    }

    // MARK: - 文

    var startLevel: Int { min(3, max(1, Int(data.levelEMA.rounded()))) }

    func isLong(wordCount: Int) -> Bool { Double(wordCount) >= data.longThreshold }

    /// 自動では助けが出なかった文で助けを求めた → その長さの文から助けるようにする。
    func requestedHelp(wordCount: Int) {
        let n = Double(wordCount)
        if n < data.longThreshold { data.longThreshold = max(10, 0.6 * data.longThreshold + 0.4 * n) }
        save()
    }

    /// 出ていた助けでは足りず、もう一段求めた。
    func escalated(to level: Int) {
        data.levelEMA += 0.25 * (Double(level) - data.levelEMA)
        save()
    }

    /// 自動で出た助けを消した → この長さなら要らない。
    func dismissedAuto(wordCount: Int) {
        data.longThreshold = min(60, max(data.longThreshold, Double(wordCount)) + 2)
        save()
    }

    // MARK: - 状況

    var stats: (theta: Double, learning: Int, recalling: Int, graduated: Int, longThreshold: Int, startLevel: Int) {
        var learning = 0, recalling = 0, graduated = 0
        for s in data.words.values {
            if s.known { graduated += 1 } else if s.strength == 0 { learning += 1 } else { recalling += 1 }
        }
        return (data.theta, learning, recalling, graduated, Int(data.longThreshold.rounded()), startLevel)
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
