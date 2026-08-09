import SwiftUI

struct EnhancementSettingsView: View {
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var modeManager = ModeManager.shared

    @State private var promptEditorMode: PromptEditorView.Mode?
    @State private var promptEditorID = UUID()

    private var currentMode: ModeConfig? {
        modeManager.currentEffectiveConfiguration
    }

    private var selectedPromptID: UUID? {
        currentMode?.selectedPrompt.flatMap(UUID.init)
    }

    private var isEnhancementEnabled: Binding<Bool> {
        Binding(
            get: { currentMode?.isAIEnhancementEnabled == true },
            set: { isEnabled in
                modeManager.updateCurrentEffectiveConfiguration { configuration in
                    configuration.isAIEnhancementEnabled = isEnabled
                    if isEnabled, configuration.selectedPrompt == nil {
                        configuration.selectedPrompt = enhancementService.allPrompts.first?.id.uuidString
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Enhancement",
                infoMessage: "Configure AI cleanup for the currently active mode."
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "Add prompt") {
                    openPromptEditor(.add)
                }
            }

            Form {
                Section("General") {
                    Toggle("Enable AI Enhancement", isOn: isEnhancementEnabled)
                        .toggleStyle(.switch)
                        .disabled(currentMode == nil)

                    LabeledContent("Active Mode") {
                        Text(currentMode?.name ?? String(localized: "No active mode"))
                            .foregroundStyle(currentMode == nil ? .secondary : .primary)
                    }
                }

                APIKeyManagementView()
                    .opacity(isEnhancementEnabled.wrappedValue ? 1 : 0.72)

                Section("Enhancement Prompts") {
                    PromptSelectionGrid(
                        prompts: enhancementService.allPrompts,
                        selectedPromptId: selectedPromptID,
                        onPromptSelected: selectPrompt,
                        onEditPrompt: { openPromptEditor(.edit($0)) },
                        onDeletePrompt: deletePrompt,
                        onAddNewPrompt: { openPromptEditor(.add) }
                    )
                }
                .opacity(isEnhancementEnabled.wrappedValue ? 1 : 0.72)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 600, minHeight: 500)
        .sidePanel(
            isPresented: Binding(
                get: { promptEditorMode != nil },
                set: { if !$0 { closePromptEditor() } }
            )
        ) {
            if let promptEditorMode {
                PromptEditorView(
                    mode: promptEditorMode,
                    onDismiss: closePromptEditor,
                    onSave: selectPrompt,
                    onDelete: deletePrompt
                )
                .environmentObject(enhancementService)
                .id(promptEditorID)
            }
        }
        .onAppear(perform: synchronizeProviderFromCurrentMode)
        .onChange(of: currentMode?.id) { _, _ in
            synchronizeProviderFromCurrentMode()
        }
        .onChange(of: aiService.selectedProvider) { _, provider in
            modeManager.updateCurrentEffectiveConfiguration { configuration in
                configuration.selectedAIProvider = provider.rawValue
                configuration.selectedAIModel = aiService.currentModel
            }
        }
        .onChange(of: aiService.currentModel) { _, model in
            modeManager.updateCurrentEffectiveConfiguration { configuration in
                configuration.selectedAIProvider = aiService.selectedProvider.rawValue
                configuration.selectedAIModel = model
            }
        }
    }

    private func synchronizeProviderFromCurrentMode() {
        guard let mode = currentMode,
            let providerName = mode.selectedAIProvider,
            let provider = AIProvider(rawValue: providerName)
        else { return }

        aiService.selectedProvider = provider
        if let model = mode.selectedAIModel, !model.isEmpty {
            aiService.selectModel(model, for: provider)
        }
    }

    private func selectPrompt(_ prompt: CustomPrompt) {
        modeManager.updateCurrentEffectiveConfiguration { configuration in
            configuration.isAIEnhancementEnabled = true
            configuration.selectedPrompt = prompt.id.uuidString
        }
        closePromptEditor()
    }

    private func deletePrompt(_ prompt: CustomPrompt) {
        enhancementService.deletePrompt(prompt)
        closePromptEditor()
    }

    private func openPromptEditor(_ mode: PromptEditorView.Mode) {
        promptEditorID = UUID()
        promptEditorMode = mode
    }

    private func closePromptEditor() {
        promptEditorMode = nil
    }
}
