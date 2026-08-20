import Foundation

struct CustomGenerationClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateImages(
        configuration: CustomGenerationConfigurationSnapshot,
        request payload: CustomImageGenerationRequest
    ) async throws -> CustomImageGenerationResponse {
        var request = URLRequest(url: configuration.imageGenerationsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomGenerationError.invalidResponse("Gateway returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(1_000), as: UTF8.self)
            throw CustomGenerationError.gateway(status: http.statusCode, message: body.isEmpty ? "Request failed." : body)
        }
        do {
            return try JSONDecoder().decode(CustomImageGenerationResponse.self, from: data)
        } catch {
            throw CustomGenerationError.invalidResponse("Gateway returned an invalid image response.")
        }
    }
}
