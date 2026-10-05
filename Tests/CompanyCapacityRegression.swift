import Foundation

private final class CompanyMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, bytes) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct CompanyCapacityRegression {
    static func main() async throws {
        var settings = PoolSettings.empty
        settings.source = .companyGateway
        settings.baseURL = "https://synthetic.example"
        settings.companyProvider = "claude"
        settings.companyModel = "claude-sonnet-fixture"
        settings.managementKey = "must-never-leave-device"
        settings.xiaomiCookie = "must-never-be-used"
        settings.xiaomiTokenPlanEnabled = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanyMockProtocol.self]
        let mock = URLSession(configuration: configuration)
        let now = Date().timeIntervalSince1970
        let fixture = """
        {"member_id":"member-a","provider":"claude","model":"claude-sonnet-fixture","mode":"shadow","advisory":true,"accounts":[
        {"id":"owned-1","ownership_tier":"own","priority":1,"reason":"quota_ranked","freshness":"fresh","observed_at":\(now),"headroom":0.2,"scoreable":true,"limiting_reset":\(now+600),"windows":[{"id":"five_hour","resource":"included","duration_seconds":18000,"remaining_fraction":0.8,"reset_at":\(now+600),"observed_at":\(now)},{"id":"seven_day","resource":"included","remaining_fraction":0.2,"reset_at":\(now+700),"observed_at":\(now)}]},
        {"id":"shared-1","ownership_tier":"shared","freshness":"unknown","scoreable":false,"windows":[]}
        ]}
        """
        var calls = 0
        CompanyMockProtocol.handler = { request in
            calls += 1
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/api/v1/capacity")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "X-Management-Key") == nil)
            precondition(request.httpBody == nil)
            precondition(!(request.allHTTPHeaderFields ?? [:]).values.contains(where: { $0.contains("must-never") }))
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "provider", value: "claude")))
            precondition(query.contains(URLQueryItem(name: "model", value: "claude-sonnet-fixture")))
            return (200, Data(fixture.utf8))
        }
        let client = PoolAPIClient(settings: settings, session: mock, companySession: mock)
        let summary = await PoolSummaryService(client: client).loadSummary()
        precondition(calls == 1, "company mode must not call auth-files, api-call or third parties")
        let capacity = summary.companyCapacity!
        precondition(capacity.personal.count == 1 && capacity.shared.count == 1 && capacity.accounts.count == 2)
        precondition(capacity.personal[0].usableHeadroom(at: Date(timeIntervalSince1970: now)) == 0.2)
        precondition(capacity.shared[0].usableHeadroom(at: Date()) == nil)
        precondition(capacity.personal[0].usableHeadroom(at: Date(timeIntervalSince1970: now+301)) == nil)
        precondition(capacity.personal[0].usableHeadroom(at: Date(timeIntervalSince1970: now+601)) == nil)
        let resetWindow = CompanyCapacityWindow(id: "short", resource: "included", duration_seconds: 60, remaining_fraction: 0.9, reset_at: now-1, observed_at: now)
        precondition(resetWindow.usableRemaining(at: Date(timeIntervalSince1970: now)) == nil, "passed reset never refills quota")
        let futureWindow = CompanyCapacityWindow(id: "short", resource: "included", duration_seconds: 60, remaining_fraction: 0.9, reset_at: now+100, observed_at: now+31)
        precondition(futureWindow.usableRemaining(at: Date(timeIntervalSince1970: now)) == nil)
        let partial = try JSONDecoder().decode(CompanyCapacity.self, from: Data(fixture.replacingOccurrences(of: "\"freshness\":\"fresh\"", with: "\"freshness\":\"partial\"").utf8))
        precondition(partial.personal[0].usableHeadroom(at: Date()) == nil)
        CompanyMockProtocol.handler = { _ in (200, Data(fixture.replacingOccurrences(of: "member-a", with: "member-b").replacingOccurrences(of: "owned-1", with: "owned-2").utf8)) }
        let second = await PoolSummaryService(client: client).loadSummary()
        precondition(second.companyCapacity?.member_id == "member-b")
        precondition(second.companyCapacity?.personal[0].id == "owned-2")
        CompanyMockProtocol.handler = { _ in (403, Data("secret raw server detail".utf8)) }
        let denied = await PoolSummaryService(client: client).loadSummary()
        precondition(denied.companyCapacity == nil && denied.errorMessage!.contains("Tailscale"))
        precondition(!denied.errorMessage!.contains("secret raw"))
        CompanyMockProtocol.handler = { _ in (200, Data(fixture.replacingOccurrences(of: "\"ownership_tier\":\"own\"", with: "\"ownership_tier\":\"other\"").utf8)) }
        let invalid = await PoolSummaryService(client: client).loadSummary()
        precondition(invalid.companyCapacity == nil)
        var unsafe = settings
        unsafe.baseURL = "http://synthetic.example"
        do { _ = try PoolAPIClient(settings: unsafe).companyCapacityRequest(); fatalError("HTTP accepted") } catch {}
        let oldSettings = try JSONDecoder().decode(PoolSettings.self, from: Data("{}".utf8))
        precondition(oldSettings.source == .standalone, "preserve standalone setting migration")
        print("PASS company passive request, owned/shared buckets, limiting headroom, stale/reset unknown, identity replacement, denied access, HTTPS and settings migration")
    }
}
