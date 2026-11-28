import AppKit
import SwiftUI
import WidgetKit
import UsageCore

private let appGroup = (Bundle.main.object(forInfoDictionaryKey: "UsageAppGroup") as? String)
    ?? "7FVL4J2UZ9.com.an-mzn.codex-usage"

private struct Allowance: Identifiable {
    let id: String
    let title: String
    let remaining: Int
    let reset: Date?
}

private struct AccountReading: Identifiable {
    let id: UUID
    let label: String
    let isClaude: Bool
    let isAntigravity: Bool
    let quotas: [Allowance]
    let fiveHour: Allowance?
    let weekly: Allowance?
    let resetCount: Int?

    init(profile: Profile) {
        id = profile.id
        label = profile.label
        isClaude = profile.claudeSnapshotPath != nil
        isAntigravity = profile.antigravitySnapshotPath != nil
        resetCount = profile.snapshot?.bankedResetCount
        let windows = profile.snapshot?.windows ?? []
        quotas = isAntigravity ? windows.prefix(2).map {
            Allowance(id: $0.id, title: $0.bucket, remaining: $0.remaining, reset: $0.reset)
        } : []
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
        self.isClaude = false
        self.isAntigravity = false
        self.quotas = []
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.resetCount = nil
    }
    var hasUsage: Bool { fiveHour != nil || weekly != nil }
}

private struct UsageEntry: TimelineEntry {
    let date: Date
    let accounts: [AccountReading]
    let refreshed: Date?
    let status: String?
}

private enum ResetCountdown {
    static let day: TimeInterval = 86_400

    static func step(for seconds: TimeInterval) -> TimeInterval {
        seconds > day ? day / 10 : 1800
    }

    static func roundedUnits(_ seconds: TimeInterval) -> Int {
        Int(ceil(max(0, seconds) / step(for: seconds) - 0.5))
    }

    static func nextChange(reset: Date, after date: Date) -> Date? {
        let seconds = reset.timeIntervalSince(date)
        let units = roundedUnits(seconds)
        guard units > 0 else { return nil }
        let boundary = (Double(units) - 0.5) * step(for: seconds)
        return reset.addingTimeInterval(-(seconds > day ? max(day, boundary) : boundary))
    }
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
        let horizon = entry.date.addingTimeInterval(12 * 3600)
        var dates = Set<Date>()
        var hasLaterChanges = false
        for account in entry.accounts.prefix(3) {
            for reset in ([account.fiveHour?.reset, account.weekly?.reset] + account.quotas.map(\.reset)).compactMap({ $0 }) {
                var date = entry.date
                while let boundary = ResetCountdown.nextChange(reset: reset, after: date), boundary > date {
                    guard boundary <= horizon else {
                        hasLaterChanges = true
                        break
                    }
                    dates.insert(boundary)
                    date = boundary
                }
            }
        }
        let updates = dates.sorted().map {
            UsageEntry(date: $0, accounts: entry.accounts, refreshed: entry.refreshed, status: entry.status)
        }
        completion(Timeline(entries: [entry] + updates, policy: hasLaterChanges ? .after(horizon) : .never))
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

struct UsageWidget: Widget {
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
    private static let logo = Bundle.main.url(forResource: "codex-usage", withExtension: "svg")
        .flatMap { NSImage(contentsOf: $0) }

