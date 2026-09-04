import Foundation
import Observation
import UIKit

/// Edith'in beyni ve durum makinesi:
/// dinle → "Edith" duy → komutu topla → gör → düşün → konuş → dinle.
@Observable
@MainActor
final class EdithController {
  enum State: String {
    case idle = "Uykuda"
    case listening = "Dinliyor"
    case capturing = "Seni dinliyorum..."
    case thinking = "Düşünüyor"
    case speaking = "Konuşuyor"
  }

  struct TranscriptEntry: Identifiable {
    enum Role { case user, edith, system }
    let id = UUID()
    let role: Role
    let text: String
    let time = Date()
  }

  private(set) var state: State = .idle
  private(set) var transcript: [TranscriptEntry] = []
  private(set) var lastHeard = ""
  private(set) var isListeningActive = false
  var lastError: String?

  @ObservationIgnored let glasses: GlassesManager
  @ObservationIgnored let speaker = Speaker()
  @ObservationIgnored private let speech = SpeechListener()
  @ObservationIgnored private let conversation = Conversation()
  @ObservationIgnored private var requestTask: Task<Void, Never>?
  @ObservationIgnored private var tickTask: Task<Void, Never>?

  // Komut toplama durumu
  @ObservationIgnored private var commandText = ""
  @ObservationIgnored private var commandLastChange = Date()
  @ObservationIgnored private var wakeTime = Date()
  @ObservationIgnored private var promptedForCommand = false
  @ObservationIgnored private var ignoreSpeechUntil = Date.distantPast

  private let commandSilence: TimeInterval = 1.3
  private let promptAfter: TimeInterval = 2.5
  private let giveUpAfter: TimeInterval = 10

  init(glasses: GlassesManager) {
    self.glasses = glasses
    speaker.onFinishedAll = { [weak self] in
      guard let self, self.state == .speaking else { return }
      self.state = self.isListeningActive ? .listening : .idle
    }
    speech.onEvent = { [weak self] event in
      self?.handleSpeech(event)
    }
  }

  // MARK: Dinleme

  func startListening() async {
    guard !isListeningActive else { return }
    let perms = await SpeechListener.requestPermissions()
    guard perms.mic else { fail("Mikrofon izni verilmedi."); return }
    guard perms.speech else { fail("Konuşma tanıma izni verilmedi."); return }
    do {
      try AudioSessionManager.configure()
      try speech.start()
    } catch {
      fail("Dinleme başlatılamadı: \(error.localizedDescription)")
      return
    }
    isListeningActive = true
    state = .listening
    log("Dinleme başladı. Uyandırma kelimesi: \(Settings.shared.wakeWord)")
    tickTask?.cancel()
    tickTask = Task { [weak self] in
      while let self, !Task.isCancelled, self.isListeningActive {
        try? await Task.sleep(for: .milliseconds(200))
        self.tick()
      }
    }
  }

  func stopListening() {
    guard isListeningActive else { return }
    isListeningActive = false
    tickTask?.cancel()
    tickTask = nil
    speech.stop()
    speech.holdRestart = false
    if state != .speaking && state != .thinking {
      state = .idle
    }
  }

  /// Uyandırma kelimesi olmadan, elle komut toplamaya başla.
  func beginManualCapture() {
    guard isListeningActive else { return }
    enterCapturing(initialCommand: "")
  }

  /// Yazarak sor (ses olmadan test için).
  func askTyped(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    finalize(command: trimmed)
  }

  func resetConversation() {
    conversation.reset()
    transcript.removeAll()
    addSystemLine("Konuşma geçmişi sıfırlandı.")
  }

  // MARK: Konuşma tanıma olayları

