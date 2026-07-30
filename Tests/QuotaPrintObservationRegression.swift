import Foundation

@main
enum QuotaPrintObservationRegression {
    static func main() {
        let summary = makeSummary()
        let observations = QuotaPrintManager.makeObservations(from: summary)
        let primary = observations.first { $0.window == .fiveHour }
        expect(primary != nil, "5h observation exists")
        expect(abs((primary?.capacityUnits ?? 0) - 8) < 0.001, "5h capacity is 8 weighted units")
        expect(abs((primary?.remainingUnits ?? 0) - 4.5) < 0.001, "5h remaining is 4.5 weighted units")
        expect(abs((primary?.usedPercent ?? 0) - 43.75) < 0.001, "used percent is normalized by capacity")

        let weekKilled = summary.accounts[1]
        expect(weekKilled.effectivePrimaryRemainingPercent == 0, "fixture is week-killed in pool aggregation")
        expect(
            observations.first { $0.window == .fiveHour }?.cohortID.contains(weekKilled.authIndex) == true,
            "receipt observation uses raw 5h usage rather than week-killed effective usage"
        )
        print("QuotaPrint observation regression tests passed")
    }

    private static func makeSummary() -> PoolSummary {
        let first = makeAccount(
            id: "account-a",
            weight: 3,
            primaryUsed: 50,
            weeklyUsed: 20
        )
        let second = makeAccount(
            id: "account-b",
            weight: 5,
            primaryUsed: 40,
            weeklyUsed: 99
        )
        return PoolSummary(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            totalAccounts: 2,
            availableAccounts: 2,
            coolingAccounts: 0,
            disabledAccounts: 0,
            failedRecentRequests: 0,
            primaryRemainingUnits: 1.5,
            primaryCapacityUnits: 8,
            weeklyRemainingUnits: 0.6,
            weeklyCapacityUnits: 8,
            nextPrimaryResetHint: nil,
            nextWeeklyResetHint: nil,
            recentRequests: [],
            planBreakdown: [],
            accounts: [first, second],
            apiKeyUsages: [],
            apiKeyUsageSummary: nil,
            xiaomiTokenPlan: nil,
            errorMessage: nil
        )
    }

    private static func makeAccount(
        id: String,
        weight: Double,
        primaryUsed: Double,
        weeklyUsed: Double
    ) -> AccountUsage {
        let usage = UsageSnapshot(
            used: nil,
            limit: nil,
            remaining: nil,
            usedPercent: nil,
            planType: "plus",
            primaryUsedPercent: primaryUsed,
            primaryResetSeconds: 3_600,
            primaryResetText: nil,
            weeklyUsedPercent: weeklyUsed,
            weeklyResetSeconds: 86_400,
            weeklyResetText: nil,
            resetText: nil,
            rawStatus: nil
        )
        return AccountUsage(
            authIndex: id,
            name: id,
            provider: "codex",
            isAvailable: true,
            statusText: "active",
            weight: weight,
            weeklyKillLinePercent: 3,
            recentRequests: [],
            usage: usage,
            error: nil
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }
}
