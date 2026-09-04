import Foundation
import Observation

/// Günlük kullanım ve yaklaşık maliyet (dolar). Fiyatlar milyon token başına.
@Observable
final class UsageTracker: @unchecked Sendable {
  static let shared = UsageTracker()

  struct Day: Codable {
    var date: String
    var questions = 0
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var outputTokens = 0
    var searches = 0
    var elevenCredits: Double = 0
    var costUSD: Double = 0
  }

  private(set) var today: Day
  private(set) var lastAnswerCostUSD: Double = 0

  private let d = UserDefaults.standard
  private let key = "usage.today"
  static let searchPriceUSD = 0.01

  private init() {
    if let data = UserDefaults.standard.data(forKey: "usage.today"),
      let saved = try? JSONDecoder().decode(Day.self, from: data),
      saved.date == Self.todayKey()
    {
      today = saved
    } else {
      today = Day(date: Self.todayKey())
    }
  }

  static func todayKey() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
  }

  /// Model fiyatı: (girdi, çıktı, önbellek okuma, önbellek yazma), $/M token.
  static func price(for model: String) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
    if model.hasPrefix("claude-sonnet-5") { return (2, 10, 0.2, 2.5) }
    if model.hasPrefix("claude-fable") || model.hasPrefix("claude-mythos") { return (10, 50, 0.25, 12.5) }
    return (5, 25, 0.5, 6.25)
  }

  @discardableResult
  func recordAnswer(model: String, usage: ClaudeClient.Usage) -> Double {
    rollover()
    let p = Self.price(for: model)
    let cost =
      Double(usage.input) * p.input / 1_000_000
      + Double(usage.cacheRead) * p.cacheRead / 1_000_000
      + Double(usage.cacheWrite) * p.cacheWrite / 1_000_000
      + Double(usage.output) * p.output / 1_000_000
      + Double(usage.searches) * Self.searchPriceUSD
    today.questions += 1
    today.inputTokens += usage.input
    today.cacheReadTokens += usage.cacheRead
    today.cacheWriteTokens += usage.cacheWrite
    today.outputTokens += usage.output
    today.searches += usage.searches
    today.costUSD += cost
    lastAnswerCostUSD = cost
    save()
    return cost
  }

  func recordEleven(characters: Int, model: String) {
    rollover()
    let perChar = (model.contains("flash") || model.contains("turbo")) ? 0.5 : 1.0
    today.elevenCredits += Double(characters) * perChar
    save()
  }

  static func formatUSD(_ value: Double) -> String {
    value < 0.01 ? String(format: "%.3f $", value) : String(format: "%.2f $", value)
  }

  private func rollover() {
    if today.date != Self.todayKey() {
      today = Day(date: Self.todayKey())
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(today) {
      d.set(data, forKey: key)
    }
  }
}
