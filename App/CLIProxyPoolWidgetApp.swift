import Combine
import SwiftUI
import WidgetKit

@main
struct CLIProxyPoolWidgetApp: App {
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var quotaPrintManager: QuotaPrintManager
    @StateObject private var refreshCoordinator: PoolRefreshCoordinator

    init() {
        let settingsStore = SettingsStore.shared
        let quotaPrintManager = QuotaPrintManager()
        _settingsStore = StateObject(wrappedValue: settingsStore)
        _quotaPrintManager = StateObject(wrappedValue: quotaPrintManager)
        _refreshCoordinator = StateObject(
            wrappedValue: PoolRefreshCoordinator(
                settingsStore: settingsStore,
                quotaPrintManager: quotaPrintManager
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settingsStore)
                .environmentObject(quotaPrintManager)
                .environmentObject(refreshCoordinator)
                .frame(minWidth: 620, minHeight: 520)
        }
        .windowStyle(.titleBar)
        MenuBarExtra("Company subscriptions", systemImage: "chart.bar", isInserted: .constant(settingsStore.settings.source == .companyGateway)) {
            if let capacity = refreshCoordinator.summary.companyCapacity {
                CompanySubscriptionsView(capacity: capacity, compact: true).frame(width: 360)
            } else {
                Text(refreshCoordinator.summary.errorMessage ?? "Open the app to configure company-gateway.")
            }
            Button("Refresh") { Task { await refreshCoordinator.refresh() } }
            Divider()
            Link("Documentation", destination: URL(string: "https://github.com/bayfold/Cli-Proxy-API-Management-Center/blob/company/docs/company-gateway.md")!)
            Link("GitHub Actions OIDC spec", destination: URL(string: "https://github.com/bayfold/Cli-Proxy-API-Management-Center/blob/company/docs/ci-oidc.md")!)
            Link("Management UI source", destination: URL(string: "https://github.com/bayfold/Cli-Proxy-API-Management-Center")!)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class PoolRefreshCoordinator: ObservableObject {
    @Published var summary: PoolSummary
    @Published var isLoading = false
    @Published var refreshInFlight = false
    @Published var nextRefreshAt: Date?
    @Published var lastMessage: String?

    private let settingsStore: SettingsStore
    private let quotaPrintManager: QuotaPrintManager
    private var refreshTimer: Timer?
    private var settingsSubscription: AnyCancellable?
    private var loadTask: Task<PoolSummary, Never>?
    private var settingsGeneration = 0
    private var previousSettings: PoolSettings?
    private var backgroundActivity: NSObjectProtocol?

    init(settingsStore: SettingsStore, quotaPrintManager: QuotaPrintManager) {
        self.settingsStore = settingsStore
        self.quotaPrintManager = quotaPrintManager
        self.summary = SettingsStore.loadSummaryForWidget() ?? .placeholder
        settingsSubscription = settingsStore.$settings
            .sink { [weak self] settings in
                self?.settingsDidChange(settings)
            }

        let settings = Self.sanitize(settingsStore.settings)
        syncSettings(settings)
        if settings.isConfigured || settings.isXiaomiTokenPlanConfigured {
            Task { await refresh(showSpinner: false) }
        } else {
            updateSchedule(for: settings)
        }
    }

    static func sanitize(_ settings: PoolSettings) -> PoolSettings {
        var result = PoolSettings(
            baseURL: settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            managementKey: settings.managementKey.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshMinutes: max(5, settings.refreshMinutes),
            appRefreshSeconds: max(10, settings.appRefreshSeconds),
            liveRefreshEnabled: settings.liveRefreshEnabled,
            usageAccountLimit: max(1, settings.usageAccountLimit),
            showOnlyCodex: settings.showOnlyCodex,
            plusWeight: max(0.1, settings.plusWeight),
            proLiteWeight: max(0.1, settings.proLiteWeight),
            proWeight: max(0.1, settings.proWeight),
            weeklyKillLinePercent: max(0, settings.weeklyKillLinePercent),
            xiaomiTokenPlanEnabled: settings.xiaomiTokenPlanEnabled,
            xiaomiCookie: settings.xiaomiCookie.trimmingCharacters(in: .whitespacesAndNewlines),
            preferredLanguageCode: AppLanguagePreference(rawValue: settings.preferredLanguageCode)?.rawValue ?? AppLanguagePreference.auto.rawValue,
            ignoredAPIKeyIDs: settings.ignoredAPIKeyIDs
        )
        result.source = settings.source
        result.companyProvider = settings.companyProvider
        result.companyModel = settings.companyModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.source == .companyGateway {
            result.managementKey = ""
            result.xiaomiCookie = ""
            result.xiaomiTokenPlanEnabled = false
            result.appRefreshSeconds = max(30, result.appRefreshSeconds)
        }
        return result
    }

    func saveAndRefresh(_ settings: PoolSettings) async {
        let saved = Self.sanitize(settings)
        settingsStore.settings = saved
        syncSettings(saved)
        lastMessage = L10n.text("Saved. The widget will refresh shortly.", "已保存，组件很快会刷新。")
        await refresh(showSpinner: false)
    }

    func refresh(showSpinner: Bool = true) async {
        guard !refreshInFlight else {
            return
        }

        let settings = Self.sanitize(settingsStore.settings)
        guard settings.isConfigured || settings.isXiaomiTokenPlanConfigured else {
            summary = .placeholder
            nextRefreshAt = nil
            lastMessage = L10n.text(
                "Configure the pool URL and management key or Xiaomi Token Plan cookie first.",
                "请先配置池地址和管理密钥，或填写小米 Token Plan Cookie。"
            )
            updateSchedule(for: settings)
            return
        }

        syncSettings(settings)
        refreshInFlight = true
        if showSpinner {
            isLoading = true
        }
        defer {
            isLoading = false
            refreshInFlight = false
            updateSchedule(for: Self.sanitize(settingsStore.settings))
        }

        lastMessage = settings.liveRefreshEnabled && !showSpinner ? L10n.text("Refreshing...", "刷新中…") : nil
        let generation = settingsGeneration
        if settings.source == .companyGateway { summary = .placeholder }
        let task = Task { await PoolSummaryService(client: PoolAPIClient(settings: settings)).loadSummary() }
        loadTask = task
        let loaded = await task.value
        guard generation == settingsGeneration, !task.isCancelled else { return }
        loadTask = nil
        summary = loaded
        if let error = loaded.errorMessage {
            lastMessage = error
        } else {
            if loaded.totalAccounts > 0 {
                lastMessage = L10n.isChinese ? "已获取 \(loaded.totalAccounts) 个账号。" : "Fetched \(loaded.totalAccounts) accounts."
            } else if loaded.xiaomiTokenPlan != nil {
                lastMessage = L10n.text("Fetched Xiaomi Token Plan.", "已获取小米 Token Plan。")
            } else {
                lastMessage = L10n.text("Fetched.", "已获取。")
            }
            settingsStore.syncSummaryToWidget(loaded)
            WidgetCenter.shared.reloadAllTimelines()
            if settings.source != .companyGateway { await quotaPrintManager.process(summary: loaded) }
        }
    }

    private func settingsDidChange(_ rawSettings: PoolSettings) {
        let settings = Self.sanitize(rawSettings)
        if let previousSettings, previousSettings != settings {
            settingsGeneration += 1
            loadTask?.cancel()
            loadTask = nil
            summary = .placeholder
            SettingsStore.clearSummaryForWidget()
        }
        previousSettings = settings
        syncSettings(settings)
        updateSchedule(for: settings)
    }

    private func syncSettings(_ settings: PoolSettings) {
        settingsStore.syncToWidget(settings)
        WidgetCenter.shared.reloadTimelines(ofKind: "CLIProxyPoolWidget")
    }

    private func updateSchedule(for settings: PoolSettings) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard (settings.isConfigured || settings.isXiaomiTokenPlanConfigured), settings.liveRefreshEnabled else {
            nextRefreshAt = nil
            endBackgroundActivity()
            return
        }

        beginBackgroundActivity()
        let interval = TimeInterval(max(10, settings.appRefreshSeconds))
        nextRefreshAt = Date().addingTimeInterval(interval)

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh(showSpinner: false)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginBackgroundActivity() {
        guard backgroundActivity == nil else {
            return
        }
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .automaticTerminationDisabled],
            reason: "Refresh CLIProxy Pool widget data in the background"
        )
    }

    private func endBackgroundActivity() {
        guard let backgroundActivity else {
            return
        }
        ProcessInfo.processInfo.endActivity(backgroundActivity)
        self.backgroundActivity = nil
    }
}
