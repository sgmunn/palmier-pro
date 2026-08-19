import Foundation

struct CustomImageGenerationRequest: Encodable, Sendable {
    let model: String
    let prompt: String
    let n: Int
    let aspectRatio: String
    let resolution: String?
    let quality: String?

    private enum CodingKeys: String, CodingKey {
        case model, prompt, n, quality
        case aspectRatio = "aspect_ratio"
        case resolution
    }
}

struct CustomImageGenerationResponse: Decodable, Sendable {
    struct Output: Decodable, Sendable {
        let url: URL?
        let base64: String?

        private enum CodingKeys: String, CodingKey {
            case url
            case base64 = "b64_json"
        }
    }

    let data: [Output]
}

enum CustomGenerationError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case unsupported(String)
    case invalidResponse(String)
    case gateway(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .unsupported(let message), .invalidResponse(let message): message
        case .gateway(let status, let message): "Gateway error (\(status)): \(message)"
        }
    }
}
