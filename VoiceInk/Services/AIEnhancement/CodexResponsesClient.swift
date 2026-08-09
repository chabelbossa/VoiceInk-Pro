import Foundation
import os

enum CodexServiceTierUsed: String {
    case fast
    case standard
    case spark

    var displayName: String {
        switch self {
        case .fast:
            return "Fast mode"
        case .standard:
            return "Standard mode"
        case .spark:
            return "Codex Spark"
        }
    }
}

struct CodexResponseResult {
    var text: String
    var accountAlias: String
    var serviceTier: CodexServiceTierUsed
}

final class CodexResponsesClient {
    static let shared = CodexResponsesClient()

    private static let installationID: String = {
        let key = "CodexOAuthInstallationID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CodexResponsesClient")
    private let router = CodexAuthRouter.shared
    private let accountManager = CodexAccountManager.shared
    private let responsesURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private let fastModeServiceTier = "priority"
    private let maxRotationAttempts = 5

    private init() {}

    func generateResponse(model: String, systemPrompt: String?, userPrompt: String, reasoningEffort: CodexReasoningEffort, timeout: TimeInterval) async throws -> CodexResponseResult {
        var attemptedAliases = Set<String>()
        var lastError: Error?

        for _ in 0..<maxRotationAttempts {
            guard let selection = await router.selectAccount() else {
                if let lastError {
                    throw CodexClientError.allAccountsExhausted(lastError.localizedDescription)
                }
                if let refreshError = await temporaryRefreshErrorIfNeeded() {
                    throw refreshError
                }
                if let scopeError = await missingScopeErrorIfNeeded() {
                    throw scopeError
                }
                throw CodexClientError.notConfigured
            }

            let account = selection.account
            guard !attemptedAliases.contains(account.alias) else {
                continue
            }
            attemptedAliases.insert(account.alias)

            guard let secret = await accountManager.secret(for: account) else {
                await router.recordAuthFailure(account.alias)
                lastError = CodexClientError.noEligibleAccounts("Missing OAuth tokens for \(account.alias).")
                continue
            }

            let resolvedModel = resolveCodexModel(model)
            let chatGPTAccountID = Self.chatGPTAccountID(fromIDToken: secret.idToken)
            do {
                let (text, headers, serviceTier) = try await callResponsesAPIWithFastDefault(
                    accessToken: secret.accessToken,
                    chatGPTAccountID: chatGPTAccountID,
                    model: resolvedModel,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    reasoningEffort: reasoningEffort,
                    timeout: timeout
                )
                await router.recordSuccess(account.alias)
                await router.updateLimitsFromHeaders(alias: account.alias, headers: headers)
                return CodexResponseResult(text: text, accountAlias: account.alias, serviceTier: serviceTier)
            } catch let error as CodexClientError {
                lastError = error
                if case .apiError(let statusCode, let message) = error {
                    if statusCode == 429 || message.localizedCaseInsensitiveContains("rate limit") {
                        await router.recordRateLimit(account.alias, retryAfter: retryAfterSeconds(from: message))
                        logger.warning("Rate limit on Codex account \(account.alias, privacy: .public), rotating")
                        continue
                    }
                    if isMissingResponsesScope(message) {
                        await router.recordMissingScope(account.alias)
                        lastError = CodexClientError.missingScope(missingScopeMessage)
                        logger.warning("Missing Responses scope on Codex account \(account.alias, privacy: .public), re-auth required")
                        continue
                    }
                    if statusCode == 401 || statusCode == 403 {
                        if let retryResult = try await retryAfterForcedRefresh(
                            account: account,
                            model: resolvedModel,
                            systemPrompt: systemPrompt,
                            userPrompt: userPrompt,
                            reasoningEffort: reasoningEffort,
                            timeout: timeout
                        ) {
                            return retryResult
                        }
                        await router.recordAuthFailure(account.alias)
                        logger.warning("Auth failure on Codex account \(account.alias, privacy: .public), rotating")
                        continue
                    }
                    if statusCode >= 500 {
                        await router.recordServerError(account.alias)
                        continue
                    }
                }
                throw error
            } catch {
                lastError = error
                await router.recordServerError(account.alias)
                continue
            }
        }

        throw CodexClientError.allAccountsExhausted(
            lastError?.localizedDescription ?? "All Codex OAuth accounts were exhausted."
        )
    }

