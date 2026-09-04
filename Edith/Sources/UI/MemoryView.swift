import SwiftUI

struct MemoryView: View {
  @Environment(\.dismiss) private var dismiss
  private var store = MemoryStore.shared

  var body: some View {
    NavigationStack {
      List {
        Section("Hatırladıkları (\(store.memories.count))") {
          if store.memories.isEmpty {
            Text("Henüz bir şey yok. \"Edith, arabayı B2'ye park ettim, hatırla\" de.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          ForEach(store.memories.reversed()) { memory in
            VStack(alignment: .leading, spacing: 2) {
              Text(memory.text)
              Text(MemoryStore.shortDate(memory.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .swipeActions {
              Button("Sil", role: .destructive) { store.delete(id: memory.id) }
            }
          }
        }

        Section("Gözlükten sahne notları (\(store.sceneNotes.count))") {
          if store.sceneNotes.isEmpty {
            Text("Kamera açıkken ve ayarlardan sahne hafızası açıksa buraya otomatik notlar düşer.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          ForEach(store.sceneNotes.suffix(40).reversed()) { note in
            VStack(alignment: .leading, spacing: 2) {
              Text(note.text).font(.callout)
              Text(MemoryStore.shortDate(note.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          if !store.sceneNotes.isEmpty {
            Button("Sahne notlarını temizle", role: .destructive) { store.clearSceneNotes() }
          }
        }
      }
      .navigationTitle("Hafıza")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Hepsini sil", role: .destructive) { store.clearMemories() }
            .disabled(store.memories.isEmpty)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Kapat") { dismiss() }
        }
      }
    }
  }
}
