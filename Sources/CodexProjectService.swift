import Foundation

/// Codex 当前选中本地项目。
struct CodexProject {
    let name: String
    let rootPath: String
}

/// 只读解析 Codex 全局状态，绝不写回。
struct CodexProjectService {
    typealias Reader = (String) -> Data?

    private let home: String
    private let reader: Reader
    private let fs: FileSystemService

    init(
        home: String = NSHomeDirectory(),
        fs: FileSystemService = FileSystemService(),
        reader: @escaping Reader = { path in FileManager.default.contents(atPath: path) }
    ) {
        self.home = home
        self.fs = fs
        self.reader = reader
    }

    /// Codex 权威状态文件路径：~/.codex/.codex-global-state.json
    var statePath: String {
        (home as NSString).appendingPathComponent(".codex/.codex-global-state.json")
    }

    /// 解析当前选中的本地项目。解析链：
    /// selected-project.type == "local" → selected-project.projectId → local-projects[id].rootPaths[0]
    /// 任一步缺失、类型不符、路径非目录均返回 nil。
    func resolveProject() -> CodexProject? {
        guard let data = reader(statePath) else { return nil }
        guard let state = try? JSONDecoder().decode(CodexGlobalState.self, from: data) else { return nil }
        guard let selected = state.selectedProject, selected.type == "local",
              let projectID = selected.projectId else { return nil }
        guard let project = state.localProjects?[projectID] else { return nil }
        guard let first = project.rootPaths?.first else { return nil }
        let standardized = (first as NSString).standardizingPath
        guard fs.isExistingDirectory(standardized) else { return nil }
        return CodexProject(name: project.name ?? "未命名项目", rootPath: standardized)
    }
}

private struct CodexGlobalState: Decodable {
    let selectedProject: SelectedProject?
    let localProjects: [String: LocalProject]?

    enum CodingKeys: String, CodingKey {
        case selectedProject = "selected-project"
        case localProjects = "local-projects"
    }
}

private struct SelectedProject: Decodable {
    let type: String?
    let projectId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case projectId
    }
}

private struct LocalProject: Decodable {
    let id: String?
    let name: String?
    let rootPaths: [String]?
}
