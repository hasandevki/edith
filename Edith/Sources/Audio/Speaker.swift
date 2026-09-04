import AVFoundation
import Foundation
import Observation

/// Cümle cümle seslendirme. Cevap akışı geldikçe kuyruğa eklenir.
@Observable
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private(set) var isSpeaking = false
  var onFinishedAll: (() -> Void)?

  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var pending = 0

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }

  func speak(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let utterance = AVSpeechUtterance(string: trimmed)
    utterance.voice = Self.bestTurkishVoice()
    utterance.rate = Settings.shared.speechRate
    utterance.prefersAssistiveTechnologySettings = false
    pending += 1
    isSpeaking = true
    synthesizer.speak(utterance)
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    pending = 0
    isSpeaking = false
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
    if !wanted.isEmpty, let v = AVSpeechSynthesisVoice(identifier: wanted) {
      return v
    }
    return turkishVoices().first ?? AVSpeechSynthesisVoice(language: "tr-TR")
  }

  // MARK: AVSpeechSynthesizerDelegate

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.utteranceEnded() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.utteranceEnded() }
  }

  private func utteranceEnded() {
    pending = max(0, pending - 1)
    if pending == 0 {
      isSpeaking = false
      onFinishedAll?()
    }
  }
}