    @Environment(\.colorScheme) private var colorScheme
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
            if let account = entry.accounts.first, account.isAntigravity {
                VStack(alignment: .leading, spacing: 6) {
                    accountName(account, size: 13)
                    quotaSummary(account)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if let account = entry.accounts.first {
                HStack(alignment: .center, spacing: 16) {
                    SplitAllowanceRing(fiveHour: account.fiveHour, weekly: account.weekly, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        accountName(account, size: 13)
                        compactAllowance(account.fiveHour, title: "5h")
                        compactAllowance(account.weekly, title: "Wk")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            } else {
                Spacer(minLength: 0)
                Text(entry.status ?? "No usage available").font(.caption).foregroundStyle(Color.primary.opacity(0.9))
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 8).padding(.vertical, 16)
    }
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !entry.accounts.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(entry.accounts.prefix(3))) { account in
                        VStack(alignment: .leading, spacing: 5) {
                            accountName(account, size: 12)
                            if account.isAntigravity {
                                quotaSummary(account)
                            } else {
                                HStack(spacing: 5) {
                                    SplitAllowanceRing(fiveHour: account.fiveHour, weekly: account.weekly, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if account.fiveHour != nil {
                                            compactAllowance(account.fiveHour, title: "5h")
                                        }
                                        compactAllowance(account.weekly, title: "Wk")
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                Spacer(minLength: 0)
                footer
            } else {
                Spacer(minLength: 0)
                Text(entry.status ?? "No usage available").font(.caption).foregroundStyle(Color.primary.opacity(0.9))
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 12).padding(.vertical, 15)
    }
    private var large: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if !entry.accounts.isEmpty {
                VStack(spacing: 3) {
                    ForEach(Array(entry.accounts.prefix(3))) { account in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                accountName(account, size: 13)
                                if let count = account.resetCount, count >= 0 {
                                    Text(count == 1 ? "1 reset" : "\(count) resets")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                }
                            }
                            .frame(width: 58, alignment: .leading)
                            if account.isAntigravity {
                                ForEach(account.quotas) { quota in
                                    allowanceColumn(quota, title: quota.title)
                                }
                            } else {
                                if let fiveHour = account.fiveHour {
                                    allowanceColumn(fiveHour, title: "5 hours")
                                }
                                allowanceColumn(account.weekly, title: "Weekly")
                            }
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
                Text(entry.status ?? "No usage available").font(.callout).foregroundStyle(Color.primary.opacity(0.9))
                Spacer(minLength: 0)
            }
        }.padding(16)
    }
    private func quotaSummary(_ account: AccountReading) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(account.quotas) { quota in
                VStack(alignment: .leading, spacing: 1) {
                    Text(quota.title)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(quota.remaining)%").fontWeight(.semibold)
                        if let reset = quota.reset {
                            Text(resetTimeLeft(reset)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }
        .font(.system(size: 10))
    }

    private static let openAILogo = providerLogo("openai")
    private static let googleLogo = providerLogo("google")
    private static let claudeLogo = providerLogo("claude")

    private static func providerLogo(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg")
            .flatMap { NSImage(contentsOf: $0) }
    }

    private func accountName(_ account: AccountReading, size: CGFloat) -> some View {
        HStack(spacing: 4) {
            let logo = account.isAntigravity ? Self.googleLogo : (account.isClaude ? Self.claudeLogo : Self.openAILogo)
            if let logo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                    .offset(y: 1)
                    .accessibilityHidden(true)
            }
            Text(account.label)
                .font(.system(size: size, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let logo = Self.logo {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            Text("Usage").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
        .offset(x: -2, y: -3)
    }
    private func resetTimeLeft(_ reset: Date) -> String {
        let seconds = max(0, reset.timeIntervalSince(entry.date))
        let units = ResetCountdown.roundedUnits(seconds)
        if seconds > ResetCountdown.day {
            let tenths = units % 10
            return tenths == 0 ? "\(units / 10)d" : "\(units / 10).\(tenths)d"
        }
        let halfHours = units
        return halfHours.isMultiple(of: 2) ? "\(halfHours / 2)h" : "\(halfHours / 2).5h"
    }

    @ViewBuilder
    private func compactAllowance(_ allowance: Allowance?, title: String) -> some View {
        if let allowance {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.9))
                    Text("\(allowance.remaining)%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .layoutPriority(1)
                }
                if let reset = allowance.reset {
                    Text(resetTimeLeft(reset))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.9))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.9))
                    Text("—").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.72))
                }
                Text("Unavailable").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
    private func allowanceColumn(_ allowance: Allowance?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.9))
            if let allowance {
                Text("\(allowance.remaining)% left")
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
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
                        Text(resetTimeLeft(reset)).lineLimit(1).minimumScaleFactor(0.75)
                    } else {
                        Text("Reset time unavailable").lineLimit(1).minimumScaleFactor(0.75)
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.9))
            } else {
                Text("—").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(Color.primary.opacity(0.72))
                Capsule().fill(.quaternary).frame(height: 4)
                Text("No limit reported").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.primary.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        HStack {
            if let refreshed = entry.refreshed {
                Text("Updated \(refreshed, style: .relative)").font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.primary.opacity(0.72))
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
    var body: some View {
        ZStack {
            if fiveHour == nil, let weekly {
                segment(weekly, from: 180, to: -180)
            } else {
                segment(fiveHour, from: 221, to: 319)
                segment(weekly, from: 197, to: -17)
            }
            RoundedRectangle(cornerRadius: size * 0.04)
                .fill(Color.primary.opacity(0.8))
                .frame(width: size * 0.24, height: size * 0.24)
                .rotationEffect(.degrees(45))
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

    private func segment(_ allowance: Allowance?, from start: Double, to end: Double) -> some View {
        let style = StrokeStyle(lineWidth: size * 0.065, lineCap: .round)
        let track = RingArc(start: start, end: end)
        let fraction = Double(allowance?.remaining ?? 0) / 100
        return track.stroke(.quaternary, style: style)
            .overlay {
                RingArc(start: start, end: start + (end - start) * fraction)
                    .stroke(Color.primary, style: style)
            }
    }
}

private struct RingArc: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let inset = rect.width * 0.08
        let radius = min(rect.width, rect.height) / 2 - inset
        var path = Path()
        guard radius > 0, end != start else { return path }
        if abs(end - start) == 360 {
            return Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius,
                                          width: 2 * radius, height: 2 * radius))
        }
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(start), endAngle: .degrees(end), clockwise: end < start)
        return path
    }
}

@main
struct UsageWidgetBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}
