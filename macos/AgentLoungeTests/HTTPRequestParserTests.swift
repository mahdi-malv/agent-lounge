import Foundation
import Testing
@testable import AgentLounge

struct HTTPRequestParserTests {
    private func request(body: String, contentLength: Int? = nil) -> Data {
        let length = contentLength ?? body.utf8.count
        return Data("POST /events?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(length)\r\n\r\n\(body)".utf8)
    }

    @Test func parsesCompleteRequest() throws {
        guard case .complete(let parsed) = HTTPRequestParser.parse(request(body: "{\"a\":1}"), maxBodyBytes: 1024) else {
            Issue.record("Expected complete request")
            return
        }
        #expect(parsed.method == "POST")
        #expect(parsed.path == "/events")
        #expect(parsed.headers["host"] == "127.0.0.1")
        #expect(String(decoding: parsed.body, as: UTF8.self) == "{\"a\":1}")
    }

    @Test func waitsForTheWholeBody() {
        let data = request(body: "{\"a\"", contentLength: 7)
        guard case .incomplete = HTTPRequestParser.parse(data, maxBodyBytes: 1024) else {
            Issue.record("Expected incomplete")
            return
        }
    }

    @Test func waitsForTheHeaderEnd() {
        guard case .incomplete = HTTPRequestParser.parse(Data("GET /health HTTP/1.1\r\nHost: x".utf8), maxBodyBytes: 1024) else {
            Issue.record("Expected incomplete")
            return
        }
    }

    @Test func parsesRequestSplitAtAnyByte() {
        let full = request(body: "{\"hello\":\"world\"}")
        for split in 1..<full.count {
            if case .complete = HTTPRequestParser.parse(full.prefix(split), maxBodyBytes: 1024) {
                Issue.record("Complete too early at byte \(split)")
            }
        }
        guard case .complete = HTTPRequestParser.parse(full, maxBodyBytes: 1024) else {
            Issue.record("Expected complete")
            return
        }
    }

    @Test func rejectsTooLargeBody() {
        guard case .tooLarge = HTTPRequestParser.parse(request(body: "", contentLength: 2048), maxBodyBytes: 1024) else {
            Issue.record("Expected tooLarge")
            return
        }
    }

    @Test func rejectsGarbage() {
        guard case .invalid = HTTPRequestParser.parse(Data("hello\r\n\r\n".utf8), maxBodyBytes: 1024) else {
            Issue.record("Expected invalid")
            return
        }
    }

    @Test func serializesResponse() {
        let text = String(decoding: HTTPResponse.text("ok").serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\nok"))
    }
}
