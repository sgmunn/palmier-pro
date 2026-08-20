import Foundation

enum GenerationAccessResult: Equatable, Sendable {
    case allowed
    case refused(reason: String)
}

enum GenerationAccess {
    @MainActor
    static var canOpenPanel: Bool {
        permitsPanelAccess(
            route: CustomGenerationConfiguration.shared.route,
            hostedBackendConfigured: !AccountService.shared.isMisconfigured
        )
    }

    static func permitsPanelAccess(
        route: GenerationRoute,
        hostedBackendConfigured: Bool
    ) -> Bool {
        route == .custom || hostedBackendConfigured
    }

    @MainActor
    static func evaluate(modelID: String? = nil) -> GenerationAccessResult {
        let configuration = CustomGenerationConfiguration.shared
        switch configuration.route {
        case .custom:
            guard configuration.baseURL != nil else {
                return .refused(reason: "Enter a valid gateway URL.")
            }
            guard configuration.modelID != nil else {
                return .refused(reason: "Enter a gateway model ID.")
            }
            guard configuration.hasAPIKey else {
                return .refused(reason: "Enter a gateway API key.")
            }
            if let modelID {
                guard ModelPreferences.shared.isEnabled(modelID), ModelRegistry.exists(id: modelID) else {
                    return .refused(reason: "The selected model is unavailable.")
                }
            }
            return .allowed
        case .hosted:
            let account = AccountService.shared
            guard account.isSignedIn else { return .refused(reason: "Sign in to generate.") }
            guard !account.isMisconfigured else { return .refused(reason: "AI is unavailable.") }
            guard account.hasCredits else { return .refused(reason: "Add credits to keep generating.") }
            if let modelID, case .some(let kind) = ModelRegistry.byId[modelID] {
                let paidOnly = switch kind {
                case .video(let model): model.paidOnly
                case .image(let model): model.paidOnly
                case .audio(let model): model.paidOnly
                case .upscale(let model): model.paidOnly
                }
                guard !paidOnly || account.isPaid else {
                    return .refused(reason: "The selected model requires a paid plan.")
                }
            }
            return .allowed
        }
    }
}
