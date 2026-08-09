import SwiftUI

struct CodexAccountsSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var report: CodexHealthReport?
    @State private var settings: CodexMultiAuthSettings = .default
    @State private var newAlias: String = ""
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var aliasToDelete: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex OAuth Accounts")
                        .font(.headline)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker("Rotation", selection: $settings.rotationStrategy) {
                    ForEach(CodexRotationStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .onChange(of: settings.rotationStrategy) { _, newValue in
                    Task {
                        await CodexAccountManager.shared.updateSettings { current in
                            current.rotationStrategy = newValue
                        }
                        await refresh()
                    }
                }

                if let forcedAlias = report?.forcedAlias {
                    HStack {
                        Label("Forced account: \(forcedAlias)", systemImage: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.orange)

                        Spacer()

                        Button("Clear") {
                            Task {
                                await CodexAuthRouter.shared.clearForceMode()
                                await refresh()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            accountList

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Account")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    TextField("Alias, e.g. personal", text: $newAlias)
                        .textFieldStyle(.roundedBorder)

                    Button(action: addAccount) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Connect", systemImage: "person.crop.circle.badge.plus")
                        }
                    }
                    .disabled(isWorking)
                    .buttonStyle(.borderedProminent)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear {
            Task { await refresh() }
        }
        .alert("Codex OAuth", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Remove Account?", isPresented: Binding(
            get: { aliasToDelete != nil },
            set: { if !$0 { aliasToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if let alias = aliasToDelete {
                    removeAccount(alias)
                }
            }
        } message: {
            Text("This OAuth account will be removed from VoiceInk.")
        }
    }

    private var accountList: some View {
        Group {
            if let report, !report.accounts.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(report.accounts) { account in
                            accountRow(account)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 260)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 38))
                        .foregroundColor(.secondary.opacity(0.55))

                    Text("No Codex accounts connected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            }
        }
    }

    private func accountRow(_ account: CodexHealthAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: account.enabled ? "person.crop.circle.fill" : "person.crop.circle.badge.xmark")
                .font(.system(size: 18))
                .foregroundColor(account.enabled ? .accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.alias)
                        .font(.system(size: 13, weight: .semibold))
                    if account.eligible {
                        Text("ready")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if let reason = account.cooldownReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }

                Text(account.email)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Health \(account.healthScore)% | \(account.requestCount) request\(account.requestCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { toggleAccount(account) }) {
                Image(systemName: account.enabled ? "pause.circle" : "play.circle")
            }
            .buttonStyle(.plain)
            .help(account.enabled ? "Disable account" : "Enable account")

            Button(action: { forceAccount(account.alias) }) {
                Image(systemName: "pin")
            }
            .buttonStyle(.plain)
            .disabled(!account.enabled)
            .help("Force this account for 24 hours")

            Button(action: { reauthAccount(account.alias) }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Re-authenticate")

            Button(action: { aliasToDelete = account.alias }) {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var summaryText: String {
        guard let report else {
            return "Loading accounts..."
        }
        return "\(report.totalAccounts) account\(report.totalAccounts == 1 ? "" : "s"), \(report.healthyAccounts) ready"
    }

    @MainActor
    private func setWorking(_ working: Bool) {
        isWorking = working
    }

    @MainActor
    private func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        isWorking = false
    }

    private func addAccount() {
        Task {
            await setWorking(true)
            do {
                let draft = try await CodexOAuthFlow.run(forceNewLogin: true)
                let alias = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
                let saved = try await CodexAccountManager.shared.addAccount(
                    alias: alias.isEmpty ? draft.email : alias,
                    draft: draft
                )
                await MainActor.run {
                    newAlias = ""
                    statusMessage = "Connected \(saved.alias)."
                }
                await refresh()
                notifyAccountChange()
                await setWorking(false)
            } catch {
                await setError(error)
            }
        }
    }

    private func reauthAccount(_ alias: String) {
        Task {
            await setWorking(true)
            do {
                let draft = try await CodexOAuthFlow.run(forceNewLogin: true)
                let updated = await CodexAccountManager.shared.reauthAccount(alias: alias, draft: draft)
                await MainActor.run {
                    statusMessage = updated ? "Re-authenticated \(alias)." : "Account \(alias) was not found."
                }
                await refresh()
                notifyAccountChange()
                await setWorking(false)
            } catch {
                await setError(error)
            }
        }
    }

    private func toggleAccount(_ account: CodexHealthAccount) {
        Task {
            _ = await CodexAccountManager.shared.setAccountEnabled(alias: account.alias, enabled: !account.enabled)
            await refresh()
            notifyAccountChange()
        }
    }

    private func forceAccount(_ alias: String) {
        Task {
            _ = await CodexAuthRouter.shared.setForceMode(alias: alias)
            await refresh()
        }
    }

    private func removeAccount(_ alias: String) {
        Task {
            _ = await CodexAccountManager.shared.removeAccount(alias: alias)
            await MainActor.run {
                aliasToDelete = nil
            }
            await refresh()
            notifyAccountChange()
        }
    }

    private func refresh() async {
        await CodexAccountManager.shared.refreshRecoverableAccounts()
        let newReport = await CodexAuthRouter.shared.healthReport()
        let newSettings = await CodexAccountManager.shared.getSettings()
        await MainActor.run {
            report = newReport
            settings = newSettings
        }
    }

    private func notifyAccountChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }
}

struct CodexAccountsButton: View {
    @State private var showSheet = false
    @State private var accountCount: Int = CodexAccountManager.storedAccountCount()

    var body: some View {
        Button(action: { showSheet = true }) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 12))
                if accountCount > 0 {
                    Text("\(accountCount) account\(accountCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Connect")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .buttonStyle(.bordered)
        .onAppear {
            refreshAccountCount()
        }
        .sheet(isPresented: $showSheet) {
            CodexAccountsSettingsView()
                .onDisappear {
                    refreshAccountCount()
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                }
        }
    }

    private func refreshAccountCount() {
        Task {
            let count = await CodexAccountManager.shared.accountCount()
            await MainActor.run {
                accountCount = count
            }
        }
    }
}
