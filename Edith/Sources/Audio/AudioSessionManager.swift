import AVFoundation
import Foundation

/// Paylaşılan ses oturumu.
/// Normal mod: gözlük mikrofonu + hoparlörü (Bluetooth HFP, telefon görüşmesi kalitesi).
/// Müzik modu: çıkış gözlükten yüksek kalite (A2DP), mikrofon telefondan; Spotify bozulmasın diye.
enum AudioSessionManager {
  private(set) static var musicMode = false

  static func configure() throws {
    try configure(musicMode: musicMode)
  }

  static func configure(musicMode enabled: Bool) throws {
    musicMode = enabled
    let session = AVAudioSession.sharedInstance()
    if enabled, Settings.shared.musicMic == "phone" {
      // Çıkış gözlükten yüksek kalite (A2DP), mikrofon telefondan. Hoparlöre yönlendirme YOK.
      try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .mixWithOthers])
    } else {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .duckOthers])
    }
    try session.setActive(true)
    log("Ses oturumu aktif (\(enabled ? "müzik modu" : "normal")). Rota: \(routeDescription())")
  }

  static func deactivate() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  static func routeDescription() -> String {
    let route = AVAudioSession.sharedInstance().currentRoute
    let inputs = route.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    let outputs = route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    return "giriş: \(inputs.isEmpty ? "yok" : inputs) | çıkış: \(outputs.isEmpty ? "yok" : outputs)"
  }

  static var isBluetoothInput: Bool {
    AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
  }
}
