import AppKit
import CryptoKit
import Foundation
import Network
import os
import Security

private struct CodexAuthorizationFlow {
    let verifier: String
    let state: String
    let url: URL
}

private struct CodexTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double
    let idToken: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
        case scope
    }
}

private struct CodexJWTPayload: Decodable {
    let email: String?
}

enum CodexOAuthFlow {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexOAuthFlow")
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let callbackPort: UInt16 = 1455
    private static let callbackPath = "/auth/callback"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scopes = CodexOAuthScopes.authorizationScope

    static func run(forceNewLogin: Bool = true) async throws -> CodexAuthDraft {
        let flow = try createAuthorizationFlow(forceNewLogin: forceNewLogin)
        let server = CodexOAuthCallbackServer(state: flow.state, port: callbackPort, callbackPath: callbackPath)
        try await server.start()
        defer { server.stop() }

        NSWorkspace.shared.open(flow.url)

        guard let code = await server.waitForCode(timeout: 300) else {
            throw CodexOAuthError.timeout
        }

        let token = try await exchangeAuthorizationCode(code: code, verifier: flow.verifier)
        try validateRequiredScopes(token.scope)
        let email = decodeEmail(fromIDToken: token.idToken) ?? "unknown"
        return CodexAuthDraft(
            email: email,
            accessToken: token.accessToken,
            refreshToken: token.refreshToken ?? "",
            idToken: token.idToken,
            expiresAt: Date().addingTimeInterval(token.expiresIn),
            oauthScope: token.scope
        )
    }

    static func refreshAccessToken(_ refreshToken: String) async throws -> CodexAuthDraft {
        let body = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
        let token = try await requestToken(body: body)
        if let scope = token.scope {
            try validateRequiredScopes(scope)
        }
        let nextRefresh = token.refreshToken ?? refreshToken
        guard !nextRefresh.isEmpty else {
            throw CodexOAuthError.missingRefreshToken
        }
        return CodexAuthDraft(
            email: decodeEmail(fromIDToken: token.idToken) ?? "unknown",
            accessToken: token.accessToken,
            refreshToken: nextRefresh,
            idToken: token.idToken,
            expiresAt: Date().addingTimeInterval(token.expiresIn),
            oauthScope: token.scope
        )
    }

    private static func validateRequiredScopes(_ scope: String?) throws {
        guard CodexOAuthScopes.hasRequiredBackendScopes(scope) else {
            throw CodexOAuthError.missingScope(CodexOAuthScopes.connectorsInvoke)
        }
    }

