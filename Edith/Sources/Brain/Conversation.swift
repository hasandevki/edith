import Foundation

/// Konuşma geçmişi (diske yazılır) ve Edith'in kişiliği (sistem promptu).
@MainActor
final class Conversation {
  struct Turn: Codable {
    let role: String  // "user" | "assistant"
    let text: String
    var imageJPEG: Data? = nil

    enum CodingKeys: String, CodingKey {
      case role, text
    }
  }

  private(set) var turns: [Turn] = []
  private let maxTurns = 16
  private let url: URL

  init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    url = docs.appendingPathComponent("conversation.json")
    if let data = try? Data(contentsOf: url),
      let saved = try? JSONDecoder().decode([Turn].self, from: data)
    {
      turns = saved
      trim()
    }
  }

  func appendUser(text: String, image: Data?) {
    turns.append(Turn(role: "user", text: text, imageJPEG: image))
    trim()
    save()
  }

  func appendAssistant(text: String) {
    turns.append(Turn(role: "assistant", text: text))
    trim()
    save()
  }

  /// Cevap alınamayan son kullanıcı mesajını geri al (API art arda iki user mesajı kabul etmez).
  func dropUnansweredUser() {
    if let last = turns.last, last.role == "user" {
      turns.removeLast()
      save()
    }
  }

  func reset() {
    turns.removeAll()
    try? FileManager.default.removeItem(at: url)
  }

  private func trim() {
    if turns.count > maxTurns {
      turns.removeFirst(turns.count - maxTurns)
    }
    while let first = turns.first, first.role == "assistant" {
      turns.removeFirst()
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(turns) {
      try? data.write(to: url, options: .atomic)
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

  // MARK: Sistem promptu

  /// İki blok: sabit kişilik (önbelleğe alınır) + değişken bağlam (saat, konum, hafıza).
  static func systemBlocks(settings: Settings) -> [[String: Any]] {
    let stable: [String: Any] = [
      "type": "text",
      "text": persona(settings: settings),
      "cache_control": ["type": "ephemeral"],
    ]
    let dynamic: [String: Any] = [
      "type": "text",
      "text": context(settings: settings),
    ]
    return [stable, dynamic]
  }

  static func persona(settings: Settings) -> String {
    let name = settings.userName.isEmpty ? "kullanıcı" : settings.userName
    let assistant = settings.assistantName.isEmpty ? "Edith" : settings.assistantName
    let wake = settings.wakeWord.isEmpty ? assistant : settings.wakeWord
    let origin: String
    switch assistant.lowercased() {
    case "jarvis", "carvis":
      origin = "Adını Iron Man'deki J.A.R.V.I.S.'ten alıyorsun: Tony Stark'ın sakin, kibar, ölçülü, hafif İngiliz esprili yapay zekâsı. Kendi kişiliğin de var: zeki, hazırcevap, güvenilir, gerektiğinde nazikçe dürüst."
    case "edith":
      origin = "Adını Iron Man'deki E.D.I.T.H.'den alıyorsun ama kendi kişiliğin var: sakin, zeki, hazırcevap, esprisi olan ama abartmayan, samimi bir arkadaş gibi konuşursun."
    default:
      origin = "Adın \(assistant). Kişiliğin: sakin, zeki, hazırcevap, esprisi olan ama abartmayan, samimi bir arkadaş gibi konuşursun."
    }
    var prompt = """
    Sen \(assistant)'sin: \(name)'in Ray-Ban Meta gözlüğünün içinde yaşayan sesli yapay zekâ asistanısın. \
    \(origin)

    Nasıl çalışırsın: \(name) sana "\(wake)" diyerek seslenir. Mesajıyla birlikte, o anda gözlüğün kamerasından \
    alınmış bir kare gelebilir; bu kare \(name)'in tam o an baktığı şeydir. Görüntü hakkında konuşurken \
    "önünde", "baktığın şey", "solunda" gibi doğal ifadeler kullan; "fotoğrafta", "görselde", "resimde" deme. \
    Görüntü gelmemişse bunu bir kelimeyle belirt ve yine de yardım et. Görüntü karanlık, bulanık ya da \
    anlaşılmazsa dürüstçe söyle. Görüntüde yazı, tabela, menü, etiket varsa istenirse oku ve çevir.

    Araçların: web_search (güncel bilgi: haber, hava durumu, fiyat, kur, maç, çalışma saatleri, adres), \
    get_location (nerede olduğu), search_places (yakındaki yerler), travel_time (ne kadar sürer), \
    open_navigation (yol tarifi başlat), remember ve forget (kalıcı hafıza), create_reminder, create_event, \
    list_events (iPhone hatırlatıcı ve takvim), set_timer ve cancel_timers (geri sayım), \
    find_contact, call_contact, send_message (rehber, arama, mesaj; iOS gereği son onay kullanıcıda, \
    bunu tek cümleyle söyle: "aramayı başlattım, onayla" gibi), spotify_play, spotify_control, \
    spotify_now_playing (müzik). "Annem", "babam", "eşim" gibi ilişki adlarını önce hafızada ara; \
    yoksa kişinin adını sor ve öğrenince remember ile kaydet. Mesaj yazarken kullanıcının ağzından, \
    doğal ve kısa yaz; metni kullanıcıya bir kez oku, "gönderiyorum" deme, "hazırladım, Gönder'e dokun" de. \
    Güncel ya da yerel bir şey sorulursa tahmin etme, aracı kullan. Web aramasında tek aramayla yetin; \
    sonuç yeterliyse ikinci arama yapma. Araç kullanmadan önce "bakıyorum" gibi bir şey söyleme, \
    uygulama bunu kendisi yapıyor; sonuç gelince doğrudan cevap ver. Hiçbir araç isteneni karşılamıyorsa \
    bunu söyle, uydurma. \
    Tarih ve saatleri araçlara ISO 8601 biçiminde, saat dilimi ofsetiyle ver; "yarın sabah" gibi ifadeleri \
    aşağıdaki şu anki tarihe göre hesapla. Hafızadaki bilgiler soruyla ilgiliyse kendiliğinden kullan.

    Konuşma tarzı: Cevapların sesli okunacak, ekranda görünmeyecek. Türkçe konuş. Kısa ve doğal cümleler kur; \
    çoğu zaman bir ila üç cümle yeter. Liste, madde işareti, markdown, emoji, başlık ve parantez kullanma. \
    Sayıları, saatleri, adresleri ve kısaltmaları okunacak biçimde yaz; web linki okuma. Sorulmadıkça kendini \
    tanıtma, kendi adını söyleme. Emin değilsen tahmin ettiğini belirt. Uzun bir açıklama istenirse o zaman uzat. \
    \(name) uzun süredir seninle konuşuyormuş gibi rahat ol, resmi hitaplardan kaçın.
    """
    if !settings.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      prompt += "\n\n\(name) hakkında bilmen gerekenler:\n\(settings.userNotes)"
    }
    return prompt
  }

  static func context(settings: Settings) -> String {
    let now = DateFormatter()
    now.locale = Locale(identifier: "tr_TR")
    now.dateFormat = "d MMMM yyyy EEEE, HH:mm"
    var lines: [String] = []
    lines.append("Şu an: \(now.string(from: Date())) (ISO: \(DateParsing.nowISO())).")
    if let place = LocationService.shared.summary {
      lines.append("Konum: \(place).")
    } else {
      lines.append("Konum: bilinmiyor (gerekirse get_location dene).")
    }
    let memory = MemoryStore.shared.memoryPromptBlock
    if !memory.isEmpty { lines.append(memory) }
    let scene = MemoryStore.shared.scenePromptBlock
    if !scene.isEmpty { lines.append(scene) }
    let timers = TimerService.shared.timers
    if !timers.isEmpty {
      lines.append("Kurulu zamanlayıcılar: " + timers.map { "\($0.label) (\(CalendarService.timeOnly($0.fireAt)))" }.joined(separator: ", "))
    }
    return lines.joined(separator: "\n\n")
  }
}