    private func retryAfterForcedRefresh(account: CodexAccount, model: String, systemPrompt: String?, userPrompt: String, reasoningEffort: CodexReasoningEffort, timeout: TimeInterval) async throws -> CodexResponseResult? {
        let refreshResult = await accountManager.forceRefreshToken(alias: account.alias)
        guard refreshResult.isUsable else {
            if case .temporaryFailure(let message) = refreshResult {
                throw CodexClientError.apiError(statusCode: -1, message: message)
            }
            return nil
        }

        guard let refreshedAccount = await accountManager.getAccount(alias: account.alias),
              let refreshedSecret = await accountManager.secret(for: refreshedAccount) else {
            return nil
        }

        do {
            let (text, headers, serviceTier) = try await callResponsesAPIWithFastDefault(
                accessToken: refreshedSecret.accessToken,
                chatGPTAccountID: Self.chatGPTAccountID(fromIDToken: refreshedSecret.idToken),
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                reasoningEffort: reasoningEffort,
                timeout: timeout
            )
            await router.recordSuccess(refreshedAccount.alias)
            await router.updateLimitsFromHeaders(alias: refreshedAccount.alias, headers: headers)
            logger.info("Codex request recovered after forced token refresh for \(refreshedAccount.alias, privacy: .public)")
            return CodexResponseResult(text: text, accountAlias: refreshedAccount.alias, serviceTier: serviceTier)
        } catch let retryError as CodexClientError {
            if case .apiError(let retryStatus, _) = retryError,
               retryStatus == 401 || retryStatus == 403 {
                return nil
            }
            throw retryError
        }
    }

    private var missingScopeMessage: String {
        "Codex OAuth account is missing \(CodexOAuthScopes.connectorsInvoke). Open Settings > AI Provider Integration > Codex, then re-authenticate the account."
    }

    private func missingScopeErrorIfNeeded() async -> CodexClientError? {
        let report = await router.healthReport()
        let hasMissingScopeAccount = report.accounts.contains { $0.cooldownReason == "missing-scope" }
        guard report.totalAccounts > 0, hasMissingScopeAccount else {
            return nil
        }
        return .missingScope(missingScopeMessage)
    }

    private func temporaryRefreshErrorIfNeeded() async -> CodexClientError? {
        let report = await router.healthReport()
        guard report.totalAccounts > 0 else {
            return nil
        }

        if report.accounts.contains(where: { $0.cooldownReason == "network-retry" }) {
            return .apiError(
                statusCode: -1,
                message: "Network unavailable while refreshing Codex OAuth token."
            )
        }

        if report.enabledAccounts > 0,
           report.healthyAccounts == 0,
           report.accounts.contains(where: { $0.cooldownReason == "token-expired" }) {
            return .apiError(
                statusCode: -1,
                message: "Codex OAuth token is expired and will be refreshed when the network is available."
            )
        }

        return nil
    }

    private func isMissingResponsesScope(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains(CodexOAuthScopes.connectorsInvoke)
        || message.localizedCaseInsensitiveContains("Missing scopes")
    }

    private func isFastModeRejected(statusCode: Int, message: String) -> Bool {
        let lowered = message.lowercased()
        if statusCode == 404 && lowered.contains("model not found") {
            return true
        }

        guard statusCode == 400 || statusCode == 422 else {
            return false
        }

        let mentionsServiceTier = lowered.contains("service_tier") || lowered.contains("service tier")
        let mentionsFastMode = lowered.contains("fast mode") || (lowered.contains("fast") && (lowered.contains("tier") || lowered.contains("mode")))
        return mentionsServiceTier || mentionsFastMode
    }

