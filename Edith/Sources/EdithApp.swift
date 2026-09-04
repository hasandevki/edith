import MWDATCore
import SwiftUI

@main
struct EdithApp: App {
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
    _glasses = State(wrappedValue: glasses)
    _edith = State(wrappedValue: EdithController(glasses: glasses))
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
