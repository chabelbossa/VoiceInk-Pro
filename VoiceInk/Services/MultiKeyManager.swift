import Foundation
import os

/// Thread-safe manager for multiple API keys per provider with round-robin rotation and failover.
/// All keys are stored securely in the macOS Keychain via KeychainService.
/// The primary key (index 0) is managed by APIKeyManager; additional keys are managed here.
actor MultiKeyManager {
    static let shared = MultiKeyManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MultiKeyManager")
    
    /// In-memory index of additional keys per provider (the actual key values live in Keychain).
    /// Key: provider lowercased, Value: array of Keychain identifiers for additional keys.
    private var additionalKeyIds: [String: [String]] = [:]
    
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
        return appFolder.appendingPathComponent("multi_keys_metadata.json")
    }
    
    /// Legacy storage file to migrate from
    private var legacyStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        return appFolder.appendingPathComponent("multi_keys.json")
    }
    
    private let keychain = KeychainService.shared
    
    private init() {
        // Load metadata synchronously during init (actor is not yet isolated here)
        let url = metadataURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                additionalKeyIds = try JSONDecoder().decode([String: [String]].self, from: data)
                logger.info("Loaded multi-key metadata for \(self.additionalKeyIds.count) providers")
            } catch {
                logger.error("Failed to load multi-key metadata: \(error.localizedDescription)")
            }
        }
        
        // Migrate from legacy plaintext storage if it exists
        let legacyURL = legacyStorageURL
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            migrateLegacyKeys(from: legacyURL)
        }
    }
    
    // MARK: - Legacy Migration
    
    /// Migrates keys from the old plaintext JSON file to Keychain
    private func migrateLegacyKeys(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let legacyKeys = try JSONDecoder().decode([String: [String]].self, from: data)
            
            var migratedCount = 0
            for (provider, keys) in legacyKeys {
                let providerLower = provider.lowercased()
                for key in keys where !key.isEmpty {
                    // Check if already migrated (avoid duplicates)
                    let existingKeys = getAllKeysSync(forProvider: providerLower)
                    if !existingKeys.contains(key) {
                        let keyId = generateKeyId(forProvider: providerLower)
                        if keychain.save(key, forKey: keyId) {
                            if additionalKeyIds[providerLower] == nil {
                                additionalKeyIds[providerLower] = []
                            }
                            additionalKeyIds[providerLower]?.append(keyId)
                            migratedCount += 1
                        }
                    }
                }
            }
            
            if migratedCount > 0 {
                saveMetadata()
                logger.info("Migrated \(migratedCount) keys from legacy plaintext storage to Keychain")
            }
            
            // Remove legacy file after successful migration
            try? FileManager.default.removeItem(at: url)
            logger.info("Removed legacy multi_keys.json file")
        } catch {
            logger.error("Failed to migrate legacy keys: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Key ID Generation
    
    /// Generates a unique Keychain identifier for an additional key
    private func generateKeyId(forProvider provider: String) -> String {
        let uuid = UUID().uuidString.prefix(8)
        return "multikey_\(provider.lowercased())_\(uuid)"
    }
    
    // MARK: - Metadata Persistence
    
    /// Saves the key identifiers (not values) to disk for persistence across restarts
    private func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(additionalKeyIds)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            logger.error("Failed to save multi-key metadata: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Key Storage
    
    /// Returns all API keys for a provider (primary + additional), reading values from Keychain
    func getAllKeys(forProvider provider: String) -> [String] {
        return getAllKeysSync(forProvider: provider)
    }
    
    /// Internal synchronous version (used during migration and init)
    private func getAllKeysSync(forProvider provider: String) -> [String] {
        let providerLower = provider.lowercased()
        var keys: [String] = []
        
        // Get primary key from APIKeyManager
        if let primaryKey = APIKeyManager.shared.getAPIKey(forProvider: provider), !primaryKey.isEmpty {
            keys.append(primaryKey)
        }
        
        // Get additional keys from Keychain using stored identifiers
        if let keyIds = additionalKeyIds[providerLower] {
            for keyId in keyIds {
                if let keyValue = keychain.getString(forKey: keyId), !keyValue.isEmpty {
                    // Avoid duplicates with primary key
                    if !keys.contains(keyValue) {
                        keys.append(keyValue)
                    }
                }
            }
        }
        
        return keys
    }
    
    /// Adds a new API key for a provider, stored securely in Keychain
    @discardableResult
    func addKey(_ key: String, forProvider provider: String) -> Bool {
        let providerLower = provider.lowercased()
        
        // Check for duplicates
        let existingKeys = getAllKeysSync(forProvider: provider)
        if existingKeys.contains(key) {
            logger.info("Key already exists for provider: \(provider)")
            return false
        }
        
        // Generate a unique Keychain identifier and store the key
        let keyId = generateKeyId(forProvider: providerLower)
        guard keychain.save(key, forKey: keyId) else {
            logger.error("Failed to save additional key to Keychain for provider: \(provider)")
            return false
        }
        
        // Track the key identifier
        if additionalKeyIds[providerLower] == nil {
            additionalKeyIds[providerLower] = []
        }
        additionalKeyIds[providerLower]?.append(keyId)
        
        saveMetadata()
        
        let totalCount = getAllKeysSync(forProvider: provider).count
        logger.info("Added API key for provider: \(provider), total keys: \(totalCount)")
        return true
    }
    
    /// Removes an additional key at a specific index (0-based index within additional keys only, not including primary)
    @discardableResult
    func removeKey(at index: Int, forProvider provider: String) -> Bool {
        let providerLower = provider.lowercased()
        
        guard var keyIds = additionalKeyIds[providerLower],
              index >= 0 && index < keyIds.count else { return false }
        
        let keyId = keyIds[index]
        
        // Delete from Keychain
        keychain.delete(forKey: keyId)
        
        // Remove from tracking
        keyIds.remove(at: index)
        additionalKeyIds[providerLower] = keyIds.isEmpty ? nil : keyIds
        
        // Reset rotation state for this provider
        lastUsedIndex[providerLower] = nil
        failedKeys[providerLower] = nil
        failedKeyTimestamps[providerLower] = nil
        
        saveMetadata()
        
        logger.info("Removed additional key at index \(index) for provider: \(provider)")
        return true
    }
    
    /// Removes all additional keys for a provider (keeps primary)
    func removeAllAdditionalKeys(forProvider provider: String) {
        let providerLower = provider.lowercased()
        
        // Delete all additional keys from Keychain
        if let keyIds = additionalKeyIds[providerLower] {
            for keyId in keyIds {
                keychain.delete(forKey: keyId)
            }
        }
        
        additionalKeyIds[providerLower] = nil
        lastUsedIndex[providerLower] = nil
        failedKeys[providerLower] = nil
        failedKeyTimestamps[providerLower] = nil
        
        saveMetadata()
    }
    
    // MARK: - Round-Robin Load Balancing
    
    /// Gets the next available API key using round-robin with failover.
    /// This is the primary method that should be called for every API request.
    func getNextKey(forProvider provider: String) -> String? {
        let providerLower = provider.lowercased()
        let allKeys = getAllKeysSync(forProvider: provider)
        
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
    /// The key will be skipped for `failureCooldown` seconds.
    func markKeyAsFailed(_ key: String, forProvider provider: String) {
        let providerLower = provider.lowercased()
        let allKeys = getAllKeysSync(forProvider: provider)
        
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
    
    /// Returns total number of API keys for a provider (primary + additional)
    func keyCount(forProvider provider: String) -> Int {
        return getAllKeysSync(forProvider: provider).count
    }
    
    /// Returns whether multiple keys are available for a provider
    func hasMultipleKeys(forProvider provider: String) -> Bool {
        return keyCount(forProvider: provider) > 1
    }
    
    /// Returns whether any key exists for a provider (used to check configuration)
    func hasAnyKey(forProvider provider: String) -> Bool {
        return !getAllKeysSync(forProvider: provider).isEmpty
    }
}
