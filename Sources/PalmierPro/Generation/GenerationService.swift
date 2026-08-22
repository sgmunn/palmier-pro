import Foundation
@preconcurrency import Combine
@preconcurrency import ConvexMobile

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60
    private var activeBackendJobs: Set<String> = []
    private var generationTasks: [String: Task<Void, Never>] = [:]

    private struct PreparedReferences {
        let delivered: [String]
        let tempFiles: [URL]
    }

    private enum ReferenceDelivery {
        case hosted
        case local
    }

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        preUploadedURLs: [String]? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> BackendGenerationParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)? = nil,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        var routedInput = genInput
        let route = CustomGenerationConfiguration.shared.route
        routedInput.generationBackendID = route.rawValue
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(routedInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for outputIndex in 0..<count {
            var placeholderInput = routedInput
            placeholderInput.outputIndex = outputIndex
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: placeholderInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        captureSubmission(genInput: routedInput, assetType: assetType, outputCount: count, editor: editor)

        let generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.generationTasks[primaryId] = nil }
            do {
                if route == .custom {
                    var finalInput = routedInput
                    if finalInput.createdAt == nil { finalInput.createdAt = Date() }
                    for placeholder in placeholders {
                        updateGenerationMetadata(placeholder, editor: editor, status: .generating)
                    }
                    switch assetType {
                    case .image:
                        guard references.isEmpty, trimmedSourceOverride == nil,
                              preUploadedURLs?.isEmpty != false,
                              case .image(let imageParams) = buildParams([]) else {
                            throw CustomGenerationError.unsupported(
                                "Reference-image generation is not supported by the custom gateway yet."
                            )
                        }
                        let configuration = try await CustomGenerationConfiguration.shared.snapshot(for: .image)
                        finalInput.remoteModel = configuration.modelID
                        persistCustomInput(finalInput, placeholders: placeholders, editor: editor)
                        editor.onProjectCheckpointRequired?()
                        let result = try await CustomGenerationRunner().generateImages(
                            configuration: configuration,
                            params: imageParams
                        )
                        await self.finalizeCustomSuccess(
                            stagedFiles: result.stagedFiles,
                            placeholders: placeholders,
                            editor: editor,
                            onComplete: onComplete,
                            onFailure: onFailure
                        )
                    case .video:
                        let prepared = try await self.prepareReferences(
                            references: references,
                            trimmedSourceOverride: trimmedSourceOverride,
                            preUploadedURLs: preUploadedURLs,
                            preprocessRef: preprocessRef,
                            preprocessSourceVideo: preprocessSourceVideo,
                            delivery: .local
                        )
                        defer { Self.cleanupTempFiles(prepared.tempFiles) }
                        guard case .video(let videoParams) = buildParams(prepared.delivered) else {
                            throw CustomGenerationError.unsupported("Invalid custom video request.")
                        }
                        let configuration = try await CustomGenerationConfiguration.shared.snapshot(for: .video)
                        let runner = CustomGenerationRunner()
                        let receipt = try await runner.acceptVideo(
                            configuration: configuration,
                            params: videoParams
                        )
                        finalInput.generationBackendID = receipt.backendID
                        finalInput.remoteModel = receipt.remoteModelID
                        finalInput.backendJobId = receipt.jobID
                        persistCustomInput(finalInput, placeholders: placeholders, editor: editor)
                        editor.onProjectCheckpointRequired?()
                        let jobKey = Self.jobKey(backendID: receipt.backendID, jobID: receipt.jobID)
                        activeBackendJobs.insert(jobKey)
                        defer { activeBackendJobs.remove(jobKey) }
                        await monitorCustomVideo(
                            receipt: receipt,
                            connection: configuration.connection,
                            runner: runner,
                            placeholders: placeholders,
                            editor: editor,
                            onComplete: onComplete,
                            onFailure: onFailure
                        )
                    default:
                        throw CustomGenerationError.unsupported(
                            "The custom gateway does not support this media type yet."
                        )
                    }
                    return
                }
                let prepared = try await self.prepareReferences(
                    references: references,
                    trimmedSourceOverride: trimmedSourceOverride,
                    preUploadedURLs: preUploadedURLs,
                    preprocessRef: preprocessRef,
                    preprocessSourceVideo: preprocessSourceVideo,
                    delivery: .hosted
                )
                defer { Self.cleanupTempFiles(prepared.tempFiles) }
                let uploaded = prepared.delivered

                var finalGenInput = routedInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for (outputIndex, placeholder) in placeholders.enumerated() {
                    var storedInput = finalGenInput
                    storedInput.outputIndex = outputIndex
                    updateGenerationMetadata(placeholder, editor: editor) { input in
                        input = storedInput
                    }
                }

                let params = buildParams(uploaded)

                await self.runJob(
                    placeholders: placeholders,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure,
                    submit: {
                        try await GenerationBackend.submit(
                            model: finalGenInput.model,
                            params: params,
                            projectId: editor.projectId
                        )
                    }
                )
            } catch {
                let message = error.localizedDescription
                Log.generation.error("generation setup failed model=\(routedInput.model) error=\(message)")
                let statusMessage = route == .hosted ? "Upload failed: \(message)" : message
                for placeholder in placeholders where editor.mediaAssets.contains(where: { $0 === placeholder }) {
                    updateGenerationMetadata(placeholder, editor: editor, status: .failed(statusMessage))
                }
                onFailure?()
            }
        }
        generationTasks[primaryId] = generationTask

        return primaryId
    }

    func cancelGeneration(assetIDs: Set<String>) {
        for id in assetIDs {
            generationTasks[id]?.cancel()
        }
    }

    private func captureSubmission(
        genInput: GenerationInput,
        assetType: ClipType,
        outputCount: Int,
        editor: EditorViewModel
    ) {
        var payload = Analytics.originProperties()
        payload["project_id"] = editor.projectId ?? "unknown"
        payload["model"] = genInput.model
        payload["generation_type"] = Self.generationType(assetType: assetType, genInput: genInput)
        payload["output_count"] = outputCount
        Analytics.capture(.generationSubmitted, properties: payload)
    }

    nonisolated static func generationType(assetType: ClipType, genInput: GenerationInput) -> String {
        genInput.upscaleSettings == nil ? assetType.rawValue : "upscale"
    }

    private func prepareReferences(
        references: [MediaAsset],
        trimmedSourceOverride: TrimmedSource?,
        preUploadedURLs: [String]?,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)?,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)?,
        delivery: ReferenceDelivery
    ) async throws -> PreparedReferences {
        if let preUploadedURLs, !preUploadedURLs.isEmpty {
            guard case .hosted = delivery else {
                throw CustomGenerationError.unsupported("Custom generation requires local reference media.")
            }
            return PreparedReferences(delivered: preUploadedURLs, tempFiles: [])
        }

        var tempFiles: [URL] = []
        do {
            var urlsToUpload = references.map(\.url)
            let refTypes = references.map(\.type)
            var trimmedIndex: Int?
            if let trim = trimmedSourceOverride, trim.hasTrim,
               let index = urlsToUpload.firstIndex(of: trim.sourceURL) {
                Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[index].lastPathComponent)")
                let extracted = try await VideoTrimExtractor.extract(trim)
                urlsToUpload[index] = extracted
                tempFiles.append(extracted)
                trimmedIndex = index
            }
            if let preprocessSourceVideo, let sourceURL = urlsToUpload.first,
               let processed = try await preprocessSourceVideo(sourceURL) {
                urlsToUpload[0] = processed
                tempFiles.append(processed)
            }
            if let preprocessRef, !references.isEmpty {
                let rewrites = try await preprocessedReferenceURLs(
                    references: references,
                    currentURLs: urlsToUpload,
                    preprocessRef: preprocessRef
                )
                for (i, rewritten) in rewrites {
                    guard let rewritten else { continue }
                    urlsToUpload[i] = rewritten
                    tempFiles.append(rewritten)
                }
            }
            if case .local = delivery {
                for index in urlsToUpload.indices
                    where refTypes.indices.contains(index)
                        && refTypes[index] == .image
                        && ImageConverter.requiresConversion(urlsToUpload[index]) {
                    let converted = try await ImageConverter.convertToJPEG(urlsToUpload[index])
                    urlsToUpload[index] = converted
                    tempFiles.append(converted)
                }
            }
            let delivered: [String]
            switch delivery {
            case .hosted:
                delivered = try await uploadReferences(
                    at: urlsToUpload,
                    types: refTypes,
                    cacheKeys: uploadCacheKeys(
                        references: references,
                        trimmedIndex: trimmedIndex,
                        hasPreprocess: preprocessRef != nil || preprocessSourceVideo != nil
                    ),
                )
            case .local:
                delivered = urlsToUpload.map(\.absoluteString)
            }
            return PreparedReferences(delivered: delivered, tempFiles: tempFiles)
        } catch {
            Self.cleanupTempFiles(tempFiles)
            throw error
        }
    }

    private func preprocessedReferenceURLs(
        references: [MediaAsset],
        currentURLs: [URL],
        preprocessRef: @escaping @Sendable (Int, MediaAsset, URL) async throws -> URL?
    ) async throws -> [(Int, URL?)] {
        try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            for (i, asset) in references.enumerated() {
                let currentURL = currentURLs[i]
                group.addTask { (i, try await preprocessRef(i, asset, currentURL)) }
            }
            var results: [(Int, URL?)] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    private func uploadCacheKeys(
        references: [MediaAsset],
        trimmedIndex: Int?,
        hasPreprocess: Bool
    ) -> [MediaAsset?] {
        references.enumerated().map { index, asset in
            if hasPreprocess { return nil }
            if index == trimmedIndex { return nil }
            return asset
        }
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .preparing
        placeholder.folderId = folderId
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    @discardableResult
    private func downloadAndFinalize(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async -> Bool {
        if asset.generationStatus != .downloading {
            updateGenerationMetadata(asset, editor: editor, status: .downloading)
        }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
            let realExt = remoteURL.pathExtension.lowercased()
            if !realExt.isEmpty, realExt != asset.url.pathExtension.lowercased(),
               ClipType(fileExtension: realExt) != nil {
                asset.url = asset.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            asset.url = try await editor.commitStagedProjectMedia(tempURL, filename: asset.url.lastPathComponent)

            asset.pendingDownloadURL = nil
            editor.importMediaAsset(asset, skipAppend: true)
            let finalized = await editor.finalizeImportedAsset(asset)
            return finalized
        } catch {
            let message = error.localizedDescription
            Log.generation.error("download failed url=\(remoteURL.absoluteString) error=\(message)")
            asset.pendingDownloadURL = remoteURL
            updateGenerationMetadata(asset, editor: editor, status: .failed(message))
            return false
        }
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        Task { @MainActor in
            await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
        }
    }

    @discardableResult
    func enhanceDraft(asset: MediaAsset, editor: EditorViewModel) -> String? {
        guard asset.canEnhanceDraft,
              let originalInput = asset.generationInput,
              let sourceJobId = originalInput.backendJobId else { return nil }
        var enhancedInput = originalInput
        enhancedInput.draft = false
        enhancedInput.resolution = "1080p"
        enhancedInput.backendJobId = nil
        enhancedInput.resultURLs = nil
        enhancedInput.costCredits = nil
        enhancedInput.refundedCredits = nil
        enhancedInput.createdAt = Date()
        let placeholder = createPlaceholder(
            type: .video,
            name: "\(asset.name) 1080p",
            duration: asset.resolvedDuration,
            genInput: enhancedInput,
            folderId: asset.folderId,
            destDir: Self.destinationDirectory(for: editor.projectURL),
            fileExtension: "mp4",
            editor: editor
        )

        Task { @MainActor in
            await self.runJob(
                placeholders: [placeholder],
                genInput: enhancedInput,
                editor: editor,
                onComplete: { _ in
                    editor.mediaPanelToast = MediaPanelToast(
                        message: L10n.string("Enhanced with FLUX.3 at 1080p."),
                        kind: .success
                    )
                },
                onFailure: {
                    if case .failed(let message) = placeholder.generationStatus {
                        editor.mediaPanelToast = MediaPanelToast(message: message)
                    }
                },
                submit: {
                    try await GenerationBackend.enhanceDraft(sourceJobId: sourceJobId)
                }
            )
        }
        return placeholder.id
    }

    func resumePendingGenerations(editor: EditorViewModel) {
        func sorted(_ assets: [MediaAsset]) -> [MediaAsset] {
            assets.sorted {
                let left = $0.generationInput?.outputIndex ?? 0
                let right = $1.generationInput?.outputIndex ?? 0
                return left < right
            }
        }

        let pending = editor.mediaAssets.filter(\.isRecoveringGeneration)

        let byBackendJob = Dictionary(grouping: pending.compactMap { asset -> (String, MediaAsset)? in
            guard let input = asset.generationInput,
                  let backendJobId = input.backendJobId, !backendJobId.isEmpty,
                  let backendID = input.generationBackendID else { return nil }
            return (Self.jobKey(backendID: backendID, jobID: backendJobId), asset)
        }, by: { $0.0 })

        for (jobKey, group) in byBackendJob where !activeBackendJobs.contains(jobKey) {
            let placeholders = sorted(group.map { $0.1 })
            guard let input = placeholders.first?.generationInput,
                  let backendJobId = input.backendJobId,
                  let backendID = input.generationBackendID else { continue }
            activeBackendJobs.insert(jobKey)
            Task { @MainActor [weak self, weak editor] in
                guard let self else { return }
                defer { self.activeBackendJobs.remove(jobKey) }
                guard let editor else { return }
                switch GenerationRoute(rawValue: backendID) {
                case .hosted:
                    await self.monitorBackendJob(
                        backendJobId: backendJobId,
                        placeholders: placeholders,
                        editor: editor,
                        onComplete: nil,
                        onFailure: nil
                    )
                case .custom:
                    guard let remoteModel = input.remoteModel, !remoteModel.isEmpty else {
                        self.failRecovery(
                            placeholders,
                            message: "The stored custom video model is missing.",
                            editor: editor
                        )
                        return
                    }
                    do {
                        let connection = try await CustomGenerationConfiguration.shared.recoverySnapshot()
                        let receipt = CustomVideoJobReceipt(
                            backendID: backendID,
                            remoteModelID: remoteModel,
                            jobID: backendJobId
                        )
                        await self.monitorCustomVideo(
                            receipt: receipt,
                            connection: connection,
                            runner: CustomGenerationRunner(),
                            placeholders: placeholders,
                            editor: editor,
                            onComplete: nil,
                            onFailure: nil
                        )
                    } catch {
                        self.failRecovery(placeholders, message: error.localizedDescription, editor: editor)
                    }
                case nil:
                    self.failRecovery(
                        placeholders,
                        message: "Unknown generation backend '\(backendID)'.",
                        editor: editor
                    )
                }
            }
        }
    }

    private static func jobKey(backendID: String, jobID: String) -> String {
        "\(backendID):\(jobID)"
    }

    private func failRecovery(
        _ placeholders: [MediaAsset],
        message: String,
        editor: EditorViewModel
    ) {
        for placeholder in placeholders {
            updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
        }
        editor.onProjectCheckpointRequired?()
    }

    private func backendError(_ error: Error) -> (code: String?, message: String) {
        struct Payload: Decodable { let code: String?; let message: String? }
        if case let ClientError.ConvexError(data) = error,
           let json = data.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: json),
           let message = payload.message {
            return (payload.code, message)
        }
        return (nil, error.localizedDescription)
    }

    private func persistCustomInput(
        _ input: GenerationInput,
        placeholders: [MediaAsset],
        editor: EditorViewModel
    ) {
        for (outputIndex, placeholder) in placeholders.enumerated() {
            var storedInput = input
            storedInput.outputIndex = outputIndex
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { $0 = storedInput }
        }
    }

    private func monitorCustomVideo(
        receipt: CustomVideoJobReceipt,
        connection: CustomGenerationConnectionSnapshot,
        runner: CustomGenerationRunner,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        do {
            let remoteURL = try await runner.waitForVideo(connection: connection, receipt: receipt)
            try Task.checkCancellation()
            let resultURLs = [remoteURL.absoluteString]
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .downloading) { input in
                    input.resultURLs = resultURLs
                }
            }
            editor.onProjectCheckpointRequired?()
            let staged = try await runner.stageVideo(from: remoteURL)
            do {
                try Task.checkCancellation()
                await finalizeCustomSuccess(
                    stagedFiles: [staged],
                    placeholders: placeholders,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                await CustomGenerationRunner.remove([staged])
                throw error
            }
        } catch {
            let message = error is CancellationError ? "Video generation polling cancelled." : error.localizedDescription
            Log.generation.error("custom video job \(receipt.jobID) stopped error=\(message)")
            for placeholder in placeholders
                where placeholder.generationStatus != .none
                    && editor.mediaAssets.contains(where: { $0 === placeholder }) {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
        }
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: [asset])
    }

    /// Uploads each reference and returns the hosted URLs.
    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        cacheKeys: [MediaAsset?],
    ) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let cacheKey = cacheKeys.indices.contains(i) ? cacheKeys[i] : nil
                let requiresConversion = type == .image
                    && ImageConverter.requiresConversion(url)
                if !requiresConversion, let cacheKey, let hit = cacheKey.freshRemoteURL {
                    group.addTask { (i, hit) }
                    continue
                }
                let contentType = requiresConversion
                    ? "image/jpeg"
                    : Self.contentType(for: url, fallback: type)
                group.addTask {
                    let convertedURL = requiresConversion
                        ? try await ImageConverter.convertToJPEG(url)
                        : nil
                    do {
                        let uploaded = try await GenerationBackend.uploadReference(
                            fileURL: convertedURL ?? url,
                            contentType: contentType,
                        )
                        if let convertedURL {
                            await ImageConverter.removeConvertedFile(convertedURL)
                        }
                        if !requiresConversion, let cacheKey {
                            await Self.recordUploadCache(asset: cacheKey, url: uploaded)
                        }
                        return (i, uploaded)
                    } catch {
                        if let convertedURL {
                            await ImageConverter.removeConvertedFile(convertedURL)
                        }
                        throw error
                    }
                }
            }
            var results = [(Int, String)]()
            for try await r in group { results.append(r) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    @MainActor
    private static func recordUploadCache(asset: MediaAsset, url: String) {
        asset.cachedRemoteURL = url
        asset.cachedRemoteURLExpiresAt = Date().addingTimeInterval(uploadCacheTTL)
    }

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text, .subtitle: return "application/octet-stream"
            case .lottie: return "application/json"
            case .sequence: return "video/mp4"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?,
        submit: () async throws -> String
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        let jobId: String
        do {
            jobId = try await submit()
        } catch {
            let (code, message) = backendError(error)
            let expected: Set<String> = [
                "insufficient_credits", "subscription_required", "plan_required",
                "rate_limited", "invalid_params",
            ]
            if let code, expected.contains(code) {
                Log.generation.warning("submit failed model=\(genInput.model) code=\(code) error=\(message)")
            } else {
                Log.generation.error("submit failed model=\(genInput.model) error=\(message)")
            }
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
            }
            onFailure?()
            return
        }

        for placeholder in placeholders {
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.backendJobId = jobId
            }
        }
        editor.onProjectCheckpointRequired?()

        await monitorBackendJob(
            backendJobId: jobId,
            placeholders: placeholders,
            editor: editor,
            failIfUnavailable: true,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func monitorBackendJob(
        backendJobId: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        failIfUnavailable: Bool = false,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let publisher = GenerationBackend.subscribe(jobId: backendJobId) else {
            if failIfUnavailable {
                for placeholder in placeholders {
                    updateGenerationMetadata(placeholder, editor: editor, status: .failed("Backend not configured"))
                }
                editor.onProjectCheckpointRequired?()
                onFailure?()
            }
            return
        }

        for await jobOpt in backendJobStream(from: publisher) {
            guard let job = jobOpt else { continue }
            if await applyBackendJobUpdate(
                job: job,
                backendJobId: backendJobId,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            ) {
                return
            }
        }

        // Stream ended without a terminal update: finish from persisted URLs, else retry on reopen.
        let persisted = placeholders.compactMap(\.generationInput?.resultURLs).first ?? []
        guard !persisted.isEmpty else { return }
        await finalizeSuccess(
            urlStrings: persisted,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func backendJobStream<Failure: Error>(
        from publisher: AnyPublisher<BackendGenerationJob?, Failure>
    ) -> AsyncStream<BackendGenerationJob?> {
        AsyncStream<BackendGenerationJob?> { continuation in
            let cancellable = publisher
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in continuation.finish() },
                    receiveValue: { value in continuation.yield(value) },
                )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private func applyBackendJobUpdate(
        job: BackendGenerationJob,
        backendJobId: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async -> Bool {
        switch job.status {
        case .succeeded:
            if updateBackendJobMetadata(
                placeholders,
                backendJobId: backendJobId,
                costCredits: job.costCredits,
                editor: editor
            ) {
                editor.onProjectCheckpointRequired?()
            }
            await finalizeSuccess(
                urlStrings: job.resultUrls ?? [],
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure,
            )
            return true
        case .failed:
            let message = job.errorMessage ?? "Generation failed"
            Log.generation.error("job \(backendJobId) failed: \(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                    input.backendJobId = backendJobId
                    if let costCredits = job.costCredits {
                        input.costCredits = costCredits
                    }
                    input.refundedCredits = job.refundedCredits
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return true
        case .queued, .running:
            if updateBackendJobMetadata(
                placeholders,
                backendJobId: backendJobId,
                costCredits: job.costCredits,
                editor: editor
            ) {
                editor.onProjectCheckpointRequired?()
            }
            return false
        }
    }

    @discardableResult
    private func updateBackendJobMetadata(
        _ placeholders: [MediaAsset],
        backendJobId: String,
        costCredits: Int?,
        editor: EditorViewModel
    ) -> Bool {
        var changed = false
        for placeholder in placeholders {
            guard placeholder.generationStatus != .downloading else { continue }
            let input = placeholder.generationInput
            let metadataUnchanged = placeholder.generationStatus == .generating
                && input?.backendJobId == backendJobId
                && (costCredits == nil || input?.costCredits == costCredits)
            guard !metadataUnchanged else { continue }
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.backendJobId = backendJobId
                if let costCredits {
                    input.costCredits = costCredits
                }
            }
            changed = true
        }
        return changed
    }

    private func finalizeSuccess(
        urlStrings: [String],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard !urlStrings.isEmpty else {
            Log.generation.error("backend job succeeded with no resultUrls")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL in response"))
            }
            onFailure?()
            return
        }
        if urlStrings.count < placeholders.count {
            Log.generation.notice("backend returned \(urlStrings.count) URL(s) for \(placeholders.count) placeholder(s); marking extras as failed")
        }

        var finalized: [MediaAsset] = []
        for (i, placeholder) in placeholders.enumerated() {
            let outputIndex = placeholder.generationInput?.outputIndex ?? i
            guard outputIndex < urlStrings.count, let remote = URL(string: urlStrings[outputIndex]) else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL for placeholder"))
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading) { input in
                input.resultURLs = urlStrings
            }
            if await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor) {
                onComplete?(placeholder)
                finalized.append(placeholder)
            }
        }

        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        } else {
            onFailure?()
        }
    }

    private func finalizeCustomSuccess(
        stagedFiles: [URL],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard !stagedFiles.isEmpty else {
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("Gateway returned no media."))
            }
            onFailure?()
            return
        }
        var finalized: [MediaAsset] = []
        for (index, placeholder) in placeholders.enumerated() {
            let outputIndex = placeholder.generationInput?.outputIndex ?? index
            guard stagedFiles.indices.contains(outputIndex) else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No result for placeholder."))
                continue
            }
            let stagedURL = stagedFiles[outputIndex]
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading)
            do {
                let ext = stagedURL.pathExtension.isEmpty ? "png" : stagedURL.pathExtension.lowercased()
                placeholder.url = placeholder.url.deletingPathExtension().appendingPathExtension(ext)
                placeholder.url = try await editor.commitStagedProjectMedia(
                    stagedURL,
                    filename: placeholder.url.lastPathComponent
                )
                editor.importMediaAsset(placeholder, skipAppend: true)
                if await editor.finalizeImportedAsset(placeholder) {
                    onComplete?(placeholder)
                    finalized.append(placeholder)
                }
            } catch {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(error.localizedDescription))
            }
        }
        await CustomGenerationRunner.remove(stagedFiles)
        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        }
        if finalized.count < placeholders.count { onFailure?() }
    }

}
