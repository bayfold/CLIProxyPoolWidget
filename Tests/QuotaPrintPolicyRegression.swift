import Foundation

@main
enum QuotaPrintPolicyRegression {
    static func main() {
        testFirstSampleAndRepeatedRefresh()
        testCrossingAndJumpCoalescing()
        testSmallDropDoesNotDuplicate()
        testResetStartsANewCycle()
        testWindowsAreIndependent()
        testQuietHoursCoalesce()
        testConfigurationChangeRebaselines()
        testInterruptedSubmissionIsNotRetried()
        testMissingObservationPreservesDeliveryState()
        print("QuotaPrintPolicy regression tests passed")
    }

    private static func testFirstSampleAndRepeatedRefresh() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        expect(evaluate(9, settings: settings, ledger: &ledger).isEmpty, "first sample establishes baseline")
        expect(evaluate(9, settings: settings, ledger: &ledger).isEmpty, "repeated sample does not print")
        let events = evaluate(10, settings: settings, ledger: &ledger)
        expect(events.map(\.thresholdPercent) == [10], "9 to 10 prints 10 percent")
        QuotaPrintPolicy.markSubmitting(events[0], ledger: &ledger)
        QuotaPrintPolicy.markSucceeded(events[0], ledger: &ledger)
        expect(evaluate(10, settings: settings, ledger: &ledger).isEmpty, "submitted threshold is deduplicated")
    }

    private static func testCrossingAndJumpCoalescing() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        _ = evaluate(19, settings: settings, ledger: &ledger)
        let events = evaluate(42, settings: settings, ledger: &ledger)
        expect(events.count == 1 && events[0].thresholdPercent == 40, "19 to 42 prints one 40 percent report")
    }

    private static func testSmallDropDoesNotDuplicate() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        _ = evaluate(39, settings: settings, ledger: &ledger)
        let first = evaluate(42, settings: settings, ledger: &ledger)[0]
        QuotaPrintPolicy.markSubmitting(first, ledger: &ledger)
        QuotaPrintPolicy.markSucceeded(first, ledger: &ledger)
        expect(evaluate(39, settings: settings, ledger: &ledger).isEmpty, "small downward jitter does not reset")
        expect(evaluate(42, settings: settings, ledger: &ledger).isEmpty, "42 to 39 to 42 does not duplicate")
    }

    private static func testResetStartsANewCycle() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        _ = evaluate(39, reset: 100, settings: settings, ledger: &ledger)
        let first = evaluate(42, reset: 100, settings: settings, ledger: &ledger)[0]
        QuotaPrintPolicy.markSubmitting(first, ledger: &ledger)
        QuotaPrintPolicy.markSucceeded(first, ledger: &ledger)
        expect(evaluate(4, reset: 200, settings: settings, ledger: &ledger).isEmpty, "reset drop rebaselines")
        expect(evaluate(11, reset: 200, settings: settings, ledger: &ledger).map(\.thresholdPercent) == [10], "new cycle can print 10 percent")
    }

    private static func testWindowsAreIndependent() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = QuotaPrintPolicy.evaluate(
            observations: [observation(.fiveHour, used: 9), observation(.week, used: 29)],
            settings: settings,
            now: now,
            ledger: &ledger
        )
        let events = QuotaPrintPolicy.evaluate(
            observations: [observation(.fiveHour, used: 11), observation(.week, used: 31)],
            settings: settings,
            now: now,
            ledger: &ledger
        )
        expect(Set(events.map { $0.window }) == Set([.fiveHour, .week]), "5h and Week trigger independently")
    }

    private static func testQuietHoursCoalesce() {
        var settings = enabledSettings()
        settings.quietHoursEnabled = true
        settings.quietStartMinutes = 22 * 60
        settings.quietEndMinutes = 7 * 60
        var ledger = QuotaPrintLedger.empty
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 86_400)
        let at23 = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!
        let at08 = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        _ = QuotaPrintPolicy.evaluate(observations: [observation(.fiveHour, used: 9)], settings: settings, now: at23, ledger: &ledger, calendar: calendar)
        expect(QuotaPrintPolicy.evaluate(observations: [observation(.fiveHour, used: 21)], settings: settings, now: at23, ledger: &ledger, calendar: calendar).isEmpty, "quiet time holds report")
        expect(QuotaPrintPolicy.evaluate(observations: [observation(.fiveHour, used: 42)], settings: settings, now: at23, ledger: &ledger, calendar: calendar).isEmpty, "quiet time coalesces later threshold")
        let events = QuotaPrintPolicy.evaluate(observations: [observation(.fiveHour, used: 42)], settings: settings, now: at08, ledger: &ledger, calendar: calendar)
        expect(events.map(\.thresholdPercent) == [40], "quiet hours release only latest threshold")
        expect(QuotaPrintPolicy.isQuiet(minuteOfDay: 23 * 60, startMinutes: 22 * 60, endMinutes: 7 * 60), "cross-midnight quiet start")
        expect(!QuotaPrintPolicy.isQuiet(minuteOfDay: 8 * 60, startMinutes: 22 * 60, endMinutes: 7 * 60), "cross-midnight quiet end")
    }

    private static func testConfigurationChangeRebaselines() {
        var ledger = QuotaPrintLedger.empty
        var settings = enabledSettings()
        _ = evaluate(9, settings: settings, ledger: &ledger)
        settings.queueID = "another-printer"
        expect(evaluate(31, settings: settings, ledger: &ledger).isEmpty, "printer change does not retroactively print")
    }

    private static func testInterruptedSubmissionIsNotRetried() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        _ = evaluate(9, settings: settings, ledger: &ledger)
        let event = evaluate(11, settings: settings, ledger: &ledger)[0]
        QuotaPrintPolicy.markSubmitting(event, ledger: &ledger)
        let recovered = QuotaPrintPolicy.recoverInterruptedSubmissions(ledger: &ledger)
        expect(recovered == [event], "interrupted submission becomes unknown")
        expect(evaluate(11, settings: settings, ledger: &ledger).isEmpty, "unknown delivery is not automatically retried")
    }

    private static func testMissingObservationPreservesDeliveryState() {
        var ledger = QuotaPrintLedger.empty
        let settings = enabledSettings()
        _ = evaluate(9, settings: settings, ledger: &ledger)
        let event = evaluate(11, settings: settings, ledger: &ledger)[0]
        QuotaPrintPolicy.markSubmitting(event, ledger: &ledger)
        QuotaPrintPolicy.markSucceeded(event, ledger: &ledger)

        expect(
            QuotaPrintPolicy.evaluate(
                observations: [],
                settings: settings,
                now: Date(timeIntervalSince1970: 1_001),
                ledger: &ledger
            ).isEmpty,
            "missing observation does not emit a receipt"
        )
        expect(evaluate(9, settings: settings, ledger: &ledger).isEmpty, "temporary missing data preserves the cycle")
        expect(evaluate(11, settings: settings, ledger: &ledger).isEmpty, "restored data does not duplicate the submitted threshold")

        QuotaPrintPolicy.markSubmitting(event, ledger: &ledger)
        _ = QuotaPrintPolicy.recoverInterruptedSubmissions(ledger: &ledger)
        _ = QuotaPrintPolicy.evaluate(
            observations: [],
            settings: settings,
            now: Date(timeIntervalSince1970: 1_002),
            ledger: &ledger
        )
        expect(ledger.fiveHour.deliveryUnknownEvent == event, "missing data preserves unknown-delivery protection")
    }

    private static func enabledSettings() -> QuotaPrintSettings {
        var settings = QuotaPrintSettings.default
        settings.enabled = true
        settings.queueID = "Printer_POS_80"
        return settings
    }

    private static func evaluate(
        _ used: Double,
        reset: Int = 100,
        settings: QuotaPrintSettings,
        ledger: inout QuotaPrintLedger
    ) -> [QuotaPrintEvent] {
        QuotaPrintPolicy.evaluate(
            observations: [observation(.fiveHour, used: used, reset: reset)],
            settings: settings,
            now: Date(timeIntervalSince1970: 1_000),
            ledger: &ledger
        )
    }

    private static func observation(
        _ window: QuotaPrintWindow,
        used: Double,
        reset: Int = 100
    ) -> QuotaPrintObservation {
        QuotaPrintObservation(
            window: window,
            usedPercent: used,
            remainingPercent: 100 - used,
            remainingUnits: (100 - used) / 100,
            capacityUnits: 1,
            cohortID: "account-a:1",
            resetAnchorMinutes: reset,
            resetText: nil,
            availableAccounts: 1,
            totalAccounts: 1,
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }
}
