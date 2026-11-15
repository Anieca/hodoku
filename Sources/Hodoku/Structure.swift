import Foundation
import NaturalLanguage

enum POS {
    case noun, verb, adj, adv, pron, det, prep, conj, particle, other

    init(_ tag: NLTag?) {
        switch tag {
        case .noun?: self = .noun
        case .verb?: self = .verb
        case .adjective?: self = .adj
        case .adverb?: self = .adv
        case .pronoun?: self = .pron
        case .determiner?: self = .det
        case .preposition?: self = .prep
        case .conjunction?: self = .conj
        case .particle?: self = .particle
        default: self = .other
        }
    }
}

struct SToken {
    let lower: String
    var pos: POS
    /// この語の直後に , ; : ― ( ) などの区切りがある
    let strong: Bool
}

struct SentenceStructure {
    /// 意味のかたまりが始まる語の位置（先頭の 0 は含まない）
    var chunkStarts: [Int] = []
    /// 主節に属する語か（従属節・挿入句の中なら false）
    var isMain: [Bool] = []
    var subject: Range<Int>?
    var verb: Range<Int>?
}

/// 長い文の骨組みを取り出す。訳はせず、区切りと主語・動詞の位置だけを返す。
/// 端末内の言語モデルは無害な文でも安全フィルタで失敗することが多かったため、規則で解析している。
enum StructureAnalyzer {
    private static let be: Set = ["is", "are", "was", "were", "be", "been", "being", "am", "'s", "'re"]
    private static let have: Set = ["have", "has", "had", "having"]
    private static let aux: Set = be.union(have).union([
        "do", "does", "did", "will", "would", "can", "could", "may", "might", "must", "shall", "should",
    ])
    private static let pureSubordinators: Set = [
        "although", "though", "because", "if", "unless", "while", "whereas", "whether", "when", "whenever",
        "where", "wherever", "which", "who", "whom", "whose", "why", "how",
    ]
    /// 前置詞にもなるもの。接続詞と判定されたときだけ節の始まりとみなす。
    private static let dualSubordinators: Set = ["after", "before", "since", "until", "as", "once"]
    private static let coordinators: Set = ["and", "but", "or"]
    private static let nominative: Set = ["i", "you", "he", "she", "we", "they", "it"]
    private static let irregularParticiples: Set = [
        "written", "given", "taken", "known", "made", "built", "held", "seen", "done", "shown", "found",
        "left", "kept", "sent", "set", "put", "told", "sold", "paid", "led", "brought", "bought", "caught",
        "taught", "thought", "driven", "chosen", "drawn", "grown", "thrown", "born", "worn", "torn", "run",
        "begun", "won", "met", "lost", "spent", "read", "said", "heard", "meant", "felt", "based",
    ]
    /// that なしで節を続けられる動詞
    private static let thatless: Set = [
        "think", "thinks", "thought", "believe", "believes", "believed", "say", "says", "said", "know",
        "knows", "knew", "hope", "hopes", "hoped", "feel", "feels", "felt", "suppose", "claim", "claims",
        "claimed", "argue", "argues", "argued", "suggest", "suggests", "suggested", "show", "shows", "showed",
        "mean", "means", "meant", "find", "finds", "assume", "assumes", "assumed", "realize", "realized",
    ]
    private static let toLinkers: Set = ["used", "have", "has", "had", "going", "ought", "need", "needs", "able"]

