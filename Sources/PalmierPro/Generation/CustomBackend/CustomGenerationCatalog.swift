import Foundation

enum CustomGenerationCatalog {
    static let imageModelID = "custom/image/default"
    static let videoModelID = "custom/video/default"
    static let audioModelID = "custom/audio/tts"

    static func load() async throws -> [CatalogEntry] {
        try await Task.detached(priority: .userInitiated) {
            guard let url = BundledResource.url("GenerationCatalog/custom-generation-models.json") else {
                throw CustomGenerationError.invalidConfiguration("Custom generation catalog is missing.")
            }
            return try JSONDecoder().decode([CatalogEntry].self, from: Data(contentsOf: url))
        }.value
    }
}
