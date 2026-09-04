import Foundation
import Observation

/// Kullanıcı ayarları. API anahtarı Keychain'de, gerisi UserDefaults'ta.
@Observable
final class Settings: @unchecked Sendable {
  static let shared = Settings()

  static let models: [(id: String, label: String)] = [
    ("claude-opus-5", "Claude Opus 5 (varsayılan)"),
    ("claude-fable-5-1", "Claude Fable 5.1 (en güçlü, pahalı)"),
    ("claude-sonnet-5", "Claude Sonnet 5 (hızlı, ucuz)"),
  ]
  static let efforts: [(id: String, label: String)] = [
    ("low", "Düşük (en hızlı cevap)"),
    ("medium", "Orta"),
    ("high", "Yüksek (daha derin düşünür)"),
  ]

  var apiKey: String {
    didSet { Keychain.set(apiKey, account: "anthropic_api_key") }
  }
  var model: String { didSet { d.set(model, forKey: "model") } }
  var effort: String { didSet { d.set(effort, forKey: "effort") } }
  var wakeWord: String { didSet { d.set(wakeWord, forKey: "wakeWord") } }
  var userName: String { didSet { d.set(userName, forKey: "userName") } }
  var userNotes: String { didSet { d.set(userNotes, forKey: "userNotes") } }
  var useHiResPhoto: Bool { didSet { d.set(useHiResPhoto, forKey: "useHiResPhoto") } }
  var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") } }
  var speechRate: Float { didSet { d.set(speechRate, forKey: "speechRate") } }
  var autoStartListening: Bool { didSet { d.set(autoStartListening, forKey: "autoStartListening") } }

  private let d = UserDefaults.standard

  private init() {
    apiKey = Keychain.get("anthropic_api_key") ?? ""
    model = d.string(forKey: "model") ?? "claude-opus-5"
    effort = d.string(forKey: "effort") ?? "low"
    wakeWord = d.string(forKey: "wakeWord") ?? "Edith"
    userName = d.string(forKey: "userName") ?? "Hasan"
    userNotes = d.string(forKey: "userNotes") ?? ""
    useHiResPhoto = d.object(forKey: "useHiResPhoto") as? Bool ?? false
    voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
    speechRate = d.object(forKey: "speechRate") as? Float ?? 0.5
    autoStartListening = d.object(forKey: "autoStartListening") as? Bool ?? false
  }
}
