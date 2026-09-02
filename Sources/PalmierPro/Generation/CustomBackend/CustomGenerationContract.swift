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

struct CustomAudioGenerationRequest: Encodable, Sendable {
    let model: String
    let input: String
    let voice: String
    let responseFormat: String

    private enum CodingKeys: String, CodingKey {
        case model, input, voice
        case responseFormat = "response_format"
    }
}

struct CustomAudioGenerationResponse: Sendable {
    let data: Data
    let mimeType: String?
}

struct CustomVideoGenerationRequest: Encodable, Sendable {
    struct FrameImage: Encodable, Sendable {
        let inputImage: String
        let frame: Int

        private enum CodingKeys: String, CodingKey {
            case inputImage = "input_image"
            case frame
        }
    }

    let model: String
    let prompt: String
    let width: Int
    let height: Int
    let seconds: String
    let generateAudio: Bool?
    let frameImages: [FrameImage]?

    private enum CodingKeys: String, CodingKey {
        case model, prompt, width, height, seconds
        case generateAudio = "generate_audio"
        case frameImages = "frame_images"
    }
}

enum CustomVideoJobStatus: Equatable, Sendable {
    case queued
    case inProgress
    case completed(videoURL: URL)
    case failed(message: String)
}

struct CustomVideoJobResponse: Decodable, Sendable {
    struct Output: Decodable, Sendable {
        let videoURL: URL?

        private enum CodingKeys: String, CodingKey {
            case videoURL = "video_url"
        }
    }

    struct Failure: Decodable, Sendable {
        let message: String?
        let code: String?
    }

    let id: String
    let model: String?
    let rawStatus: String
    let outputs: Output?
    let error: Failure?

    private enum CodingKeys: String, CodingKey {
        case id, model, outputs, error
        case rawStatus = "status"
    }

    var status: CustomVideoJobStatus {
        get throws {
            switch rawStatus {
            case "queued": return .queued
            case "in_progress": return .inProgress
            case "completed":
                guard let url = outputs?.videoURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw CustomGenerationError.invalidResponse(
                        "Gateway completed the video job without a valid video URL."
                    )
                }
                return .completed(videoURL: url)
            case "failed":
                return .failed(message: error?.message ?? "Video generation failed.")
            default:
                throw CustomGenerationError.invalidResponse(
                    "Gateway returned unknown video status '" + rawStatus + "'."
                )
            }
        }
    }
}

struct CustomVideoJobReceipt: Equatable, Sendable {
    let backendID: String
    let remoteModelID: String
    let jobID: String
}

enum CustomGenerationError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case unsupported(String)
    case invalidResponse(String)
    case gateway(status: Int, message: String)
    case videoFailed(String)
    case videoSubmissionTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .unsupported(let message), .invalidResponse(let message),
             .videoFailed(let message): message
        case .gateway(let status, let message): "Gateway error (\(status)): \(message)"
        case .videoSubmissionTimedOut:
            "The gateway did not acknowledge the video request. Check the configured provider before retrying to avoid duplicate work or charges."
        }
    }
}
