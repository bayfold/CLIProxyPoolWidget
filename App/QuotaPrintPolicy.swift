import Foundation

enum QuotaPrintWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case week

    var id: String { rawValue }
}

struct QuotaPrintSettings: Codable, Equatable, Sendable {
    static let thresholdChoices = [5, 10, 20, 25, 50]

    var enabled: Bool
    var queueID: String
    var thresholdPercent: Int
    var monitorFiveHour: Bool
    var monitorWeek: Bool
    var quietHoursEnabled: Bool
    var quietStartMinutes: Int
    var quietEndMinutes: Int
    var paperWidthMM: Int
    var autoCut: Bool
    var reportTitle: String

    static let `default` = QuotaPrintSettings(
        enabled: false,
        queueID: "",
        thresholdPercent: 10,
        monitorFiveHour: true,
        monitorWeek: true,
        quietHoursEnabled: false,
        quietStartMinutes: 22 * 60,
        quietEndMinutes: 7 * 60,
        paperWidthMM: 80,
        autoCut: true,
        reportTitle: "CLIProxy Quota Report"
    )

    var normalized: QuotaPrintSettings {
        var result = self
        result.queueID = queueID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.thresholdPercent = Self.thresholdChoices.min {
            abs($0 - thresholdPercent) < abs($1 - thresholdPercent)
        } ?? 10
        result.quietStartMinutes = max(0, min(1_439, quietStartMinutes))
        result.quietEndMinutes = max(0, min(1_439, quietEndMinutes))
        result.paperWidthMM = paperWidthMM == 58 ? 58 : 80
        let title = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        result.reportTitle = String((title.isEmpty ? Self.default.reportTitle : title).prefix(48))
        return result
    }

    var activationSignature: String {
        let value = normalized
        return [
            value.queueID,
            String(value.thresholdPercent),
            value.monitorFiveHour ? "5h" : "-",
            value.monitorWeek ? "week" : "-"
        ].joined(separator: "|")
    }

    func monitors(_ window: QuotaPrintWindow) -> Bool {
        switch window {
        case .fiveHour:
            return monitorFiveHour
        case .week:
            return monitorWeek
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case queueID
        case thresholdPercent
        case monitorFiveHour
        case monitorWeek
        case quietHoursEnabled
        case quietStartMinutes
        case quietEndMinutes
        case paperWidthMM
        case autoCut
        case reportTitle
    }

    init(
        enabled: Bool,
        queueID: String,
        thresholdPercent: Int,
        monitorFiveHour: Bool,
        monitorWeek: Bool,
        quietHoursEnabled: Bool,
        quietStartMinutes: Int,
        quietEndMinutes: Int,
        paperWidthMM: Int,
        autoCut: Bool,
        reportTitle: String
    ) {
        self.enabled = enabled
        self.queueID = queueID
        self.thresholdPercent = thresholdPercent
        self.monitorFiveHour = monitorFiveHour
        self.monitorWeek = monitorWeek
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
        self.paperWidthMM = paperWidthMM
        self.autoCut = autoCut
        self.reportTitle = reportTitle
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        queueID = try container.decodeIfPresent(String.self, forKey: .queueID) ?? defaults.queueID
        thresholdPercent = try container.decodeIfPresent(Int.self, forKey: .thresholdPercent) ?? defaults.thresholdPercent
        monitorFiveHour = try container.decodeIfPresent(Bool.self, forKey: .monitorFiveHour) ?? defaults.monitorFiveHour
        monitorWeek = try container.decodeIfPresent(Bool.self, forKey: .monitorWeek) ?? defaults.monitorWeek
        quietHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .quietHoursEnabled) ?? defaults.quietHoursEnabled
        quietStartMinutes = try container.decodeIfPresent(Int.self, forKey: .quietStartMinutes) ?? defaults.quietStartMinutes
        quietEndMinutes = try container.decodeIfPresent(Int.self, forKey: .quietEndMinutes) ?? defaults.quietEndMinutes
        paperWidthMM = try container.decodeIfPresent(Int.self, forKey: .paperWidthMM) ?? defaults.paperWidthMM
        autoCut = try container.decodeIfPresent(Bool.self, forKey: .autoCut) ?? defaults.autoCut
        reportTitle = try container.decodeIfPresent(String.self, forKey: .reportTitle) ?? defaults.reportTitle
    }
}

