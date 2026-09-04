import Foundation

/// Kamera açıkken belirli aralıklarla bir kareyi kısaca betimleyip hafızaya yazar.
/// "Anahtarı en son nerede gördün?" ve "bugün neler yaptım?" bu notlardan cevaplanır.
@MainActor
final class SceneMemory {
  static let shared = SceneMemory()
  private var task: Task<Void, Never>?
  private init() {}

  func start(glasses: GlassesManager) {
    task?.cancel()
    task = Task { [weak glasses] in
      while !Task.isCancelled {
        let minutes = max(1, Settings.shared.sceneIntervalMinutes)
        try? await Task.sleep(for: .seconds(Double(minutes) * 60))
        guard !Task.isCancelled, let glasses else { continue }
        guard Settings.shared.sceneMemoryEnabled, glasses.isStreaming,
          !Settings.shared.apiKey.isEmpty,
          let jpeg = glasses.currentFrameJPEG(maxDimension: 640, quality: 0.5)
        else { continue }
        await describe(jpeg)
      }
    }
  }

  private func describe(_ jpeg: Data) async {
    let settings = Settings.shared
    let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
    let content: [[String: Any]] = [
      ["type": "image", "source": source],
      ["type": "text", "text": "Betimle."],
    ]
    let request = ClaudeClient.Request(
      apiKey: settings.apiKey,
      model: settings.model,
      effort: "low",
      system: [[
        "type": "text",
        "text": "Bu kare bir gözlük kamerasından, kullanıcının o an baktığı yer. Türkçe, en fazla iki cümleyle, somut betimle: nerede (iç/dış mekân, oda türü), görünen önemli nesneler, yazılar, insanlar varsa kaç kişi. Yorum yapma, sadece gördüğünü yaz.",
      ]],
      messages: [["role": "user", "content": content]],
      maxTokens: 150
    )
    var text = ""
    var usage = ClaudeClient.Usage()
    do {
      for try await event in ClaudeClient.stream(request) {
        switch event {
        case .text(let t): text += t
        case .usage(let u): usage = u
        default: break
        }
      }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      MemoryStore.shared.addSceneNote(trimmed)
      UsageTracker.shared.recordAnswer(model: settings.model, usage: usage)
      log("Sahne notu: \(trimmed)")
    } catch {
      log("Sahne notu hatası: \(error.localizedDescription)")
    }
  }
}
