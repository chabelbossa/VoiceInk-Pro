import Foundation
import os

/// Thread-safe manager for multiple API keys per provider with round-robin rotation and failover.
/// ALL keys are managed here — there is no concept of "primary" vs "additional" key.
/// Every key is equal and participates in round-robin rotation.
/// Keys are stored securely in the macOS Keychain via KeychainService.
actor MultiKeyManager {
    static let shared = MultiKeyManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MultiKeyManager")
    
    /// In-memory index of all key IDs per provider.
    /// Key: provider lowercased, Value: array of Keychain identifiers.
    private var keyIds: [String: [String]] = [:]
    
    /// Round-robin index per provider
    private var lastUsedIndex: [String: Int] = [:]
    
    /// Track temporarily failed keys (rate limited) with their failure timestamps
    private var failedKeys: [String: Set<Int>] = [:]
    private var failedKeyTimestamps: [String: [Int: Date]] = [:]
    
    /// Cooldown period before retrying a failed key (seconds)
    private let failureCooldown: TimeInterval = 60
    
    /// Metadata file that stores the key identifiers (NOT the actual keys) for persistence
    private var metadataURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("multi_keys_v2.json")
    }
    
    /// Legacy v1 metadata file (had primary/additional distinction)
    private var legacyMetadataURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        return appFolder.appendingPathComponent("multi_keys_metadata.json")
    }
    
    /// Legacy plaintext storage file
    private var legacyPlaintextURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        return appFolder.appendingPathComponent("multi_keys.json")
    }
    
    private let keychain = KeychainService.shared
    
    private init() {
        // Load metadata
        let url = metadataURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                keyIds = try JSONDecoder().decode([String: [String]].self, from: data)
                logger.info("Loaded multi-key v2 metadata for \(self.keyIds.count) providers")
            } catch {
                logger.error("Failed to load multi-key v2 metadata: \(error.localizedDescription)")
            }
        }
        
        // Migrate from legacy systems
        migrateFromLegacySystems()
    }
    
    // MARK: - Legacy Migration
    
    /// Migrates keys from ALL legacy systems:
    /// 1. APIKeyManager primary keys → MultiKeyManager
    /// 2. Old multi_keys_metadata.json (v1 additional keys) → MultiKeyManager
    /// 3. Old multi_keys.json (plaintext) → MultiKeyManager
    private func migrateFromLegacySystems() {
        var migrated = false
        
        // 1. Migrate primary keys from APIKeyManager for all providers
        for provider in ["gemini", "groq", "openai", "anthropic", "cerebras", "mistral", "openrouter", "elevenlabs", "deepgram", "soniox"] {
            if let primaryKey = APIKeyManager.shared.getAPIKey(forProvider: provider), !primaryKey.isEmpty {
                let existingValues = getAllKeyValues(forProvider: provider)
                if !existingValues.contains(primaryKey) {
                    let keyId = generateKeyId(forProvider: provider)
                    if keychain.save(primaryKey, forKey: keyId) {
                        if keyIds[provider] == nil { keyIds[provider] = [] }
                        keyIds[provider]?.append(keyId)
                        migrated = true
                        logger.info("Migrated primary key from APIKeyManager for provider: \(provider)")
                    }
                }
            }
        }
        
        // 2. Migrate from v1 metadata (additional keys)
        let v1URL = legacyMetadataURL
        if FileManager.default.fileExists(atPath: v1URL.path) {
            do {
                let data = try Data(contentsOf: v1URL)
                let v1Keys = try JSONDecoder().decode([String: [String]].self, from: data)
                
                for (provider, v1KeyIds) in v1Keys {
                    let providerLower = provider.lowercased()
                    for v1KeyId in v1KeyIds {
                        if let keyValue = keychain.getString(forKey: v1KeyId), !keyValue.isEmpty {
                            let existingValues = getAllKeyValues(forProvider: providerLower)
                            if !existingValues.contains(keyValue) {
                                // Re-use the same keychain entry, just track it
                                if keyIds[providerLower] == nil { keyIds[providerLower] = [] }
                                keyIds[providerLower]?.append(v1KeyId)
                                migrated = true
                            }
                        }
                    }
                }
                
                // Remove legacy file
                try? FileManager.default.removeItem(at: v1URL)
                logger.info("Migrated from v1 multi-key metadata")
            } catch {
                logger.error("Failed to migrate v1 metadata: \(error.localizedDescription)")
            }
        }
        
        // 3. Migrate from legacy plaintext JSON
        let plaintextURL = legacyPlaintextURL
        if FileManager.default.fileExists(atPath: plaintextURL.path) {
            do {
                let data = try Data(contentsOf: plaintextURL)
                let legacyKeys = try JSONDecoder().decode([String: [String]].self, from: data)
                
                for (provider, keys) in legacyKeys {
                    let providerLower = provider.lowercased()
                    for key in keys where !key.isEmpty {
                        let existingValues = getAllKeyValues(forProvider: providerLower)
                        if !existingValues.contains(key) {
                            let keyId = generateKeyId(forProvider: providerLower)
                            if keychain.save(key, forKey: keyId) {
                                if keyIds[providerLower] == nil { keyIds[providerLower] = [] }
                                keyIds[providerLower]?.append(keyId)
                                migrated = true
                            }
                        }
                    }
                }
                
                try? FileManager.default.removeItem(at: plaintextURL)
                logger.info("Migrated from legacy plaintext multi_keys.json")
            } catch {
                logger.error("Failed to migrate plaintext keys: \(error.localizedDescription)")
            }
        }
        
        if migrated {
            saveMetadata()
        }
    }
    
    // MARK: - Key ID Generation
    
    private func generateKeyId(forProvider provider: String) -> String {
        let uuid = UUID().uuidString.prefix(8)
        return "mk_\(provider.lowercased())_\(uuid)"
    }
    
    // MARK: - Metadata Persistence
    
    private func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(keyIds)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            logger.error("Failed to save multi-key metadata: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Key Value Retrieval (Internal)
    
    /// Gets all actual key values for a provider from Keychain
    private func getAllKeyValues(forProvider provider: String) -> [String] {
        let providerLower = provider.lowercased()
        guard let ids = keyIds[providerLower] else { return [] }
        
        var values: [String] = []
        for keyId in ids {
            if let value = keychain.getString(forKey: keyId), !value.isEmpty {
                if !values.contains(value) {
                    values.append(value)
                }
            }
        }
        return values
    }
    
    // MARK: - Public API: Key Storage
    
    /// Returns all API keys for a provider (all equal, no primary distinction)
    func getAllKeys(forProvider provider: String) -> [String] {
        return getAllKeyValues(forProvider: provider)
    }
    
    /// Adds a new API key for a provider
    @discardableResult
    func addKey(_ key: String, forProvider provider: String) -> Bool {
        let providerLower = provider.lowercased()
        
        // Check for duplicates
        let existingKeys = getAllKeyValues(forProvider: providerLower)
        if existingKeys.contains(key) {
            logger.info("Key already exists for provider: \(provider)")
            return false
        }
        
        let keyId = generateKeyId(forProvider: providerLower)
        guard keychain.save(key, forKey: keyId) else {
            logger.error("Failed to save key to Keychain for provider: \(provider)")
            return false
        }
        
        if keyIds[providerLower] == nil {
            keyIds[providerLower] = []
        }
        keyIds[providerLower]?.append(keyId)
        
        saveMetadata()
        
        let totalCount = getAllKeyValues(forProvider: providerLower).count
        logger.info("Added API key for provider: \(provider), total keys: \(totalCount)")
        return true
    }
    
    /// Removes a key at a specific index (0-based, all keys are equal)
    @discardableResult
    func removeKey(at index: Int, forProvider provider: String) -> Bool {
        let providerLower = provider.lowercased()
        
        guard var ids = keyIds[providerLower],
              index >= 0 && index < ids.count else { return false }
        
        let keyId = ids[index]
        
        // Delete from Keychain
        keychain.delete(forKey: keyId)
        
        // Remove from tracking
        ids.remove(at: index)
        keyIds[providerLower] = ids.isEmpty ? nil : ids
        
        // Reset rotation state
        lastUsedIndex[providerLower] = nil
        failedKeys[providerLower] = nil
        failedKeyTimestamps[providerLower] = nil
        
        saveMetadata()
        
        logger.info("Removed key at index \(index) for provider: \(provider)")
        return true
    }
    
    /// Removes all keys for a provider
    func removeAllKeys(forProvider provider: String) {
        let providerLower = provider.lowercased()
        
        if let ids = keyIds[providerLower] {
            for keyId in ids {
                keychain.delete(forKey: keyId)
            }
        }
        
        keyIds[providerLower] = nil
        lastUsedIndex[providerLower] = nil
        failedKeys[providerLower] = nil
        failedKeyTimestamps[providerLower] = nil
        
        saveMetadata()
    }
    
    // MARK: - Round-Robin Load Balancing
    
    /// Gets the next available API key using round-robin with failover.
    /// This is THE method that should be called for every API request.
    func getNextKey(forProvider provider: String) -> String? {
        let providerLower = provider.lowercased()
        let allKeys = getAllKeyValues(forProvider: providerLower)
        
        guard !allKeys.isEmpty else {
            logger.warning("No API keys available for provider: \(provider)")
            return nil
        }
        
        // Single key: no rotation needed
        if allKeys.count == 1 {
            return allKeys[0]
        }
        
        // Clean up expired failures
        cleanupExpiredFailures(forProvider: providerLower)
        
        // Get indices of non-failed keys
        let failedIndices = failedKeys[providerLower] ?? []
        let availableIndices = (0..<allKeys.count).filter { !failedIndices.contains($0) }
        
        // If all keys failed, reset and start over
        if availableIndices.isEmpty {
            logger.warning("All \(allKeys.count) keys failed for \(provider), resetting failures")
            failedKeys[providerLower] = nil
            failedKeyTimestamps[providerLower] = nil
            lastUsedIndex[providerLower] = 0
            return allKeys[0]
        }
        
        // Round-robin: advance to next available key
        let lastIndex = lastUsedIndex[providerLower] ?? -1
        var nextIndex = (lastIndex + 1) % allKeys.count
        
        // Find next available (non-failed) index
        var attempts = 0
        while !availableIndices.contains(nextIndex) && attempts < allKeys.count {
            nextIndex = (nextIndex + 1) % allKeys.count
            attempts += 1
        }
        
        lastUsedIndex[providerLower] = nextIndex
        
        let selectedKey = allKeys[nextIndex]
        logger.debug("Selected key #\(nextIndex + 1)/\(allKeys.count) for provider: \(provider)")
        return selectedKey
    }
    
    /// Marks a key as temporarily failed (e.g., rate limited).
    func markKeyAsFailed(_ key: String, forProvider provider: String) {
        let providerLower = provider.lowercased()
        let allKeys = getAllKeyValues(forProvider: providerLower)
        
        guard let index = allKeys.firstIndex(of: key) else { return }
        
        if failedKeys[providerLower] == nil {
            failedKeys[providerLower] = []
        }
        failedKeys[providerLower]?.insert(index)
        
        if failedKeyTimestamps[providerLower] == nil {
            failedKeyTimestamps[providerLower] = [:]
        }
        failedKeyTimestamps[providerLower]?[index] = Date()
        
        logger.warning("Marked key #\(index + 1) as failed for provider: \(provider)")
    }
    
    /// Cleans up expired failure markers
    private func cleanupExpiredFailures(forProvider provider: String) {
        guard var timestamps = failedKeyTimestamps[provider] else { return }
        
        let now = Date()
        var indicesToRemove: [Int] = []
        
        for (index, timestamp) in timestamps {
            if now.timeIntervalSince(timestamp) > failureCooldown {
                indicesToRemove.append(index)
            }
        }
        
        for index in indicesToRemove {
            timestamps.removeValue(forKey: index)
            failedKeys[provider]?.remove(index)
        }
        
        if timestamps.isEmpty {
            failedKeyTimestamps[provider] = nil
            failedKeys[provider] = nil
        } else {
            failedKeyTimestamps[provider] = timestamps
        }
    }
    
    // MARK: - Statistics
    
    /// Returns total number of API keys for a provider
    func keyCount(forProvider provider: String) -> Int {
        return getAllKeyValues(forProvider: provider.lowercased()).count
    }
    
    /// Returns whether multiple keys are available for a provider
    func hasMultipleKeys(forProvider provider: String) -> Bool {
        return keyCount(forProvider: provider) > 1
    }
    
    /// Returns whether any key exists for a provider
    func hasAnyKey(forProvider provider: String) -> Bool {
        return !getAllKeyValues(forProvider: provider.lowercased()).isEmpty
    }
}
