import Foundation

struct PhoneHermesSnapshot: Equatable {
    var installed: Bool
    var running: Bool
}

struct PhoneHermesSession: Equatable {
    var id: String
    var title: String
}

struct PhoneHermesTurn: Equatable {
    var role: String
    var text: String
}

protocol PhoneHermesRuntime: AnyObject {
    func snapshot() async -> PhoneHermesSnapshot
    func listSessions() async throws -> [PhoneHermesSession]
    func listSessions(profile: String) async throws -> [PhoneHermesSession]
    func createSession(title: String) async throws -> PhoneHermesSession
    func createSession(title: String, profile: String) async throws -> PhoneHermesSession
    func session(sessionID: String, profile: String) async throws -> PhoneHermesSession
    func deleteSession(sessionID: String, profile: String) async throws
    func renameSession(sessionID: String, title: String, profile: String) async throws -> String
    func messages(sessionID: String) async throws -> [PhoneHermesTurn]
    func messages(sessionID: String, profile: String) async throws -> [PhoneHermesTurn]
    func chat(sessionID: String, text: String, directory: String) async throws -> String
    func chat(sessionID: String, text: String, directory: String, profile: String) async throws -> String
}

extension PhoneHermesRuntime {
    func listSessions(profile: String) async throws -> [PhoneHermesSession] {
        try await listSessions()
    }

    func createSession(title: String, profile: String) async throws -> PhoneHermesSession {
        try await createSession(title: title)
    }

    func session(sessionID: String, profile: String) async throws -> PhoneHermesSession {
        throw URLError(.unsupportedURL)
    }

    func deleteSession(sessionID: String, profile: String) async throws {
        throw URLError(.unsupportedURL)
    }

    func renameSession(sessionID: String, title: String, profile: String) async throws -> String {
        throw URLError(.unsupportedURL)
    }

    func messages(sessionID: String, profile: String) async throws -> [PhoneHermesTurn] {
        try await messages(sessionID: sessionID)
    }

    func chat(sessionID: String, text: String, directory: String, profile: String) async throws -> String {
        try await chat(sessionID: sessionID, text: text, directory: directory)
    }
}

struct PhoneHermesAppReply {
    var ok: Bool
    var text: String
    var body: [String: Any]

    static func failure(_ text: String) -> PhoneHermesAppReply {
        PhoneHermesAppReply(ok: false, text: text, body: [:])
    }

    static func success(_ text: String, body: [String: Any] = [:]) -> PhoneHermesAppReply {
        PhoneHermesAppReply(ok: true, text: text, body: body)
    }
}

enum PhoneHermesEnvironment {
    static func apiKey(from envText: String) -> String {
        value(named: "API_SERVER_KEY", in: envText)
    }

    static func port(from envText: String) -> Int {
        let raw = value(named: "API_SERVER_PORT", in: envText)
        return Int(raw) ?? 8642
    }

    static func value(named name: String, in envText: String) -> String {
        for line in envText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let prefix = name + "="
            guard trimmed.hasPrefix(prefix) else { continue }
            var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return ""
    }
}

enum PhoneHermesDirectory {
    static let maxEntries = 300
    static let maxDepth = 4