    private func callResponsesAPIWithFastDefault(accessToken: String, chatGPTAccountID: String?, model: String, systemPrompt: String?, userPrompt: String, reasoningEffort: CodexReasoningEffort, timeout: TimeInterval) async throws -> (String, [AnyHashable: Any], CodexServiceTierUsed) {
        if isCodexSparkModel(model) {
            let (text, headers) = try await callResponsesAPI(
                accessToken: accessToken,
                chatGPTAccountID: chatGPTAccountID,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                reasoningEffort: reasoningEffort,
                timeout: timeout,
                serviceTier: nil
            )
            return (text, headers, .spark)
        }

        do {
            let (text, headers) = try await callResponsesAPI(
                accessToken: accessToken,
                chatGPTAccountID: chatGPTAccountID,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                reasoningEffort: reasoningEffort,
                timeout: timeout,
                serviceTier: fastModeServiceTier
            )
            return (text, headers, .fast)
        } catch let error as CodexClientError {
            if case .apiError(let statusCode, let message) = error,
               isFastModeRejected(statusCode: statusCode, message: message) {
                logger.warning("Codex Fast mode was rejected for model \(model, privacy: .public), retrying with standard tier")
                let (text, headers) = try await callResponsesAPI(
                    accessToken: accessToken,
                    chatGPTAccountID: chatGPTAccountID,
                    model: model,
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    reasoningEffort: reasoningEffort,
                    timeout: timeout,
                    serviceTier: nil
                )
                return (text, headers, .standard)
            }
            throw error
        }
    }

