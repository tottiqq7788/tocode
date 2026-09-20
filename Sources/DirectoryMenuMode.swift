import AppKit
import Foundation

enum DirectoryMenuMode: Equatable {
    case normal
    case delete
    case access

    static func resolve(option: Bool, command: Bool) -> DirectoryMenuMode {
        if option { return .delete }
        if command { return .access }
        return .normal
    }

    func action(for kind: FileSystemService.Kind) -> DirectoryMenuEntryAction {
        switch self {
        case .normal:
            return .copy
        case .delete:
            return .delete
        case .access:
            switch kind {
            case .directory:
                return .openDirectory
            case .file:
                return .openFile
            }
        }
    }

    func bottomAction() -> DirectoryMenuBottomAction {
        switch self {
        case .normal:
            return .create
        case .delete:
            return .clear
        case .access:
            return .access
        }
    }
}

enum DirectoryMenuEntryAction: Equatable {
    case copy
    case delete
    case openDirectory
    case openFile
}

enum DirectoryMenuBottomAction: Equatable {
    case create
    case clear
    case access
}

enum WorkspaceItemOpenError: LocalizedError {
    case directoryUnavailable(String)
    case fileUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let path):
            return "无法在访达中打开「\((path as NSString).lastPathComponent)」"
        case .fileUnavailable(let path):
            return "无法用默认应用打开「\((path as NSString).lastPathComponent)」"
        }
    }
}

protocol WorkspaceItemOpening {
    func revealDirectoryInFinder(_ path: String) throws
    func openFileWithDefaultApplication(_ path: String) throws
}

struct NSWorkspaceItemOpener: WorkspaceItemOpening {
    let workspace: NSWorkspace
    let fileManager: FileManager

    init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    func revealDirectoryInFinder(_ path: String) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceItemOpenError.directoryUnavailable(path)
        }
        guard workspace.selectFile(nil, inFileViewerRootedAtPath: path) else {
            throw WorkspaceItemOpenError.directoryUnavailable(path)
        }
    }

    func openFileWithDefaultApplication(_ path: String) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw WorkspaceItemOpenError.fileUnavailable(path)
        }
        guard workspace.open(URL(fileURLWithPath: path)) else {
            throw WorkspaceItemOpenError.fileUnavailable(path)
        }
    }
}

enum DirectoryMenuAccess {
    static func perform(path: String, kind: FileSystemService.Kind, opener: WorkspaceItemOpening) throws {
        switch kind {
        case .directory:
            try opener.revealDirectoryInFinder(path)
        case .file:
            try opener.openFileWithDefaultApplication(path)
        }
    }
}
