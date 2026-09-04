import AVFoundation
import Foundation

/// Paylaşılan ses oturumu: mikrofon + hoparlör, Bluetooth kulaklık (gözlük) rotası.
enum AudioSessionManager {
  static func configure() throws {
    let session = AVAudioSession.sharedInstance()
    // voiceChat: yankı bastırma açık; gözlüğün hoparlöründen çıkan sesi mikrofondan ayıklar.
    // allowBluetoothHFP: gözlük mikrofonu ve hoparlörü aynı anda kullanılabilsin.
    try session.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.allowBluetoothHFP, .duckOthers]
    )
    try session.setActive(true)
    log("Ses oturumu aktif. Rota: \(routeDescription())")
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
