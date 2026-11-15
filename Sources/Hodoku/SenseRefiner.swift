import Foundation
import FoundationModels

@Generable
struct SensePick {
    @Guide(description: "Number of the meaning that fits the word as used in the sentence")
    var number: Int
}

/// 多義語について、文脈に合う語義を端末内の言語モデル（Apple Intelligence）に選ばせる。
/// 候補は辞書の語義だけで、モデルに訳を作らせることはしない。使えないときは辞書の先頭の語義のまま。
actor SenseRefiner {
    private var cache: [String: Int] = [:]
    private var meanings: [String: String] = [:]

    /// 辞書にない語や、使う人が選んだ句の、その文での意味を短い日本語で返す。
    /// 語句だけを渡して語句の意味だけを受け取る（文全体の訳は作らせない）。
    func meaning(of phrase: String, in sentence: String) async -> String? {
        guard isAvailable else { return nil }
        let key = phrase + "|" + sentence
        if let hit = meanings[key] { return hit }
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: "You are an English-Japanese dictionary. Reply with only the Japanese meaning of the phrase as used in the sentence: a few words, no explanation, no English.")
        do {
            // 文字列の構造化出力は止まらずに生成し続けることがあったので、素の応答を短く打ち切る。
            let raw = try await session.respond(
                to: "Sentence: \(sentence)\nPhrase: \(phrase)\nJapanese meaning:",
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 24)
            ).content
            var text = (raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " 　「」\"'。.、"))
            guard !text.isEmpty else { return nil }
            if text.count > 18 { text = String(text.prefix(17)) + "…" }
            meanings[key] = text
            return text
        } catch {
            return nil
        }
    }

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func pick(word: String, sentence: String, candidates: [String]) async -> Int? {
        guard candidates.count > 1, isAvailable else { return nil }
        let key = word + "|" + sentence
        if let hit = cache[key] { return hit >= 0 ? hit : nil }
        let list = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: "Pick which dictionary meaning fits the word as used in the sentence.")
        do {
            let answer = try await session.respond(
                to: "Sentence: \(sentence)\nWord: \(word)\nMeanings:\n\(list)", generating: SensePick.self
            ).content.number
            let index = (1...candidates.count).contains(answer) ? answer - 1 : -1
            cache[key] = index
            return index >= 0 ? index : nil
        } catch {
            cache[key] = -1
            return nil
        }
    }
}
