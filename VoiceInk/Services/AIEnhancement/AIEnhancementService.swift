import Foundation
import SwiftData
import AppKit
import os
import LLMkit

enum EnhancementPrompt {
    case transcriptionEnhancement
    case aiAssistant
}

@MainActor
class AIEnhancementService: ObservableObject {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AIEnhancementService")

    @Published var isEnhancementEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnhancementEnabled, forKey: "isAIEnhancementEnabled")
            if isEnhancementEnabled && selectedPromptId == nil {
                selectedPromptId = customPrompts.first?.id
            }
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            NotificationCenter.default.post(name: .enhancementToggleChanged, object: nil)
        }
    }

    @Published var useClipboardContext: Bool {
        didSet {
            UserDefaults.standard.set(useClipboardContext, forKey: "useClipboardContext")
        }
    }

    @Published var useScreenCaptureContext: Bool {
        didSet {
            UserDefaults.standard.set(useScreenCaptureContext, forKey: "useScreenCaptureContext")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published var customPrompts: [CustomPrompt] {
        didSet {
            if let encoded = try? JSONEncoder().encode(customPrompts) {
                UserDefaults.standard.set(encoded, forKey: "customPrompts")
            }
        }
    }

    @Published var selectedPromptId: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPromptId?.uuidString, forKey: "selectedPromptId")
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            NotificationCenter.default.post(name: .promptSelectionChanged, object: nil)
        }
    }

    @Published var lastSystemMessageSent: String?
    @Published var lastUserMessageSent: String?
    /// The masked API key that was used in the last successful enhancement (e.g. "sk-...ab12")
    @Published var lastAPIKeyUsed: String?

    var activePrompt: CustomPrompt? {
        allPrompts.first { $0.id == selectedPromptId }
    }

    var allPrompts: [CustomPrompt] {
        return customPrompts
    }

    private let aiService: AIService
    private let screenCaptureService: ScreenCaptureService
    private let customVocabularyService: CustomVocabularyService
    private var baseTimeout: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: "EnhancementTimeoutSeconds")
        return stored > 0 ? TimeInterval(stored) : 7
    }
    private let rateLimitInterval: TimeInterval = 1.0
    private var lastRequestTime: Date?
    private let modelContext: ModelContext
    
    @Published var lastCapturedClipboard: String?

    init(aiService: AIService = AIService(), modelContext: ModelContext) {
        self.aiService = aiService
        self.modelContext = modelContext
        self.screenCaptureService = ScreenCaptureService()
        self.customVocabularyService = CustomVocabularyService.shared

        self.isEnhancementEnabled = UserDefaults.standard.bool(forKey: "isAIEnhancementEnabled")
        self.useClipboardContext = UserDefaults.standard.bool(forKey: "useClipboardContext")
        self.useScreenCaptureContext = UserDefaults.standard.bool(forKey: "useScreenCaptureContext")
        if let savedPromptsData = UserDefaults.standard.data(forKey: "customPrompts"),
           let decodedPrompts = try? JSONDecoder().decode([CustomPrompt].self, from: savedPromptsData) {
            self.customPrompts = decodedPrompts
        } else {
            self.customPrompts = []
        }

        if let savedPromptId = UserDefaults.standard.string(forKey: "selectedPromptId") {
            self.selectedPromptId = UUID(uuidString: savedPromptId)
        }

        if isEnhancementEnabled && (selectedPromptId == nil || !allPrompts.contains(where: { $0.id == selectedPromptId })) {
            self.selectedPromptId = allPrompts.first?.id
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAPIKeyChange),
            name: .aiProviderKeyChanged,
            object: nil
        )

        initializePredefinedPrompts()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAPIKeyChange() {
        DispatchQueue.main.async {
            self.objectWillChange.send()
            // Refresh multi-key status before checking
            self.aiService.refreshMultiKeyStatus()
            if !self.aiService.isAPIKeyValid && !self.aiService.hasAnyMultiKey {
                self.isEnhancementEnabled = false
            }
        }
    }

    func getAIService() -> AIService? {
        return aiService
    }

    var isConfigured: Bool {
        aiService.isAPIKeyValid || aiService.hasAnyMultiKey
    }

    private func waitForRateLimit() async throws {
        if let lastRequest = lastRequestTime {
            let timeSinceLastRequest = Date().timeIntervalSince(lastRequest)
            if timeSinceLastRequest < rateLimitInterval {
                try await Task.sleep(nanoseconds: UInt64((rateLimitInterval - timeSinceLastRequest) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    private func getSystemMessage(for mode: EnhancementPrompt) async -> String {
        let selectedTextContext: String
        if AXIsProcessTrusted() {
            if let selectedText = await SelectedTextService.fetchSelectedText(), !selectedText.isEmpty {
                selectedTextContext = "\n\n<CURRENTLY_SELECTED_TEXT>\n\(selectedText)\n</CURRENTLY_SELECTED_TEXT>"
            } else {
                selectedTextContext = ""
            }
        } else {
            selectedTextContext = ""
        }

        let clipboardContext = if useClipboardContext,
                              let clipboardText = lastCapturedClipboard,
                              !clipboardText.isEmpty {
            "\n\n<CLIPBOARD_CONTEXT>\n\(clipboardText)\n</CLIPBOARD_CONTEXT>"
        } else {
            ""
        }

        let screenCaptureContext = if useScreenCaptureContext,
                                   let capturedText = screenCaptureService.lastCapturedText,
                                   !capturedText.isEmpty {
            "\n\n<CURRENT_WINDOW_CONTEXT>\n\(capturedText)\n</CURRENT_WINDOW_CONTEXT>"
        } else {
            ""
        }

        let customVocabulary = customVocabularyService.getCustomVocabulary(from: modelContext)

        let allContextSections = selectedTextContext + clipboardContext + screenCaptureContext

        let customVocabularySection = if !customVocabulary.isEmpty {
            """


            The following are important vocabulary words, proper nouns, and technical terms. When these words or similar-sounding words appear in the <TRANSCRIPT>, ensure they are spelled EXACTLY as shown below:
            <CUSTOM_VOCABULARY>
            \(customVocabulary)
            </CUSTOM_VOCABULARY>
            """
        } else {
            ""
        }

        let finalContextSection = allContextSections + customVocabularySection

        if let activePrompt = activePrompt {
            if activePrompt.id == PredefinedPrompts.assistantPromptId {
                return activePrompt.promptText + finalContextSection
            } else {
                return activePrompt.finalPromptText + finalContextSection
            }
        } else {
            let defaultPrompt = allPrompts.first(where: { $0.id == PredefinedPrompts.defaultPromptId }) ?? allPrompts.first!
            return defaultPrompt.finalPromptText + finalContextSection
        }
    }

    /// Resolves the API key to use for the current request.
    /// Uses MultiKeyManager round-robin for providers with multiple keys,
    /// falls back to AIService's primary key otherwise.
    private func resolveAPIKey() async -> String? {
        let provider = aiService.selectedProvider.rawValue
        
        // Try multi-key rotation first
        if let key = await MultiKeyManager.shared.getNextKey(forProvider: provider) {
            return key
        }
        
        // Fallback to primary key
        if !aiService.apiKey.isEmpty {
            return aiService.apiKey
        }
        
        return nil
    }
    
    private func makeRequest(text: String, mode: EnhancementPrompt, apiKeyOverride: String? = nil) async throws -> String {
        guard isConfigured else {
            throw EnhancementError.notConfigured
        }

        guard !text.isEmpty else {
            return ""
        }
        
        // Resolve the API key: use override if provided, otherwise rotate
        let currentAPIKey: String
        if let override = apiKeyOverride {
            currentAPIKey = override
        } else {
            guard let resolvedKey = await resolveAPIKey() else {
                throw EnhancementError.notConfigured
            }
            currentAPIKey = resolvedKey
        }

        let formattedText = "\n<TRANSCRIPT>\n\(text)\n</TRANSCRIPT>"
        let systemMessage = await getSystemMessage(for: mode)

        await MainActor.run {
            self.lastSystemMessageSent = systemMessage
            self.lastUserMessageSent = formattedText
        }

        if aiService.selectedProvider == .ollama {
            do {
                let result = try await aiService.enhanceWithOllama(text: formattedText, systemPrompt: systemMessage)
                return AIEnhancementOutputFilter.filter(result)
            } catch {
                if let localError = error as? LocalAIError {
                    throw EnhancementError.customError(localError.errorDescription ?? "An unknown Ollama error occurred.")
                } else {
                    throw EnhancementError.customError(error.localizedDescription)
                }
            }
        }

        if aiService.selectedProvider == .localCLI {
            do {
                let result = try await aiService.enhanceWithLocalCLI(systemPrompt: systemMessage, userPrompt: formattedText)
                return AIEnhancementOutputFilter.filter(result)
            } catch {
                if let localError = error as? LocalCLIError {
                    throw EnhancementError.customError(localError.errorDescription ?? "An unknown Local CLI error occurred.")
                } else {
                    throw EnhancementError.customError(error.localizedDescription)
                }
            }
        }

        try await waitForRateLimit()

        do {
            let result: String
            switch aiService.selectedProvider {
            case .anthropic:
                result = try await AnthropicLLMClient.chatCompletion(
                    apiKey: currentAPIKey,
                    model: aiService.currentModel,
                    messages: [.user(formattedText)],
                    systemPrompt: systemMessage,
                    timeout: baseTimeout
                )
            default:
                guard let baseURL = URL(string: aiService.selectedProvider.baseURL) else {
                    throw EnhancementError.customError("\(aiService.selectedProvider.rawValue) has an invalid API endpoint URL. Please update it in AI settings.")
                }
                let temperature = 0.8
                let reasoningEffort = ReasoningConfig.getReasoningParameter(
                    for: aiService.selectedProvider,
                    modelName: aiService.currentModel
                )
                let extraBody = ReasoningConfig.getExtraBodyParameters(
                    for: aiService.selectedProvider,
                    modelName: aiService.currentModel
                )
                result = try await OpenAILLMClient.chatCompletion(
                    baseURL: baseURL,
                    apiKey: currentAPIKey,
                    model: aiService.currentModel,
                    messages: [.user(formattedText)],
                    systemPrompt: systemMessage,
                    temperature: temperature,
                    reasoningEffort: reasoningEffort,
                    extraBody: extraBody,
                    timeout: baseTimeout
                )
            }
            return AIEnhancementOutputFilter.filter(result.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let error as LLMKitError {
            throw mapLLMKitError(error)
        } catch let error as EnhancementError {
            throw error
        } catch {
            throw EnhancementError.customError(error.localizedDescription)
        }
    }

    private func mapLLMKitError(_ error: LLMKitError) -> EnhancementError {
        switch error {
        case .missingAPIKey:
            return .notConfigured
        case .httpError(let statusCode, let message):
            if statusCode == 429 { return .rateLimitExceeded }
            if (500...599).contains(statusCode) { return .serverError }
            return .customError("HTTP \(statusCode): \(message)")
        case .noResultReturned:
            return .enhancementFailed
        case .networkError:
            return .networkError
        case .timeout:
            return .timeout
        case .invalidURL, .decodingError, .encodingError:
            return .customError(error.localizedDescription ?? "An unknown error occurred.")
        }
    }

    private var retryOnTimeout: Bool {
        UserDefaults.standard.bool(forKey: "EnhancementRetryOnTimeout")
    }

    private func makeRequestWithRetry(text: String, mode: EnhancementPrompt, maxRetries: Int = 3, initialDelay: TimeInterval = 1.0) async throws -> (String, String?) {
        // Returns (enhancedText, keyUsed)
        let provider = aiService.selectedProvider.rawValue
        let multiKeyManager = MultiKeyManager.shared
        
        // Total keys available (1 if single, N if multiple)
        // Total attempts = number of keys × maxRetries (backoff kicks in after a full rotation)
        let totalKeys = max(1, await multiKeyManager.keyCount(forProvider: provider))
        let maxAttempts = totalKeys * maxRetries
        
        var attempts = 0
        var currentDelay = initialDelay
        // lastRotatedKey ensures getNextKey(after:) always advances from the correct position
        var lastRotatedKey: String? = await multiKeyManager.lastUsedKey(forProvider: provider)
        
        logger.notice("🚀 Enhancement starting — provider: \(provider), keys available: \(totalKeys), max attempts: \(maxAttempts)")

        while attempts < maxAttempts {
            // Always go through getNextKey — works for 1 key or N keys identically
            guard let currentKey = await multiKeyManager.getNextKey(forProvider: provider, after: lastRotatedKey) else {
                // No key in MultiKeyManager at all — fall back to the legacy primary key
                guard let legacyKey = await resolveAPIKey() else {
                    throw EnhancementError.notConfigured
                }
                // Legacy single key: run one attempt with plain backoff
                let result = try await makeRequest(text: text, mode: mode, apiKeyOverride: legacyKey)
                return (result, legacyKey)
            }
            // Remember this key so the next iteration advances from it
            lastRotatedKey = currentKey
            
            do {
                // Always pass currentKey explicitly — never let makeRequest call getNextKey() again
                let result = try await makeRequest(text: text, mode: mode, apiKeyOverride: currentKey)
                return (result, currentKey)
            } catch let error as EnhancementError {
                switch error {
                case .rateLimitExceeded:
                    // Mark this key as failed so round-robin skips it on the next iteration
                    await multiKeyManager.markKeyAsFailed(currentKey, forProvider: provider)
                    logger.warning("Rate limit on key, marked as failed. Trying next key... (Attempt \(attempts + 1)/\(maxAttempts))")
                    
                    attempts += 1
                    
                    // After a full rotation of all keys, apply exponential backoff
                    if attempts % totalKeys == 0 && attempts < maxAttempts {
                        logger.warning("All \(totalKeys) key(s) exhausted in rotation #\(attempts / totalKeys), backing off \(currentDelay)s...")
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    }
                    // Immediately try next key within the same rotation (no delay)
                    continue
                    
                case .networkError, .serverError:
                    attempts += 1
                    if attempts < maxAttempts {
                        logger.warning("Request failed, retrying in \(currentDelay)s... (Attempt \(attempts)/\(maxAttempts))")
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    } else {
                        logger.error("Request failed after \(maxAttempts) attempts.")
                        throw error
                    }
                case .timeout:
                    if retryOnTimeout {
                        attempts += 1
                        if attempts < maxAttempts {
                            logger.warning("Request timed out, retrying immediately... (Attempt \(attempts)/\(maxAttempts))")
                        } else {
                            logger.error("Request timed out after \(maxAttempts) attempts.")
                            throw error
                        }
                    } else {
                        logger.error("Request timed out, failing immediately (retry disabled).")
                        throw error
                    }
                default:
                    throw error
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(nsError.code) {
                    attempts += 1
                    if attempts < maxAttempts {
                        logger.warning("Network error, retrying in \(currentDelay)s... (Attempt \(attempts)/\(maxAttempts))")
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    } else {
                        logger.error("Request failed after \(maxAttempts) attempts with network error.")
                        throw EnhancementError.networkError
                    }
                } else {
                    throw error
                }
            }
        }

        logger.error("❌ All \(totalKeys) key(s) exhausted after \(maxAttempts) attempts for provider: \(provider)")
        throw EnhancementError.customError("Rate limit exceeded on all \(totalKeys) key(s) after \(maxAttempts) attempts. Try reducing usage or wait 60s.")
    }

    func enhance(_ text: String) async throws -> (String, TimeInterval, String?) {
        let startTime = Date()
        let enhancementPrompt: EnhancementPrompt = .transcriptionEnhancement
        let promptName = activePrompt?.title

        let (result, keyUsed) = try await makeRequestWithRetry(text: text, mode: enhancementPrompt)
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        // Store masked key for history display
        await MainActor.run {
            self.lastAPIKeyUsed = Self.maskKey(keyUsed)
        }
        
        return (result, duration, promptName)
    }
    
    /// Returns a masked version of the key: shows first 4 and last 4 characters.
    static func maskKey(_ key: String?) -> String? {
        guard let key = key, key.count > 8 else { return key }
        let prefix = key.prefix(4)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    func captureScreenContext() async {
        guard CGPreflightScreenCaptureAccess() else {
            return
        }

        if let capturedText = await screenCaptureService.captureAndExtractText() {
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }

    func captureClipboardContext() {
        lastCapturedClipboard = NSPasteboard.general.string(forType: .string)
    }
    
    func clearCapturedContexts() {
        lastCapturedClipboard = nil
        screenCaptureService.lastCapturedText = nil
    }

    func addPrompt(title: String, promptText: String, icon: PromptIcon = "doc.text.fill", description: String? = nil, triggerWords: [String] = [], useSystemInstructions: Bool = true) {
        let newPrompt = CustomPrompt(title: title, promptText: promptText, icon: icon, description: description, isPredefined: false, triggerWords: triggerWords, useSystemInstructions: useSystemInstructions)
        customPrompts.append(newPrompt)
        if customPrompts.count == 1 {
            selectedPromptId = newPrompt.id
        }
    }

    func updatePrompt(_ prompt: CustomPrompt) {
        if let index = customPrompts.firstIndex(where: { $0.id == prompt.id }) {
            customPrompts[index] = prompt
        }
    }

    func deletePrompt(_ prompt: CustomPrompt) {
        customPrompts.removeAll { $0.id == prompt.id }
        if selectedPromptId == prompt.id {
            selectedPromptId = allPrompts.first?.id
        }
    }

    func setActivePrompt(_ prompt: CustomPrompt) {
        selectedPromptId = prompt.id
    }

    private func initializePredefinedPrompts() {
        let predefinedTemplates = PredefinedPrompts.createDefaultPrompts()

        for template in predefinedTemplates {
            if let existingIndex = customPrompts.firstIndex(where: { $0.id == template.id }) {
                var updatedPrompt = customPrompts[existingIndex]
                updatedPrompt = CustomPrompt(
                    id: updatedPrompt.id,
                    title: template.title,
                    promptText: template.promptText,
                    isActive: updatedPrompt.isActive,
                    icon: template.icon,
                    description: template.description,
                    isPredefined: true,
                    triggerWords: updatedPrompt.triggerWords,
                    useSystemInstructions: template.useSystemInstructions
                )
                customPrompts[existingIndex] = updatedPrompt
            } else {
                customPrompts.append(template)
            }
        }
    }
}

enum EnhancementError: Error {
    case notConfigured
    case invalidResponse
    case enhancementFailed
    case networkError
    case serverError
    case rateLimitExceeded
    case timeout
    case customError(String)
}

extension EnhancementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI provider not configured. Please check your API key."
        case .invalidResponse:
            return "Invalid response from AI provider."
        case .enhancementFailed:
            return "AI enhancement failed to process the text."
        case .networkError:
            return "Network connection failed. Check your internet."
        case .serverError:
            return "The AI provider's server encountered an error. Please try again later."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .timeout:
            return "Enhancement request timed out. Check your connection or increase the timeout duration."
        case .customError(let message):
            return message
        }
    }
}
