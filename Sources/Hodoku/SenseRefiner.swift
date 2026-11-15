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
