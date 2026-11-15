import AppKit
import NaturalLanguage
import Vision

struct WordAnn {
    var text: String
    /// 画面上の位置（ポイント、左上原点）
    var rect: CGRect
    /// 学習状態のキー（原形・小文字）
    var key: String
    /// nil なら助けの対象外（辞書にない・固有名詞・短すぎる など）
    var difficulty: Double?
    var glosses: [String]
    var sentence: Int
    /// 周囲の背景色
    var bg: NSColor
}

struct SentAnn {
    var id: String
    var text: String
    /// Page.words の添字
    var words: [Int]
    var structure: SentenceStructure
}

struct Page {
    var size: CGSize
    var words: [WordAnn] = []
    var sentences: [SentAnn] = []
}

/// 画像 → 文字認識 → 単語と文の情報。すべて端末内で完結する。
enum Analyzer {
    private struct Line {
        var text: String
        var rect: CGRect
        var tokens: [(text: String, range: Range<String.Index>, rect: CGRect)]
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z]+(?:['’][A-Za-z]+)*(?:-[A-Za-z]+)*"#)
    private static let strongPunct = CharacterSet(charactersIn: ",;:—–()[]")

    static func analyze(image: CGImage, viewSize: CGSize) -> Page {
        var page = Page(size: viewSize)
        let lines = recognize(image: image, viewSize: viewSize)
        let sampler = ColorSampler(image: image, viewSize: viewSize)
        for para in paragraphs(lines) {
            build(paragraph: para, into: &page, sampler: sampler)
        }
        return page
    }

    /// テスト用: 文字列だけから構造を調べる。
    static func structure(of sentence: String) -> (words: [String], structure: SentenceStructure) {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        let ns = sentence as NSString
        let matches = wordPattern.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
        var words: [String] = []
        var tokens: [SToken] = []
        for (i, m) in matches.enumerated() {
            let r = Range(m.range, in: sentence)!
            let next = i + 1 < matches.count ? Range(matches[i + 1].range, in: sentence)!.lowerBound : sentence.endIndex
            words.append(String(sentence[r]))
            tokens.append(
                SToken(
                    lower: sentence[r].lowercased(),
                    pos: POS(tagger.tag(at: r.lowerBound, unit: .word, scheme: .lexicalClass).0),
                    strong: isStrong(sentence[r.upperBound..<next])))
        }
        return (words, StructureAnalyzer.analyze(tokens))
    }

    private static func isStrong(_ gap: Substring) -> Bool {
        gap.unicodeScalars.contains { strongPunct.contains($0) } || gap.contains(" - ")
    }

    // MARK: - 文字認識

    private static func recognize(image: CGImage, viewSize: CGSize) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // 日本語も指定しておくと、日本語の部分が英字の化け文字として拾われない。
        request.recognitionLanguages = ["en-US", "ja-JP"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        func toView(_ b: CGRect) -> CGRect {
            CGRect(
                x: b.minX * viewSize.width, y: (1 - b.maxY) * viewSize.height,
                width: b.width * viewSize.width, height: b.height * viewSize.height)
        }
        var lines: [Line] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            let ns = s as NSString
            var tokens: [(String, Range<String.Index>, CGRect)] = []
            for m in wordPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: s), let box = try? cand.boundingBox(for: r) else { continue }
                tokens.append((String(s[r]), r, toView(box.boundingBox)))
            }
            guard !tokens.isEmpty else { continue }
            lines.append(Line(text: s, rect: toView(obs.boundingBox), tokens: tokens))
        }
        return lines
    }

    // MARK: - 行を段落にまとめる

    private static func paragraphs(_ lines: [Line]) -> [[Line]] {
        let sorted = lines.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
        var paras: [[Line]] = []
        for line in sorted {
            var bestIndex: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for (i, para) in paras.enumerated() {
                let last = para[para.count - 1].rect
                let h = min(last.height, line.rect.height)
                let gap = line.rect.minY - last.maxY
                let overlap = min(last.maxX, line.rect.maxX) - max(last.minX, line.rect.minX)
                guard gap > -h * 0.5, gap < h * 0.9,
                    abs(last.height - line.rect.height) < h * 0.3,
                    overlap > min(last.width, line.rect.width) * 0.5,
                    abs(last.minX - line.rect.minX) < h * 4
                else { continue }
                if gap < bestGap {
                    bestGap = gap
                    bestIndex = i
                }
            }
            if let bestIndex { paras[bestIndex].append(line) } else { paras.append([line]) }
        }
        return paras
    }

    // MARK: - 段落 → 単語・文

    private static let posName: [POS: String] = [.verb: "動詞", .noun: "名詞", .adj: "形容詞", .adv: "副詞"]

    private static func build(paragraph lines: [Line], into page: inout Page, sampler: ColorSampler) {
        // 行をつないで 1 本の文字列にし、各語の位置を覚えておく。
        var text = ""
        var toks: [(text: String, range: Range<String.Index>, rect: CGRect)] = []
        var pending: [(String, Int, Int, CGRect)] = []
        for line in lines {
            if !text.isEmpty { text += " " }
            let base = text.utf16.count
            for t in line.tokens {
                let lo = line.text.utf16.distance(from: line.text.startIndex, to: t.range.lowerBound)
                let hi = line.text.utf16.distance(from: line.text.startIndex, to: t.range.upperBound)
                pending.append((t.text, base + lo, base + hi, t.rect))
            }
            text += line.text
        }
        for (s, lo, hi, rect) in pending {
            let a = String.Index(utf16Offset: lo, in: text), b = String.Index(utf16Offset: hi, in: text)
            toks.append((s, a..<b, rect))
        }
        guard toks.count >= 4 else { return }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)

        let capitalized = toks.filter { $0.text.first!.isUppercase }.count
        let titleCase = Double(capitalized) / Double(toks.count) > 0.5

        let splitter = NLTokenizer(unit: .sentence)
        splitter.string = text
        splitter.setLanguage(.english)
        var ti = 0
        for sentenceRange in splitter.tokens(for: text.startIndex..<text.endIndex) {
            var indices: [Int] = []
            var stokens: [SToken] = []
            let sentenceIndex = page.sentences.count
            var first = true
            while ti < toks.count, toks[ti].range.lowerBound < sentenceRange.upperBound {
                let tok = toks[ti]
                let lower = tok.text.lowercased()
                let pos = POS(tagger.tag(at: tok.range.lowerBound, unit: .word, scheme: .lexicalClass).0)
                let nextStart = ti + 1 < toks.count ? toks[ti + 1].range.lowerBound : text.endIndex
                stokens.append(SToken(lower: lower, pos: pos, strong: isStrong(text[tok.range.upperBound..<nextStart])))

                var ann = WordAnn(
                    text: tok.text, rect: tok.rect, key: lower, difficulty: nil, glosses: [],
                    sentence: sentenceIndex, bg: sampler.background(near: tok.rect))
                let plain = tok.text.allSatisfy { $0.isLetter && $0.isASCII }
                let acronym = tok.text.count > 1 && tok.text.allSatisfy(\.isUppercase)
                let properNoun = tok.text.first!.isUppercase && !first && !titleCase
                let contentWord = pos == .noun || pos == .verb || pos == .adj || pos == .adv || pos == .other
                if plain, tok.text.count >= 3, !acronym, !properNoun, contentWord {
                    let lemma = tagger.tag(at: tok.range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
                    if let entry = EJDictionary.shared.entry(word: lower, lemma: lemma) {
                        ann.key = lemma ?? lower
                        ann.difficulty = entry.difficulty
                        // 文中での品詞に合う語義を先に。
                        let wanted = posName[pos]
                        let matching = entry.senses.filter { wanted != nil && $0.pos.contains(wanted!) }
                        let ordered = matching + entry.senses.filter { s in !matching.contains { $0.gloss == s.gloss } }
                        ann.glosses = Array(ordered.prefix(5).map(\.gloss))
                    }
                }
                indices.append(page.words.count)
                page.words.append(ann)
                first = false
                ti += 1
            }
            guard !indices.isEmpty else { continue }
            page.sentences.append(
                SentAnn(
                    id: String(text[sentenceRange]).trimmingCharacters(in: .whitespacesAndNewlines),
                    text: String(text[sentenceRange]), words: indices,
                    structure: StructureAnalyzer.analyze(stokens)))
        }
    }
}

