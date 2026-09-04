import Foundation
import MWDATCamera
import MWDATCore
import Observation
import UIKit

/// Ray-Ban Meta gözlüğüyle ilişkiyi yönetir: Meta AI üzerinden kayıt,
/// cihaz takibi, oturum, kamera akışı ve "o an görülen kare".
@Observable
@MainActor
final class GlassesManager {
  // MARK: Durum (arayüz bunlara bağlanır)

  var registrationState: RegistrationState
  var devices: [DeviceIdentifier] = []
  var hasActiveDevice = false
  var sessionState: DeviceSessionState = .idle
  var streamState: StreamState = .stopped
  var latestFrame: UIImage?
  var lastFrameAt: Date?
  var frameCount = 0
  var lastError: String?
  var requiresFirmwareUpdate = false
  var needsGlassesAppUpdate = false
  /// Kullanıcı "gözler açık" istiyor mu (yeniden bağlanma için hatırlanır).
  var eyesWanted = false

  var isRegistered: Bool { registrationState == .registered }
  var isStreaming: Bool { streamState == .streaming }
  var hasSession: Bool {
    switch sessionState {
    case .starting, .started, .paused, .stopping: return true
    case .idle, .stopped: return false
    }
  }

  var streamStateText: String {
    switch streamState {
    case .streaming: return "akışta"
    case .starting: return "başlıyor"
    case .waitingForDevice: return "cihaz bekleniyor"
    case .stopping: return "duruyor"
    case .stopped: return "kapalı"
    case .paused: return "duraklatıldı"
    }
  }

  var sessionStateText: String { sessionState.description }
  var registrationText: String { "\(registrationState)" }

