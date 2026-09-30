import Foundation

final class ModelRelayService {
    private let configStore: ModelRelayConfigStoring
    private let upstreamKeyStore: ModelRelayUpstreamKeyStoring
    private let localKeyVault: ModelRelayLocalKeyVault
    private let upstreamClient: ModelRelayUpstreamClient
    private let lock = NSLock()
    private var configuration: ModelRelayConfiguration
    private let startupError: Error?
    private var refreshTimer: DispatchSourceTimer?
    private var storedRunState: ModelRelayRunState = .stopped
    private var wantsRunning = false
    let router: ModelRelayRouter
    let server: ModelRelayHTTPServer

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
        upstreamClient: ModelRelayUpstreamClient = ModelRelayUpstreamClient()
    ) {
        self.configStore = configStore
        self.upstreamKeyStore = upstreamKeyStore
        self.localKeyVault = localKeyVault
        self.upstreamClient = upstreamClient
        let loaded: ModelRelayConfiguration
        do {
            loaded = try configStore.load()
            startupError = nil
        } catch {
            loaded = ModelRelayConfiguration()
            startupError = error
            storedRunState = .failed(error.localizedDescription)
        }
        configuration = loaded
        router = ModelRelayRouter(configuration: loaded, keyStore: upstreamKeyStore, vault: localKeyVault)
        server = ModelRelayHTTPServer(router: router, upstream: upstreamClient)
        server.stateDidChange = { [weak self] state in
            self?.setRunState(state)
        }
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
    func addProvider(name: String, baseURL: String) throws -> ModelRelayProvider {
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        let normalizedURL = try ModelRelayValidation.normalizedBaseURL(baseURL)
        var provider = ModelRelayProvider(name: normalizedName, baseURL: normalizedURL)
        try mutateConfiguration { configuration in
            guard !configuration.providers.contains(where: {
                $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
            }) else {
                throw ModelRelayError.duplicateProviderName
            }
            configuration.providers.append(provider)
            provider = configuration.providers.last!
        }
        return provider
    }

    func updateProvider(id: UUID, name: String, baseURL: String) throws {
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        let normalizedURL = try ModelRelayValidation.normalizedBaseURL(baseURL)
        var resetKeyIDs: [UUID] = []
        try mutateConfiguration { configuration in
            guard let index = configuration.providers.firstIndex(where: { $0.id == id }) else {
                throw ModelRelayError.providerNotFound
            }
            guard !configuration.providers.contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
            }) else {
                throw ModelRelayError.duplicateProviderName
            }
            if configuration.providers[index].baseURL != normalizedURL {
                configuration.providers[index].models.removeAll()
                resetKeyIDs = configuration.providers[index].keys.map(\.id)
            }
            configuration.providers[index].name = normalizedName
            configuration.providers[index].baseURL = normalizedURL
        }
        router.resetHealth(keyIDs: resetKeyIDs)
    }

    func deleteProvider(id: UUID) throws {
        let keyIDs = configurationSnapshot().providers
            .first(where: { $0.id == id })?.keys.map(\.id)
        guard let keyIDs else { throw ModelRelayError.providerNotFound }
        var existingSecrets: [UUID: String] = [:]
        for keyID in keyIDs {
            if let secret = try upstreamKeyStore.load(id: keyID) {
                existingSecrets[keyID] = secret
            }
        }
        var deleted: [UUID] = []
        do {
            for keyID in keyIDs {
                try upstreamKeyStore.delete(id: keyID)
                deleted.append(keyID)
            }
            try mutateConfiguration { configuration in
                configuration.providers.removeAll { $0.id == id }
            }
        } catch {
            for keyID in deleted {
                if let secret = existingSecrets[keyID] {
                    try? upstreamKeyStore.save(secret, id: keyID)
                }
            }
            throw error
        }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let modelIDs = try await self.upstreamClient.fetchModels(
                    baseURL: provider.baseURL,
                    secret: secret
                )
                let reference = try self.storeUpstreamKey(
                    providerID: providerID,
                    name: normalizedName,
                    secret: secret
                )
                do {
                    _ = try self.mergeModels(provider: provider, modelIDs: modelIDs)
                    self.router.recordSuccess(keyID: reference.id)
                    self.completeOnMain(completion, result: .success(reference))
                } catch {
                    try? self.deleteUpstreamKey(providerID: providerID, keyID: reference.id)
                    throw error
                }
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    private func storeUpstreamKey(providerID: UUID, name: String, secret: String) throws -> ModelRelayUpstreamKeyReference {
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelRelayError.keyNotFound
        }
        let reference = ModelRelayUpstreamKeyReference(name: normalizedName)
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            throw ModelRelayError.providerNotFound
        }
        guard !provider.keys.contains(where: {
            $0.name.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) else {
            throw ModelRelayError.duplicateKeyName
        }
        try upstreamKeyStore.save(secret, id: reference.id)
        do {
            try mutateConfiguration { configuration in
                guard let index = configuration.providers.firstIndex(where: { $0.id == providerID }) else {
                    throw ModelRelayError.providerNotFound
                }
                configuration.providers[index].keys.append(reference)
            }
        } catch {
            try? upstreamKeyStore.delete(id: reference.id)
            throw error
        }
        router.resetHealth(keyIDs: [reference.id])
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
        let loadedPreviousSecret: String?
        do {
            loadedPreviousSecret = try upstreamKeyStore.load(id: keyID)
        } catch {
            completeOnMain(completion, result: .failure(error))
            return
        }
        guard let previousReference = provider.keys.first(where: { $0.id == keyID }),
              let previousSecret = loadedPreviousSecret else {
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
                try self.storeReplacement(
                    providerID: providerID,
                    keyID: keyID,
                    name: normalizedName,
                    secret: secret
                )
                do {
                    _ = try self.mergeModels(provider: provider, modelIDs: modelIDs)
                } catch {
                    try? self.storeReplacement(
                        providerID: providerID,
                        keyID: keyID,
                        name: previousReference.name,
                        secret: previousSecret
                    )
                    throw error
                }
                self.router.recordSuccess(keyID: keyID)
                self.completeOnMain(completion, result: .success(()))
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    private func storeReplacement(providerID: UUID, keyID: UUID, name: String, secret: String) throws {
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelRelayError.keyNotFound
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
        let previousSecret = try upstreamKeyStore.load(id: keyID)
        try upstreamKeyStore.save(secret, id: keyID)
        do {
            try mutateConfiguration { configuration in
                guard let providerIndex = configuration.providers.firstIndex(where: { $0.id == providerID }),
                      let keyIndex = configuration.providers[providerIndex].keys.firstIndex(where: { $0.id == keyID }) else {
                    throw ModelRelayError.keyNotFound
                }
                configuration.providers[providerIndex].keys[keyIndex].name = normalizedName
            }
        } catch {
            if let previousSecret {
                try? upstreamKeyStore.save(previousSecret, id: keyID)
            } else {
                try? upstreamKeyStore.delete(id: keyID)
            }
            throw error
        }
        router.resetHealth(keyIDs: [keyID])
    }

    func deleteUpstreamKey(providerID: UUID, keyID: UUID) throws {
        let previousSecret = try upstreamKeyStore.load(id: keyID)
        try upstreamKeyStore.delete(id: keyID)
        do {
            try mutateConfiguration { configuration in
                guard let providerIndex = configuration.providers.firstIndex(where: { $0.id == providerID }) else {
                    throw ModelRelayError.providerNotFound
                }
                guard configuration.providers[providerIndex].keys.contains(where: { $0.id == keyID }) else {
                    throw ModelRelayError.keyNotFound
                }
                configuration.providers[providerIndex].keys.removeAll { $0.id == keyID }
            }
        } catch {
            if let previousSecret {
                try? upstreamKeyStore.save(previousSecret, id: keyID)
            }
            throw error
        }
        router.resetHealth(keyIDs: [keyID])
    }

    func fetchModels(
        providerID: UUID,
        resetAuthenticationFailures: Bool = true,
        completion: @escaping (Result<[ModelRelayModelRoute], Error>) -> Void
    ) {
        let snapshot = configurationSnapshot()
        guard let provider = snapshot.providers.first(where: { $0.id == providerID }) else {
            completeOnMain(completion, result: .failure(ModelRelayError.providerNotFound))
            return
        }
        let references: [ModelRelayUpstreamKeyReference]
        if resetAuthenticationFailures {
            router.resetHealth(keyIDs: provider.keys.map(\.id))
            references = provider.keys
        } else {
            let eligible = Set(router.keyIDsEligibleForAutomaticRefresh(provider.keys.map(\.id)))
            references = provider.keys.filter { eligible.contains($0.id) }
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let modelIDs = try await self.fetchModels(
                    provider: provider,
                    references: references
                )
                do {
                    let routes = try self.mergeModels(provider: provider, modelIDs: modelIDs)
                    self.completeOnMain(completion, result: .success(routes))
                } catch {
                    self.completeOnMain(completion, result: .failure(error))
                }
            } catch {
                self.completeOnMain(completion, result: .failure(error))
            }
        }
    }

    func updateAlias(routeID: UUID, alias: String) throws {
        let normalizedAlias = try ModelRelayValidation.normalizedName(alias)
        try mutateConfiguration { configuration in
            guard let providerIndex = configuration.providers.firstIndex(where: {
                $0.models.contains(where: { $0.id == routeID })
            }), let modelIndex = configuration.providers[providerIndex].models.firstIndex(where: {
                $0.id == routeID
            }) else {
                throw ModelRelayError.modelNotFound
            }
            guard !configuration.providers.flatMap(\.models).contains(where: {
                $0.id != routeID && $0.alias.caseInsensitiveCompare(normalizedAlias) == .orderedSame
            }) else {
                throw ModelRelayError.duplicateAlias
            }
            configuration.providers[providerIndex].models[modelIndex].alias = normalizedAlias
        }
    }

    @discardableResult
    func createLocalKey(name: String, password: String) throws -> ModelRelayLocalKeyRecord {
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
        references: [ModelRelayUpstreamKeyReference]
    ) async throws -> [String] {
        var lastError: Error = ModelRelayError.noHealthyUpstream
        var firstSuccessfulCatalog: [String]?
        for reference in references {
            do {
                guard let secret = try upstreamKeyStore.load(id: reference.id) else {
                    router.recordFailure(keyID: reference.id, statusCode: nil)
                    lastError = ModelRelayError.keyNotFound
                    continue
                }
                let models = try await upstreamClient.fetchModels(
                    baseURL: provider.baseURL,
                    secret: secret
                )
                router.recordSuccess(keyID: reference.id)
                if firstSuccessfulCatalog == nil {
                    firstSuccessfulCatalog = models
                }
            } catch {
                let statusCode: Int?
                if case ModelRelayError.upstreamHTTP(let status) = error {
                    statusCode = status
                } else {
                    statusCode = nil
                }
                router.recordFailure(keyID: reference.id, statusCode: statusCode)
                lastError = error
            }
        }
        if let firstSuccessfulCatalog {
            return firstSuccessfulCatalog
        }
        throw lastError
    }

    private func mergeModels(provider: ModelRelayProvider, modelIDs: [String]) throws -> [ModelRelayModelRoute] {
        let uniqueIDs = Array(Set(modelIDs)).sorted()
        guard !uniqueIDs.isEmpty else { throw ModelRelayError.noModels }
        var result: [ModelRelayModelRoute] = []
        try mutateConfiguration { configuration in
            guard let providerIndex = configuration.providers.firstIndex(where: { $0.id == provider.id }),
                  configuration.providers[providerIndex].baseURL == provider.baseURL else {
                throw ModelRelayError.providerNotFound
            }
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
                if var existing = existingForProvider[modelID] {
                    if occupied.contains(existing.alias.lowercased()) {
                        existing.alias = uniqueAlias(
                            preferred: "\(provider.name)/\(modelID)",
                            occupied: occupied
                        )
                    }
                    occupied.insert(existing.alias.lowercased())
                    merged.append(existing)
                } else {
                    let alias = uniqueAlias(
                        preferred: occupied.contains(modelID.lowercased())
                            ? "\(provider.name)/\(modelID)"
                            : modelID,
                        occupied: occupied
                    )
                    occupied.insert(alias.lowercased())
                    merged.append(ModelRelayModelRoute(
                        upstreamModelID: modelID,
                        alias: alias
                    ))
                }
            }
            configuration.providers[providerIndex].models = merged
            result = merged
        }
        return result.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private func uniqueAlias(preferred: String, occupied: Set<String>) -> String {
        if !occupied.contains(preferred.lowercased()) { return preferred }
        var suffix = 2
        while occupied.contains("\(preferred)-\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(preferred)-\(suffix)"
    }

    private func mutateConfiguration(_ body: (inout ModelRelayConfiguration) throws -> Void) throws {
        if let startupError { throw startupError }
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
        for provider in configurationSnapshot().providers where !provider.keys.isEmpty {
            fetchModels(providerID: provider.id, resetAuthenticationFailures: false) { _ in }
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
