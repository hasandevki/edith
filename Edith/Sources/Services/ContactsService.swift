import Contacts
import Foundation
import UIKit

/// Rehber araması ve arama/mesaj için sistem uygulamalarını açma.
/// iOS, uygulamaların kendi başına arama yapmasına ya da mesaj göndermesine izin vermez;
/// burada yapılan, ilgili uygulamayı doğru kişi ve metinle açmaktır; son onay kullanıcıda.
@MainActor
final class ContactsService {
  static let shared = ContactsService()
  private let store = CNContactStore()

  struct Match {
    let name: String
    let numbers: [(label: String, number: String)]
    var primaryNumber: String? {
      numbers.first { $0.label.lowercased().contains("mobile") || $0.label.lowercased().contains("iphone") || $0.label.lowercased().contains("cep") }?.number
        ?? numbers.first?.number
    }
  }

  func find(_ name: String) async throws -> [Match] {
    let granted = try await store.requestAccess(for: .contacts)
    guard granted else { return [] }
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
    let predicate = CNContact.predicateForContacts(matchingName: name)
    let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
    return contacts.prefix(5).map { contact in
      let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
      let numbers = contact.phoneNumbers.map { entry -> (String, String) in
        let label = entry.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? "telefon"
        return (label, entry.value.stringValue)
      }
      return Match(name: fullName.isEmpty ? contact.nickname : fullName, numbers: numbers)
    }
  }

  func describe(_ matches: [Match]) -> String {
    if matches.isEmpty { return "Rehberde eşleşen kişi yok." }
    return matches.map { match in
      let nums = match.numbers.map { "\($0.label): \($0.number)" }.joined(separator: ", ")
      return "\(match.name) — \(nums.isEmpty ? "numara yok" : nums)"
    }.joined(separator: "\n")
  }

  /// "0532 123 45 67" → "+905321234567". Ülke kodu yoksa Türkiye varsayılır.
  static func e164(_ raw: String, defaultCountryCode: String = "90") -> String {
    var digits = raw.filter { $0.isNumber || $0 == "+" }
    if digits.hasPrefix("+") { return digits }
    if digits.hasPrefix("00") { digits.removeFirst(2); return "+" + digits }
    if digits.hasPrefix("0") { digits.removeFirst() }
    return "+" + defaultCountryCode + digits
  }

  // MARK: Sistem uygulamalarını açma

  @discardableResult
  private func open(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url)
  }

  func call(number: String, via: String) async -> String {
    let e164 = Self.e164(number)
    switch via {
    case "facetime":
      guard let url = URL(string: "facetime-audio://\(e164)") else { return "Numara geçersiz." }
      let ok = await open(url)
      return ok ? "FaceTime sesli arama başlatılıyor (\(e164)); ekranda onay istenebilir." : "FaceTime açılamadı."
    case "whatsapp":
      let digits = e164.replacingOccurrences(of: "+", with: "")
      guard let url = URL(string: "whatsapp://send?phone=\(digits)") else { return "Numara geçersiz." }
      let ok = await open(url)
      return ok
        ? "WhatsApp'ta sohbet açıldı (\(e164)). WhatsApp dışarıdan arama başlatmaya izin vermiyor; kullanıcı sağ üstteki telefon simgesine dokunmalı."
        : "WhatsApp açılamadı; yüklü olmayabilir."
    default:
      guard let url = URL(string: "tel://\(e164)") else { return "Numara geçersiz." }
      let ok = await open(url)
      return ok ? "Arama başlatılıyor (\(e164)); iOS onay soracak." : "Arama açılamadı."
    }
  }

  func message(number: String, text: String, via: String) async -> String {
    let e164 = Self.e164(number)
    let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    switch via {
    case "whatsapp":
      let digits = e164.replacingOccurrences(of: "+", with: "")
      guard let url = URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)") else { return "Bağlantı kurulamadı." }
      let ok = await open(url)
      return ok ? "WhatsApp açıldı, mesaj yazılı halde hazır; kullanıcı Gönder'e dokunmalı." : "WhatsApp açılamadı."
    default:
      guard let url = URL(string: "sms:\(e164)&body=\(encoded)") else { return "Bağlantı kurulamadı." }
      let ok = await open(url)
      return ok ? "Mesajlar açıldı, metin yazılı halde hazır; kullanıcı Gönder'e dokunmalı." : "Mesajlar açılamadı."
    }
  }
}
