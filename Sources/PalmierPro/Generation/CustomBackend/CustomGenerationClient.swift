import Foundation

struct CustomGenerationClient: Sendable {
    let session: URLSession
    let requestTimeout: TimeInterval
    let imageGenerationTimeout: TimeInterval
    let videoSubmissionTimeout: TimeInterval
    let downloadTimeout: TimeInterval

    init(
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        imageGenerationTimeout: TimeInterval = 20 * 60,
        videoSubmissionTimeout: TimeInterval = 180,
        downloadTimeout: TimeInterval = 120
    ) {
        self.session = session
        self.requestTimeout = requestTimeout
        self.imageGenerationTimeout = imageGenerationTimeout
        self.videoSubmissionTimeout = videoSubmissionTimeout
        self.downloadTimeout = downloadTimeout
    }

    func generateImages(
        configuration: CustomGenerationConfigurationSnapshot,
        request payload: CustomImageGenerationRequest
    ) async throws -> CustomImageGenerationResponse {
        var request = URLRequest(url: configuration.imageGenerationsURL)
        request.httpMethod = "POST"
        configure(&request, apiKey: configuration.apiKey)
        request.timeoutInterval = imageGenerationTimeout
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(CustomImageGenerationResponse.self, from: data)
        } catch {
            throw CustomGenerationError.invalidResponse("Gateway returned an invalid image response.")
        }
    }

    func fetchCatalog(
        connection: CustomGenerationConnectionSnapshot
    ) async throws -> [CatalogEntry] {
        var request = URLRequest(url: connection.modelCatalogURL)
        request.httpMethod = "GET"
        configure(&request, apiKey: connection.apiKey)
        let data = try await responseData(for: request)
        do {
            let envelope = try JSONDecoder().decode(CustomGenerationCatalogEnvelope.self, from: data)
            return try CustomGenerationCatalog.validate(envelope)
        } catch let error as CustomGenerationError {
            throw error
        } catch {
            throw CustomGenerationError.invalidResponse("Gateway returned an invalid model catalog.")
        }
    }

    func createVideo(
        configuration: CustomGenerationConfigurationSnapshot,
        request payload: CustomVideoGenerationRequest
    ) async throws -> CustomVideoJobResponse {
        var request = URLRequest(url: configuration.videosURL)
        request.httpMethod = "POST"
        configure(&request, apiKey: configuration.apiKey)
        request.timeoutInterval = videoSubmissionTimeout
        request.httpBody = try JSONEncoder().encode(payload)
        do {
            return try decodeVideoResponse(try await responseData(for: request))
        } catch let error as URLError where error.code == .timedOut {
            throw CustomGenerationError.videoSubmissionTimedOut
        }
    }

    func generateSpeech(
        configuration: CustomGenerationConfigurationSnapshot,
        request payload: CustomAudioGenerationRequest
    ) async throws -> CustomAudioGenerationResponse {
        var request = URLRequest(url: configuration.audioSpeechURL)
        request.httpMethod = "POST"
        configure(&request, apiKey: configuration.apiKey)
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await response(for: request)
        guard !data.isEmpty else {
            throw CustomGenerationError.invalidResponse("Gateway returned empty audio.")
        }
        return CustomAudioGenerationResponse(data: data, mimeType: response.mimeType)
    }

    func retrieveVideo(
        connection: CustomGenerationConnectionSnapshot,
        jobID: String
    ) async throws -> CustomVideoJobResponse {
        guard !jobID.isEmpty else {
            throw CustomGenerationError.invalidResponse("The stored video job ID is empty.")
        }
        var request = URLRequest(url: connection.videoURL(jobID: jobID))
        request.httpMethod = "GET"
        configure(&request, apiKey: connection.apiKey)
        let response = try decodeVideoResponse(try await responseData(for: request))
        guard response.id == jobID else {
            throw CustomGenerationError.invalidResponse("Gateway returned a different video job ID.")
        }
        return response
    }

    private func configure(_ request: inout URLRequest, apiKey: String) {
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        try await response(for: request).0
    }

    private func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomGenerationError.invalidResponse("Gateway returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(1_000), as: UTF8.self)
            throw CustomGenerationError.gateway(status: http.statusCode, message: body.isEmpty ? "Request failed." : body)
        }
        return (data, http)
    }

    private func decodeVideoResponse(_ data: Data) throws -> CustomVideoJobResponse {
        do {
            let response = try JSONDecoder().decode(CustomVideoJobResponse.self, from: data)
            guard !response.id.isEmpty else {
                throw CustomGenerationError.invalidResponse("Gateway returned an empty video job ID.")
            }
            _ = try response.status
            return response
        } catch let error as CustomGenerationError {
            throw error
        } catch {
            throw CustomGenerationError.invalidResponse("Gateway returned an invalid video response.")
        }
    }
}
