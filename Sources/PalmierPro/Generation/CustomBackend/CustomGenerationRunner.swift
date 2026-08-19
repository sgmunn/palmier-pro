import Foundation

struct CustomGenerationResult: Sendable {
    let stagedFiles: [URL]
}

struct CustomGenerationRunner: Sendable {
    let client: CustomGenerationClient

    init(client: CustomGenerationClient = CustomGenerationClient()) {
        self.client = client
    }

    func generateImages(
        configuration: CustomGenerationConfigurationSnapshot,
        remoteModel: String,
        params: ImageGenerationParams
    ) async throws -> CustomGenerationResult {
        guard params.imageURLs.isEmpty else {
            throw CustomGenerationError.unsupported("Reference-image generation is not supported by the custom gateway yet.")
        }
        let response = try await client.generateImages(
            configuration: configuration,
            request: CustomImageGenerationRequest(
                model: remoteModel,
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
