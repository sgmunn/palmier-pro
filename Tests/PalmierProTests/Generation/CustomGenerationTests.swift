import Foundation
import Testing
@testable import PalmierPro

private final class CustomGenerationTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let data: Data
        let status: Int
        if request.httpMethod == "POST", url.path == "/v2/videos" {
            data = Data(#"{"id":"job-1","model":"runware:123@1","status":"queued"}"#.utf8)
            status = 200
        } else if request.httpMethod == "GET", url.path == "/v2/videos/job-1" {
            data = Data(
                #"{"id":"job-1","model":"runware:123@1","status":"completed","outputs":{"video_url":"https://gateway.example/result.mp4"}}"#.utf8
            )
            status = 200
        } else {
            data = Data("not found".utf8)
            status = 404
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class TimedOutCustomGenerationTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
    override func stopLoading() {}
}

@Suite("Custom generation", .serialized)
struct CustomGenerationTests {
    @Test(
        "Gateway base URL resolves the image endpoint",
        arguments: [
            ("https://api.together.ai", "https://api.together.ai/v1/images/generations"),
            ("https://api.together.ai/v1", "https://api.together.ai/v1/images/generations"),
            ("https://api.together.ai/v2", "https://api.together.ai/v1/images/generations"),
        ]
    )
    func gatewayEndpoint(baseURL: String, expected: String) throws {
        let configuration = CustomGenerationConfigurationSnapshot(
            baseURL: try #require(URL(string: baseURL)),
            apiKey: "test-key",
            modelID: "black-forest-labs/FLUX.1-schnell"
        )

        #expect(configuration.imageGenerationsURL.absoluteString == expected)
    }

    @Test(
        "Gateway base URL resolves current video endpoints",
        arguments: [
            ("https://api.together.ai", "https://api.together.ai/v2/videos"),
            ("https://api.together.ai/v1", "https://api.together.ai/v2/videos"),
            ("https://api.together.ai/v2", "https://api.together.ai/v2/videos"),
        ]
    )
    func videoEndpoint(baseURL: String, expected: String) throws {
        let connection = CustomGenerationConnectionSnapshot(
            baseURL: try #require(URL(string: baseURL)),
            apiKey: "test-key"
        )

        #expect(connection.videosURL.absoluteString == expected)
        #expect(connection.videoURL(jobID: "job-123").absoluteString == expected + "/job-123")
    }

    @Test("Image-only catalog replaces an unavailable video selection")
    @MainActor
    func imageOnlyCatalogSelection() {
        #expect(GenerationView.normalizedGenerationType(
            .video,
            available: [.image]
        ) == .image)
    }

    @Test("Custom route exposes generation without a hosted backend")
    func customRoutePanelAccess() {
        #expect(GenerationAccess.permitsPanelAccess(
            route: .custom,
            hostedBackendConfigured: false
        ))
    }

    @Test("MCP image generation requires an explicit aspect ratio")
    func imageGenerationSchemaRequiresAspectRatio() throws {
        let tool = try #require(ToolDefinitions.mcpServer.first { $0.name == .generateImage })
        let required = try #require(tool.inputSchema["required"] as? [String])

        #expect(required == ["prompt", "aspectRatio"])
    }

    @Test("Bundled catalog maps the custom image model")
    func bundledCatalog() async throws {
        let entries = try await CustomGenerationCatalog.load()
        let entry = try #require(entries.first { $0.id == CustomGenerationCatalog.imageModelID })

        #expect(entries.count == 2)
        #expect(entry.id == "custom/image/default")
        guard case .image(let capabilities) = entry.uiCapabilities else {
            Issue.record("Expected image capabilities")
            return
        }
        #expect(capabilities.supportsImageReference == false)
        #expect(capabilities.maxImages == 4)

        let video = try #require(entries.first { $0.id == CustomGenerationCatalog.videoModelID })
        guard case .video(let videoCapabilities) = video.uiCapabilities else {
            Issue.record("Expected video capabilities")
            return
        }
        #expect(videoCapabilities.durations == [10])
        #expect(videoCapabilities.resolutions == ["768p"])
        #expect(videoCapabilities.aspectRatios == ["16:9"])
        #expect(videoCapabilities.supportsFirstFrame)
        #expect(!videoCapabilities.supportsLastFrame)
    }

    @Test("Video request uses the Together v2 field names")
    func videoRequestEncoding() throws {
        let request = CustomVideoGenerationRequest(
            model: "minimax/hailuo-02",
            prompt: "A quiet harbor",
            width: 1366,
            height: 768,
            seconds: "10",
            generateAudio: nil,
            frameImages: [.init(inputImage: "aW1hZ2U=", frame: 0)]
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        let frames = try #require(object["frame_images"] as? [[String: Any]])

        #expect(object["model"] as? String == "minimax/hailuo-02")
        #expect(object["seconds"] as? String == "10")
        #expect(object["width"] as? Int == 1366)
        #expect(object["height"] as? Int == 768)
        #expect(object["generate_audio"] == nil)
        #expect(frames.first?["input_image"] as? String == "aW1hZ2U=")
        #expect(frames.first?["frame"] as? Int == 0)
    }

    @Test(
        "Video response normalizes supported statuses",
        arguments: ["queued", "in_progress", "completed", "failed"]
    )
    func videoResponseStatuses(rawStatus: String) throws {
        var object: [String: Any] = [
            "id": "job-1",
            "model": "minimax/hailuo-02",
            "status": rawStatus,
        ]
        if rawStatus == "completed" {
            object["outputs"] = ["video_url": "https://gateway.example/result.mp4"]
        } else if rawStatus == "failed" {
            object["error"] = ["message": "provider failed"]
        }
        let json = try JSONSerialization.data(withJSONObject: object)
        let response = try JSONDecoder().decode(CustomVideoJobResponse.self, from: json)

        switch try response.status {
        case .queued: #expect(rawStatus == "queued")
        case .inProgress: #expect(rawStatus == "in_progress")
        case .completed(let url):
            #expect(rawStatus == "completed")
            #expect(url.absoluteString == "https://gateway.example/result.mp4")
        case .failed(let message):
            #expect(rawStatus == "failed")
            #expect(message == "provider failed")
        }
    }

    @Test("Unknown and malformed video responses fail explicitly")
    func invalidVideoResponses() throws {
        let unknown = try JSONDecoder().decode(
            CustomVideoJobResponse.self,
            from: Data(#"{"id":"job-1","status":"cancelled"}"#.utf8)
        )
        #expect(throws: CustomGenerationError.self) { try unknown.status }

        let completedWithoutURL = try JSONDecoder().decode(
            CustomVideoJobResponse.self,
            from: Data(#"{"id":"job-1","status":"completed","outputs":{}}"#.utf8)
        )
        #expect(throws: CustomGenerationError.self) { try completedWithoutURL.status }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CustomVideoJobResponse.self, from: Data(#"{"status":"queued"}"#.utf8))
        }
    }

    @Test("Video client creates and retrieves the same job")
    func videoClientRoundTrip() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CustomGenerationTestURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = CustomGenerationClient(session: session, requestTimeout: 3)
        let configuration = CustomGenerationConfigurationSnapshot(
            baseURL: try #require(URL(string: "https://gateway.example/v1")),
            apiKey: "test-key",
            modelID: "minimax/hailuo-02"
        )
        let created = try await client.createVideo(
            configuration: configuration,
            request: CustomVideoGenerationRequest(
                model: configuration.modelID,
                prompt: "A quiet harbor",
                width: 1366,
                height: 768,
                seconds: "10",
                generateAudio: nil,
                frameImages: nil
            )
        )
        let retrieved = try await client.retrieveVideo(
            connection: configuration.connection,
            jobID: created.id
        )

        #expect(created.id == "job-1")
        guard case .completed(let videoURL) = try retrieved.status else {
            Issue.record("Expected completed video")
            return
        }
        #expect(videoURL.absoluteString == "https://gateway.example/result.mp4")
    }

    @Test("Video submission uses an extended timeout and reports ambiguous acceptance")
    func videoSubmissionTimeout() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TimedOutCustomGenerationTestURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = CustomGenerationClient(session: session, requestTimeout: 3)
        let configuration = CustomGenerationConfigurationSnapshot(
            baseURL: try #require(URL(string: "https://gateway.example/v1")),
            apiKey: "test-key",
            modelID: "minimax/hailuo-02"
        )

        #expect(client.videoSubmissionTimeout == 180)
        await #expect(throws: CustomGenerationError.videoSubmissionTimedOut) {
            try await client.createVideo(
                configuration: configuration,
                request: CustomVideoGenerationRequest(
                    model: configuration.modelID,
                    prompt: "timeout",
                    width: 1366,
                    height: 768,
                    seconds: "10",
                    generateAudio: nil,
                    frameImages: nil
                )
            )
        }
    }

    @Test("Cancellation before video submission does not create a job")
    func videoCancellationBeforeSubmit() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CustomGenerationRunner().acceptVideo(
                configuration: CustomGenerationConfigurationSnapshot(
                    baseURL: URL(string: "https://gateway.invalid")!,
                    apiKey: "test-key",
                    modelID: "minimax/hailuo-02"
                ),
                params: VideoGenerationParams(
                    prompt: "A quiet harbor",
                    duration: 10,
                    aspectRatio: "16:9",
                    resolution: "768p",
                    generateAudio: false
                )
            )
        }

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Video acceptance persists the gateway canonical model")
    func videoAcceptanceUsesCanonicalModel() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CustomGenerationTestURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let receipt = try await CustomGenerationRunner(
            client: CustomGenerationClient(session: session, requestTimeout: 3),
            pollInterval: .zero
        ).acceptVideo(
            configuration: CustomGenerationConfigurationSnapshot(
                baseURL: try #require(URL(string: "https://gateway.example/v1")),
                apiKey: "test-key",
                modelID: "minimax/hailuo-02"
            ),
            params: VideoGenerationParams(
                prompt: "A quiet harbor",
                duration: 10,
                aspectRatio: "16:9",
                resolution: "768p",
                generateAudio: false
            )
        )

        #expect(receipt.remoteModelID == "runware:123@1")
        #expect(receipt.jobID == "job-1")
    }

    @Test("Custom failed jobs retain recovery eligibility")
    @MainActor
    func failedCustomJobIsRetryable() {
        var input = GenerationInput(
            prompt: "Test",
            model: CustomGenerationCatalog.videoModelID,
            duration: 10,
            aspectRatio: "16:9"
        )
        input.generationBackendID = GenerationRoute.custom.rawValue
        input.remoteModel = "minimax/hailuo-02"
        input.backendJobId = "job-1"
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/video.mp4"),
            type: .video,
            name: "Video",
            generationInput: input
        )
        asset.generationStatus = .failed("Timed out")

        #expect(asset.isRecoveringGeneration)
    }

    @Test("Image request uses the stable gateway field names")
    func imageRequestEncoding() throws {
        let request = CustomImageGenerationRequest(
            model: "black-forest-labs/FLUX.1-schnell",
            prompt: "A quiet harbor",
            n: 2,
            aspectRatio: "16:9",
            width: 1024,
            height: 576,
            resolution: "1920x1080",
            quality: "high"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        #expect(object["model"] as? String == "black-forest-labs/FLUX.1-schnell")
        #expect(object["prompt"] as? String == "A quiet harbor")
        #expect(object["n"] as? Int == 2)
        #expect(object["aspect_ratio"] as? String == "16:9")
        #expect(object["width"] as? Int == 1024)
        #expect(object["height"] as? Int == 576)
        #expect(object["resolution"] as? String == "1920x1080")
        #expect(object["quality"] as? String == "high")
    }

    @Test(
        "Custom image dimensions match catalog aspect ratios",
        arguments: [
            ("1:1", 1024, 1024),
            ("16:9", 1024, 576),
            ("9:16", 576, 1024),
            ("4:3", 1024, 768),
            ("3:4", 768, 1024),
        ]
    )
    func customImageDimensions(aspectRatio: String, width: Int, height: Int) throws {
        let dimensions = try #require(CustomGenerationRunner.dimensions(for: aspectRatio))
        #expect(dimensions.width == width)
        #expect(dimensions.height == height)
    }

    @Test("Image response accepts URL and base64 outputs")
    func imageResponseDecoding() throws {
        let json = Data(#"{"data":[{"url":"https://gateway.example/result.png"},{"b64_json":"aW1hZ2U="}]}"#.utf8)
        let response = try JSONDecoder().decode(CustomImageGenerationResponse.self, from: json)

        #expect(response.data.count == 2)
        #expect(response.data[0].url?.absoluteString == "https://gateway.example/result.png")
        #expect(response.data[1].base64 == "aW1hZ2U=")
    }

    @Test("Generation input persists backend identity and model mapping")
    func generationInputPersistence() throws {
        var input = GenerationInput(prompt: "Test", model: "custom/image/default", duration: 0, aspectRatio: "1:1")
        input.generationBackendID = GenerationRoute.custom.rawValue
        input.remoteModel = "flux-schnell"

        let restored = try JSONDecoder().decode(GenerationInput.self, from: JSONEncoder().encode(input))

        #expect(restored.generationBackendID == GenerationRoute.custom.rawValue)
        #expect(restored.remoteModel == "flux-schnell")
    }
}
