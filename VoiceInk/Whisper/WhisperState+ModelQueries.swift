import Foundation

extension WhisperState {
    var usableModels: [any TranscriptionModel] {
        allAvailableModels.filter { model in
            switch model.provider {
            case .local:
                return availableModels.contains { $0.name == model.name }
            case .parakeet:
                return isParakeetModelDownloaded(named: model.name)
            case .nativeApple:
                if #available(macOS 26, *) {
                    return true
                } else {
                    return false
                }
            case .groq:
                return APIKeyManager.shared.hasAPIKey(forProvider: "Groq")
            case .elevenLabs:
                return APIKeyManager.shared.hasAPIKey(forProvider: "ElevenLabs")
            case .deepgram:
                return APIKeyManager.shared.hasAPIKey(forProvider: "Deepgram")
            case .mistral:
                return APIKeyManager.shared.hasAPIKey(forProvider: "Mistral")
            case .gemini:
                // Gemini supports multi-key: usable if primary key OR any multi-key exists
                return APIKeyManager.shared.hasAPIKey(forProvider: "Gemini")
            case .soniox:
                return APIKeyManager.shared.hasAPIKey(forProvider: "Soniox")
            case .custom:
                // Custom models are always usable since they contain their own API keys
                return true
            }
        }
    }
} 
