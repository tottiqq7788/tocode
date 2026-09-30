import Foundation

/// 左键目录树展示根解析：默认固定目录；仅当前台匹配且对应跟随开启时临时接管。
enum DirectoryRootFollowFrontmost: Equatable {
    case finder
    case codex
    case other
}

enum DirectoryRootResolver {
    static func resolve(
        frontmost: DirectoryRootFollowFrontmost,
        finderFollowEnabled: Bool,
        finderDirectory: String?,
        codexFollowEnabled: Bool,
        codexRoot: String?,
        manualRoot: String
    ) -> String {
        switch frontmost {
        case .finder:
            if finderFollowEnabled, let finderDirectory {
                return finderDirectory
            }
        case .codex:
            if codexFollowEnabled, let codexRoot {
                return codexRoot
            }
        case .other:
            break
        }
        return manualRoot
    }

    static func frontmost(fromBundleIdentifier bundleIdentifier: String?) -> DirectoryRootFollowFrontmost {
        switch bundleIdentifier {
        case "com.apple.finder":
            return .finder
        case "com.openai.codex":
            return .codex
        default:
            return .other
        }
    }
}
