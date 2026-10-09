import Foundation
import XCTest
@testable import EgoKit

final class HTTPWireTests: XCTestCase {
    let url = URL(string: "https://8.8.8.8:47398/rpc")!

    func testARequestIsWrittenAsHTTP11() {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"id":1}"#.utf8)
        let text = String(decoding: HTTPWire.encode(request, host: "8.8.8.8", port: 47398), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("POST /rpc HTTP/1.1\r\nHost: 8.8.8.8:47398\r\nConnection: close\r\nContent-Length: 8\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"id\":1}"))
    }

    func testAResponseWithContentLength() throws {
        let raw = Data("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\n\r\n{\"ok\":true}".utf8)
        let (body, response) = try HTTPWire.parse(raw, url: url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"ok":true}"#)
    }

    func testAChunkedResponse() throws {
        let raw = Data("HTTP/1.1 429 Too Many Requests\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n".utf8)
        let (body, response) = try HTTPWire.parse(raw, url: url)
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"a":1}"#)
    }

    func testCutOffOrGarbledResponsesAreRefused() {
        for text in [
            "HTTP/1.1 200 OK\r\ncontent-length: 50\r\n\r\n{}",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n{}",
            "SSH-2.0-OpenSSH\r\n\r\n",
            "HTTP/1.1 200 OK",
        ] {
            XCTAssertThrowsError(try HTTPWire.parse(Data(text.utf8), url: url), text)
        }
    }
}
