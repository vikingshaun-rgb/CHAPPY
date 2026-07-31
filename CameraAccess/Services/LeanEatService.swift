/*
 * LeanEat Service
 * Food nutrition analysis — uses the currently selected AI provider (Claude by default)
 */

import Foundation
import UIKit

class LeanEatService {
    private let apiKey: String
    private let baseURL: String
    private let model: String

    /// Initialize with explicit API key (uses current provider's URL + model)
    init(apiKey: String) {
        self.apiKey = apiKey
        self.baseURL = VisionAPIConfig.baseURL
        self.model = VisionAPIConfig.model
    }

    /// Initialize with current provider configuration
    convenience init() {
        self.init(apiKey: VisionAPIConfig.apiKey)
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
        let choices: [Choice]

        struct Choice: Codable {
            let message: Message

            struct Message: Codable {
                let content: String
            }
        }
    }

    // MARK: - Nutrition Analysis

    func analyzeFood(_ image: UIImage) async throws -> FoodNutritionResponse {
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw LeanEatError.invalidImage
        }

        let base64String = imageData.base64EncodedString()
        let dataURL = "data:image/jpeg;base64,\(base64String)"

        // Nutrition analysis prompt — strict JSON, English output
        let nutritionPrompt = """
You are a professional nutritionist AI. Analyze the food in the image and return the nutrition information as pure JSON.

**STRICT REQUIREMENT: return ONLY pure JSON — no extra text, no markdown fences.**
**All text values (including the name field) must be in English.**

JSON format:
{
  "foods": [
    {
      "name": "food name",
      "portion": "portion size (e.g. 1 bowl, 100 g)",
      "calories": integer calories in kcal,
      "protein": protein in grams (number),
      "fat": fat in grams (number),
      "carbs": carbohydrates in grams (number),
      "fiber": dietary fiber in grams (number, optional),
      "sugar": sugar in grams (number, optional),
      "health_rating": "one of: Excellent / Good / Fair / Poor"
    }
  ],
  "total_calories": integer total calories,
  "total_protein": total protein (number),
  "total_fat": total fat (number),
  "total_carbs": total carbohydrates (number),
  "health_score": integer health score 0-100,
  "suggestions": [
    "nutrition tip 1",
    "nutrition tip 2",
    "nutrition tip 3"
  ]
}

Return strictly in the JSON format above with no additional commentary.
"""

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
                            text: nutritionPrompt,
                            imageUrl: nil
                        )
                    ]
                )
            ]
        )

        // Make API call
        let responseText = try await makeRequest(request)

        // Parse JSON response
        return try parseNutritionResponse(responseText)
    }

    // MARK: - Private Methods

    private func makeRequest(_ request: ChatCompletionRequest) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LeanEatError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"

        // Provider-aware headers
        let headers = VisionAPIConfig.headers(with: apiKey)
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.timeoutInterval = 60

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LeanEatError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LeanEatError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

        guard let firstChoice = apiResponse.choices.first else {
            throw LeanEatError.emptyResponse
        }

        return firstChoice.message.content
    }

    private func parseNutritionResponse(_ text: String) throws -> FoodNutritionResponse {
        // Extract JSON from response (in case AI added extra text or fences)
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try to find JSON object in the response
        if let jsonStart = jsonText.range(of: "{"),
           let jsonEnd = jsonText.range(of: "}", options: .backwards) {
            jsonText = String(jsonText[jsonStart.lowerBound...jsonEnd.upperBound])
        }

        guard let jsonData = jsonText.data(using: .utf8) else {
            throw LeanEatError.invalidJSON
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(FoodNutritionResponse.self, from: jsonData)
        } catch {
            print("❌ [LeanEat] JSON parse failed: \(error)")
            print("📝 [LeanEat] Raw response: \(text)")
            throw LeanEatError.invalidJSON
        }
    }
}

// MARK: - Error Types

enum LeanEatError: LocalizedError {
    case invalidImage
    case emptyResponse
    case invalidResponse
    case invalidJSON
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Unable to process the image"
        case .emptyResponse:
            return "The API returned an empty response"
        case .invalidResponse:
            return "Invalid response format"
        case .invalidJSON:
            return "Couldn't parse the nutrition data — please try again"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        }
    }
}
