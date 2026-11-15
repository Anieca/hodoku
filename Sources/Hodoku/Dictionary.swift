import CoreServices
import Foundation

// macOS 内蔵の辞書（ウィズダム英和辞典）を実行時に引く。辞書データは同梱しない。
// 公開 API の DCSCopyTextDefinition では辞書を指定できないため、Dictionary Services の非公開関数を使う。
@_silgen_name("DCSCopyAvailableDictionaries")
private func DCSCopyAvailableDictionaries() -> Unmanaged<CFSet>?
@_silgen_name("DCSDictionaryGetName")
private func DCSDictionaryGetName(_ dict: DCSDictionary) -> Unmanaged<CFString>?
@_silgen_name("DCSCopyRecordsForSearchString")
private func DCSCopyRecordsForSearchString(
    _ dict: DCSDictionary, _ string: CFString, _ a: UnsafeMutableRawPointer?, _ b: UnsafeMutableRawPointer?
) -> Unmanaged<CFArray>?
@_silgen_name("DCSRecordCopyData")
private func DCSRecordCopyData(_ record: CFTypeRef, _ version: Int) -> Unmanaged<CFString>?
@_silgen_name("DCSRecordGetHeadword")
private func DCSRecordGetHeadword(_ record: CFTypeRef) -> Unmanaged<CFString>?

struct Sense {
    let pos: String  // 「動詞」「名詞」など（辞書の表記のまま）
    let gloss: String
}

struct DictEntry {
    /// 0（誰でも知っている）〜 1（かなり難しい）。辞書の記述量から推定する。
    let difficulty: Double
    let senses: [Sense]
}

final class EJDictionary {
    static let shared = EJDictionary()

    private let dict: DCSDictionary?
    private var cache: [String: DictEntry?] = [:]
    private let lock = NSLock()

    var isAvailable: Bool { dict != nil }

    private init() {
        var found: DCSDictionary?
        if let set = DCSCopyAvailableDictionaries()?.takeRetainedValue() as NSSet? {
            for item in set {
                let d = item as! DCSDictionary
                let name = (DCSDictionaryGetName(d)?.takeUnretainedValue() as String?) ?? ""
                if name.contains("英和") { found = d }
            }
        }
        dict = found
    }

