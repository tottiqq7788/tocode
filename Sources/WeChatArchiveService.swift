import Foundation
import Darwin

enum WeChatArchiveError: Error, Equatable {
    case createDirectory
    case appendLog
    case missingArchiveRoot
    case invalidReceiptPath
}

private struct WeChatDirectoryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

final class WeChatArchiveDirectoryHandle {
    fileprivate let parentDescriptor: Int32
    fileprivate let rootDescriptor: Int32
    fileprivate let dateDescriptor: Int32
    fileprivate let rootName: String
    fileprivate let dateName: String
    fileprivate let rootIdentity: WeChatDirectoryIdentity
    fileprivate let dateIdentity: WeChatDirectoryIdentity

    fileprivate init(
        parentDescriptor: Int32,
        rootDescriptor: Int32,
        dateDescriptor: Int32,
        rootName: String,
        dateName: String,
        rootIdentity: WeChatDirectoryIdentity,
        dateIdentity: WeChatDirectoryIdentity
    ) {
        self.parentDescriptor = parentDescriptor
        self.rootDescriptor = rootDescriptor
        self.dateDescriptor = dateDescriptor
        self.rootName = rootName
        self.dateName = dateName
        self.rootIdentity = rootIdentity
        self.dateIdentity = dateIdentity
    }

    deinit {
        Darwin.close(dateDescriptor)
        Darwin.close(rootDescriptor)
        Darwin.close(parentDescriptor)
    }
}

protocol WeChatFileSystem {
    func openArchiveDirectory(
        root: URL,
        dateName: String
    ) throws -> WeChatArchiveDirectoryHandle
    func verifyArchiveDirectory(_ directory: WeChatArchiveDirectoryHandle) throws
    func writeExclusive(
        _ data: Data,
        named name: String,
        in directory: WeChatArchiveDirectoryHandle
    ) throws -> Bool
    func append(
        _ data: Data,
        named name: String,
        in directory: WeChatArchiveDirectoryHandle
    ) throws
    func removeFileIfPresent(
        named name: String,
        in directory: WeChatArchiveDirectoryHandle
    )
}

struct SystemWeChatFileSystem: WeChatFileSystem {
    func openArchiveDirectory(
        root: URL,
        dateName: String
    ) throws -> WeChatArchiveDirectoryHandle {
        let normalizedRoot = root.standardizedFileURL
        let rootName = normalizedRoot.lastPathComponent
        guard Self.isSafeComponent(rootName),
              dateName.count == 6,
              dateName.allSatisfy(\.isNumber) else {
            throw WeChatArchiveError.createDirectory
        }
        let parent = normalizedRoot.deletingLastPathComponent()
        let parentDescriptor = parent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard parentDescriptor >= 0 else {
            throw WeChatArchiveError.createDirectory
        }

        var rootDescriptor: Int32 = -1
        var dateDescriptor: Int32 = -1
        do {
            if rootName.withCString({
                Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
            }) != 0, errno != EEXIST {
                throw WeChatArchiveError.createDirectory
            }
            rootDescriptor = try Self.openDirectory(
                named: rootName,
                relativeTo: parentDescriptor
            )
            guard Darwin.fchmod(rootDescriptor, mode_t(0o700)) == 0 else {
                throw WeChatArchiveError.createDirectory
            }
            if dateName.withCString({
                Darwin.mkdirat(rootDescriptor, $0, mode_t(0o700))
            }) != 0, errno != EEXIST {
                throw WeChatArchiveError.createDirectory
            }
            dateDescriptor = try Self.openDirectory(
                named: dateName,
                relativeTo: rootDescriptor
            )
            guard Darwin.fchmod(dateDescriptor, mode_t(0o700)) == 0 else {
                throw WeChatArchiveError.createDirectory
            }
            return WeChatArchiveDirectoryHandle(
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor,
                dateDescriptor: dateDescriptor,
                rootName: rootName,
                dateName: dateName,
                rootIdentity: try Self.identity(of: rootDescriptor),
                dateIdentity: try Self.identity(of: dateDescriptor)
            )
        } catch {
            if dateDescriptor >= 0 { Darwin.close(dateDescriptor) }
            if rootDescriptor >= 0 { Darwin.close(rootDescriptor) }
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    func verifyArchiveDirectory(_ directory: WeChatArchiveDirectoryHandle) throws {
        let root = try Self.openDirectory(
            named: directory.rootName,
            relativeTo: directory.parentDescriptor
        )
        defer { Darwin.close(root) }
        guard try Self.identity(of: root) == directory.rootIdentity else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        let date = try Self.openDirectory(
            named: directory.dateName,
            relativeTo: root
        )
        defer { Darwin.close(date) }
        guard try Self.identity(of: date) == directory.dateIdentity else {
            throw WeChatArchiveError.invalidReceiptPath
        }
    }

    func writeExclusive(
        _ data: Data,
        named name: String,
        in directory: WeChatArchiveDirectoryHandle
    ) throws -> Bool {
        guard Self.isSafeComponent(name) else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directory.dateDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        if descriptor < 0, errno == EEXIST {
            return false
        }
        guard descriptor >= 0 else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        do {
            defer { Darwin.close(descriptor) }
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw WeChatArchiveError.invalidReceiptPath
            }
            try Self.writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw WeChatArchiveError.invalidReceiptPath
            }
            return true
        } catch {
            _ = name.withCString {
                Darwin.unlinkat(directory.dateDescriptor, $0, 0)
            }
            throw error
        }
    }

