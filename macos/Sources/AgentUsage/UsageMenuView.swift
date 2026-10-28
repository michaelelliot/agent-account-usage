import AgentUsageCore
import AppKit
import SwiftUI

struct UsageMenuView: View {
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.configError {
                ErrorText(message: error)
            }
            ForEach(model.reports) { report in
                ProfileSection(report: report)
                if report.id != model.reports.last?.id {
                    Divider()
                }
            }
            if model.reports.isEmpty && model.configError == nil {
                Text("Loading…").foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refreshIfStale() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let lastUpdated = model.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(model.isRefreshing)
            Button(action: model.openConfig) {
                Image(systemName: "gearshape")
            }
            .help("Open \(model.configURL.path)")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct ProfileSection: View {
    let report: ProfileReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if case let .success(profile) = report.result, let plan = profile.subscriptionType {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
            }
            switch report.result {
            case let .success(profile):
                let rows = profile.usage.rows
                if rows.isEmpty {
                    Text("No plan usage limits reported").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    UsageRowView(row: row)
                }
                if let extra = profile.usage.extraUsage?.summary {
                    ExtraUsageView(summary: extra)
                }
            case let .failure(error):
                ErrorText(message: error.message)
            }
        }
    }
}

private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(row.level.color)
            }
            UsageBar(percent: row.percent, color: row.level.color)
            if let resetsAt = row.resetsAt {
                Text("Resets in \(formatDuration(resetsAt.timeIntervalSinceNow))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(resetsAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .font(.callout)
    }
}

private struct ExtraUsageView: View {
    let summary: ExtraUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Extra usage")
                Spacer()
                Text(summary.amount).monospacedDigit()
                if let percent = summary.percent {
                    Text("(\(Int(percent.rounded()))%)")
                        .monospacedDigit()
                        .foregroundStyle(Level(percent: percent).color)
                }
            }
            if !summary.isEnabled {
                Text(summary.disabledReason.map { "Disabled (\($0))" } ?? "Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct UsageBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 6)
    }
}

private struct ErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Level {
    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}
