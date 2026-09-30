import Foundation

/// 左键目录树展示根解析：访达跟随 > codex跟随 > 手动根。
enum DirectoryRootResolver {
    static func resolve(
        finderFollowEnabled: Bool,
        finderDirectory: String?,
        codexFollowEnabled: Bool,
        codexRoot: String?,
        manualRoot: String
    ) -> String {
        if finderFollowEnabled, let finderDirectory {
            return finderDirectory
        }
        if codexFollowEnabled, let codexRoot {
            return codexRoot
        }
        return manualRoot
    }
}
