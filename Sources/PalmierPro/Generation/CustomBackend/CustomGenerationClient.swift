import Foundation

struct CustomGenerationClient: Sendable {
    let session: URLSession
    let requestTimeout: TimeInterval
    let videoSubmissionTimeout: TimeInterval
    let downloadTimeout: TimeInterval

    init(
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 30,
        videoSubmissionTimeout: TimeInterval = 180,
        downloadTimeout: TimeInterval = 120
    ) {
        self.session = session
        self.requestTimeout = requestTimeout
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
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(CustomImageGenerationResponse.self, from: data)
        } catch {
            throw CustomGenerationError.invalidResponse("Gateway returned an invalid image response.")
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomGenerationError.invalidResponse("Gateway returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(1_000), as: UTF8.self)
            throw CustomGenerationError.gateway(status: http.statusCode, message: body.isEmpty ? "Request failed." : body)
        }
        return data
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
