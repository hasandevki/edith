import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

/// Spotify Web API: PKCE ile giriş, arama, oynatma ve kontrol.
/// Uzaktan oynatma için Spotify Premium gerekir; hedef cihaz telefondaki Spotify uygulamasıdır.
@Observable
@MainActor
final class SpotifyService: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = SpotifyService()

  struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private(set) var isConnected: Bool
  private(set) var lastStatus = ""

  @ObservationIgnored private var accessToken: String
  @ObservationIgnored private var refreshToken: String
  @ObservationIgnored private var expiresAt: Date
  @ObservationIgnored private var session: ASWebAuthenticationSession?

  private let redirectURI = "edith://spotify-callback"
  private let scopes = "user-modify-playback-state user-read-playback-state user-read-currently-playing"

  private override init() {
    accessToken = Keychain.get("spotify_access") ?? ""
    refreshToken = Keychain.get("spotify_refresh") ?? ""
    expiresAt = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "spotifyExpiresAt"))
    isConnected = !(Keychain.get("spotify_refresh") ?? "").isEmpty
    super.init()
  }

  // MARK: Giriş (PKCE)

  func connect(clientId: String) async throws {
    guard !clientId.isEmpty else { throw APIError(message: "Spotify Client ID girilmemiş.") }
    let verifier = Self.randomString(64)
    let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "scope", value: scopes),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "state", value: Self.randomString(16)),
    ]
    let authURL = components.url!

    let callback: URL = try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "edith") { url, error in
        if let url { continuation.resume(returning: url) } else {
          continuation.resume(throwing: APIError(message: error?.localizedDescription ?? "Giriş iptal edildi."))
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      if !session.start() {
        continuation.resume(throwing: APIError(message: "Giriş penceresi açılamadı."))
      }
    }
    guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
      throw APIError(message: "Spotify kod döndürmedi.")
    }
    try await exchange(form: [
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirectURI,
      "client_id": clientId,
      "code_verifier": verifier,
    ])
    log("Spotify bağlandı.")
  }

  func disconnect() {
    accessToken = ""
    refreshToken = ""
    expiresAt = .distantPast
    Keychain.set("", account: "spotify_access")
    Keychain.set("", account: "spotify_refresh")
    isConnected = false
  }

  private func exchange(form: [String: String]) async throws {
    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
      .joined(separator: "&").data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = json["access_token"] as? String
    else {
      throw APIError(message: "Spotify token hatası (HTTP \(status)): \(String(decoding: data.prefix(200), as: UTF8.self))")
    }
    accessToken = token
    if let refresh = json["refresh_token"] as? String { refreshToken = refresh }
    let expires = json["expires_in"] as? Double ?? 3600
    expiresAt = Date().addingTimeInterval(expires - 60)
    Keychain.set(accessToken, account: "spotify_access")
    Keychain.set(refreshToken, account: "spotify_refresh")
    UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: "spotifyExpiresAt")
    isConnected = !refreshToken.isEmpty
  }

  private func validToken() async throws -> String {
    guard !refreshToken.isEmpty else { throw APIError(message: "Spotify bağlı değil. Ayarlardan Spotify'a bağlan.") }
    if Date() < expiresAt, !accessToken.isEmpty { return accessToken }
    try await exchange(form: [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": Settings.shared.spotifyClientId,
    ])
    return accessToken
  }

  // MARK: API

  private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> (Data, Int) {
    let token = try await validToken()
    var components = URLComponents(string: "https://api.spotify.com" + path)!
    if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  struct Item {
    let name: String
    let detail: String
    let uri: String
    let isTrack: Bool
  }

  func search(_ query: String, kind: String) async throws -> Item? {
    let types = kind == "any" ? "track,artist,album,playlist" : kind
    let (data, status) = try await request("GET", "/v1/search", query: ["q": query, "type": types, "limit": "3"])
    guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw APIError(message: "Spotify arama hatası (HTTP \(status)): \(Self.spotifyMessage(data))")
    }
    func first(_ key: String) -> [String: Any]? {
      ((json[key] as? [String: Any])?["items"] as? [[String: Any]])?.first { $0["uri"] != nil }
    }
    let order = kind == "any" ? ["tracks", "artists", "albums", "playlists"] : ["\(kind)s"]
    for key in order {
      guard let item = first(key), let name = item["name"] as? String, let uri = item["uri"] as? String else { continue }
      let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
      let owner = (item["owner"] as? [String: Any])?["display_name"] as? String ?? ""
      let detail = !artists.isEmpty ? artists : (!owner.isEmpty ? owner : key)
      return Item(name: name, detail: detail, uri: uri, isTrack: key == "tracks")
    }
    return nil
  }

  /// Telefondaki Spotify'ı hedefler; kapalıysa açıp tekrar dener.
  private func deviceId() async throws -> String? {
    let (data, status) = try await request("GET", "/v1/me/player/devices")
    guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let devices = json["devices"] as? [[String: Any]]
    else { return nil }
    if let active = devices.first(where: { $0["is_active"] as? Bool == true }) { return active["id"] as? String }
    if let phone = devices.first(where: { ($0["type"] as? String)?.lowercased() == "smartphone" }) { return phone["id"] as? String }
    return devices.first?["id"] as? String
  }

  func play(_ item: Item) async throws -> String {
    var device = try await deviceId()
    if device == nil, let url = URL(string: "spotify:") {
      _ = await UIApplication.shared.open(url)
      try? await Task.sleep(for: .seconds(3))
      device = try await deviceId()
    }
    let body: [String: Any] = item.isTrack ? ["uris": [item.uri]] : ["context_uri": item.uri]
    let (data, status) = try await request("PUT", "/v1/me/player/play", query: device.map { ["device_id": $0] } ?? [:], body: body)
    switch status {
    case 200, 202, 204:
      lastStatus = "Çalıyor: \(item.name) — \(item.detail)"
      return lastStatus
    case 403:
      let reason = Self.spotifyMessage(data)
      log("Spotify 403: \(reason)")
      return "Spotify uzaktan oynatmayı reddetti: \(reason). (Premium yoksa ya da giriş yapılan hesap dashboard'daki hesap değilse olur.)"
    case 404:
      return "Spotify'da aktif cihaz yok. Spotify uygulamasını bir kez açıp bir şey çal, sonra tekrar dene."
    default:
      let reason = Self.spotifyMessage(data)
      log("Spotify \(status): \(reason)")
      return "Spotify oynatma hatası (HTTP \(status)): \(reason)"
    }
  }

  func control(_ action: String) async throws -> String {
    let (method, path): (String, String)
    switch action {
    case "pause": (method, path) = ("PUT", "/v1/me/player/pause")
    case "resume": (method, path) = ("PUT", "/v1/me/player/play")
    case "next": (method, path) = ("POST", "/v1/me/player/next")
    case "previous": (method, path) = ("POST", "/v1/me/player/previous")
    default: return "Bilinmeyen komut: \(action)"
    }
    let (data, status) = try await request(method, path)
    switch status {
    case 200, 202, 204: return "Tamam."
    case 403: return "Spotify reddetti: \(Self.spotifyMessage(data))"
    case 404: return "Spotify'da aktif cihaz yok."
    default: return "Spotify hatası (HTTP \(status)): \(Self.spotifyMessage(data))"
    }
  }

  func nowPlaying() async throws -> String {
    let (data, status) = try await request("GET", "/v1/me/player/currently-playing")
    guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let item = json["item"] as? [String: Any], let name = item["name"] as? String
    else { return "Şu an bir şey çalmıyor." }
    let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
    let playing = json["is_playing"] as? Bool ?? false
    return "\(playing ? "Çalıyor" : "Duraklatılmış"): \(name)\(artists.isEmpty ? "" : " — \(artists)")"
  }

  // MARK: Yardımcılar

  /// Spotify'ın {"error":{"status":..,"message":".."}} gövdesinden mesajı çeker.
  private static func spotifyMessage(_ data: Data) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = json["error"] as? [String: Any], let message = error["message"] as? String
    {
      return message
    }
    let raw = String(decoding: data.prefix(160), as: UTF8.self)
    return raw.isEmpty ? "(boş cevap)" : raw
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
      UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first ?? ASPresentationAnchor()
    }
  }

  private static func randomString(_ length: Int) -> String {
    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return String((0..<length).map { _ in chars.randomElement()! })
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