    private static func createAuthorizationFlow(forceNewLogin: Bool) throws -> CodexAuthorizationFlow {
        let verifier = try randomBase64URL(byteCount: 64)
        let challenge = sha256Base64URL(verifier)
        let state = try randomHex(byteCount: 16)

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs")
        ]
        if forceNewLogin {
            items.append(URLQueryItem(name: "prompt", value: "login"))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw CodexOAuthError.network("Could not build OAuth authorization URL.")
        }
        return CodexAuthorizationFlow(verifier: verifier, state: state, url: url)
    }

    private static func exchangeAuthorizationCode(code: String, verifier: String) async throws -> CodexTokenResponse {
        let body = formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ])
        let token = try await requestToken(body: body)
        guard token.refreshToken?.isEmpty == false else {
            throw CodexOAuthError.missingRefreshToken
        }
        return token
    }

    private static func requestToken(body: Data) async throws -> CodexTokenResponse {
        let maxAttempts = 4
        var delay: TimeInterval = 1
        var lastNetworkMessage: String?

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                lastNetworkMessage = error.localizedDescription
                guard attempt < maxAttempts, isRetryableNetworkError(error) else {
                    throw CodexOAuthError.network(error.localizedDescription)
                }
                logger.warning("Token request network failure, retrying after connectivity wait. Attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
                await waitForNetworkRecovery(maxWait: min(60, max(5, delay * 4)))
                delay *= 2
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexOAuthError.invalidTokenResponse
            }

            if (200..<300).contains(httpResponse.statusCode) {
                do {
                    return try JSONDecoder().decode(CodexTokenResponse.self, from: data)
                } catch {
                    logger.error("Token response decoding failed: \(error.localizedDescription, privacy: .public)")
                    throw CodexOAuthError.invalidTokenResponse
                }
            }

            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            if attempt < maxAttempts, isRetryableTokenStatus(httpResponse.statusCode) {
                let retryDelay = retryAfterSeconds(from: httpResponse) ?? delay
                logger.warning("Token request returned retryable HTTP \(httpResponse.statusCode, privacy: .public), retrying in \(retryDelay, privacy: .public)s")
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                delay *= 2
                continue
            }

            logger.error("Token request failed: \(httpResponse.statusCode, privacy: .public)")
            throw CodexOAuthError.tokenExchangeFailed(message)
        }

        throw CodexOAuthError.network(lastNetworkMessage ?? "Token request failed after retries.")
    }

    private static func isRetryableTokenStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        return [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorDataNotAllowed
        ].contains(nsError.code)
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        return TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func waitForNetworkRecovery(maxWait: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000))
    }

    private static func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    private static func decodeEmail(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let payload = try? JSONDecoder().decode(CodexJWTPayload.self, from: payloadData) else {
            return nil
        }
        return payload.email?.lowercased()
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw CodexOAuthError.network("Could not generate secure random bytes.")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func randomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw CodexOAuthError.network("Could not generate secure random bytes.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private final class CodexOAuthCallbackServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexOAuthCallbackServer")
    private let state: String
    private let port: UInt16
    private let callbackPath: String
    private let queue = DispatchQueue(label: "voiceink.codex.oauth.callback")
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var codeContinuation: CheckedContinuation<String?, Never>?
    private var completedCode: String?
    private var stopped = false

    init(state: String, port: UInt16, callbackPath: String) {
        self.state = state
        self.port = port
        self.callbackPath = callbackPath
    }

    func start() async throws {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: .tcp, on: endpointPort)
        self.listener = listener

        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.startContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: self.queue)
            }
        }
    }

    func waitForCode(timeout: TimeInterval) async -> String? {
        if let completedCode {
            return completedCode
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                if let completedCode = self.completedCode {
                    continuation.resume(returning: completedCode)
                    return
                }
                self.codeContinuation = continuation
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish(with: nil)
            }
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            if let continuation = self.codeContinuation {
                self.codeContinuation = nil
                continuation.resume(returning: nil)
            }
            if let continuation = self.startContinuation {
                self.startContinuation = nil
                continuation.resume(throwing: CodexOAuthError.callbackServerUnavailable)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            resolveStart(.success(()))
        case .failed(let error):
            logger.error("OAuth callback listener failed: \(error.localizedDescription, privacy: .public)")
            resolveStart(.failure(CodexOAuthError.callbackServerUnavailable))
            finish(with: nil)
        case .cancelled:
            resolveStart(.failure(CodexOAuthError.callbackServerUnavailable))
        default:
            break
        }
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.send(status: 400, body: "Bad request", on: connection)
                return
            }
            self.handleRequest(request, connection: connection)
        }
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            send(status: 400, body: "Bad request", on: connection)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(status: 400, body: "Bad request", on: connection)
            return
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)"),
              components.path == callbackPath else {
            send(status: 404, body: "Not found", on: connection)
            return
        }

        guard components.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            send(status: 400, body: "State mismatch", on: connection)
            return
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            send(status: 400, body: "Missing authorization code", on: connection)
            return
        }

        send(status: 200, body: Self.successHTML, contentType: "text/html; charset=utf-8", on: connection)
        finish(with: code)
    }

    private func finish(with code: String?) {
        queue.async {
            if let code, self.completedCode == nil {
                self.completedCode = code
            }
            guard let continuation = self.codeContinuation else { return }
            self.codeContinuation = nil
            continuation.resume(returning: code ?? self.completedCode)
        }
    }

    private func send(status: Int, body: String, contentType: String = "text/plain; charset=utf-8", on connection: NWConnection) {
        let statusText = status == 200 ? "OK" : "Error"
        let bodyData = body.data(using: .utf8) ?? Data()
        let headers = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(bodyData.count)\r
        X-Frame-Options: DENY\r
        X-Content-Type-Options: nosniff\r
        Content-Security-Policy: default-src 'self'; script-src 'none'\r
        Connection: close\r
        \r

        """
        var responseData = headers.data(using: .utf8) ?? Data()
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let successHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Authentication Successful</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background: #0d0d0d; color: #fff; }
        main { text-align: center; padding: 32px; border-radius: 12px; background: #1a1a1a; box-shadow: 0 8px 40px rgba(0,0,0,0.35); }
        h1 { margin: 0 0 8px; font-size: 22px; }
        p { margin: 0; color: #aaa; }
      </style>
    </head>
    <body>
      <main>
        <h1>Authentication Successful</h1>
        <p>You can close this window and return to VoiceInk Pro.</p>
      </main>
    </body>
    </html>
    """
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