    private func callResponsesAPI(accessToken: String, chatGPTAccountID: String?, model: String, systemPrompt: String?, userPrompt: String, reasoningEffort: CodexReasoningEffort, timeout: TimeInterval, serviceTier: String?) async throws -> (String, [AnyHashable: Any]) {
        var body = Self.makeRequestBody(
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )

        let sessionID = UUID().uuidString.lowercased()
        let turnID = UUID().uuidString.lowercased()
        let windowID = "\(sessionID):0"
        let turnMetadata: [String: Any] = [
            "installation_id": Self.installationID,
            "session_id": sessionID,
            "thread_id": sessionID,
            "turn_id": turnID,
            "window_id": windowID,
            "request_kind": "turn",
            "thread_source": "user",
            "turn_started_at_unix_ms": Int(Date().timeIntervalSince1970 * 1_000)
        ]
        let turnMetadataData = try JSONSerialization.data(withJSONObject: turnMetadata)
        let turnMetadataJSON = String(decoding: turnMetadataData, as: UTF8.self)
        body["prompt_cache_key"] = sessionID
        body["text"] = ["verbosity": "low"]
        body["client_metadata"] = [
            "session_id": sessionID,
            "thread_id": sessionID,
            "turn_id": turnID,
            "x-codex-window-id": windowID,
            "x-codex-installation-id": Self.installationID,
            "x-codex-turn-metadata": turnMetadataJSON
        ]

        var request = URLRequest(url: responsesURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let chatGPTAccountID {
            request.setValue(chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue(sessionID, forHTTPHeaderField: "session-id")
        request.setValue(sessionID, forHTTPHeaderField: "thread-id")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        request.setValue(windowID, forHTTPHeaderField: "x-codex-window-id")
        request.setValue("remote_compaction_v2", forHTTPHeaderField: "x-codex-beta-features")
        request.setValue(turnMetadataJSON, forHTTPHeaderField: "x-codex-turn-metadata")
        request.setValue("Codex Desktop/0.144.0 (Mac OS; arm64) VoiceInk", forHTTPHeaderField: "User-Agent")
        if model.hasPrefix("gpt-5.6-") {
            request.setValue("true", forHTTPHeaderField: "x-openai-internal-codex-responses-lite")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequestWithNetworkRetry(request, timeout: timeout)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw CodexClientError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        return (try parseResponseText(data), httpResponse.allHeaderFields)
    }

    static func makeRequestBody(model: String, systemPrompt: String?, userPrompt: String, reasoningEffort: CodexReasoningEffort, serviceTier: String?) -> [String: Any] {
        let usesResponsesLite = model.hasPrefix("gpt-5.6-")
        var reasoning: [String: String] = ["effort": reasoningEffort.rawValue]
        if usesResponsesLite {
            reasoning["context"] = "all_turns"
        }

        let fallbackInstructions = systemPrompt ?? "Follow the user's instructions."
        let input: [[String: Any]]
        if usesResponsesLite {
            input = [
                [
                    "type": "additional_tools",
                    "role": "developer",
                    "tools": []
                ],
                [
                    "type": "message",
                    "role": "developer",
                    "content": [["type": "input_text", "text": fallbackInstructions]]
                ],
                [
                    "type": "message",
                    "role": "user",
                    "content": [["type": "input_text", "text": userPrompt]]
                ]
            ]
        } else {
            input = [["role": "user", "content": userPrompt]]
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "reasoning": reasoning,
            "stream": true,
            "store": false
        ]
        if usesResponsesLite {
            body["parallel_tool_calls"] = false
            body["include"] = ["reasoning.encrypted_content"]
            body["tool_choice"] = "auto"
        } else {
            body["instructions"] = fallbackInstructions
        }
        if let serviceTier {
            body["service_tier"] = serviceTier
        }

        return body
    }

    static func chatGPTAccountID(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let accountID = object["chatgpt_account_id"] as? String, !accountID.isEmpty {
            return accountID
        }
        let authClaims = object["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = authClaims?["chatgpt_account_id"] as? String, !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    private func performRequestWithNetworkRetry(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let maxAttempts = 4
        var delay: TimeInterval = 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                guard attempt < maxAttempts, isRetryableNetworkError(error) else {
                    throw CodexClientError.apiError(statusCode: -1, message: error.localizedDescription)
                }

                logger.warning("Codex network failure, waiting for connectivity before retry. Attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
                await waitForNetworkRecovery(maxWait: min(60, max(5, min(timeout, delay * 4))))
                delay *= 2
            }
        }

        throw CodexClientError.apiError(statusCode: -1, message: lastError?.localizedDescription ?? "Network request failed after retries.")
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
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

    private func waitForNetworkRecovery(maxWait: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(maxWait * 1_000_000_000))
    }

    private func parseResponseText(_ data: Data) throws -> String {
        if let sseText = String(data: data, encoding: .utf8),
           sseText.contains("event:") || sseText.contains("data:") {
            let parsed = parseSSEText(sseText)
            if !parsed.isEmpty {
                return parsed
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexClientError.invalidResponse
        }

        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            let fragments = output.flatMap { item -> [String] in
                if let content = item["content"] as? String {
                    return [content]
                }
                if let content = item["content"] as? [[String: Any]] {
                    return content.compactMap { fragment in
                        if let text = fragment["text"] as? String {
                            return text
                        }
                        if let outputText = fragment["output_text"] as? String {
                            return outputText
                        }
                        return nil
                    }
                }
                return []
            }
            let joined = fragments.joined()
            if !joined.isEmpty {
                return joined
            }
        }

        throw CodexClientError.invalidResponse
    }

    private func parseSSEText(_ text: String) -> String {
        var deltas: [String] = []
        var completedText: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data: ") else {
                continue
            }
            let jsonText = String(line.dropFirst("data: ".count))
            guard let data = jsonText.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let delta = event["delta"] as? String {
                deltas.append(delta)
            }

            if let text = event["text"] as? String, !text.isEmpty {
                completedText = text
            }

            if let response = event["response"] as? [String: Any],
               let output = response["output"] as? [[String: Any]] {
                let responseText = output.compactMap { outputItem -> String? in
                    guard let content = outputItem["content"] as? [[String: Any]] else {
                        return nil
                    }
                    return content.compactMap { $0["text"] as? String }.joined()
                }.joined()
                if !responseText.isEmpty {
                    completedText = responseText
                }
            }
        }

        let joined = deltas.joined()
        if !joined.isEmpty {
            return joined
        }

        return completedText ?? ""
    }

    private func resolveCodexModel(_ model: String) -> String {
        CodexModelCatalog.resolvedModelID(model)
    }

    private func isCodexSparkModel(_ model: String) -> Bool {
        model.lowercased() == "gpt-5.3-codex-spark"
    }

    private func retryAfterSeconds(from message: String) -> TimeInterval? {
        let pattern = #"retry[_\s-]?after[:\s]*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return TimeInterval(String(message[range])) ?? 60
    }
}
