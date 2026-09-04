import CoreLocation
import Foundation
import MapKit

/// Claude'un çağırabildiği yerel araçlar: konum, haritalar, hafıza, takvim, zamanlayıcı.
enum Tools {
  // MARK: Tanımlar (strict şema)

  static func definitions() -> [[String: Any]] {
    func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
      [
        "name": name,
        "description": description,
        "strict": true,
        "input_schema": [
          "type": "object",
          "properties": properties,
          "required": required,
          "additionalProperties": false,
        ],
      ]
    }
    let destination: [String: Any] = ["type": "string", "description": "Hedef yer adı veya adres"]
    let mode: [String: Any] = ["type": "string", "enum": ["walking", "driving", "transit"], "description": "Ulaşım biçimi"]

    return [
      tool(
        "get_location",
        "Kullanıcının şu anki konumu: koordinat, adres, doğruluk. Nerede olduğu, yakınındaki şeyler ya da yol tarifi sorulduğunda önce bunu çağır.",
        [:], []
      ),
      tool(
        "search_places",
        "Kullanıcının yakınındaki yerleri Apple Haritalar'da arar (eczane, kahveci, benzinlik, market, bir işletme adı). Sonuçlar mesafeyle döner.",
        [
          "query": ["type": "string", "description": "Aranacak yer ya da kategori"],
          "limit": ["type": "integer", "description": "Kaç sonuç, 1-8"],
        ],
        ["query", "limit"]
      ),
      tool(
        "travel_time",
        "Bir hedefe tahmini varış süresi ve mesafe.",
        ["destination": destination, "mode": mode],
        ["destination", "mode"]
      ),
      tool(
        "open_navigation",
        "Apple Haritalar'ı hedefe yol tarifiyle açar. Sadece kullanıcı açıkça yol tarifi başlatmak isteyince kullan.",
        ["destination": destination, "mode": mode],
        ["destination", "mode"]
      ),
      tool(
        "remember",
        "Kullanıcının hatırlanmasını istediği bilgiyi kalıcı hafızaya yazar (park yeri, isim, tercih, şifre değil). Kullanıcı 'hatırla', 'not al', 'unutma' derse kullan.",
        ["text": ["type": "string", "description": "Hatırlanacak bilgi, kısa ve net, Türkçe"]],
        ["text"]
      ),
      tool(
        "forget",
        "Hafızadan, verilen ifadeyle eşleşen kayıtları siler.",
        ["query": ["type": "string", "description": "Silinecek kaydın içindeki anahtar kelime"]],
        ["query"]
      ),
      tool(
        "create_reminder",
        "iPhone Hatırlatıcılar'a hatırlatıcı ekler.",
        [
          "title": ["type": "string", "description": "Hatırlatıcı başlığı"],
          "due": ["type": ["string", "null"], "description": "ISO 8601, saat dilimi ofsetiyle (örn 2026-09-05T09:00:00+03:00); belirsizse null"],
        ],
        ["title", "due"]
      ),
      tool(
        "create_event",
        "iPhone Takvim'e etkinlik ekler.",
        [
          "title": ["type": "string"],
          "start": ["type": "string", "description": "ISO 8601, saat dilimi ofsetiyle"],
          "end": ["type": "string", "description": "ISO 8601, saat dilimi ofsetiyle; söylenmediyse başlangıç + 1 saat"],
          "location": ["type": ["string", "null"], "description": "Yer, yoksa null"],
        ],
        ["title", "start", "end", "location"]
      ),
      tool(
        "list_events",
        "Takvimdeki etkinlikleri listeler. 'Bugün ne var', 'yarın programım' gibi sorularda kullan.",
        [
          "from": ["type": "string", "description": "ISO 8601, saat dilimi ofsetiyle"],
          "to": ["type": "string", "description": "ISO 8601, saat dilimi ofsetiyle"],
        ],
        ["from", "to"]
      ),
      tool(
        "set_timer",
        "Geri sayım zamanlayıcısı kurar; süre dolunca Edith sesli söyler ve bildirim gelir.",
        [
          "minutes": ["type": "number", "description": "Dakika (0.5 = 30 saniye)"],
          "label": ["type": "string", "description": "Ne için, örn 'makarna'"],
        ],
        ["minutes", "label"]
      ),
      tool(
        "cancel_timers",
        "Kurulu tüm zamanlayıcıları iptal eder.",
        [:], []
      ),
      tool(
        "find_contact",
        "Rehberde kişi arar (ad, soyad ya da takma ad) ve numaralarını döner.",
        ["name": ["type": "string", "description": "Rehberdeki ad"]],
        ["name"]
      ),
      tool(
        "call_contact",
        "Kişiyi arar. via=phone: normal arama (iOS 'Ara?' diye onay sorar). via=facetime: FaceTime sesli. via=whatsapp: WhatsApp sohbetini açar, kullanıcı arama simgesine dokunur (WhatsApp dışarıdan aramayı başlatmaya izin vermez). 'Annem' gibi ilişki adlarını önce hafızadan gerçek ada çevir; yoksa kullanıcıya sor.",
        [
          "name": ["type": "string", "description": "Rehberdeki ad"],
          "via": ["type": "string", "enum": ["phone", "facetime", "whatsapp"]],
        ],
        ["name", "via"]
      ),
      tool(
        "send_message",
        "Kişiye mesaj hazırlar. via=whatsapp ya da imessage. Uygulama metin yazılı halde açılır ve kullanıcı Gönder'e dokunur; otomatik gönderilmez. Metni kullanıcının ağzından, kısa ve doğal yaz.",
        [
          "name": ["type": "string", "description": "Rehberdeki ad"],
          "text": ["type": "string", "description": "Gönderilecek mesaj"],
          "via": ["type": "string", "enum": ["whatsapp", "imessage"]],
        ],
        ["name", "text", "via"]
      ),
      tool(
        "spotify_play",
        "Spotify'da arayıp telefonda çalar (Spotify Premium gerekir). kind: track, artist, album, playlist ya da any.",
        [
          "query": ["type": "string", "description": "Şarkı, sanatçı, albüm ya da çalma listesi adı"],
          "kind": ["type": "string", "enum": ["track", "artist", "album", "playlist", "any"]],
        ],
        ["query", "kind"]
      ),
      tool(
        "spotify_control",
        "Spotify'ı kontrol eder: pause (durdur), resume (devam), next (sonraki), previous (önceki).",
        ["action": ["type": "string", "enum": ["pause", "resume", "next", "previous"]]],
        ["action"]
      ),
      tool(
        "spotify_now_playing",
        "Spotify'da şu an ne çaldığını söyler.",
        [:], []
      ),
    ]
  }

  /// Web araması tanımı. Anthropic bazı ülke kodlarını (örn. MK) kabul etmiyor;
  /// reddedilen ülkelerde konum bilgisi eklenmez.
  @MainActor
  static func webSearchDefinition(variant: String, rejectedCountries: Set<String>) -> [String: Any] {
    var definition: [String: Any] = ["type": variant, "name": "web_search", "max_uses": 2]
    if let location = LocationService.shared.userLocationForSearch {
      let country = (location["country"] as? String ?? "").uppercased()
      if country.isEmpty || !rejectedCountries.contains(country) {
        definition["user_location"] = location
      }
    }
    return definition
  }

  // MARK: Çalıştırma

  /// Aracı çalıştırır; (sonuç metni, hata mı) döner.
  @MainActor
  static func run(_ call: ClaudeClient.ToolUse) async -> (String, Bool) {
    func str(_ key: String) -> String { (call.input[key] as? String) ?? "" }
    func num(_ key: String) -> Double? { (call.input[key] as? NSNumber)?.doubleValue }

    log("Araç: \(call.name) \(call.input)")
    do {
      switch call.name {
      case "get_location":
        return (LocationService.shared.describeForTool(), false)

      case "search_places":
        let limit = min(8, max(1, Int(num("limit") ?? 5)))
        return (try await searchPlaces(query: str("query"), limit: limit), false)

      case "travel_time":
        return (try await travelTime(destination: str("destination"), mode: str("mode")), false)

      case "open_navigation":
        return (try await openNavigation(destination: str("destination"), mode: str("mode")), false)

      case "remember":
        let memory = MemoryStore.shared.remember(str("text"))
        return ("Kaydedildi: \(memory.text)", false)

      case "forget":
        let removed = MemoryStore.shared.forget(matching: str("query"))
        return (removed == 0 ? "Eşleşen kayıt yok." : "\(removed) kayıt silindi.", false)

      case "create_reminder":
        let due = (call.input["due"] as? String).flatMap(DateParsing.parse)
        return (try await CalendarService.shared.createReminder(title: str("title"), due: due), false)

      case "create_event":
        guard let start = DateParsing.parse(str("start")) else { return ("Başlangıç tarihi anlaşılamadı.", true) }
        let end = DateParsing.parse(str("end")) ?? start.addingTimeInterval(3600)
        let location = call.input["location"] as? String
        return (try await CalendarService.shared.createEvent(title: str("title"), start: start, end: end, location: location), false)

      case "list_events":
        guard let from = DateParsing.parse(str("from")), let to = DateParsing.parse(str("to")) else {
          return ("Tarih aralığı anlaşılamadı.", true)
        }
        return (try await CalendarService.shared.listEvents(from: from, to: to), false)

      case "set_timer":
        let minutes = num("minutes") ?? 0
        guard minutes > 0 else { return ("Süre geçersiz.", true) }
        return (TimerService.shared.start(minutes: minutes, label: str("label")), false)

      case "cancel_timers":
        let count = TimerService.shared.cancelAll()
        return (count == 0 ? "Kurulu zamanlayıcı yok." : "\(count) zamanlayıcı iptal edildi.", false)

      case "find_contact":
        let matches = try await ContactsService.shared.find(str("name"))
        return (ContactsService.shared.describe(matches), false)

      case "call_contact":
        let target = str("name")
        let matches = try await ContactsService.shared.find(target)
        guard let match = matches.first, let number = match.primaryNumber else {
          return ("Rehberde \"\(target)\" bulunamadı ya da numarası yok. İlişki adıysa (annem gibi) hafızaya bak, yoksa kullanıcıya tam adını sor.", true)
        }
        let result = await ContactsService.shared.call(number: number, via: str("via"))
        return ("\(match.name): \(result)", false)

      case "send_message":
        let target = str("name")
        let matches = try await ContactsService.shared.find(target)
        guard let match = matches.first, let number = match.primaryNumber else {
          return ("Rehberde \"\(target)\" bulunamadı ya da numarası yok.", true)
        }
        let result = await ContactsService.shared.message(number: number, text: str("text"), via: str("via"))
        return ("\(match.name): \(result)", false)

      case "spotify_play":
        let kind = str("kind").isEmpty ? "any" : str("kind")
        guard let item = try await SpotifyService.shared.search(str("query"), kind: kind) else {
          return ("Spotify'da \"\(str("query"))\" bulunamadı.", true)
        }
        let result = try await SpotifyService.shared.play(item)
        if result.hasPrefix("Çalıyor"), Settings.shared.autoMusicMode, !AudioSessionManager.musicMode {
          try? AudioSessionManager.configure(musicMode: true)
        }
        return (result, false)

      case "spotify_control":
        let action = str("action")
        let result = try await SpotifyService.shared.control(action)
        if action == "pause" {
          SpotifyService.shared.userPaused = true
          if AudioSessionManager.musicMode { try? AudioSessionManager.configure(musicMode: false) }
        } else {
          SpotifyService.shared.userPaused = false
          if Settings.shared.autoMusicMode, !AudioSessionManager.musicMode { try? AudioSessionManager.configure(musicMode: true) }
        }
        return (result, false)

      case "spotify_now_playing":
        return (try await SpotifyService.shared.nowPlaying(), false)

      default:
        return ("Bilinmeyen araç: \(call.name)", true)
      }
    } catch {
      return ("Hata: \(error.localizedDescription)", true)
    }
  }

  // MARK: Haritalar

  @MainActor
  private static func searchPlaces(query: String, limit: Int) async throws -> String {
    guard let here = LocationService.shared.location else {
      return "Konum bilinmiyor; konum izni gerekli."
    }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
    let response = try await MKLocalSearch(request: request).start()
    let ranked = response.mapItems
      .map { item -> (MKMapItem, CLLocationDistance) in
        let distance = item.placemark.location.map { here.distance(from: $0) } ?? .infinity
        return (item, distance)
      }
      .sorted { $0.1 < $1.1 }
      .prefix(limit)
    if ranked.isEmpty { return "\"\(query)\" için yakında sonuç bulunamadı." }
    return ranked.enumerated().map { index, pair in
      let (item, distance) = pair
      var line = "\(index + 1). \(item.name ?? "(isimsiz)") — \(formatDistance(distance))"
      if let address = item.placemark.title { line += " — \(address)" }
      if let phone = item.phoneNumber { line += " — \(phone)" }
      return line
    }.joined(separator: "\n")
  }

  @MainActor
  private static func resolve(_ destination: String) async throws -> MKMapItem? {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = destination
    if let here = LocationService.shared.location {
      request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }
    return try await MKLocalSearch(request: request).start().mapItems.first
  }

  private static func transport(_ mode: String) -> MKDirectionsTransportType {
    switch mode {
    case "walking": return .walking
    case "transit": return .transit
    default: return .automobile
    }
  }

  private static func modeLabel(_ mode: String) -> String {
    switch mode {
    case "walking": return "yürüyerek"
    case "transit": return "toplu taşımayla"
    default: return "araçla"
    }
  }

  @MainActor
  private static func travelTime(destination: String, mode: String) async throws -> String {
    guard LocationService.shared.location != nil else {
      return "Konum bilinmiyor; konum izni gerekli."
    }
    guard let target = try await resolve(destination) else {
      return "\"\(destination)\" bulunamadı."
    }
    let request = MKDirections.Request()
    request.source = MKMapItem.forCurrentLocation()
    request.destination = target
    request.transportType = transport(mode)
    let eta = try await MKDirections(request: request).calculateETA()
    let minutes = Int((eta.expectedTravelTime / 60).rounded())
    return "\(target.name ?? destination): \(modeLabel(mode)) yaklaşık \(minutes) dakika, \(formatDistance(eta.distance))."
  }

  @MainActor
  private static func openNavigation(destination: String, mode: String) async throws -> String {
    guard let target = try await resolve(destination) else {
      return "\"\(destination)\" bulunamadı."
    }
    let directionsMode: String
    switch mode {
    case "walking": directionsMode = MKLaunchOptionsDirectionsModeWalking
    case "transit": directionsMode = MKLaunchOptionsDirectionsModeTransit
    default: directionsMode = MKLaunchOptionsDirectionsModeDriving
    }
    _ = await MainActor.run {
      target.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: directionsMode])
    }
    return "Apple Haritalar açıldı: \(target.name ?? destination)."
  }

  private static func formatDistance(_ meters: CLLocationDistance) -> String {
    guard meters.isFinite else { return "mesafe bilinmiyor" }
    return meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000)
  }
}
