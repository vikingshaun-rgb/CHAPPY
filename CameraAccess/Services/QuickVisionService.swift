/*
 * Quick Vision Service
 * Quick Vision service — multi-provider (Claude/Gemini/OpenRouter)
 * Returns a concise description suitable for TTS
 */

import Foundation
import UIKit

class QuickVisionService {
    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let provider: APIProvider

    /// Initialize with explicit configuration
    init(apiKey: String, baseURL: String? = nil, model: String? = nil) {
        self.apiKey = apiKey
        self.provider = VisionAPIConfig.provider
        self.baseURL = baseURL ?? VisionAPIConfig.baseURL
        self.model = model ?? VisionAPIConfig.model
    }

    /// Initialize with current provider configuration
    convenience init() {
        self.init(
            apiKey: VisionAPIConfig.apiKey,
            baseURL: VisionAPIConfig.baseURL,
            model: VisionAPIConfig.model
        )
    }

    // MARK: - API Request/Response Models

    struct ChatCompletionRequest: Codable {
        let model: String
        let messages: [Message]

        struct Message: Codable {
            let role: String
            let content: [Content]

            struct Content: Codable {
                let type: String
                let text: String?
                let imageUrl: ImageURL?

                enum CodingKeys: String, CodingKey {
                    case type
                    case text
                    case imageUrl = "image_url"
                }

                struct ImageURL: Codable {
                    let url: String
                }
            }
        }
    }

    struct ChatCompletionResponse: Codable {
        let choices: [Choice]?
        let error: APIError?

        struct Choice: Codable {
            let message: Message?
            let delta: Delta?

            struct Message: Codable {
                let content: String?
            }

            struct Delta: Codable {
                let content: String?
            }
        }

        struct APIError: Codable {
            let message: String?
            let code: Int?
        }
    }

    // MARK: - Quick Vision Analysis

    /// Quick Vision — returns a concise spoken description
    /// - Parameters:
    ///   - image: The image to recognize
    ///   - customPrompt: Custom prompt (optional; falls back to the current mode's prompt when nil)
    ///   - deepAnalysis: escalate to the big model with extended thinking for a careful look
    /// - Returns: Concise description text suitable for TTS
    func analyzeImage(_ image: UIImage, customPrompt: String? = nil, deepAnalysis: Bool = false) async throws -> String {
        // Use the custom prompt, the mode manager's prompt, or the default
        let prompt = customPrompt ?? QuickVisionModeManager.staticPrompt

        // CLAUDE NATIVE PATH: the OpenAI-compatible endpoint locks out
        // Anthropic's native powers (web search, thinking, prompt caching,
        // proper vision). When the provider is Claude, use the real
        // Messages API instead.
        if provider == .anthropic {
            // Higher quality for Claude — it reads fine print happily
            guard let imageData = image.jpegData(compressionQuality: 0.85) else {
                throw QuickVisionError.invalidImage
            }
            return try await makeAnthropicRequest(
                imageB64: imageData.base64EncodedString(),
                prompt: prompt,
                deep: deepAnalysis
            )
        }

        // Convert image to base64 (OpenAI-compatible providers)
        guard let imageData = image.jpegData(compressionQuality: 0.7) else {
            throw QuickVisionError.invalidImage
        }

        let base64String = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64String)"

