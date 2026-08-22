import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

struct PermissionsView: View {
    @StateObject private var modeManager = ModeManager.shared
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var hasAccessibilityAccess = AXIsProcessTrusted()
    @State private var hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
    @State private var isRequestingScreenRecording = false

    private var currentMode: ModeConfig? {
        modeManager.currentEffectiveConfiguration
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Permissions",
                infoMessage: "Review macOS access and the context sources used by the active mode."
            ) {
                AppIconButton(systemName: "arrow.clockwise", help: "Recheck permissions") {
                    refreshStatuses()
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    permissionSection
                    contextSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .onAppear(perform: refreshStatuses)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS Permissions")
                .font(.system(size: 16, weight: .semibold))

            PermissionStatusRow(
                systemImage: "mic.fill",
                title: "Microphone",
                subtitle: "Required to record audio for transcription.",
                isGranted: microphoneStatus == .authorized,
                statusText: microphoneStatusLabel,
                actionTitle: microphoneStatus == .notDetermined ? "Allow" : "Open Settings",
                action: requestMicrophoneAccess
            )

            PermissionStatusRow(
                systemImage: "hand.raised.fill",
                title: "Accessibility",
                subtitle: "Required to paste at the cursor and read selected text.",
                isGranted: hasAccessibilityAccess,
                statusText: hasAccessibilityAccess ? "Granted" : "Needs access",
                actionTitle: "Open Settings",
                action: requestAccessibilityAccess
            )

            PermissionStatusRow(
                systemImage: "rectangle.on.rectangle",
                title: "Screen Recording",
                subtitle: "Required for screen-context capture and local OCR.",
                isGranted: hasScreenRecordingAccess,
                statusText: hasScreenRecordingAccess ? "Granted" : "Needs access",
                actionTitle: isRequestingScreenRecording ? "Requesting..." : "Allow",
                isActionDisabled: isRequestingScreenRecording,
                action: requestScreenRecordingAccess
            )
        }
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Context Used by Active Mode")
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Text(currentMode?.name ?? String(localized: "No active mode"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ContextSourceRow(
                systemImage: "doc.on.clipboard",
                title: "Clipboard Context",
                subtitle: "No macOS permission is required for clipboard text.",
                isOn: contextBinding(\.useClipboardContext)
            )

            ContextSourceRow(
                systemImage: "selection.pin.in.out",
                title: "Selected Text Context",
                subtitle: hasAccessibilityAccess
                    ? "Accessibility access is ready."
                    : "Enable Accessibility before selected text can be read.",
                isOn: contextBinding(\.useSelectedTextContext)
            )

            ContextSourceRow(
                systemImage: "text.viewfinder",
                title: "Screen Context",
                subtitle: hasScreenRecordingAccess
                    ? "Screen capture and OCR are ready."
                    : "Enable Screen Recording before screen context can be captured.",
                isOn: contextBinding(\.useScreenCapture)
            )
        }
    }

    private var microphoneStatusLabel: String {
        switch microphoneStatus {
        case .authorized: return String(localized: "Granted")
        case .denied: return String(localized: "Denied")
        case .restricted: return String(localized: "Restricted")
        case .notDetermined: return String(localized: "Needs access")
        @unknown default: return String(localized: "Unknown")
        }
    }

    private func contextBinding(_ keyPath: WritableKeyPath<ModeConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { currentMode?[keyPath: keyPath] ?? false },
            set: { newValue in
                modeManager.updateCurrentEffectiveConfiguration { configuration in
                    configuration[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func refreshStatuses() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasAccessibilityAccess = AXIsProcessTrusted()
        hasScreenRecordingAccess = CGPreflightScreenCaptureAccess()
    }

    private func requestMicrophoneAccess() {
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { refreshStatuses() }
            }
        } else {
            openPrivacySettings(.microphone)
        }
    }

    private func requestAccessibilityAccess() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
        openPrivacySettings(.accessibility)
    }

    private func requestScreenRecordingAccess() {
        isRequestingScreenRecording = true
        Task { @MainActor in
            let isGranted = await ScreenCaptureService.requestScreenCapturePermissionRegistration()
            refreshStatuses()
            isRequestingScreenRecording = false

            if !isGranted {
                openPrivacySettings(.screenRecording)
            }
        }
    }

    private func openPrivacySettings(_ pane: PrivacySettingsPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionStatusRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isGranted: Bool
    let statusText: String
    let actionTitle: LocalizedStringKey
    var isActionDisabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isGranted ? AppTheme.Status.positive : AppTheme.Status.warning)
                .frame(width: 34, height: 34)
                .background(AppTheme.Surface.controlActive)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Label(statusText, systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isGranted ? AppTheme.Status.positive : AppTheme.Status.warning)

            if !isGranted {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isActionDisabled)
            }
        }
        .padding(14)
        .background(AppTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ContextSourceRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isOn ? AppTheme.Status.infoStrong : .secondary)
                .frame(width: 34, height: 34)
                .background(AppTheme.Surface.controlActive)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(14)
        .background(AppTheme.Surface.card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
