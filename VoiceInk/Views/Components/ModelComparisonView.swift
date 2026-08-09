import SwiftData
import SwiftUI

private struct ComparisonProviderGroup: Identifiable {
    let provider: AIProvider
    let candidates: [ModelComparisonCandidate]

    var id: String {
        provider.rawValue
    }
}

struct ModelComparisonView: View {
    let transcription: Transcription

    @EnvironmentObject private var enhancementService: AIEnhancementService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var comparisonCandidates: [ModelComparisonCandidate] = []
    @State private var selectedCandidates = Set<ModelComparisonCandidate>()
    @State private var results: [ModelComparisonResult] = []
    @State private var isLoadingCandidates = false
    @State private var isComparing = false
    @State private var appliedResultID: UUID?

    private let comparisonLimit = 6

    private var aiService: AIService? {
        enhancementService.getAIService()
    }

    private var providerOrder: [AIProvider] {
        [
            .gemini,
            .codex,
            .openAI,
            .anthropic,
            .nvidia,
            .groq,
            .cerebras,
            .mistral,
            .openRouter,
            .custom,
            .ollama,
            .localCLI
        ]
    }

    private var currentCandidate: ModelComparisonCandidate? {
        guard let aiService, !aiService.currentModel.isEmpty else { return nil }
        return ModelComparisonCandidate(provider: aiService.selectedProvider, model: aiService.currentModel)
    }

    private var selectedCandidatesInOrder: [ModelComparisonCandidate] {
        let ordered = comparisonCandidates.filter { selectedCandidates.contains($0) }
        let remaining = selectedCandidates.filter { !comparisonCandidates.contains($0) }
            .sorted { $0.displayName < $1.displayName }
        return ordered + remaining
    }

    private var groupedCandidates: [ComparisonProviderGroup] {
        let grouped = Dictionary(grouping: comparisonCandidates, by: \.provider)
        return providerOrder.compactMap { provider in
            guard let candidates = grouped[provider], !candidates.isEmpty else { return nil }
            return ComparisonProviderGroup(provider: provider, candidates: candidates)
        }
    }

    private var canCompare: Bool {
        !selectedCandidates.isEmpty && !isComparing && !isLoadingCandidates
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(alignment: .top, spacing: 0) {
                modelPicker
                    .frame(width: 310)

                Divider()

                resultPane
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .task {
            await loadComparisonCandidates()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Models")
                    .font(.system(size: 18, weight: .semibold))

                if let currentCandidate {
                    Text(currentCandidate.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Providers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(selectedCandidates.count)/\(comparisonLimit)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoadingCandidates {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else if groupedCandidates.isEmpty {
                        Text("No configured providers")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    } else {
                        ForEach(groupedCandidates) { group in
                            providerSection(group)
                        }
                    }
                }
                .padding(.trailing, 4)
            }

            Button(action: runComparison) {
                HStack(spacing: 8) {
                    if isComparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }

                    Text(isComparing ? "Comparing..." : "Run")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCompare)
        }
        .padding(18)
    }

    private var resultPane: some View {
        Group {
            if isComparing && results.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Comparing selected models")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No comparison results yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(results) { result in
                            comparisonCard(for: result)
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func providerSection(_ group: ComparisonProviderGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.provider.rawValue)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.candidates) { candidate in
                    modelToggle(for: candidate)
                }
            }
        }
    }

    private func modelToggle(for candidate: ModelComparisonCandidate) -> some View {
        let isSelected = selectedCandidates.contains(candidate)
        let isCurrent = candidate == currentCandidate

        return Button {
            toggleCandidate(candidate)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(candidate.model)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if isCurrent {
                    Text("Current")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func comparisonCard(for result: ModelComparisonResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.provider.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Text(result.model)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }

                Spacer()

                if let keyUsed = result.keyUsed {
                    Text(keyUsed)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(formatDuration(result.duration))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = result.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let output = result.output {
                Text(output)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()

                Button(action: { apply(result) }) {
                    HStack(spacing: 6) {
                        Image(systemName: appliedResultID == result.id ? "checkmark" : "arrow.down.doc.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(appliedResultID == result.id ? "Using" : "Use this version")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .disabled(!result.isSuccess)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .stroke(appliedResultID == result.id ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func loadComparisonCandidates() async {
        guard comparisonCandidates.isEmpty else { return }

        await MainActor.run {
            isLoadingCandidates = true
        }

        let candidates = await enhancementService.availableModelComparisonCandidates()

        await MainActor.run {
            comparisonCandidates = candidates
            isLoadingCandidates = false
            seedDefaultCandidates()
        }
    }

    private func seedDefaultCandidates() {
        guard selectedCandidates.isEmpty else { return }

        var defaults: [ModelComparisonCandidate] = []
        var preferredProviders = [AIProvider]()

        if let currentCandidate {
            defaults.append(currentCandidate)
            preferredProviders.append(currentCandidate.provider)
        }

        preferredProviders.append(contentsOf: [.gemini, .codex, .openAI, .anthropic, .nvidia, .groq])

        for provider in preferredProviders where defaults.count < min(4, comparisonLimit) {
            guard let candidate = comparisonCandidates.first(where: { $0.provider == provider }),
                  !defaults.contains(candidate) else { continue }
            defaults.append(candidate)
        }

        for candidate in comparisonCandidates where defaults.count < min(4, comparisonLimit) {
            guard !defaults.contains(candidate) else { continue }
            defaults.append(candidate)
        }

        selectedCandidates = Set(defaults.prefix(comparisonLimit))
    }

    private func toggleCandidate(_ candidate: ModelComparisonCandidate) {
        if selectedCandidates.contains(candidate) {
            selectedCandidates.remove(candidate)
        } else if selectedCandidates.count < comparisonLimit {
            selectedCandidates.insert(candidate)
        }
    }

    private func runComparison() {
        guard canCompare else { return }

        let candidates = selectedCandidatesInOrder
        isComparing = true
        appliedResultID = nil
        results = []

        Task {
            let comparisonResults = await enhancementService.compareEnhancementModels(
                text: transcription.text,
                candidates: candidates
            )

            await MainActor.run {
                results = comparisonResults
                isComparing = false
            }
        }
    }

    private func apply(_ result: ModelComparisonResult) {
        guard result.isSuccess, let output = result.output else { return }

        transcription.enhancedText = output
        transcription.aiEnhancementModelName = "\(result.provider.rawValue): \(result.model)"
        transcription.promptName = result.promptName
        transcription.enhancementDuration = result.duration
        transcription.aiRequestSystemMessage = result.systemMessage
        transcription.aiRequestUserMessage = result.userMessage
        transcription.aiKeyUsed = result.keyUsed
        try? modelContext.save()

        appliedResultID = result.id
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int(duration * 1000))ms"
        }
        return String(format: "%.1fs", duration)
    }
}
