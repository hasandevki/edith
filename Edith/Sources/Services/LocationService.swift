import CoreLocation
import Foundation
import Observation

/// Telefonun konumu ve adres çözümlemesi. Dinleme başlayınca açılır.
@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
  static let shared = LocationService()

  private(set) var location: CLLocation?
  private(set) var placemark: CLPlacemark?
  private(set) var status: CLAuthorizationStatus = .notDetermined

  @ObservationIgnored private let manager = CLLocationManager()
  @ObservationIgnored private let geocoder = CLGeocoder()
  @ObservationIgnored private var lastGeocodedAt: Date?
  @ObservationIgnored private var lastGeocodedLocation: CLLocation?
  @ObservationIgnored private var geocoding = false
  @ObservationIgnored private var started = false

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 50
    manager.pausesLocationUpdatesAutomatically = true
    manager.showsBackgroundLocationIndicator = true
  }

  func start() {
    status = manager.authorizationStatus
    switch status {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse, .authorizedAlways:
      beginUpdates()
    default:
      log("Konum izni yok (durum \(status.rawValue)).")
    }
  }

  private func beginUpdates() {
    guard !started else { return }
    started = true
    manager.allowsBackgroundLocationUpdates = true
    manager.startUpdatingLocation()
    log("Konum güncellemeleri başladı.")
  }

  var isAuthorized: Bool {
    status == .authorizedWhenInUse || status == .authorizedAlways
  }

  // MARK: CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      self.status = status
      if self.isAuthorized {
        self.beginUpdates()
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let last = locations.last else { return }
    Task { @MainActor in self.handle(last) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in log("Konum hatası: \(error.localizedDescription)") }
  }

  private func handle(_ loc: CLLocation) {
    location = loc
    let moved = lastGeocodedLocation.map { $0.distance(from: loc) } ?? .infinity
    let stale = lastGeocodedAt.map { Date().timeIntervalSince($0) > 600 } ?? true
    if !geocoding, moved > 200 || stale {
      geocode(loc)
    }
  }

  private func geocode(_ loc: CLLocation) {
    geocoding = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.geocoding = false }
      do {
        let marks = try await self.geocoder.reverseGeocodeLocation(loc)
        self.placemark = marks.first
        self.lastGeocodedAt = Date()
        self.lastGeocodedLocation = loc
        if let summary = self.summary { log("Konum: \(summary)") }
      } catch {
        log("Adres çözümleme hatası: \(error.localizedDescription)")
      }
    }
  }

  // MARK: Çıktılar

  /// "Moda Caddesi, Kadıköy, İstanbul" gibi kısa özet.
  var summary: String? {
    guard let p = placemark else { return nil }
    let parts = [p.thoroughfare, p.subLocality, p.locality, p.administrativeArea].compactMap { $0 }
    var unique: [String] = []
    for part in parts where !unique.contains(part) { unique.append(part) }
    return unique.isEmpty ? nil : unique.joined(separator: ", ")
  }

  /// Web araması için yaklaşık konum.
  var userLocationForSearch: [String: Any]? {
    guard let p = placemark else { return nil }
    var d: [String: Any] = ["type": "approximate", "timezone": TimeZone.current.identifier]
    if let city = p.locality { d["city"] = city }
    if let region = p.administrativeArea { d["region"] = region }
    if let country = p.isoCountryCode { d["country"] = country }
    return d
  }

  func describeForTool() -> String {
    guard let loc = location else {
      return isAuthorized ? "Konum henüz alınamadı, birkaç saniye sonra tekrar dene." : "Konum bilinmiyor; konum izni verilmemiş."
    }
    var lines: [String] = []
    lines.append(String(format: "Koordinat: %.5f, %.5f (doğruluk ±%.0f m, %.0f sn önce)", loc.coordinate.latitude, loc.coordinate.longitude, loc.horizontalAccuracy, Date().timeIntervalSince(loc.timestamp)))
    if let p = placemark {
      let address = [p.name, p.thoroughfare, p.subLocality, p.locality, p.administrativeArea, p.postalCode, p.country].compactMap { $0 }
      var unique: [String] = []
      for part in address where !unique.contains(part) { unique.append(part) }
      lines.append("Adres: " + unique.joined(separator: ", "))
    }
    if loc.speed > 0.5 {
      lines.append(String(format: "Hız: %.0f km/sa", loc.speed * 3.6))
    }
    return lines.joined(separator: "\n")
  }
}
