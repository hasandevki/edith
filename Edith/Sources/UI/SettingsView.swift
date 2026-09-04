import AVFoundation
import SwiftUI

struct SettingsView: View {
  @Bindable var settings = Settings.shared
  var edith: EdithController
  @Environment(\.dismiss) private var dismiss
  @State private var pingResult = ""
  @State private var pinging = false
  @State private var voices: [ElevenLabsClient.Voice] = []
  @State private var loadingVoices = false
  @State private var voicesMessage = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Claude") {
          SecureField("API anahtarı (sk-ant-...)", text: $settings.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Picker("Model", selection: $settings.model) {
            ForEach(Settings.models, id: \.id) { Text($0.label).tag($0.id) }
          }
          Picker("Düşünme derinliği", selection: $settings.effort) {
            ForEach(Settings.efforts, id: \.id) { Text($0.label).tag($0.id) }
          }
          Button(pinging ? "Deneniyor..." : "API'yi dene") { ping() }
            .disabled(pinging || settings.apiKey.isEmpty)
          if !pingResult.isEmpty {
            Text(pingResult).font(.footnote).foregroundStyle(.secondary)
          }
        }

        Section("Edith") {
          TextField("Uyandırma kelimesi", text: $settings.wakeWord)
          TextField("Senin adın", text: $settings.userName)
          VStack(alignment: .leading) {
            Text("Edith senin hakkında ne bilsin?").font(.footnote).foregroundStyle(.secondary)
            TextEditor(text: $settings.userNotes)
              .frame(minHeight: 90)
          }
          Toggle("Yüksek çözünürlüklü fotoğraf çek (yavaş, deklanşör sesi)", isOn: $settings.useHiResPhoto)
        }

        Section("Ses motoru") {
          Picker("Ses", selection: $settings.ttsProvider) {
            Text("Apple (ücretsiz)").tag("apple")
            Text("ElevenLabs").tag("eleven")
          }
          .pickerStyle(.segmented)
          Button("Sesi dene") {
            edith.speaker.speak("Merhaba, ben Edith. Beni duyabiliyor musun? Bugün nasılsın?")
          }
        }

        if settings.ttsProvider == "eleven" {
          Section("ElevenLabs") {
            SecureField("ElevenLabs API anahtarı", text: $settings.elevenKey)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Picker("Model", selection: $settings.elevenModel) {
              ForEach(Settings.elevenModels, id: \.id) { Text($0.label).tag($0.id) }
            }
            Button(loadingVoices ? "Getiriliyor..." : "Sesleri getir") { loadVoices() }
              .disabled(loadingVoices || settings.elevenKey.isEmpty)
            if !voices.isEmpty {
              Picker("Ses", selection: $settings.elevenVoiceId) {
                Text("Seçilmedi").tag("")
                ForEach(voices) { voice in
                  Text(voice.subtitle.isEmpty ? voice.name : "\(voice.name) · \(voice.subtitle)").tag(voice.id)
                }
              }
              .onChange(of: settings.elevenVoiceId) { _, newId in
                settings.elevenVoiceName = voices.first { $0.id == newId }?.name ?? ""
              }
            } else if !settings.elevenVoiceName.isEmpty {
              Text("Seçili ses: \(settings.elevenVoiceName)").font(.footnote)
            }
            if !voicesMessage.isEmpty {
              Text(voicesMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Ses ElevenLabs'ten gelmezse (internet, kredi) Edith o cümleyi Apple sesiyle okur ve bir dakika sonra tekrar dener.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }

        Section("Apple sesi (yedek)") {
          Picker("Ses", selection: $settings.voiceIdentifier) {
            Text("Otomatik (en iyi Türkçe)").tag("")
            ForEach(Speaker.turkishVoices(), id: \.identifier) { voice in
              Text("\(voice.name) · \(qualityLabel(voice.quality))").tag(voice.identifier)
            }
          }
          VStack(alignment: .leading) {
            Text("Konuşma hızı: \(String(format: "%.2f", settings.speechRate))")
              .font(.footnote)
            Slider(value: $settings.speechRate, in: 0.35...0.65)
          }
          Text("Daha doğal Apple sesi için: iPhone Ayarlar → Erişilebilirlik → Sesli İçerik → Sesler → Türkçe → Yelda (Geliştirilmiş) indir.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Ayarlar")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Bitti") { dismiss() }
        }
      }
    }
  }

  private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .premium: return "premium"
    case .enhanced: return "geliştirilmiş"
    default: return "standart"
    }
  }

  private func ping() {
    pinging = true
    pingResult = ""
    Task {
      do {
        let reply = try await ClaudeClient.ping(apiKey: settings.apiKey, model: settings.model)
        pingResult = "Cevap: \(reply)"
      } catch {
        pingResult = "Hata: \(error.localizedDescription)"
      }
      pinging = false
    }
  }

  private func loadVoices() {
    loadingVoices = true
    voicesMessage = ""
    Task {
      do {
        let list = try await ElevenLabsClient.listVoices(apiKey: settings.elevenKey)
        voices = list
        voicesMessage = list.isEmpty ? "Hesapta ses yok. ElevenLabs'te sesi 'Add to my voices' ile ekle." : "\(list.count) ses bulundu."
        if !settings.elevenVoiceId.isEmpty, !list.contains(where: { $0.id == settings.elevenVoiceId }) {
          settings.elevenVoiceId = ""
        }
        log("ElevenLabs sesleri: \(list.map { $0.name }.joined(separator: ", "))")
      } catch {
        voicesMessage = "Hata: \(error.localizedDescription)"
      }
      loadingVoices = false
    }
  }
}