  // MARK: Özel

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let selector: AutoDeviceSelector
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored private let decoder = VideoFrameDecoder()
  @ObservationIgnored private let sessionTokens = ListenerTokenBag()
  @ObservationIgnored private let streamTokens = ListenerTokenBag()
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var photoContinuation: CheckedContinuation<Data?, Never>?
  @ObservationIgnored private var retryTask: Task<Void, Never>?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.selector = AutoDeviceSelector(wearables: wearables)
    self.registrationState = wearables.registrationState
    self.devices = wearables.devices

    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await state in wearables.registrationStateStream() {
        self.registrationState = state
        log("Kayıt durumu: \(state)")
      }
    })
    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await devices in wearables.devicesStream() {
        self.devices = devices
        self.checkCompatibility(devices)
        log("Cihazlar: \(devices.count)")
      }
    })
    tasks.append(Task { [weak self] in
      guard let self else { return }
      for await deviceId in self.selector.activeDeviceStream() {
        let active = deviceId != nil
        if active != self.hasActiveDevice {
          log(active ? "Gözlük aktif." : "Gözlük aktif değil (takılı değil / kapalı / uzak).")
        }
        self.hasActiveDevice = active
        if active, self.eyesWanted, !self.hasSession {
          await self.eyesOn()
        }
      }
    })
  }

  // MARK: Kayıt (Meta AI uygulaması üzerinden)

  func connect() async {
    guard registrationState != .registering else { return }
    do {
      log("Meta AI ile kayıt başlatılıyor...")
      try await wearables.startRegistration()
    } catch let error as RegistrationError {
      fail("Kayıt hatası: \(error.description)")
    } catch {
      fail("Kayıt hatası: \(error.localizedDescription)")
    }
  }

  func disconnect() async {
    eyesOff()
    do {
      try await wearables.startUnregistration()
    } catch let error as UnregistrationError {
      fail("Kayıt silme hatası: \(error.description)")
    } catch {
      fail("Kayıt silme hatası: \(error.localizedDescription)")
    }
  }

  /// Meta AI uygulamasından dönen geri çağırma URL'si.
  func handle(url: URL) async {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else {
      log("İlgisiz URL yok sayıldı: \(url)")
      return
    }
    do {
      _ = try await Wearables.shared.handleUrl(url)
      log("Meta AI geri çağırması işlendi.")
    } catch let error as RegistrationError {
      fail("Geri çağırma hatası: \(error.description)")
    } catch {
      fail("Geri çağırma hatası: \(error.localizedDescription)")
    }
  }

  func openFirmwareUpdate() async {
    do { try await wearables.openFirmwareUpdate() } catch { fail("Firmware güncelleme açılamadı: \(error)") }
  }

  func openGlassesAppUpdate() async {
    do { try await wearables.openDATGlassesAppUpdate() } catch { fail("Gözlük uygulaması güncellemesi açılamadı: \(error)") }
  }

  // MARK: Gözler (oturum + kamera akışı)

  /// Oturumu başlatır; oturum `.started` olunca akış otomatik açılır.
  func eyesOn() async {
    eyesWanted = true
    guard isRegistered else {
      fail("Önce gözlüğü bağla (Meta AI kaydı).")
      return
    }
    if hasSession {
      if session?.state == .started, camera == nil {
        await startStream()
      }
      return
    }
    do {
      let newSession = try wearables.createSession(deviceSelector: selector)
      session = newSession
      observe(newSession)
      sessionState = .starting
      try newSession.start()
      log("Oturum başlatıldı.")
    } catch {
      fail("Oturum başlatılamadı: \(error.localizedDescription)")
      sessionState = .idle
      cleanupSession()
    }
  }

  func eyesOff() {
    eyesWanted = false
    retryTask?.cancel()
    retryTask = nil
    if let camera {
      streamState = .stopping
      camera.stop()
    }
    if let session {
      sessionState = .stopping
      session.stop()
      log("Oturum kapatılıyor.")
    }
  }

  /// Akışı duraklat/devam ettir (gözlük sapına dokunmakla aynı etki).
  func pauseStreamIfPossible() {
    guard let camera else { return }
    camera.stop()
  }

  private func startStream() async {
    guard let session, session.state == .started, camera == nil else { return }
    do {
      var status = try await wearables.checkPermissionStatus(.camera)
      if status != .granted {
        log("Kamera izni yok, Meta AI'a yönlendiriliyor...")
        status = try await wearables.requestPermission(.camera)
      }
      guard status == .granted else {
        fail("Kamera izni verilmedi.")
        return
      }
    } catch {
      fail("Kamera izni kontrolü: \(error.localizedDescription)")
      return
    }

    // hvc1: arka planda da akmaya devam eder (raw kodek arka planda durur).
    let config = StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.medium,
      frameRate: 7
    )
    do {
      guard let newCamera = try session.addCamera(config: config) else {
        fail("Kamera oluşturulamadı.")
        return
      }
      camera = newCamera
      observe(newCamera.stream)
      streamState = .starting
      newCamera.stream.start()
      log("Kamera akışı başlatılıyor (medium, 7 fps, hvc1).")
    } catch {
      camera = nil
      fail("Kamera eklenemedi: \(error.localizedDescription)")
    }
  }

  // MARK: Kare erişimi

  /// Son kareyi (uzun kenar en fazla `maxDimension` piksel) JPEG olarak verir.
  /// Akış karesi zaten 504x896; bu yüzden genelde yeniden boyutlanmaz, sadece sıkıştırılır.
  func currentFrameJPEG(maxDimension: CGFloat = 896, quality: CGFloat = 0.6) -> Data? {
    guard let image = latestFrame else { return nil }
    if let lastFrameAt, Date().timeIntervalSince(lastFrameAt) > 10 {
      log("Uyarı: son kare \(Int(Date().timeIntervalSince(lastFrameAt))) sn eski.")
    }
    return Self.resizedJPEG(image: image, maxDimension: maxDimension, quality: quality)
  }

  /// Gözlükten tam çözünürlüklü fotoğraf ister, gelince uzun kenarı 1568 piksele indirir
  /// (Claude'un görüntüyü işlediği üst sınır; daha büyüğü sadece bant genişliği yakar).
  /// `timeout` içinde gelmezse nil; çağıran akış karesine düşer.
  func captureHiResJPEG(timeout: TimeInterval = 3.0) async -> Data? {
    guard let camera, isStreaming else { return nil }
    if photoContinuation != nil { return nil }
    let ok = camera.stream.capturePhoto(format: .jpeg)
    guard ok else {
      log("capturePhoto reddedildi.")
      return nil
    }
    let raw: Data? = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
      photoContinuation = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(timeout))
        guard let self, let pending = self.photoContinuation else { return }
        self.photoContinuation = nil
        log("Fotoğraf zaman aşımı, akış karesi kullanılacak.")
        pending.resume(returning: nil)
      }
    }
    guard let raw, let image = UIImage(data: raw) else { return nil }
    let resized = Self.resizedJPEG(image: image, maxDimension: 1568, quality: 0.7)
    if let resized {
      log("Fotoğraf küçültüldü: \(raw.count / 1024) KB → \(resized.count / 1024) KB")
    }
    return resized
  }

  /// Uzun kenarı `maxDimension`'a indirip JPEG'e sıkıştırır. Büyütmez.
  static func resizedJPEG(image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
    let size = image.size
    let longest = max(size.width, size.height)
    guard longest > 0 else { return nil }
    let scale = min(1, maxDimension / longest)
    if scale >= 1 {
      return image.jpegData(compressionQuality: quality)
    }
    let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    return resized.jpegData(compressionQuality: quality)
  }

  // MARK: Gözlem

  private func observe(_ session: DeviceSession) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleSessionState(state) }
    }.store(in: sessionTokens)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleSessionError(error) }
    }.store(in: sessionTokens)
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    sessionState = state
    log("Oturum: \(state.description)")
    switch state {
    case .started:
      if eyesWanted, camera == nil {
        Task { await startStream() }
      }
    case .stopped:
      cleanupSession()
      scheduleRetryIfWanted()
    default:
      break
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    if case .datAppOnTheGlassesUpdateRequired = error {
      needsGlassesAppUpdate = true
    }
    fail("Oturum hatası: \(error.localizedDescription)")
  }

  private func observe(_ stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStreamState(state) }
    }.store(in: streamTokens)

    stream.videoFramePublisher.listen { [weak self] frame in
      guard let self else { return }
      // Ana aktör dışında çözümle; sadece sonucu ana aktöre taşı.
      let image = self.decoder.decode(frame.sampleBuffer)
      Task { @MainActor [weak self] in
        guard let self, let image else { return }
        self.latestFrame = image
        self.lastFrameAt = Date()
        self.frameCount += 1
        if self.frameCount == 1 { log("İlk kare geldi: \(Int(image.size.width))x\(Int(image.size.height))") }
      }
    }.store(in: streamTokens)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.fail("Akış hatası: \(error.localizedDescription)") }
    }.store(in: streamTokens)

    stream.photoDataPublisher.listen { [weak self] photo in
      Task { @MainActor in self?.handlePhoto(photo) }
    }.store(in: streamTokens)
  }

  private func handleStreamState(_ state: StreamState) {
    streamState = state
    log("Akış: \(streamStateText)")
    if state == .stopped {
      streamTokens.clear()
      camera?.stop()
      camera = nil
      frameCount = 0
    }
  }

  private func handlePhoto(_ photo: PhotoData) {
    log("Fotoğraf geldi: \(photo.data.count / 1024) KB")
    if let pending = photoContinuation {
      photoContinuation = nil
      pending.resume(returning: photo.data)
    }
  }

  private func cleanupSession() {
    sessionTokens.clear()
    session = nil
    camera = nil
  }

  /// Oturum beklenmedik şekilde kapanırsa (gözlük uyudu, menteşe kapandı, ısı/pil koruması)
  /// gözlük tekrar aktif olduğu sürece artan aralıklarla yeniden dener.
  /// SDK kendi başına yeniden bağlanmaz; bu döngü olmadan "gözler" bir kez kapanınca kapalı kalır.
  private func scheduleRetryIfWanted() {
    guard eyesWanted else { return }
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      let delays: [Int] = [4, 6, 10, 15, 20, 30, 30, 30]
      for (attempt, delay) in delays.enumerated() {
        try? await Task.sleep(for: .seconds(delay))
        guard let self, !Task.isCancelled, self.eyesWanted else { return }
        if self.hasSession { return }
        guard self.hasActiveDevice else {
          log("Yeniden bağlanma \(attempt + 1): gözlük aktif değil, bekleniyor.")
          continue
        }
        log("Yeniden bağlanma \(attempt + 1): oturum açılıyor.")
        await self.eyesOn()
      }
      log("Yeniden bağlanma denemeleri bitti; gözlük aktif olunca otomatik denenecek.")
    }
  }

  private func checkCompatibility(_ devices: [DeviceIdentifier]) {
    var needsUpdate = false
    for id in devices {
      if let device = wearables.deviceForIdentifier(id), device.compatibility() == .deviceUpdateRequired {
        needsUpdate = true
      }
    }
    requiresFirmwareUpdate = needsUpdate
  }

  private func fail(_ message: String) {
    lastError = message
    log(message)
  }
}
