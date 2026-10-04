import Foundation

/// Optional cloud brain: Claude Haiku 4.5, Anthropic's fastest model, streamed over SSE.
/// Only used if you pick it in Settings and paste an API key (stored in the Keychain). Billed per use by
/// Anthropic. The VOICE is never a paid service: speech always comes from the free on-device synthesizer.
struct ClaudeBrain: Brain {
    let apiKey: String
    /// Lets Claude run live web searches itself (Anthropic's server-side web search tool, billed per search).
    var nativeSearch = false
    static let model = "claude-haiku-4-5-20251001"
    var displayName: String { "Claude Haiku" }

    private func request(system: String, messages: [[String: String]], maxTokens: Int, stream: Bool, searchTool: Bool = false) throws -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": searchTool ? maxTokens + 300 : maxTokens,
            "system": system,
            "messages": messages,
            "stream": stream,
        ]
        if searchTool {
            body["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 3]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The API needs strictly alternating roles starting with "user".
    private func messages(history: [ChatTurn], user: String) -> [[String: String]] {
        var out: [[String: String]] = []
        func push(_ role: String, _ text: String) {
            if let last = out.last, last["role"] == role {
                out[out.count - 1]["content"] = (last["content"] ?? "") + "\n" + text
            } else {
                out.append(["role": role, "content": text])
            }
        }
        for t in history.suffix(12) {
            let role = t.role == .user ? "user" : "assistant"
            if out.isEmpty && role == "assistant" { continue }
            push(role, t.text)
        }
        push("user", user)
        return out
    }

    func respond(system: String, history: [ChatTurn], user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var useSearch = nativeSearch
                    while true {
                        let req = try request(system: system, messages: messages(history: history, user: user),
                                              maxTokens: maxTokens, stream: true, searchTool: useSearch)
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                            var body = ""
                            for try await line in bytes.lines { body += line }
                            // Web search not enabled for this account? Retry once as a plain chat.
                            if useSearch { useSearch = false; continue }
                            throw BrainError.http(http.statusCode, Self.errorMessage(from: body))
                        }
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:") else { continue }
                            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            guard let data = json.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  obj["type"] as? String == "content_block_delta",
                                  let delta = obj["delta"] as? [String: Any],
                                  let text = delta["text"] as? String else { continue }
                            continuation.yield(text)
                        }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Describes a photo you took with BOT's camera. Claude only (Apple's on-device model can't see images).
    func vision(system: String, jpeg: Data, question: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
        let imageBlock: [String: Any] = ["type": "image", "source": source]
        let textBlock: [String: Any] = ["type": "text", "text": question]
        let message: [String: Any] = ["role": "user", "content": [imageBlock, textBlock]]
        let body: [String: Any] = ["model": Self.model, "max_tokens": maxTokens, "system": system, "messages": [message]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BrainError.http(http.statusCode, Self.errorMessage(from: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func complete(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let req = try request(system: system, messages: [["role": "user", "content": prompt]],
                              maxTokens: maxTokens, stream: false)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BrainError.http(http.statusCode, Self.errorMessage(from: String(data: data, encoding: .utf8) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    private static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        return String(body.prefix(120))
    }
}