/// 注釈を背景になじませるため、語のまわりの色を画面の画像から拾う。
final class ColorSampler {
    private let width: Int, height: Int
    private var pixels: [UInt8]
    private let viewSize: CGSize

    init(image: CGImage, viewSize: CGSize) {
        self.viewSize = viewSize
        width = max(1, image.width / 2)
        height = max(1, image.height / 2)
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.interpolationQuality = .low
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func background(near rect: CGRect) -> NSColor {
        // 語のすぐ外側を数か所拾い、いちばん多い色を背景とみなす（隣の文字を拾っても負けない）。
        // CGContext のメモリは上の行から並ぶ。
        let points = [
            CGPoint(x: rect.minX - 2, y: rect.minY - 1), CGPoint(x: rect.maxX + 2, y: rect.minY - 1),
            CGPoint(x: rect.midX, y: rect.minY - 2), CGPoint(x: rect.minX - 2, y: rect.maxY + 1),
            CGPoint(x: rect.maxX + 2, y: rect.maxY + 1), CGPoint(x: rect.midX, y: rect.maxY + 2),
            CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY - 2),
        ]
        let samples: [(Int, Int, Int)] = points.map { p in
            let x = min(width - 1, max(0, Int(p.x / viewSize.width * CGFloat(width))))
            let y = min(height - 1, max(0, Int(p.y / viewSize.height * CGFloat(height))))
            let o = (y * width + x) * 4
            return (Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))
        }
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) < 40
        }
        let best = samples.max { a, b in samples.filter { near($0, a) }.count < samples.filter { near($0, b) }.count }!
        return NSColor(srgbRed: CGFloat(best.0) / 255, green: CGFloat(best.1) / 255, blue: CGFloat(best.2) / 255, alpha: 1)
    }
}
