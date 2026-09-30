import Foundation

struct ModelRelayUpstreamCandidate: Equatable {
    let providerID: UUID
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
    private var configuration: ModelRelayConfiguration
    private var health: [UUID: KeyHealth] = [:]
    private var cursors: [UUID: Int] = [:]

    init(
        configuration: ModelRelayConfiguration,
        keyStore: ModelRelayUpstreamKeyStoring,
        vault: ModelRelayLocalKeyVault,
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.keyStore = keyStore
        self.vault = vault
        self.now = now
    }

    func update(configuration: ModelRelayConfiguration) {
        lock.lock()
        self.configuration = configuration
        let validKeyIDs = Set(configuration.providers.flatMap(\.keys).map(\.id))
        health = health.filter { validKeyIDs.contains($0.key) }
        cursors = cursors.filter { providerID, _ in
            configuration.providers.contains(where: { $0.id == providerID })
        }
        lock.unlock()
    }

    func authenticate(_ secret: String) -> Bool {
        lock.lock()
        let records = configuration.localKeys
        lock.unlock()
        return vault.authenticates(secret, records: records)
    }

    func availableAliases() -> [String] {
        lock.lock()
        let date = now()
        let providers = configuration.providers
        let healthSnapshot = health
        lock.unlock()
        let aliases = providers.flatMap { provider -> [String] in
            let hasAvailableKey = provider.keys.contains { reference in
                guard healthSnapshot[reference.id, default: KeyHealth()].isAvailable(at: date) else {
                    return false
                }
                do {
                    return try keyStore.load(id: reference.id) != nil
                } catch {
                    return false
                }
            }
            return hasAvailableKey ? provider.models.map(\.alias) : []
        }
        return aliases.sorted()
    }

    func resolve(alias: String) throws -> ModelRelayResolvedRoute {
        lock.lock()
        guard let provider = configuration.providers.first(where: {
            $0.models.contains(where: { $0.alias == alias })
        }), let model = provider.models.first(where: { $0.alias == alias }) else {
            lock.unlock()
            throw ModelRelayError.modelNotFound
        }
        let date = now()
        let available = provider.keys.filter {
            health[$0.id, default: KeyHealth()].isAvailable(at: date)
        }
        let start = available.isEmpty ? 0 : (cursors[provider.id, default: 0] % available.count)
        if !available.isEmpty {
            cursors[provider.id] = (start + 1) % available.count
        }
        let ordered = available.isEmpty
            ? []
            : Array(available[start...]) + Array(available[..<start])
        lock.unlock()

        var candidates: [ModelRelayUpstreamCandidate] = []
        for reference in ordered {
            guard let secret = try keyStore.load(id: reference.id) else {
                recordFailure(keyID: reference.id, statusCode: nil)
                continue
            }
            candidates.append(ModelRelayUpstreamCandidate(
                providerID: provider.id,
                keyID: reference.id,
                baseURL: provider.baseURL,
                upstreamModelID: model.upstreamModelID,
                secret: secret
            ))
        }
        guard !candidates.isEmpty else {
            throw ModelRelayError.noHealthyUpstream
        }
        return ModelRelayResolvedRoute(alias: alias, candidates: candidates)
    }

    func recordSuccess(keyID: UUID) {
        lock.lock()
        health[keyID] = KeyHealth()
        lock.unlock()
    }

    func recordFailure(keyID: UUID, statusCode: Int?) {
        lock.lock()
        var state = health[keyID, default: KeyHealth()]
        switch statusCode {
        case 401?, 403?:
            state.authenticationFailed = true
            state.unavailableUntil = nil
        case 429?:
            state.unavailableUntil = now().addingTimeInterval(60)
        case let code? where (500...599).contains(code):
            state.unavailableUntil = now().addingTimeInterval(30)
        default:
            state.unavailableUntil = now().addingTimeInterval(30)
        }
        health[keyID] = state
        lock.unlock()
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