        // Create API request
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                ChatCompletionRequest.Message(
                    role: "user",
                    content: [
                        ChatCompletionRequest.Message.Content(
                            type: "image_url",
                            text: nil,
                            imageUrl: ChatCompletionRequest.Message.Content.ImageURL(url: dataURL)
                        ),
                        ChatCompletionRequest.Message.Content(
                            type: "text",
                            text: prompt,
                            imageUrl: nil
                        )
                    ]
                )
            ]
        )

        // Make API call
        return try await makeRequest(request)
    }

    // MARK: - Anthropic Native Messages API

    private static let chappySystemPrompt = """
    You are Chappy, the personal assistant of Shaun, an Australian traveller, \
    looking at a photo taken through his smart glasses. NEVER mention Claude, \
    Anthropic, or being an AI model - you are simply Chappy. Answer concisely \
    and speak-ably (your answer is read aloud): lead with the answer, exact \
    words and numbers when text is visible, verbatim reading when asked. \
    When asked about food or products, read labels and flag allergens. \
    When text is in a foreign language, translate it and give the original \
    name too. Use web search when current real-world facts would improve \
    the answer (prices, opening hours, reviews, what a place or product is).
    """

    private func makeAnthropicRequest(imageB64: String, prompt: String, deep: Bool) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw QuickVisionError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.timeoutInterval = deep ? 120 : 60

        // DEEP LOOK: escalate to the big model with extended thinking
        let useModel = deep ? "claude-opus-4-8" : model

        var body: [String: Any] = [
            "model": useModel,
            "max_tokens": deep ? 8192 : 1024,
            // cache_control: the system prompt is cached server-side —
            // repeat snaps get faster and ~90% cheaper
            "system": [[
                "type": "text",
                "text": QuickVisionService.chappySystemPrompt,
                "cache_control": ["type": "ephemeral"]
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": imageB64]],
                    // PHASE 4: context rides in the USER text (not the system
                    // prompt) so the cached system prompt stays cache-hittable
                    ["type": "text", "text": prompt + "\n\n[Context: " + ContextEngine.shared.contextHeader() + "]"]
                ]
            ]],
            "tools": [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 3
            ]]
        ]
        if deep {
            body["thinking"] = ["type": "enabled", "budget_tokens": 4096]
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("📡 [QuickVision] Claude native request → \(useModel)\(deep ? " (deep)" : "")")
        var (data, response) = try await URLSession.shared.data(for: urlRequest)

        // Graceful degrade: if this API version rejects the web_search tool,
        // retry once without tools rather than failing the whole snap.
        if let http = response as? HTTPURLResponse, http.statusCode == 400,
           let bodyText = String(data: data, encoding: .utf8), bodyText.contains("web_search") {
            print("⚠️ [QuickVision] web_search tool rejected — retrying without tools")
            body["tools"] = nil
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuickVisionError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ [QuickVision] Claude error \(httpResponse.statusCode): \(errorMessage.prefix(300))")
            throw QuickVisionError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw QuickVisionError.invalidResponse
        }

        // Join all text blocks (skips thinking/tool blocks automatically)
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: " ")

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuickVisionError.emptyResponse }

        print("✅ [QuickVision] Claude result: \(trimmed.prefix(120))")
        return trimmed
    }

    // MARK: - Private Methods

    private func makeRequest(_ request: ChatCompletionRequest) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw QuickVisionError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"

        // Set headers based on provider
        let headers = VisionAPIConfig.headers(with: apiKey)
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        urlRequest.timeoutInterval = 60 // 60second timeout (OpenRouter can take longer)

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        print("📡 [QuickVision] Sending request to \(model) via \(provider.displayName)...")
        print("📡 [QuickVision] URL: \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuickVisionError.invalidResponse
        }

        // Log raw response for debugging
        let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode"
        print("📡 [QuickVision] HTTP Status: \(httpResponse.statusCode)")
        print("📡 [QuickVision] Raw response: \(rawResponse.prefix(500))")

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ [QuickVision] API error: \(httpResponse.statusCode) - \(errorMessage)")
            throw QuickVisionError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let decoder = JSONDecoder()
        let apiResponse: ChatCompletionResponse

        do {
            apiResponse = try decoder.decode(ChatCompletionResponse.self, from: data)
        } catch {
            print("❌ [QuickVision] JSON decode error: \(error)")
            throw QuickVisionError.invalidResponse
        }

        // Check for API error in response body
        if let apiError = apiResponse.error {
            let errorMsg = apiError.message ?? "Unknown API error"
            print("❌ [QuickVision] API returned error: \(errorMsg)")
            throw QuickVisionError.apiError(statusCode: apiError.code ?? -1, message: errorMsg)
        }

        // Get content from choices
        guard let choices = apiResponse.choices, let firstChoice = choices.first else {
            print("❌ [QuickVision] No choices in response")
            throw QuickVisionError.emptyResponse
        }

        // Try message.content first, then delta.content
        let content = firstChoice.message?.content ?? firstChoice.delta?.content

        guard let result = content, !result.isEmpty else {
            print("❌ [QuickVision] Empty content in response")
            throw QuickVisionError.emptyResponse
        }

        let trimmedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        print("✅ [QuickVision] Result: \(trimmedResult)")

        return trimmedResult
    }
}

// MARK: - Error Types

enum QuickVisionError: LocalizedError {
    case noDevice
    case streamNotReady
    case frameTimeout
    case invalidImage
    case emptyResponse
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "Glasses not connected — pair them in the Meta AI app first"
        case .streamNotReady:
            return "Video stream failed to start — check the glasses connection"
        case .frameTimeout:
            return "Timed out waiting for a video frame — please retry"
        case .invalidImage:
            return "Unable to process the image"
        case .emptyResponse:
            return "AIreturned an empty response — please retry"
        case .invalidResponse:
            return "Invalid response format"
        case .apiError(let statusCode, let message):
            return "APIError (\(statusCode)): \(message)"
        }
    }
}
