import AVFoundation
import Foundation

/// Ham 16-bit PCM parçalarını geldikçe çalar. Uygulamanın ses oturumunu kullanır,
/// yani gözlük bağlıysa gözlükten duyulur.
@MainActor
final class PCMPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format: AVAudioFormat
  private var scheduled = 0
  private var played = 0
  private var finishedFeeding = false
  private var generation = 0
  private var leftover = Data()
  private var continuation: CheckedContinuation<Void, Never>?

  init(sampleRate: Double) {
    format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  /// Yeni bir cümle için hazırla.
  func begin() throws {
    generation += 1
    scheduled = 0
    played = 0
    finishedFeeding = false
    leftover = Data()
    if !engine.isRunning {
      try engine.start()
    }
    if !node.isPlaying {
      node.play()
    }
  }

  /// Gelen ham baytları (16-bit little-endian mono) kuyruğa ekler.
  func feed(_ data: Data) {
    leftover.append(data)
    let usable = leftover.count - leftover.count % 2
    guard usable > 0 else { return }
    let chunk = leftover.prefix(usable)
    leftover = Data(leftover.dropFirst(usable))

    let frames = AVAudioFrameCount(usable / 2)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
      let out = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = frames
    chunk.withUnsafeBytes { raw in
      for i in 0..<Int(frames) {
        let sample = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
        out[i] = Float(Int16(littleEndian: sample)) / 32768
      }
    }

    scheduled += 1
    let myGeneration = generation
    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, myGeneration == self.generation else { return }
        self.played += 1
        self.checkDone()
      }
    }
  }

  /// Besleme bitti; çalınan son parçaya kadar bekler.
  func finishAndWait() async {
    finishedFeeding = true
    if played >= scheduled { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      continuation = c
    }
  }

  func stop() {
    generation += 1
    node.stop()
    scheduled = 0
    played = 0
    finishedFeeding = false
    leftover = Data()
    if let c = continuation {
      continuation = nil
      c.resume()
    }
  }

  private func checkDone() {
    if finishedFeeding, played >= scheduled, let c = continuation {
      continuation = nil
      c.resume()
    }
  }
}