    static func list(root: String, includeHidden: Bool, fileManager: FileManager = .default) -> PhoneHermesAppReply {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return .failure(PhoneHermesApp.missingProjectFolder)
        }
        let fileSystem = FileSystemService(fm: fileManager)
        let rootReal = canonical(root)
        var entries: [[String: String]] = []
        var truncated = false
        func visit(_ path: String, depth: Int) {
            guard depth <= maxDepth, !truncated else {
                truncated = true
                return
            }
            let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                if entries.count >= maxEntries {
                    truncated = true
                    return
                }
                let child = (path as NSString).appendingPathComponent(name)
                if !includeHidden && fileSystem.isHiddenEntry(name: name, path: child) { continue }
                let real = canonical(child)
                guard real == rootReal || real.hasPrefix(rootReal + "/") else { continue }
                var childIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: real, isDirectory: &childIsDir) else { continue }
                let relative = String(real.dropFirst(rootReal.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relative.isEmpty else { continue }
                let kind = childIsDir.boolValue ? "directory" : "file"
                entries.append(["path": relative, "name": name, "kind": kind])
                if childIsDir.boolValue {
                    visit(real, depth: depth + 1)
                }
            }
        }
        visit(rootReal, depth: 1)
        return .success(truncated ? "只显示了前 \(maxEntries) 项" : "", body: ["entries": entries])
    }

    static let maxPreviewCharacters = 60_000

    /// 只读打开项目目录里的一个文本文件。路径相对项目根目录，解析后必须仍在里面。
    static func preview(root: String, relative: String, fileManager: FileManager = .default) -> PhoneHermesAppReply {
        let rootReal = canonical(root)
        guard let file = fileInside(root: rootReal, relative: relative) else {
            return .failure("这个文件不在项目里")
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: file, isDirectory: &isDir) else {
            return .failure("文件不存在")
        }
        guard !isDir.boolValue else { return .failure("这是文件夹") }
        guard let handle = FileHandle(forReadingAtPath: file) else { return .failure("这个文件不能预览") }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxPreviewCharacters + 1)
        guard looksLikeText(data) else { return .failure("这个文件不能预览") }
        let truncated = data.count > maxPreviewCharacters
        var slice = truncated ? data.prefix(maxPreviewCharacters) : data.prefix(data.count)
        var text = String(data: slice, encoding: .utf8)
        while text == nil && !slice.isEmpty {
            slice = slice.dropLast()
            text = String(data: slice, encoding: .utf8)
        }
        guard let text else { return .failure("这个文件不能预览") }
        let name = (file as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let format = ["md", "markdown", "mdown"].contains(ext) ? "markdown" : "text"
        let shown = String(file.dropFirst(rootReal.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return .success(truncated ? "只显示了前面一段" : "", body: [
            "name": name,
            "path": shown,
            "format": format,
            "content": text,
            "truncated": truncated
        ])
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        if data.contains(0) { return false }
        let sample = data.prefix(8_192)
        if sample.isEmpty { return true }
        var controls = 0
        for byte in sample where byte < 9 || (byte > 13 && byte < 32) {
            controls += 1
        }
        return controls * 20 <= sample.count
    }

    private static func fileInside(root: String, relative: String) -> String? {
        guard !relative.isEmpty, relative.count <= 1024, !relative.hasPrefix("/") else { return nil }
        guard relative.unicodeScalars.allSatisfy({ !$0.isASCII || $0.value >= 32 }) else { return nil }
        let segments = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let joined = segments.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
        let real = canonical(joined)
        guard real.hasPrefix(root + "/") else { return nil }
        return real
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}

/// 手机发起、还没结束的 Hermes 回合。退出对话页也不会清掉，会话列表和再次进入都靠它。
final class PhoneHermesActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<String> = []

    func mark(profile: String, sessionID: String) {
        lock.lock()
        running.insert(Self.key(profile, sessionID))
        lock.unlock()
    }

    func clear(profile: String, sessionID: String) {
        lock.lock()
        running.remove(Self.key(profile, sessionID))
        lock.unlock()
    }

    func contains(profile: String, sessionID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.contains(Self.key(profile, sessionID))
    }

    private static func key(_ profile: String, _ sessionID: String) -> String {
        "\(profile)\n\(sessionID)"
    }
}

enum PhoneHermesApp {
    static let missingHermes = "这台电脑没有 Hermes"
    static let hermesClosed = "这台电脑的 Hermes 没开"
    static let needProject = "先进入一个项目"
    static let missingProject = "项目不存在"
    static let missingProjectFolder = "项目目录不存在"

    static func instructions(for directory: String) -> String {
        "工作目录是 \(directory)。请在这个目录里完成请求。"
    }

    static func handle(
        kind: String,
        sessionID: String,
        title: String,
        text: String,
        runtime: PhoneHermesRuntime,
        profile: String = "",
        projectID: String = "",
        path: String = "",
        home: String = NSHomeDirectory(),
        includeHidden: Bool = false,
        profileStore: PhoneHermesProfileStore = PhoneHermesProfileStore(
            defaults: UserDefaults(suiteName: "tocode.phoneHermes.ephemeral.\(UUID().uuidString)")!
        ),
        sessionIndex: PhoneHermesSessionIndex = PhoneHermesSessionIndex(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("tocode-phone-hermes-unused-\(UUID().uuidString).json")
        ),
        catalog: [String] = ["default"],
        activity: PhoneHermesActivity = PhoneHermesActivity(),
        projectsDatabase: (String) -> String = { _ in "" },
        isDirectory: @escaping (String) -> Bool = { _ in false },
        ensureProfileEnv: (String) throws -> Void = { _ in }
    ) async -> PhoneHermesAppReply {
        let names = catalog.isEmpty ? ["default"] : catalog
        let active = HermesProfileCatalog.accepted(
            profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? profileStore.resolved(among: names) : profile,
            among: names
        )
        let snapshot = await runtime.snapshot()
        switch kind {
        case "status":
            if snapshot.installed, profileStore.resolved(among: names) != active {
                profileStore.save(active)
            }
            return .success("", body: statusBody(
                snapshot: snapshot,
                profile: snapshot.installed ? active : "default",
                names: snapshot.installed ? names : []
            ))
        case "tree":
            guard snapshot.installed else { return .failure(missingHermes) }
            guard let project = ownedProject(projectID, profile: active, database: projectsDatabase) else {
                return .failure(needProject)
            }
            return PhoneHermesDirectory.list(root: project.rootPath, includeHidden: includeHidden)
        case "preview":
            guard snapshot.installed else { return .failure(missingHermes) }
            guard let project = ownedProject(projectID, profile: active, database: projectsDatabase) else {
                return .failure(needProject)
            }
            return PhoneHermesDirectory.preview(root: project.rootPath, relative: path)
        case "folders":
            guard snapshot.installed else { return .failure(missingHermes) }
            return PhoneHermesHomeFolder.folders(under: path, home: home, includeHidden: includeHidden)
        case "profiles":
            guard snapshot.installed else { return .failure(missingHermes) }
            return .success("", body: ["profile": active, "profiles": names])
        case "profile_select":
            guard snapshot.installed else { return .failure(missingHermes) }
            let requested = profile.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = HermesProfileCatalog.accepted(requested, among: names)
            let known = requested.isEmpty || names.contains(requested)
            guard known, chosen == (requested.isEmpty ? "default" : requested) else {
                profileStore.save("default")
                return .success("没有这个档案，已回到 default", body: profileBody(active: "default", names: names, database: projectsDatabase))
            }
            do {
                try ensureProfileEnv(chosen)
            } catch {
                return .failure("这台电脑还不能使用这个档案")
            }
            profileStore.save(chosen)
            return .success("", body: profileBody(active: chosen, names: names, database: projectsDatabase))
        case "projects":
            guard snapshot.installed else { return .failure(missingHermes) }
            return .success("", body: ["projects": projectRows(database: projectsDatabase(active))])
        case "project_create":
            guard snapshot.installed else { return .failure(missingHermes) }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure("请输入项目名称") }
            guard let folder = PhoneHermesHomeFolder.resolve(path, home: home) else {
                return .failure("请选择主目录里的一个现存文件夹")
            }
            do {
                let created = try HermesProfileProjects.create(
                    databasePath: projectsDatabase(active),
                    name: name,
                    folder: folder,
                    isDirectory: isDirectory
                )
                return .success("", body: ["project": ["id": created.id, "name": created.name]])
            } catch HermesProfileProjects.Failure.duplicateFolder {
                return .failure("这个文件夹已经属于别的项目")
            } catch HermesProfileProjects.Failure.missingFolder {
                return .failure("请选择一个现存文件夹")
            } catch HermesProfileProjects.Failure.invalidName {
                return .failure("请输入项目名称")
            } catch {
                return .failure("还不能新建项目")
            }
        case "sessions", "session_create", "session_delete", "session_rename", "messages", "chat":
            guard snapshot.installed else { return .failure(missingHermes) }
            guard snapshot.running else { return .failure(hermesClosed) }
            return await sessionCall(
                kind: kind,
                sessionID: sessionID,
                title: title,
                text: text,
                profile: active,
                projectID: projectID,
                runtime: runtime,
                sessionIndex: sessionIndex,
                projectsDatabase: projectsDatabase,
                isDirectory: isDirectory,
                activity: activity
            )
        default:
            return .failure("无法处理")
        }
    }

    private static func sessionCall(
        kind: String,
        sessionID: String,
        title: String,
        text: String,
        profile: String,
        projectID: String,
        runtime: PhoneHermesRuntime,
        sessionIndex: PhoneHermesSessionIndex,
        projectsDatabase: (String) -> String,
        isDirectory: (String) -> Bool,
        activity: PhoneHermesActivity
    ) async -> PhoneHermesAppReply {
        do {
            switch kind {
            case "sessions":
                guard let project = ownedProject(projectID, profile: profile, database: projectsDatabase) else {
                    return projectID.isEmpty || !HermesProfileProjects.isProjectID(projectID) ? .failure(needProject) : .failure(missingProject)
                }
                let known = sessionIndex.sessionIDs(profile: profile, projectID: project.id)
                let remote = try await runtime.listSessions(profile: profile)
                let sessions = known.compactMap { id in remote.first { $0.id == id } }
                return .success("", body: ["sessions": sessions.map {
                    ["id": $0.id, "title": $0.title, "running": activity.contains(profile: profile, sessionID: $0.id)]
                }])
            case "session_create":
                guard let project = ownedProject(projectID, profile: profile, database: projectsDatabase) else {
                    return .failure(needProject)
                }
                guard isDirectory(project.rootPath) else { return .failure(missingProjectFolder) }
                let created = try await runtime.createSession(title: title, profile: profile)
                sessionIndex.remember(profile: profile, projectID: project.id, sessionID: created.id)
                return .success("", body: ["session": ["id": created.id, "title": created.title]])
            case "session_delete":
                guard ownedSession(sessionID, profile: profile, projectID: projectID, database: projectsDatabase, sessionIndex: sessionIndex) != nil else {
                    return .failure("会话不存在")
                }
                do {
                    try await runtime.deleteSession(sessionID: sessionID, profile: profile)
                } catch let error as PhoneHermesHTTPError where PhoneHermesSessionTitle.isBusy(error) {
                    return .failure("这轮对话还没结束，稍后再删")
                }
                sessionIndex.forget(profile: profile, sessionID: sessionID)
                return .success("")
            case "session_rename":
                guard ownedSession(sessionID, profile: profile, projectID: projectID, database: projectsDatabase, sessionIndex: sessionIndex) != nil else {
                    return .failure("会话不存在")
                }
                let renamed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !renamed.isEmpty, renamed.count <= 80 else { return .failure("请输入会话标题") }
                do {
                    let saved = try await runtime.renameSession(sessionID: sessionID, title: renamed, profile: profile)
                    return .success("", body: ["session": ["id": sessionID, "title": saved]])
                } catch let error as PhoneHermesHTTPError where PhoneHermesSessionTitle.isTaken(error) {
                    return .failure("这个名字已经有了")
                }
            case "messages":
                guard validSession(sessionID) else { return .failure("会话不存在") }
                guard sessionIndex.projectID(profile: profile, sessionID: sessionID) != nil else { return .failure(needProject) }
                let turns = try await runtime.messages(sessionID: sessionID, profile: profile)
                let visible = turns.filter {
                    $0.role == "user" || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return .success("", body: [
                    "messages": visible.map { ["role": $0.role, "text": $0.text] },
                    "running": activity.contains(profile: profile, sessionID: sessionID)
                ])
            case "chat":
                guard validSession(sessionID) else { return .failure("会话不存在") }
                guard let owner = sessionIndex.projectID(profile: profile, sessionID: sessionID),
                      let project = ownedProject(owner, profile: profile, database: projectsDatabase) else {
                    return .failure(needProject)
                }
                guard isDirectory(project.rootPath) else { return .failure(missingProjectFolder) }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .failure("请输入内容") }
                activity.mark(profile: profile, sessionID: sessionID)
                let answer: String
                do {
                    answer = try await runtime.chat(
                        sessionID: sessionID,
                        text: trimmed,
                        directory: project.rootPath,
                        profile: profile
                    )
                    activity.clear(profile: profile, sessionID: sessionID)
                } catch {
                    activity.clear(profile: profile, sessionID: sessionID)
                    throw error
                }
                let named = try? await runtime.session(sessionID: sessionID, profile: profile)
                var body: [String: Any] = [:]
                if let title = named?.title, !title.isEmpty {
                    body["title"] = title
                }
                return .success(answer, body: body)
            default:
                return .failure("无法处理")
            }
        } catch let error as PhoneHermesHTTPError where PhoneHermesSessionTitle.isBusy(error) {
            return .failure("这轮对话还在进行")
        } catch let error as URLError where error.code == .timedOut {
            return .failure("这一轮时间比较长，回到会话可以看进度")
        } catch {
            return .failure("这台电脑的 Hermes 还不能接收手机消息")
        }
    }

    /// 只允许改、删记在当前项目下的会话。
    private static func ownedSession(
        _ sessionID: String,
        profile: String,
        projectID: String,
        database: (String) -> String,
        sessionIndex: PhoneHermesSessionIndex
    ) -> HermesProfileProjects.Project? {
        guard validSession(sessionID),
              let project = ownedProject(projectID, profile: profile, database: database),
              sessionIndex.projectID(profile: profile, sessionID: sessionID) == project.id else {
            return nil
        }
        return project
    }

    private static func ownedProject(_ projectID: String, profile: String, database: (String) -> String) -> HermesProfileProjects.Project? {
        guard HermesProfileProjects.isProjectID(projectID) else { return nil }
        return HermesProfileProjects.project(databasePath: database(profile), id: projectID)
    }

    private static func projectRows(database path: String) -> [[String: String]] {
        HermesProfileProjects.list(databasePath: path).map { ["id": $0.id, "name": $0.name] }
    }

    private static func profileBody(active: String, names: [String], database: (String) -> String) -> [String: Any] {
        [
            "profile": active,
            "profiles": names,
            "projects": projectRows(database: database(active))
        ]
    }

    private static func statusBody(snapshot: PhoneHermesSnapshot, profile: String, names: [String]) -> [String: Any] {
        [
            "hermes_installed": snapshot.installed,
            "hermes_running": snapshot.running,
            "profile": profile,
            "profiles": names
        ]
    }

    private static func validSession(_ sessionID: String) -> Bool {
        !sessionID.isEmpty && sessionID.count <= 256 && sessionID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}
