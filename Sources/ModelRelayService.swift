import Foundation

final class ModelRelayService: @unchecked Sendable {
    private struct FetchedModels {
        let discovery: ModelRelayModelDiscovery
        let keyID: UUID
        let secretDigest: Data
    }

    private struct ModelFetchFailure: Error {
        let underlying: Error
        let keyID: UUID
        let secretDigest: Data?
        let statusCode: Int?
    }

    private let configStore: ModelRelayConfigStoring
    private let upstreamKeyStore: ModelRelayUpstreamKeyStoring
    private let localKeyVault: ModelRelayLocalKeyVault
    private let upstreamClient: ModelRelayUpstreamClient
    private let persistenceLock = NSRecursiveLock()
    private let lock = NSLock()
    private var configuration: ModelRelayConfiguration
    private let startupError: Error?
    private var refreshTimer: DispatchSourceTimer?
    private var storedRunState: ModelRelayRunState = .stopped
    private var wantsRunning = false
    private let internalAccessToken: String
    let router: ModelRelayRouter
    let server: ModelRelayHTTPServer
    let callMetrics: ModelRelayCallMetricsRecording

    var didChange: (() -> Void)?

    var runState: ModelRelayRunState {
        lock.lock()
        defer { lock.unlock() }
        return storedRunState
    }

    init(
        configStore: ModelRelayConfigStoring = FileModelRelayConfigStore(),
        upstreamKeyStore: ModelRelayUpstreamKeyStoring = KeychainModelRelayUpstreamKeyStore(),
        localKeyVault: ModelRelayLocalKeyVault = ModelRelayLocalKeyVault(),
        upstreamClient: ModelRelayUpstreamClient = ModelRelayUpstreamClient(),
        callMetrics: ModelRelayCallMetricsRecording = ModelRelayCallMetricsStore()
    ) {
        self.configStore = configStore
        self.upstreamKeyStore = upstreamKeyStore
        self.localKeyVault = localKeyVault
        self.upstreamClient = upstreamClient
        self.callMetrics = callMetrics
        internalAccessToken = "tg_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let loaded: ModelRelayConfiguration
        do {
            let stored = try configStore.load()
            let migrated = Self.normalizingPublishedModelIDs(
                Self.migratingLegacyProviderKeys(stored)
            )
            if migrated != stored {
                try configStore.save(migrated)
            }
            loaded = migrated
            startupError = nil
        } catch {
            loaded = ModelRelayConfiguration()
            startupError = error
            storedRunState = .failed(error.localizedDescription)
        }
        configuration = loaded
        router = ModelRelayRouter(
            configuration: loaded,
            keyStore: upstreamKeyStore,
            vault: localKeyVault,
            internalCredentialDigest: ModelRelayLocalKeyVault.digest(internalAccessToken)
        )
        server = ModelRelayHTTPServer(router: router, upstream: upstreamClient, metrics: callMetrics)
        server.stateDidChange = { [weak self] state in
            self?.setRunState(state)
        }
        router.availabilityDidChange = { [weak self] in
            self?.notifyChange()
        }
        cleanupPendingUpstreamKeys()
    }

    static func migratingLegacyProviderKeys(
        _ configuration: ModelRelayConfiguration
    ) -> ModelRelayConfiguration {
        guard configuration.providers.contains(where: { $0.keys.count > 1 }) else {
            return configuration
        }
        var migrated = configuration
        var occupied = Set(configuration.providers.map { $0.name.lowercased() })
        var providers: [ModelRelayProvider] = []
        for provider in configuration.providers {
            guard let first = provider.keys.first, provider.keys.count > 1 else {
                providers.append(provider)
                continue
            }
            var primary = provider
            primary.keys = [first]
            providers.append(primary)
            for key in provider.keys.dropFirst() {
                let name = uniqueMigratedProviderName(
                    preferred: "\(provider.name) · \(key.name)",
                    occupied: occupied
                )
                occupied.insert(name.lowercased())
                providers.append(ModelRelayProvider(
                    name: name,
                    baseURL: provider.baseURL,
                    keys: [key],
                    models: provider.models.map {
                        ModelRelayModelRoute(
                            id: UUID(),
                            upstreamModelID: $0.upstreamModelID,
                            alias: $0.upstreamModelID,
                            capability: $0.capability
                        )
                    }
                ))
            }
        }
        migrated.providers = providers
        return migrated
    }

    static func normalizingPublishedModelIDs(
        _ configuration: ModelRelayConfiguration
    ) -> ModelRelayConfiguration {
        var updated = configuration
        var occupied = Set<String>()
        var providers: [ModelRelayProvider] = []
        for provider in configuration.providers {
            var next = provider
            var models: [ModelRelayModelRoute] = []
            for route in provider.models {
                let published = publishedModelID(
                    upstreamModelID: route.upstreamModelID,
                    providerName: provider.name,
                    occupied: occupied
                )
                occupied.insert(published.lowercased())
                models.append(ModelRelayModelRoute(
                    id: route.id,
                    upstreamModelID: route.upstreamModelID,
                    alias: published,
                    capability: route.capability
                ))
            }
            next.models = models
            providers.append(next)
        }
        updated.providers = providers
        return updated
    }

