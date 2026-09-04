import Foundation
import Observation
import UserNotifications

/// Geri sayım zamanlayıcıları: uygulama açıksa Edith sesli söyler, ayrıca bildirim gelir.
@Observable
@MainActor
final class TimerService {
  static let shared = TimerService()

  struct ActiveTimer: Identifiable {
    let id: String
    let label: String
    let fireAt: Date
  }

  private(set) var timers: [ActiveTimer] = []
  @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var onFire: ((String) -> Void)?

  private init() {}

  func requestPermission() async {
    do {
      _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    } catch {
      log("Bildirim izni: \(error.localizedDescription)")
    }
  }

  func start(minutes: Double, label: String) -> String {
    let id = UUID().uuidString
    let seconds = max(1, minutes * 60)
    let fireAt = Date().addingTimeInterval(seconds)
    let name = label.isEmpty ? "zamanlayıcı" : label
    timers.append(ActiveTimer(id: id, label: name, fireAt: fireAt))

    let content = UNMutableNotificationContent()
    content.title = "Edith"
    content.body = "Süre doldu: \(name)"
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) { error in
      if let error { log("Bildirim kurulamadı: \(error.localizedDescription)") }
    }

    tasks[id] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, !Task.isCancelled else { return }
      self.timers.removeAll { $0.id == id }
      self.tasks[id] = nil
      self.onFire?(name)
    }
    return "Zamanlayıcı kuruldu: \(name), \(Self.describe(minutes)) sonra (\(CalendarService.timeOnly(fireAt)))."
  }

  func cancelAll() -> Int {
    let count = timers.count
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: timers.map { $0.id })
    timers.removeAll()
    return count
  }

  static func describe(_ minutes: Double) -> String {
    if minutes < 1 { return "\(Int((minutes * 60).rounded())) saniye" }
    if minutes < 60 { return "\(Int(minutes.rounded())) dakika" }
    let hours = Int(minutes / 60)
    let rest = Int(minutes.truncatingRemainder(dividingBy: 60))
    return rest == 0 ? "\(hours) saat" : "\(hours) saat \(rest) dakika"
  }
}
