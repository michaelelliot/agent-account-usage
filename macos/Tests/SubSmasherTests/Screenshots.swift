import AppKit
import SwiftUI
import Testing

@testable import SubSmasher
@testable import SubSmasherCore

/// Renders the README's screenshots into $SUBSMASHER_SCREENSHOTS: the menu for sample accounts, and the CLI's output
/// for the same accounts from $SUBSMASHER_CLI_OUTPUT. Run `scripts/screenshots.sh` rather than this directly.
@MainActor
struct Screenshots {
    nonisolated static let directory = ProcessInfo.processInfo.environment["SUBSMASHER_SCREENSHOTS"]
    nonisolated static let cliOutput = ProcessInfo.processInfo.environment["SUBSMASHER_CLI_OUTPUT"]

    @Test(.enabled(if: directory != nil))
    func menu() throws {
        let view = UsageMenuView(model: UsageModel(reports: Self.sampleReports(now: .now)))
            .background(Color(red: 38 / 255, green: 42 / 255, blue: 46 / 255))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        try render(view, to: URL(fileURLWithPath: Self.directory!).appending(path: "menu.png"))
    }

    @Test(.enabled(if: directory != nil && cliOutput != nil))
    func cli() throws {
        let output = try String(contentsOfFile: Self.cliOutput!, encoding: .utf8)
        let view = Terminal(command: "subsmash -a", output: output)
        try render(view, to: URL(fileURLWithPath: Self.directory!).appending(path: "cli.png"))
    }

    static func sampleReports(now: Date) -> [ProfileReport] {
        func row(_ label: String, _ percent: Double, resetsIn seconds: TimeInterval?) -> UsageRow {
            UsageRow(label: label, percent: percent, resetsAt: seconds.map { now.addingTimeInterval($0) })
        }
        let hour: TimeInterval = 3600
        let day = 24 * hour
        let unix = { (seconds: TimeInterval) in String(Int(now.addingTimeInterval(seconds).timeIntervalSince1970)) }
        let headers = [
            "anthropic-ratelimit-unified-5h-utilization": "0.07",
            "anthropic-ratelimit-unified-5h-reset": unix(4 * hour + 31 * 60),
            "anthropic-ratelimit-unified-7d-utilization": "0.91",
            "anthropic-ratelimit-unified-7d-reset": unix(2 * day + 5 * hour),
        ]
        var work = ProfileUsage(setupToken: UnifiedLimits(headers: headers)!, now: now)
        work.checkedAt = now.addingTimeInterval(-6 * 60)
        let reports: [(String, ProfileUsage)] = [
            (
                "me@example.com",
                ProfileUsage(
                    subscriptionType: "max",
                    rows: [
                        row("Session (5h)", 42, resetsIn: 2 * hour + 13 * 60),
                        row("Weekly", 82, resetsIn: day + 8 * hour),
                        row("Weekly Fable", 30, resetsIn: day + 8 * hour),
                    ],
                    extraUsage: ExtraUsageSummary(
                        amount: "$26.66 / $40.00", percent: 66.65, isEnabled: false, disabledReason: "out of credits"),
                    credits: nil, resets: nil)
            ),
            ("Work", work),
            (
                "ChatGPT",
                ProfileUsage(
                    subscriptionType: "pro", rows: [row("Weekly", 64, resetsIn: 5 * day + 22 * hour)], extraUsage: nil,
                    credits: CreditsSummary(balance: "59,945", isInUse: false),
                    resets: ResetsSummary(available: 3, nextExpiry: now.addingTimeInterval(11 * day + 9 * hour)))
            ),
            (
                "Grok",
                ProfileUsage(
                    subscriptionType: "Ultra", rows: [row("Weekly", 32, resetsIn: 2 * day + 18 * hour)], extraUsage: nil,
                    credits: nil, resets: nil)
            ),
        ]
        return reports.map { ProfileReport(id: $0.0, displayName: $0.0, result: .success($0.1)) }
    }

    /// Draws `view` at 2x in dark mode, off screen.
    func render(_ view: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now.addingTimeInterval(0.5))
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// A dark terminal window showing `command` and its output, coloured from the ANSI codes the CLI writes.
private struct Terminal: View {
    let command: String
    let output: String

    /// SF Mono's advance is 0.6em, so at 15pt the bar's block characters land on whole pixels and barely show seams.
    static let fontSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([(255, 95, 87), (254, 188, 46), (40, 200, 64)], id: \.0) { red, green, blue in
                    Circle()
                        .fill(Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(14)
            Text(Self.styled("\u{1b}[2m$\u{1b}[22m \(command)\n\(output.trimmingCharacters(in: .newlines))"))
                .font(.system(size: Self.fontSize, design: .monospaced))
                .lineSpacing(4)
                .fixedSize()
                .padding([.horizontal, .bottom], 20)
        }
        .background(Color(red: 30 / 255, green: 31 / 255, blue: 34 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The codes `styleText` writes: bold and dim (both ended by 22), and red, green, yellow and the default colour.
    static func styled(_ ansi: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var dim = false
        var color: Color?
        for (index, part) in ansi.components(separatedBy: "\u{1b}[").enumerated() {
            var text = Substring(part)
            if index > 0, let end = text.firstIndex(of: "m") {
                for code in text[..<end].split(separator: ";") {
                    switch code {
                    case "1": bold = true
                    case "2": dim = true
                    case "22": (bold, dim) = (false, false)
                    case "31": color = Color(nsColor: .systemRed)
                    case "32": color = Color(nsColor: .systemGreen)
                    case "33": color = Color(nsColor: .systemYellow)
                    case "39": color = nil
                    default: break
                    }
                }
                text = text[text.index(after: end)...]
            }
            var run = AttributedString(text)
            run.foregroundColor = color ?? Color(white: dim ? 0.5 : 0.92)
            if bold { run.font = .system(size: fontSize, weight: .bold, design: .monospaced) }
            result += run
        }
        return result
    }
}
