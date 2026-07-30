import Foundation

@main
struct ThermalPrinterPayloadRegression {
    static func main() throws {
        let observation = QuotaPrintObservation(
            window: .week,
            usedPercent: 40,
            remainingPercent: 60,
            remainingUnits: 12,
            capacityUnits: 20,
            cohortID: "regression",
            resetAnchorMinutes: 30_000_000,
            resetText: "3 天后",
            availableAccounts: 2,
            totalAccounts: 3,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let event = QuotaPrintEvent(
            window: .week,
            thresholdPercent: 40,
            observation: observation
        )
        var settings = QuotaPrintSettings.default
        settings.queueID = "Printer_POS_80"
        settings.paperWidthMM = 80
        settings.autoCut = true

        expect(ThermalPrinterService.remainingSegmentFill(percent: 60) == 12, "60% remaining must fill 12 of 20 segments")
        expect(abs(ThermalPrinterService.remainingSegmentFill(percent: 56.25) - 11.25) < 0.001, "56.25% remaining must preserve a quarter-filled segment")
        expect(abs(ThermalPrinterService.remainingSegmentFill(percent: 38) - 7.6) < 0.001, "38% remaining must preserve a partial segment instead of rounding")
        expect(ThermalPrinterService.remainingSegmentFill(percent: 0) == 0, "0% remaining must fill no segments")
        expect(ThermalPrinterService.remainingSegmentFill(percent: 100) == 20, "100% remaining must fill all segments")

        let payload = try ThermalPrinterService.makeRawReceiptPayload(
            event: event,
            settings: settings,
            isTest: true
        )
        let raster = Data([0x1D, 0x76, 0x30, 0x00])
        let feedThreeLines = Data([0x1B, 0x64, 0x03])
        let partialCut = Data([0x1D, 0x56, 0x01])

        expect(payload.starts(with: Data([0x1B, 0x40, 0x1B, 0x61, 0x00])), "payload must initialize once and use left alignment")
        expect(occurrences(of: raster, in: payload) == 1, "payload must contain exactly one raster image")
        expect(occurrences(of: feedThreeLines, in: payload) == 1, "payload must feed exactly three lines")
        expect(occurrences(of: partialCut, in: payload) == 1, "payload must contain exactly one partial cut")
        expect(payload.suffix(feedThreeLines.count + partialCut.count) == feedThreeLines + partialCut, "feed and the single cut must be the final commands")
        expect(!payload.starts(with: Data("%PDF".utf8)), "payload must not be a PDF")

        let rasterStart = payload.range(of: raster)!.lowerBound
        let header = payload[rasterStart..<(rasterStart + 8)]
        let widthBytes = Int(header[header.startIndex + 4]) | (Int(header[header.startIndex + 5]) << 8)
        let heightDots = Int(header[header.startIndex + 6]) | (Int(header[header.startIndex + 7]) << 8)
        expect(widthBytes == 72, "80 mm mode must render the 72 mm printable width as 576 dots")
        expect(heightDots > 0 && heightDots <= ThermalPrinterService.maxRasterHeightDots, "receipt must fit one bounded raster")
        let rasterBytes = widthBytes * heightDots
        let expectedLength = 19 + rasterBytes
        expect(payload.count == expectedLength, "payload must contain one image followed only by feed and cut")

        settings.paperWidthMM = 58
        let compactPayload = try ThermalPrinterService.makeRawReceiptPayload(
            event: event,
            settings: settings,
            isTest: true
        )
        let compactRasterStart = compactPayload.range(of: raster)!.lowerBound
        let compactHeader = compactPayload[compactRasterStart..<(compactRasterStart + 8)]
        let compactWidthBytes = Int(compactHeader[compactHeader.startIndex + 4]) | (Int(compactHeader[compactHeader.startIndex + 5]) << 8)
        let compactHeightDots = Int(compactHeader[compactHeader.startIndex + 6]) | (Int(compactHeader[compactHeader.startIndex + 7]) << 8)
        expect(compactWidthBytes == 48, "58 mm mode must render the 48 mm printable width as 384 dots")
        expect(compactHeightDots > 0 && compactHeightDots <= ThermalPrinterService.maxRasterHeightDots, "58 mm receipt must remain one bounded raster")

        settings.autoCut = false
        let noCutPayload = try ThermalPrinterService.makeRawReceiptPayload(
            event: event,
            settings: settings,
            isTest: true
        )
        expect(occurrences(of: partialCut, in: noCutPayload) == 0, "cut-disabled payload must contain no cut command")
        expect(noCutPayload.suffix(feedThreeLines.count) == feedThreeLines, "cut-disabled payload must still feed three lines")

        let arguments = ThermalPrinterService.makeLPArguments(
            queueID: settings.queueID,
            title: "CLIProxy Week 40%"
        )
        expect(arguments.contains("raw"), "CUPS submission must use raw mode")
        let joined = arguments.joined(separator: " ")
        expect(!joined.contains("media="), "raw submission must not request custom media")
        expect(!joined.contains("PageCutType"), "raw submission must not request page cutting")
        expect(!joined.contains("DocCutType"), "raw submission must not request document cutting")
        expect(!joined.contains("FeedCutAfterJobEnd"), "raw submission must not request driver feeding/cutting")

        let readyStatus = ThermalPrinterService.queueStatus(
            fromLPOptions: "printer-state=3 printer-state-reasons=none"
        )
        expect(readyStatus.isReady, "idle printer queue is ready")
        let pausedStatus = ThermalPrinterService.queueStatus(
            fromLPOptions: "printer-state=5 printer-state-reasons=paused,offline-report"
        )
        expect(!pausedStatus.isReady, "paused or offline queue is blocked before submission")
        expect(
            ThermalPrinterService.pendingJobCount(
                fromLPStat: "Printer_POS_80-1 user 123 date\nPrinter_POS_80-2 user 456 date\n"
            ) == 2,
            "unfinished queue jobs are counted before submission"
        )

        print("Thermal printer payload regression tests passed")
    }

    private static func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, in: searchStart..<haystack.endIndex)
        {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
