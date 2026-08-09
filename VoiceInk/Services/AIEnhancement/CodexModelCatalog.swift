import Foundation

enum CodexReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low (Fast)"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }

    var summary: String {
        switch self {
        case .low: return "Best for fast, well-scoped transcription cleanup."
        case .medium: return "More planning for nuanced rewrites and mixed context."
        case .high: return "Deeper analysis for difficult or ambiguous text."
        case .xhigh: return "Very deep reasoning with noticeably higher latency."
        case .max: return "Maximum single-model depth for exceptional cases."
        }
    }
}

struct CodexModelOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let summary: String
    let supportedReasoningEfforts: [CodexReasoningEffort]
    let defaultReasoningEffort: CodexReasoningEffort
    let isRecommendedForVoiceInk: Bool
}

enum CodexModelCatalog {
    static let defaultModelID = "codex:gpt-5.6-terra"

    private static let standardEfforts: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh]
    private static let gpt56Efforts: [CodexReasoningEffort] = [.low, .medium, .high, .xhigh, .max]

    static let options: [CodexModelOption] = [
        CodexModelOption(
            id: "codex:gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            summary: "Highest quality for complex, ambiguous, or high-value transformations.",
            supportedReasoningEfforts: gpt56Efforts,
            defaultReasoningEffort: .medium,
            isRecommendedForVoiceInk: false
        ),
        CodexModelOption(
            id: defaultModelID,
            displayName: "GPT-5.6 Terra",
            summary: "Best balance of quality and speed for everyday transcription enhancement.",
            supportedReasoningEfforts: gpt56Efforts,
            defaultReasoningEffort: .low,
            isRecommendedForVoiceInk: true
        ),
        CodexModelOption(
            id: "codex:gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            summary: "Fastest GPT-5.6 choice for clear, repeatable, high-volume cleanup.",
            supportedReasoningEfforts: gpt56Efforts,
            defaultReasoningEffort: .low,
            isRecommendedForVoiceInk: false
        ),
        CodexModelOption(
            id: "codex:gpt-5.5",
            displayName: "GPT-5.5",
            summary: "Previous-generation frontier fallback for complex work.",
            supportedReasoningEfforts: standardEfforts,
            defaultReasoningEffort: .low,
            isRecommendedForVoiceInk: false
        ),
        CodexModelOption(
            id: "codex:gpt-5.4",
            displayName: "GPT-5.4",
            summary: "Reliable previous-generation model for general enhancement.",
            supportedReasoningEfforts: standardEfforts,
            defaultReasoningEffort: .low,
            isRecommendedForVoiceInk: false
        ),
        CodexModelOption(
            id: "codex:gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            summary: "Compact fallback for responsive, straightforward edits.",
            supportedReasoningEfforts: standardEfforts,
            defaultReasoningEffort: .low,
            isRecommendedForVoiceInk: false
        ),
        CodexModelOption(
            id: "codex:gpt-5.3-codex-spark",
            displayName: "GPT-5.3 Codex Spark",
            summary: "Near-instant research preview for eligible Codex plans.",
            supportedReasoningEfforts: standardEfforts,
            defaultReasoningEffort: .low,
            isRecommendedForVoiceInk: false
        )
    ]

    static var modelIDs: [String] { options.map(\.id) }

    static func option(for modelID: String) -> CodexModelOption? {
        options.first { $0.id == modelID }
    }

    static func effectiveReasoningEffort(_ requestedEffort: CodexReasoningEffort, for modelID: String) -> CodexReasoningEffort {
        guard let option = option(for: modelID) else { return .low }
        return option.supportedReasoningEfforts.contains(requestedEffort)
            ? requestedEffort
            : option.defaultReasoningEffort
    }

    static func resolvedModelID(_ modelID: String) -> String {
        guard modelID.hasPrefix("codex:") else { return modelID }
        return String(modelID.dropFirst("codex:".count))
    }
}