    func append(
        _ data: Data,
        named name: String,
        in directory: WeChatArchiveDirectoryHandle
    ) throws {
        guard Self.isSafeComponent(name) else {
            throw WeChatArchiveError.appendLog
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directory.dateDescriptor,
                $0,
                O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw WeChatArchiveError.appendLog
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw WeChatArchiveError.appendLog
        }
        do {
            try Self.writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw WeChatArchiveError.appendLog
            }
        } catch {
            throw WeChatArchiveError.appendLog
        }
    }

    func removeFileIfPresent(
        named name: String,
        in directory: WeChatArchiveDirectoryHandle
    ) {
        guard Self.isSafeComponent(name) else { return }
        _ = name.withCString {
            Darwin.unlinkat(directory.dateDescriptor, $0, 0)
        }
    }

    private static func openDirectory(named name: String, relativeTo parent: Int32) throws -> Int32 {
        guard isSafeComponent(name) else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(descriptor)
            throw WeChatArchiveError.invalidReceiptPath
        }
        return descriptor
    }

    private static func identity(of descriptor: Int32) throws -> WeChatDirectoryIdentity {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        return WeChatDirectoryIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw WeChatArchiveError.invalidReceiptPath
                }
            }
        }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}

struct WeChatArchiveReceipt: Equatable, Sendable {
    let logRelativePath: String
    let attachmentRelativePaths: [String]

    static let empty = WeChatArchiveReceipt(
        logRelativePath: "",
        attachmentRelativePaths: []
    )
}

protocol WeChatArchiving: AnyObject {
    func archive(
        _ message: WeChatMessage,
        receivedAt: Date,
        root: URL
    ) async throws -> WeChatArchiveReceipt
}

