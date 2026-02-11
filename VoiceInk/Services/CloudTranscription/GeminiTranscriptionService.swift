import Foundation
import os

class GeminiTranscriptionService {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "GeminiService")
    
    /// Maximum number of retry attempts when rate limited with multiple keys
    private let maxRetries = 3
    
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        logger.notice("Starting Gemini transcription with model: \(model.name, privacy: .public)")
        
        guard let audioData = try? Data(contentsOf: audioURL) else {
            throw CloudTranscriptionError.audioFileNotFound
        }
        
        logger.notice("Audio file loaded, size: \(audioData.count) bytes")
        
        let base64AudioData = audioData.base64EncodedString()
        
        // Try with multi-key rotation and retry on rate limit
        let multiKeyManager = MultiKeyManager.shared
        let totalKeys = await multiKeyManager.keyCount(forProvider: "Gemini")
        let maxAttempts = max(totalKeys, 1) * maxRetries
        
        var attempts = 0
        var currentDelay: TimeInterval = 1.0
        
        while attempts < maxAttempts {
            // Get the next API key via round-robin
            guard let apiKey = await multiKeyManager.getNextKey(forProvider: "Gemini") else {
                throw CloudTranscriptionError.missingAPIKey
            }
            
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.name):generateContent"
            guard let apiURL = URL(string: urlString) else {
                throw CloudTranscriptionError.dataEncodingError
            }
            
            var request = URLRequest(url: apiURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            
            let requestBody = GeminiRequest(
                contents: [
                    GeminiContent(
                        parts: [
                            .text(GeminiTextPart(text: "Please transcribe this audio file. Provide only the transcribed text.")),
                            .audio(GeminiAudioPart(
                                inlineData: GeminiInlineData(
                                    mimeType: "audio/wav",
                                    data: base64AudioData
                                )
                            ))
                        ]
                    )
                ]
            )
            
            do {
                let jsonData = try JSONEncoder().encode(requestBody)
                request.httpBody = jsonData
                logger.notice("Request body encoded, sending to Gemini API (attempt \(attempts + 1)/\(maxAttempts))")
            } catch {
                logger.error("Failed to encode Gemini request: \(error.localizedDescription)")
                throw CloudTranscriptionError.dataEncodingError
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
            }
            
            // Handle rate limit: mark key as failed and try next one
            if httpResponse.statusCode == 429 {
                await multiKeyManager.markKeyAsFailed(apiKey, forProvider: "Gemini")
                attempts += 1
                
                if attempts < maxAttempts {
                    // Apply backoff after full key rotation
                    if totalKeys > 1 && attempts % totalKeys == 0 {
                        logger.warning("All Gemini keys rate-limited, backing off \(currentDelay)s...")
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    } else if totalKeys <= 1 {
                        logger.warning("Gemini rate limited, retrying in \(currentDelay)s...")
                        try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay *= 2
                    } else {
                        logger.warning("Gemini key rate-limited, trying next key...")
                    }
                    continue
                } else {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Rate limit exceeded"
                    throw CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: errorMessage)
                }
            }
            
            if !(200...299).contains(httpResponse.statusCode) {
                let errorMessage = String(data: data, encoding: .utf8) ?? "No error message"
                logger.error("Gemini API request failed with status \(httpResponse.statusCode): \(errorMessage, privacy: .public)")
                throw CloudTranscriptionError.apiRequestFailed(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            do {
                let transcriptionResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
                guard let candidate = transcriptionResponse.candidates.first,
                      let part = candidate.content.parts.first,
                      !part.text.isEmpty else {
                    logger.error("No transcript found in Gemini response")
                    throw CloudTranscriptionError.noTranscriptionReturned
                }
                logger.notice("Gemini transcription successful, text length: \(part.text.count)")
                return part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                logger.error("Failed to decode Gemini API response: \(error.localizedDescription)")
                throw CloudTranscriptionError.noTranscriptionReturned
            }
        }
        
        throw CloudTranscriptionError.apiRequestFailed(statusCode: 429, message: "All API keys exhausted after \(maxAttempts) attempts")
    }
    
    // MARK: - Request/Response Models
    
    private struct GeminiRequest: Codable {
        let contents: [GeminiContent]
    }
    
    private struct GeminiContent: Codable {
        let parts: [GeminiPart]
    }
    
    private enum GeminiPart: Codable {
        case text(GeminiTextPart)
        case audio(GeminiAudioPart)
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let textPart):
                try container.encode(textPart)
            case .audio(let audioPart):
                try container.encode(audioPart)
            }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let textPart = try? container.decode(GeminiTextPart.self) {
                self = .text(textPart)
            } else if let audioPart = try? container.decode(GeminiAudioPart.self) {
                self = .audio(audioPart)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid part"))
            }
        }
    }
    
    private struct GeminiTextPart: Codable {
        let text: String
    }
    
    private struct GeminiAudioPart: Codable {
        let inlineData: GeminiInlineData
    }
    
    private struct GeminiInlineData: Codable {
        let mimeType: String
        let data: String
    }
    
    private struct GeminiResponse: Codable {
        let candidates: [GeminiCandidate]
    }
    
    private struct GeminiCandidate: Codable {
        let content: GeminiResponseContent
    }
    
    private struct GeminiResponseContent: Codable {
        let parts: [GeminiResponsePart]
    }
    
    private struct GeminiResponsePart: Codable {
        let text: String
    }
}