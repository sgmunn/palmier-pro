import Foundation

struct CustomGenerationCatalogEnvelope: Decodable, Sendable {
    let catalogVersion: Int
    let models: [CatalogEntry]
}

enum CustomGenerationCatalog {
    static let supportedVersion = 1

    static func validate(_ envelope: CustomGenerationCatalogEnvelope) throws -> [CatalogEntry] {
        guard envelope.catalogVersion == supportedVersion else {
            throw CustomGenerationError.invalidResponse(
                "Gateway catalog version \(envelope.catalogVersion) is unsupported."
            )
        }
        var ids: Set<String> = []
        for entry in envelope.models {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CustomGenerationError.invalidResponse("Gateway catalog contains an empty model ID.")
            }
            guard ids.insert(entry.id).inserted else {
                throw CustomGenerationError.invalidResponse(
                    "Gateway catalog contains duplicate model ID '\(entry.id)'."
                )
            }
            guard entry.kind != .upscale else {
                throw CustomGenerationError.invalidResponse(
                    "The custom gateway does not support upscale models."
                )
            }
        }
        return envelope.models
    }
}
