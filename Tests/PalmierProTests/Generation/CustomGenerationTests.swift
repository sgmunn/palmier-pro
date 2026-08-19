import Foundation
import Testing
@testable import PalmierPro

@Suite("Custom generation")
struct CustomGenerationTests {
    @Test("Image-only catalog replaces an unavailable video selection")
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

    @Test("Bundled catalog maps the custom image model")
    func bundledCatalog() async throws {
        let entries = try await CustomGenerationCatalog.load()
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(entry.id == "custom/image/default")
        #expect(entry.generationBackendID == GenerationRoute.custom.rawValue)
        #expect(entry.remoteModel == "default")
        guard case .image(let capabilities) = entry.uiCapabilities else {
            Issue.record("Expected image capabilities")
            return
        }
        #expect(capabilities.supportsImageReference == false)
        #expect(capabilities.maxImages == 4)
    }

    @Test("Image request uses the stable gateway field names")
    func imageRequestEncoding() throws {
        let request = CustomImageGenerationRequest(
            model: "flux-schnell",
            prompt: "A quiet harbor",
            n: 2,
            aspectRatio: "16:9",
            resolution: "1920x1080",
            quality: "high"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        #expect(object["model"] as? String == "flux-schnell")
        #expect(object["prompt"] as? String == "A quiet harbor")
        #expect(object["n"] as? Int == 2)
        #expect(object["aspect_ratio"] as? String == "16:9")
        #expect(object["resolution"] as? String == "1920x1080")
        #expect(object["quality"] as? String == "high")
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
