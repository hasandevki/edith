import MWDATCore
import SwiftUI

@main
struct EdithApp: App {
  /// Kısayollar ve Siri (App Intents) buradan ulaşır.
  @MainActor static var shared: EdithController?

  @State private var glasses: GlassesManager
  @State private var edith: EdithController

  init() {
    do {
      try Wearables.configure()
      log("Wearables SDK yapılandırıldı.")
    } catch {
      log("Wearables.configure hatası: \(error)")
    }
    let glasses = GlassesManager(wearables: Wearables.shared)
    let edith = EdithController(glasses: glasses)
    _glasses = State(wrappedValue: glasses)
    _edith = State(wrappedValue: edith)
    EdithApp.shared = edith
  }

  var body: some Scene {
    WindowGroup {
      ContentView(glasses: glasses, edith: edith)
        .onOpenURL { url in
          Task { await glasses.handle(url: url) }
        }
    }
  }
}
