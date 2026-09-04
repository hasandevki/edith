import Foundation
import Observation

/// Kalıcı hafıza: kullanıcının "hatırla" dedikleri ve gözlüğün gördüğü sahne notları.
/// Belgeler klasöründe JSON olarak saklanır; uygulama silinmedikçe kalır.
@Observable
@MainActor
final class MemoryStore {
  static let shared = MemoryStore()

  struct Memory: Codable, Identifiable {
    let id: String
    let text: String
    let date: Date
  }

  struct SceneNote: Codable, Identifiable {
    let id: String
    let text: String
    let date: Date
  }

  private(set) var memories: [Memory] = []
  private(set) var sceneNotes: [SceneNote] = []

  @ObservationIgnored private let memoriesURL: URL
  @ObservationIgnored private let sceneURL: URL

  private init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    memoriesURL = docs.appendingPathComponent("memories.json")
    sceneURL = docs.appendingPathComponent("scene-notes.json")
    load()
  }

  // MARK: Hafıza

  @discardableResult
  func remember(_ text: String) -> Memory {
    let memory = Memory(id: UUID().uuidString, text: text.trimmingCharacters(in: .whitespacesAndNewlines), date: Date())
    memories.append(memory)
    if memories.count > 300 { memories.removeFirst(memories.count - 300) }
    saveMemories()
    log("Hafızaya yazıldı: \(memory.text)")
    return memory
  }

  func forget(matching query: String) -> Int {
    let needle = EdithController.normalize(query)
    guard !needle.isEmpty else { return 0 }
    let before = memories.count
    memories.removeAll { EdithController.normalize($0.text).contains(needle) }
    saveMemories()
    return before - memories.count
  }

  func delete(id: String) {
    memories.removeAll { $0.id == id }
    saveMemories()
  }

  func clearMemories() {
    memories.removeAll()
    saveMemories()
  }

  // MARK: Sahne notları

  func addSceneNote(_ text: String) {
    sceneNotes.append(SceneNote(id: UUID().uuidString, text: text, date: Date()))
    if sceneNotes.count > 200 { sceneNotes.removeFirst(sceneNotes.count - 200) }
    saveScene()
  }

  func clearSceneNotes() {
    sceneNotes.removeAll()
    saveScene()
  }

  // MARK: Prompt blokları

  var memoryPromptBlock: String {
    guard !memories.isEmpty else { return "" }
    let lines = memories.suffix(60).map { "- [\(Self.shortDate($0.date))] \($0.text)" }
    return "Hafızandakiler (kullanıcı söyledi, gerekince kullan):\n" + lines.joined(separator: "\n")
  }

  var scenePromptBlock: String {
    guard !sceneNotes.isEmpty else { return "" }
    let lines = sceneNotes.suffix(20).map { "- [\(Self.shortTime($0.date))] \($0.text)" }
    return "Gözlükten son gördüklerin (otomatik notlar, en yeni en altta):\n" + lines.joined(separator: "\n")
  }

  static func shortDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "tr_TR")
    f.dateFormat = "d MMM HH:mm"
    return f.string(from: date)
  }

  static func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "tr_TR")
    if Calendar.current.isDateInToday(date) {
      f.dateFormat = "HH:mm"
    } else {
      f.dateFormat = "d MMM HH:mm"
    }
    return f.string(from: date)
  }

  // MARK: Disk

  private func load() {
    if let data = try? Data(contentsOf: memoriesURL),
      let saved = try? JSONDecoder().decode([Memory].self, from: data)
    {
      memories = saved
    }
    if let data = try? Data(contentsOf: sceneURL),
      let saved = try? JSONDecoder().decode([SceneNote].self, from: data)
    {
      sceneNotes = saved
    }
  }

  private func saveMemories() {
    if let data = try? JSONEncoder().encode(memories) {
      try? data.write(to: memoriesURL, options: .atomic)
    }
  }

  private func saveScene() {
    if let data = try? JSONEncoder().encode(sceneNotes) {
      try? data.write(to: sceneURL, options: .atomic)
    }
  }
}
