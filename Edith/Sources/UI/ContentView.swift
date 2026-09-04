import SwiftUI

struct ContentView: View {
  var glasses: GlassesManager
  var edith: EdithController
  @State private var showSettings = false
  @State private var showLogs = false
  @State private var showMemory = false
  @State private var typed = ""
  private var usage = UsageTracker.shared
  private var timers = TimerService.shared

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          stateCard
          glassesCard
          listeningCard
          translationCard
          transcriptCard
        }
        .padding()
      }
      .navigationTitle("Edith")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { showLogs = true } label: { Image(systemName: "list.bullet.rectangle") }
        }
        ToolbarItem(placement: .topBarTrailing) {
          HStack {
            Button { showMemory = true } label: { Image(systemName: "brain") }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
          }
        }
      }
      .sheet(isPresented: $showSettings) { SettingsView(edith: edith) }
      .sheet(isPresented: $showLogs) { LogView() }
      .sheet(isPresented: $showMemory) { MemoryView() }
      .task {
        if Settings.shared.autoStartListening, !edith.isListeningActive {
          await edith.startListening()
        }
      }
    }
  }

  // MARK: Kartlar

  private var stateCard: some View {
    VStack(spacing: 8) {
      ZStack {
        Circle()
          .fill(stateColor.opacity(0.18))
          .frame(width: 120, height: 120)
        Circle()
          .fill(stateColor)
          .frame(width: edith.state == .capturing || edith.state == .speaking ? 84 : 64,
                 height: edith.state == .capturing || edith.state == .speaking ? 84 : 64)
          .animation(.easeInOut(duration: 0.4), value: edith.state)
      }
      Text(edith.state.rawValue)
        .font(.title2.weight(.semibold))
      if !edith.lastHeard.isEmpty {
        Text("Duyulan: \(edith.lastHeard)")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
      Text(usageLine)
        .font(.caption)
        .foregroundStyle(.secondary)
      if !timers.timers.isEmpty {
        Text("Zamanlayıcı: " + timers.timers.map { "\($0.label) \(CalendarService.timeOnly($0.fireAt))" }.joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let error = edith.lastError ?? glasses.lastError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var usageLine: String {
    let day = usage.today
    var line = "Bugün: \(UsageTracker.formatUSD(day.costUSD)) · \(day.questions) soru"
    if day.searches > 0 { line += " · \(day.searches) arama" }
    if day.elevenCredits > 0 { line += " · ElevenLabs \(Int(day.elevenCredits)) kredi" }
    return line
  }

  private var stateColor: Color {
    switch edith.state {
    case .idle: return .gray
    case .listening: return .blue
    case .followUp: return .teal
    case .capturing: return .green
    case .thinking: return .orange
    case .speaking: return .purple
    }
  }

  private var glassesCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Gözlük", systemImage: "eyeglasses")
        .font(.headline)

      HStack {
        VStack(alignment: .leading, spacing: 4) {
          row("Kayıt", glasses.registrationText)
          row("Cihaz", glasses.hasActiveDevice ? "aktif" : (glasses.devices.isEmpty ? "yok" : "bağlı değil"))
          row("Oturum", glasses.sessionStateText)
          row("Kamera", glasses.streamStateText + (glasses.frameCount > 0 ? " (\(glasses.frameCount) kare)" : ""))
        }
        Spacer()
        if let frame = glasses.latestFrame {
          Image(uiImage: frame)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 72, height: 128)
            .overlay(Image(systemName: "eye.slash").foregroundStyle(.secondary))
        }
      }

      HStack {
        if glasses.isRegistered {
          Button("Bağlantıyı kes", role: .destructive) { Task { await glasses.disconnect() } }
            .buttonStyle(.bordered)
        } else {
          Button("Gözlüğü bağla") { Task { await glasses.connect() } }
            .buttonStyle(.borderedProminent)
        }
        Spacer()
        if glasses.eyesWanted {
          Button("Gözleri kapat") { glasses.eyesOff() }
            .buttonStyle(.bordered)
        } else {
          Button("Gözleri aç") { Task { await glasses.eyesOn() } }
            .buttonStyle(.borderedProminent)
            .disabled(!glasses.isRegistered)
        }
      }

      if glasses.requiresFirmwareUpdate {
        Button("Gözlük firmware güncellemesi gerekiyor") { Task { await glasses.openFirmwareUpdate() } }
          .font(.footnote)
      }
      if glasses.needsGlassesAppUpdate {
        Button("Gözlükteki uygulamayı güncelle") { Task { await glasses.openGlassesAppUpdate() } }
          .font(.footnote)
      }
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var listeningCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Kulak", systemImage: "waveform")
        .font(.headline)
      Text("Uyandırma: \"\(Settings.shared.wakeWord)\" de, sonra soruyu sor. Cevaptan sonra bir süre kelimesiz devam edebilirsin.")
        .font(.footnote)
        .foregroundStyle(.secondary)
      HStack {
        if edith.isListeningActive {
          Button("Dinlemeyi durdur") { edith.stopListening() }
            .buttonStyle(.bordered)
          Spacer()
          Button("Şimdi konuş") { edith.beginManualCapture() }
            .buttonStyle(.borderedProminent)
            .disabled(edith.state == .capturing)
        } else {
          Button("Dinlemeyi başlat") { Task { await edith.startListening() } }
            .buttonStyle(.borderedProminent)
          Spacer()
        }
      }
      HStack {
        TextField("Yazarak sor (test)", text: $typed)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.send)
          .onSubmit(sendTyped)
        Button(action: sendTyped) { Image(systemName: "paperplane.fill") }
          .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if edith.speaker.isSpeaking {
        Button("Sustur") { edith.speaker.stop() }
          .font(.footnote)
      }
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var translationCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Çeviri modu", systemImage: "globe")
          .font(.headline)
        Spacer()
        Toggle("", isOn: Binding(
          get: { edith.translationMode },
          set: { edith.setTranslation(enabled: $0) }
        ))
        .labelsHidden()
        .disabled(!edith.isListeningActive)
      }
      let target = Settings.translationLabel(Settings.shared.translationTarget)
      if edith.translationMode {
        Picker("Yön", selection: Binding(
          get: { edith.translationDirection == .toTarget ? 0 : 1 },
          set: { edith.setTranslationDirection($0 == 0 ? .toTarget : .fromTarget) }
        )) {
          Text("Ben: Türkçe → \(target)").tag(0)
          Text("Karşı taraf: \(target) → Türkçe").tag(1)
        }
        .pickerStyle(.segmented)
        Text("Uyandırma kelimesi gerekmez; söylenen her şey çevrilir. \"Edith, çeviriyi kapat\" ile çıkılır.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else {
        Text("Sesle: \"Edith, çeviri modunu aç\". Hedef dil ayarlardan (şu an \(target)).")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var transcriptCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Konuşma", systemImage: "text.bubble")
          .font(.headline)
        Spacer()
        Button("Sıfırla") { edith.resetConversation() }
          .font(.footnote)
      }
      if edith.transcript.isEmpty {
        Text("Henüz konuşma yok.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      ForEach(edith.transcript.suffix(30)) { entry in
        HStack(alignment: .top, spacing: 8) {
          Text(prefix(for: entry.role))
            .font(.caption.weight(.bold))
            .foregroundStyle(color(for: entry.role))
            .frame(width: 44, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
              .font(.callout)
              .textSelection(.enabled)
            if let cost = entry.costUSD {
              Text(UsageTracker.formatUSD(cost))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .padding()
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  // MARK: Yardımcılar

  private func sendTyped() {
    let text = typed
    typed = ""
    edith.askTyped(text)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(spacing: 6) {
      Text(label + ":").foregroundStyle(.secondary)
      Text(value)
    }
    .font(.footnote)
  }

  private func prefix(for role: EdithController.TranscriptEntry.Role) -> String {
    switch role {
    case .user: return "Sen"
    case .edith: return "Edith"
    case .system: return "•"
    }
  }

  private func color(for role: EdithController.TranscriptEntry.Role) -> Color {
    switch role {
    case .user: return .blue
    case .edith: return .purple
    case .system: return .secondary
    }
  }
}
