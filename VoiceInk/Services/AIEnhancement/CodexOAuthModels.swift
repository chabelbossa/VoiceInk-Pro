import Foundation

enum CodexOAuthScopes {
    static let connectorsInvoke = "api.connectors.invoke"

    static let authorizationScopes = [
        "openid",
        "profile",
        "email",
        "offline_access",
        "api.connectors.read",
        connectorsInvoke
    ]

    static var authorizationScope: String {
        authorizationScopes.joined(separator: " ")
    }

    static func hasRequiredBackendScopes(_ scope: String?) -> Bool {
        guard let scope else { return false }
        return scope
            .split(separator: " ")
            .map(String.init)
            .contains(connectorsInvoke)
    }
}

enum CodexRotationStrategy: String, Codable, CaseIterable, Identifiable {
    case roundRobin = "round-robin"
    case leastUsed = "least-used"
    case random
    case weightedRoundRobin = "weighted-round-robin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .roundRobin:
            return "Round Robin"
        case .leastUsed:
            return "Least Used"
        case .random:
            return "Random"
        case .weightedRoundRobin:
            return "Weighted"
        }
    }
}

struct CodexRateLimits: Codable, Equatable {
    var dailyRemaining: Int?
    var dailyLimit: Int?
    var weeklyRemaining: Int?
    var weeklyLimit: Int?
}

struct CodexAccount: Identifiable, Codable, Equatable {
    let id: String
    var alias: String
    var email: String
    var enabled: Bool
    var disabledAt: Date? = nil
    var disableReason: String? = nil
    var expiresAt: Date
    var obtainedAt: Date
    var oauthScope: String? = nil
    var rateLimits: CodexRateLimits? = nil
    var lastLimitProbeAt: Date? = nil
    var limitStatus: String? = nil
    var rateLimitedUntil: Date? = nil
    var consecutiveErrors: Int
    var lastErrorAt: Date? = nil
    var requestCount: Int
    var weight: Double

    var hasRequiredScopes: Bool {
        CodexOAuthScopes.hasRequiredBackendScopes(oauthScope)
    }
}

struct CodexMultiAuthSettings: Codable, Equatable {
    var rotationStrategy: CodexRotationStrategy
    var forcedAlias: String? = nil
    var forcedUntil: Date? = nil
    var previousStrategy: CodexRotationStrategy? = nil
    var criticalThreshold: Int
    var lowThreshold: Int

    static let `default` = CodexMultiAuthSettings(
        rotationStrategy: .roundRobin,
        criticalThreshold: 10,
        lowThreshold: 25
    )
}

struct CodexAuthDraft {
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var expiresAt: Date
    var oauthScope: String?
}

struct CodexAccountSecret {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
}

struct CodexAccountSelection {
    var account: CodexAccount
    var reason: String
    var forced: Bool
}

enum CodexTokenRefreshResult {
    case valid
    case refreshed
    case missingSecret
    case temporaryFailure(String)
    case reauthRequired(String)

    var isUsable: Bool {
        switch self {
        case .valid, .refreshed:
            return true
        case .missingSecret, .temporaryFailure, .reauthRequired:
            return false
        }
    }

    var message: String? {
        switch self {
        case .valid, .refreshed:
            return nil
        case .missingSecret:
            return "Missing OAuth token secrets."
        case .temporaryFailure(let message), .reauthRequired(let message):
            return message
        }
    }
}

struct CodexHealthAccount: Identifiable, Equatable {
    var id: String { alias }
    var alias: String
    var email: String
    var enabled: Bool
    var eligible: Bool
    var healthScore: Int
    var requestCount: Int
    var rateLimitedUntil: Date?
    var cooldownReason: String?
    var limitStatus: String
}

struct CodexHealthReport: Equatable {
    var totalAccounts: Int
    var enabledAccounts: Int
    var healthyAccounts: Int
    var rateLimitedAccounts: Int
    var coolingDownAccounts: Int
    var forcedAlias: String?
    var currentStrategy: CodexRotationStrategy
    var accounts: [CodexHealthAccount]
}

enum CodexOAuthError: LocalizedError {
    case callbackServerUnavailable
    case timeout
    case tokenExchangeFailed(String)
    case invalidTokenResponse
    case missingRefreshToken
    case missingScope(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .callbackServerUnavailable:
            return "Could not start the local OAuth callback server on port 1455."
        case .timeout:
            return "OAuth login timed out or was cancelled."
        case .tokenExchangeFailed(let message):
            return "OAuth token exchange failed: \(message)"
        case .invalidTokenResponse:
            return "OAuth token response was missing required fields."
        case .missingRefreshToken:
            return "OAuth refresh response did not include a usable refresh token."
        case .missingScope(let scope):
            return "OAuth login did not grant the required \(scope) scope. Re-authenticate the account and approve the requested access."
        case .network(let message):
            return message
        }
    }
}

enum CodexClientError: LocalizedError {
    case notConfigured
    case noEligibleAccounts(String)
    case allAccountsExhausted(String)
    case missingScope(String)
    case apiError(statusCode: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No Codex OAuth account configured."
        case .noEligibleAccounts(let message):
            return message
        case .allAccountsExhausted(let message):
            return message
        case .missingScope(let message):
            return message
        case .apiError(let statusCode, let message):
            return "Codex API error \(statusCode): \(message)"
        case .invalidResponse:
            return "Codex API returned an unexpected response."
        }
    }
}
