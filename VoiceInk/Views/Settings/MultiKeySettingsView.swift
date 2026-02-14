import SwiftUI

/// Main view for managing multiple API keys — ALL keys are equal, no primary/secondary distinction.
struct MultiKeySettingsView: View {
    let provider: String
    @State private var keys: [String] = []
    @State private var newKey: String = ""
    @State private var showAddKeyField = false
    @State private var keyToDelete: Int? = nil
    @State private var showDeleteConfirmation = false
    @State private var showBulkAdd = false
    @State private var bulkKeys: String = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Multi-Key Manager")
                        .font(.headline)
                    Text("\(provider) — \(keys.count) key\(keys.count == 1 ? "" : "s") configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 4)
            
            Divider()
            
            // Keys list
            if keys.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No API keys configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Add your API keys below. All keys rotate\nautomatically (round-robin) to avoid rate limits.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                            HStack(spacing: 8) {
                                // Key number badge
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor.opacity(0.8))
                                    .clipShape(Circle())
                                
                                Image(systemName: "key.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 11))
                                
                                Text(maskedKey(key))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Button(action: {
                                    keyToDelete = index
                                    showDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .help("Remove this key")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            
            Divider()
            
            // Add key section
            if showAddKeyField {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add API Key")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    HStack {
                        SecureField("Paste your API key here", text: $newKey)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Add") {
                            addKey()
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                        
                        Button("Cancel") {
                            newKey = ""
                            showAddKeyField = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else if showBulkAdd {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bulk Add Keys")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Paste multiple keys, one per line:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    TextEditor(text: $bulkKeys)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.secondary.opacity(0.3))
                        .cornerRadius(4)
                    
                    HStack {
                        Button("Add All") {
                            addBulkKeys()
                        }
                        .disabled(bulkKeys.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                        
                        Button("Cancel") {
                            bulkKeys = ""
                            showBulkAdd = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button(action: { showAddKeyField = true }) {
                        Label("Add Key", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { showBulkAdd = true }) {
                        Label("Bulk Add", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    if !keys.isEmpty {
                        Button(action: {
                            removeAllKeys()
                        }) {
                            Label("Clear All", systemImage: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            
            // Info section
            VStack(alignment: .leading, spacing: 6) {
                Label("How Multi-Key Works:", systemImage: "info.circle")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text("""
                All keys rotate automatically (round-robin) with each request.
                If a key hits a rate limit (429), it is skipped for 60 seconds.
                Keys are stored securely in the macOS Keychain.
                """)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .cornerRadius(8)
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .onAppear {
            loadKeys()
        }
        .alert("Remove Key?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                if let index = keyToDelete {
                    removeKey(at: index)
                }
            }
        } message: {
            Text("This API key will be permanently removed.")
        }
    }
    
    private func loadKeys() {
        Task {
            let loadedKeys = await MultiKeyManager.shared.getAllKeys(forProvider: provider)
            await MainActor.run {
                keys = loadedKeys
            }
        }
    }
    
    private func addKey() {
        let keyToAdd = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToAdd.isEmpty else { return }
        
        Task {
            let success = await MultiKeyManager.shared.addKey(keyToAdd, forProvider: provider)
            await MainActor.run {
                if success {
                    newKey = ""
                    showAddKeyField = false
                }
                loadKeys()
            }
        }
    }
    
    private func addBulkKeys() {
        let lines = bulkKeys.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !lines.isEmpty else { return }
        
        Task {
            for key in lines {
                _ = await MultiKeyManager.shared.addKey(key, forProvider: provider)
            }
            await MainActor.run {
                bulkKeys = ""
                showBulkAdd = false
                loadKeys()
            }
        }
    }
    
    private func removeKey(at index: Int) {
        Task {
            _ = await MultiKeyManager.shared.removeKey(at: index, forProvider: provider)
            await MainActor.run {
                loadKeys()
            }
        }
    }
    
    private func removeAllKeys() {
        Task {
            await MultiKeyManager.shared.removeAllKeys(forProvider: provider)
            await MainActor.run {
                loadKeys()
            }
        }
    }
    
    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "\u{2022}", count: 8) }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(suffix)"
    }
}

/// Button to open multi-key settings — this is the PRIMARY way to manage API keys
struct MultiKeyButton: View {
    let provider: String
    @State private var showSheet = false
    @State private var keyCount: Int = 0
    
    var body: some View {
        Button(action: { showSheet = true }) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 12))
                if keyCount > 0 {
                    Text("\(keyCount) key\(keyCount == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Add Keys")
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .buttonStyle(.bordered)
        .onAppear {
            refreshKeyCount()
        }
        .sheet(isPresented: $showSheet) {
            MultiKeySettingsView(provider: provider)
                .onDisappear {
                    refreshKeyCount()
                    // Notify that keys changed so UI updates
                    NotificationCenter.default.post(name: .aiProviderKeyChanged, object: nil)
                }
        }
    }
    
    private func refreshKeyCount() {
        Task {
            let count = await MultiKeyManager.shared.keyCount(forProvider: provider)
            await MainActor.run {
                keyCount = count
            }
        }
    }
}
