import Foundation
import Darwin

struct TogentWorkspaceReceipt {
    let root: URL
    let agentsURL: URL
    let projectURL: URL
    let archiveURL: URL
    let createdRoot: Bool
    let createdProject: Bool
    let createdArchive: Bool
    let previousAgentsData: Data?
    let createdAgents: Bool
}

final class TogentWorkspaceService {
    static let managedBegin = "<!-- TOCODE:TOGENT:BEGIN -->"
    static let managedEnd = "<!-- TOCODE:TOGENT:END -->"
    static let memoryHeading = "## 角色记忆与分类依据"

    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    func defaultWorkspacePath(registeredPaths: [String]) -> String {
        let parent = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("togent", isDirectory: true)
        var occupied = Set<Int>()
        for path in registeredPaths {
            if let number = Self.roleNumber(from: URL(fileURLWithPath: path).lastPathComponent) {
                occupied.insert(number)
            }
        }
        if let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                if let number = Self.roleNumber(from: entry.lastPathComponent) {
                    occupied.insert(number)
                }
            }
        }
        var candidate = 1
        while occupied.contains(candidate) {
            candidate += 1
        }
        return parent.appendingPathComponent("角色\(candidate)", isDirectory: true).path
    }

    func canonicalPath(_ rawPath: String) throws -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard expanded.hasPrefix("/") else {
            throw TogentError.invalidWorkspacePath
        }
        let standardized = (expanded as NSString).standardizingPath
        guard standardized != "/", !standardized.isEmpty else {
            throw TogentError.invalidWorkspacePath
        }

        var existing = URL(fileURLWithPath: standardized)
        var missingComponents: [String] = []
        var isDirectory: ObjCBool = false
        while !fileManager.fileExists(atPath: existing.path, isDirectory: &isDirectory) {
            let component = existing.lastPathComponent
            guard !component.isEmpty else {
                throw TogentError.invalidWorkspacePath
            }
            missingComponents.insert(component, at: 0)
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                throw TogentError.invalidWorkspacePath
            }
            existing = parent
        }
        guard isDirectory.boolValue else {
            throw TogentError.invalidWorkspacePath
        }
        guard let resolvedExistingPath = Self.realPath(existing.path) else {
            throw TogentError.invalidWorkspacePath
        }
        var canonical = URL(
            fileURLWithPath: resolvedExistingPath,
            isDirectory: true
        )
        for component in missingComponents {
            canonical.appendPathComponent(component, isDirectory: true)
        }
        // 不再调用 standardizedFileURL：它会把 realpath 得到的
        // `/private/var` 折叠回 `/var`，破坏沙箱的真实路径匹配。
        return canonical.path
    }

    func validateIsolation(
        candidatePath: String,
        existingRoles: [TogentRole],
        excluding roleID: UUID? = nil
    ) throws {
        let candidate = try canonicalPath(candidatePath)
        for role in existingRoles where role.id != roleID {
            let existing = try canonicalPath(role.workspacePath)
            if candidate == existing {
                throw TogentError.duplicateWorkspacePath
            }
            if Self.isDescendant(candidate, of: existing)
                || Self.isDescendant(existing, of: candidate) {
                throw TogentError.overlappingWorkspacePath
            }
        }
    }

    func provision(role: TogentRole) throws -> TogentWorkspaceReceipt {
        let canonical = try canonicalPath(role.workspacePath)
        let root = URL(fileURLWithPath: canonical, isDirectory: true)
        let agentsURL = root.appendingPathComponent("AGENTS.md")
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        let archiveURL = root.appendingPathComponent("wechat", isDirectory: true)

        var rootIsDirectory: ObjCBool = false
        let rootExisted = fileManager.fileExists(
            atPath: root.path,
            isDirectory: &rootIsDirectory
        )
        if rootExisted, !rootIsDirectory.boolValue {
            throw TogentError.invalidWorkspacePath
        }
        let projectExisted = fileManager.fileExists(atPath: projectURL.path)
        let archiveIsSymbolicLink =
            (try? fileManager.destinationOfSymbolicLink(atPath: archiveURL.path)) != nil
        let archiveExisted = fileManager.fileExists(atPath: archiveURL.path)
            || archiveIsSymbolicLink
        let previousAgentsData = try? Data(contentsOf: agentsURL)
        let agentsExisted = previousAgentsData != nil

        do {
            if !rootExisted {
                try fileManager.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            }
            var projectIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: projectURL.path, isDirectory: &projectIsDirectory) {
                guard projectIsDirectory.boolValue else {
                    throw TogentError.workspace("project 已存在但不是文件夹")
                }
            } else {
                try fileManager.createDirectory(
                    at: projectURL,
                    withIntermediateDirectories: false
                )
            }
            var archiveIsDirectory: ObjCBool = false
            if archiveIsSymbolicLink {
                throw TogentError.workspaceOutsideBoundary
            }
            if fileManager.fileExists(atPath: archiveURL.path, isDirectory: &archiveIsDirectory) {
                guard archiveIsDirectory.boolValue else {
                    throw TogentError.workspace("wechat 已存在但不是文件夹")
                }
                try validateArchiveDirectory(archiveURL, workspaceRoot: root)
            } else {
                try fileManager.createDirectory(
                    at: archiveURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: archiveURL.path
            )

            let existingText: String
            if let previousAgentsData {
                guard let decoded = String(data: previousAgentsData, encoding: .utf8) else {
                    throw TogentError.workspace("现有 AGENTS.md 不是 UTF-8，未作修改")
                }
                existingText = decoded
            } else {
                existingText = ""
            }
            let merged = try mergedAgents(existing: existingText, role: role)
            try Data(merged.utf8).write(to: agentsURL, options: .atomic)

            return TogentWorkspaceReceipt(
                root: root,
                agentsURL: agentsURL,
                projectURL: projectURL,
                archiveURL: archiveURL,
                createdRoot: !rootExisted,
                createdProject: !projectExisted,
                createdArchive: !archiveExisted,
                previousAgentsData: previousAgentsData,
                createdAgents: !agentsExisted
            )
        } catch {
            let receipt = TogentWorkspaceReceipt(
                root: root,
                agentsURL: agentsURL,
                projectURL: projectURL,
                archiveURL: archiveURL,
                createdRoot: !rootExisted,
                createdProject: !projectExisted,
                createdArchive: !archiveExisted,
                previousAgentsData: previousAgentsData,
                createdAgents: !agentsExisted
            )
            rollback(receipt)
            if let error = error as? TogentError {
                throw error
            }
            throw TogentError.workspace(error.localizedDescription)
        }
    }

    func rollback(_ receipt: TogentWorkspaceReceipt) {
        if let previous = receipt.previousAgentsData {
            try? previous.write(to: receipt.agentsURL, options: .atomic)
        } else if receipt.createdAgents {
            try? fileManager.removeItem(at: receipt.agentsURL)
        }
        if receipt.createdArchive {
            try? fileManager.removeItem(at: receipt.archiveURL)
        }
        if receipt.createdProject {
            try? fileManager.removeItem(at: receipt.projectURL)
        }
        if receipt.createdRoot {
            try? fileManager.removeItem(at: receipt.root)
        }
    }

    func archiveDirectory(for role: TogentRole) throws -> URL {
        let canonicalWorkspace = try canonicalPath(role.workspacePath)
        guard canonicalWorkspace == role.workspacePath else {
            throw TogentError.workspaceOutsideBoundary
        }
        let root = URL(fileURLWithPath: canonicalWorkspace, isDirectory: true)
        let archive = root.appendingPathComponent("wechat", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: archive.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TogentError.workspace("角色 wechat 归档目录不存在")
        }
        try validateArchiveDirectory(archive, workspaceRoot: root)
        return archive
    }

    func mergedAgents(existing: String, role: TogentRole) throws -> String {
        let managed = managedBlock(role: role)
        let beginRange = existing.range(of: Self.managedBegin)
        let endRange = existing.range(of: Self.managedEnd)
        var result: String

        switch (beginRange, endRange) {
        case (nil, nil):
            if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = "# \(role.name)\n\n\(managed)"
            } else {
                result = existing.trimmingCharacters(in: .newlines) + "\n\n" + managed
            }
        case (.some(let begin), .some(let end)) where begin.lowerBound < end.upperBound:
            result = existing
            result.replaceSubrange(begin.lowerBound..<end.upperBound, with: managed)
        default:
            throw TogentError.workspace("AGENTS.md 中的 Tocode 托管区块标记不完整")
        }

        if !result.contains(Self.memoryHeading) {
            result = result.trimmingCharacters(in: .newlines)
                + "\n\n\(Self.memoryHeading)\n\n"
                + "- 在这里维护长期记忆、项目分类依据和必要的决策；不要写入密钥。\n"
        }
        return result.trimmingCharacters(in: .newlines) + "\n"
    }

    private func managedBlock(role: TogentRole) -> String {
        let archive = URL(fileURLWithPath: role.workspacePath, isDirectory: true)
            .appendingPathComponent("wechat", isDirectory: true)
            .path
        let rolePrompt = role.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(Self.managedBegin)
        ## Tocode 托管规则

        - Tocode 是当前运行的 macOS 菜单栏应用；Togent 是随 Tocode 启动、由微信消息驱动的内置 Pi Agent。
        - 微信是唯一任务入口。不要创建其他 prompt 接口，也不要把 Agent 回复伪装成入站归档。
        - 当前角色：\(role.name)
        - 当前工作区：\(role.workspacePath)
        - 只允许在当前工作区内写入。不得尝试读取或写入其他角色、钥匙串、微信凭据或 Tocode 配置。
        - 微信历史归档位于 \(archive)，仅在任务确有必要时按日期只读查询，不要自动加载全部历史。
        - 新的软件或独立工作必须归类到 `project/项目名/`，每个项目使用独立目录并自行初始化本地 Git，避免不同工作混杂。
        - 沙箱内的本地 Git 可直接使用；远程 clone/fetch/pull/push 必须调用 `togent-git`，禁止 force push 和删除远程分支。
        - 用户明确要求发送当前工作区文件本体时，不要声称微信只能回复文字；确认文件后，按当前任务提示在最终回复末尾输出受管文件控制块。控制块只使用当前工作区相对路径，禁止绝对路径、目录、symlink、工作区外路径或超过五个文件。
        - 将稳定的长期信息、当前分类依据和项目索引维护在下方“角色记忆与分类依据”中，避免跨项目记忆混乱。

        ### 角色提示词

        \(rolePrompt.isEmpty ? "（未设置额外角色提示词）" : rolePrompt)
        \(Self.managedEnd)
        """
    }

    private func validateArchiveDirectory(
        _ archive: URL,
        workspaceRoot: URL
    ) throws {
        let values = try archive.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw TogentError.workspaceOutsideBoundary
        }
        let canonicalArchive = try canonicalPath(archive.path)
        guard canonicalArchive == archive.path,
              Self.isDescendant(canonicalArchive, of: workspaceRoot.path) else {
            throw TogentError.workspaceOutsideBoundary
        }
    }

    private static func roleNumber(from name: String) -> Int? {
        guard name.hasPrefix("角色") else { return nil }
        let suffix = name.dropFirst(2)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber),
              let number = Int(suffix), number > 0 else {
            return nil
        }
        return number
    }

    static func isDescendant(_ path: String, of parent: String) -> Bool {
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return path.hasPrefix(prefix)
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
