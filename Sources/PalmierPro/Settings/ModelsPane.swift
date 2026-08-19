import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var account = AccountService.shared

    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let paidOnly: Bool
        let providerIconKey: String?
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private func isLocked(_ row: Row) -> Bool { row.paidOnly && !account.isPaid }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func prepare(_ rows: [Row]) -> [Row] {
            let matched = q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
            // Available models first, locked (paid-only) ones grouped at the bottom.
            return matched.filter { !isLocked($0) } + matched.filter { isLocked($0) }
        }
        return [
            Section(id: "image", title: L10n.string("Image"),
                    rows: prepare(catalog.image.map { row(for: $0.entry) })),
            Section(id: "video", title: L10n.string("Video"),
                    rows: prepare(catalog.video.map { row(for: $0.entry) })),
            Section(id: "audio", title: L10n.string("Audio"),
                    rows: prepare(catalog.audio.map { row(for: $0.entry) })),
        ].filter { !$0.rows.isEmpty }
    }

    private func row(for entry: CatalogEntry) -> Row {
        Row(
            id: entry.id,
            displayName: entry.displayName,
            paidOnly: entry.paidOnly,
            providerIconKey: entry.providerIconKey
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            CustomGenerationSettings()
            searchBar

            if sections.isEmpty {
                Text(catalog.isLoaded
                    ? L10n.string("No models match \"\(query)\".")
                    : L10n.string("Loading models…"))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.lg)
            } else {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField(L10n.string("Search models"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: Section) -> some View {
        SettingsSection(title: section.title) {
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func modelRow(_ row: Row) -> some View {
        let locked = isLocked(row)
        HStack(spacing: AppTheme.Spacing.md) {
            if let iconKey = row.providerIconKey {
                ProviderLogo(iconKey: iconKey, size: AppTheme.IconSize.md)
                    .opacity(locked ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            }
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(locked ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            if locked {
                Button(L10n.string("Subscribe")) {
                    SettingsWindowController.shared.show(tab: .account)
                }
                .buttonStyle(.capsule(.secondary))
            } else {
                Toggle(String(), isOn: Binding(
                    get: { prefs.isEnabled(row.id) },
                    set: { prefs.setEnabled(row.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(row.displayName)
            }
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}

private struct CustomGenerationSettings: View {
    @Bindable private var configuration = CustomGenerationConfiguration.shared
    @State private var apiKey = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        SettingsSection(title: L10n.string("Generation backend")) {
            Picker(L10n.string("Backend"), selection: $configuration.route) {
                Text(L10n.string("Palmier Hosted")).tag(GenerationRoute.hosted)
                Text(L10n.string("Custom Gateway")).tag(GenerationRoute.custom)
            }
            .pickerStyle(.segmented)

            if configuration.route == .custom {
                TextField(L10n.string("Gateway URL"), text: $configuration.baseURLText)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: AppTheme.Spacing.sm) {
                    SecureField(
                        configuration.hasAPIKey ? L10n.string("API key saved") : L10n.string("API key"),
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit(saveKey)
                    Button(L10n.string("Save"), action: saveKey)
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if configuration.hasAPIKey {
                        Button(L10n.string("Remove")) {
                            Task { await configuration.setAPIKey(nil) }
                        }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                    }
                }
                if let error = configuration.configurationError {
                    Text(verbatim: error)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
    }

    private func saveKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        apiKey = ""
        keyFocused = false
        Task { await configuration.setAPIKey(value) }
    }
}
