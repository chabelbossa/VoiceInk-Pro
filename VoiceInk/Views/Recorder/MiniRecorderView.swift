import SwiftUI

private final class PillDragState {
    weak var panel: MiniRecorderPanel?
    var controlBarOrigin: NSPoint?
    var transcriptPreviousTranslation: CGSize?
    var transcriptTracking = false
    var lastMoveTime: TimeInterval = 0
}

struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @State private var dragState = PillDragState()

    private let dragMoveMinimumInterval: TimeInterval = 1.0 / 120.0

    // MARK: - Window Dragging

    private func dragPanel() -> MiniRecorderPanel? {
        if let panel = dragState.panel {
            return panel
        }
        guard let panel = NSApp.windows.first(where: { $0 is MiniRecorderPanel }) as? MiniRecorderPanel
        else {
            return nil
        }
        dragState.panel = panel
        return panel
    }

    private func shouldMovePanelNow() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - dragState.lastMoveTime >= dragMoveMinimumInterval else { return false }
        dragState.lastMoveTime = now
        return true
    }

    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard let panel = dragPanel() else { return }
                if dragState.controlBarOrigin == nil {
                    dragState.controlBarOrigin = panel.frame.origin
                }
                guard let origin = dragState.controlBarOrigin, shouldMovePanelNow() else { return }
                panel.setFrameOrigin(
                    NSPoint(
                        x: origin.x + value.translation.width,
                        y: origin.y - value.translation.height
                    )
                )
            }
            .onEnded { _ in
                dragState.controlBarOrigin = nil
                dragState.panel = nil
            }
    }

    private var transcriptDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let previous = dragState.transcriptPreviousTranslation
                let tracking = dragState.transcriptTracking
                dragState.transcriptPreviousTranslation = value.translation
                dragState.transcriptTracking = true
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                guard tracking, let previous, let panel = dragPanel(), shouldMovePanelNow() else {
                    return
                }
                panel.moveBy(
                    dx: value.translation.width - previous.width,
                    dy: value.translation.height - previous.height
                )
            }
            .onEnded { _ in
                dragState.transcriptPreviousTranslation = nil
                dragState.transcriptTracking = false
                dragState.panel = nil
            }
    }

    // MARK: - Layout Constants

    private let controlBarHeight: CGFloat = 40
    private let compactWidth: CGFloat = 184
    private let expandedWidth: CGFloat = 300
    private let assistantWidth: CGFloat = 520
    private let compactCornerRadius: CGFloat = 20
    private let expandedCornerRadius: CGFloat = 14

    // true when live transcript is streaming in during recording
    private var hasLiveTranscript: Bool {
        showLiveTranscript
            && stateProvider.recordingState == .recording
            && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool {
        assistantSession.isVisible
    }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var controlBar: some View {
        HStack(spacing: 0) {
            Group {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                } else {
                    RecorderRecordButton(
                        recordingState: stateProvider.recordingState,
                        action: onRecordButtonTapped
                    )
                }
            }
            .padding(.leading, 10)

            RecorderModeButton(
                buttonSize: 22,
                padding: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0)
            )

            Spacer(minLength: 0)

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeter: recorder.audioMeter
            )

            Spacer(minLength: 0)

            RecorderEnhancementButton(buttonSize: 22)
            .padding(.trailing, 12)
        }
        .frame(height: controlBarHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(windowDragGesture)
    }

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                Divider().background(Color.white.opacity(0.15))
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(transcriptDragGesture)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
                Divider().background(Color.white.opacity(0.15))
            } else {
                transcriptSection
            }
            controlBar
        }
        .frame(width: hasAssistantResponse ? assistantWidth : (hasLiveTranscript ? expandedWidth : compactWidth))
        .background(Color.black)
        .clipShape(
            RoundedRectangle(
                cornerRadius: hasLiveTranscript || hasAssistantResponse ? expandedCornerRadius : compactCornerRadius,
                style: .continuous)
        )
        .animation(.easeInOut(duration: 0.3), value: hasLiveTranscript)
        .animation(.easeInOut(duration: 0.3), value: hasAssistantResponse)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
