import SwiftUI

/// View for managing multiple API keys for load balancing
struct MultiKeySettingsView: View {
    let provider: String
    @State private var keys: [String] = []
    @State private var newKey: String = ""
    @State private var showAddKeyField = false
    @State private var keyToDelete: Int? = nil
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Multi-Key Load Balancing")
                        .font(.headline)
                    Text("Add multiple API keys to avoid rate limits")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 8)
            
            Divider()
            
            // Current keys list
            if keys.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No API keys configured")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Add API keys to enable automatic round-robin\nrotation and rate limit avoidance.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                            HStack {
                                Image(systemName: index == 0 ? "star.fill" : "key.fill")
                                    .foregroundColor(index == 0 ? .yellow : .secondary)
                                    .frame(width: 20)
                                
                                Text("Key \(index + 1)")
                                    .font(.system(size: 13, weight: .medium))
                                
                                Text(maskedKey(key))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                if index > 0 {
                                    Button(action: {
                                        keyToDelete = index
                                        showDeleteConfirmation = true
                                    }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text("Primary")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.1))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(10)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            
            Divider()
            
            // Add new key section
            if showAddKeyField {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add New API Key")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    HStack {
                        SecureField("Paste your API key here", text: $newKey)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Add") {
                            addKey()
                        }
                        .disabled(newKey.isEmpty)
                        .buttonStyle(.borderedProminent)
                        
                        Button("Cancel") {
                            newKey = ""
                            showAddKeyField = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Button(action: { showAddKeyField = true }) {
                    Label("Add API Key", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
            }
            
            // Info section
            VStack(alignment: .leading, spacing: 6) {
                Label("How it works:", systemImage: "info.circle")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text("Keys rotate automatically with each request (round-robin).\nIf a key hits its rate limit, it is skipped for 60 seconds.\nAll keys are stored securely in the macOS Keychain.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
        .padding(20)
        .frame(width: 450, height: 450)
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
            Text("This API key will be removed from the rotation pool.")
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
        guard !newKey.isEmpty else { return }
        let keyToAdd = newKey
        
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
    
    private func removeKey(at index: Int) {
        // Don't remove the primary key (index 0)
        guard index > 0 else { return }
        
        Task {
            // For additional keys, index in storage is index - 1
            _ = await MultiKeyManager.shared.removeKey(at: index - 1, forProvider: provider)
            await MainActor.run {
                loadKeys()
            }
        }
    }
    
    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "\u{2022}", count: 8) }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(4))
        return "\(prefix)\u{2022}\u{2022}\u{2022}\u{2022}\(suffix)"
    }
}

/// Button to open multi-key settings (to be used in AI provider settings)
struct MultiKeyButton: View {
    let provider: String
    @State private var showSheet = false
    @State private var keyCount: Int = 0
    
    var body: some View {
        Button(action: { showSheet = true }) {
            HStack(spacing: 4) {
                Image(systemName: "key.horizontal.fill")
                if keyCount > 1 {
                    Text("\(keyCount) keys")
                        .font(.caption)
                } else {
                    Text("Multi-Key")
                        .font(.caption)
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
