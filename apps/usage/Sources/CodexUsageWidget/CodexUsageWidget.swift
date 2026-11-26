import SwiftUI
import WidgetKit
import UsageCore

private let appGroup = "7FVL4J2UZ9.com.an-mzn.codex-usage"

private struct Allowance: Identifiable {
    let id: String
    let title: String
    let remaining: Int
    let reset: Date?
}

private struct AccountReading: Identifiable {
    let id: UUID
    let label: String
    let fiveHour: Allowance?
    let weekly: Allowance?

    init(profile: Profile) {
        id = profile.id
        label = profile.label
        let windows = profile.snapshot?.windows ?? []
        fiveHour = windows.first(where: { $0.minutes == 300 }).map {
            Allowance(id: $0.id, title: "5h", remaining: $0.remaining, reset: $0.reset)
        }
        weekly = windows.first(where: { $0.minutes == 10_080 }).map {
            Allowance(id: $0.id, title: "Week", remaining: $0.remaining, reset: $0.reset)
        }
    }
    init(id: UUID, label: String, fiveHour: Allowance?, weekly: Allowance?) {
        self.id = id
        self.label = label
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
    var hasUsage: Bool { fiveHour != nil || weekly != nil }
}

private struct UsageEntry: TimelineEntry {
    let date: Date
    let accounts: [AccountReading]
    let refreshed: Date?
    let status: String?
}

private struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, accounts: [AccountReading(id: UUID(), label: "Personal",
            fiveHour: Allowance(id: "5h", title: "5h", remaining: 78, reset: nil),
            weekly: Allowance(id: "week", title: "Week", remaining: 64, reset: nil))], refreshed: .now, status: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = read()
        completion(Timeline(entries: [entry], policy: .never))
    }
    private func read() -> UsageEntry {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return UsageEntry(date: .now, accounts: [], refreshed: nil, status: "Shared account storage is unavailable")
        }
        do {
            let config = try Storage(root: root).load()
            let accounts = config.profiles.map(AccountReading.init(profile:))
            return UsageEntry(date: .now, accounts: accounts, refreshed: config.lastRefreshed,
                              status: accounts.isEmpty ? "Add an account in Usage" : nil)
        } catch { return UsageEntry(date: .now, accounts: [], refreshed: nil, status: "Could not read allowance") }
    }
}

struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("See your remaining 5-hour and weekly Codex allowance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry
    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
            .fontDesign(.rounded).foregroundStyle(.primary)
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let account = entry.accounts.first {
                HStack(spacing: 9) {
                    SplitAllowanceRing(fiveHour: account.fiveHour, weekly: account.weekly, size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        compactAllowance(account.fiveHour, title: "5h")
                        compactAllowance(account.weekly, title: "Wk")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0); footer
            } else {
                Spacer(minLength: 0)
                Text(entry.status ?? "No usage available").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }.padding(14)
    }
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !entry.accounts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(entry.accounts.prefix(3))) { account in
                        HStack(spacing: 7) {
                            Text(account.label)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .frame(width: 55, alignment: .leading)
                            SplitAllowanceRing(fiveHour: account.fiveHour, weekly: account.weekly, size: 32, lineWidth: 4)
                            compactAllowance(account.fiveHour, title: "5h")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            compactAllowance(account.weekly, title: "Wk")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 30)
                        if account.id != entry.accounts.prefix(3).last?.id {
                            Rectangle().fill(.quaternary).frame(height: 1)
                        }
                    }
                }
                Spacer(minLength: 0)
                footer
            } else {
                Spacer(minLength: 0)
                Text(entry.status ?? "No usage available").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }.padding(12)
    }
    private var large: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if !entry.accounts.isEmpty {
                VStack(spacing: 3) {
                    ForEach(Array(entry.accounts.prefix(3))) { account in
                        HStack(spacing: 10) {
                            Text(account.label)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .frame(width: 58, alignment: .leading)
                            allowanceColumn(account.fiveHour, title: "5 hours")
                            allowanceColumn(account.weekly, title: "Weekly")
                        }
                        .frame(height: 76)
                        if account.id != entry.accounts.prefix(3).last?.id {
                            Rectangle().fill(.quaternary).frame(height: 1)
                        }
                    }
                }
                Spacer(minLength: 0)
                footer
            } else {
                Spacer(minLength: 0)
                Text(entry.status ?? "No usage available").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }.padding(16)
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Usage").font(.caption.weight(.semibold)); Spacer(minLength: 0)
            if entry.accounts.count > 1 {
                Text("\(min(entry.accounts.count, 3)) of \(entry.accounts.count) accounts")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    @ViewBuilder
    private func compactAllowance(_ allowance: Allowance?, title: String) -> some View {
        if let allowance {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    Text("\(allowance.remaining)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                if let reset = allowance.reset {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 7, weight: .medium))
                        Text(reset, style: .relative).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    Text("—").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
                Text("Unavailable").font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
    private func allowanceColumn(_ allowance: Allowance?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            if let allowance {
                Text("\(allowance.remaining)% left")
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.75)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(gaugeColor(allowance.remaining))
                            .frame(width: proxy.size.width * CGFloat(allowance.remaining) / 100)
                    }
                }.frame(height: 4)
                HStack(spacing: 2) {
                    if let reset = allowance.reset {
                        Text("Resets in")
                        Text(reset, style: .relative).lineLimit(1).minimumScaleFactor(0.75)
                    } else {
                        Text("Reset time unavailable").lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                .font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.tertiary)
                Capsule().fill(.quaternary).frame(height: 4)
                Text("No limit reported").font(.system(size: 8, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack {
            if let refreshed = entry.refreshed {
                Text("Updated \(refreshed, style: .relative)").font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
        }
    }
    private func gaugeColor(_ remaining: Int) -> Color {
        if remaining <= 15 { return .orange }; if remaining <= 35 { return .yellow }; return .green
    }
}

private struct SplitAllowanceRing: View {
    let fiveHour: Allowance?
    let weekly: Allowance?
    let size: CGFloat
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            allowanceArc(from: 180, to: 360).stroke(.quaternary,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            allowanceArc(from: 0, to: 180).stroke(.quaternary,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if let fiveHour {
                allowanceArc(from: 180, to: 180 + 180 * progress(fiveHour.remaining))
                    .stroke(allowanceColor(fiveHour.remaining), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            if let weekly {
                allowanceArc(from: 0, to: 180 * progress(weekly.remaining))
                    .stroke(allowanceColor(weekly.remaining), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.system(size: max(9, size * 0.2), weight: .semibold)).foregroundStyle(.secondary)
            Image(systemName: "clock")
                .font(.system(size: max(6, size * 0.14), weight: .medium)).foregroundStyle(.secondary)
                .offset(y: -size * 0.22)
            Image(systemName: "calendar")
                .font(.system(size: max(6, size * 0.13), weight: .medium)).foregroundStyle(.secondary)
                .offset(y: size * 0.22)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ringAccessibilityLabel)
    }

    private var ringAccessibilityLabel: String {
        let five = fiveHour.map { "5-hour allowance \($0.remaining) percent" } ?? "5-hour allowance unavailable"
        let week = weekly.map { "weekly allowance \($0.remaining) percent" } ?? "weekly allowance unavailable"
        return "\(five), \(week)"
    }

    private func progress(_ remaining: Int) -> Double {
        Double(min(100, max(0, remaining))) / 100
    }

    private func allowanceColor(_ remaining: Int) -> Color {
        if remaining <= 15 { return .orange }
        if remaining <= 35 { return .yellow }
        return .green
    }

    private func allowanceArc(from start: Double, to end: Double) -> RingArc {
        RingArc(start: start, end: end)
    }
}

private struct RingArc: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.08
        let radius = min(rect.width, rect.height) / 2 - inset
        var path = Path()
        guard radius > 0, end > start else { return path }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(start), endAngle: .degrees(end), clockwise: true)
        return path
    }
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget { CodexUsageWidget() }
}