  private func handleSpeech(_ event: SpeechListener.Event) {
    switch event {
    case .partial(let text), .final(let text):
      lastHeard = text
      guard Date() >= ignoreSpeechUntil else { return }
      let (heardWake, command) = Self.extractCommand(from: text, wakeWord: Settings.shared.wakeWord)

      switch state {
      case .listening, .idle:
        if heardWake { enterCapturing(initialCommand: command) }
      case .thinking, .speaking:
        if heardWake {
          log("Araya girildi.")
          requestTask?.cancel()
          speaker.stop()
          enterCapturing(initialCommand: command)
        }
      case .capturing:
        let newCommand = heardWake ? command : text
        if newCommand != commandText {
          commandText = newCommand
          commandLastChange = Date()
        }
      }

      if case .final = event, state == .capturing, !commandText.isEmpty {
        finalize(command: commandText)
      }

    case .restarted:
      break
    case .error(let message):
      lastError = message
    }
  }

  private func enterCapturing(initialCommand: String) {
    state = .capturing
    commandText = initialCommand
    commandLastChange = Date()
    wakeTime = Date()
    promptedForCommand = false
    speech.holdRestart = true
    log("Uyandırma kelimesi duyuldu. Komut: \"\(initialCommand)\"")
  }

  private func tick() {
    guard state == .capturing else { return }
    let now = Date()
    if !commandText.isEmpty {
      if now.timeIntervalSince(commandLastChange) >= commandSilence {
        finalize(command: commandText)
      }
      return
    }
    if !promptedForCommand, now.timeIntervalSince(wakeTime) >= promptAfter {
      promptedForCommand = true
      ignoreSpeechUntil = now.addingTimeInterval(1.2)
      speaker.speak("Efendim?")
    }
    if now.timeIntervalSince(wakeTime) >= giveUpAfter {
      log("Komut gelmedi, dinlemeye dönülüyor.")
      speech.holdRestart = false
      speech.restartRecognition()
      state = .listening
    }
  }

  private func finalize(command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    speech.holdRestart = false
    if isListeningActive { speech.restartRecognition() }
    commandText = ""
    state = .thinking
    transcript.append(TranscriptEntry(role: .user, text: trimmed))
    requestTask?.cancel()
    requestTask = Task { [weak self] in
      await self?.ask(trimmed)
    }
  }

  // MARK: Claude

  private func ask(_ command: String) async {
    let settings = Settings.shared
    guard !settings.apiKey.isEmpty else {
      speakAndLog("Önce ayarlardan API anahtarını girmen lazım.")
      state = isListeningActive ? .listening : .idle
      return
    }

    var image: Data?
    if glasses.isStreaming {
      if settings.useHiResPhoto {
        image = await glasses.captureHiResJPEG()
      }
      if image == nil {
        image = glasses.currentFrameJPEG()
      }
    }
    let timeText = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
    let context = image == nil
      ? "Bu mesajda görüntü yok; gözler kapalı ya da bağlı değil."
      : "Ekli görüntü şu anki bakış açımı gösteriyor."
    let userText = "\(command)\n\n(Şu an: \(timeText). \(context))"
    conversation.appendUser(text: userText, image: image)
    log("Claude'a gidiyor: \"\(command)\" \(image == nil ? "görüntüsüz" : "görüntülü, \(image!.count / 1024) KB")")

    let chunker = SentenceChunker()
    var full = ""
    var stopReason = ""
    let started = Date()
    var firstTokenAt: Date?

    do {
      for try await event in ClaudeClient.stream(
        apiKey: settings.apiKey,
        model: settings.model,
        effort: settings.effort,
        system: Conversation.systemPrompt(settings: settings),
        messages: conversation.apiMessages()
      ) {
        if Task.isCancelled { break }
        switch event {
        case .modelUsed(let model):
          log("Model: \(model)")
        case .text(let text):
          if firstTokenAt == nil {
            firstTokenAt = Date()
            log("İlk kelime \(String(format: "%.1f", Date().timeIntervalSince(started))) sn sonra.")
          }
          full += text
          for sentence in chunker.push(text) {
            state = .speaking
            speaker.speak(sentence)
          }
        case .stopReason(let reason):
          stopReason = reason
        case .done:
          break
        }
      }
      if Task.isCancelled {
        conversation.dropUnansweredUser()
        return
      }
      for sentence in chunker.flush() {
        state = .speaking
        speaker.speak(sentence)
      }
      if stopReason == "refusal" && full.isEmpty {
        conversation.dropUnansweredUser()
        speakAndLog("Bu isteğe cevap veremiyorum.")
      } else {
        conversation.appendAssistant(text: full)
        transcript.append(TranscriptEntry(role: .edith, text: full))
        log("Cevap tamam (\(full.count) karakter, \(String(format: "%.1f", Date().timeIntervalSince(started))) sn).")
      }
    } catch is CancellationError {
      conversation.dropUnansweredUser()
      return
    } catch {
      conversation.dropUnansweredUser()
      let message = error.localizedDescription
      lastError = message
      log("Claude hatası: \(message)")
      speakAndLog(Self.spokenError(for: message))
    }

    if !speaker.isSpeaking {
      state = isListeningActive ? .listening : .idle
    } else {
      state = .speaking
    }
  }

