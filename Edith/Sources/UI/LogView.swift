import SwiftUI

struct LogView: View {
  @Environment(\.dismiss) private var dismiss
  private var logStore = Log.shared

  private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  var body: some View {
    NavigationStack {
      List(logStore.entries.reversed()) { entry in
        VStack(alignment: .leading, spacing: 2) {
          Text(timeFormatter.string(from: entry.time))
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(entry.text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
      }
      .listStyle(.plain)
      .navigationTitle("Kayıtlar")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Temizle") { logStore.clear() }
        }
        ToolbarItem(placement: .primaryAction) {
          ShareLink(item: logStore.exportText) {
            Image(systemName: "square.and.arrow.up")
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kapat") { dismiss() }
        }
      }
    }
  }
}
