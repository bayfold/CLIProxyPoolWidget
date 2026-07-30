import Combine
import CoreGraphics
import CoreText
import Foundation

struct PrinterQueue: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let isReady: Bool
    let statusDetail: String?

    init(
        id: String,
        displayName: String,
        isReady: Bool = true,
        statusDetail: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isReady = isReady
        self.statusDetail = statusDetail
    }
}

struct PrinterDiscovery: Equatable, Sendable {
    let queues: [PrinterQueue]
    let defaultQueueID: String?
}

enum ThermalPrinterError: LocalizedError, Sendable {
    case noQueueSelected
    case invalidBitmap
    case receiptTooLong
    case queueUnavailable(String)
    case queueBacklogged(Int)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noQueueSelected:
            return L10n.text("Select a printer queue first.", "请先选择打印机队列。")
        case .invalidBitmap:
            return L10n.text("Could not create the receipt bitmap.", "无法生成小票位图。")
        case .receiptTooLong:
            return L10n.text(
                "The receipt is too long for one safe print. Shorten the title or content.",
                "小票内容过长，无法作为单张安全打印，请缩短标题或内容。"
            )
        case .queueUnavailable(let detail):
            return L10n.isChinese
                ? "打印队列已停用或离线，未提交小票。\(detail)"
                : "The printer queue is stopped or offline; the receipt was not submitted. \(detail)"
        case .queueBacklogged(let count):
            return L10n.isChinese
                ? "打印队列仍有 \(count) 个未完成任务，未提交新小票。请先处理旧任务，避免连续切纸。"
                : "The printer queue still has \(count) unfinished job(s). No new receipt was submitted, preventing consecutive cuts."
        case .commandFailed(let message):
            return message
        }
    }
}

enum ThermalPrinterService {
    static let maxRasterHeightDots = 1_600

    static func discoverQueues() async throws -> PrinterDiscovery {
        async let queueOutput = run("/usr/bin/lpstat", arguments: ["-e"])
        async let defaultOutput = run("/usr/bin/lpstat", arguments: ["-d"], allowsFailure: true)
        let (rawQueues, rawDefault) = try await (queueOutput, defaultOutput)

        let ids = rawQueues
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var queues: [PrinterQueue] = []
        for id in ids {
            let options = try await run(
                "/usr/bin/lpoptions",
                arguments: ["-p", id],
                allowsFailure: true
            )
            let status = queueStatus(fromLPOptions: options)
            queues.append(
                PrinterQueue(
                    id: id,
                    displayName: id.replacingOccurrences(of: "_", with: " "),
                    isReady: status.isReady,
                    statusDetail: status.detail
                )
            )
        }
        let parsedDefault = rawDefault
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultID = parsedDefault.flatMap { ids.contains($0) ? $0 : nil }
        return PrinterDiscovery(queues: queues, defaultQueueID: defaultID)
    }

    static func submit(
        event: QuotaPrintEvent,
        settings rawSettings: QuotaPrintSettings,
        isTest: Bool = false
    ) async throws -> String {
        let settings = rawSettings.normalized
        guard !settings.queueID.isEmpty else {
            throw ThermalPrinterError.noQueueSelected
        }

        try await ensureQueueCanAcceptReceipt(settings.queueID)
        let payload = try makeRawReceiptPayload(event: event, settings: settings, isTest: isTest)
        let windowName = event.window == .fiveHour ? "5h" : "Week"
        let title = isTest ? "CLIProxy test receipt" : "CLIProxy \(windowName) \(event.thresholdPercent)%"
        return try await run(
            "/usr/bin/lp",
            arguments: makeLPArguments(queueID: settings.queueID, title: title),
            input: payload
        )
    }