struct QuotaPrintObservation: Codable, Equatable, Sendable {
    let window: QuotaPrintWindow
    let usedPercent: Double
    let remainingPercent: Double
    let remainingUnits: Double
    let capacityUnits: Double
    let cohortID: String
    let resetAnchorMinutes: Int?
    let resetText: String?
    let availableAccounts: Int
    let totalAccounts: Int
    let observedAt: Date
}

struct QuotaPrintEvent: Codable, Equatable, Sendable {
    let window: QuotaPrintWindow
    let thresholdPercent: Int
    let observation: QuotaPrintObservation
}

struct QuotaPrintWindowState: Codable, Equatable, Sendable {
    var lastBucket: Int?
    var peakUsedPercent: Double?
    var cohortID: String?
    var resetAnchorMinutes: Int?
    var pendingEvent: QuotaPrintEvent?
    var lastSubmittedThreshold: Int?
    var submittingEvent: QuotaPrintEvent?
    var deliveryUnknownEvent: QuotaPrintEvent?
    var failureCount = 0
    var nextRetryAt: Date?

    static let empty = QuotaPrintWindowState()
}

struct QuotaPrintLedger: Codable, Equatable, Sendable {
    var activationSignature: String?
    var fiveHour = QuotaPrintWindowState.empty
    var week = QuotaPrintWindowState.empty

    subscript(_ window: QuotaPrintWindow) -> QuotaPrintWindowState {
        get {
            switch window {
            case .fiveHour: fiveHour
            case .week: week
            }
        }
        set {
            switch window {
            case .fiveHour: fiveHour = newValue
            case .week: week = newValue
            }
        }
    }

    static let empty = QuotaPrintLedger()
}

enum QuotaPrintPolicy {
    static func evaluate(
        observations: [QuotaPrintObservation],
        settings rawSettings: QuotaPrintSettings,
        now: Date,
        ledger: inout QuotaPrintLedger,
        calendar: Calendar = .current
    ) -> [QuotaPrintEvent] {
        let settings = rawSettings.normalized
        guard settings.enabled, !settings.queueID.isEmpty else {
            ledger = .empty
            return []
        }

        guard settings.monitorFiveHour || settings.monitorWeek else {
            ledger = .empty
            return []
        }

        if ledger.activationSignature != settings.activationSignature {
            ledger = QuotaPrintLedger(activationSignature: settings.activationSignature)
        }

        let byWindow = Dictionary(uniqueKeysWithValues: observations.map { ($0.window, $0) })
        let quiet = settings.quietHoursEnabled && isQuiet(
            at: now,
            startMinutes: settings.quietStartMinutes,
            endMinutes: settings.quietEndMinutes,
            calendar: calendar
        )
        var events: [QuotaPrintEvent] = []

        for window in QuotaPrintWindow.allCases {
            guard settings.monitors(window) else {
                ledger[window] = .empty
                continue
            }
            guard let observation = byWindow[window] else {
                continue
            }

            var state = ledger[window]
            let bucket = bucketIndex(for: observation.usedPercent, step: settings.thresholdPercent)
            let cohortChanged = state.cohortID != nil && state.cohortID != observation.cohortID
            let peak = state.peakUsedPercent ?? observation.usedPercent
            let resetAnchorAdvanced = state.resetAnchorMinutes != nil &&
                observation.resetAnchorMinutes != nil &&
                state.resetAnchorMinutes != observation.resetAnchorMinutes
            let materialDrop = peak - observation.usedPercent >= max(5, Double(settings.thresholdPercent) * 0.75)
            let resetDetected = materialDrop || (resetAnchorAdvanced && observation.usedPercent < peak - 1)

            if state.lastBucket == nil || cohortChanged || resetDetected {
                state = baselineState(for: observation, bucket: bucket)
            } else {
                if let lastBucket = state.lastBucket, bucket > lastBucket {
                    let threshold = min(100, bucket * settings.thresholdPercent)
                    if threshold > 0,
                       threshold > (state.lastSubmittedThreshold ?? 0),
                       threshold > (state.deliveryUnknownEvent?.thresholdPercent ?? 0) {
                        state.pendingEvent = QuotaPrintEvent(
                            window: window,
                            thresholdPercent: threshold,
                            observation: observation
                        )
                    }
                    state.lastBucket = bucket
                }
                state.peakUsedPercent = max(peak, observation.usedPercent)
                state.resetAnchorMinutes = observation.resetAnchorMinutes ?? state.resetAnchorMinutes
            }

            if !quiet,
               state.submittingEvent == nil,
               let pending = state.pendingEvent,
               now >= (state.nextRetryAt ?? .distantPast) {
                events.append(pending)
            }
            ledger[window] = state
        }
        return events
    }

