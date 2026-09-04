import Foundation
import Observation

/// Kullanıcı ayarları. API anahtarları Keychain'de, gerisi UserDefaults'ta.
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
  static let elevenModels: [(id: String, label: String)] = [
    ("eleven_flash_v2_5", "Flash v2.5 (hızlı, yarım kredi)"),
    ("eleven_multilingual_v2", "Multilingual v2 (daha doğal, tam kredi)"),
  ]

  // Claude
  var apiKey: String { didSet { Keychain.set(apiKey, account: "anthropic_api_key") } }
  var model: String { didSet { d.set(model, forKey: "model") } }
  var effort: String { didSet { d.set(effort, forKey: "effort") } }

  // Edith
  var wakeWord: String { didSet { d.set(wakeWord, forKey: "wakeWord") } }
  var userName: String { didSet { d.set(userName, forKey: "userName") } }
  var userNotes: String { didSet { d.set(userNotes, forKey: "userNotes") } }
  var useHiResPhoto: Bool { didSet { d.set(useHiResPhoto, forKey: "useHiResPhoto") } }
  var autoStartListening: Bool { didSet { d.set(autoStartListening, forKey: "autoStartListening") } }

  // Ses: Apple
  var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") } }
  var speechRate: Float { didSet { d.set(speechRate, forKey: "speechRate") } }

  // Ses: ElevenLabs
  var ttsProvider: String { didSet { d.set(ttsProvider, forKey: "ttsProvider") } }  // "apple" | "eleven"
  var elevenKey: String { didSet { Keychain.set(elevenKey, account: "elevenlabs_api_key") } }
  var elevenVoiceId: String { didSet { d.set(elevenVoiceId, forKey: "elevenVoiceId") } }
  var elevenVoiceName: String { didSet { d.set(elevenVoiceName, forKey: "elevenVoiceName") } }
  var elevenModel: String { didSet { d.set(elevenModel, forKey: "elevenModel") } }

  /// ElevenLabs kullanılabilir mi: seçili, anahtar ve ses girilmiş.
  var elevenReady: Bool {
    ttsProvider == "eleven" && !elevenKey.isEmpty && !elevenVoiceId.isEmpty
  }

  private let d = UserDefaults.standard

  private init() {
    apiKey = Keychain.get("anthropic_api_key") ?? ""
    model = d.string(forKey: "model") ?? "claude-opus-5"
    effort = d.string(forKey: "effort") ?? "low"
    wakeWord = d.string(forKey: "wakeWord") ?? "Edith"
    userName = d.string(forKey: "userName") ?? "Hasan"
    userNotes = d.string(forKey: "userNotes") ?? ""
    useHiResPhoto = d.object(forKey: "useHiResPhoto") as? Bool ?? false
    autoStartListening = d.object(forKey: "autoStartListening") as? Bool ?? false
    voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
    speechRate = d.object(forKey: "speechRate") as? Float ?? 0.5
    ttsProvider = d.string(forKey: "ttsProvider") ?? "apple"
    elevenKey = Keychain.get("elevenlabs_api_key") ?? ""
    elevenVoiceId = d.string(forKey: "elevenVoiceId") ?? ""
    elevenVoiceName = d.string(forKey: "elevenVoiceName") ?? ""
    elevenModel = d.string(forKey: "elevenModel") ?? "eleven_flash_v2_5"
  }
}
