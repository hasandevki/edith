import AVFoundation
import Foundation
import Speech

/// Mikrofonu sürekli dinler ve Apple konuşma tanımayla (tr-TR) yazıya çevirir.
/// Tanıma görevi belirli aralıklarla yeniden başlatılır (Apple'ın süre sınırı için)
/// ve her yeniden başlatmada metin tamponu sıfırlanır.
@MainActor
final class SpeechListener {
  enum Event {
    case partial(String)
    case final(String)
    case restarted
    case error(String)
  }

  var onEvent: ((Event) -> Void)?
  /// Komut toplanırken otomatik yeniden başlatmayı ertele.
  var holdRestart = false
  private(set) var isRunning = false
  private(set) var usesOnDevice = false

  private let engine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private let requestBox = RequestBox()
  private var task: SFSpeechRecognitionTask?
  private var restartLoop: Task<Void, Never>?
  private var tapInstalled = false
  private var generation = 0
  private var observers: [NSObjectProtocol] = []

  private let restartInterval: TimeInterval = 45

  // MARK: İzinler

  static func requestPermissions() async -> (mic: Bool, speech: Bool) {
    let mic = await AVAudioApplication.requestRecordPermission()
    let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { status in
        c.resume(returning: status == .authorized)
      }
    }
    return (mic, speech)
  }

  // MARK: Başlat / durdur

  func start() throws {
    guard !isRunning else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR")) else {
      throw NSError(domain: "Edith", code: 1, userInfo: [NSLocalizedDescriptionKey: "Türkçe konuşma tanıma bu cihazda yok."])
    }
    self.recognizer = recognizer
    usesOnDevice = recognizer.supportsOnDeviceRecognition
    log("Konuşma tanıma: \(usesOnDevice ? "cihaz üstü" : "sunucu tabanlı") (tr-TR)")

    try installTap()
    try engine.start()
    isRunning = true
    installObservers()
    beginTask()

    restartLoop = Task { [weak self] in
      while let self, !Task.isCancelled, self.isRunning {
        try? await Task.sleep(for: .seconds(self.restartInterval))
        guard !Task.isCancelled, self.isRunning else { break }
        var waited = 0
        while self.holdRestart, waited < 20 {
          try? await Task.sleep(for: .seconds(1))
          waited += 1
        }
        self.restartRecognition()
      }
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    restartLoop?.cancel()
    restartLoop = nil
    endTask()
    engine.stop()
    removeTap()
    removeObservers()
    log("Dinleme durduruldu.")
  }

  /// Mevcut tanıma görevini bitirir ve yenisini başlatır (tampon sıfırlanır).
  func restartRecognition() {
    guard isRunning else { return }
    endTask()
    beginTask()
    onEvent?(.restarted)
  }

  // MARK: Tanıma görevi

  private func beginTask() {
    guard let recognizer else { return }
    generation += 1
    let myGeneration = generation

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if #available(iOS 16, *) {
      request.addsPunctuation = false
    }
    if usesOnDevice {
      request.requiresOnDeviceRecognition = true
    }
    requestBox.set(request)

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor [weak self] in
        guard let self, myGeneration == self.generation else { return }
        if let result {
          let text = result.bestTranscription.formattedString
          if result.isFinal {
            self.onEvent?(.final(text))
          } else {
            self.onEvent?(.partial(text))
          }
        }
        if let error {
          let ns = error as NSError
          // 1110: konuşma algılanmadı, 216/301: iptal — bunlar normal.
          let benign = [1110, 216, 301].contains(ns.code)
          if !benign {
            log("Tanıma hatası (\(ns.domain) \(ns.code)): \(ns.localizedDescription)")
            self.onEvent?(.error(ns.localizedDescription))
          }
          if self.isRunning, myGeneration == self.generation {
            // Kısa bekleyip yeni görev başlat; sıkı döngüyü önler.
            try? await Task.sleep(for: .milliseconds(400))
            guard self.isRunning, myGeneration == self.generation else { return }
            self.endTask()
            self.beginTask()
            self.onEvent?(.restarted)
          }
        } else if let result, result.isFinal, self.isRunning, myGeneration == self.generation {
          self.endTask()
          self.beginTask()
          self.onEvent?(.restarted)
        }
      }
    }
  }

  private func endTask() {
    requestBox.current?.endAudio()
    requestBox.set(nil)
    task?.cancel()
    task = nil
  }

  // MARK: Mikrofon tap'i

  private func installTap() throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "Edith", code: 2, userInfo: [NSLocalizedDescriptionKey: "Kullanılabilir mikrofon yok (format 0)."])
    }
    let box = requestBox
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      box.current?.append(buffer)
    }
    tapInstalled = true
    log("Mikrofon tap'i kuruldu: \(Int(format.sampleRate)) Hz, \(format.channelCount) kanal. Rota: \(AudioSessionManager.routeDescription())")
  }

  private func removeTap() {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
  }

  /// Rota değişince (gözlük bağlanınca/kopunca) giriş formatı değişir; tap'i yeniden kur.
  private func reconfigure() {
    guard isRunning else { return }
    log("Ses yapılandırması değişti, mikrofon yeniden kuruluyor. Rota: \(AudioSessionManager.routeDescription())")
    endTask()
    engine.stop()
    removeTap()
    do {
      try AudioSessionManager.configure()
      try installTap()
      try engine.start()
      beginTask()
      onEvent?(.restarted)
    } catch {
      log("Yeniden kurulum hatası: \(error.localizedDescription)")
      onEvent?(.error(error.localizedDescription))
    }
  }

  private func installObservers() {
    removeObservers()
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.reconfigure() }
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
      Task { @MainActor in
        guard let self else { return }
        log("Ses rotası değişti (\(reason.map { String(describing: $0) } ?? "?")): \(AudioSessionManager.routeDescription())")
        if !self.engine.isRunning { self.reconfigure() }
      }
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }
      Task { @MainActor in
        guard let self else { return }
        switch type {
        case .began:
          log("Ses kesintisi başladı (arama vb.).")
        case .ended:
          log("Ses kesintisi bitti, dinleme yeniden kuruluyor.")
          self.reconfigure()
        @unknown default:
          break
        }
      }
    })
  }

  private func removeObservers() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }
}

/// Ses iş parçacığından güvenli erişim için istek kutusu.
final class RequestBox: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?

  var current: SFSpeechAudioBufferRecognitionRequest? {
    lock.lock()
    defer { lock.unlock() }
    return request
  }

  func set(_ new: SFSpeechAudioBufferRecognitionRequest?) {
    lock.lock()
    request = new
    lock.unlock()
  }
}
