import Foundation

struct ModelRelayHTTPRequest: Equatable {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let body: Data

    var bearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty else {
            return nil
        }
        return parts[1]
    }
}

enum ModelRelayHTTPParseError: Error, Equatable {
    case headersTooLarge
    case bodyTooLarge
    case malformedRequest
    case unsupportedTransferEncoding
}

enum ModelRelayHTTPParser {
    static let maximumHeaderBytes = 64 * 1024
    static let maximumBodyBytes = 64 * 1024 * 1024
    private static let headerDelimiter = Data("\r\n\r\n".utf8)
    private static let lineDelimiter = Data("\r\n".utf8)

    static func parse(_ data: Data) throws -> (request: ModelRelayHTTPRequest, consumed: Int)? {
        guard let headerRange = data.range(of: headerDelimiter) else {
            if data.count > maximumHeaderBytes {
                throw ModelRelayHTTPParseError.headersTooLarge
            }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw ModelRelayHTTPParseError.malformedRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ModelRelayHTTPParseError.malformedRequest
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
            throw ModelRelayHTTPParseError.malformedRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw ModelRelayHTTPParseError.malformedRequest
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw ModelRelayHTTPParseError.malformedRequest
            }
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        let bodyStart = headerRange.upperBound
        let bodyData = data[bodyStart...]
        let body: Data
        let consumedBodyBytes: Int
        if let transferEncoding = headers["transfer-encoding"] {
            let encodings = transferEncoding.lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard encodings == ["chunked"], headers["content-length"] == nil else {
                throw ModelRelayHTTPParseError.unsupportedTransferEncoding
            }
            guard bodyData.count <= maximumBodyBytes + maximumHeaderBytes else {
                throw ModelRelayHTTPParseError.bodyTooLarge
            }
            guard let chunked = try parseChunked(Data(bodyData)) else { return nil }
            body = chunked.body
            consumedBodyBytes = chunked.consumed
        } else {
            let length: Int
            if let rawLength = headers["content-length"] {
                guard let parsed = Int(rawLength), parsed >= 0 else {
                    throw ModelRelayHTTPParseError.malformedRequest
                }
                length = parsed
            } else {
                length = 0
            }
            guard length <= maximumBodyBytes else {
                throw ModelRelayHTTPParseError.bodyTooLarge
            }
            guard bodyData.count >= length else { return nil }
            body = Data(bodyData.prefix(length))
            consumedBodyBytes = length
        }
        return (
            ModelRelayHTTPRequest(
                method: String(requestParts[0]).uppercased(),
                target: String(requestParts[1]),
                version: String(requestParts[2]),
                headers: headers,
                body: body
            ),
            bodyStart + consumedBodyBytes
        )
    }

    private static func parseChunked(_ data: Data) throws -> (body: Data, consumed: Int)? {
        var cursor = data.startIndex
        var decoded = Data()
        while true {
            guard let lineRange = data.range(of: lineDelimiter, in: cursor..<data.endIndex) else {
                return nil
            }
            guard let line = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii) else {
                throw ModelRelayHTTPParseError.malformedRequest
            }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else {
                throw ModelRelayHTTPParseError.malformedRequest
            }
            cursor = lineRange.upperBound
            if size == 0 {
                guard data.count >= cursor + 2,
                      data[cursor..<cursor + 2] == lineDelimiter else {
                    return nil
                }
                return (decoded, cursor + 2)
            }
            guard size <= maximumBodyBytes - decoded.count else {
                throw ModelRelayHTTPParseError.bodyTooLarge
            }
            guard data.count >= cursor + size + 2 else { return nil }
            decoded.append(data[cursor..<cursor + size])
            cursor += size
            guard data[cursor..<cursor + 2] == lineDelimiter else {
                throw ModelRelayHTTPParseError.malformedRequest
            }
            cursor += 2
        }
    }
}

enum ModelRelayHTTPResponse {
    static func fixed(
        status: Int,
        reason: String,
        body: Data = Data(),
        contentType: String = "application/json"
    ) -> Data {
        var output = Data(
            "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8
        )
        output.append(body)
        return output
    }

    static func json(status: Int, reason: String, object: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return fixed(status: status, reason: reason, body: body)
    }

    static func error(status: Int, reason: String, message: String) -> Data {
        json(
            status: status,
            reason: reason,
            object: [
                "error": [
                    "message": message,
                    "type": "tocode_relay_error"
                ]
            ]
        )
    }

    static func chunkedHeader(
        status: Int,
        reason: String,
        headers: [AnyHashable: Any]
    ) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        let forbidden = Set([
            "connection", "content-length", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"
        ])
        for (rawName, rawValue) in headers {
            let name = String(describing: rawName)
            guard !forbidden.contains(name.lowercased()) else { continue }
            lines.append("\(name): \(String(describing: rawValue))")
        }
        lines.append("Transfer-Encoding: chunked")
        lines.append("Connection: close")
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func chunk(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(String(data.count, radix: 16).utf8)
        output.append(Data("\r\n".utf8))
        output.append(data)
        output.append(Data("\r\n".utf8))
        return output
    }

    static let finalChunk = Data("0\r\n\r\n".utf8)
}