  private static func spokenError(for message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("401") || lower.contains("authentication") { return "API anahtarı geçersiz görünüyor." }
    if lower.contains("429") || lower.contains("rate") { return "Çok sık istek gitti, biraz sonra tekrar dene." }
    if lower.contains("offline") || lower.contains("internet") || lower.contains("network") || lower.contains("-1009") {
      return "İnternet bağlantısı yok gibi."
    }
    return "Bir hata oldu, tekrar dener misin?"
  }

  private func speakAndLog(_ text: String) {
    state = .speaking
    transcript.append(TranscriptEntry(role: .edith, text: text))
    speaker.speak(text)
  }

  private func addSystemLine(_ text: String) {
    transcript.append(TranscriptEntry(role: .system, text: text))
  }

  private func fail(_ message: String) {
    lastError = message
    log(message)
  }

  // MARK: Uyandırma kelimesi

  /// Metinde uyandırma kelimesi var mı ve ondan sonra ne söylendi.
  static func extractCommand(from text: String, wakeWord: String) -> (Bool, String) {
    let tokens = normalize(text).split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return (false, "") }
    var wakeSet: Set<String> = ["edith", "edit", "idit", "editt", "eddit", "edid", "edits"]
    let custom = normalize(wakeWord)
    if !custom.isEmpty { wakeSet.insert(custom) }

    guard let index = tokens.lastIndex(where: { wakeSet.contains($0) }) else {
      return (false, "")
    }
    // Komut, orijinal metindeki karşılık gelen kelimelerden alınır (Türkçe karakterler korunur).
    let original = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if original.count == tokens.count {
      return (true, original[(index + 1)...].joined(separator: " "))
    }
    return (true, tokens[(index + 1)...].joined(separator: " "))
  }

  static func normalize(_ text: String) -> String {
    var s = text.lowercased(with: Locale(identifier: "tr_TR"))
    s = s.replacingOccurrences(of: "ı", with: "i")
    s = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    let allowed = s.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
      return " "
    }
    return String(allowed).split(separator: " ").joined(separator: " ")
  }
}

/// Akış halinde gelen metni cümlelere böler.
final class SentenceChunker {
  private var buffer = ""
  private let terminators: Set<Character> = [".", "!", "?", "…", ":", ";"]

  func push(_ text: String) -> [String] {
    buffer += text
    var out: [String] = []
    while let cut = nextCut() {
      let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
      buffer = String(buffer[cut...])
      if sentence.count >= 2 { out.append(sentence) }
    }
    return out
  }

  func flush() -> [String] {
    let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer = ""
    return rest.isEmpty ? [] : [rest]
  }

  private func nextCut() -> String.Index? {
    var index = buffer.startIndex
    while index < buffer.endIndex {
      let ch = buffer[index]
      if ch == "\n" {
        return buffer.index(after: index)
      }
      if terminators.contains(ch) {
        let next = buffer.index(after: index)
        if next < buffer.endIndex, buffer[next].isWhitespace {
          return next
        }
      }
      index = buffer.index(after: index)
    }
    return nil
  }
}
