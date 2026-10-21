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
    /// 这一步还要调用工具。结束回复为 false。
    var interim: Bool = false
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
    static let pageSize = 80

    /// 只列当前这一层。`offset` 是这一层已经给出的项数，每次再给一页。
    static func list(
        root: String,
        includeHidden: Bool,
        relative: String = "",
        offset: Int = 0,
        pageSize: Int = PhoneHermesDirectory.pageSize,
        fileManager: FileManager = .default
    ) -> PhoneHermesAppReply {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return .failure(PhoneHermesApp.missingProjectFolder)
        }
        let fileSystem = FileSystemService(fm: fileManager)
        let rootReal = canonical(root)
        let folder: String
        if relative.isEmpty {
            folder = rootReal
        } else {
            guard let resolved = fileInside(root: rootReal, relative: relative) else {
                return .failure("这个文件夹不在项目里")
            }
            var folderIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: resolved, isDirectory: &folderIsDir), folderIsDir.boolValue else {
                return .failure("这个文件夹不在项目里")
            }
            folder = resolved
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: folder)) ?? []
        var rows: [(name: String, path: String, kind: String, directory: Bool)] = []
        for name in names {
            let child = (folder as NSString).appendingPathComponent(name)
            if !includeHidden && fileSystem.isHiddenEntry(name: name, path: child) { continue }
            let real = canonical(child)
            guard real == rootReal || real.hasPrefix(rootReal + "/") else { continue }
            var childIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: real, isDirectory: &childIsDir) else { continue }
            let shown = relative.isEmpty ? name : relative + "/" + name
            rows.append((name, shown, childIsDir.boolValue ? "directory" : "file", childIsDir.boolValue))
        }
        rows.sort { lhs, rhs in
            if lhs.directory != rhs.directory { return lhs.directory && !rhs.directory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let start = min(max(offset, 0), rows.count)
        let end = min(rows.count, start + max(pageSize, 1))
        let entries = rows[start..<end].map { ["path": $0.path, "name": $0.name, "kind": $0.kind] }
        return .success("", body: [
            "entries": entries,
            "next": end,
            "truncated": end < rows.count,
            "root": rootReal
        ])
    }

    static let previewPageCharacters = 12_000
    static let previewReadLimit = 8_000_000

    /// 只读打开项目目录里的一个文本文件。路径相对项目根目录，解析后必须仍在里面。
    /// `offset` 是已经读过的字符数，每次只再给一页，方便手机接着往下读。
    static func preview(
        root: String,
        relative: String,
        offset: Int = 0,
        pageCharacters: Int = previewPageCharacters,
        fileManager: FileManager = .default
    ) -> PhoneHermesAppReply {
        let rootReal = canonical(root)
        guard let file = fileInside(root: rootReal, relative: relative) else {
            return .failure("这个文件不在项目里")
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: file, isDirectory: &isDir) else {
            return .failure("文件不存在")
        }
        guard !isDir.boolValue else { return .failure("这是文件夹") }
        guard var data = fileManager.contents(atPath: file) else { return .failure("这个文件不能预览") }
        guard looksLikeText(data.prefix(8_192)) else { return .failure("这个文件不能预览") }
        if data.count > previewReadLimit { data = data.prefix(previewReadLimit) }
        var slice = data
        var text = String(data: slice, encoding: .utf8)
        while text == nil && !slice.isEmpty {
            slice = slice.dropLast()
            text = String(data: slice, encoding: .utf8)
        }
        guard let text else { return .failure("这个文件不能预览") }
        let start = min(max(offset, 0), text.count)
        if start >= text.count {
            return previewBody(file: file, root: rootReal, content: "", next: start, truncated: false)
        }
        let page = max(pageCharacters, 1)
        var end = min(text.count, start + page)
        if end < text.count {
            let cursor = text.index(text.startIndex, offsetBy: end)
            let endedOnNewline = end > start && text[text.index(before: cursor)] == "\n"
            if !endedOnNewline, let newline = text[cursor...].prefix(200).firstIndex(of: "\n") {
                end = text.distance(from: text.startIndex, to: text.index(after: newline))
            }
        }
        let piece = String(text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)])
        return previewBody(file: file, root: rootReal, content: piece, next: end, truncated: end < text.count)
    }

    private static func previewBody(file: String, root: String, content: String, next: Int, truncated: Bool) -> PhoneHermesAppReply {
        let name = (file as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        let format = ["md", "markdown", "mdown"].contains(ext) ? "markdown" : "text"
        let shown = String(file.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return .success("", body: [
            "name": name,
            "path": shown,
            "format": format,
            "content": content,
            "next": next,
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
        offset: Int = 0,
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
            return PhoneHermesDirectory.list(
                root: project.rootPath,
                includeHidden: includeHidden,
                relative: path,
                offset: offset
            )
        case "preview":
            guard snapshot.installed else { return .failure(missingHermes) }
            guard let project = ownedProject(projectID, profile: active, database: projectsDatabase) else {
                return .failure(needProject)
            }
            return PhoneHermesDirectory.preview(root: project.rootPath, relative: path, offset: offset)
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
                    "messages": visible.map {
                        ["role": $0.role, "text": $0.text, "interim": $0.interim] as [String: Any]
                    },
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

    /// 把手机交来的一个文件新建在当前项目的固定附件文件夹里。手机不指定路径。
    static func saveAttachment(
        profile: String,
        projectID: String,
        name: String,
        kind: String,
        bytes: Data,
        catalog: [String] = ["default"],
        profileStore: PhoneHermesProfileStore,
        projectsDatabase: (String) -> String,
        isDirectory: (String) -> Bool,
        fileManager: FileManager = .default
    ) -> PhoneHermesAppReply {
        let names = catalog.isEmpty ? ["default"] : catalog
        let requested = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = HermesProfileCatalog.accepted(
            requested.isEmpty ? profileStore.resolved(among: names) : requested,
            among: names
        )
        guard let project = ownedProject(projectID, profile: active, database: projectsDatabase) else {
            return .failure(projectID.isEmpty || !HermesProfileProjects.isProjectID(projectID) ? needProject : missingProject)
        }
        guard isDirectory(project.rootPath) else { return .failure(missingProjectFolder) }
        switch PhoneProjectAttachments.store(root: project.rootPath, name: name, kind: kind, bytes: bytes, fileManager: fileManager) {
        case .success(let relative):
            return .success("", body: ["path": relative])
        case .failure(let error):
            return .failure(error.text)
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

struct PhoneAttachmentError: Error {
    let text: String
}

enum PhoneProjectAttachments {
    static let imageFolder = "对话附件-图片"
    static let fileFolder = "对话附件-文件"
    static let byteLimit = 20 * 1024 * 1024

    /// 只在项目根目录下的两个固定文件夹里新建文件。同名不覆盖，解析后必须仍在项目内。
    static func store(
        root: String,
        name: String,
        kind: String,
        bytes: Data,
        fileManager: FileManager = .default
    ) -> Result<String, PhoneAttachmentError> {
        let rootReal = canonical(root)
        var rootIsDir: ObjCBool = false
        guard fileManager.fileExists(atPath: rootReal, isDirectory: &rootIsDir), rootIsDir.boolValue else {
            return .failure(PhoneAttachmentError(text: "项目目录不存在"))
        }
        guard kind == "image" || kind == "file" else { return .failure(PhoneAttachmentError(text: "无法保存")) }
        guard !bytes.isEmpty, bytes.count <= byteLimit else { return .failure(PhoneAttachmentError(text: "只接受不超过 20MB 的单个文件")) }
        guard let safe = sanitized(name) else { return .failure(PhoneAttachmentError(text: "文件名不能使用")) }
        let folderName = kind == "image" ? imageFolder : fileFolder
        let folderReal = canonical((rootReal as NSString).appendingPathComponent(folderName))
        guard folderReal.hasPrefix(rootReal + "/") else { return .failure(PhoneAttachmentError(text: "不能写到项目外面")) }
        var folderIsDir: ObjCBool = false
        if fileManager.fileExists(atPath: folderReal, isDirectory: &folderIsDir) {
            guard folderIsDir.boolValue else { return .failure(PhoneAttachmentError(text: "附件文件夹被同名文件占住了")) }
        } else {
            do {
                try fileManager.createDirectory(atPath: folderReal, withIntermediateDirectories: true)
            } catch {
                return .failure(PhoneAttachmentError(text: "无法新建附件文件夹"))
            }
        }
        guard let chosen = uniqueName(folder: folderReal, name: safe, fileManager: fileManager) else {
            return .failure(PhoneAttachmentError(text: "同名文件太多了"))
        }
        let destination = (folderReal as NSString).appendingPathComponent(chosen)
        guard canonical(destination).hasPrefix(rootReal + "/") else { return .failure(PhoneAttachmentError(text: "不能写到项目外面")) }
        do {
            try bytes.write(to: URL(fileURLWithPath: destination), options: .atomic)
        } catch {
            return .failure(PhoneAttachmentError(text: "无法保存文件"))
        }
        guard canonical(destination).hasPrefix(rootReal + "/") else { return .failure(PhoneAttachmentError(text: "不能写到项目外面")) }
        return .success("\(folderName)/\(chosen)")
    }

    private static func sanitized(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255 else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0") else { return nil }
        guard trimmed != ".", trimmed != ".." else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { return nil }
        return trimmed
    }

    private static func uniqueName(folder: String, name: String, fileManager: FileManager) -> String? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        func candidate(_ index: Int) -> String {
            let base = index <= 1 ? stem : "\(stem)-\(index)"
            return ext.isEmpty ? base : "\(base).\(ext)"
        }
        var index = 1
        while index < 1000 && fileManager.fileExists(atPath: (folder as NSString).appendingPathComponent(candidate(index))) {
            index += 1
        }
        guard index < 1000 else { return nil }
        return candidate(index)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
