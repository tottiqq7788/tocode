import Foundation

struct ModelRelayUpstreamCandidate: Equatable {
    let providerID: UUID
    let providerName: String
    let keyID: UUID
    let baseURL: String
    let upstreamModelID: String
    let secret: String
}

struct ModelRelayResolvedRoute: Equatable {
    let alias: String
    let candidates: [ModelRelayUpstreamCandidate]
}

final class ModelRelayRouter: @unchecked Sendable {
    private struct KeyHealth {
        var authenticationFailed = false
        var unavailableUntil: Date?

        func isAvailable(at date: Date) -> Bool {
            !authenticationFailed && (unavailableUntil == nil || unavailableUntil! <= date)
        }
    }

    private let lock = NSLock()
    private let keyStore: ModelRelayUpstreamKeyStoring
    private let vault: ModelRelayLocalKeyVault
    private let now: () -> Date
    private let internalCredentialDigest: Data?
    private var configuration: ModelRelayConfiguration
    private var health: [UUID: KeyHealth] = [:]
    private var availabilityChangeHandler: (() -> Void)?

    init(
        configuration: ModelRelayConfiguration,
        keyStore: ModelRelayUpstreamKeyStoring,
        vault: ModelRelayLocalKeyVault,
        internalCredentialDigest: Data? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.keyStore = keyStore
        self.vault = vault
        self.internalCredentialDigest = internalCredentialDigest
        self.now = now
    }

