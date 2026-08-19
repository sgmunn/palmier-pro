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
        baseURLText = defaults.string(forKey: Self.baseURLKey) ?? ""
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

    func snapshot() async throws -> CustomGenerationConfigurationSnapshot {
        guard let baseURL else { throw CustomGenerationError.invalidConfiguration("Enter a valid gateway URL.") }
        guard let apiKey = await Self.loadAPIKey() else {
            throw CustomGenerationError.invalidConfiguration("Enter a gateway API key.")
        }
        return CustomGenerationConfigurationSnapshot(baseURL: baseURL, apiKey: apiKey)
    }
}

struct CustomGenerationConfigurationSnapshot: Sendable {
    let baseURL: URL
    let apiKey: String
}
