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
@main struct CompanySubscriptionsRegression {
    static func main() async throws {
        var settings = PoolSettings.empty
        settings.source = .companyGateway
        settings.baseURL = "https://synthetic.example"
        settings.managementKey = "must-never-leave-device"
        settings.xiaomiCookie = "must-never-be-used"
        settings.xiaomiTokenPlanEnabled = true
        var keyless = settings
        keyless.managementKey = ""
        precondition(keyless.isConfigured, "company overview needs no key or model")
        _ = try PoolAPIClient(settings: keyless).companySubscriptionsRequest()
        var incomplete = keyless
        incomplete.baseURL = " "
        precondition(!incomplete.isConfigured)
        precondition(incomplete.configurationPrompt == L10n.text(
            "Enter your company-gateway HTTPS URL over Tailscale.",
            "请填写通过 Tailscale 访问的 company-gateway HTTPS 地址。"
        ))
        var standalone = keyless
        standalone.source = .standalone
        precondition(!standalone.isConfigured, "standalone still requires a key")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanyMockProtocol.self]
        let mock = URLSession(configuration: configuration)
        let now = Date().timeIntervalSince1970
        let fixture = """
        {"member_id":"member-a","accounts":[
        {"id":"owned-1","provider":"claude","label":"Claude subscription","ownership_tier":"own","freshness":"fresh","observed_at":\(now),"windows":[{"id":"five_hour","resource":"included","duration_seconds":18000,"remaining_fraction":0.8,"reset_at":\(now+600),"observed_at":\(now)},{"id":"seven_day","resource":"included","remaining_fraction":0.2,"reset_at":\(now+700),"observed_at":\(now)}]},
        {"id":"shared-1","provider":"codex","label":"Shared Codex","ownership_tier":"shared","freshness":"unknown","windows":[]}
        ]}
        """
        var calls = 0
        CompanyMockProtocol.handler = { request in
            calls += 1
            precondition(request.httpMethod == "GET")
            precondition(request.url?.path == "/api/v1/subscriptions")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "X-Management-Key") == nil)
            precondition(request.httpBody == nil)
            precondition(!(request.allHTTPHeaderFields ?? [:]).values.contains(where: { $0.contains("must-never") }))
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
            precondition(request.url?.query == nil, "overview must not request a model or provider")
            return (200, Data(fixture.utf8))
        }
        let client = PoolAPIClient(settings: settings, session: mock, companySession: mock)
        let summary = await PoolSummaryService(client: client).loadSummary()
        precondition(calls == 1, "company mode must not call auth-files, api-call or third parties")
        let capacity = summary.companySubscriptions!
        precondition(capacity.personal.count == 1 && capacity.shared.count == 1 && capacity.accounts.count == 2)
        precondition(capacity.personal[0].usableRemaining(capacity.personal[0].windows[1], at: Date(timeIntervalSince1970: now)) == 0.2)
        precondition(capacity.shared[0].windows.first.flatMap { capacity.shared[0].usableRemaining($0, at: Date()) } == nil)
        precondition(capacity.personal[0].usableRemaining(capacity.personal[0].windows[1], at: Date(timeIntervalSince1970: now+301)) == nil)
        precondition(capacity.personal[0].usableRemaining(capacity.personal[0].windows[1], at: Date(timeIntervalSince1970: now+601)) == nil)
        precondition(capacity.providers == ["claude", "codex"])
        let resetWindow = SubscriptionQuotaWindow(id: "short", resource: "included", duration_seconds: 60, remaining_fraction: 0.9, reset_at: now-1, observed_at: now)
        precondition(resetWindow.usableRemaining(at: Date(timeIntervalSince1970: now)) == nil, "passed reset never refills quota")
        let futureWindow = SubscriptionQuotaWindow(id: "short", resource: "included", duration_seconds: 60, remaining_fraction: 0.9, reset_at: now+100, observed_at: now+31)
        precondition(futureWindow.usableRemaining(at: Date(timeIntervalSince1970: now)) == nil)
        let partial = try JSONDecoder().decode(CompanySubscriptions.self, from: Data(fixture.replacingOccurrences(of: "\"freshness\":\"fresh\"", with: "\"freshness\":\"partial\"").utf8))
        precondition(partial.personal[0].usableRemaining(partial.personal[0].windows[0], at: Date()) == nil)
        CompanyMockProtocol.handler = { _ in (200, Data(fixture.replacingOccurrences(of: "member-a", with: "member-b").replacingOccurrences(of: "owned-1", with: "owned-2").utf8)) }
        let second = await PoolSummaryService(client: client).loadSummary()
        precondition(second.companySubscriptions?.member_id == "member-b")
        precondition(second.companySubscriptions?.personal[0].id == "owned-2")
        CompanyMockProtocol.handler = { _ in (403, Data("secret raw server detail".utf8)) }
        let denied = await PoolSummaryService(client: client).loadSummary()
        precondition(denied.companySubscriptions == nil && denied.errorMessage!.contains("Tailscale"))
        precondition(!denied.errorMessage!.contains("secret raw"))
        CompanyMockProtocol.handler = { _ in (200, Data(fixture.replacingOccurrences(of: "\"ownership_tier\":\"own\"", with: "\"ownership_tier\":\"other\"").utf8)) }
        let invalid = await PoolSummaryService(client: client).loadSummary()
        precondition(invalid.companySubscriptions == nil)
        var unsafe = settings
        unsafe.baseURL = "http://synthetic.example"
        do { _ = try PoolAPIClient(settings: unsafe).companySubscriptionsRequest(); fatalError("HTTP accepted") } catch {}
        let oldSettings = try JSONDecoder().decode(PoolSettings.self, from: Data("{}".utf8))
        precondition(oldSettings.source == .standalone, "preserve standalone setting migration")
        print("PASS company model-free subscriptions request, owned/shared buckets, per-window quota, stale/reset unknown, identity replacement, denied access, HTTPS and settings migration")
    }
}
