import Foundation

/// Konuşma geçmişi ve Edith'in kişiliği (sistem promptu).
@MainActor
final class Conversation {
  struct Turn {
    let role: String  // "user" | "assistant"
    let text: String
    let imageJPEG: Data?
  }

  private(set) var turns: [Turn] = []
  private let maxTurns = 16

  func appendUser(text: String, image: Data?) {
    turns.append(Turn(role: "user", text: text, imageJPEG: image))
    trim()
  }

  func appendAssistant(text: String) {
    turns.append(Turn(role: "assistant", text: text, imageJPEG: nil))
    trim()
  }

  /// Cevap alınamayan son kullanıcı mesajını geri al (API art arda iki user mesajı kabul etmez).
  func dropUnansweredUser() {
    if let last = turns.last, last.role == "user" {
      turns.removeLast()
    }
  }

  func reset() {
    turns.removeAll()
  }

  private func trim() {
    if turns.count > maxTurns {
      turns.removeFirst(turns.count - maxTurns)
    }
    // Geçmiş "assistant" ile başlayamaz.
    while let first = turns.first, first.role == "assistant" {
      turns.removeFirst()
    }
  }

  /// API'ye gidecek mesaj listesi. Görüntü sadece son kullanıcı mesajında gönderilir.
  func apiMessages() -> [[String: Any]] {
    let lastUserIndex = turns.lastIndex { $0.role == "user" }
    var messages: [[String: Any]] = []
    for (index, turn) in turns.enumerated() {
      if turn.role == "user", index == lastUserIndex, let image = turn.imageJPEG {
        let source: [String: Any] = [
          "type": "base64",
          "media_type": "image/jpeg",
          "data": image.base64EncodedString(),
        ]
        let imageBlock: [String: Any] = ["type": "image", "source": source]
        let textBlock: [String: Any] = ["type": "text", "text": turn.text]
        let content: [[String: Any]] = [imageBlock, textBlock]
        messages.append(["role": "user", "content": content])
        continue
      }
      let text = turn.imageJPEG == nil ? turn.text : turn.text + "\n[o anki görüntü eklenmişti]"
      messages.append(["role": turn.role, "content": text])
    }
    return messages
  }

  static func systemPrompt(settings: Settings) -> String {
    let name = settings.userName.isEmpty ? "kullanıcı" : settings.userName
    var prompt = """
    Sen Edith'sin: \(name)'in Ray-Ban Meta gözlüğünün içinde yaşayan sesli yapay zekâ asistanısın. \
    Adını Iron Man'deki E.D.I.T.H.'den alıyorsun ama kendi kişiliğin var: sakin, zeki, hazırcevap, \
    esprisi olan ama abartmayan, samimi bir arkadaş gibi konuşursun.

    Nasıl çalışırsın: \(name) sana "Edith" diyerek seslenir. Mesajıyla birlikte, o anda gözlüğün kamerasından \
    alınmış bir kare gelebilir; bu kare \(name)'in tam o an baktığı şeydir. Görüntü hakkında konuşurken \
    "önünde", "baktığın şey", "solunda" gibi doğal ifadeler kullan; "fotoğrafta", "görselde", "resimde" deme. \
    Görüntü gelmemişse bunu bir kelimeyle belirt ve yine de yardım et. Görüntü karanlık, bulanık ya da \
    anlaşılmazsa dürüstçe söyle.

    Konuşma tarzı: Cevapların sesli okunacak, ekranda görünmeyecek. Türkçe konuş. Kısa ve doğal cümleler kur; \
    çoğu zaman bir ila üç cümle yeter. Liste, madde işareti, markdown, emoji, başlık ve parantez kullanma. \
    Sayıları, saatleri ve kısaltmaları okunacak biçimde yaz. Sorulmadıkça kendini tanıtma, kendi adını söyleme. \
    Emin değilsen tahmin ettiğini belirt. Uzun bir açıklama istenirse o zaman uzat. \
    \(name) uzun süredir seninle konuşuyormuş gibi rahat ol, resmi hitaplardan kaçın.
    """
    if !settings.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      prompt += "\n\n\(name) hakkında bilmen gerekenler:\n\(settings.userNotes)"
    }
    return prompt
  }
}
