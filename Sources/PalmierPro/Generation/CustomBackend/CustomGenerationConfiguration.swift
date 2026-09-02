import Foundation

enum GenerationRoute: String, CaseIterable, Sendable {
    case hosted = "palmier-hosted"
    case custom = "custom-gateway"
}

@Observable
@MainActor
final class CustomGenerationConfiguration {
    static let shared = CustomGenerationConfiguration()
    nonisolated static let defaultBaseURL = "http://127.0.0.1:8190"

    private static let routeKey = "generationRoute"
    private static let baseURLKey = "customGenerationBaseURL"
    nonisolated private static let apiKeyAccount = "custom-generation-gateway"

    private let defaults: UserDefaults
    @ObservationIgnored private var catalogReloadTask: Task<Void, Never>?

    var route: GenerationRoute {
        didSet {
            catalogReloadTask?.cancel()
            defaults.set(route.rawValue, forKey: Self.routeKey)
            ModelCatalog.shared.reload()
        }
    }

    var baseURLText: String {
        didSet {
            defaults.set(baseURLText, forKey: Self.baseURLKey)
            scheduleCatalogReload()
        }
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

    var configurationError: String? {
        guard route == .custom else { return nil }
        guard baseURL != nil else { return L10n.string("Enter a valid gateway URL.") }
        guard hasAPIKey else { return L10n.string("Enter a gateway API key.") }
        return nil
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        route = GenerationRoute(rawValue: defaults.string(forKey: Self.routeKey) ?? "") ?? .hosted
        baseURLText = defaults.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
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
        if route == .custom { ModelCatalog.shared.reload() }
    }

    nonisolated static func loadAPIKey() async -> String? {
        await Task.detached { KeychainStore.load(account: apiKeyAccount) }.value
    }

    func snapshot(modelID: String) async throws -> CustomGenerationConfigurationSnapshot {
        let connection = try await connectionSnapshot()
        return CustomGenerationConfigurationSnapshot(connection: connection, modelID: modelID)
    }

    func recoverySnapshot() async throws -> CustomGenerationConnectionSnapshot {
        try await connectionSnapshot()
    }

    func connectionSnapshot() async throws -> CustomGenerationConnectionSnapshot {
        guard let apiKey = await Self.loadAPIKey() else {
            throw CustomGenerationError.invalidConfiguration("Enter a gateway API key.")
        }
        guard let baseURL else { throw CustomGenerationError.invalidConfiguration("Enter a valid gateway URL.") }
        return CustomGenerationConnectionSnapshot(baseURL: baseURL, apiKey: apiKey)
    }

    private func scheduleCatalogReload() {
        guard route == .custom else { return }
        catalogReloadTask?.cancel()
        catalogReloadTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            ModelCatalog.shared.reload()
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

    var audioSpeechURL: URL {
        endpoint(version: "v1", components: ["audio", "speech"])
    }

    var modelCatalogURL: URL {
        endpoint(version: "v1", components: ["palmier", "models"])
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

    init(connection: CustomGenerationConnectionSnapshot, modelID: String) {
        self.connection = connection
        self.modelID = modelID
    }

    var baseURL: URL { connection.baseURL }
    var apiKey: String { connection.apiKey }
    var imageGenerationsURL: URL { connection.imageGenerationsURL }
    var videosURL: URL { connection.videosURL }
    var audioSpeechURL: URL { connection.audioSpeechURL }
}