    static func queueStatus(fromLPOptions output: String) -> (isReady: Bool, detail: String?) {
        var options: [String: String] = [:]
        for token in output.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                options[pair[0]] = pair[1]
            }
        }
        let state = Int(options["printer-state"] ?? "")
        let reasons = options["printer-state-reasons"]?
            .split(separator: ",")
            .map(String.init) ?? []
        let blockedReason = reasons.first {
            let value = $0.lowercased()
            return value.contains("paused") ||
                value.contains("offline") ||
                value.contains("shutdown")
        }
        let isReady = state != 5 && blockedReason == nil
        let detail = blockedReason ?? (state == 5 ? "printer-state=5" : nil)
        return (isReady, detail)
    }

    static func pendingJobCount(fromLPStat output: String) -> Int {
        output
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private static func ensureQueueCanAcceptReceipt(_ queueID: String) async throws {
        let options = try await run("/usr/bin/lpoptions", arguments: ["-p", queueID])
        let status = queueStatus(fromLPOptions: options)
        guard status.isReady else {
            throw ThermalPrinterError.queueUnavailable(status.detail ?? queueID)
        }

        let jobs = try await run(
            "/usr/bin/lpstat",
            arguments: ["-W", "not-completed", "-o", queueID],
            allowsFailure: true
        )
        let pendingJobs = pendingJobCount(fromLPStat: jobs)
        guard pendingJobs == 0 else {
            throw ThermalPrinterError.queueBacklogged(pendingJobs)
        }
    }

    private enum ReceiptContent {
        case text(String)
        case badge(String)
        case hero(value: String, label: String)
        case progress(filled: Double, total: Int)
        case metricPair(
            leftLabel: String,
            leftValue: String,
            rightLabel: String,
            rightValue: String
        )
        case reset(label: String, value: String)
        case rule
    }

    private struct ReceiptLine {
        let content: ReceiptContent
        let size: CGFloat
        let bold: Bool
        let centered: Bool
        let extraSpacing: CGFloat
    }

    static func makeRawReceiptPayload(
        event: QuotaPrintEvent,
        settings rawSettings: QuotaPrintSettings,
        isTest: Bool
    ) throws -> Data {
        let settings = rawSettings.normalized
        let observation = event.observation
        let chinese = L10n.isChinese
        let window = event.window == .fiveHour ? "5h" : "Week"
        let widthMM = settings.paperWidthMM == 58 ? 48.0 : 72.0
        let pageWidth = millimetersToPoints(widthMM)
        let compact = settings.paperWidthMM == 58
        let baseSize: CGFloat = compact ? 8.8 : 9.8
        let titleSize: CGFloat = compact ? 11.5 : 13.5
        let heroSize: CGFloat = compact ? 24 : 28
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: chinese ? "zh_Hans_CN" : "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let remainingUnits = format(observation.remainingUnits)
        let capacityUnits = format(observation.capacityUnits)
        let filled = remainingSegmentFill(percent: observation.remainingPercent)
        let eyebrow = isTest
            ? L10n.text("\(window.uppercased()) · TEST SNAPSHOT", "\(window.uppercased()) · 测试快照")
            : L10n.text("\(window.uppercased()) · QUOTA SNAPSHOT", "\(window.uppercased()) · 额度快照")
        let milestone = isTest
            ? L10n.text("TEST · NO MILESTONE RECORDED", "测试小票 · 不记录触发档位")
            : L10n.text(
                "USED CROSSED \(event.thresholdPercent)%",
                "已用跨过 \(event.thresholdPercent)% 档位"
            )

        var lines = [
            ReceiptLine(content: .text(settings.reportTitle), size: titleSize, bold: true, centered: true, extraSpacing: 3),
            ReceiptLine(content: .text(eyebrow), size: compact ? 7.2 : 8.0, bold: true, centered: true, extraSpacing: compact ? 15 : 18),
            ReceiptLine(
                content: .hero(
                    value: "\(format(observation.remainingPercent))%",
                    label: L10n.text("CURRENT REMAINING", "当前剩余")
                ),
                size: heroSize,
                bold: true,
                centered: true,
                extraSpacing: 8
            ),
            ReceiptLine(content: .progress(filled: filled, total: 20), size: baseSize, bold: true, centered: false, extraSpacing: 7),
            ReceiptLine(
                content: .metricPair(
                    leftLabel: L10n.text("WEIGHTED REMAINING", "加权余量"),
                    leftValue: "\(remainingUnits) / \(capacityUnits)",
                    rightLabel: L10n.text("ACCOUNTS ONLINE", "账号在线"),
                    rightValue: "\(observation.availableAccounts) / \(observation.totalAccounts)"
                ),
                size: baseSize,
                bold: true,
                centered: false,
                extraSpacing: 7
            ),
            ReceiptLine(content: .badge(milestone), size: compact ? 7.4 : 8.2, bold: true, centered: true, extraSpacing: 8)
        ]
        if let resetText = observation.resetText, !resetText.isEmpty {
            lines.append(
                ReceiptLine(
                    content: .reset(
                        label: L10n.text("EXPECTED QUOTA RESTORE", "预计额度恢复"),
                        value: resetText
                    ),
                    size: compact ? 8.4 : 9.4,
                    bold: true,
                    centered: false,
                    extraSpacing: 8
                )
            )
        }
        lines += [
            ReceiptLine(content: .rule, size: baseSize, bold: false, centered: false, extraSpacing: 5),
            ReceiptLine(
                content: .text("\(timeFormatter.string(from: observation.observedAt)) · AUTO REPORT"),
                size: compact ? 6.8 : 7.6,
                bold: false,
                centered: true,
                extraSpacing: 10
            )
        ]

        let margin: CGFloat = compact ? 5 : 7
        let lineHeights = lines.map { line -> CGFloat in
            switch line.content {
            case .progress:
                return (compact ? 6 : 7) + line.extraSpacing
            case .rule:
                return 1 + line.extraSpacing
            case .badge:
                return line.size + 6 + line.extraSpacing
            case .hero:
                return line.size * 1.42 + line.extraSpacing
            case .metricPair:
                return line.size * 2.15 + line.extraSpacing
            case .reset:
                return line.size * 2.05 + line.extraSpacing
            case .text:
                return max(line.size * 1.42, 12) + line.extraSpacing
            }
        }
        let pageHeight = max(millimetersToPoints(50), margin * 2 + lineHeights.reduce(0, +))
        let pixelWidth = compact ? 384 : 576
        let scale = CGFloat(pixelWidth) / pageWidth
        let pixelHeight = Int(ceil(pageHeight * scale))
        guard pixelHeight > 0, pixelHeight <= maxRasterHeightDots else {
            throw ThermalPrinterError.receiptTooLong
        }
        var pixels = [UInt8](repeating: 255, count: pixelWidth * pixelHeight)
        guard let context = CGContext(
            data: &pixels,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw ThermalPrinterError.invalidBitmap
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0, alpha: 1))

        var baseline = pageHeight - margin - lines[0].size
        for (index, line) in lines.enumerated() {
            switch line.content {
            case .text(let text):
                let textLine = makeTextLine(text, size: line.size, bold: line.bold, chinese: chinese)
                let textWidth = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
                let x = line.centered ? max(margin, (pageWidth - textWidth) / 2) : margin
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(textLine, context)
            case .badge(let text):
                let textLine = makeTextLine(
                    text,
                    size: line.size,
                    bold: true,
                    chinese: chinese,
                    foregroundGray: 1
                )
                let textWidth = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
                let horizontalPadding: CGFloat = compact ? 5 : 7
                let badgeWidth = min(pageWidth - margin * 2, textWidth + horizontalPadding * 2)
                let badgeHeight = line.size + 5
                let badgeRect = CGRect(
                    x: (pageWidth - badgeWidth) / 2,
                    y: baseline - 2,
                    width: badgeWidth,
                    height: badgeHeight
                )
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.addPath(
                    CGPath(
                        roundedRect: badgeRect,
                        cornerWidth: 2,
                        cornerHeight: 2,
                        transform: nil
                    )
                )
                context.fillPath()
                context.textPosition = CGPoint(x: (pageWidth - textWidth) / 2, y: baseline)
                CTLineDraw(textLine, context)
            case .hero(let value, let label):
                let valueLine = makeTextLine(value, size: line.size, bold: true, chinese: chinese, monospaced: true)
                let valueWidth = CGFloat(CTLineGetTypographicBounds(valueLine, nil, nil, nil))
                context.textPosition = CGPoint(x: (pageWidth - valueWidth) / 2, y: baseline)
                CTLineDraw(valueLine, context)
                let labelSize = compact ? 7.4 : 8.2
                let labelLine = makeTextLine(label, size: labelSize, bold: true, chinese: chinese)
                let labelWidth = CGFloat(CTLineGetTypographicBounds(labelLine, nil, nil, nil))
                context.textPosition = CGPoint(x: (pageWidth - labelWidth) / 2, y: baseline - line.size * 0.72)
                CTLineDraw(labelLine, context)
            case .progress(let filledCount, let totalCount):
                drawProgress(
                    in: context,
                    x: margin,
                    y: baseline,
                    width: pageWidth - margin * 2,
                    height: compact ? 6 : 7,
                    filled: filledCount,
                    total: totalCount,
                    compact: compact
                )
            case .metricPair(let leftLabel, let leftValue, let rightLabel, let rightValue):
                let leftCenter = margin + (pageWidth - margin * 2) * 0.25
                let rightCenter = margin + (pageWidth - margin * 2) * 0.75
                drawMetric(
                    in: context,
                    label: leftLabel,
                    value: leftValue,
                    centerX: leftCenter,
                    baseline: baseline,
                    size: line.size,
                    chinese: chinese
                )
                drawMetric(
                    in: context,
                    label: rightLabel,
                    value: rightValue,
                    centerX: rightCenter,
                    baseline: baseline,
                    size: line.size,
                    chinese: chinese
                )
                context.setStrokeColor(CGColor(gray: 0.65, alpha: 1))
                context.setLineWidth(0.35)
                context.move(to: CGPoint(x: pageWidth / 2, y: baseline - line.size * 0.7))
                context.addLine(to: CGPoint(x: pageWidth / 2, y: baseline + line.size * 0.65))
                context.strokePath()
            case .reset(let label, let value):
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(
                    CGRect(
                        x: margin,
                        y: baseline - line.size * 1.2,
                        width: compact ? 1.5 : 1.8,
                        height: line.size * 2.05
                    )
                )
                let textX = margin + (compact ? 6 : 8)
                let labelLine = makeTextLine(label, size: line.size * 0.78, bold: true, chinese: chinese)
                context.textPosition = CGPoint(x: textX, y: baseline)
                CTLineDraw(labelLine, context)
                let valueLine = makeTextLine(value, size: line.size * 1.12, bold: true, chinese: chinese)
                context.textPosition = CGPoint(x: textX, y: baseline - line.size * 1.05)
                CTLineDraw(valueLine, context)
            case .rule:
                context.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
                context.setLineWidth(0.45)
                context.move(to: CGPoint(x: margin, y: baseline + 1))
                context.addLine(to: CGPoint(x: pageWidth - margin, y: baseline + 1))
                context.strokePath()
            }
            baseline -= lineHeights[index]
        }
        context.flush()

        let widthBytes = pixelWidth / 8
        var payload = Data([0x1B, 0x40, 0x1B, 0x61, 0x00])
        payload.append(contentsOf: [
            0x1D, 0x76, 0x30, 0x00,
            UInt8(widthBytes & 0xFF),
            UInt8((widthBytes >> 8) & 0xFF),
            UInt8(pixelHeight & 0xFF),
            UInt8((pixelHeight >> 8) & 0xFF)
        ])
        payload.append(packRaster(pixels: pixels, width: pixelWidth, height: pixelHeight))
        payload.append(contentsOf: [0x1B, 0x64, 0x03])
        if settings.autoCut {
            payload.append(contentsOf: [0x1D, 0x56, 0x01])
        }
        return payload
    }

    static func makeLPArguments(queueID: String, title: String) -> [String] {
        let safeTitle = title
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .prefix(80)
        return [
            "-d", queueID,
            "-t", String(safeTitle),
            "-o", "raw"
        ]
    }

    private static func packRaster(pixels: [UInt8], width: Int, height: Int) -> Data {
        precondition(width.isMultiple(of: 8))
        var packed = Data(capacity: width / 8 * height)
        for y in 0..<height {
            let rowStart = y * width
            for xByte in 0..<(width / 8) {
                var value: UInt8 = 0
                for bit in 0..<8 where pixels[rowStart + xByte * 8 + bit] < 128 {
                    value |= UInt8(1 << (7 - bit))
                }
                packed.append(value)
            }
        }
        return packed
    }

    private static func makeTextLine(
        _ text: String,
        size: CGFloat,
        bold: Bool,
        chinese: Bool,
        monospaced: Bool = false,
        foregroundGray: CGFloat = 0
    ) -> CTLine {
        let fontName: String
        if monospaced {
            fontName = bold ? "Menlo-Bold" : "Menlo-Regular"
        } else if chinese && !text.unicodeScalars.allSatisfy({ $0.isASCII }) {
            fontName = bold ? "PingFangSC-Semibold" : "PingFangSC-Medium"
        } else {
            fontName = bold ? "AvenirNext-DemiBold" : "HelveticaNeue-Medium"
        }
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: foregroundGray, alpha: 1)
            ]
        )
        return CTLineCreateWithAttributedString(attributed)
    }

    private static func drawMetric(
        in context: CGContext,
        label: String,
        value: String,
        centerX: CGFloat,
        baseline: CGFloat,
        size: CGFloat,
        chinese: Bool
    ) {
        let valueLine = makeTextLine(value, size: size * 1.12, bold: true, chinese: chinese, monospaced: true)
        let valueWidth = CGFloat(CTLineGetTypographicBounds(valueLine, nil, nil, nil))
        context.textPosition = CGPoint(x: centerX - valueWidth / 2, y: baseline)
        CTLineDraw(valueLine, context)

        let labelLine = makeTextLine(label, size: size * 0.72, bold: true, chinese: chinese)
        let labelWidth = CGFloat(CTLineGetTypographicBounds(labelLine, nil, nil, nil))
        context.textPosition = CGPoint(x: centerX - labelWidth / 2, y: baseline - size * 0.92)
        CTLineDraw(labelLine, context)
    }

    private static func drawProgress(
        in context: CGContext,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        filled: Double,
        total: Int,
        compact: Bool
    ) {
        guard total > 0 else { return }
        let gap: CGFloat = compact ? 1.15 : 1.45
        let cellWidth = (width - gap * CGFloat(total - 1)) / CGFloat(total)
        let radius = min(1.4, cellWidth * 0.28)
        for index in 0..<total {
            let rect = CGRect(
                x: x + CGFloat(index) * (cellWidth + gap),
                y: y,
                width: cellWidth,
                height: height
            )
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
            context.setLineWidth(0.55)
            context.addPath(path)
            context.strokePath()

            let fillAmount = max(0, min(1, filled - Double(index)))
            if fillAmount > 0 {
                context.saveGState()
                context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width * fillAmount, height: rect.height))
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    static func remainingSegmentFill(percent: Double, total: Int = 20) -> Double {
        guard total > 0, percent.isFinite else { return 0 }
        return max(0, min(Double(total), percent / 100 * Double(total)))
    }

    private static func format(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(Int(value.rounded()))
        }
        let rounded = (value * 10).rounded(.toNearestOrAwayFromZero) / 10
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    private static func millimetersToPoints(_ value: Double) -> CGFloat {
        CGFloat(value / 25.4 * 72)
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        input: Data? = nil,
        allowsFailure: Bool = false
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            let inputPipe = input.map { _ in Pipe() }
            process.standardInput = inputPipe
            do {
                try process.run()
                if let input, let inputPipe {
                    try inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try inputPipe.fileHandleForWriting.close()
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                throw ThermalPrinterError.commandFailed(error.localizedDescription)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0, !allowsFailure {
                throw ThermalPrinterError.commandFailed(
                    message.isEmpty
                        ? L10n.text("The print command failed.", "打印命令执行失败。")
                        : message
                )
            }
            return message
        }.value
    }
}

@MainActor
final class QuotaPrintManager: ObservableObject {
    @Published var settings: QuotaPrintSettings {
        didSet { saveSettings() }
    }
    @Published private(set) var availableQueues: [PrinterQueue] = []
    @Published private(set) var defaultQueueID: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBusy = false

    private let defaults: UserDefaults
    private var ledger: QuotaPrintLedger
    private var submissionInFlight = false
    private static let settingsKey = "quotaPrint.settings.v1"
    private static let ledgerKey = "quotaPrint.ledger.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(QuotaPrintSettings.self, from: data) {
            settings = decoded.normalized
        } else {
            settings = .default
        }
        if let data = defaults.data(forKey: Self.ledgerKey),
           let decoded = try? JSONDecoder().decode(QuotaPrintLedger.self, from: data) {
            ledger = decoded
        } else {
            ledger = .empty
        }

        let recovered = QuotaPrintPolicy.recoverInterruptedSubmissions(ledger: &ledger)
        if !recovered.isEmpty {
            statusMessage = L10n.text(
                "A previous print submission has unknown delivery status and will not be retried automatically.",
                "上一次打印提交结果未知，为避免重复出纸将不会自动重试。"
            )
            saveLedger()
        }
    }

    var selectedQueueIsAvailable: Bool {
        availableQueues.contains { $0.id == settings.queueID }
    }

    var selectedQueueIsReady: Bool {
        availableQueues.first { $0.id == settings.queueID }?.isReady == true
    }

    var selectedQueueStatusDetail: String? {
        availableQueues.first { $0.id == settings.queueID }?.statusDetail
    }

    var deliveryUnknownEvent: QuotaPrintEvent? {
        ledger.fiveHour.deliveryUnknownEvent ?? ledger.week.deliveryUnknownEvent
    }

    func reloadQueues() async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let discovery = try await ThermalPrinterService.discoverQueues()
            availableQueues = discovery.queues
            defaultQueueID = discovery.defaultQueueID
            if settings.queueID.isEmpty {
                let readyDefault = discovery.queues.first {
                    $0.id == discovery.defaultQueueID && $0.isReady
                }?.id
                settings.queueID = readyDefault ?? discovery.queues.first(where: \.isReady)?.id ?? ""
            }
            statusMessage = discovery.queues.isEmpty
                ? L10n.text("No macOS printer queues were found.", "没有找到 macOS 打印机队列。")
                : L10n.isChinese
                    ? "找到 \(discovery.queues.count) 个系统打印队列，其中 \(discovery.queues.filter(\.isReady).count) 个可用。"
                    : "Found \(discovery.queues.count) macOS printer queues; \(discovery.queues.filter(\.isReady).count) ready."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func testPrint(summary: PoolSummary) async {
        let settings = settings.normalized
        guard !settings.queueID.isEmpty else {
            statusMessage = ThermalPrinterError.noQueueSelected.localizedDescription
            return
        }
        guard beginSubmission() else {
            statusMessage = L10n.text(
                "Another printer operation is already running.",
                "另一个打印操作正在进行。"
            )
            return
        }
        defer { endSubmission() }
        let observation = Self.makeObservations(from: summary).first ?? Self.sampleObservation(summary: summary)
        let event = QuotaPrintEvent(window: observation.window, thresholdPercent: settings.thresholdPercent, observation: observation)
        do {
            let response = try await ThermalPrinterService.submit(event: event, settings: settings, isTest: true)
            statusMessage = L10n.isChinese
                ? "测试小票已提交到 \(settings.queueID)。\(response.isEmpty ? "" : " \(response)")"
                : "Test receipt submitted to \(settings.queueID).\(response.isEmpty ? "" : " \(response)")"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func process(summary: PoolSummary) async {
        let currentSettings = settings.normalized
        let now = Date()
        let events = QuotaPrintPolicy.evaluate(
            observations: Self.makeObservations(from: summary),
            settings: currentSettings,
            now: now,
            ledger: &ledger
        )
        saveLedger()
        guard !events.isEmpty else {
            return
        }
        guard beginSubmission() else {
            return
        }
        defer { endSubmission() }

        for event in events {
            QuotaPrintPolicy.markSubmitting(event, ledger: &ledger)
            saveLedger()
            do {
                let response = try await ThermalPrinterService.submit(event: event, settings: currentSettings)
                QuotaPrintPolicy.markSucceeded(event, ledger: &ledger)
                saveLedger()
                let window = event.window == .fiveHour ? "5h" : "Week"
                statusMessage = L10n.isChinese
                    ? "已打印 \(window) \(event.thresholdPercent)% 额度汇报。\(response.isEmpty ? "" : " \(response)")"
                    : "Printed \(window) \(event.thresholdPercent)% quota report.\(response.isEmpty ? "" : " \(response)")"
            } catch {
                QuotaPrintPolicy.markFailed(event, now: Date(), ledger: &ledger)
                saveLedger()
                statusMessage = L10n.isChinese
                    ? "额度小票提交失败，将稍后重试：\(error.localizedDescription)"
                    : "Quota receipt failed and will retry later: \(error.localizedDescription)"
            }
        }
    }

    func retryUnknownDelivery() async {
        guard let event = deliveryUnknownEvent else {
            return
        }
        guard beginSubmission() else {
            statusMessage = L10n.text(
                "Another printer operation is already running.",
                "另一个打印操作正在进行。"
            )
            return
        }
        defer { endSubmission() }
        do {
            let response = try await ThermalPrinterService.submit(event: event, settings: settings.normalized)
            QuotaPrintPolicy.markSucceeded(event, ledger: &ledger)
            saveLedger()
            statusMessage = L10n.isChinese
                ? "结果未知的小票已手动重印。\(response.isEmpty ? "" : " \(response)")"
                : "Reprinted the receipt with unknown delivery status.\(response.isEmpty ? "" : " \(response)")"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func dismissUnknownDelivery() {
        for window in QuotaPrintWindow.allCases {
            QuotaPrintPolicy.clearDeliveryUnknown(for: window, ledger: &ledger)
        }
        saveLedger()
        statusMessage = L10n.text("Unknown delivery status dismissed.", "已忽略结果未知的打印状态。")
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings.normalized) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(ledger) {
            defaults.set(data, forKey: Self.ledgerKey)
            defaults.synchronize()
        }
    }

    private func beginSubmission() -> Bool {
        guard !submissionInFlight, !isBusy else {
            return false
        }
        submissionInFlight = true
        isBusy = true
        return true
    }

    private func endSubmission() {
        submissionInFlight = false
        isBusy = false
    }

    nonisolated static func makeObservations(from summary: PoolSummary) -> [QuotaPrintObservation] {
        QuotaPrintWindow.allCases.compactMap { window in
            let accounts = summary.accounts.filter { account in
                guard account.isAvailable else {
                    return false
                }
                switch window {
                case .fiveHour:
                    return account.usage?.primaryRemainingPercent != nil
                case .week:
                    return account.usage?.weeklyRemainingPercent != nil
                }
            }
            guard !accounts.isEmpty else {
                return nil
            }

            let capacity = accounts.reduce(0) { $0 + $1.weight }
            guard capacity > 0 else {
                return nil
            }
            let remaining = accounts.reduce(0.0) { total, account in
                let percent: Double
                switch window {
                case .fiveHour:
                    percent = account.usage?.primaryRemainingPercent ?? 0
                case .week:
                    percent = account.usage?.weeklyRemainingPercent ?? 0
                }
                return total + account.weight * max(0, min(100, percent)) / 100
            }
            let remainingPercent = max(0, min(100, remaining / capacity * 100))
            let usedPercent = 100 - remainingPercent
            let cohortID = accounts
                .sorted { $0.authIndex < $1.authIndex }
                .map { account in
                    String(format: "%@|%.4f", locale: Locale(identifier: "en_US_POSIX"), account.authIndex, account.weight)
                }
                .joined(separator: ";")
            let resetEpochs = accounts.compactMap { account -> Double? in
                let seconds: Double?
                switch window {
                case .fiveHour:
                    seconds = account.usage?.primaryResetSeconds
                case .week:
                    seconds = account.usage?.weeklyResetSeconds
                }
                return seconds.map { summary.generatedAt.timeIntervalSince1970 + $0 }
            }.sorted()
            let medianReset = resetEpochs.isEmpty ? nil : resetEpochs[resetEpochs.count / 2]
            let resetAnchor = medianReset.map { Int(($0 / 300).rounded()) }
            let resetText: String?
            switch window {
            case .fiveHour:
                resetText = summary.nextPrimaryResetHint?.timeText
            case .week:
                resetText = summary.nextWeeklyResetHint?.timeText
            }

            return QuotaPrintObservation(
                window: window,
                usedPercent: usedPercent,
                remainingPercent: remainingPercent,
                remainingUnits: remaining,
                capacityUnits: capacity,
                cohortID: cohortID,
                resetAnchorMinutes: resetAnchor,
                resetText: resetText,
                availableAccounts: summary.availableAccounts,
                totalAccounts: summary.totalAccounts,
                observedAt: summary.generatedAt
            )
        }
    }

    private static func sampleObservation(summary: PoolSummary) -> QuotaPrintObservation {
        QuotaPrintObservation(
            window: .fiveHour,
            usedPercent: 10,
            remainingPercent: 90,
            remainingUnits: 9,
            capacityUnits: 10,
            cohortID: "test",
            resetAnchorMinutes: nil,
            resetText: L10n.text("test print", "测试打印"),
            availableAccounts: max(1, summary.availableAccounts),
            totalAccounts: max(1, summary.totalAccounts),
            observedAt: Date()
        )
    }
}