actor WeChatArchiveService: WeChatArchiving {
    private let fixedRoot: URL?
    private let transport: WeChatILinkTransporting
    private let fileSystem: WeChatFileSystem
    private let calendarProvider: () -> Calendar

    init(
        root: URL? = nil,
        transport: WeChatILinkTransporting,
        fileSystem: WeChatFileSystem = SystemWeChatFileSystem(),
        calendarProvider: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }
    ) {
        fixedRoot = root
        self.transport = transport
        self.fileSystem = fileSystem
        self.calendarProvider = calendarProvider
    }

    func archive(
        _ message: WeChatMessage,
        receivedAt: Date
    ) async throws -> WeChatArchiveReceipt {
        guard let fixedRoot else {
            throw WeChatArchiveError.missingArchiveRoot
        }
        return try await archive(message, receivedAt: receivedAt, root: fixedRoot)
    }

    func archive(
        _ message: WeChatMessage,
        receivedAt: Date,
        root: URL
    ) async throws -> WeChatArchiveReceipt {
        let calendar = calendarProvider()
        let dateName = format(receivedAt, pattern: "yyMMdd", calendar: calendar)
        let timeName = format(receivedAt, pattern: "HHmmss_SSS", calendar: calendar)
        let headingTime = format(receivedAt, pattern: "HH:mm:ss", calendar: calendar)
        let dateDirectory = root.appendingPathComponent(dateName, isDirectory: true)

        let archiveDirectory: WeChatArchiveDirectoryHandle
        do {
            archiveDirectory = try fileSystem.openArchiveDirectory(
                root: root,
                dateName: dateName
            )
        } catch {
            throw WeChatArchiveError.createDirectory
        }

        let content = collectContent(from: message)
        let downloaded = await downloadAttachments(content.attachments)
        do {
            try fileSystem.verifyArchiveDirectory(archiveDirectory)
        } catch {
            throw WeChatArchiveError.invalidReceiptPath
        }
        var attachmentLines = content.missingAttachmentLines
        var savedAttachmentNames: [String] = []

        for result in downloaded.sorted(by: { $0.plan.index < $1.plan.index }) {
            switch result.data {
            case .success(let data):
                do {
                    let finalName = try writeUniqueAttachment(
                        data,
                        in: archiveDirectory,
                        prefix: timeName,
                        index: result.plan.index,
                        originalName: result.plan.originalName
                    )
                    savedAttachmentNames.append(finalName)
                    attachmentLines.append(
                        "- \(result.plan.label)：[\(escapeLinkText(finalName))](\(encodeLink(finalName)))"
                    )
                } catch {
                    attachmentLines.append("- \(result.plan.label)：保存失败")
                }
            case .failure:
                attachmentLines.append("- \(result.plan.label)：下载或解密失败")
            }
        }

        let markdown = makeMarkdown(
            message: message,
            headingTime: headingTime,
            textParts: content.textParts,
            voiceParts: content.voiceParts,
            quotedParts: content.quotedParts,
            attachmentLines: attachmentLines
        )
        let logName = "wechat\(dateName).md"
        let logURL = dateDirectory.appendingPathComponent(logName)
        do {
            try fileSystem.append(
                Data(markdown.utf8),
                named: logName,
                in: archiveDirectory
            )
        } catch {
            for name in savedAttachmentNames {
                fileSystem.removeFileIfPresent(
                    named: name,
                    in: archiveDirectory
                )
            }
            throw WeChatArchiveError.appendLog
        }
        do {
            try fileSystem.verifyArchiveDirectory(archiveDirectory)
            let receipt = WeChatArchiveReceipt(
                logRelativePath: try Self.validatedWorkspaceRelativePath(
                    for: logURL,
                    archiveRoot: root
                ),
                attachmentRelativePaths: try savedAttachmentNames.map {
                    try Self.validatedWorkspaceRelativePath(
                        for: dateDirectory.appendingPathComponent($0),
                        archiveRoot: root
                    )
                }
            )
            try fileSystem.verifyArchiveDirectory(archiveDirectory)
            return receipt
        } catch {
            for name in savedAttachmentNames {
                fileSystem.removeFileIfPresent(
                    named: name,
                    in: archiveDirectory
                )
            }
            throw WeChatArchiveError.invalidReceiptPath
        }
    }

    static func validatedWorkspaceRelativePath(
        for fileURL: URL,
        archiveRoot: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let root = archiveRoot.standardizedFileURL
        let file = fileURL.standardizedFileURL
        guard isDescendant(file.path, of: root.path) else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        let values = try file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedFile.path, of: resolvedRoot.path) else {
            throw WeChatArchiveError.invalidReceiptPath
        }

        let workspace = root.deletingLastPathComponent().standardizedFileURL
        let prefix = workspace.path.hasSuffix("/")
            ? workspace.path
            : workspace.path + "/"
        guard file.path.hasPrefix(prefix) else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        let relative = String(file.path.dropFirst(prefix.count))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"),
              !components.isEmpty,
              components.first == Substring(root.lastPathComponent),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WeChatArchiveError.invalidReceiptPath
        }
        return relative
    }

    private static func isDescendant(_ candidate: String, of root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(prefix)
    }

    static func sanitizedFilename(_ rawName: String, fallback: String) -> String {
        let slashNormalized = rawName.replacingOccurrences(of: "\\", with: "/")
        var name = (slashNormalized as NSString).lastPathComponent
        name = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7f
        })
        let disallowed = CharacterSet(charactersIn: "/:")
        name = name.components(separatedBy: disallowed).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        if name.isEmpty || name == "." || name == ".." {
            name = fallback
        }

        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        let maximum = 120
        if name.count > maximum {
            if ext.isEmpty {
                name = String(name.prefix(maximum))
            } else {
                let available = max(1, maximum - ext.count - 1)
                name = "\(String(stem.prefix(available))).\(ext)"
            }
        }
        return name
    }

    private func downloadAttachments(_ plans: [AttachmentPlan]) async -> [AttachmentDownload] {
        await withTaskGroup(of: AttachmentDownload.self) { group in
            for plan in plans {
                group.addTask { [transport] in
                    do {
                        return AttachmentDownload(
                            plan: plan,
                            data: .success(try await transport.downloadMedia(plan.descriptor))
                        )
                    } catch {
                        return AttachmentDownload(plan: plan, data: .failure)
                    }
                }
            }
            var results: [AttachmentDownload] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func collectContent(from message: WeChatMessage) -> CollectedContent {
        var collected = CollectedContent()
        var attachmentIndex = 0

        for item in message.items {
            collect(
                type: item.type,
                text: item.textItem,
                image: item.imageItem,
                voice: item.voiceItem,
                file: item.fileItem,
                video: item.videoItem,
                quoted: false,
                attachmentIndex: &attachmentIndex,
                into: &collected
            )
            if let quoted = item.reference?.messageItem {
                collect(
                    type: quoted.type,
                    text: quoted.textItem,
                    image: quoted.imageItem,
                    voice: quoted.voiceItem,
                    file: quoted.fileItem,
                    video: quoted.videoItem,
                    quoted: true,
                    attachmentIndex: &attachmentIndex,
                    into: &collected
                )
            }
        }
        return collected
    }

    private func collect(
        type: Int,
        text: WeChatTextItem?,
        image: WeChatImageItem?,
        voice: WeChatVoiceItem?,
        file: WeChatFileItem?,
        video: WeChatVideoItem?,
        quoted: Bool,
        attachmentIndex: inout Int,
        into collected: inout CollectedContent
    ) {
        switch type {
        case 1:
            let value = text?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return }
            if quoted { collected.quotedParts.append("文字：\(value)") }
            else { collected.textParts.append(value) }
        case 2:
            attachmentIndex += 1
            guard let image else {
                collected.missingAttachmentLines.append("- 图片：未提供可下载媒体")
                return
            }
            let descriptor = descriptor(
                media: image.media,
                directURL: image.url,
                preferredKey: image.aesKey
            )
            appendAttachment(
                descriptor: descriptor,
                index: attachmentIndex,
                originalName: "image.jpg",
                label: quoted ? "引用图片" : "图片",
                into: &collected
            )
        case 3:
            let transcription = voice?.transcription ?? ""
            if !transcription.isEmpty {
                if quoted { collected.quotedParts.append("语音转写：\(transcription)") }
                else { collected.voiceParts.append(transcription) }
            }
            guard let voice, let media = voice.media else {
                if !quoted {
                    collected.missingAttachmentLines.append(
                        transcription.isEmpty
                            ? "- 语音：未收到可用转写或原件"
                            : "- 语音：仅收到语音转写"
                    )
                }
                return
            }
            let descriptor = descriptor(media: media, directURL: media.directURL, preferredKey: voice.aesKey)
            if descriptor.isDownloadable {
                attachmentIndex += 1
                appendAttachment(
                    descriptor: descriptor,
                    index: attachmentIndex,
                    originalName: "voice.silk",
                    label: quoted ? "引用语音" : "语音",
                    into: &collected
                )
            } else if !quoted {
                collected.missingAttachmentLines.append(
                    transcription.isEmpty
                        ? "- 语音：未收到可用转写或原件"
                        : "- 语音：仅收到语音转写"
                )
            }
        case 4:
            attachmentIndex += 1
            guard let file else {
                collected.missingAttachmentLines.append("- 文件：未提供可下载媒体")
                return
            }
            let descriptor = descriptor(media: file.media, directURL: file.url, preferredKey: "")
            appendAttachment(
                descriptor: descriptor,
                index: attachmentIndex,
                originalName: file.fileName.isEmpty ? "file.bin" : file.fileName,
                label: quoted ? "引用文件" : "文件",
                into: &collected
            )
        case 5:
            attachmentIndex += 1
            guard let video else {
                collected.missingAttachmentLines.append("- 视频：未提供可下载媒体")
                return
            }
            let descriptor = descriptor(media: video.media, directURL: video.url, preferredKey: "")
            appendAttachment(
                descriptor: descriptor,
                index: attachmentIndex,
                originalName: video.fileName.isEmpty ? "video.mp4" : video.fileName,
                label: quoted ? "引用视频" : "视频",
                into: &collected
            )
        default:
            if quoted { collected.quotedParts.append("不支持的消息类型 \(type)") }
            else { collected.textParts.append("[不支持的消息类型 \(type)]") }
        }
    }

    private func appendAttachment(
        descriptor: WeChatMediaDescriptor,
        index: Int,
        originalName: String,
        label: String,
        into collected: inout CollectedContent
    ) {
        guard descriptor.isDownloadable else {
            collected.missingAttachmentLines.append("- \(label)：未提供可下载媒体")
            return
        }
        collected.attachments.append(
            AttachmentPlan(
                index: index,
                originalName: originalName,
                label: label,
                descriptor: descriptor
            )
        )
    }

    private func descriptor(
        media: WeChatMedia?,
        directURL: String,
        preferredKey: String
    ) -> WeChatMediaDescriptor {
        WeChatMediaDescriptor(
            directURL: media?.directURL.isEmpty == false ? media!.directURL : directURL,
            encryptQueryParameter: media?.encryptQueryParameter ?? "",
            aesKey: preferredKey.isEmpty ? (media?.aesKey ?? "") : preferredKey
        )
    }

    private func writeUniqueAttachment(
        _ data: Data,
        in directory: WeChatArchiveDirectoryHandle,
        prefix: String,
        index: Int,
        originalName: String
    ) throws -> String {
        let fallback: String
        let lower = originalName.lowercased()
        if lower.contains("image") { fallback = "image.jpg" }
        else if lower.contains("video") { fallback = "video.mp4" }
        else if lower.contains("voice") { fallback = "voice.silk" }
        else { fallback = "file.bin" }

        let clean = Self.sanitizedFilename(originalName, fallback: fallback)
        let base = "\(prefix)_\(String(format: "%02d", index))_\(clean)"
        var candidate = base
        var collision = 2
        while true {
            if try fileSystem.writeExclusive(
                data,
                named: candidate,
                in: directory
            ) {
                return candidate
            }
            let ns = base as NSString
            let ext = ns.pathExtension
            let stem = ns.deletingPathExtension
            candidate = ext.isEmpty
                ? "\(stem)_\(collision)"
                : "\(stem)_\(collision).\(ext)"
            collision += 1
        }
    }

    private func makeMarkdown(
        message: WeChatMessage,
        headingTime: String,
        textParts: [String],
        voiceParts: [String],
        quotedParts: [String],
        attachmentLines: [String]
    ) -> String {
        var lines = [
            "## \(headingTime)",
            "",
            "- 会话：\(message.groupID.isEmpty ? "私聊" : "群聊")",
            "- 发送者：\(escapeInline(message.fromUserID))"
        ]
        if !textParts.isEmpty {
            lines += ["", "**文字**", ""]
            lines += quote(textParts.joined(separator: "\n"))
        }
        if !voiceParts.isEmpty {
            lines += ["", "**语音转写**", ""]
            lines += quote(voiceParts.joined(separator: "\n"))
        }
        if !quotedParts.isEmpty {
            lines += ["", "**引用消息**", ""]
            lines += quote(quotedParts.joined(separator: "\n"))
        }
        if !attachmentLines.isEmpty {
            lines += ["", "**附件**", ""]
            lines += attachmentLines
        }
        lines += ["", ""]
        return lines.joined(separator: "\n")
    }

    private func quote(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { "> \($0)" }
    }

    private func escapeInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private func escapeLinkText(_ value: String) -> String {
        value.replacingOccurrences(of: "]", with: "\\]")
    }

    private func encodeLink(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func format(_ date: Date, pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private struct CollectedContent {
        var textParts: [String] = []
        var voiceParts: [String] = []
        var quotedParts: [String] = []
        var attachments: [AttachmentPlan] = []
        var missingAttachmentLines: [String] = []
    }

    private struct AttachmentPlan: Sendable {
        let index: Int
        let originalName: String
        let label: String
        let descriptor: WeChatMediaDescriptor
    }

    private struct AttachmentDownload: Sendable {
        enum Result: Sendable {
            case success(Data)
            case failure
        }

        let plan: AttachmentPlan
        let data: Result
    }
}