    static func markSubmitting(_ event: QuotaPrintEvent, ledger: inout QuotaPrintLedger) {
        var state = ledger[event.window]
        state.submittingEvent = event
        ledger[event.window] = state
    }

    static func markSucceeded(_ event: QuotaPrintEvent, ledger: inout QuotaPrintLedger) {
        var state = ledger[event.window]
        state.lastSubmittedThreshold = max(state.lastSubmittedThreshold ?? 0, event.thresholdPercent)
        if state.pendingEvent?.thresholdPercent ?? 0 <= event.thresholdPercent {
            state.pendingEvent = nil
        }
        state.submittingEvent = nil
        state.deliveryUnknownEvent = nil
        state.failureCount = 0
        state.nextRetryAt = nil
        ledger[event.window] = state
    }

    static func markFailed(_ event: QuotaPrintEvent, now: Date, ledger: inout QuotaPrintLedger) {
        var state = ledger[event.window]
        state.submittingEvent = nil
        state.failureCount = min(5, state.failureCount + 1)
        let delay = min(300, 15 * pow(2, Double(state.failureCount - 1)))
        state.nextRetryAt = now.addingTimeInterval(delay)
        ledger[event.window] = state
    }

    static func recoverInterruptedSubmissions(ledger: inout QuotaPrintLedger) -> [QuotaPrintEvent] {
        var recovered: [QuotaPrintEvent] = []
        for window in QuotaPrintWindow.allCases {
            var state = ledger[window]
            guard let event = state.submittingEvent else {
                continue
            }
            recovered.append(event)
            state.deliveryUnknownEvent = event
            state.lastSubmittedThreshold = max(state.lastSubmittedThreshold ?? 0, event.thresholdPercent)
            if state.pendingEvent?.thresholdPercent ?? 0 <= event.thresholdPercent {
                state.pendingEvent = nil
            }
            state.submittingEvent = nil
            state.failureCount = 0
            state.nextRetryAt = nil
            ledger[window] = state
        }
        return recovered
    }

    static func clearDeliveryUnknown(for window: QuotaPrintWindow, ledger: inout QuotaPrintLedger) {
        var state = ledger[window]
        state.deliveryUnknownEvent = nil
        ledger[window] = state
    }

    static func isQuiet(
        minuteOfDay: Int,
        startMinutes: Int,
        endMinutes: Int
    ) -> Bool {
        let minute = max(0, min(1_439, minuteOfDay))
        let start = max(0, min(1_439, startMinutes))
        let end = max(0, min(1_439, endMinutes))
        if start == end {
            return false
        }
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    private static func isQuiet(
        at date: Date,
        startMinutes: Int,
        endMinutes: Int,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return isQuiet(minuteOfDay: minute, startMinutes: startMinutes, endMinutes: endMinutes)
    }

    private static func bucketIndex(for usedPercent: Double, step: Int) -> Int {
        let clamped = max(0, min(100, usedPercent))
        if clamped >= 99.999 {
            return Int(ceil(100 / Double(step)))
        }
        return Int(floor((clamped + 0.000_001) / Double(step)))
    }

    private static func baselineState(
        for observation: QuotaPrintObservation,
        bucket: Int
    ) -> QuotaPrintWindowState {
        QuotaPrintWindowState(
            lastBucket: bucket,
            peakUsedPercent: observation.usedPercent,
            cohortID: observation.cohortID,
            resetAnchorMinutes: observation.resetAnchorMinutes,
            pendingEvent: nil,
            lastSubmittedThreshold: nil,
            submittingEvent: nil,
            deliveryUnknownEvent: nil,
            failureCount: 0,
            nextRetryAt: nil
        )
    }
}