    private static func uniqueMigratedProviderName(
        preferred: String,
        occupied: Set<String>
    ) -> String {
        func limited(_ value: String) -> String {
            String(value.prefix(80))
        }
        let base = limited(preferred)
        if !occupied.contains(base.lowercased()) {
            return base
        }
        var suffix = 2
        while true {
            let marker = "-\(suffix)"
            let prefix = String(preferred.prefix(max(1, 80 - marker.count)))
            let candidate = prefix + marker
            if !occupied.contains(candidate.lowercased()) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func publishedModelID(
        upstreamModelID: String,
        providerName: String,
        occupied: Set<String>
    ) -> String {
        let preferred = occupied.contains(upstreamModelID.lowercased())
            ? "\(providerName)/\(upstreamModelID)"
            : upstreamModelID
        if !occupied.contains(preferred.lowercased()) {
            return preferred
        }
        var suffix = 2
        while occupied.contains("\(preferred)-\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(preferred)-\(suffix)"
    }

    deinit {
        refreshTimer?.cancel()
        server.stop()
    }

    func start() throws {
        lock.lock()
        wantsRunning = true
        lock.unlock()
        do {
            if let startupError { throw startupError }
            let port = configurationSnapshot().port
            let readiness = ModelRelayServiceReadiness()
            try server.start(port: port) { result in
                readiness.resolve(result)
            }
            guard let result = readiness.wait(timeout: 5) else {
                server.stop()
                throw ModelRelayError.listener("启动监听超时")
            }
            if case .failure(let error) = result {
                throw error
            }
            startRefreshTimer()
            refreshAllProviders()
        } catch {
            setRunState(.failed(error.localizedDescription))
            throw error
        }
    }

    func stop() {
        lock.lock()
        wantsRunning = false
        let timer = refreshTimer
        refreshTimer = nil
        lock.unlock()
        timer?.cancel()
        server.stop()
    }

    func snapshot() -> ModelRelayConfiguration {
        configurationSnapshot()
    }

    /// CLI / 微信点号命令用的非密钥状态摘要。
    func cliStatus() -> TocodeModelRelayCLIStatus {
        let configuration = configurationSnapshot()
        let lastID = callMetrics.lastUsedProviderID
        let lastName = configuration.providers.first(where: { $0.id == lastID })?.name
        let count: Int
        if let lastID {
            count = callMetrics.series(
                providerID: lastID,
                range: .sixHours,
                now: Date()
            ).reduce(0) { $0 + $1.count }
        } else {
            count = 0
        }
        return TocodeModelRelayCLIStatus(
            baseURL: "http://127.0.0.1:\(configuration.port)/v1",
            port: configuration.port,
            runStateText: runState.menuText,
            lastUsedProviderName: lastName,
            callCountLast6Hours: count
        )
    }

    func availableTogentModels() -> [TogentModelOption] {
        router.availableTogentModels()
    }

    func todayCallLogURL() throws -> URL {
        try callMetrics.ensureTodayLogFile()
    }

    /// 仅供同一 Tocode 进程启动受管 Togent 子进程；token 从不进入持久配置或日志。
    func togentRelayAccess() -> TogentRelayAccess {
        let snapshot = configurationSnapshot()
        return TogentRelayAccess(
            baseURL: "http://127.0.0.1:\(snapshot.port)/v1",
            bearerToken: internalAccessToken,
            models: router.availableTogentModels()
        )
    }

    /// 健康状态回调专用；不能读取钥匙串，否则首次授权会阻塞菜单主线程。
    func togentRelayFingerprint() -> String {
        let snapshot = configurationSnapshot()
        let models = router.togentModelFingerprintsForHealthObservation()
        return (["http://127.0.0.1:\(snapshot.port)/v1"] + models)
            .joined(separator: "\n")
    }

    func updatePort(
        _ value: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if let startupError {
            completeOnMain(completion, result: .failure(startupError))
            return
        }
        guard (1024...65_535).contains(value) else {
            completeOnMain(completion, result: .failure(ModelRelayError.invalidPort))
            return
        }
        let previousPort = configurationSnapshot().port
        let nextPort = UInt16(value)
        guard previousPort != nextPort else {
            completeOnMain(completion, result: .success(()))
            return
        }
        lock.lock()
        let wasActive = storedRunState != .stopped
        lock.unlock()
        guard wasActive else {
            do {
                try mutateConfiguration { $0.port = nextPort }
                completeOnMain(completion, result: .success(()))
            } catch {
                completeOnMain(completion, result: .failure(error))
            }
            return
        }

        server.stop()
        do {
            try server.start(port: nextPort) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.restoreListener(
                        port: previousPort,
                        originalError: error,
                        completion: completion
                    )
                case .success:
                    do {
                        try self.mutateConfiguration { $0.port = nextPort }
                        if self.isRunningWanted() {
                            self.startRefreshTimer()
                            self.refreshAllProviders()
                        }
                        self.completeOnMain(completion, result: .success(()))
                    } catch {
                        self.restoreListener(
                            port: previousPort,
                            originalError: error,
                            completion: completion
                        )
                    }
                }
            }
        } catch {
            restoreListener(
                port: previousPort,
                originalError: error,
                completion: completion
            )
        }
    }

    @discardableResult
    func testProviderConnection(
        providerID: UUID?,
        baseURL: String,
        candidateSecret: String?,
        completion: @escaping (Result<ModelRelayProviderConnectionTest, Error>) -> Void
    ) -> Task<Void, Never> {
        let normalizedURL: String
        let secret: String
        let replacesKey: Bool
        let cachedCapabilities: [String: ModelRelayModelCapability]
        do {
            normalizedURL = try ModelRelayValidation.normalizedBaseURL(baseURL)
            if let providerID {
                let provider = configurationSnapshot().providers.first { $0.id == providerID }
                guard let provider, provider.keys.count <= 1 else {
                    throw ModelRelayError.providerNotFound
                }
            }
            if let candidateSecret, !candidateSecret.isEmpty {
                secret = try normalizedUpstreamSecret(candidateSecret)
                replacesKey = true
                cachedCapabilities = [:]
            } else if let providerID {
                let snapshot = configurationSnapshot()
                guard let provider = snapshot.providers.first(where: { $0.id == providerID }),
                      provider.keys.count <= 1,
                      let key = provider.upstreamKey,
                      let stored = try upstreamKeyStore.load(id: key.id) else {
                    throw ModelRelayError.keyNotFound
                }
                secret = stored
                replacesKey = false
                cachedCapabilities = provider.baseURL == normalizedURL
                    ? Dictionary(
                        uniqueKeysWithValues: provider.models.map {
                            ($0.upstreamModelID, $0.capability)
                        }
                    )
                    : [:]
            } else {
                throw ModelRelayError.keyNotFound
            }
        } catch {
            completeOnMain(completion, result: .failure(error))
            return Task {}
        }
        return Task { [weak self] in
            guard let self else { return }
            do {
                let discovery = try await self.upstreamClient.discoverModels(
                    baseURL: normalizedURL,
                    secret: secret,
                    cachedCapabilities: cachedCapabilities,
                    probeCapabilities: true
                )
                try Task.checkCancellation()
                self.completeOnMain(completion, result: .success(
                    ModelRelayProviderConnectionTest(
                        providerID: providerID,
                        baseURL: normalizedURL,
                        secret: secret,
                        replacesKey: replacesKey,
                        modelIDs: discovery.modelIDs,
                        capabilities: discovery.capabilities
                    )
                ))
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    @discardableResult
    func createProvider(
        name: String,
        using test: ModelRelayProviderConnectionTest
    ) throws -> ModelRelayProvider {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard test.providerID == nil,
              test.replacesKey,
              !test.modelIDs.isEmpty else {
            throw ModelRelayError.providerConnectionNotTested
        }
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        let normalizedURL = try ModelRelayValidation.normalizedBaseURL(test.baseURL)
        let secret = try normalizedUpstreamSecret(test.secret)
        let reference = ModelRelayUpstreamKeyReference(name: "默认")
        var provider = ModelRelayProvider(
            name: normalizedName,
            baseURL: normalizedURL,
            keys: [reference]
        )
        try stageUpstreamKeyForDeletion(reference.id)
        do {
            try upstreamKeyStore.save(secret, id: reference.id)
        } catch {
            let originalError = error
            cleanupPendingUpstreamKeys()
            throw originalError
        }
        do {
            try mutateConfiguration { configuration in
                guard !configuration.providers.contains(where: {
                    $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
                }) else {
                    throw ModelRelayError.duplicateProviderName
                }
                provider.models = mergedModelRoutes(
                    providerID: provider.id,
                    providerName: normalizedName,
                    modelIDs: test.modelIDs,
                    existing: [],
                    capabilities: test.capabilities,
                    configuration: configuration
                )
                configuration.providers.append(provider)
                configuration.pendingUpstreamKeyDeletions.removeAll { $0 == reference.id }
            }
        } catch {
            let originalError = error
            try discardStagedUpstreamKey(
                reference.id,
                rollbackMessage: "厂家创建失败后的密钥清理失败。"
            )
            throw originalError
        }
        router.recordSuccess(keyID: reference.id)
        return provider
    }

    func updateProvider(
        id: UUID,
        name: String,
        using test: ModelRelayProviderConnectionTest?
    ) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        let before = configurationSnapshot()
        guard let existing = before.providers.first(where: { $0.id == id }) else {
            throw ModelRelayError.providerNotFound
        }
        guard existing.keys.count <= 1 else {
            throw ModelRelayError.providerAlreadyHasKey
        }
        if test == nil {
            try mutateConfiguration { configuration in
                guard let index = configuration.providers.firstIndex(where: { $0.id == id }) else {
                    throw ModelRelayError.providerNotFound
                }
                try ensureUniqueProviderName(
                    normalizedName,
                    excluding: id,
                    configuration: configuration
                )
                configuration.providers[index].name = normalizedName
                configuration = Self.normalizingPublishedModelIDs(configuration)
            }
            return
        }
        guard let test,
              test.providerID == id,
              !test.modelIDs.isEmpty else {
            throw ModelRelayError.providerConnectionNotTested
        }
        let normalizedURL = try ModelRelayValidation.normalizedBaseURL(test.baseURL)
        let currentReference = existing.upstreamKey
        guard test.replacesKey || currentReference != nil else {
            throw ModelRelayError.keyNotFound
        }
        let currentSecret = try currentReference.flatMap { try upstreamKeyStore.load(id: $0.id) }
        if !test.replacesKey, currentSecret != test.secret {
            throw ModelRelayError.providerConnectionNotTested
        }
        let rotatesConnection = test.replacesKey || normalizedURL != existing.baseURL
        let reference = rotatesConnection
            ? ModelRelayUpstreamKeyReference(name: currentReference?.name ?? "默认")
            : currentReference!
        let candidateSecret = test.replacesKey
            ? try normalizedUpstreamSecret(test.secret)
            : test.secret
        if rotatesConnection {
            try stageUpstreamKeyForDeletion(reference.id)
            do {
                try upstreamKeyStore.save(candidateSecret, id: reference.id)
            } catch {
                let originalError = error
                cleanupPendingUpstreamKeys()
                throw originalError
            }
        }
        do {
            try mutateConfiguration { configuration in
                guard let index = configuration.providers.firstIndex(where: { $0.id == id }),
                      configuration.providers[index].keys.count <= 1,
                      configuration.providers[index].upstreamKey?.id == currentReference?.id else {
                    throw ModelRelayError.providerNotFound
                }
                try ensureUniqueProviderName(
                    normalizedName,
                    excluding: id,
                    configuration: configuration
                )
                let current = configuration.providers[index]
                configuration.providers[index].name = normalizedName
                configuration.providers[index].baseURL = normalizedURL
                configuration.providers[index].keys = [reference]
                configuration.providers[index].models = mergedModelRoutes(
                    providerID: id,
                    providerName: normalizedName,
                    modelIDs: test.modelIDs,
                    existing: current.models,
                    capabilities: test.capabilities,
                    configuration: configuration
                )
                if rotatesConnection {
                    configuration.pendingUpstreamKeyDeletions.removeAll { $0 == reference.id }
                    if let currentReference,
                       !configuration.pendingUpstreamKeyDeletions.contains(currentReference.id) {
                        configuration.pendingUpstreamKeyDeletions.append(currentReference.id)
                    }
                }
            }
        } catch {
            let originalError = error
            if rotatesConnection {
                try discardStagedUpstreamKey(
                    reference.id,
                    rollbackMessage: "厂家连接配置保存失败后的候选密钥清理失败。"
                )
            }
            throw originalError
        }
        if rotatesConnection {
            cleanupPendingUpstreamKeys()
        }
        if let currentReference, currentReference.id != reference.id {
            router.resetHealth(keyIDs: [currentReference.id])
        }
        router.recordSuccess(keyID: reference.id)
    }

    func deleteProvider(id: UUID) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        try mutateConfiguration { configuration in
            guard let provider = configuration.providers.first(where: { $0.id == id }) else {
                throw ModelRelayError.providerNotFound
            }
            for keyID in provider.keys.map(\.id)
                where !configuration.pendingUpstreamKeyDeletions.contains(keyID) {
                configuration.pendingUpstreamKeyDeletions.append(keyID)
            }
            configuration.providers.removeAll { $0.id == id }
        }
        cleanupPendingUpstreamKeys()
    }

    func addUpstreamKey(
        providerID: UUID,
        name: String,
        secret: String,
        completion: @escaping (Result<ModelRelayUpstreamKeyReference, Error>) -> Void
    ) {
        let normalizedName: String
        do {
            normalizedName = try validateUpstreamKeyInput(
                providerID: providerID,
                keyID: nil,
                name: name,
                secret: secret
            )
        } catch {
            completeOnMain(completion, result: .failure(error))
            return
        }
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            completeOnMain(completion, result: .failure(ModelRelayError.providerNotFound))
            return
        }
        guard provider.keys.isEmpty else {
            completeOnMain(completion, result: .failure(ModelRelayError.providerAlreadyHasKey))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let modelIDs = try await self.upstreamClient.fetchModels(
                    baseURL: provider.baseURL,
                    secret: secret
                )
                let reference = try self.withPersistenceTransaction {
                    let reference = try self.storeUpstreamKey(
                        providerID: providerID,
                        name: normalizedName,
                        secret: secret,
                        modelIDs: modelIDs
                    )
                    self.recordSuccessIfCurrent(
                        provider: provider,
                        keyID: reference.id,
                        secretDigest: ModelRelayLocalKeyVault.digest(secret)
                    )
                    return reference
                }
                self.completeOnMain(completion, result: .success(reference))
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    private func storeUpstreamKey(
        providerID: UUID,
        name: String,
        secret: String,
        modelIDs: [String]
    ) throws -> ModelRelayUpstreamKeyReference {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelRelayError.keyNotFound
        }
        let uniqueModelIDs = Array(Set(modelIDs)).sorted()
        guard !uniqueModelIDs.isEmpty else {
            throw ModelRelayError.noModels
        }
        let reference = ModelRelayUpstreamKeyReference(name: normalizedName)
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            throw ModelRelayError.providerNotFound
        }
        guard provider.keys.isEmpty else {
            throw ModelRelayError.providerAlreadyHasKey
        }
        guard !provider.keys.contains(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ModelRelayError.duplicateKeyName
        }
        try stageUpstreamKeyForDeletion(reference.id)
        do {
            try upstreamKeyStore.save(secret, id: reference.id)
        } catch {
            let originalError = error
            cleanupPendingUpstreamKeys()
            throw originalError
        }
        do {
            try mutateConfiguration { configuration in
                guard let index = configuration.providers.firstIndex(where: { $0.id == providerID }),
                      configuration.providers[index].keys.isEmpty else {
                    throw ModelRelayError.providerNotFound
                }
                let current = configuration.providers[index]
                configuration.providers[index].keys = [reference]
                configuration.providers[index].models = mergedModelRoutes(
                    providerID: providerID,
                    providerName: current.name,
                    modelIDs: uniqueModelIDs,
                    existing: current.models,
                    capabilities: Self.unknownCapabilities(for: uniqueModelIDs),
                    configuration: configuration
                )
                configuration.pendingUpstreamKeyDeletions.removeAll { $0 == reference.id }
            }
        } catch {
            let originalError = error
            try discardStagedUpstreamKey(
                reference.id,
                rollbackMessage: "厂家密钥创建失败后的清理失败。"
            )
            throw originalError
        }
        return reference
    }

    func replaceUpstreamKey(
        providerID: UUID,
        keyID: UUID,
        name: String,
        secret: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let normalizedName: String
        do {
            normalizedName = try validateUpstreamKeyInput(
                providerID: providerID,
                keyID: keyID,
                name: name,
                secret: secret
            )
        } catch {
            completeOnMain(completion, result: .failure(error))
            return
        }
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            completeOnMain(completion, result: .failure(ModelRelayError.providerNotFound))
            return
        }
        guard provider.keys.contains(where: { $0.id == keyID }) else {
            completeOnMain(completion, result: .failure(ModelRelayError.keyNotFound))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let modelIDs = try await self.upstreamClient.fetchModels(
                    baseURL: provider.baseURL,
                    secret: secret
                )
                let replacement = try self.withPersistenceTransaction {
                    try self.storeReplacement(
                        providerID: providerID,
                        keyID: keyID,
                        name: normalizedName,
                        secret: secret,
                        modelIDs: modelIDs
                    )
                }
                self.recordSuccessIfCurrent(
                    provider: provider,
                    keyID: replacement.id,
                    secretDigest: ModelRelayLocalKeyVault.digest(secret)
                )
                self.completeOnMain(completion, result: .success(()))
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    private func storeReplacement(
        providerID: UUID,
        keyID: UUID,
        name: String,
        secret: String,
        modelIDs: [String]
    ) throws -> ModelRelayUpstreamKeyReference {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelRelayError.keyNotFound
        }
        let uniqueModelIDs = Array(Set(modelIDs)).sorted()
        guard !uniqueModelIDs.isEmpty else {
            throw ModelRelayError.noModels
        }
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            throw ModelRelayError.providerNotFound
        }
        guard provider.keys.contains(where: { $0.id == keyID }) else {
            throw ModelRelayError.keyNotFound
        }
        guard !provider.keys.contains(where: {
            $0.id != keyID && $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ModelRelayError.duplicateKeyName
        }
        let replacement = ModelRelayUpstreamKeyReference(name: normalizedName)
        try stageUpstreamKeyForDeletion(replacement.id)
        do {
            try upstreamKeyStore.save(secret, id: replacement.id)
        } catch {
            let originalError = error
            cleanupPendingUpstreamKeys()
            throw originalError
        }
        do {
            try mutateConfiguration { configuration in
                guard let providerIndex = configuration.providers.firstIndex(where: { $0.id == providerID }),
                      configuration.providers[providerIndex].keys.count == 1,
                      configuration.providers[providerIndex].upstreamKey?.id == keyID else {
                    throw ModelRelayError.keyNotFound
                }
                let current = configuration.providers[providerIndex]
                configuration.providers[providerIndex].keys = [replacement]
                configuration.providers[providerIndex].models = mergedModelRoutes(
                    providerID: providerID,
                    providerName: current.name,
                    modelIDs: uniqueModelIDs,
                    existing: current.models,
                    capabilities: Self.unknownCapabilities(for: uniqueModelIDs),
                    configuration: configuration
                )
                configuration.pendingUpstreamKeyDeletions.removeAll { $0 == replacement.id }
                if !configuration.pendingUpstreamKeyDeletions.contains(keyID) {
                    configuration.pendingUpstreamKeyDeletions.append(keyID)
                }
            }
        } catch {
            let originalError = error
            try discardStagedUpstreamKey(
                replacement.id,
                rollbackMessage: "厂家密钥更新失败后的候选密钥清理失败。"
            )
            throw originalError
        }
        cleanupPendingUpstreamKeys()
        return replacement
    }

    func deleteUpstreamKey(providerID: UUID, keyID: UUID) throws {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        try mutateConfiguration { configuration in
            guard let providerIndex = configuration.providers.firstIndex(where: { $0.id == providerID }) else {
                throw ModelRelayError.providerNotFound
            }
            guard configuration.providers[providerIndex].keys.contains(where: { $0.id == keyID }) else {
                throw ModelRelayError.keyNotFound
            }
            configuration.providers[providerIndex].keys.removeAll { $0.id == keyID }
            if !configuration.pendingUpstreamKeyDeletions.contains(keyID) {
                configuration.pendingUpstreamKeyDeletions.append(keyID)
            }
        }
        cleanupPendingUpstreamKeys()
        router.resetHealth(keyIDs: [keyID])
    }

    @discardableResult
    func fetchModels(
        providerID: UUID,
        resetAuthenticationFailures: Bool = true,
        probeCapabilities: Bool = true,
        completion: @escaping (Result<[ModelRelayModelRoute], Error>) -> Void
    ) -> Task<Void, Never> {
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            completeOnMain(completion, result: .failure(ModelRelayError.providerNotFound))
            return Task {}
        }
        let references: [ModelRelayUpstreamKeyReference]
        let entityKeys = Array(provider.keys.prefix(1))
        if resetAuthenticationFailures {
            references = entityKeys
        } else {
            let eligible = Set(router.keyIDsEligibleForAutomaticRefresh(entityKeys.map(\.id)))
            references = entityKeys.filter { eligible.contains($0.id) }
        }
        return Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.fetchModels(
                    provider: provider,
                    references: references,
                    probeCapabilities: probeCapabilities
                )
                try Task.checkCancellation()
                do {
                    let routes = try self.mergeModels(
                        provider: provider,
                        modelIDs: fetched.discovery.modelIDs,
                        capabilities: fetched.discovery.capabilities,
                        expectedKeyID: fetched.keyID,
                        expectedSecretDigest: fetched.secretDigest
                    )
                    self.recordSuccessIfCurrent(
                        provider: provider,
                        keyID: fetched.keyID,
                        secretDigest: fetched.secretDigest
                    )
                    self.completeOnMain(completion, result: .success(routes))
                } catch {
                    self.completeOnMain(completion, result: .failure(error))
                }
            } catch let failure as ModelFetchFailure {
                if !Task.isCancelled {
                    self.recordFailureIfCurrent(provider: provider, failure: failure)
                }
                self.completeOnMain(completion, result: .failure(
                    Task.isCancelled ? CancellationError() : failure.underlying
                ))
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    @discardableResult
    func createLocalKey(name: String, password: String) throws -> ModelRelayLocalKeyRecord {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard password.count >= 8 else { throw ModelRelayError.invalidViewingPassword }
        let snapshot = configurationSnapshot()
        guard !snapshot.localKeys.contains(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ModelRelayError.duplicateKeyName
        }
        let created = try localKeyVault.create(name: normalizedName, viewingPassword: password)
        try mutateConfiguration { $0.localKeys.append(created.record) }
        return created.record
    }

    func connectionInfo(localKeyID: UUID, password: String) throws -> ModelRelayConnectionInfo {
        let snapshot = configurationSnapshot()
        guard let record = snapshot.localKeys.first(where: { $0.id == localKeyID }) else {
            throw ModelRelayError.keyNotFound
        }
        let key = try localKeyVault.reveal(record, viewingPassword: password)
        return ModelRelayConnectionInfo(
            baseURL: "http://127.0.0.1:\(snapshot.port)/v1",
            apiKey: key,
            models: router.availableAliases()
        )
    }

    func deleteLocalKey(id: UUID) throws {
        guard configurationSnapshot().localKeys.contains(where: { $0.id == id }) else {
            throw ModelRelayError.keyNotFound
        }
        try mutateConfiguration { $0.localKeys.removeAll { $0.id == id } }
    }

    func connectionBlock(localKeyID: UUID, password: String) throws -> String {
        try connectionInfo(localKeyID: localKeyID, password: password).clipboardText
    }

    private func fetchModels(
        provider: ModelRelayProvider,
        references: [ModelRelayUpstreamKeyReference],
        probeCapabilities: Bool
    ) async throws -> FetchedModels {
        var lastError: Error = ModelRelayError.noHealthyUpstream
        var firstSuccessfulCatalog: FetchedModels?
        let cachedCapabilities = Dictionary(
            uniqueKeysWithValues: provider.models.map {
                ($0.upstreamModelID, $0.capability)
            }
        )
        for reference in references {
            var secretDigest: Data?
            do {
                guard let secret = try upstreamKeyStore.load(id: reference.id) else {
                    lastError = ModelRelayError.keyNotFound
                    continue
                }
                secretDigest = ModelRelayLocalKeyVault.digest(secret)
                let discovery = try await upstreamClient.discoverModels(
                    baseURL: provider.baseURL,
                    secret: secret,
                    cachedCapabilities: cachedCapabilities,
                    probeCapabilities: probeCapabilities
                )
                if firstSuccessfulCatalog == nil {
                    firstSuccessfulCatalog = FetchedModels(
                        discovery: discovery,
                        keyID: reference.id,
                        secretDigest: secretDigest!
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let statusCode: Int?
                if case ModelRelayError.upstreamHTTP(let status) = error {
                    statusCode = status
                } else {
                    statusCode = nil
                }
                lastError = ModelFetchFailure(
                    underlying: error,
                    keyID: reference.id,
                    secretDigest: secretDigest,
                    statusCode: statusCode
                )
            }
        }
        if let firstSuccessfulCatalog {
            return firstSuccessfulCatalog
        }
        if let failure = lastError as? ModelFetchFailure {
            throw failure
        }
        let reference = references.first
        throw ModelFetchFailure(
            underlying: lastError,
            keyID: reference?.id ?? UUID(),
            secretDigest: nil,
            statusCode: nil
        )
    }

    private func recordSuccessIfCurrent(
        provider: ModelRelayProvider,
        keyID: UUID,
        secretDigest: Data
    ) {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard currentConnectionMatches(
            providerID: provider.id,
            baseURL: provider.baseURL,
            keyID: keyID,
            secretDigest: secretDigest
        ) else {
            return
        }
        router.recordSuccess(keyID: keyID)
    }

    private func recordFailureIfCurrent(
        provider: ModelRelayProvider,
        failure: ModelFetchFailure
    ) {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        guard currentConnectionMatches(
            providerID: provider.id,
            baseURL: provider.baseURL,
            keyID: failure.keyID,
            secretDigest: failure.secretDigest
        ) else {
            return
        }
        router.recordFailure(keyID: failure.keyID, statusCode: failure.statusCode)
    }

    private func currentConnectionMatches(
        providerID: UUID,
        baseURL: String,
        keyID: UUID,
        secretDigest: Data?
    ) -> Bool {
        let snapshot = configurationSnapshot()
        guard let current = snapshot.providers.first(where: { $0.id == providerID }),
              current.baseURL == baseURL,
              current.upstreamKey?.id == keyID else {
            return false
        }
        do {
            let currentSecret = try upstreamKeyStore.load(id: keyID)
            guard let secretDigest else {
                return currentSecret == nil
            }
            guard let currentSecret else {
                return false
            }
            return ModelRelayLocalKeyVault.constantTimeEqual(
                ModelRelayLocalKeyVault.digest(currentSecret),
                secretDigest
            )
        } catch {
            return secretDigest == nil
        }
    }

    private func normalizedUpstreamSecret(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw else {
            throw ModelRelayError.keyNotFound
        }
        return raw
    }

    private static func unknownCapabilities(
        for modelIDs: [String]
    ) -> [String: ModelRelayModelCapability] {
        Dictionary(
            uniqueKeysWithValues: Set(modelIDs).map {
                ($0, ModelRelayModelCapability.unknown)
            }
        )
    }

    private func ensureUniqueProviderName(
        _ name: String,
        excluding providerID: UUID?,
        configuration: ModelRelayConfiguration
    ) throws {
        guard !configuration.providers.contains(where: {
            $0.id != providerID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw ModelRelayError.duplicateProviderName
        }
    }

    private func mergedModelRoutes(
        providerID: UUID,
        providerName: String,
        modelIDs: [String],
        existing: [ModelRelayModelRoute],
        capabilities: [String: ModelRelayModelCapability] = [:],
        configuration: ModelRelayConfiguration
    ) -> [ModelRelayModelRoute] {
        let existingByID = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.upstreamModelID, $0) }
        )
        var occupied = Set(configuration.providers
            .filter { $0.id != providerID }
            .flatMap(\.models)
            .map { $0.alias.lowercased() })
        var routes: [ModelRelayModelRoute] = []
        for modelID in Array(Set(modelIDs)).sorted() {
            let published = Self.publishedModelID(
                upstreamModelID: modelID,
                providerName: providerName,
                occupied: occupied
            )
            occupied.insert(published.lowercased())
            if let existing = existingByID[modelID] {
                routes.append(ModelRelayModelRoute(
                    id: existing.id,
                    upstreamModelID: modelID,
                    alias: published,
                    capability: capabilities[modelID] ?? existing.capability
                ))
            } else {
                routes.append(ModelRelayModelRoute(
                    upstreamModelID: modelID,
                    alias: published,
                    capability: capabilities[modelID] ?? .unknown
                ))
            }
        }
        return routes
    }

    private func mergeModels(
        provider: ModelRelayProvider,
        modelIDs: [String],
        capabilities: [String: ModelRelayModelCapability] = [:],
        expectedKeyID: UUID? = nil,
        expectedSecretDigest: Data? = nil
    ) throws -> [ModelRelayModelRoute] {
        let uniqueIDs = Array(Set(modelIDs)).sorted()
        guard !uniqueIDs.isEmpty else { throw ModelRelayError.noModels }
        var result: [ModelRelayModelRoute] = []
        try mutateConfiguration { configuration in
            guard let providerIndex = configuration.providers.firstIndex(where: { $0.id == provider.id }),
                  configuration.providers[providerIndex].baseURL == provider.baseURL,
                  configuration.providers[providerIndex].upstreamKey?.id == provider.upstreamKey?.id else {
                throw ModelRelayError.providerNotFound
            }
            if let expectedKeyID, let expectedSecretDigest {
                guard configuration.providers[providerIndex].upstreamKey?.id == expectedKeyID,
                      let currentSecret = try upstreamKeyStore.load(id: expectedKeyID),
                      ModelRelayLocalKeyVault.constantTimeEqual(
                        ModelRelayLocalKeyVault.digest(currentSecret),
                        expectedSecretDigest
                      ) else {
                    throw ModelRelayError.providerNotFound
                }
            }
            let currentName = configuration.providers[providerIndex].name
            let existingForProvider = Dictionary(
                uniqueKeysWithValues: configuration.providers[providerIndex].models
                    .map { ($0.upstreamModelID, $0) }
            )
            var occupied = Set(configuration.providers
                .filter { $0.id != provider.id }
                .flatMap(\.models)
                .map { $0.alias.lowercased() })
            var merged: [ModelRelayModelRoute] = []
            for modelID in uniqueIDs {
                let published = Self.publishedModelID(
                    upstreamModelID: modelID,
                    providerName: currentName,
                    occupied: occupied
                )
                occupied.insert(published.lowercased())
                if let existing = existingForProvider[modelID] {
                    merged.append(ModelRelayModelRoute(
                        id: existing.id,
                        upstreamModelID: modelID,
                        alias: published,
                        capability: capabilities[modelID] ?? existing.capability
                    ))
                } else {
                    merged.append(ModelRelayModelRoute(
                        upstreamModelID: modelID,
                        alias: published,
                        capability: capabilities[modelID] ?? .unknown
                    ))
                }
            }
            configuration.providers[providerIndex].models = merged
            result = merged
        }
        return result.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private func mutateConfiguration(_ body: (inout ModelRelayConfiguration) throws -> Void) throws {
        if let startupError { throw startupError }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        lock.lock()
        do {
            var updated = configuration
            try body(&updated)
            try configStore.save(updated)
            configuration = updated
            lock.unlock()
            router.update(configuration: updated)
            notifyChange()
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func configurationSnapshot() -> ModelRelayConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private func isRunningWanted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return wantsRunning
    }

    private func setRunState(_ state: ModelRelayRunState) {
        lock.lock()
        storedRunState = state
        lock.unlock()
        notifyChange()
    }

    private func startRefreshTimer() {
        lock.lock()
        guard refreshTimer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(300), repeating: .seconds(300))
        timer.setEventHandler { [weak self] in
            self?.refreshAllProviders()
        }
        refreshTimer = timer
        timer.resume()
        lock.unlock()
    }

    private func refreshAllProviders() {
        cleanupPendingUpstreamKeys()
        for provider in configurationSnapshot().providers where !provider.keys.isEmpty {
            fetchModels(
                providerID: provider.id,
                resetAuthenticationFailures: false,
                probeCapabilities: false
            ) { _ in }
        }
    }

    private func validateUpstreamKeyInput(
        providerID: UUID,
        keyID: UUID?,
        name: String,
        secret: String
    ) throws -> String {
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              secret == secret.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ModelRelayError.keyNotFound
        }
        guard let provider = configurationSnapshot().providers.first(where: { $0.id == providerID }) else {
            throw ModelRelayError.providerNotFound
        }
        guard keyID == nil || provider.keys.contains(where: { $0.id == keyID }) else {
            throw ModelRelayError.keyNotFound
        }
        guard !provider.keys.contains(where: {
            $0.id != keyID && $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ModelRelayError.duplicateKeyName
        }
        return normalizedName
    }

    private func performPersistenceRollback(
        _ message: String,
        actions: [() throws -> Void]
    ) throws {
        var failed = false
        for action in actions {
            do {
                try action()
            } catch {
                failed = true
            }
        }
        if failed {
            throw ModelRelayError.persistenceRollback(message)
        }
    }

    private func withPersistenceTransaction<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        return try body()
    }

    private func stageUpstreamKeyForDeletion(_ id: UUID) throws {
        try mutateConfiguration { configuration in
            guard !configuration.providers.flatMap(\.keys).contains(where: { $0.id == id }) else {
                throw ModelRelayError.configurationCorrupt
            }
            if !configuration.pendingUpstreamKeyDeletions.contains(id) {
                configuration.pendingUpstreamKeyDeletions.append(id)
            }
        }
    }

    private func discardStagedUpstreamKey(
        _ id: UUID,
        rollbackMessage: String
    ) throws {
        do {
            try upstreamKeyStore.delete(id: id)
        } catch {
            throw ModelRelayError.persistenceRollback(rollbackMessage)
        }
        do {
            try mutateConfiguration {
                $0.pendingUpstreamKeyDeletions.removeAll { $0 == id }
            }
        } catch {
            throw ModelRelayError.persistenceRollback(rollbackMessage)
        }
    }

    @discardableResult
    private func cleanupPendingUpstreamKeys() -> Bool {
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let snapshot = configurationSnapshot()
        let active = Set(snapshot.providers.flatMap(\.keys).map(\.id))
        var cleanedAll = true
        for id in snapshot.pendingUpstreamKeyDeletions {
            guard !active.contains(id) else {
                cleanedAll = false
                continue
            }
            do {
                try upstreamKeyStore.delete(id: id)
                try mutateConfiguration {
                    $0.pendingUpstreamKeyDeletions.removeAll { $0 == id }
                }
            } catch {
                cleanedAll = false
            }
        }
        return cleanedAll
    }

    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.didChange?()
        }
    }

    private func completeOnMain<T>(
        _ completion: @escaping (Result<T, Error>) -> Void,
        result: Result<T, Error>
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func restoreListener(
        port: UInt16,
        originalError: Error,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        server.stop()
        do {
            try server.start(port: port) { [weak self] result in
                guard let self else { return }
                if case .success = result, self.isRunningWanted() {
                    self.startRefreshTimer()
                    self.refreshAllProviders()
                }
                self.completeOnMain(completion, result: .failure(originalError))
            }
        } catch {
            setRunState(.failed(error.localizedDescription))
            completeOnMain(completion, result: .failure(originalError))
        }
    }
}

private final class ModelRelayServiceReadiness {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

@MainActor
extension ModelRelayService: TocodeModelRelayCommanding {
    func updatePort(_ value: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            updatePort(value) { result in
                continuation.resume(with: result)
            }
        }
    }
}
