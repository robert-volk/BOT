import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device language model (Apple Intelligence). Free, private, no network, and fast:
/// the first tokens arrive in a fraction of a second on supported iPhones (15 Pro and newer).
@available(iOS 26.0, *)
struct AppleBrain: Brain {
    var displayName: String { "On-device AI" }

    static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            let r = String(describing: reason).lowercased()
            if r.contains("eligible") { return "This iPhone doesn't support Apple Intelligence." }
            if r.contains("enabled") { return "Turn on Apple Intelligence in Settings." }
            if r.contains("ready") { return "Apple Intelligence is still downloading its model." }
            return "Apple Intelligence isn't available right now."
        }
    }

    func prewarm(system: String) {
        LanguageModelSession(instructions: system).prewarm()
    }

    func respond(system: String, history: [ChatTurn], user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: system)
                    let prompt = PromptBuilder.transcriptPrompt(history: history, user: user)
                    let options = GenerationOptions(temperature: 0.8, maximumResponseTokens: maxTokens)
                    var sent = 0
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        let full = snapshot.content
                        // Snapshots are cumulative; forward only the new tail.
                        if full.count > sent {
                            continuation.yield(String(full.dropFirst(sent)))
                            sent = full.count
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }
}
#endif
