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
  static let followUpOptions: [(id: Int, label: String)] = [
    (0, "Kapalı (her seferinde Edith de)"),
    (5, "5 saniye"),
    (8, "8 saniye"),
    (12, "12 saniye"),
    (20, "20 saniye"),
  ]
  static let translationTargets: [(id: String, label: String)] = [
    ("en-US", "İngilizce"),
    ("de-DE", "Almanca"),
    ("fr-FR", "Fransızca"),
    ("es-ES", "İspanyolca"),
    ("it-IT", "İtalyanca"),
    ("ru-RU", "Rusça"),
    ("ar-SA", "Arapça"),
    ("mk-MK", "Makedonca"),
  ]
  static let sceneIntervals: [(id: Int, label: String)] = [
    (2, "2 dakika"),
    (3, "3 dakika"),
    (5, "5 dakika"),
    (10, "10 dakika"),
  ]

  static func translationLabel(_ id: String) -> String {
    translationTargets.first { $0.id == id }?.label ?? id
  }

  // Claude
  var apiKey: String { didSet { Keychain.set(apiKey, account: "anthropic_api_key") } }
  var model: String { didSet { d.set(model, forKey: "model") } }
  var effort: String { didSet { d.set(effort, forKey: "effort") } }
  var webSearchEnabled: Bool { didSet { d.set(webSearchEnabled, forKey: "webSearchEnabled") } }

  // Edith
  var assistantName: String { didSet { d.set(assistantName, forKey: "assistantName") } }
  var wakeWord: String { didSet { d.set(wakeWord, forKey: "wakeWord") } }
  var userName: String { didSet { d.set(userName, forKey: "userName") } }
  var userNotes: String { didSet { d.set(userNotes, forKey: "userNotes") } }
  var useHiResPhoto: Bool { didSet { d.set(useHiResPhoto, forKey: "useHiResPhoto") } }
  var autoStartListening: Bool { didSet { d.set(autoStartListening, forKey: "autoStartListening") } }
  var followUpSeconds: Int { didSet { d.set(followUpSeconds, forKey: "followUpSeconds") } }
  var translationTarget: String { didSet { d.set(translationTarget, forKey: "translationTarget") } }
  var sceneMemoryEnabled: Bool { didSet { d.set(sceneMemoryEnabled, forKey: "sceneMemoryEnabled") } }
  var sceneIntervalMinutes: Int { didSet { d.set(sceneIntervalMinutes, forKey: "sceneIntervalMinutes") } }

  // Ses: Apple
  var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") } }
  var speechRate: Float { didSet { d.set(speechRate, forKey: "speechRate") } }

  // Ses: ElevenLabs
  var ttsProvider: String { didSet { d.set(ttsProvider, forKey: "ttsProvider") } }
  var elevenKey: String { didSet { Keychain.set(elevenKey, account: "elevenlabs_api_key") } }
  var elevenVoiceId: String { didSet { d.set(elevenVoiceId, forKey: "elevenVoiceId") } }
  var elevenVoiceName: String { didSet { d.set(elevenVoiceName, forKey: "elevenVoiceName") } }
  var elevenModel: String { didSet { d.set(elevenModel, forKey: "elevenModel") } }

  var elevenReady: Bool {
    ttsProvider == "eleven" && !elevenKey.isEmpty && !elevenVoiceId.isEmpty
  }

  private let d = UserDefaults.standard

  private init() {
    apiKey = Keychain.get("anthropic_api_key") ?? ""
    model = d.string(forKey: "model") ?? "claude-opus-5"
    effort = d.string(forKey: "effort") ?? "low"
    webSearchEnabled = d.object(forKey: "webSearchEnabled") as? Bool ?? true
    assistantName = d.string(forKey: "assistantName") ?? "Edith"
    wakeWord = d.string(forKey: "wakeWord") ?? "Edith"
    userName = d.string(forKey: "userName") ?? "Hasan"
    userNotes = d.string(forKey: "userNotes") ?? ""
    useHiResPhoto = d.object(forKey: "useHiResPhoto") as? Bool ?? false
    autoStartListening = d.object(forKey: "autoStartListening") as? Bool ?? false
    followUpSeconds = d.object(forKey: "followUpSeconds") as? Int ?? 8
    translationTarget = d.string(forKey: "translationTarget") ?? "en-US"
    sceneMemoryEnabled = d.object(forKey: "sceneMemoryEnabled") as? Bool ?? false
    sceneIntervalMinutes = d.object(forKey: "sceneIntervalMinutes") as? Int ?? 3
    voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
    speechRate = d.object(forKey: "speechRate") as? Float ?? 0.5
    ttsProvider = d.string(forKey: "ttsProvider") ?? "apple"
    elevenKey = Keychain.get("elevenlabs_api_key") ?? ""
    elevenVoiceId = d.string(forKey: "elevenVoiceId") ?? ""
    elevenVoiceName = d.string(forKey: "elevenVoiceName") ?? ""
    elevenModel = d.string(forKey: "elevenModel") ?? "eleven_flash_v2_5"
  }
}
