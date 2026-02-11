import Foundation
import os

/// Manages multiple API keys per provider with load balancing and failover capabilities
final class MultiKeyManager {
    static let shared = MultiKeyManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MultiKeyManager")
    
    /// Storage file location (in Application Support, persists across reinstalls)
    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
        
        // Create folder if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        return appFolder.appendingPathComponent("multi_keys.json")
    }
    
    /// Track last used key index per provider for round-robin
    private var lastUsedIndex: [String: Int] = [:]
    
    /// Track failed keys temporarily (rate limited)
    private var failedKeys: [String: Set<Int>] = [:]
    private var failedKeyTimestamps: [String: [Int: Date]] = [:]
    
    /// Cooldown period before retrying a failed key (in seconds)
    private let failureCooldown: TimeInterval = 60
    
    /// In-memory cache of stored keys
    private var storedKeys: [String: [String]] = [:]
    
    private init() {
        loadFromDisk()
    }
    
    // MARK: - Persistent File Storage
    
    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: storageURL)
            storedKeys = try JSONDecoder().decode([String: [String]].self, from: data)
            logger.info("Loaded \(self.storedKeys.count) providers from disk")
        } catch {
            logger.error("Failed to load keys: \(error.localizedDescription)")
        }
    }
    
    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(storedKeys)
            try data.write(to: storageURL, options: .atomic)
            logger.info("Saved keys to disk")
        } catch {
            logger.error("Failed to save keys: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Multi-Key Storage
    
    /// Returns all API keys for a provider
    func getAllKeys(forProvider provider: String) -> [String] {
        let providerLower = provider.lowercased()
        
        // First, check if there's a primary key from APIKeyManager
        var keys: [String] = []
        if let primaryKey = APIKeyManager.shared.getAPIKey(forProvider: provider) {
            keys.append(primaryKey)
        }
        
        // Then get additional keys from our persistent storage
        if let additionalKeys = storedKeys[providerLower] {
            for key in additionalKeys {
                // Avoid duplicates with primary key
                if !keys.contains(key) && !key.isEmpty {
                    keys.append(key)
                }
            }
        }
        
        return keys
    }
    
    /// Adds a new API key for a provider
    @discardableResult
    func addKey(_ key: String, forProvider provider: String) -> Bool {
        let providerLower = provider.lowercased()
        
        // Check if key already exists
        let existingKeys = getAllKeys(forProvider: provider)
        if existingKeys.contains(key) {
            logger.info("Key already exists for provider: \(provider)")
            return false
        }
        
        // Add the new key
        if storedKeys[providerLower] == nil {
            storedKeys[providerLower] = []
        }
        storedKeys[providerLower]?.append(key)
        
        saveToDisk()
        
        logger.info("Added API key #\(self.storedKeys[providerLower]?.count ?? 0) for provider: \(provider)")
        return true
    }
    
    /// Removes an API key at a specific index (0 = first additional key, not primary)
    @discardableResult
    func removeKey(at index: Int, forProvider provider: String) -> Bool {
        let providerLower = provider.lowercased()
        
        guard var additionalKeys = storedKeys[providerLower],
              index >= 0 && index < additionalKeys.count else { return false }
        
        additionalKeys.remove(at: index)
        storedKeys[providerLower] = additionalKeys
        
        saveToDisk()
        
        logger.info("Removed API key at index \(index) for provider: \(provider)")
        return true
    }
    
    /// Removes all additional keys for a provider (keeps primary)
    func removeAllAdditionalKeys(forProvider provider: String) {
        let providerLower = provider.lowercased()
        storedKeys[providerLower] = nil
        saveToDisk()
        lastUsedIndex[providerLower] = nil
        failedKeys[providerLower] = nil
    }
    
    // MARK: - Load Balancing
    
    /// Gets the next available API key using round-robin with failover
    func getNextKey(forProvider provider: String) -> String? {
        let providerLower = provider.lowercased()
        let allKeys = getAllKeys(forProvider: provider)
        
        guard !allKeys.isEmpty else { return nil }
        
        // Clean up expired failures
        cleanupExpiredFailures(forProvider: providerLower)
        
        // Get available keys (not currently failed)
        let failedIndices = failedKeys[providerLower] ?? []
        let availableIndices = (0..<allKeys.count).filter { !failedIndices.contains($0) }
        
        // If all keys failed, return the first one anyway (reset)
        guard !availableIndices.isEmpty else {
            logger.warning("All keys failed for \(provider), resetting failures")
            failedKeys[providerLower] = nil
            failedKeyTimestamps[providerLower] = nil
            return allKeys.first
        }
        
        // Round-robin selection among available keys
        let lastIndex = lastUsedIndex[providerLower] ?? -1
        var nextIndex = lastIndex + 1
        
        // Find next available index
        while !availableIndices.contains(nextIndex % allKeys.count) {
            nextIndex += 1
            if nextIndex > allKeys.count * 2 { break } // Safety
        }
        
        let selectedIndex = nextIndex % allKeys.count
        lastUsedIndex[providerLower] = selectedIndex
        
        return allKeys[selectedIndex]
    }
    
    /// Marks a key as failed (rate limited)
    func markKeyAsFailed(_ key: String, forProvider provider: String) {
        let providerLower = provider.lowercased()
        let allKeys = getAllKeys(forProvider: provider)
        
        guard let index = allKeys.firstIndex(of: key) else { return }
        
        if failedKeys[providerLower] == nil {
            failedKeys[providerLower] = []
        }
        failedKeys[providerLower]?.insert(index)
        
        if failedKeyTimestamps[providerLower] == nil {
            failedKeyTimestamps[providerLower] = [:]
        }
        failedKeyTimestamps[providerLower]?[index] = Date()
        
        logger.warning("Marked key #\(index) as failed for provider: \(provider)")
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
    
    /// Returns the count of API keys for a provider
    func keyCount(forProvider provider: String) -> Int {
        return getAllKeys(forProvider: provider).count
    }
    
    /// Returns whether multi-key is enabled for a provider
    func hasMultipleKeys(forProvider provider: String) -> Bool {
        return keyCount(forProvider: provider) > 1
    }
}
