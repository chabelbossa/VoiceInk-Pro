import Foundation

private struct CodexHealthEntry {
    var score: Double
    var lastUpdated: Date
    var consecutiveFailures: Int
}

actor CodexAuthRouter {
    static let shared = CodexAuthRouter()

    private let accountManager = CodexAccountManager.shared
    private var currentRoundRobinIndex = 0
    private var healthScores: [String: CodexHealthEntry] = [:]

    private let successDelta = 1.0
    private let rateLimitDelta = -10.0
    private let failureDelta = -20.0
    private let passiveRecoveryPerHour = 2.0

    func selectAccount() async -> CodexAccountSelection? {
        var settings = await accountManager.getSettings()

        if let forcedAlias = settings.forcedAlias, let forcedUntil = settings.forcedUntil {
            if Date() < forcedUntil {
                if let forced = await accountManager.getAccount(alias: forcedAlias),
                   canAttempt(forced),
                   await accountManager.refreshTokenIfNeeded(alias: forced.alias),
                   let refreshed = await accountManager.getAccount(alias: forced.alias) {
                    return CodexAccountSelection(account: refreshed, reason: "force-mode", forced: true)
                }
                return nil
            } else {
                let previous = settings.previousStrategy
                await accountManager.updateSettings { current in
                    current.forcedAlias = nil
                    current.forcedUntil = nil
                    current.previousStrategy = nil
                    if let previous {
                        current.rotationStrategy = previous
                    }
                }
                settings = await accountManager.getSettings()
            }
        }

        let enabled = await accountManager.getEnabledAccounts()
        let candidates = enabled.filter { canAttempt($0) }
        guard !candidates.isEmpty else {
            return nil
        }

        for selected in orderedCandidates(candidates, strategy: settings.rotationStrategy) {
            let refreshResult = await accountManager.ensureFreshToken(alias: selected.alias)
            guard refreshResult.isUsable,
                  let refreshed = await accountManager.getAccount(alias: selected.alias) else {
                if case .missingSecret = refreshResult {
                    await recordAuthFailure(selected.alias)
                }
                continue
            }

            _ = await accountManager.updateAccount(alias: refreshed.alias) { account in
                account.requestCount += 1
            }
            let current = await accountManager.getAccount(alias: refreshed.alias) ?? refreshed
            return CodexAccountSelection(account: current, reason: settings.rotationStrategy.rawValue, forced: false)
        }

        return nil
    }

    func recordSuccess(_ alias: String) async {
        let entry = recoveredEntry(for: alias)
        let newScore = min(entry.score + successDelta, 100)
        healthScores[alias] = CodexHealthEntry(score: newScore, lastUpdated: Date(), consecutiveFailures: 0)
        _ = await accountManager.updateAccount(alias: alias) { account in
            account.consecutiveErrors = 0
            account.lastErrorAt = nil
        }
    }

    func recordRateLimit(_ alias: String, retryAfter: TimeInterval?) async {
        let entry = recoveredEntry(for: alias)
        let failures = entry.consecutiveFailures + 1
        healthScores[alias] = CodexHealthEntry(
            score: max(entry.score + rateLimitDelta, 0),
            lastUpdated: Date(),
            consecutiveFailures: failures
        )
        let until = Date().addingTimeInterval(retryAfter ?? 60)
        _ = await accountManager.updateAccount(alias: alias) { account in
            account.rateLimitedUntil = until
            account.consecutiveErrors = failures
            account.lastErrorAt = Date()
        }
    }

    func recordAuthFailure(_ alias: String) async {
        let entry = recoveredEntry(for: alias)
        let failures = entry.consecutiveFailures + 1
        setHealth(alias: alias, score: max(entry.score + failureDelta, 0), failures: failures)
        _ = await accountManager.updateAccount(alias: alias) { account in
            account.consecutiveErrors = failures
            account.lastErrorAt = Date()
            if failures >= 3 {
                account.enabled = false
                account.disableReason = "Too many authentication failures. Re-auth required."
            }
        }
    }

    func recordMissingScope(_ alias: String) async {
        setHealth(alias: alias, score: 0, failures: 3)
        _ = await accountManager.markAccountNeedsReauth(
            alias: alias,
            reason: "Missing \(CodexOAuthScopes.connectorsInvoke) scope. Re-auth required."
        )
    }

    func recordServerError(_ alias: String) async {
        let entry = recoveredEntry(for: alias)
        let failures = entry.consecutiveFailures + 1
        healthScores[alias] = CodexHealthEntry(score: max(entry.score - 5, 0), lastUpdated: Date(), consecutiveFailures: failures)
        _ = await accountManager.updateAccount(alias: alias) { account in
            account.consecutiveErrors = failures
            account.lastErrorAt = Date()
        }
    }

    func updateLimitsFromHeaders(alias: String, headers: [AnyHashable: Any]) async {
        let dailyRemaining = intHeader(headers, "x-ratelimit-remaining-requests")
        let dailyLimit = intHeader(headers, "x-ratelimit-limit-requests")
        guard dailyRemaining != nil || dailyLimit != nil else {
            return
        }
        _ = await accountManager.updateAccount(alias: alias) { account in
            account.rateLimits = CodexRateLimits(
                dailyRemaining: dailyRemaining,
                dailyLimit: dailyLimit,
                weeklyRemaining: account.rateLimits?.weeklyRemaining,
                weeklyLimit: account.rateLimits?.weeklyLimit
            )
            account.lastLimitProbeAt = Date()
            account.limitStatus = "fresh"
        }
    }

    func setForceMode(alias: String, hours: Double = 24) async -> Bool {
        guard let account = await accountManager.getAccount(alias: alias), account.enabled else {
            return false
        }
        let settings = await accountManager.getSettings()
        await accountManager.updateSettings { current in
            current.forcedAlias = alias
            current.forcedUntil = Date().addingTimeInterval(hours * 60 * 60)
            current.previousStrategy = settings.rotationStrategy
        }
        return true
    }

    func clearForceMode() async {
        await accountManager.updateSettings { current in
            let previous = current.previousStrategy
            current.forcedAlias = nil
            current.forcedUntil = nil
            current.previousStrategy = nil
            if let previous {
                current.rotationStrategy = previous
            }
        }
    }

    func healthReport() async -> CodexHealthReport {
        let accounts = await accountManager.getAccounts()
        let settings = await accountManager.getSettings()
        let enabled = accounts.filter(\.enabled)
        let eligible = enabled.filter { hasFreshUsableToken($0) }
        let rateLimited = enabled.filter { account in
            if let until = account.rateLimitedUntil {
                return Date() < until
            }
            return false
        }
        let coolingDown = enabled.filter { account in
            !hasFreshUsableToken(account) && !rateLimited.contains(account)
        }

        return CodexHealthReport(
            totalAccounts: accounts.count,
            enabledAccounts: enabled.count,
            healthyAccounts: eligible.count,
            rateLimitedAccounts: rateLimited.count,
            coolingDownAccounts: coolingDown.count,
            forcedAlias: settings.forcedAlias,
            currentStrategy: settings.rotationStrategy,
            accounts: accounts.map { account in
                let health = recoveredEntry(for: account.alias)
                return CodexHealthAccount(
                    alias: account.alias,
                    email: account.email,
                    enabled: account.enabled,
                    eligible: hasFreshUsableToken(account),
                    healthScore: Int(health.score.rounded()),
                    requestCount: account.requestCount,
                    rateLimitedUntil: account.rateLimitedUntil,
                    cooldownReason: cooldownReason(for: account),
                    limitStatus: account.limitStatus ?? "unknown"
                )
            }
        )
    }

    private func canAttempt(_ account: CodexAccount) -> Bool {
        guard account.enabled else {
            return false
        }
        guard account.hasRequiredScopes else {
            return false
        }
        if let rateLimitedUntil = account.rateLimitedUntil, Date() < rateLimitedUntil {
            return false
        }
        return true
    }

    private func hasFreshUsableToken(_ account: CodexAccount) -> Bool {
        canAttempt(account) && account.expiresAt > Date().addingTimeInterval(60)
    }

    private func orderedCandidates(_ accounts: [CodexAccount], strategy: CodexRotationStrategy) -> [CodexAccount] {
        switch strategy {
        case .roundRobin:
            return roundRobinOrder(accounts)
        case .leastUsed:
            return accounts.sorted { $0.requestCount < $1.requestCount }
        case .random:
            return accounts.shuffled()
        case .weightedRoundRobin:
            let first = selectWeighted(accounts)
            return [first] + accounts.filter { $0.alias != first.alias }
        }
    }

    private func roundRobinOrder(_ accounts: [CodexAccount]) -> [CodexAccount] {
        guard !accounts.isEmpty else {
            return []
        }
        let startIndex = currentRoundRobinIndex % accounts.count
        currentRoundRobinIndex = (startIndex + 1) % accounts.count
        return (0..<accounts.count).map { offset in
            accounts[(startIndex + offset) % accounts.count]
        }
    }

    private func selectWeighted(_ accounts: [CodexAccount]) -> CodexAccount {
        let totalWeight = accounts.reduce(0.0) { $0 + max($1.weight, 0.1) }
        var cursor = Double.random(in: 0..<totalWeight)
        for account in accounts {
            cursor -= max(account.weight, 0.1)
            if cursor <= 0 {
                return account
            }
        }
        return accounts[0]
    }

    private func recoveredEntry(for alias: String) -> CodexHealthEntry {
        let current = healthScores[alias] ?? CodexHealthEntry(score: 100, lastUpdated: Date(), consecutiveFailures: 0)
        let hours = Date().timeIntervalSince(current.lastUpdated) / 3600
        let recovered = min(current.score + hours * passiveRecoveryPerHour, 100)
        return CodexHealthEntry(score: recovered, lastUpdated: current.lastUpdated, consecutiveFailures: current.consecutiveFailures)
    }

    private func setHealth(alias: String, score: Double, failures: Int) {
        healthScores[alias] = CodexHealthEntry(score: score, lastUpdated: Date(), consecutiveFailures: failures)
    }

    private func cooldownReason(for account: CodexAccount) -> String? {
        if !account.hasRequiredScopes || account.limitStatus == "missing-scope" {
            return "missing-scope"
        }
        if account.limitStatus == "token-refresh-required" {
            return "reauth-required"
        }
        if account.limitStatus == "refresh-retryable" {
            return "network-retry"
        }
        if let until = account.rateLimitedUntil, Date() < until {
            return "rate-limited"
        }
        if account.expiresAt <= Date().addingTimeInterval(60) {
            return "token-expired"
        }
        return nil
    }

    private func intHeader(_ headers: [AnyHashable: Any], _ name: String) -> Int? {
        for (key, value) in headers {
            if String(describing: key).lowercased() == name.lowercased() {
                return Int(String(describing: value))
            }
        }
        return nil
    }
}
