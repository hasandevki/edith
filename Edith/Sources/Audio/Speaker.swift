import AVFoundation
import Foundation
import Observation

/// Cümle cümle seslendirme kuyruğu. Ayara göre ElevenLabs (akış) ya da Apple sesi.
/// ElevenLabs'e ulaşılamazsa o cümleyi Apple sesiyle okur ve bir süre ElevenLabs'i denemez.
@Observable
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private(set) var isSpeaking = false
  var onFinishedAll: (() -> Void)?

  private struct Item {
    let text: String
    let language: String?
  }

  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private let pcm = PCMPlayer(sampleRate: ElevenLabsClient.sampleRate)
  @ObservationIgnored private var queue: [Item] = []
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var appleContinuation: CheckedContinuation<Void, Never>?
  @ObservationIgnored private var prefetch: (item: Item, task: Task<[Data], Error>)?
  @ObservationIgnored private var elevenDisabledUntil = Date.distantPast

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  // MARK: Genel API

  /// `language`: "tr-TR", "en-US" gibi; nil ise Türkçe.
  func speak(_ text: String, language: String? = nil) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.append(Item(text: trimmed, language: language))
    isSpeaking = true
    if worker == nil {
      let gen = generation
      worker = Task { [weak self] in await self?.drain(gen) }
    }
  }

  func stop() {
    generation += 1
    queue.removeAll()
    worker?.cancel()
    worker = nil
    prefetch?.task.cancel()
    prefetch = nil
    pcm.stop()
    synthesizer.stopSpeaking(at: .immediate)
    if let c = appleContinuation {
      appleContinuation = nil
      c.resume()
    }
    isSpeaking = false
  }

  // MARK: Kuyruk

  private func drain(_ gen: Int) async {
    while !queue.isEmpty, !Task.isCancelled, gen == generation {
      let item = queue.removeFirst()
      if let next = queue.first, useEleven, !(prefetch.map { $0.item.text == next.text && $0.item.language == next.language } ?? false) {
        startPrefetch(next)
      }
      await say(item, gen: gen)
    }
    guard gen == generation else { return }
    worker = nil
    isSpeaking = false
    onFinishedAll?()
  }

  private var useEleven: Bool {
    Settings.shared.elevenReady && Date() >= elevenDisabledUntil
  }

  private func say(_ item: Item, gen: Int) async {
    if useEleven {
      do {
        try await sayEleven(item, gen: gen)
        return
      } catch is CancellationError {
        return
      } catch {
        guard gen == generation else { return }
        log("ElevenLabs hatası, Apple sesine düşülüyor: \(error.localizedDescription)")
        elevenDisabledUntil = Date().addingTimeInterval(60)
        pcm.stop()
      }
    }
    guard gen == generation else { return }
    await sayApple(item)
  }

  // MARK: ElevenLabs

  private static func languageCode(_ language: String?) -> String {
    guard let language, let prefix = language.split(separator: "-").first else { return "tr" }
    return String(prefix).lowercased()
  }

  private func startPrefetch(_ item: Item) {
    prefetch?.task.cancel()
    let settings = Settings.shared
    let code = Self.languageCode(item.language)
    let task = Task<[Data], Error> {
      var chunks: [Data] = []
      for try await chunk in ElevenLabsClient.streamPCM(
        text: item.text, voiceId: settings.elevenVoiceId, modelId: settings.elevenModel,
        apiKey: settings.elevenKey, languageCode: code
      ) {
        chunks.append(chunk)
      }
      return chunks
    }
    prefetch = (item, task)
  }

  private func sayEleven(_ item: Item, gen: Int) async throws {
    let settings = Settings.shared
    try pcm.begin()
    let started = Date()
    UsageTracker.shared.recordEleven(characters: item.text.count, model: settings.elevenModel)
    if let ready = prefetch, ready.item.text == item.text, ready.item.language == item.language {
      prefetch = nil
      let chunks = try await ready.task.value
      guard gen == generation else { return }
      for chunk in chunks { pcm.feed(chunk) }
    } else {
      var first = true
      for try await chunk in ElevenLabsClient.streamPCM(
        text: item.text, voiceId: settings.elevenVoiceId, modelId: settings.elevenModel,
        apiKey: settings.elevenKey, languageCode: Self.languageCode(item.language)
      ) {
        guard gen == generation else { return }
        if first {
          first = false
          log("ElevenLabs ilk ses \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
        pcm.feed(chunk)
      }
    }
    guard gen == generation else { return }
    await pcm.finishAndWait()
  }

  // MARK: Apple

  private func sayApple(_ item: Item) async {
    let utterance = AVSpeechUtterance(string: item.text)
    if let language = item.language, !language.lowercased().hasPrefix("tr") {
      utterance.voice = Self.bestVoice(for: language)
    } else {
      utterance.voice = Self.bestTurkishVoice()
    }
    utterance.rate = Settings.shared.speechRate
    utterance.prefersAssistiveTechnologySettings = false
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      appleContinuation = c
      synthesizer.speak(utterance)
    }
  }

  static func turkishVoices() -> [AVSpeechSynthesisVoice] {
    voices(prefix: "tr")
  }

  static func voices(prefix: String) -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.lowercased().hasPrefix(prefix.lowercased()) }
      .sorted { a, b in
        if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
        return a.name < b.name
      }
  }

  static func bestTurkishVoice() -> AVSpeechSynthesisVoice? {
    let wanted = Settings.shared.voiceIdentifier
    if !wanted.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: wanted) {
      return voice
    }
    return turkishVoices().first ?? AVSpeechSynthesisVoice(language: "tr-TR")
  }

  static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
    let prefix = String(language.split(separator: "-").first ?? Substring(language))
    return voices(prefix: prefix).first ?? AVSpeechSynthesisVoice(language: language)
  }

  // MARK: AVSpeechSynthesizerDelegate

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.appleUtteranceEnded() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.appleUtteranceEnded() }
  }

  private func appleUtteranceEnded() {
    if let c = appleContinuation {
      appleContinuation = nil
      c.resume()
    }
  }
}
