//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
import Testing
@testable import VoiceInk_Pro

struct VoiceInkTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func codexCatalogIncludesGPT56FamilyAndLeanFallbacks() {
        #expect(CodexModelCatalog.defaultModelID == "codex:gpt-5.6-terra")
        #expect(CodexModelCatalog.modelIDs == [
            "codex:gpt-5.6-sol",
            "codex:gpt-5.6-terra",
            "codex:gpt-5.6-luna",
            "codex:gpt-5.5",
            "codex:gpt-5.4",
            "codex:gpt-5.4-mini",
            "codex:gpt-5.3-codex-spark"
        ])
        #expect(!CodexModelCatalog.modelIDs.contains("codex:gpt-5.2"))
        #expect(!CodexModelCatalog.modelIDs.contains("codex:gpt-5.1"))
        #expect(!CodexModelCatalog.modelIDs.contains("codex:gpt-5"))
    }

    @Test func codexReasoningEffortsAreBoundedByModelGeneration() throws {
        let terra = try #require(CodexModelCatalog.option(for: "codex:gpt-5.6-terra"))
        let legacy = try #require(CodexModelCatalog.option(for: "codex:gpt-5.5"))

        #expect(terra.defaultReasoningEffort == .low)
        #expect(terra.supportedReasoningEfforts.contains(.max))
        #expect(!legacy.supportedReasoningEfforts.contains(.max))
        #expect(CodexModelCatalog.effectiveReasoningEffort(.max, for: legacy.id) == .low)
        #expect(CodexModelCatalog.effectiveReasoningEffort(.max, for: terra.id) == .max)
    }

    @Test func codexRequestBodyIncludesModelReasoningAndFastTier() throws {
        let body = CodexResponsesClient.makeRequestBody(
            model: "gpt-5.6-terra",
            systemPrompt: "Improve the transcript.",
            userPrompt: "hello world",
            reasoningEffort: .low,
            serviceTier: "priority"
        )
        let reasoning = try #require(body["reasoning"] as? [String: String])

        #expect(body["model"] as? String == "gpt-5.6-terra")
        #expect(reasoning["effort"] == "low")
        #expect(reasoning["context"] == "all_turns")
        #expect(body["service_tier"] as? String == "priority")
        #expect(body["parallel_tool_calls"] as? Bool == false)
        #expect(body["instructions"] == nil)
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.first?["type"] as? String == "additional_tools")
        #expect(input.dropFirst().first?["role"] as? String == "developer")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
    }

    @Test func codexAccountIDIsReadFromOfficialJWTClaim() throws {
        let claims: [String: Any] = [
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-voiceink"]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: claims)
        let payload = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"

        #expect(CodexResponsesClient.chatGPTAccountID(fromIDToken: token) == "account-voiceink")
    }

    @Test func codexOAuthGPT56FamilyIntegration() async throws {
        guard ProcessInfo.processInfo.environment["VOICEINK_RUN_CODEX_INTEGRATION"] == "1" else {
            return
        }

        let cases: [(model: String, effort: CodexReasoningEffort)] = [
            ("gpt-5.6-sol", .low),
            ("gpt-5.6-luna", .low),
            ("gpt-5.6-terra", .low),
            ("gpt-5.6-terra", .medium),
            ("gpt-5.6-terra", .high),
            ("gpt-5.6-terra", .xhigh),
            ("gpt-5.6-terra", .max)
        ]

        for testCase in cases {
            let startedAt = Date()
            let result = try await CodexResponsesClient.shared.generateResponse(
                model: testCase.model,
                systemPrompt: "Return only the corrected transcript. Preserve its language and meaning.",
                userPrompt: "<TRANSCRIPT>bonjour euh merci</TRANSCRIPT>",
                reasoningEffort: testCase.effort,
                timeout: 45
            )
            let elapsed = Date().timeIntervalSince(startedAt)

            #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            print("CODEX_INTEGRATION model=\(testCase.model) effort=\(testCase.effort.rawValue) tier=\(result.serviceTier.rawValue) elapsed=\(String(format: "%.2f", elapsed))s")
        }
    }

}
