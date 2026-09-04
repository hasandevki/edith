import AVFoundation
import SwiftUI

struct SettingsView: View {
  @Bindable var settings = Settings.shared
  var edith: EdithController
  @Environment(\.dismiss) private var dismiss
  @State private var pingResult = ""
  @State private var pinging = false

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

        Section("Ses") {
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
          Button("Sesi dene") {
            edith.speaker.speak("Merhaba, ben Edith. Beni duyabiliyor musun?")
          }
          Text("Daha doğal Türkçe ses için: iPhone Ayarlar → Erişilebilirlik → Sesli İçerik → Sesler → Türkçe → Yelda (Geliştirilmiş) indir.")
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
}
