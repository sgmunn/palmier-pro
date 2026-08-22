import Foundation

enum GenerationRoute: String, CaseIterable, Sendable {
    case hosted = "palmier-hosted"
    case custom = "custom-gateway"
}

@Observable
@MainActor
final class CustomGenerationConfiguration {
    static let shared = CustomGenerationConfiguration()

    private static let routeKey = "generationRoute"
    private static let baseURLKey = "customGenerationBaseURL"
    private static let imageModelIDKey = "customGenerationImageModelID"
    private static let videoModelIDKey = "customGenerationVideoModelID"
    nonisolated private static let apiKeyAccount = "custom-generation-gateway"

    private let defaults: UserDefaults

    var route: GenerationRoute {
        didSet {
            defaults.set(route.rawValue, forKey: Self.routeKey)
            ModelCatalog.shared.reload()
        }
    }

    var baseURLText: String {
        didSet { defaults.set(baseURLText, forKey: Self.baseURLKey) }
    }

    var imageModelIDText: String {
        didSet { defaults.set(imageModelIDText, forKey: Self.imageModelIDKey) }
    }

    var videoModelIDText: String {
        didSet { defaults.set(videoModelIDText, forKey: Self.videoModelIDKey) }
    }

    private(set) var hasAPIKey = false

    var baseURL: URL? {
        let value = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    var imageModelID: String? {
        let value = imageModelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var videoModelID: String? {
        let value = videoModelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var configurationError: String? {
        guard route == .custom else { return nil }
        guard baseURL != nil else { return L10n.string("Enter a valid gateway URL.") }
        guard imageModelID != nil else { return L10n.string("Enter an image model ID.") }
        guard videoModelID != nil else { return L10n.string("Enter a video model ID.") }
        guard hasAPIKey else { return L10n.string("Enter a gateway API key.") }
        return nil
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        route = GenerationRoute(rawValue: defaults.string(forKey: Self.routeKey) ?? "") ?? .hosted
        baseURLText = defaults.string(forKey: Self.baseURLKey) ?? ""
        imageModelIDText = defaults.string(forKey: Self.imageModelIDKey)
            ?? "black-forest-labs/FLUX.1-schnell"
        videoModelIDText = defaults.string(forKey: Self.videoModelIDKey)
            ?? "minimax/hailuo-02"
        Task { [weak self] in
            let hasKey = await Self.loadAPIKey() != nil
            self?.hasAPIKey = hasKey
        }
    }

    func setAPIKey(_ value: String?) async {
        let key = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        await Task.detached {
            if let key, !key.isEmpty {
                KeychainStore.save(key, account: Self.apiKeyAccount)
            } else {
                KeychainStore.delete(account: Self.apiKeyAccount)
            }
        }.value
        hasAPIKey = key?.isEmpty == false
    }

    nonisolated static func loadAPIKey() async -> String? {
        await Task.detached { KeychainStore.load(account: apiKeyAccount) }.value
    }

    func snapshot(for kind: CatalogEntry.Kind) async throws -> CustomGenerationConfigurationSnapshot {
        guard let apiKey = await Self.loadAPIKey() else {
            throw CustomGenerationError.invalidConfiguration("Enter a gateway API key.")
        }
        guard let baseURL else { throw CustomGenerationError.invalidConfiguration("Enter a valid gateway URL.") }
        let modelID: String? = switch kind {
        case .image: imageModelID
        case .video: videoModelID
        case .audio, .upscale: nil
        }
        guard let modelID else {
            throw CustomGenerationError.invalidConfiguration("Enter a " + kind.rawValue + " model ID.")
        }
        return CustomGenerationConfigurationSnapshot(baseURL: baseURL, apiKey: apiKey, modelID: modelID)
    }

    func recoverySnapshot() async throws -> CustomGenerationConnectionSnapshot {
        guard let apiKey = await Self.loadAPIKey() else {
            throw CustomGenerationError.invalidConfiguration("Enter a gateway API key.")
        }
        guard let baseURL else { throw CustomGenerationError.invalidConfiguration("Enter a valid gateway URL.") }
        return CustomGenerationConnectionSnapshot(baseURL: baseURL, apiKey: apiKey)
    }

    func remoteModelID(for catalogModelID: String) -> String? {
        switch catalogModelID {
        case CustomGenerationCatalog.imageModelID: imageModelID
        case CustomGenerationCatalog.videoModelID: videoModelID
        default: nil
        }
    }
}

struct CustomGenerationConnectionSnapshot: Sendable {
    let baseURL: URL
    let apiKey: String

    var imageGenerationsURL: URL {
        endpoint(version: "v1", components: ["images", "generations"])
    }

    var videosURL: URL {
        endpoint(version: "v2", components: ["videos"])
    }

    func videoURL(jobID: String) -> URL {
        videosURL.appendingPathComponent(jobID, isDirectory: false)
    }

    private func endpoint(version: String, components: [String]) -> URL {
        var root = baseURL
        if ["v1", "v2"].contains(root.lastPathComponent.lowercased()) {
            root.deleteLastPathComponent()
        }
        return components.reduce(root.appendingPathComponent(version, isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }
}

struct CustomGenerationConfigurationSnapshot: Sendable {
    let connection: CustomGenerationConnectionSnapshot
    let modelID: String

    init(baseURL: URL, apiKey: String, modelID: String) {
        connection = CustomGenerationConnectionSnapshot(baseURL: baseURL, apiKey: apiKey)
        self.modelID = modelID
    }

    var baseURL: URL { connection.baseURL }
    var apiKey: String { connection.apiKey }
    var imageGenerationsURL: URL { connection.imageGenerationsURL }
    var videosURL: URL { connection.videosURL }
}
