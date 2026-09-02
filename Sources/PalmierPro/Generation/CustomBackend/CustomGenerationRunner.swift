import Foundation

struct CustomGenerationResult: Sendable {
    let stagedFiles: [URL]
}

struct CustomGenerationRunner: Sendable {
    let client: CustomGenerationClient
    let pollInterval: Duration

    init(
        client: CustomGenerationClient = CustomGenerationClient(),
        pollInterval: Duration = .seconds(10)
    ) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func acceptVideo(
        configuration: CustomGenerationConfigurationSnapshot,
        params: VideoGenerationParams
    ) async throws -> CustomVideoJobReceipt {
        try Task.checkCancellation()
        guard params.sourceVideoURL == nil,
              params.endFrameURL == nil,
              params.referenceImageURLs.isEmpty,
              params.referenceVideoURLs.isEmpty,
              params.referenceAudioURLs.isEmpty else {
            throw CustomGenerationError.unsupported(
                "The custom video model supports text and one starting frame only."
            )
        }
        guard params.duration == 10 else {
            throw CustomGenerationError.unsupported("The custom video model supports 10-second videos only.")
        }
        guard params.resolution == nil || params.resolution == "768p" else {
            throw CustomGenerationError.unsupported("The custom video model supports 768p output only.")
        }
        guard params.aspectRatio == "16:9" else {
            throw CustomGenerationError.unsupported("The custom video model supports 16:9 output only.")
        }
        guard !params.generateAudio else {
            throw CustomGenerationError.unsupported("The custom video model does not generate audio.")
        }

        let frameImages: [CustomVideoGenerationRequest.FrameImage]?
        if let startFrameURL = params.startFrameURL {
            let base64 = try await Self.base64Image(at: startFrameURL)
            frameImages = [
                .init(inputImage: base64, frame: 0),
            ]
        } else {
            frameImages = nil
        }
        let response = try await client.createVideo(
            configuration: configuration,
            request: CustomVideoGenerationRequest(
                model: configuration.modelID,
                prompt: params.prompt,
                width: 1366,
                height: 768,
                seconds: "10",
                generateAudio: nil,
                frameImages: frameImages
            )
        )
        let returnedModel = response.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptedModel = returnedModel.flatMap { $0.isEmpty ? nil : $0 }
        return CustomVideoJobReceipt(
            backendID: GenerationRoute.custom.rawValue,
            remoteModelID: acceptedModel ?? configuration.modelID,
            jobID: response.id
        )
    }

    func waitForVideo(
        connection: CustomGenerationConnectionSnapshot,
        receipt: CustomVideoJobReceipt
    ) async throws -> URL {
        while true {
            try Task.checkCancellation()
            let response = try await client.retrieveVideo(connection: connection, jobID: receipt.jobID)
            switch try response.status {
            case .queued, .inProgress:
                try await ContinuousClock().sleep(for: pollInterval)
            case .completed(let videoURL):
                return videoURL
            case .failed(let message):
                throw CustomGenerationError.videoFailed(message)
            }
        }
    }

