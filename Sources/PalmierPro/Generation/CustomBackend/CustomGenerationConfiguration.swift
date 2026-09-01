import Foundation

enum GenerationRoute: String, CaseIterable, Sendable {
    case hosted = "palmier-hosted"
    case custom = "custom-gateway"
}

@Observable
@MainActor
final class CustomGenerationConfiguration {
    static let shared = CustomGenerationConfiguration()
    nonisolated static let defaultImageModelID = "black-forest-labs/FLUX.2-dev"
    nonisolated static let defaultAudioModelID = "hexgrad/Kokoro-82M"
    nonisolated static let defaultAudioVoiceIDs = ["af_alloy", "af_bella", "af_heart"]

    private static let routeKey = "generationRoute"
    private static let baseURLKey = "customGenerationBaseURL"
    private static let imageModelIDKey = "customGenerationImageModelID"
    private static let videoModelIDKey = "customGenerationVideoModelID"
    private static let audioModelIDKey = "customGenerationAudioModelID"
    private static let audioVoiceIDsKey = "customGenerationAudioVoiceIDs"
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
        didSet { defaults.set(baseURLText, forKey: Self.baseURLKey) }
    }

    var imageModelIDText: String {
        didSet { defaults.set(imageModelIDText, forKey: Self.imageModelIDKey) }
    }

    var videoModelIDText: String {
        didSet { defaults.set(videoModelIDText, forKey: Self.videoModelIDKey) }
    }

    var audioModelIDText: String {
        didSet { defaults.set(audioModelIDText, forKey: Self.audioModelIDKey) }
    }

    var audioVoiceIDsText: String {
        didSet {
            defaults.set(audioVoiceIDsText, forKey: Self.audioVoiceIDsKey)
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

    var imageModelID: String? {
        let value = imageModelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var videoModelID: String? {
        let value = videoModelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var audioModelID: String? {
        let value = audioModelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var audioVoiceIDs: [String] {
        Self.parseAudioVoiceIDs(audioVoiceIDsText)
    }

    var configurationError: String? {
        guard route == .custom else { return nil }
        guard baseURL != nil else { return L10n.string("Enter a valid gateway URL.") }
        guard imageModelID != nil else { return L10n.string("Enter an image model ID.") }
        guard videoModelID != nil else { return L10n.string("Enter a video model ID.") }
        guard audioModelID != nil else { return L10n.string("Enter an audio model ID.") }
        guard !audioVoiceIDs.isEmpty else { return L10n.string("Enter at least one audio voice ID.") }
        guard hasAPIKey else { return L10n.string("Enter a gateway API key.") }
        return nil
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        route = GenerationRoute(rawValue: defaults.string(forKey: Self.routeKey) ?? "") ?? .hosted
        baseURLText = defaults.string(forKey: Self.baseURLKey) ?? ""
        imageModelIDText = defaults.string(forKey: Self.imageModelIDKey)
            ?? Self.defaultImageModelID
        videoModelIDText = defaults.string(forKey: Self.videoModelIDKey)
            ?? "minimax/hailuo-02"
        audioModelIDText = defaults.string(forKey: Self.audioModelIDKey)
            ?? Self.defaultAudioModelID
        audioVoiceIDsText = defaults.string(forKey: Self.audioVoiceIDsKey)
            ?? Self.defaultAudioVoiceIDs.joined(separator: ", ")
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
        case .audio: audioModelID
        case .upscale: nil
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
        case CustomGenerationCatalog.audioModelID: audioModelID
        default: nil
        }
    }

    nonisolated static func parseAudioVoiceIDs(_ value: String) -> [String] {
        var seen: Set<String> = []
        return value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
    var audioSpeechURL: URL { connection.audioSpeechURL }
}