    func entry(word: String, lemma: String?) -> DictEntry? {
        let key = word + "|" + (lemma ?? "")
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let result = lookup(word: word, lemma: lemma)
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    private func lookup(word: String, lemma: String?) -> DictEntry? {
        guard let dict else { return nil }
        guard
            let records = DCSCopyRecordsForSearchString(dict, word as CFString, nil, nil)?
                .takeRetainedValue() as? [AnyObject], !records.isEmpty
        else { return nil }

        var best: (html: String, rank: Int)?
        var maxSize = 0
        for record in records {
            let headword = ((DCSRecordGetHeadword(record)?.takeUnretainedValue() as String?) ?? "").lowercased()
            let html = (DCSRecordCopyData(record, 0)?.takeRetainedValue() as String?) ?? ""
            maxSize = max(maxSize, html.utf8.count)
            // 見出し語が原形に一致するものを優先し、次に表記そのもの、最後に先頭の候補。
            let rank = headword == lemma ? 0 : (headword == word ? 1 : 2)
            if best == nil || rank < best!.rank { best = (html, rank) }
        }
        guard let best, maxSize > 0 else { return nil }
        let senses = Self.parseSenses(best.html)
        guard !senses.isEmpty else { return nil }
        // 派生語（initially, researcher など）は項目が短くても、元の語が易しければ易しい。
        var difficulty = Self.difficulty(entrySize: maxSize)
        for stem in Self.stems(of: lemma ?? word) {
            if let size = entrySize(of: stem) { difficulty = min(difficulty, Self.difficulty(entrySize: size) + 0.08) }
        }
        return DictEntry(difficulty: difficulty, senses: senses)
    }

    private func entrySize(of word: String) -> Int? {
        guard let dict,
            let records = DCSCopyRecordsForSearchString(dict, word as CFString, nil, nil)?
                .takeRetainedValue() as? [AnyObject]
        else { return nil }
        var size = 0
        for record in records
        where ((DCSRecordGetHeadword(record)?.takeUnretainedValue() as String?) ?? "").lowercased() == word {
            size = max(size, ((DCSRecordCopyData(record, 0)?.takeRetainedValue() as String?) ?? "").utf8.count)
        }
        return size > 0 ? size : nil
    }

    private static let suffixes: [(String, [String])] = [
        ("ically", ["ic"]), ("ally", ["al", ""]), ("ily", ["y"]), ("ly", [""]), ("ation", ["", "e", "ate"]),
        ("ion", ["", "e"]), ("ness", [""]), ("ment", [""]), ("ity", ["", "e"]), ("able", ["", "e"]),
        ("ful", [""]), ("less", [""]), ("er", ["", "e"]), ("or", ["", "e"]), ("ist", [""]), ("ive", ["", "e"]),
        ("ize", [""]), ("al", [""]), ("ing", ["", "e"]), ("ed", ["", "e"]),
    ]

    static func stems(of word: String) -> [String] {
        var out: [String] = []
        for (suffix, replacements) in suffixes where word.hasSuffix(suffix) {
            let base = String(word.dropLast(suffix.count))
            for r in replacements where base.count + r.count >= 3 { out.append(base + r) }
            break
        }
        for prefix in ["un", "non", "re"] where word.hasPrefix(prefix) && word.count - prefix.count >= 4 {
            out.append(String(word.dropFirst(prefix.count)))
        }
        return out
    }

    /// よく使う語ほど辞書の記述が長い（the: 110KB, important: 15KB, mitigate: 1.5KB）。
    /// 頻度表を同梱する代わりに、これを難しさの手がかりにする。
    static func difficulty(entrySize: Int) -> Double {
        let hi = log(60_000.0), lo = log(1_200.0)
        let v = (hi - log(Double(max(entrySize, 1)))) / (hi - lo)
        return min(1, max(0, v))
    }

    // MARK: - 辞書 HTML から語義を取り出す

    private static let marker = try! NSRegularExpression(
        pattern: #"<span[^>]*class="(ps[^"]*|trans)"[^>]*>"#)

    static func parseSenses(_ html: String) -> [Sense] {
        let ns = html as NSString
        var senses: [Sense] = []
        var pos = ""
        var perPos: [String: Int] = [:]
        for m in marker.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let cls = ns.substring(with: m.range(at: 1))
            let start = m.range.location + m.range.length
            if cls.hasPrefix("ps") {
                let end = ns.range(of: "<", range: NSRange(location: start, length: ns.length - start))
                if end.location != NSNotFound {
                    pos = ns.substring(with: NSRange(location: start, length: end.location - start))
                        .trimmingCharacters(in: .whitespaces)
                }
            } else {
                guard perPos[pos, default: 0] < 4, senses.count < 12 else { continue }
                let inner = innerHTML(ns, from: start)
                let gloss = cleanGloss(inner)
                if !gloss.isEmpty, !senses.contains(where: { $0.gloss == gloss }) {
                    senses.append(Sense(pos: pos, gloss: gloss))
                    perPos[pos, default: 0] += 1
                }
            }
        }
        return senses
    }

    /// `from` の位置で開いている span の中身（対応する閉じタグまで）を返す。
    private static func innerHTML(_ ns: NSString, from: Int) -> String {
        var depth = 1
        var i = from
        while i < ns.length {
            let r = ns.range(of: "<", range: NSRange(location: i, length: ns.length - i))
            if r.location == NSNotFound { break }
            if ns.length - r.location >= 6, ns.substring(with: NSRange(location: r.location, length: 6)) == "</span" {
                depth -= 1
                if depth == 0 { return ns.substring(with: NSRange(location: from, length: r.location - from)) }
            } else if ns.length - r.location >= 5,
                ns.substring(with: NSRange(location: r.location, length: 5)) == "<span"
            {
                depth += 1
            }
            i = r.location + 1
        }
        return ns.substring(from: from)
    }

    private static let dropSpan = try! NSRegularExpression(
        pattern: #"<span[^>]*class="(xrg|pr|oup_label|lbl|grnote)[^"]*"[^>]*>"#)
    private static let tag = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let brackets = try! NSRegularExpression(
        pattern: #"〈[^〉]*〉|｟[^｠]*｠|【[^】]*】|《[^》]*》|\([^)]*\)|（[^）]*）|\[[^\]]*\]|〖[^〗]*〗"#)

    static func cleanGloss(_ innerHTML: String) -> String {
        var s = innerHTML
        // 参照（→ desert など）や発音は語義ではないので、入れ子ごと落とす。
        while let m = dropSpan.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) {
            let ns = s as NSString
            let bodyStart = m.range.location + m.range.length
            let body = Self.innerHTML(ns, from: bodyStart)
            let end = min(ns.length, bodyStart + (body as NSString).length + 7)
            s = ns.replacingCharacters(in: NSRange(location: m.range.location, length: end - m.range.location), with: "")
        }
        s = tag.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        s = brackets.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ",;，；.．"))
            .map { part -> String in
                var p = part.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["…を", "…に", "…が", "…と", "…", "を", "に"] where p.hasPrefix(prefix) && p.count > prefix.count + 1 {
                    p.removeFirst(prefix.count)
                    break
                }
                return p
            }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return "" }
        var out = first
        if parts.count > 1, first.count + parts[1].count <= 11 { out += "、" + parts[1] }
        if out.count > 14 { out = String(out.prefix(13)) + "…" }
        return out
    }
}
