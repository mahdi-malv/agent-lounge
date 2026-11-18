import Foundation

nonisolated struct HTTPRequest: Sendable {
    var method: String
    /// Path without the query string.
    var path: String
    /// Header names in lower case.
    var headers: [String: String]
    var body: Data
}

nonisolated struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String?
    var body: Data

    init(status: Int, contentType: String? = nil, body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static let noContent = HTTPResponse(status: 204)
    static let accepted = HTTPResponse(status: 202)
    static let badRequest = HTTPResponse(status: 400)
    static let notFound = HTTPResponse(status: 404)
    static let tooLarge = HTTPResponse(status: 413)

    static func text(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func json(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: data)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 403: "Forbidden"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        default: "Status"
        }
    }
}

/// Minimal HTTP/1.1 request parser: request line, headers, `Content-Length` body.
/// No chunked encoding, no keep-alive (the hook sends one request per connection).
nonisolated enum HTTPRequestParser {
    enum Result: Sendable {
        case incomplete
        case complete(HTTPRequest)
        case invalid(String)
        case tooLarge
    }

    static let maxHeaderBytes = 16 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data, maxBodyBytes: Int) -> Result {
        guard let terminator = buffer.firstRange(of: headerTerminator) else {
            return buffer.count > maxHeaderBytes ? .invalid("Header too large") : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<terminator.lowerBound], encoding: .utf8) else {
            return .invalid("Header is not UTF-8")
        }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid("Bad request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("Bad header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { return .invalid("Bad Content-Length") }
            length = parsed
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .tooLarge }

        let bodyStart = terminator.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: Data(body)))
    }
}
