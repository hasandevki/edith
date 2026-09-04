import Foundation

/// Claude Messages API'ye ham HTTPS ile akış (SSE) isteği.
enum ClaudeClient {
  enum Event {
    case modelUsed(String)
    case text(String)
    case stopReason(String)
    case done
  }

  struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func stream(
    apiKey: String,
    model: String,
    effort: String,
    system: String,
    messages: [[String: Any]],
    maxTokens: Int = 1024
  ) -> AsyncThrowingStream<Event, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
          request.httpMethod = "POST"
          request.timeoutInterval = 90
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
          request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

          var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": [
              ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
            ],
            "output_config": ["effort": effort],
            "messages": messages,
          ]
          // Güvenlik sınıflandırıcısı reddederse sunucu tarafında başka modele düşer.
          // Sadece Opus 5 / Fable ailesi kabul ediyor; Sonnet'e gönderilirse 400 döner.
          if Self.supportsFallbacks(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
          }
          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          if status != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let message = Self.errorMessage(from: raw) ?? raw
            throw APIError(message: "HTTP \(status): \(message)")
          }

          for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
            else { continue }

            switch type {
            case "message_start":
              if let message = json["message"] as? [String: Any], let model = message["model"] as? String {
                continuation.yield(.modelUsed(model))
              }
            case "content_block_delta":
              if let delta = json["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta",
                let text = delta["text"] as? String
              {
                continuation.yield(.text(text))
              }
            case "message_delta":
              if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                continuation.yield(.stopReason(reason))
              }
            case "error":
              let message = (json["error"] as? [String: Any])?["message"] as? String ?? "bilinmeyen akış hatası"
              throw APIError(message: message)
            case "message_stop":
              continuation.yield(.done)
            default:
              break
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

  /// Hızlı bağlantı testi: kısa bir cevap döndürür.
  static func ping(apiKey: String, model: String) async throws -> String {
    var out = ""
    for try await event in stream(
      apiKey: apiKey, model: model, effort: "low",
      system: "Tek kelimeyle, Türkçe cevap ver.",
      messages: [["role": "user", "content": "Bağlantı testi. Beni duyuyor musun?"]],
      maxTokens: 64
    ) {
      if case .text(let t) = event { out += t }
    }
    return out
  }

  static func supportsFallbacks(_ model: String) -> Bool {
    model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5") || model.hasPrefix("claude-mythos")
  }

  private static func errorMessage(from raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
  }
}
