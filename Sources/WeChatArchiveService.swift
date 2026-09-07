import Foundation

enum WeChatArchiveError: Error, Equatable {
    case createDirectory
    case appendLog
}

protocol WeChatFileSystem {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func append(_ data: Data, to url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItemIfPresent(at url: URL)
}

struct SystemWeChatFileSystem: WeChatFileSystem {
    private let manager = FileManager.default

    func createDirectory(at url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func fileExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func append(_ data: Data, to url: URL) throws {
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil) else {
                throw WeChatArchiveError.appendLog
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try manager.moveItem(at: source, to: destination)
    }

    func removeItemIfPresent(at url: URL) {
        try? manager.removeItem(at: url)
    }
}

protocol WeChatArchiving: AnyObject {
    func archive(_ message: WeChatMessage, receivedAt: Date) async throws
}

actor WeChatArchiveService: WeChatArchiving {
    static let defaultRoot = URL(fileURLWithPath: "/Users/admin/Documents/wechat", isDirectory: true)

    private let root: URL
    private let transport: WeChatILinkTransporting
    private let fileSystem: WeChatFileSystem
    private let calendarProvider: () -> Calendar

    init(
        root: URL = defaultRoot,
        transport: WeChatILinkTransporting,
        fileSystem: WeChatFileSystem = SystemWeChatFileSystem(),
        calendarProvider: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }
    ) {
        self.root = root
        self.transport = transport
        self.fileSystem = fileSystem
        self.calendarProvider = calendarProvider
    }

    func archive(_ message: WeChatMessage, receivedAt: Date) async throws {
        let calendar = calendarProvider()
        let dateName = format(receivedAt, pattern: "yyMMdd", calendar: calendar)
        let timeName = format(receivedAt, pattern: "HHmmss_SSS", calendar: calendar)
        let headingTime = format(receivedAt, pattern: "HH:mm:ss", calendar: calendar)
        let dateDirectory = root.appendingPathComponent(dateName, isDirectory: true)

        do {
            try fileSystem.createDirectory(at: dateDirectory)
        } catch {
            throw WeChatArchiveError.createDirectory
        }

        let content = collectContent(from: message)
        let downloaded = await downloadAttachments(content.attachments)
        var attachmentLines = content.missingAttachmentLines
        var savedAttachments: [URL] = []

        for result in downloaded.sorted(by: { $0.plan.index < $1.plan.index }) {
            switch result.data {
            case .success(let data):
                do {
                    let finalURL = uniqueAttachmentURL(
                        in: dateDirectory,
                        prefix: timeName,
                        index: result.plan.index,
                        originalName: result.plan.originalName
                    )
                    let partURL = dateDirectory.appendingPathComponent(
                        ".\(finalURL.lastPathComponent).\(UUID().uuidString).part"
                    )
                    defer { fileSystem.removeItemIfPresent(at: partURL) }
                    try fileSystem.write(data, to: partURL)
                    try fileSystem.moveItem(at: partURL, to: finalURL)
                    savedAttachments.append(finalURL)
                    attachmentLines.append(
                        "- \(result.plan.label)：[\(escapeLinkText(finalURL.lastPathComponent))](\(encodeLink(finalURL.lastPathComponent)))"
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
        let logURL = dateDirectory.appendingPathComponent("wechat\(dateName).md")
        do {
            try fileSystem.append(Data(markdown.utf8), to: logURL)
        } catch {
            for url in savedAttachments {
                fileSystem.removeItemIfPresent(at: url)
            }
            throw WeChatArchiveError.appendLog
        }
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

    private func uniqueAttachmentURL(
        in directory: URL,
        prefix: String,
        index: Int,
        originalName: String
    ) -> URL {
        let fallback: String
        let lower = originalName.lowercased()
        if lower.contains("image") { fallback = "image.jpg" }
        else if lower.contains("video") { fallback = "video.mp4" }
        else if lower.contains("voice") { fallback = "voice.silk" }
        else { fallback = "file.bin" }

        let clean = Self.sanitizedFilename(originalName, fallback: fallback)
        let base = "\(prefix)_\(String(format: "%02d", index))_\(clean)"
        var candidate = directory.appendingPathComponent(base)
        var collision = 2
        while fileSystem.fileExists(at: candidate) {
            let ns = base as NSString
            let ext = ns.pathExtension
            let stem = ns.deletingPathExtension
            let name = ext.isEmpty ? "\(stem)_\(collision)" : "\(stem)_\(collision).\(ext)"
            candidate = directory.appendingPathComponent(name)
            collision += 1
        }
        return candidate
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
