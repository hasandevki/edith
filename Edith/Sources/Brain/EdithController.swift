import Foundation
import Observation
import UIKit

/// Edith'in beyni ve durum makinesi:
/// dinle → "Edith" duy → komutu topla → gör → düşün (gerekirse araç kullan) → konuş → dinle.
@Observable
@MainActor
final class EdithController {
  enum State: String {
    case idle = "Uykuda"
    case listening = "Dinliyor"
    case followUp = "Devam edebilirsin"
    case capturing = "Seni dinliyorum..."
    case thinking = "Düşünüyor"
    case speaking = "Konuşuyor"
  }

  enum TranslationDirection {
    case toTarget    // Türkçe → hedef dil
    case fromTarget  // hedef dil → Türkçe
  }

  struct TranscriptEntry: Identifiable {
    enum Role { case user, edith, system }
    let id = UUID()
    let role: Role
    let text: String
    var costUSD: Double? = nil
    let time = Date()
  }

  private(set) var state: State = .idle
  private(set) var transcript: [TranscriptEntry] = []
  private(set) var lastHeard = ""
  private(set) var isListeningActive = false
  private(set) var translationMode = false
  private(set) var translationDirection: TranslationDirection = .toTarget
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
  @ObservationIgnored private var followUpUntil = Date.distantPast
  /// Model → çalışan web araması sürümü (nil = bu model aramayı desteklemiyor). Her soruda yeniden denenmesin diye.
  @ObservationIgnored private var searchVariantByModel: [String: String?] = [:]
  /// Web aramasının konum bilgisinde kabul etmediği ülke kodları (örn. MK).
  @ObservationIgnored private var searchRejectedCountries: Set<String> = []

  private let commandSilence: TimeInterval = 1.3
  private let promptAfter: TimeInterval = 2.5
  private let giveUpAfter: TimeInterval = 10

