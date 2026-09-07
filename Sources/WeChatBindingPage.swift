import AppKit
import CoreImage
import Foundation

enum WeChatBindingPageStatus: Equatable {
    case waiting
    case scanned
    case success
    case expired
    case failed(String)

    var title: String {
        switch self {
        case .waiting: return "等待扫码"
        case .scanned: return "已扫码，请在微信中确认"
        case .success: return "微信绑定成功"
        case .expired: return "二维码已过期"
        case .failed: return "绑定失败"
        }
    }

    var detail: String {
        switch self {
        case .waiting:
            return "请使用微信扫描二维码。页面会自动更新绑定状态。"
        case .scanned:
            return "请回到微信完成确认。"
        case .success:
            return "可以关闭此页面，Tocode 已开始接收并归档新消息。"
        case .expired:
            return "请回到 Tocode，再次点击“绑定微信”。"
        case .failed(let message):
            return message
        }
    }

    var shouldRefresh: Bool {
        self == .waiting || self == .scanned
    }
}

protocol WeChatBindingPageWriting {
    func prepare(qrCode: WeChatQRCode) throws -> URL
    func update(_ status: WeChatBindingPageStatus) throws
}

final class WeChatBindingPageWriter: WeChatBindingPageWriting {
    private let directory: URL
    private let fileManager: FileManager
    private let context = CIContext()

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            self.directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("com.tocode.app", isDirectory: true)
                .appendingPathComponent("wechat-binding", isDirectory: true)
        }
    }

    func prepare(qrCode: WeChatQRCode) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let pngURL = directory.appendingPathComponent("qrcode.png")
        let htmlURL = directory.appendingPathComponent("index.html")
        try makeQRCodePNG(from: qrCode.scanURLString).write(to: pngURL, options: .atomic)
        try writeHTML(status: .waiting)
        return htmlURL
    }

    func update(_ status: WeChatBindingPageStatus) throws {
        try writeHTML(status: status)
    }

    private func makeQRCodePNG(from value: String) throws -> Data {
        guard let data = value.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw WeChatTransportError.invalidResponse
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = context.createCGImage(image, from: image.extent) else {
            throw WeChatTransportError.invalidResponse
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw WeChatTransportError.invalidResponse
        }
        return png
    }

    private func writeHTML(status: WeChatBindingPageStatus) throws {
        let refresh = status.shouldRefresh ? "<meta http-equiv=\"refresh\" content=\"2\">" : ""
        let qrVisibility = status == .success ? "display:none" : "display:block"
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          \(refresh)
          <title>绑定微信 - Tocode</title>
          <style>
            :root { color-scheme: light dark; }
            body { margin:0; min-height:100vh; display:grid; place-items:center; font-family:-apple-system,BlinkMacSystemFont,sans-serif; background:#f4f5f7; color:#17191c; }
            main { width:min(88vw,420px); text-align:center; padding:42px 24px; }
            img { width:260px; height:260px; margin:24px auto; image-rendering:pixelated; \(qrVisibility); }
            h1 { font-size:26px; font-weight:650; margin:0 0 10px; }
            p { font-size:15px; line-height:1.6; color:#5a6068; margin:0; }
            .brand { font-size:13px; color:#16764a; margin-bottom:18px; }
            @media (prefers-color-scheme:dark) {
              body { background:#17191c; color:#f5f6f7; }
              p { color:#abb1b8; }
              img { background:white; padding:12px; box-sizing:border-box; }
            }
          </style>
        </head>
        <body>
          <main>
            <div class="brand">Tocode · 微信关联</div>
            <h1>\(escape(status.title))</h1>
            <p>\(escape(status.detail))</p>
            <img src="qrcode.png" alt="微信绑定二维码">
          </main>
        </body>
        </html>
        """
        try Data(html.utf8).write(
            to: directory.appendingPathComponent("index.html"),
            options: .atomic
        )
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

protocol WeChatURLOpening {
    @discardableResult
    func open(_ url: URL) -> Bool
}

struct WorkspaceWeChatURLOpener: WeChatURLOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
