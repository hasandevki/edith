import Foundation

/// Claude Messages API'ye ham HTTPS ile akış (SSE) isteği. Araç çağrılarını ve
/// sunucu araçlarını (web araması) toplar, kullanım bilgisini döner.
enum ClaudeClient {
  struct ToolUse {
    let id: String
    let name: String
    let input: [String: Any]
  }

  struct Usage {
    var input = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0
    var searches = 0

    mutating func add(_ other: Usage) {
      input += other.input
      cacheRead += other.cacheRead
      cacheWrite += other.cacheWrite
      output += other.output
      searches += other.searches
    }
  }

  enum Event {
    case modelUsed(String)
    case text(String)
    case toolUse(ToolUse)
    case stopReason(String)
    case usage(Usage)
    case assistantBlocks([[String: Any]])
    case done
  }

  struct Request {
    var apiKey: String
    var model: String
    var effort: String
    var system: [[String: Any]]
    var messages: [[String: Any]]
    var tools: [[String: Any]] = []
    var maxTokens = 1024
  }

  struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { status > 0 ? "HTTP \(status): \(message)" : message }
  }

  static func supportsFallbacks(_ model: String) -> Bool {
    model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5") || model.hasPrefix("claude-mythos")
  }

  static func stream(_ r: Request) -> AsyncThrowingStream<Event, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
          request.httpMethod = "POST"
          request.timeoutInterval = 120
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          request.setValue(r.apiKey, forHTTPHeaderField: "x-api-key")
          request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

          var body: [String: Any] = [
            "model": r.model,
            "max_tokens": r.maxTokens,
            "stream": true,
            "system": r.system,
            "output_config": ["effort": r.effort],
            "messages": r.messages,
          ]
          if !r.tools.isEmpty {
            body["tools"] = r.tools
          }
          // Güvenlik sınıflandırıcısı reddederse sunucu tarafında başka modele düşer.
          // Sadece Opus 5 / Fable ailesi kabul ediyor; Sonnet'e gönderilirse 400 döner.
          if supportsFallbacks(r.model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
          }
          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          if status != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw APIError(status: status, message: Self.errorMessage(from: raw) ?? raw)
          }

          var blocks: [Int: [String: Any]] = [:]
          var order: [Int] = []
          var textAcc: [Int: String] = [:]
          var jsonAcc: [Int: String] = [:]
          var usage = Usage()

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
              if let message = json["message"] as? [String: Any] {
                if let model = message["model"] as? String {
                  continuation.yield(.modelUsed(model))
                }
                if let u = message["usage"] as? [String: Any] {
                  usage.input = u["input_tokens"] as? Int ?? 0
                  usage.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
                  usage.cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
                }
              }

            case "content_block_start":
              guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any] else { continue }
              blocks[index] = block
              order.append(index)
              if let text = block["text"] as? String, !text.isEmpty {
                textAcc[index] = text
                continuation.yield(.text(text))
              }

            case "content_block_delta":
              guard let index = json["index"] as? Int, let delta = json["delta"] as? [String: Any] else { continue }
              switch delta["type"] as? String {
              case "text_delta":
                if let text = delta["text"] as? String {
                  textAcc[index, default: ""] += text
                  continuation.yield(.text(text))
                }
              case "input_json_delta":
                if let partial = delta["partial_json"] as? String {
                  jsonAcc[index, default: ""] += partial
                }
              default:
                break
              }

            case "content_block_stop":
              guard let index = json["index"] as? Int, var block = blocks[index] else { continue }
              let blockType = block["type"] as? String ?? ""
              if blockType == "text" {
                block["text"] = textAcc[index] ?? ""
                block.removeValue(forKey: "citations")
              } else if blockType == "tool_use" || blockType == "server_tool_use" {
                let raw = jsonAcc[index] ?? ""
                var input: [String: Any] = [:]
                if !raw.isEmpty, let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                  input = parsed
                }
                block["input"] = input
                if blockType == "tool_use", let id = block["id"] as? String, let name = block["name"] as? String {
                  continuation.yield(.toolUse(ToolUse(id: id, name: name, input: input)))
                }
              }
              blocks[index] = block

            case "message_delta":
              if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                continuation.yield(.stopReason(reason))
              }
              if let u = json["usage"] as? [String: Any] {
                if let output = u["output_tokens"] as? Int { usage.output = output }
                if let serverTools = u["server_tool_use"] as? [String: Any],
                  let searches = serverTools["web_search_requests"] as? Int
                {
                  usage.searches = searches
                }
              }

            case "error":
              let message = (json["error"] as? [String: Any])?["message"] as? String ?? "bilinmeyen akış hatası"
              throw APIError(status: 0, message: message)

            case "message_stop":
              let ordered = order.compactMap { blocks[$0] }.filter { block in
                if block["type"] as? String == "text" {
                  return !((block["text"] as? String ?? "").isEmpty)
                }
                return true
              }
              continuation.yield(.assistantBlocks(ordered))
              continuation.yield(.usage(usage))
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
    let request = Request(
      apiKey: apiKey, model: model, effort: "low",
      system: [["type": "text", "text": "Tek kelimeyle, Türkçe cevap ver."]],
      messages: [["role": "user", "content": "Bağlantı testi. Beni duyuyor musun?"]],
      maxTokens: 64
    )
    for try await event in stream(request) {
      if case .text(let t) = event { out += t }
    }
    return out
  }

  private static func errorMessage(from raw: String) -> String? {
    guard let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
  }
}