  init(glasses: GlassesManager) {
    self.glasses = glasses
    speaker.onFinishedAll = { [weak self] in
      guard let self, self.state == .speaking else { return }
      self.finishedSpeaking()
    }
    speech.onEvent = { [weak self] event in
      self?.handleSpeech(event)
    }
    TimerService.shared.onFire = { [weak self] label in
      self?.timerFired(label)
    }
    SceneMemory.shared.start(glasses: glasses)
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
    state = translationMode ? .followUp : .listening
    if translationMode { followUpUntil = .distantFuture }
    log("Dinleme başladı. Uyandırma kelimesi: \(Settings.shared.wakeWord)")
    LocationService.shared.start()
    await TimerService.shared.requestPermission()
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

  /// Uyandırma kelimesi olmadan, elle komut toplamaya başla (Action Button, Siri, buton).
  func beginManualCapture() {
    guard isListeningActive else { return }
    if state == .speaking || state == .thinking {
      requestTask?.cancel()
      speaker.stop()
    }
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

  // MARK: Çeviri modu

  func setTranslation(enabled: Bool) {
    guard enabled != translationMode else { return }
    translationMode = enabled
    requestTask?.cancel()
    speaker.stop()
    commandText = ""
    speech.holdRestart = false
    if enabled {
      translationDirection = .toTarget
      speech.setLocale("tr-TR")
      let target = Settings.translationLabel(Settings.shared.translationTarget)
      addSystemLine("Çeviri modu açık: Türkçe → \(target)")
      speakAndLog("Çeviri modu açık. Konuş, \(target) söyleyeyim. Karşı taraf konuşacaksa ekrandan yönü değiştir.")
    } else {
      speech.setLocale("tr-TR")
      followUpUntil = .distantPast
      addSystemLine("Çeviri modu kapandı.")
      speakAndLog("Çeviri modu kapandı.")
    }
  }

  func setTranslationDirection(_ direction: TranslationDirection) {
    guard translationMode else { return }
    translationDirection = direction
    commandText = ""
    speech.setLocale(direction == .fromTarget ? Settings.shared.translationTarget : "tr-TR")
    if isListeningActive, state != .speaking, state != .thinking {
      state = .followUp
      followUpUntil = .distantFuture
    }
  }

  // MARK: Konuşma tanıma olayları

  private func handleSpeech(_ event: SpeechListener.Event) {
    switch event {
    case .partial(let text), .final(let text):
      lastHeard = text
      guard Date() >= ignoreSpeechUntil else { return }
      let (heardWake, command) = Self.extractCommand(from: text, wakeWords: Self.wakeVariants(settings: Settings.shared))

      if translationMode {
        handleTranslationSpeech(text: text, heardWake: heardWake, command: command, isFinal: { if case .final = event { return true }; return false }())
        return
      }

      switch state {
      case .listening, .idle:
        if heardWake { enterCapturing(initialCommand: command) }
      case .followUp:
        // Devam penceresi: uyandırma kelimesi şart değil.
        let spoken = heardWake ? command : text.trimmingCharacters(in: .whitespacesAndNewlines)
        if heardWake || spoken.count >= 2 {
          enterCapturing(initialCommand: spoken, chime: heardWake)
        }
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

  private func handleTranslationSpeech(text: String, heardWake: Bool, command: String, isFinal: Bool) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if heardWake, translationDirection == .toTarget {
      let n = Self.normalize(command)
      if n.contains("kapat") || n.contains("bitir") {
        setTranslation(enabled: false)
        speech.restartRecognition()
        return
      }
    }
    switch state {
    case .listening, .followUp, .idle:
      if trimmed.count >= 2 { enterCapturing(initialCommand: trimmed, chime: false) }
    case .capturing:
      if trimmed != commandText {
        commandText = trimmed
        commandLastChange = Date()
      }
    case .thinking, .speaking:
      break
    }
    if isFinal, state == .capturing, !commandText.isEmpty {
      finalize(command: commandText)
    }
  }

  private func enterCapturing(initialCommand: String, chime: Bool = true) {
    state = .capturing
    commandText = initialCommand
    commandLastChange = Date()
    wakeTime = Date()
    promptedForCommand = false
    speech.holdRestart = true
    if chime {
      Chime.shared.play(.wake)
      log("Uyandırma kelimesi duyuldu. Komut: \"\(initialCommand)\"")
    } else {
      log("Konuşma yakalandı: \"\(initialCommand)\"")
    }
  }

  private func tick() {
    if state == .followUp, Date() >= followUpUntil {
      state = .listening
      log("Devam penceresi kapandı, uyandırma kelimesi bekleniyor.")
      return
    }
    guard state == .capturing else { return }
    let now = Date()
    if !commandText.isEmpty {
      if now.timeIntervalSince(commandLastChange) >= commandSilence {
        finalize(command: commandText)
      }
      return
    }
    if translationMode {
      if now.timeIntervalSince(wakeTime) >= giveUpAfter {
        state = .followUp
        followUpUntil = .distantFuture
        speech.holdRestart = false
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
      Chime.shared.play(.cancel)
      state = .listening
    }
  }

  private func finalize(command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    speech.holdRestart = false
    if isListeningActive { speech.restartRecognition() }
    commandText = ""
    if isListeningActive { Chime.shared.play(.sent) }
    transcript.append(TranscriptEntry(role: .user, text: trimmed))
    requestTask?.cancel()

    if translationMode {
      state = .thinking
      requestTask = Task { [weak self] in await self?.runTranslation(trimmed) }
      return
    }
    if handleLocalCommand(trimmed) {
      return
    }
    state = .thinking
    requestTask = Task { [weak self] in await self?.ask(trimmed) }
  }

  /// Claude'a gitmeden yerelde çözülen komutlar (çeviri modu aç/kapat).
  private func handleLocalCommand(_ command: String) -> Bool {
    let n = Self.normalize(command)
    guard n.contains("ceviri") else { return false }
    let tokens = Set(n.split(separator: " ").map(String.init))
    let close = tokens.contains("kapat") || tokens.contains("bitir") || tokens.contains("kapa") || tokens.contains("dur")
    let open = tokens.contains("ac") || tokens.contains("acalim") || tokens.contains("baslat") || tokens.contains("gec") || tokens.contains("gecelim") || n.contains("ceviri modu")
    if close {
      setTranslation(enabled: false)
      return true
    }
    if open {
      setTranslation(enabled: true)
      return true
    }
    return false
  }

  /// Edith sustu: çeviri modunda dinlemeye devam; normalde ayar açıksa devam penceresi.
  private func finishedSpeaking() {
    guard isListeningActive else {
      state = .idle
      return
    }
    if translationMode {
      speech.restartRecognition()
      ignoreSpeechUntil = Date().addingTimeInterval(0.5)
      followUpUntil = .distantFuture
      state = .followUp
      return
    }
    let seconds = Settings.shared.followUpSeconds
    guard seconds > 0 else {
      state = .listening
      return
    }
    speech.restartRecognition()
    ignoreSpeechUntil = Date().addingTimeInterval(0.5)
    followUpUntil = Date().addingTimeInterval(TimeInterval(seconds))
    state = .followUp
  }

  private func timerFired(_ label: String) {
    Chime.shared.play(.wake)
    addSystemLine("Süre doldu: \(label)")
    if state == .capturing || state == .thinking {
      requestTask?.cancel()
    }
    state = .speaking
    speaker.speak("Süre doldu: \(label).")
  }

  // MARK: Claude (araç döngüsüyle)

  private func ask(_ command: String) async {
    let settings = Settings.shared
    guard !settings.apiKey.isEmpty else {
      speakAndLog("Önce ayarlardan API anahtarını girmen lazım.")
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
    let context = image == nil
      ? "(Bu mesajda görüntü yok; gözler kapalı ya da bağlı değil.)"
      : "(Ekli görüntü şu anki bakış açımı gösteriyor.)"
    conversation.appendUser(text: "\(command)\n\(context)", image: image)
    log("Claude'a gidiyor: \"\(command)\" \(image == nil ? "görüntüsüz" : "görüntülü, \(image!.count / 1024) KB")")

    var messages = conversation.apiMessages()
    let localTools = Tools.definitions()
    var searchVariant: String? = settings.webSearchEnabled ? "web_search_20260209" : nil
    if settings.webSearchEnabled, let known = searchVariantByModel[settings.model] {
      searchVariant = known
    }
    let chunker = SentenceChunker()
    var spoken = ""
    var totalUsage = ClaudeClient.Usage()
    let started = Date()
    var firstTokenAt: Date?
    var iterations = 0

    do {
      while iterations < 6 {
        iterations += 1
        var toolCalls: [ClaudeClient.ToolUse] = []
        var stop = ""
        var blocks: [[String: Any]] = []
        var toolList = localTools
        if let variant = searchVariant {
          toolList.append(Tools.webSearchDefinition(variant: variant, rejectedCountries: searchRejectedCountries))
        }
        let request = ClaudeClient.Request(
          apiKey: settings.apiKey,
          model: settings.model,
          effort: settings.effort,
          system: Conversation.systemBlocks(settings: settings),
          messages: messages,
          tools: toolList,
          maxTokens: 1024
        )
        do {
          for try await event in ClaudeClient.stream(request) {
            if Task.isCancelled { break }
            switch event {
            case .modelUsed(let model):
              if iterations == 1 { log("Model: \(model)") }
            case .text(let text):
              if firstTokenAt == nil {
                firstTokenAt = Date()
                log("İlk kelime \(String(format: "%.1f", Date().timeIntervalSince(started))) sn sonra.")
              }
              spoken += text
              for sentence in chunker.push(text) {
                state = .speaking
                speaker.speak(sentence)
              }
            case .toolUse(let call):
              toolCalls.append(call)
            case .stopReason(let reason):
              stop = reason
            case .usage(let usage):
              totalUsage.add(usage)
            case .assistantBlocks(let list):
              blocks = list
            case .done:
              break
            }
          }
        } catch let error as ClaudeClient.APIError
          where error.status == 400 && searchVariant != nil && error.message.lowercased().contains("web_search")
        {
          let lower = error.message.lowercased()
          if lower.contains("user_location") || lower.contains("country") {
            // Konum bilgisindeki ülke kabul edilmiyor: aynı sürümü konumsuz dene.
            let country = (LocationService.shared.placemark?.isoCountryCode ?? "").uppercased()
            if !country.isEmpty, !searchRejectedCountries.contains(country) {
              searchRejectedCountries.insert(country)
              log("Web araması: \(country) ülke kodu kabul edilmiyor, arama konumsuz gönderilecek. (\(error.message))")
              iterations -= 1
              continue
            }
          }
          // Bu model bu arama sürümünü desteklemiyor: eski sürümü dene, o da olmazsa aramasız devam et.
          if searchVariant == "web_search_20260209" {
            searchVariant = "web_search_20250305"
            log("Web araması eski sürüme düşürüldü (\(settings.model)): \(error.message)")
          } else {
            searchVariant = nil
            log("Web araması bu modelde kapatıldı (\(settings.model)): \(error.message)")
          }
          searchVariantByModel[settings.model] = searchVariant
          iterations -= 1
          continue
        }

        if Task.isCancelled {
          conversation.dropUnansweredUser()
          return
        }

        if stop == "tool_use", !toolCalls.isEmpty {
          if !blocks.isEmpty {
            messages.append(["role": "assistant", "content": blocks])
          }
          var results: [[String: Any]] = []
          for call in toolCalls {
            let (text, isError) = await Tools.run(call)
            log("Araç sonucu (\(call.name)): \(text.prefix(200))")
            results.append(["type": "tool_result", "tool_use_id": call.id, "content": text, "is_error": isError])
          }
          messages.append(["role": "user", "content": results])
          continue
        }
        if stop == "pause_turn", !blocks.isEmpty {
          messages.append(["role": "assistant", "content": blocks])
          continue
        }
        break
      }

      for sentence in chunker.flush() {
        state = .speaking
        speaker.speak(sentence)
      }
      let finalText = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
      if finalText.isEmpty {
        conversation.dropUnansweredUser()
        speakAndLog("Bir cevap üretemedim, tekrar sorar mısın?")
      } else {
        conversation.appendAssistant(text: finalText)
        let cost = UsageTracker.shared.recordAnswer(model: settings.model, usage: totalUsage)
        transcript.append(TranscriptEntry(role: .edith, text: finalText, costUSD: cost))
        log("Cevap tamam: \(finalText.count) karakter, \(String(format: "%.1f", Date().timeIntervalSince(started))) sn, \(UsageTracker.formatUSD(cost)), arama \(totalUsage.searches), tur \(iterations).")
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

  // MARK: Çeviri

  private func runTranslation(_ text: String) async {
    let settings = Settings.shared
    guard !settings.apiKey.isEmpty else {
      speakAndLog("Önce ayarlardan API anahtarını girmen lazım.")
      return
    }
    let target = settings.translationTarget
    let targetLabel = Settings.translationLabel(target)
    let source = translationDirection == .toTarget ? "Türkçe" : targetLabel
    let destination = translationDirection == .toTarget ? targetLabel : "Türkçe"
    let speakLanguage = translationDirection == .toTarget ? target : "tr-TR"
    let system = "Sen simultane çevirmensin. Verilen konuşmayı \(source) dilinden \(destination) diline çevir. Sadece çeviriyi yaz; açıklama, tırnak, ek yorum, ön ek yok. Konuşma dilinde, doğal ve kısa tut. Anlaşılmayan bir kısım varsa en olası anlamı ver."
    let request = ClaudeClient.Request(
      apiKey: settings.apiKey,
      model: settings.model,
      effort: "low",
      system: [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
      messages: [["role": "user", "content": text]],
      maxTokens: 400
    )
    let chunker = SentenceChunker()
    var full = ""
    var usage = ClaudeClient.Usage()
    do {
      for try await event in ClaudeClient.stream(request) {
        if Task.isCancelled { return }
        switch event {
        case .text(let t):
          full += t
          for sentence in chunker.push(t) {
            state = .speaking
            speaker.speak(sentence, language: speakLanguage)
          }
        case .usage(let u):
          usage = u
        default:
          break
        }
      }
      for sentence in chunker.flush() {
        state = .speaking
        speaker.speak(sentence, language: speakLanguage)
      }
      let cost = UsageTracker.shared.recordAnswer(model: settings.model, usage: usage)
      transcript.append(TranscriptEntry(role: .edith, text: full.trimmingCharacters(in: .whitespacesAndNewlines), costUSD: cost))
    } catch is CancellationError {
      return
    } catch {
      lastError = error.localizedDescription
      log("Çeviri hatası: \(error.localizedDescription)")
      speakAndLog("Çeviri yapılamadı.")
    }
    if !speaker.isSpeaking {
      state = .followUp
      followUpUntil = .distantFuture
    } else {
      state = .speaking
    }
  }

  // MARK: Yardımcılar

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

  /// Ayarlardaki isim ve uyandırma kelimesi için, konuşma tanımanın yazabileceği varyantlar.
  static func wakeVariants(settings: Settings) -> Set<String> {
    var set: Set<String> = []
    for word in [settings.wakeWord, settings.assistantName] {
      let n = normalize(word)
      guard !n.isEmpty else { continue }
      set.insert(n)
      switch n {
      case "edith", "edit":
        set.formUnion(["edith", "edit", "idit", "editt", "eddit", "edid", "edits"])
      case "jarvis", "carvis":
        set.formUnion(["jarvis", "carvis", "carviz", "jarviz", "charvis", "jarwis", "carwis", "cervis", "jarvi", "carvi", "jarvs", "carvs"])
      default:
        break
      }
    }
    return set
  }

  /// Kelime bir varyanta eşitse ya da varyant + kısa Türkçe ek ise ("carvise", "edithim") eşleşir.
  static func matchesWake(_ token: String, _ wakeWords: Set<String>) -> Bool {
    if wakeWords.contains(token) { return true }
    for word in wakeWords where word.count >= 4 && token.hasPrefix(word) && token.count - word.count <= 3 {
      return true
    }
    return false
  }

  static func extractCommand(from text: String, wakeWords: Set<String>) -> (Bool, String) {
    let tokens = normalize(text).split(separator: " ").map(String.init)
    guard !tokens.isEmpty else { return (false, "") }

    guard let index = tokens.lastIndex(where: { matchesWake($0, wakeWords) }) else {
      return (false, "")
    }
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
