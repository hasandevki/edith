import AVFoundation
import Foundation

/// Kısa geri bildirim sesleri: uyandı, gönderildi, vazgeçti.
/// Uygulamanın ses oturumu üzerinden çalar; gözlük bağlıysa gözlükten duyulur.
@MainActor
final class Chime {
  static let shared = Chime()

  enum Kind {
    case wake    // "Edith" duyuldu, seni dinliyor
    case sent    // soru Claude'a gitti
    case cancel  // komut gelmedi, dinlemeye döndü
  }

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format: AVAudioFormat
  private var buffers: [Kind: AVAudioPCMBuffer] = [:]

  private init() {
    format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    buffers[.wake] = Self.tone(notes: [(880, 0.09), (1318.5, 0.16)], gain: 0.35, format: format)
    buffers[.sent] = Self.tone(notes: [(1046.5, 0.08)], gain: 0.25, format: format)
    buffers[.cancel] = Self.tone(notes: [(659.3, 0.09), (440, 0.16)], gain: 0.3, format: format)
  }

  func play(_ kind: Kind) {
    guard let buffer = buffers[kind] else { return }
    do {
      if !engine.isRunning {
        try engine.start()
      }
      player.stop()
      player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
      player.play()
    } catch {
      log("Ses ipucu çalınamadı: \(error.localizedDescription)")
    }
  }

  /// Ardışık sinüs notalarından yumuşak zarflı kısa bir ses üretir.
  private static func tone(notes: [(Double, Double)], gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    let sampleRate = format.sampleRate
    let totalSeconds = notes.reduce(0.0) { $0 + $1.1 }
    let frames = AVAudioFrameCount(totalSeconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let data = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = frames

    var index = 0
    for (frequency, duration) in notes {
      let count = Int(duration * sampleRate)
      let attack = 0.01 * sampleRate
      let release = 0.03 * sampleRate
      for i in 0..<count where index < Int(frames) {
        let t = Double(i) / sampleRate
        let envelope = min(1.0, Double(i) / attack, Double(count - i) / release)
        data[index] = Float(sin(2 * Double.pi * frequency * t)) * gain * Float(max(0, envelope))
        index += 1
      }
    }
    return buffer
  }
}
