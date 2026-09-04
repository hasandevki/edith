import Foundation
import Observation
import os

/// Uygulama içi günlük. Xcode olmadan hata ayıklamak için ekranda gösterilir
/// ve paylaşılabilir. Aynı zamanda os.Logger'a yazar.
@Observable
final class Log: @unchecked Sendable {
  static let shared = Log()

  struct Entry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
  }

  private(set) var entries: [Entry] = []
  private let logger = Logger(subsystem: "com.hasan.edith", category: "app")
  private let maxEntries = 800

  func add(_ text: String) {
    logger.log("\(text, privacy: .public)")
    if Thread.isMainThread {
      append(text)
    } else {
      DispatchQueue.main.async { self.append(text) }
    }
  }

  private func append(_ text: String) {
    entries.append(Entry(time: Date(), text: text))
    if entries.count > maxEntries {
      entries.removeFirst(entries.count - maxEntries)
    }
  }

  func clear() {
    entries.removeAll()
  }

  var exportText: String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return entries.map { "\(f.string(from: $0.time))  \($0.text)" }.joined(separator: "\n")
  }
}

func log(_ text: String) {
  Log.shared.add(text)
}
