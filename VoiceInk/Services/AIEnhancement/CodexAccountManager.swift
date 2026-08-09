import Foundation
import os

private struct CodexAccountsMetadata: Codable {
    var accounts: [CodexAccount]
    var settings: CodexMultiAuthSettings
}

actor CodexAccountManager {
    static let shared = CodexAccountManager()

    private static let accountCountDefaultsKey = "CodexOAuthAccountCount"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexAccountManager")
    private let keychain = KeychainService.shared
    private var accounts: [CodexAccount] = []
    private var settings: CodexMultiAuthSettings = .default

    private nonisolated static var metadataURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("codex_oauth_accounts.json")
    }

    private var metadataURL: URL {
        Self.metadataURL
    }

    private init() {
        let url = Self.metadataURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.set(0, forKey: Self.accountCountDefaultsKey)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(CodexAccountsMetadata.self, from: data)
            accounts = metadata.accounts
            settings = metadata.settings
            UserDefaults.standard.set(accounts.count, forKey: Self.accountCountDefaultsKey)
        } catch {
            logger.error("Failed to load Codex OAuth metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func storedAccountCount() -> Int {
        UserDefaults.standard.integer(forKey: accountCountDefaultsKey)
    }

    func getAccounts() -> [CodexAccount] {
        accounts
    }

    func getEnabledAccounts() -> [CodexAccount] {
        accounts.filter(\.enabled)
    }

    func getAccount(alias: String) -> CodexAccount? {
        accounts.first { $0.alias == alias }
    }

    func accountCount() -> Int {
        accounts.count
    }

    func hasAnyAccount() -> Bool {
        accounts.contains { $0.enabled }
    }

    func getSettings() -> CodexMultiAuthSettings {
        settings
    }

    func setSettings(_ patch: CodexMultiAuthSettings) {
        settings = patch
        persist()
    }

    func updateSettings(_ update: (inout CodexMultiAuthSettings) -> Void) {
        update(&settings)
        persist()
    }

    func addAccount(alias rawAlias: String, draft: CodexAuthDraft) throws -> CodexAccount {
        let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else {
            throw CodexClientError.noEligibleAccounts("Account alias cannot be empty.")
        }
        guard !accounts.contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) else {
            throw CodexClientError.noEligibleAccounts("An account named \(alias) already exists.")
        }

        let id = UUID().uuidString
        let account = CodexAccount(
            id: id,
            alias: alias,
            email: draft.email.lowercased(),
            enabled: true,
            expiresAt: draft.expiresAt,
            obtainedAt: Date(),
            oauthScope: draft.oauthScope,
            consecutiveErrors: 0,
            requestCount: 0,
            weight: 1.0
        )
        saveSecrets(draft, forAccountID: id)
        accounts.append(account)
        persist()
        logger.info("Added Codex OAuth account: \(alias, privacy: .public)")
        return account
    }

    func removeAccount(alias: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.alias == alias }) else {
            return false
        }
        let account = accounts.remove(at: index)
        deleteSecrets(forAccountID: account.id)
        if settings.forcedAlias == alias {
            settings.forcedAlias = nil
            settings.forcedUntil = nil
            settings.previousStrategy = nil
        }
        persist()
        return true
    }

    func setAccountEnabled(alias: String, enabled: Bool) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.alias == alias }) else {
            return false
        }
        accounts[index].enabled = enabled
        accounts[index].disabledAt = enabled ? nil : Date()
        if enabled {
            accounts[index].disableReason = nil
            accounts[index].consecutiveErrors = 0
        }
        persist()
        return true
    }

    func updateAccount(alias: String, patch: (inout CodexAccount) -> Void) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.alias == alias }) else {
            return false
        }
        patch(&accounts[index])
        persist()
        return true
    }

    func reauthAccount(alias: String, draft: CodexAuthDraft) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.alias == alias }) else {
            return false
        }
        saveSecrets(draft, forAccountID: accounts[index].id)
        accounts[index].email = draft.email.lowercased()
        accounts[index].expiresAt = draft.expiresAt
        accounts[index].obtainedAt = Date()
        accounts[index].oauthScope = draft.oauthScope
        accounts[index].consecutiveErrors = 0
        accounts[index].lastErrorAt = nil
        accounts[index].enabled = true
        accounts[index].disabledAt = nil
        accounts[index].disableReason = nil
        accounts[index].rateLimitedUntil = nil
        accounts[index].limitStatus = nil
        persist()
        return true
    }

    func markAccountNeedsReauth(alias: String, reason: String) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.alias == alias }) else {
            return false
        }
        accounts[index].enabled = false
        accounts[index].disabledAt = Date()
        accounts[index].disableReason = reason
        accounts[index].consecutiveErrors = 3
        accounts[index].lastErrorAt = Date()
        accounts[index].limitStatus = "missing-scope"
        persist()
        return true
    }

    func secret(for account: CodexAccount) -> CodexAccountSecret? {
        guard let accessToken = keychain.getString(forKey: accessTokenKey(for: account.id), syncable: false),
              let refreshToken = keychain.getString(forKey: refreshTokenKey(for: account.id), syncable: false) else {
            return nil
        }
        return CodexAccountSecret(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: keychain.getString(forKey: idTokenKey(for: account.id), syncable: false)
        )
    }

    func refreshTokenIfNeeded(alias: String) async -> Bool {
        await ensureFreshToken(alias: alias).isUsable
    }

    func forceRefreshToken(alias: String) async -> CodexTokenRefreshResult {
        await ensureFreshToken(alias: alias, force: true)
    }

    func refreshRecoverableAccounts() async {
        let refreshThreshold = Date().addingTimeInterval(5 * 60)
        let aliases = accounts
            .filter { $0.enabled && $0.hasRequiredScopes && $0.expiresAt <= refreshThreshold }
            .map(\.alias)

        for alias in aliases {
            _ = await ensureFreshToken(alias: alias)
        }
    }

    func ensureFreshToken(alias: String, force: Bool = false) async -> CodexTokenRefreshResult {
        guard let account = getAccount(alias: alias),
              let secret = secret(for: account) else {
            return .missingSecret
        }

        let fiveMinutes: TimeInterval = 5 * 60
        if !force, account.expiresAt.timeIntervalSinceNow > fiveMinutes {
            return .valid
        }

        do {
            let draft = try await CodexOAuthFlow.refreshAccessToken(secret.refreshToken)
            let updated = reauthAccount(alias: alias, draft: CodexAuthDraft(
                email: draft.email == "unknown" ? account.email : draft.email,
                accessToken: draft.accessToken,
                refreshToken: draft.refreshToken,
                idToken: draft.idToken ?? secret.idToken,
                expiresAt: draft.expiresAt,
                oauthScope: draft.oauthScope ?? account.oauthScope
            ))
            return updated ? .refreshed : .missingSecret
        } catch {
            let message = error.localizedDescription
            if refreshFailureRequiresReauth(error) {
                _ = updateAccount(alias: alias) { account in
                    account.enabled = false
                    account.disabledAt = Date()
                    account.disableReason = "Token refresh failed permanently. Re-auth required."
                    account.consecutiveErrors = 3
                    account.lastErrorAt = Date()
                    account.limitStatus = "token-refresh-required"
                }
                logger.error("Token refresh requires re-auth for \(alias, privacy: .public): \(message, privacy: .public)")
                return .reauthRequired(message)
            }

            _ = updateAccount(alias: alias) { account in
                account.consecutiveErrors += 1
                account.lastErrorAt = Date()
                account.limitStatus = "refresh-retryable"
            }
            logger.warning("Temporary token refresh failure for \(alias, privacy: .public): \(message, privacy: .public)")
            return .temporaryFailure(message)
        }
    }

    private func refreshFailureRequiresReauth(_ error: Error) -> Bool {
        guard let oauthError = error as? CodexOAuthError else {
            return false
        }

        switch oauthError {
        case .missingRefreshToken, .missingScope:
            return true
        case .tokenExchangeFailed(let message):
            let lowered = message.lowercased()
            return lowered.contains("invalid_grant")
                || lowered.contains("invalid refresh")
                || lowered.contains("expired")
                || lowered.contains("revoked")
                || lowered.contains("unauthorized")
        case .callbackServerUnavailable, .timeout, .invalidTokenResponse, .network:
            return false
        }
    }

    private func load() {
        let url = metadataURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.set(0, forKey: Self.accountCountDefaultsKey)
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(CodexAccountsMetadata.self, from: data)
            accounts = metadata.accounts
            settings = metadata.settings
            UserDefaults.standard.set(accounts.count, forKey: Self.accountCountDefaultsKey)
        } catch {
            logger.error("Failed to load Codex OAuth metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(CodexAccountsMetadata(accounts: accounts, settings: settings))
            try data.write(to: metadataURL, options: .atomic)
            UserDefaults.standard.set(accounts.count, forKey: Self.accountCountDefaultsKey)
        } catch {
            logger.error("Failed to persist Codex OAuth metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveSecrets(_ draft: CodexAuthDraft, forAccountID id: String) {
        keychain.save(draft.accessToken, forKey: accessTokenKey(for: id), syncable: false)
        keychain.save(draft.refreshToken, forKey: refreshTokenKey(for: id), syncable: false)
        if let idToken = draft.idToken {
            keychain.save(idToken, forKey: idTokenKey(for: id), syncable: false)
        } else {
            keychain.delete(forKey: idTokenKey(for: id), syncable: false)
        }
    }

    private func deleteSecrets(forAccountID id: String) {
        keychain.delete(forKey: accessTokenKey(for: id), syncable: false)
        keychain.delete(forKey: refreshTokenKey(for: id), syncable: false)
        keychain.delete(forKey: idTokenKey(for: id), syncable: false)
    }

    private func accessTokenKey(for id: String) -> String {
        "codex_\(id)_accessToken"
    }

    private func refreshTokenKey(for id: String) -> String {
        "codex_\(id)_refreshToken"
    }

    private func idTokenKey(for id: String) -> String {
        "codex_\(id)_idToken"
    }
}
