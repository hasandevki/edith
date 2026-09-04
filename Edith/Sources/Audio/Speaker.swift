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

  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private let pcm = PCMPlayer(sampleRate: ElevenLabsClient.sampleRate)
  @ObservationIgnored private var queue: [String] = []
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var appleContinuation: CheckedContinuation<Void, Never>?
  @ObservationIgnored private var prefetch: (text: String, task: Task<[Data], Error>)?
  @ObservationIgnored private var elevenDisabledUntil = Date.distantPast

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  // MARK: Genel API

  func speak(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    queue.append(trimmed)
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
      let text = queue.removeFirst()
      if let next = queue.first, useEleven, prefetch?.text != next {
        startPrefetch(next)
      }
      await say(text, gen: gen)
    }
    guard gen == generation else { return }
    worker = nil
    isSpeaking = false
    onFinishedAll?()
  }

  private var useEleven: Bool {
    Settings.shared.elevenReady && Date() >= elevenDisabledUntil
  }

  private func say(_ text: String, gen: Int) async {
    if useEleven {
      do {
        try await sayEleven(text, gen: gen)
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
    await sayApple(text)
  }

  // MARK: ElevenLabs

  private func startPrefetch(_ text: String) {
    prefetch?.task.cancel()
    let settings = Settings.shared
    let task = Task<[Data], Error> {
      var chunks: [Data] = []
      for try await chunk in ElevenLabsClient.streamPCM(
        text: text, voiceId: settings.elevenVoiceId, modelId: settings.elevenModel, apiKey: settings.elevenKey
      ) {
        chunks.append(chunk)
      }
      return chunks
    }
    prefetch = (text, task)
  }

  private func sayEleven(_ text: String, gen: Int) async throws {
    let settings = Settings.shared
    try pcm.begin()
    let started = Date()
    if let ready = prefetch, ready.text == text {
      prefetch = nil
      let chunks = try await ready.task.value
      guard gen == generation else { return }
      for chunk in chunks { pcm.feed(chunk) }
    } else {
      var first = true
      for try await chunk in ElevenLabsClient.streamPCM(
        text: text, voiceId: settings.elevenVoiceId, modelId: settings.elevenModel, apiKey: settings.elevenKey
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

  private func sayApple(_ text: String) async {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = Self.bestTurkishVoice()
    utterance.rate = Settings.shared.speechRate
    utterance.prefersAssistiveTechnologySettings = false
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      appleContinuation = c
      synthesizer.speak(utterance)
    }
  }

  static func turkishVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.lowercased().hasPrefix("tr") }
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
