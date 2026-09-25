import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

// Signing in to Google for Drive sync.
//
// The web app runs the OAuth web-server flow and keeps the refresh token in an
// encrypted cookie (src/lib/google-server.ts). A Mac app cannot hold a client
// secret, so this is the installed-app flow instead: an "iOS" OAuth client (no
// secret), PKCE, and Google's page in an ASWebAuthenticationSession. The
// refresh token is kept in this Mac's Keychain; access tokens live in memory
// and last an hour.
//
// The client must be in the same Google Cloud project as the web app's: Drive's
// appDataFolder belongs to the project, so that is what lets both see one file.

@MainActor
final class GoogleAuth: NSObject {
    static let shared = GoogleAuth()

    /// Who is signed in. Not a secret, so it is kept in the app's preferences.
    struct Account: Codable, Equatable {
        var email: String?
        /// First name, used to fill in "Your name" when it's empty.
        var name: String?
    }

    enum AuthError: LocalizedError {
        case notConfigured
        /// The saved sign-in no longer works: sign in again.
        case notConnected(String)
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Google sync isn't set up in this build of Four Notes."
            case .notConnected(let message), .failed(let message): return message
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    static let driveScope = "https://www.googleapis.com/auth/drive.appdata"
    // "profile" gives the account's name, as on the web.
    static let scopes = ["openid", "email", "profile", driveScope]

    /// GOOGLE_CLIENT_ID in project.yml, stamped into Info.plist. Not a secret:
    /// an installed app's client ID ships inside the app either way.
    static var clientId: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "FNGoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc",
    /// the scheme Google redirects an iOS client to.
    nonisolated static func redirectScheme(for clientId: String) -> String {
        let suffix = ".apps.googleusercontent.com"
        let id = clientId.hasSuffix(suffix) ? String(clientId.dropLast(suffix.count)) : clientId
        return "com.googleusercontent.apps.\(id)"
    }

    private static let accountKey = "fournotes.google.account"
    private static let keychainService = "com.fournotes.mac.google"
    private static let keychainAccount = "refreshToken"

    private var accessToken: (value: String, expires: Date)?
    private var session: ASWebAuthenticationSession?

    var account: Account? {
        guard !AppModel.isTesting, let data = UserDefaults.standard.data(forKey: Self.accountKey) else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    // MARK: - Sign in

    /// Shows Google's sign-in page and keeps the refresh token.
    func signIn() async throws -> Account {
        guard let clientId = Self.clientId else { throw AuthError.notConfigured }
        let scheme = Self.redirectScheme(for: clientId)
        let redirectURI = "\(scheme):/oauth2redirect"
        let verifier = Self.randomToken()
        let state = Self.randomToken()

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            // Consent every time, so Google always returns a refresh token.
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "state", value: state),
        ]

        let callback = try await present(components.url!, scheme: scheme)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        if let error = value("error") {
            throw error == "access_denied" ? AuthError.cancelled : AuthError.failed("Google sign-in failed (\(error)).")
        }
        guard value("state") == state, let code = value("code") else {
            throw AuthError.failed("Google sign-in couldn't be completed. Try again.")
        }

        let token = try await Self.tokenRequest([
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard token.scope?.split(separator: " ").contains(Substring(Self.driveScope)) == true else {
            throw AuthError.failed("Google Drive access wasn't allowed. Connect again and tick the Google Drive permission.")
        }
        guard let refresh = token.refresh_token, Self.writeRefreshToken(refresh) else {
            throw AuthError.failed("Google didn't allow offline access, so sync can't continue on its own. Try again.")
        }

        let account = Self.profile(fromIdToken: token.id_token)
        UserDefaults.standard.set(try? JSONEncoder().encode(account), forKey: Self.accountKey)
        accessToken = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60))
        return account
    }

    private func present(_ url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme),
                                                     completionHandler: Self.completion(continuation))
            session.presentationContextProvider = self
            // Share the browser's Google sign-in, so an account already signed in is one click.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.failed("Google sign-in couldn't open."))
            }
        }
    }

    /// The session calls back on a queue of its own, not the main thread. A
    /// closure written inside `present` would be main-actor isolated, and
    /// Swift traps when it runs anywhere else — which ended every sign-in the
    /// moment Google handed back. Made here, outside the actor, it isn't.
    nonisolated private static func completion(
        _ continuation: CheckedContinuation<URL, Error>
    ) -> @Sendable (URL?, Error?) -> Void {
        { url, error in
            if let url {
                continuation.resume(returning: url)
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                continuation.resume(throwing: AuthError.cancelled)
            } else {
                continuation.resume(throwing: AuthError.failed(
                    "Google sign-in couldn't open (\(error?.localizedDescription ?? "unknown error"))."))
            }
        }
    }

    // MARK: - Tokens

    /// A current access token, refreshed when it has expired or `force` is set
    /// (Drive said the cached one was no longer accepted).
    func token(force: Bool = false) async throws -> String {
        if !force, let accessToken, accessToken.expires > Date() { return accessToken.value }
        guard let clientId = Self.clientId else { throw AuthError.notConfigured }
        guard let refresh = Self.readRefreshToken() else {
            throw AuthError.notConnected("Not connected to Google on this Mac.")
        }
        do {
            let token = try await Self.tokenRequest([
                "client_id": clientId,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            accessToken = (token.access_token, Date().addingTimeInterval(TimeInterval(token.expires_in ?? 3600) - 60))
            return token.access_token
        } catch TokenError.invalidGrant {
            forget()
            throw AuthError.notConnected("Google access was removed or has expired. Connect again.")
        }
    }

    /// Revokes this Mac's access and forgets the sign-in.
    func signOut() async {
        if let refresh = Self.readRefreshToken() {
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": refresh])
            _ = try? await URLSession.shared.data(for: request)
        }
        forget()
    }

    private func forget() {
        accessToken = nil
        Self.deleteRefreshToken()
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
    }

    private enum TokenError: Error { case invalidGrant }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int?
        var refresh_token: String?
        var id_token: String?
        var scope: String?
    }

    private static func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(params)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.failed("Couldn't reach Google. Sync will retry soon.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status), let token = try? JSONDecoder().decode(TokenResponse.self, from: data) {
            return token
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"] as? String
        if error == "invalid_grant" { throw TokenError.invalidGrant }
        let description = body?["error_description"] as? String
        throw AuthError.failed("Google sign-in failed (\(description ?? error ?? "\(status)")).")
    }

    private static func form(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }

    /// The id_token comes straight from Google's token endpoint over TLS, so
    /// reading its payload without checking the signature is safe here.
    nonisolated static func profile(fromIdToken idToken: String?) -> Account {
        let parts = idToken?.split(separator: ".") ?? []
        guard parts.count >= 2 else { return Account() }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return Account() }
        // First name reads better in the daily brief greeting than the full name.
        let name = ((claims["given_name"] as? String) ?? (claims["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return Account(email: claims["email"] as? String, name: name.isEmpty ? nil : String(name.prefix(60)))
    }

    // MARK: - PKCE

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Keychain

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readRefreshToken() -> String? {
        // The test build is signed differently; reading the app's item would
        // stall the run on a password prompt.
        guard !AppModel.isTesting else { return nil }
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeRefreshToken(_ token: String) -> Bool {
        guard !AppModel.isTesting else { return false }
        deleteRefreshToken()
        var add = keychainQuery
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteRefreshToken() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}

extension GoogleAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}
