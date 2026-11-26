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
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(900))))
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry
    var body: some View {
        Group { if family == .systemSmall { small } else { medium } }
            .fontDesign(.rounded).foregroundStyle(.primary)
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let account = entry.accounts.first(where: \.hasUsage) {
                VStack(alignment: .leading, spacing: 8) {
                    if let fiveHour = account.fiveHour { gauge(fiveHour) }
                    if let weekly = account.weekly { gauge(weekly) }
                }
                Spacer(minLength: 0); footer
            } else {
                Spacer(minLength: 0); Text(entry.status ?? "No usage available").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }.padding(14)
    }
    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if entry.accounts.contains(where: \.hasUsage) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(entry.accounts.filter(\.hasUsage)) { account in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(account.label).font(.caption.weight(.semibold)).lineLimit(1)
                            if let fiveHour = account.fiveHour { gauge(fiveHour) }
                            if let weekly = account.weekly { gauge(weekly) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0); footer
            } else {
                Spacer(minLength: 0); Text(entry.status ?? "No usage available").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }.padding(16)
    }
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("Usage").font(.caption.weight(.semibold)); Spacer(minLength: 0)
            if entry.accounts.count > 1 { Text("\(entry.accounts.count) accounts").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func gauge(_ allowance: Allowance) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(allowance.remaining) / 100)
                    .stroke(gaugeColor(allowance.remaining), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: allowance.title == "Week" ? "calendar" : "clock")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.frame(width: 31, height: 31)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(allowance.title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(allowance.remaining)%").font(.system(.body, design: .rounded, weight: .semibold).monospacedDigit())
                }
                if let reset = allowance.reset {
                    Text(reset, style: .relative).font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .ignore)
         .accessibilityLabel("\(allowance.title), \(allowance.remaining) percent remaining")
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

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget { CodexUsageWidget() }
}
