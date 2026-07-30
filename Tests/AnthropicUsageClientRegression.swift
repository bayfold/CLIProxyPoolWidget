import Foundation

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: PoolAPIError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
enum AnthropicUsageClientRegression {
    static func main() async {
        do {
            try await testAnthropicAPICallEnvelope()
            print("Anthropic usage client regression tests passed")
        } catch {
            fputs("FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testAnthropicAPICallEnvelope() async throws {
        var settings = PoolSettings.empty
        settings.baseURL = "https://pool.example"
        settings.managementKey = "management-secret"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            MockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        MockURLProtocol.handler = { request in
            expect(request.url?.path == "/v0/management/api-call", "management api-call path")
            expect(request.httpMethod == "POST", "management api-call method")
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer management-secret", "management key header")

            let body = try requestBodyData(request)
            let payload = try unwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any],
                "JSON payload"
            )
            expect(payload["auth_index"] as? String == "claude-oauth-1", "Claude auth index")
            expect(payload["method"] as? String == "GET", "Claude upstream method")
            expect(
                payload["url"] as? String == "https://api.anthropic.com/api/oauth/usage",
                "Claude usage endpoint"
            )

            let headers = try unwrap(payload["header"] as? [String: String], "upstream headers")
            expect(headers["Authorization"] == "Bearer $TOKEN$", "token placeholder remains server-side")
            expect(headers["anthropic-beta"] == "oauth-2025-04-20", "Claude OAuth beta header")
            expect(headers["Content-Type"] == "application/json", "Claude content type")

            let usageBody = #"{"five_hour":{"utilization":23.5,"resets_at":null},"seven_day":{"utilization":41.2,"resets_at":null}}"#
            let envelope = try JSONSerialization.data(withJSONObject: [
                "status_code": 200,
                "header": [:],
                "body": usageBody
            ])
            let response = try unwrap(
                HTTPURLResponse(
                    url: try unwrap(request.url, "request URL"),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                ),
                "HTTP response"
            )
            return (response, envelope)
        }

        let client = PoolAPIClient(settings: settings, session: session)
        let snapshot = try await client.fetchAnthropicUsage(authIndex: "claude-oauth-1")
        expect(snapshot.primaryRemainingPercent == 76.5, "Claude 5h envelope parsing")
        expect(snapshot.weeklyRemainingPercent == 58.8, "Claude Week envelope parsing")
        expect(snapshot.planType == "claude", "Claude plan family")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw NSError(domain: "AnthropicUsageClientRegression", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing \(message)"
            ])
        }
        return value
    }

    private static func requestBodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw NSError(domain: "AnthropicUsageClientRegression", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Missing request body"
            ])
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? PoolAPIError.invalidResponse
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