    static func analyze(_ input: [SToken]) -> SentenceStructure {
        var t = input
        let n = t.count
        // 品詞判定の誤りを補う: "models trained on ..." の models が動詞とされることがある。
        // 三単現の形の直後に別の動詞が続くなら、名詞（複数形）とみなす。
        for i in 0..<max(0, n - 1) where t[i].pos == .verb && t[i].lower.hasSuffix("s") && !aux.contains(t[i].lower) && !t[i].strong {
            let next = t[i + 1]
            let participle = (next.lower.count > 3 && next.lower.hasSuffix("ed")) || irregularParticiples.contains(next.lower)
            if aux.contains(next.lower) || (next.pos == .verb && participle) { t[i].pos = .noun }
        }
        var out = SentenceStructure()
        out.isMain = [Bool](repeating: true, count: n)
        guard n > 0 else { return out }

        func isVerbLike(_ i: Int) -> Bool { t[i].pos == .verb || aux.contains(t[i].lower) }
        func isIng(_ i: Int) -> Bool { t[i].lower.count > 4 && t[i].lower.hasSuffix("ing") }
        func isParticipleLike(_ i: Int) -> Bool {
            let w = t[i].lower
            return (w.count > 3 && w.hasSuffix("ed")) || irregularParticiples.contains(w)
        }
        func isSubordinator(_ i: Int) -> Bool {
            let w = t[i].lower
            if pureSubordinators.contains(w) { return true }
            if w == "that" {
                if t[i].pos == .det { return false }
                // "that" の直後が名詞で終わるなら指示語（that idea）
                return !(i + 1 < n && t[i + 1].pos == .noun && (i + 2 >= n || t[i + 1].strong))
            }
            return dualSubordinators.contains(w) && (t[i].pos == .conj || clauseFollows(i))
        }
        /// "before the merger was announced" のように、直後に主語と動詞が続くか
        func clauseFollows(_ i: Int) -> Bool {
            guard i + 1 < n, !t[i].strong else { return false }
            switch t[i + 1].pos {
            case .det, .pron, .noun, .adj: break
            default: return false
            }
            var j = i + 2
            while j < n, !t[j - 1].strong {
                let w = t[j].lower
                if coordinators.contains(w) || pureSubordinators.contains(w) || w == "that" { return false }
                if isVerbLike(j), t[j - 1].lower != "to", !isIng(j) { return true }
                j += 1
            }
            return false
        }
        func startsNounPhrase(_ i: Int) -> Bool {
            switch t[i].pos {
            case .det, .pron, .noun, .adj, .other: return true
            default: return false
            }
        }
        /// i 以降に「確実に述語になる動詞」があるか（節や等位接続をまたがない範囲で）
        func hasLaterFiniteVerb(from start: Int) -> Bool {
            var j = start
            while j < n {
                let w = t[j].lower
                if coordinators.contains(w) || isSubordinator(j) { return false }
                if j + 1 < n, t[j].pos == .prep, ["which", "whom", "whose"].contains(t[j + 1].lower) { return false }
                if isVerbLike(j), t[j - 1].lower != "to" {
                    if aux.contains(w) { return true }
                    if !isIng(j) && !isParticipleLike(j) { return true }
                }
                j += 1
            }
            return false
        }

        struct Clause {
            var isMainClause = false
            var hasVerb = false
            /// コンマで始まった挿入。次のコンマで閉じる。
            var paren = false
        }
        var stack = [Clause(isMainClause: true)]
        var boundary = [Bool](repeating: false, count: n)
        var mainVerb: Range<Int>?
        var mainVerbAmbiguous = false
        var groupEnd = 0
        var chunkLen = 0
        var chunkHasVerb = false
        var skipOpener = -1

        for i in 0..<n {
            let w = t[i].lower
            let commaBefore = i > 0 && t[i - 1].strong
            var closedParen = false
            var returnedFromClause = false

            if commaBefore {
                if stack.last!.paren {
                    stack.removeLast()
                    closedParen = true
                } else if stack.count > 1, stack.last!.hasVerb, !isSubordinator(i),
                    startsNounPhrase(i) || coordinators.contains(w)
                {
                    // "When ..., S V" のように、先行する従属節がコンマで終わる。
                    while stack.count > 1, stack.last!.hasVerb { stack.removeLast() }
                }
            }

            // 節・挿入句の始まり
            var opened = false
            var weakOpen = false
            var participleOpen = false
            if i != skipOpener {
                if t[i].pos == .prep, i + 1 < n, ["which", "whom", "whose"].contains(t[i + 1].lower) {
                    stack.append(Clause(paren: commaBefore))
                    opened = true
                    skipOpener = i + 1
                } else if isSubordinator(i) {
                    stack.append(Clause(paren: commaBefore))
                    opened = true
                } else if i > 0, !commaBefore, nominative.contains(w),
                    t[i - 1].pos == .noun || thatless.contains(t[i - 1].lower)
                {
                    // 関係詞や that の省略: "the text they produce", "I think it is"
                    stack.append(Clause())
                    opened = true
                    weakOpen = true
                } else if i > 0, !commaBefore, thatless.contains(t[i - 1].lower),
                    t[i].pos == .det || t[i].pos == .noun, hasLaterFiniteVerb(from: i + 1)
                {
                    stack.append(Clause())
                    opened = true
                    weakOpen = true
                } else if (commaBefore && !closedParen) || (i == 0 && t.contains(where: \.strong)) {
                    // 分詞で始まる挿入句: ", released two years later," / "Trained on ..., the model"
                    let j = (t[i].pos == .adv && i + 1 < n) ? i + 1 : i
                    if t[j].pos == .verb, !aux.contains(t[j].lower), isIng(j) || isParticipleLike(j) {
                        stack.append(Clause(hasVerb: true, paren: true))
                        opened = true
                        participleOpen = true
                    }
                }
            }

            // 動詞のまとまり
            var finiteStart = false
            if i >= groupEnd, isVerbLike(i) {
                let prev = i > 0 ? t[i - 1].lower : ""
                let afterTo = prev == "to" || (i > 1 && t[i - 1].pos == .adv && t[i - 2].lower == "to")
                var finite = !afterTo && !isIng(i) && !participleOpen
                var ambiguous = false
                if finite, isParticipleLike(i), !aux.contains(w), i > 0, t[i - 1].pos == .noun || t[i - 1].lower == "those", !commaBefore,
                    i + 1 >= n || t[i + 1].pos == .prep || t[i + 1].pos == .adv
                {
                    // "models trained on data ... can be said": 名詞を後ろから修飾する過去分詞かもしれない。
                    ambiguous = true
                    if hasLaterFiniteVerb(from: i + 1) { finite = false }
                }
                // 助動詞の連なり + 本動詞ひとつまでを 1 つのまとまりにする（has been formed / used to tell）。
                var j = i + 1
                var open = aux.contains(w)
                var lastVerb = w
                while j < n, !t[j - 1].strong {
                    if t[j].lower == "to", toLinkers.contains(lastVerb), j + 1 < n, isVerbLike(j + 1) {
                        lastVerb = t[j + 1].lower
                        open = aux.contains(lastVerb)
                        j += 2
                    } else if open, isVerbLike(j) {
                        lastVerb = t[j].lower
                        open = aux.contains(lastVerb)
                        j += 1
                    } else if open, t[j].pos == .adv || t[j].lower == "not" {
                        j += 1
                    } else {
                        break
                    }
                }
                while j - 1 > i, t[j - 1].pos == .adv || t[j - 1].lower == "to" { j -= 1 }
                groupEnd = j

                if finite {
                    let coordinated = coordinators.contains(prev) || (i > 1 && t[i - 1].pos == .adv && coordinators.contains(t[i - 2].lower))
                    if !coordinated {
                        // すでに動詞を持つ節は終わっている。動詞を待っている外側の節へ戻る。
                        while stack.count > 1, stack.last!.hasVerb {
                            stack.removeLast()
                            returnedFromClause = true
                        }
                    }
                    if !stack[stack.count - 1].hasVerb {
                        stack[stack.count - 1].hasVerb = true
                        finiteStart = true
                        if stack.count == 1 {
                            mainVerb = i..<j
                            mainVerbAmbiguous = ambiguous
                        }
                    } else if stack.count == 1, mainVerbAmbiguous, !coordinated {
                        // 先に主動詞とみなしたものは分詞だった。こちらが本当の主動詞。
                        mainVerb = i..<j
                        mainVerbAmbiguous = false
                        finiteStart = true
                        returnedFromClause = true
                    }
                }
            }

            out.isMain[i] = stack.count == 1

            // 区切り
            var b = false
            if i > 0 {
                if commaBefore {
                    b = true
                } else if opened, !weakOpen || chunkLen >= 3 {
                    b = true
                } else if finiteStart, returnedFromClause || (chunkLen >= 4 && !chunkHasVerb) {
                    b = true
                } else if w == "to", i + 1 < n, isVerbLike(i + 1) {
                    b = chunkLen >= 4
                } else if t[i].pos == .prep, w != "of", i >= groupEnd, i != skipOpener, chunkLen >= 3,
                    t[i - 1].pos != .prep, n - i >= 2
                {
                    b = true
                } else if coordinators.contains(w), chunkLen >= 4, n - i >= 3 {
                    // 動詞を含むまとまりをつなぐ and だけ区切る（"swift and transparent" は区切らない）。
                    var j = i + 1
                    while j < n, !t[j - 1].strong, !isVerbLike(j) { j += 1 }
                    b = j < n && !t[j - 1].strong
                }
            }
            if b {
                boundary[i] = true
                chunkLen = 0
                chunkHasVerb = false
            }
            chunkLen += 1
            if isVerbLike(i) { chunkHasVerb = true }
        }

        // 1 語だけのかたまりは隣にくっつける。
        var starts = (0..<n).filter { $0 == 0 || boundary[$0] }
        var k = 0
        while k < starts.count {
            let s = starts[k]
            let e = k + 1 < starts.count ? starts[k + 1] : n
            if e - s == 1, starts.count > 1 {
                if s > 0, !t[s - 1].strong {
                    starts.remove(at: k)
                    continue
                } else if e < n, !t[e - 1].strong {
                    starts.remove(at: k + 1)
                    continue
                }
            }
            k += 1
        }
        out.chunkStarts = Array(starts.dropFirst())
        out.verb = mainVerb

        // 主語: 主動詞の前にある、主節レベルの名詞句（前置詞句の手前まで）
        if let mainVerb {
            var e = mainVerb.lowerBound
            while e > 0, !out.isMain[e - 1] || t[e - 1].pos == .adv { e -= 1 }
            var s = e
            while s > 0, out.isMain[s - 1], !(s < e && t[s - 1].strong) { s -= 1 }
            while s < e, t[s].pos == .adv || t[s].pos == .conj { s += 1 }
            if let p = (s..<e).first(where: { $0 > s && t[$0].pos == .prep && t[$0].lower != "of" }) { e = p }
            if s < e { out.subject = s..<e }
        }
        return out
    }
}