    func stageVideo(from remoteURL: URL) async throws -> URL {
        try Task.checkCancellation()
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = client.downloadTimeout
        let (downloaded, response) = try await client.session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CustomGenerationError.invalidResponse("Gateway video download failed.")
        }
        let staged = try await Self.stageDownloadedVideo(
            downloaded,
            mimeType: http.mimeType
        )
        do {
            try Task.checkCancellation()
            return staged
        } catch {
            await Self.remove([staged])
            throw error
        }
    }

    func generateImages(
        configuration: CustomGenerationConfigurationSnapshot,
        params: ImageGenerationParams
    ) async throws -> CustomGenerationResult {
        guard params.imageURLs.isEmpty else {
            throw CustomGenerationError.unsupported("Reference-image generation is not supported by the custom gateway yet.")
        }
        let response = try await client.generateImages(
            configuration: configuration,
            request: CustomImageGenerationRequest(
                model: configuration.modelID,
                prompt: params.prompt,
                n: params.numImages,
                aspectRatio: params.aspectRatio,
                resolution: params.resolution,
                quality: params.quality
            )
        )
        guard !response.data.isEmpty else {
            throw CustomGenerationError.invalidResponse("Gateway returned no images.")
        }

        var staged: [URL] = []
        do {
            for output in response.data {
                try Task.checkCancellation()
                let file: URL
                if let remoteURL = output.url {
                    guard ["http", "https"].contains(remoteURL.scheme?.lowercased() ?? "") else {
                        throw CustomGenerationError.invalidResponse("Gateway returned an invalid image URL.")
                    }
                    let (downloaded, response) = try await client.session.download(from: remoteURL)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw CustomGenerationError.invalidResponse("Gateway image download failed.")
                    }
                    file = try await Self.stageDownloaded(
                        downloaded,
                        remoteURL: remoteURL,
                        mimeType: http.mimeType
                    )
                } else if let base64 = output.base64, let data = Data(base64Encoded: base64) {
                    file = try await Self.stage(data)
                } else {
                    throw CustomGenerationError.invalidResponse("Gateway image output has neither a URL nor base64 data.")
                }
                staged.append(file)
            }
            return CustomGenerationResult(stagedFiles: staged)
        } catch {
            await Self.remove(staged)
            throw error
        }
    }

    func generateSpeech(
        configuration: CustomGenerationConfigurationSnapshot,
        params: AudioGenerationParams
    ) async throws -> CustomGenerationResult {
        try Task.checkCancellation()
        guard params.lyrics == nil,
              params.styleInstructions == nil,
              !params.instrumental,
              params.durationSeconds == nil,
              params.videoURL == nil,
              params.sourceURL == nil,
              params.referenceImageURL == nil,
              params.referenceAudioURLs?.isEmpty != false,
              params.targetLanguage == nil,
              params.multilingual == nil else {
            throw CustomGenerationError.unsupported(
                "The custom speech model supports text and one configured voice only."
            )
        }
        let prompt = params.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw CustomGenerationError.unsupported("Enter text to generate speech.")
        }
        guard let voice = params.voice?.trimmingCharacters(in: .whitespacesAndNewlines),
              !voice.isEmpty else {
            throw CustomGenerationError.unsupported("Choose a voice for speech generation.")
        }
        let response = try await client.generateSpeech(
            configuration: configuration,
            request: CustomAudioGenerationRequest(
                model: configuration.modelID,
                input: prompt,
                voice: voice,
                responseFormat: "mp3"
            )
        )
        let staged = try await Self.stageAudio(response.data, mimeType: response.mimeType)
        do {
            try Task.checkCancellation()
            return CustomGenerationResult(stagedFiles: [staged])
        } catch {
            await Self.remove([staged])
            throw error
        }
    }

    private static func base64Image(at value: String) async throws -> String {
        guard let url = URL(string: value), url.isFileURL else {
            throw CustomGenerationError.unsupported("The starting frame must be a prepared local image.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            guard imageExtension(data.prefix(12)) != nil else {
                throw CustomGenerationError.unsupported("The starting frame is not a supported image.")
            }
            return data.base64EncodedString()
        }.value
    }

    private static func stage(_ data: Data) async throws -> URL {
        guard let fileExtension = imageExtension(data.prefix(12)) else {
            throw CustomGenerationError.invalidResponse("Gateway returned invalid base64 image data.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("palmier-custom-generation-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("result.\(fileExtension)")
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private static func stageDownloaded(
        _ source: URL,
        remoteURL: URL,
        mimeType: String?
    ) async throws -> URL {
        return try await Task.detached(priority: .userInitiated) {
            let knownExtensions = ["png", "jpg", "jpeg", "webp", "gif"]
            var fileExtension = knownExtensions.contains(remoteURL.pathExtension.lowercased())
                ? remoteURL.pathExtension.lowercased()
                : nil
            if fileExtension == nil {
                fileExtension = switch mimeType?.lowercased() {
                case "image/png": "png"
                case "image/jpeg": "jpg"
                case "image/webp": "webp"
                case "image/gif": "gif"
                default: nil
                }
            }
            if fileExtension == nil {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                fileExtension = imageExtension(try handle.read(upToCount: 12) ?? Data())
            }
            guard let fileExtension else {
                throw CustomGenerationError.invalidResponse("Gateway download is not a supported image.")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("palmier-custom-generation-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("result.\(fileExtension)")
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private static func stageDownloadedVideo(
        _ source: URL,
        mimeType: String?
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            let fileExtension: String?
            switch mimeType?.lowercased() {
            case "video/mp4": fileExtension = "mp4"
            case "video/quicktime": fileExtension = "mov"
            case "video/webm": fileExtension = "webm"
            default:
                if header.count >= 8, header.dropFirst(4).prefix(4) == Data("ftyp".utf8) {
                    fileExtension = "mp4"
                } else if header.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
                    fileExtension = "webm"
                } else {
                    fileExtension = nil
                }
            }
            guard let fileExtension else {
                throw CustomGenerationError.invalidResponse("Gateway download is not a supported video.")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("palmier-custom-generation-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("result.\(fileExtension)")
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private static func stageAudio(_ data: Data, mimeType: String?) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let fileExtension = audioExtension(data.prefix(16), mimeType: mimeType) else {
                throw CustomGenerationError.invalidResponse("Gateway response is not supported audio.")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("palmier-custom-generation-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("result.\(fileExtension)")
                try data.write(to: destination, options: .atomic)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    private static func audioExtension(_ bytes: Data.SubSequence, mimeType: String?) -> String? {
        let data = Data(bytes)
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WAVE".utf8) { return "wav" }
        if data.starts(with: Data("fLaC".utf8)) { return "flac" }
        if data.starts(with: Data("OggS".utf8)) { return "ogg" }
        if data.starts(with: Data("ID3".utf8)) { return "mp3" }
        if data.count >= 2, data[0] == 0xFF, data[1] & 0xE0 == 0xE0 { return "mp3" }
        return switch mimeType?.lowercased().split(separator: ";").first.map(String.init) {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/flac": "flac"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/aac": "aac"
        default: nil
        }
    }

    private static func imageExtension(_ bytes: Data.SubSequence) -> String? {
        let data = Data(bytes)
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return "webp" }
        return nil
    }

    static func remove(_ urls: [URL]) async {
        await Task.detached {
            for url in urls {
                let parent = url.deletingLastPathComponent()
                if parent.lastPathComponent.hasPrefix("palmier-custom-generation-") {
                    try? FileManager.default.removeItem(at: parent)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }.value
    }
}
