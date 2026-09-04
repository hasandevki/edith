import Foundation

/// ElevenLabs: ses listesi ve akış halinde metinden sese (ham PCM).
enum ElevenLabsClient {
  struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let labels: [String: String]

    var subtitle: String {
      var parts: [String] = []
      if let lang = labels["language"] { parts.append(lang) }
      if let gender = labels["gender"] { parts.append(gender) }
      if let accent = labels["accent"] { parts.append(accent) }
      if parts.isEmpty, !category.isEmpty { parts.append(category) }
      return parts.joined(separator: " · ")
    }
  }

  struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static let sampleRate: Double = 24000

  // MARK: Ses listesi

  static func listVoices(apiKey: String) async throws -> [Voice] {
    var components = URLComponents(string: "https://api.elevenlabs.io/v2/voices")!
    components.queryItems = [URLQueryItem(name: "page_size", value: "100")]
    var request = URLRequest(url: components.url!)
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.timeoutInterval = 30

    let (data, response) = try await URLSession.shared.data(for: request)
    try check(response, data)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let voices = json["voices"] as? [[String: Any]]
    else {
      throw APIError(message: "Ses listesi okunamadı.")
    }
    let parsed: [Voice] = voices.compactMap { item in
      guard let id = item["voice_id"] as? String, let name = item["name"] as? String else { return nil }
      let category = item["category"] as? String ?? ""
      let labels = (item["labels"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
      return Voice(id: id, name: name, category: category, labels: labels)
    }
    // Kullanıcının eklediği/klonladığı sesler önce, hazır sesler sonra.
    return parsed.sorted { a, b in
      let aPremade = a.category == "premade"
      let bPremade = b.category == "premade"
      if aPremade != bPremade { return !aPremade }
      return a.name < b.name
    }
  }

  // MARK: Metinden sese (PCM 16-bit, mono, 24 kHz)

  /// Ses verisini geldikçe parça parça verir. İlk parça küçüktür ki oynatma hemen başlasın.
  static func streamPCM(text: String, voiceId: String, modelId: String, apiKey: String) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!
          components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
          var request = URLRequest(url: components.url!)
          request.httpMethod = "POST"
          request.timeoutInterval = 30
          request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")

          var body: [String: Any] = [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
              "stability": 0.5,
              "similarity_boost": 0.8,
              "style": 0.0,
              "use_speaker_boost": true,
            ],
          ]
          // Dil zorlaması sadece Flash/Turbo modellerinde destekleniyor.
          if modelId.contains("flash") || modelId.contains("turbo") {
            body["language_code"] = "tr"
          }
          request.httpBody = try JSONSerialization.data(withJSONObject: body)

          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          if status != 200 {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            throw APIError(message: "HTTP \(status): \(errorMessage(from: raw) ?? String(decoding: raw.prefix(200), as: UTF8.self))")
          }

          var buffer = Data()
          buffer.reserveCapacity(16_000)
          let firstChunk = 4_800   // 100 ms
          let laterChunk = 9_600   // 200 ms
          var emitted = 0
          for try await byte in bytes {
            if Task.isCancelled { break }
            buffer.append(byte)
            let threshold = emitted == 0 ? firstChunk : laterChunk
            if buffer.count >= threshold {
              continuation.yield(buffer)
              emitted += buffer.count
              buffer = Data()
              buffer.reserveCapacity(laterChunk)
            }
          }
          if !buffer.isEmpty { continuation.yield(buffer) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: Yardımcılar

  private static func check(_ response: URLResponse, _ data: Data) throws {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw APIError(message: "HTTP \(status): \(errorMessage(from: data) ?? String(decoding: data.prefix(200), as: UTF8.self))")
    }
  }

  private static func errorMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let detail = json["detail"] as? [String: Any] {
      return detail["message"] as? String ?? detail["status"] as? String
    }
    if let detail = json["detail"] as? String { return detail }
    return nil
  }
}