    var availabilityDidChange: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return availabilityChangeHandler
        }
        set {
            lock.lock()
            availabilityChangeHandler = newValue
            lock.unlock()
        }
    }

    func update(configuration: ModelRelayConfiguration) {
        lock.lock()
        self.configuration = configuration
        let validKeyIDs = Set(configuration.providers.flatMap(\.keys).map(\.id))
        health = health.filter { validKeyIDs.contains($0.key) }
        lock.unlock()
    }

    func authenticate(_ secret: String) -> Bool {
        lock.lock()
        let records = configuration.localKeys
        lock.unlock()
        let localMatch = vault.authenticates(secret, records: records)
        let candidate = ModelRelayLocalKeyVault.digest(secret)
        let internalMatch = internalCredentialDigest.map {
            ModelRelayLocalKeyVault.constantTimeEqual(candidate, $0)
        } ?? false
        return localMatch || internalMatch
    }

    func availableAliases() -> [String] {
        lock.lock()
        let date = now()
        let providers = configuration.providers
        let healthSnapshot = health
        lock.unlock()
        let aliases = providers.flatMap { provider -> [String] in
            guard let reference = provider.upstreamKey,
                  healthSnapshot[reference.id, default: KeyHealth()].isAvailable(at: date) else {
                return []
            }
            let hasAvailableKey: Bool
            do {
                hasAvailableKey = try keyStore.load(id: reference.id) != nil
            } catch {
                hasAvailableKey = false
            }
            return hasAvailableKey ? provider.models.map(\.alias) : []
        }
        return aliases.sorted()
    }

    /// 仅用于观察 Relay 路由边界变化，不触碰可能要求用户授权的钥匙串。
    func togentModelIDsForHealthObservation() -> [String] {
        lock.lock()
        let date = now()
        let providers = configuration.providers
        let healthSnapshot = health
        lock.unlock()

        return providers.flatMap { provider -> [String] in
            guard let reference = provider.upstreamKey,
                  healthSnapshot[reference.id, default: KeyHealth()].isAvailable(at: date) else {
                return []
            }
            return provider.models.map(\.alias)
        }.sorted()
    }

    /// 运行时指纹包含图片输入能力；能力变化必须淘汰旧 Pi 与旧 models.json。
    func togentModelFingerprintsForHealthObservation() -> [String] {
        lock.lock()
        let date = now()
        let providers = configuration.providers
        let healthSnapshot = health
        lock.unlock()

        return providers.flatMap { provider -> [String] in
            guard let reference = provider.upstreamKey,
                  healthSnapshot[reference.id, default: KeyHealth()].isAvailable(at: date) else {
                return []
            }
            return provider.models.map {
                "\($0.alias)|\($0.capability.effectiveImageInput.rawValue)"
            }
        }.sorted()
    }

    func availableTogentModels() -> [TogentModelOption] {
        lock.lock()
        let date = now()
        let providers = configuration.providers
        let healthSnapshot = health
        lock.unlock()

        return providers.flatMap { provider -> [TogentModelOption] in
            guard let reference = provider.upstreamKey,
                  healthSnapshot[reference.id, default: KeyHealth()].isAvailable(at: date),
                  (try? keyStore.load(id: reference.id)) != nil else {
                return []
            }
            return provider.models.map {
                TogentModelOption(
                    publishedModelID: $0.alias,
                    providerName: provider.name,
                    imageInput: TogentImageInputCapability(
                        rawValue: $0.capability.effectiveImageInput.rawValue
                    ) ?? .unknown
                )
            }
        }.sorted {
            if $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedSame {
                return $0.publishedModelID.localizedCaseInsensitiveCompare(
                    $1.publishedModelID
                ) == .orderedAscending
            }
            return $0.providerName.localizedCaseInsensitiveCompare(
                $1.providerName
            ) == .orderedAscending
        }
    }

    func resolve(alias: String) throws -> ModelRelayResolvedRoute {
        lock.lock()
        guard let provider = configuration.providers.first(where: {
            $0.models.contains(where: { $0.alias == alias })
        }), let model = provider.models.first(where: { $0.alias == alias }) else {
            lock.unlock()
            throw ModelRelayError.modelNotFound
        }
        let reference = provider.upstreamKey
        let isAvailable = reference.map {
            health[$0.id, default: KeyHealth()].isAvailable(at: now())
        } ?? false
        lock.unlock()

        guard let reference, isAvailable else {
            throw ModelRelayError.noHealthyUpstream
        }
        guard let secret = try keyStore.load(id: reference.id) else {
            recordFailure(keyID: reference.id, statusCode: nil)
            throw ModelRelayError.noHealthyUpstream
        }
        return ModelRelayResolvedRoute(alias: alias, candidates: [
            ModelRelayUpstreamCandidate(
                providerID: provider.id,
                providerName: provider.name,
                keyID: reference.id,
                baseURL: provider.baseURL,
                upstreamModelID: model.upstreamModelID,
                secret: secret
            )
        ])
    }

    func recordSuccess(keyID: UUID) {
        lock.lock()
        let wasAvailable = health[keyID, default: KeyHealth()].isAvailable(at: now())
        health[keyID] = KeyHealth()
        let callback = wasAvailable ? nil : availabilityChangeHandler
        lock.unlock()
        callback?()
    }

    func recordFailure(keyID: UUID, statusCode: Int?) {
        lock.lock()
        let date = now()
        var state = health[keyID, default: KeyHealth()]
        let wasAvailable = state.isAvailable(at: date)
        switch statusCode {
        case 401?, 403?:
            state.authenticationFailed = true
            state.unavailableUntil = nil
        case 429?:
            state.unavailableUntil = date.addingTimeInterval(60)
        case let code? where (500...599).contains(code):
            state.unavailableUntil = date.addingTimeInterval(30)
        default:
            state.unavailableUntil = date.addingTimeInterval(30)
        }
        health[keyID] = state
        let callback = wasAvailable == state.isAvailable(at: date)
            ? nil
            : availabilityChangeHandler
        lock.unlock()
        callback?()
    }

    func resetHealth(keyIDs: [UUID]? = nil) {
        lock.lock()
        if let keyIDs {
            for keyID in keyIDs {
                health[keyID] = KeyHealth()
            }
        } else {
            health.removeAll()
        }
        lock.unlock()
    }

    func keyIDsEligibleForAutomaticRefresh(_ keyIDs: [UUID]) -> [UUID] {
        lock.lock()
        let eligible = keyIDs.filter {
            !health[$0, default: KeyHealth()].authenticationFailed
        }
        lock.unlock()
        return eligible
    }
}
