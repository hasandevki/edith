import EventKit
import Foundation

/// iPhone Takvim ve Hatırlatıcılar.
@MainActor
final class CalendarService {
  static let shared = CalendarService()
  private let store = EKEventStore()

  func createReminder(title: String, due: Date?) async throws -> String {
    guard try await store.requestFullAccessToReminders() else {
      return "Hatırlatıcılar izni verilmedi. iPhone Ayarlar → Edith → Hatırlatıcılar'dan açılabilir."
    }
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = store.defaultCalendarForNewReminders()
    if let due {
      reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
      reminder.addAlarm(EKAlarm(absoluteDate: due))
    }
    try store.save(reminder, commit: true)
    if let due {
      return "Hatırlatıcı eklendi: \(title), \(Self.format(due))."
    }
    return "Hatırlatıcı eklendi: \(title) (tarihsiz)."
  }

  func createEvent(title: String, start: Date, end: Date, location: String?) async throws -> String {
    guard try await store.requestFullAccessToEvents() else {
      return "Takvim izni verilmedi. iPhone Ayarlar → Edith → Takvimler'den açılabilir."
    }
    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = start
    event.endDate = end > start ? end : start.addingTimeInterval(3600)
    event.location = location
    event.calendar = store.defaultCalendarForNewEvents
    event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
    try store.save(event, span: .thisEvent, commit: true)
    return "Takvime eklendi: \(title), \(Self.format(start)) - \(Self.timeOnly(event.endDate))."
  }

  func listEvents(from: Date, to: Date) async throws -> String {
    guard try await store.requestFullAccessToEvents() else {
      return "Takvim izni verilmedi."
    }
    let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
    let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    if events.isEmpty { return "Bu aralıkta takvimde etkinlik yok." }
    return events.prefix(20).map { event in
      var line = "\(Self.format(event.startDate)) - \(Self.timeOnly(event.endDate)): \(event.title ?? "(isimsiz)")"
      if let place = event.location, !place.isEmpty { line += " @ \(place)" }
      return line
    }.joined(separator: "\n")
  }

  static func format(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "tr_TR")
    f.dateFormat = "d MMMM EEEE HH:mm"
    return f.string(from: date)
  }

  static func timeOnly(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "tr_TR")
    f.dateFormat = "HH:mm"
    return f.string(from: date)
  }
}

/// Modelin ürettiği tarih metinlerini çözer (ISO 8601 öncelikli).
enum DateParsing {
  static func parse(_ text: String) -> Date? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.lowercased() != "null" else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: s) { return d }
    for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = .current
      f.dateFormat = pattern
      if let d = f.date(from: s) { return d }
    }
    return nil
  }

  /// Şu anki tarih/saat, saat dilimi ofsetiyle (model araçlara bunu örnek alır).
  static func nowISO() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = .current
    return f.string(from: Date())
  }
}
