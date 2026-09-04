import AppIntents
import Foundation

/// Kısayollar, Siri ve iPhone 15 Pro Action Button için giriş noktaları.
/// Kısayollar uygulamasında "Edith'e sor" eylemi olarak görünür; Action Button'a atanabilir.
struct AskEdithIntent: AppIntent {
  static var title: LocalizedStringResource = "Edith'e sor"
  static var description = IntentDescription("Edith'i açar ve hemen dinlemeye alır; uyandırma kelimesi gerekmez.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let edith = EdithApp.shared else { return .result() }
    await edith.startListening()
    edith.beginManualCapture()
    return .result()
  }
}

struct ToggleListeningIntent: AppIntent {
  static var title: LocalizedStringResource = "Edith dinlemeyi aç/kapat"
  static var description = IntentDescription("Edith'in kulağını açar ya da kapatır.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let edith = EdithApp.shared else { return .result() }
    if edith.isListeningActive {
      edith.stopListening()
    } else {
      await edith.startListening()
    }
    return .result()
  }
}

struct ToggleEyesIntent: AppIntent {
  static var title: LocalizedStringResource = "Edith gözleri aç/kapat"
  static var description = IntentDescription("Gözlük kamerasını Edith için açar ya da kapatır.")
  static var openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let edith = EdithApp.shared else { return .result() }
    if edith.glasses.eyesWanted {
      edith.glasses.eyesOff()
    } else {
      await edith.glasses.eyesOn()
    }
    return .result()
  }
}

struct EdithShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskEdithIntent(),
      phrases: ["\(.applicationName)'e sor", "\(.applicationName) dinle"],
      shortTitle: "Edith'e sor",
      systemImageName: "waveform"
    )
    AppShortcut(
      intent: ToggleListeningIntent(),
      phrases: ["\(.applicationName) dinlemeyi değiştir"],
      shortTitle: "Dinlemeyi aç/kapat",
      systemImageName: "ear"
    )
    AppShortcut(
      intent: ToggleEyesIntent(),
      phrases: ["\(.applicationName) gözleri değiştir"],
      shortTitle: "Gözleri aç/kapat",
      systemImageName: "eyeglasses"
    )
  }
}
