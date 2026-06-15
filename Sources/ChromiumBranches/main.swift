import AppKit
import Foundation

struct VersionHistoryResponse: Decodable {
    struct Version: Decodable { let version: String }
    let versions: [Version]
}

struct ScheduleResponse: Decodable {
    let mstones: [Milestone]
}

struct Milestone: Decodable {
    let mstone: Int
    let branch_point: String?
    let feature_freeze: String?
    let earliest_beta: String?
    let latest_beta: String?
    let final_beta: String?
    let stable_date: String?
    let early_stable: String?
    let late_stable_date: String?
    let stable_refresh_first: String?
    let stable_refresh_second: String?
    let stable_refresh_third: String?
}

struct ChannelInfo {
    let name: String
    let version: String
    let milestone: Int
    let schedule: Milestone?
}

struct GerritAccount: Decodable {
    let name: String?
    let email: String?
    let username: String?
}

struct GerritMessage: Decodable {
    let date: String
    let message: String
    let author: GerritAccount?
}

struct GerritChange: Decodable {
    let changeNumber: Int
    let subject: String
    let status: String
    let branch: String
    let updated: String
    let owner: GerritAccount?
    let messages: [GerritMessage]?
    let submittable: Bool?
    let mergeable: Bool?

    enum CodingKeys: String, CodingKey {
        case changeNumber = "_number"
        case subject
        case status
        case branch
        case updated
        case owner
        case messages
        case submittable
        case mergeable
    }
}

struct GerritMergeable: Decodable {
    let mergeable: Bool
}

struct IssueInfo {
    let id: String
    let title: String
    let updated: String
}

struct GerritTarget {
    let host: String
    let project: String
    let id: String

    init(_ bookmark: String) {
        let parts = bookmark.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.count == 3 {
            host = parts[0]
            project = parts[1]
            id = parts[2]
        } else {
            host = "chromium-review.googlesource.com"
            project = "chromium/src"
            id = bookmark
        }
    }

    var displayID: String { id }
    var displayProject: String { project }
    var url: String { "https://\(host)/c/\(project)/+/\(id)" }
}

final class GerritService {
    private let session = URLSession.shared
    private let decoder = JSONDecoder()

    func loadChange(_ bookmark: String) async throws -> GerritChange {
        let target = GerritTarget(bookmark)
        let encodedProject = target.project.replacingOccurrences(of: "/", with: "%2F")
        let url = URL(string: "https://\(target.host)/changes/\(encodedProject)~\(target.id)/detail?o=MESSAGES&o=DETAILED_ACCOUNTS&o=SUBMITTABLE&o=LABELS")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ChromiumBranches", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not load CL \(target.id)"])
        }
        let detailText = stripXSSIPrefix(String(decoding: data, as: UTF8.self))
        let detail = try decoder.decode(GerritChange.self, from: Data(detailText.utf8))
        let mergeable = try? await loadMergeable(target, encodedProject: encodedProject)
        return GerritChange(
            changeNumber: detail.changeNumber,
            subject: detail.subject,
            status: detail.status,
            branch: detail.branch,
            updated: detail.updated,
            owner: detail.owner,
            messages: detail.messages,
            submittable: detail.submittable,
            mergeable: mergeable
        )
    }

    private func loadMergeable(_ target: GerritTarget, encodedProject: String) async throws -> Bool {
        let url = URL(string: "https://\(target.host)/changes/\(encodedProject)~\(target.id)/revisions/current/mergeable")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return true }
        let text = stripXSSIPrefix(String(decoding: data, as: UTF8.self))
        return try decoder.decode(GerritMergeable.self, from: Data(text.utf8)).mergeable
    }

    private func stripXSSIPrefix(_ text: String) -> String {
        text.hasPrefix(")]}'") ? String(text.dropFirst(5)) : text
    }
}

final class ChromiumDataService {
    private let session = URLSession.shared
    private let jsonDecoder = JSONDecoder()
    private let channels = ["stable", "beta", "dev", "canary"]

    func load() async throws -> [ChannelInfo] {
        try await withThrowingTaskGroup(of: ChannelInfo.self) { group in
            for channel in channels {
                group.addTask { try await self.loadChannel(channel) }
            }

            var result: [ChannelInfo] = []
            for try await item in group { result.append(item) }
            result = try await self.adjustCanaryMilestone(result)
            return result.sorted { channelOrder($0.name) < channelOrder($1.name) }
        }
    }

    private func loadChannel(_ channel: String) async throws -> ChannelInfo {
        let version = try await fetchVersion(channel)
        let milestone = Int(version.split(separator: ".").first ?? "0") ?? 0
        let schedule = try? await fetchSchedule(milestone)
        return ChannelInfo(name: channel, version: version, milestone: milestone, schedule: schedule)
    }

    private func adjustCanaryMilestone(_ channels: [ChannelInfo]) async throws -> [ChannelInfo] {
        guard let dev = channels.first(where: { $0.name == "dev" }),
              let canary = channels.first(where: { $0.name == "canary" }),
              dev.milestone == canary.milestone,
              hasBranched(dev.schedule?.branch_point) else {
            return channels
        }

        let nextMilestone = dev.milestone + 1
        let nextSchedule = try? await fetchSchedule(nextMilestone)
        return channels.map { channel in
            if channel.name == "canary" {
                return ChannelInfo(name: channel.name, version: channel.version, milestone: nextMilestone, schedule: nextSchedule)
            }
            return channel
        }
    }

    private func hasBranched(_ value: String?) -> Bool {
        guard let days = daysUntil(value) else { return false }
        return days <= 0
    }

    private func fetchVersion(_ channel: String) async throws -> String {
        let url = URL(string: "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/\(channel)/versions/?pageSize=1")!
        let (data, response) = try await session.data(from: url)
        try validate(response)
        let decoded = try jsonDecoder.decode(VersionHistoryResponse.self, from: data)
        guard let version = decoded.versions.first?.version else {
            throw NSError(domain: "ChromiumBranches", code: 1, userInfo: [NSLocalizedDescriptionKey: "No version for \(channel)"])
        }
        return version
    }

    private func fetchSchedule(_ milestone: Int) async throws -> Milestone? {
        let url = URL(string: "https://chromiumdash.appspot.com/fetch_milestone_schedule?mstone=\(milestone)")!
        let (data, response) = try await session.data(from: url)
        try validate(response)
        return try jsonDecoder.decode(ScheduleResponse.self, from: data).mstones.first
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ChromiumBranches", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network request failed"])
        }
    }
}

private func channelOrder(_ name: String) -> Int {
    switch name {
    case "stable": return 0
    case "beta": return 1
    case "dev": return 2
    case "canary": return 3
    default: return 99
    }
}

private func channelEmoji(_ name: String) -> String {
    switch name {
    case "stable": return "●"
    case "beta": return "●"
    case "dev": return "●"
    case "canary": return "●"
    default: return "●"
    }
}

private func channelColor(_ name: String) -> NSColor {
    switch name {
    case "stable": return NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.32, alpha: 1)
    case "beta": return NSColor(calibratedRed: 0.16, green: 0.43, blue: 0.86, alpha: 1)
    case "dev": return NSColor(calibratedRed: 0.86, green: 0.46, blue: 0.12, alpha: 1)
    case "canary": return NSColor(calibratedRed: 0.82, green: 0.62, blue: 0.10, alpha: 1)
    default: return NSColor.secondaryLabelColor
    }
}

private let readableGreen = NSColor(calibratedRed: 0.18, green: 0.55, blue: 0.28, alpha: 1)
private let timelineBackground = NSColor(calibratedWhite: 0.97, alpha: 1)
private let timelinePrimaryText = NSColor(calibratedWhite: 0.10, alpha: 1)
private let timelineSecondaryText = NSColor(calibratedWhite: 0.34, alpha: 1)
private let timelineMutedText = NSColor(calibratedWhite: 0.52, alpha: 1)

private func coloredTitle(_ text: String, color: NSColor, bold: Bool = false) -> NSAttributedString {
    let font = bold ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.menuFont(ofSize: 0)
    return NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font])
}

private func displayName(_ name: String) -> String {
    name.prefix(1).uppercased() + name.dropFirst()
}

private let inputFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
}()

private let shortFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return inputFormatter.date(from: value.replacingOccurrences(of: "Z", with: ""))
}

private func dateText(_ value: String?) -> String {
    guard let date = parseDate(value) else { return "TBD" }
    return shortFormatter.string(from: date)
}

private func daysUntil(_ value: String?) -> Int? {
    guard let date = parseDate(value) else { return nil }
    return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day
}

private func relativeText(_ value: String?) -> String {
    guard let days = daysUntil(value) else { return "TBD" }
    if days == 0 { return "today" }
    if days == 1 { return "tomorrow" }
    if days == -1 { return "yesterday" }
    if days > 0 { return "in \(days)d" }
    return "\(-days)d ago"
}

private func branchCountdownText(_ value: String?) -> String {
    guard let days = daysUntil(value) else { return "branch TBD" }
    if days == 0 { return "branches today" }
    if days == 1 { return "branches tomorrow" }
    if days > 1 { return "branches in \(days)d" }
    if days == -1 { return "branched yesterday" }
    return "branched \(-days)d ago"
}

struct TimelineEvent {
    let date: Date
    let milestone: Int
    let channel: String
    let title: String
    let subtitle: String
    let color: NSColor
}

final class TimelineView: NSView {
    let events: [TimelineEvent]

    init(events: [TimelineEvent]) {
        self.events = events.sorted {
            if $0.milestone != $1.milestone { return $0.milestone < $1.milestone }
            return $0.date < $1.date
        }
        let milestoneCount = Set(events.map { $0.milestone }).count
        let height = max(170, events.count * 32 + milestoneCount * 26 + 28)
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: CGFloat(height)))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        timelineBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 4), xRadius: 12, yRadius: 12).fill()
        guard !events.isEmpty else { return }
        let lineX: CGFloat = 34
        let top = bounds.maxY - 20
        let bottom: CGFloat = 18

        NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: lineX, y: bottom))
        line.line(to: NSPoint(x: lineX, y: top - 14))
        line.lineWidth = 2
        line.stroke()

        var y = top
        var currentMilestone: Int?
        for event in events {
            if currentMilestone != event.milestone {
                currentMilestone = event.milestone
                drawMilestoneHeader(event.milestone, y: y)
                y -= 26
            }

            drawEvent(event, y: y, lineX: lineX)
            y -= 32
        }
    }

    private func drawMilestoneHeader(_ milestone: Int, y: CGFloat) {
        let rect = NSRect(x: 18, y: y - 17, width: 64, height: 20)
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        ("M\(milestone)" as NSString).draw(in: NSRect(x: 34, y: y - 14, width: 42, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: timelinePrimaryText])
    }

    private func drawEvent(_ event: TimelineEvent, y: CGFloat, lineX: CGFloat) {
        let today = Calendar.current.startOfDay(for: Date())
        let eventDay = Calendar.current.startOfDay(for: event.date)
        let isToday = eventDay == today
        let isPast = eventDay < today

        if isToday {
            NSColor(calibratedRed: 0.86, green: 0.92, blue: 1.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 14, y: y - 12, width: 522, height: 24), xRadius: 8, yRadius: 8).fill()
            ("TODAY" as NSString).draw(in: NSRect(x: 482, y: y - 8, width: 48, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: channelColor("beta")])
        }

        event.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: lineX - 6, y: y - 6, width: 12, height: 12)).fill()

        let titleColor = isPast ? timelineMutedText : timelinePrimaryText
        let rel = relativeText(inputFormatter.string(from: event.date))
        let date = shortFormatter.string(from: event.date)
        let channelText = displayName(event.channel)

        (event.title as NSString).draw(in: NSRect(x: 56, y: y - 8, width: 154, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: titleColor])
        (channelText as NSString).draw(in: NSRect(x: 214, y: y - 8, width: 66, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: highContrastChannelColor(event.channel)])
        (event.subtitle as NSString).draw(in: NSRect(x: 284, y: y - 8, width: 62, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: timelineSecondaryText])
        (date as NSString).draw(in: NSRect(x: 350, y: y - 8, width: 92, height: 18), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: timelineSecondaryText])
        (rel as NSString).draw(in: NSRect(x: 444, y: y - 8, width: 76, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: highContrastRelativeColor(rel)])
    }
}

private func relativeColorStatic(_ text: String) -> NSColor {
    if text == "today" || text == "tomorrow" { return NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.10, alpha: 1) }
    if text.hasPrefix("in ") { return readableGreen }
    if text == "TBD" { return NSColor.secondaryLabelColor }
    return NSColor.tertiaryLabelColor
}

private func highContrastRelativeColor(_ text: String) -> NSColor {
    if text == "today" || text == "tomorrow" { return NSColor(calibratedRed: 0.72, green: 0.30, blue: 0.06, alpha: 1) }
    if text.hasPrefix("in ") { return NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.20, alpha: 1) }
    if text == "TBD" { return timelineMutedText }
    return timelineMutedText
}

private func highContrastChannelColor(_ name: String) -> NSColor {
    switch name {
    case "stable": return NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.18, alpha: 1)
    case "beta": return NSColor(calibratedRed: 0.08, green: 0.26, blue: 0.65, alpha: 1)
    case "dev": return NSColor(calibratedRed: 0.62, green: 0.28, blue: 0.04, alpha: 1)
    case "canary": return NSColor(calibratedRed: 0.55, green: 0.38, blue: 0.02, alpha: 1)
    default: return timelineSecondaryText
    }
}

final class CardBackgroundView: NSView {
    let color: NSColor
    let progress: CGFloat

    init(color: NSColor, progress: CGFloat) {
        self.color = color
        self.progress = max(0, min(1, progress))
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds.insetBy(dx: 8, dy: 5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        path.fill()

        color.withAlphaComponent(0.16).setFill()
        path.fill()

        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.minX, y: bounds.minY, width: 5, height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()

        let track = NSRect(x: bounds.minX + 18, y: bounds.minY + 13, width: bounds.width - 36, height: 5)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()

        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * progress, height: track.height)
        color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = ChromiumDataService()
    private let gerritService = GerritService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var channels: [ChannelInfo] = []
    private var clInfos: [String: GerritChange] = [:]
    private var clErrors: [String: String] = [:]
    private var issueInfos: [String: IssueInfo] = [:]
    private var issueErrors: [String: String] = [:]
    private var lastUpdated: Date?
    private var refreshTimer: Timer?
    private let visibleChannelsKey = "visibleMenuBarChannels"
    private let clBookmarksKey = "clBookmarks"
    private let issueBookmarksKey = "issueBookmarks"
    private let defaultVisibleChannels: Set<String> = ["stable", "beta", "dev", "canary"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        statusItem.button?.title = "Cr ..."
        statusItem.button?.toolTip = "Chromium branch/channel schedule"
        rebuildMenu(loading: true, error: nil)
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func refresh() {
        statusItem.button?.title = "Cr ..."
        rebuildMenu(loading: true, error: nil)
        Task {
            do {
                channels = try await service.load()
                await refreshBookmarks(rebuild: false)
                lastUpdated = Date()
                updateTitle()
                rebuildMenu(loading: false, error: nil)
            } catch {
                statusItem.button?.title = "Cr !"
                rebuildMenu(loading: false, error: error.localizedDescription)
            }
        }
    }

    private func updateTitle() {
        let visible = visibleMenuBarChannels()
        let parts = channels
            .filter { visible.contains($0.name) }
            .sorted { channelOrder($0.name) < channelOrder($1.name) }
            .map { menuBarPart($0) }

        let title = parts.isEmpty ? "● Cr" : parts.joined(separator: "  ")
        let attributed = NSMutableAttributedString(string: title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
        colorDot(in: attributed, marker: "● S", color: channelColor("stable"))
        colorDot(in: attributed, marker: "● B", color: channelColor("beta"))
        colorDot(in: attributed, marker: "● D", color: channelColor("dev"))
        colorDot(in: attributed, marker: "● C", color: channelColor("canary"))
        colorDot(in: attributed, marker: "● Cr", color: channelColor("stable"))
        statusItem.button?.attributedTitle = attributed
    }

    private func menuBarPart(_ channel: ChannelInfo) -> String {
        let letter = String(displayName(channel.name).prefix(1))
        if channel.name == "dev" || channel.name == "canary" {
            return "● \(letter)\(channel.milestone) (\(menuBarBranchText(channel.schedule?.branch_point)))"
        }
        return "● \(letter)\(channel.milestone)"
    }

    private func menuBarBranchText(_ value: String?) -> String {
        guard let days = daysUntil(value) else { return "br?" }
        if days == 0 { return "br today" }
        if days > 0 { return "br \(days)d" }
        return "br+\(-days)d"
    }

    private func colorDot(in string: NSMutableAttributedString, marker: String, color: NSColor) {
        let ns = string.string as NSString
        let range = ns.range(of: marker)
        if range.location != NSNotFound {
            string.addAttribute(.foregroundColor, value: color, range: NSRange(location: range.location, length: 1))
        }
    }

    private func rebuildMenu(loading: Bool, error: String?) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Chromium Branches", action: nil, keyEquivalent: "")
        header.attributedTitle = coloredTitle("Chromium Branches", color: NSColor.labelColor, bold: true)
        header.isEnabled = false
        menu.addItem(header)

        if loading {
            let item = NSMenuItem(title: "Refreshing schedule...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if let error {
            let item = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !channels.isEmpty {
            menu.addItem(.separator())
            addAtAGlance(to: menu)
            menu.addItem(.separator())
            for channel in channels {
                addChannel(channel, to: menu)
            }
            menu.addItem(.separator())
            addScheduleTimeline(to: menu)
            addMilestoneSummary(to: menu)
        }

        menu.addItem(.separator())
        addCLStatusSection(to: menu)

        menu.addItem(.separator())
        addMenuBarVisibilitySection(to: menu)

        menu.addItem(.separator())
        if let lastUpdated {
            let updated = NSMenuItem(title: "Updated \(shortFormatter.string(from: lastUpdated)) \(DateFormatter.localizedString(from: lastUpdated, dateStyle: .none, timeStyle: .short))", action: nil, keyEquivalent: "")
            updated.isEnabled = false
            menu.addItem(updated)
        }

        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open ChromiumDash Schedule", action: #selector(openSchedule), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func addAtAGlance(to menu: NSMenu) {
        let root = NSMenuItem(title: "At a glance", action: nil, keyEquivalent: "")
        root.attributedTitle = coloredTitle("At a glance", color: NSColor.labelColor, bold: true)
        let submenu = NSMenu()
        for insight in confusionResolverInsights() {
            submenu.addItem(insightItem(insight))
        }
        root.submenu = submenu
        menu.addItem(root)
    }

    private func confusionResolverInsights() -> [String] {
        var insights: [String] = []
        let stable = channels.first { $0.name == "stable" }
        let beta = channels.first { $0.name == "beta" }
        let dev = channels.first { $0.name == "dev" }
        let canary = channels.first { $0.name == "canary" }

        if let stable, let beta, stable.milestone == beta.milestone {
            insights.append("M\(stable.milestone) is both Stable and Beta right now. That is a channel promotion overlap, not a new branch.")
        }

        if let beta, let dev, beta.milestone == dev.milestone {
            insights.append("M\(beta.milestone) is both Beta and Dev right now. Dev has not moved to the next milestone yet.")
        }

        if let dev, let branchDays = daysUntil(dev.schedule?.branch_point), branchDays <= 0 {
            insights.append("M\(dev.milestone) Dev already branched \(relativeText(dev.schedule?.branch_point)). New trunk work belongs to the next milestone.")
        }

        if let dev, let canary, canary.milestone == dev.milestone + 1 {
            let binaryMilestone = Int(canary.version.split(separator: ".").first ?? "0") ?? canary.milestone
            if binaryMilestone != canary.milestone {
                insights.append("Canary binary is still \(binaryMilestone).x, but schedule-wise Canary is treated as M\(canary.milestone).")
            } else {
                insights.append("Canary is on the next milestone, M\(canary.milestone), while Dev remains M\(dev.milestone).")
            }
        }

        if let next = nextTimelineEvent() {
            insights.append("Next schedule event: M\(next.milestone) \(displayName(next.channel)) \(next.title.lowercased()) on \(dateText(inputFormatter.string(from: next.date))) (\(relativeText(inputFormatter.string(from: next.date)))).")
        }

        if insights.isEmpty {
            insights.append("No channel overlap or branch gap detected. The channels line up normally.")
        }
        return insights
    }

    private func nextTimelineEvent() -> TimelineEvent? {
        let start = Calendar.current.startOfDay(for: Date())
        return timelineEvents().filter { Calendar.current.startOfDay(for: $0.date) >= start }.sorted { $0.date < $1.date }.first
    }

    private func insightItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 500
        let height = heightForInsight(text, width: width)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let icon = NSTextField(labelWithString: "?")
        icon.frame = NSRect(x: 16, y: height - 30, width: 20, height: 18)
        icon.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        icon.textColor = channelColor("beta")
        icon.alignment = .center
        view.addSubview(icon)

        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 44, y: 8, width: width - 62, height: height - 14)
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor.labelColor
        view.addSubview(label)

        item.view = view
        return item
    }

    private func heightForInsight(_ text: String, width: CGFloat) -> CGFloat {
        let maxTextWidth = width - 62
        let rect = (text as NSString).boundingRect(with: NSSize(width: maxTextWidth, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular)])
        return max(36, ceil(rect.height) + 18)
    }

    private func addChannel(_ channel: ChannelInfo, to menu: NSMenu) {
        let branch = branchCountdownText(channel.schedule?.branch_point)
        let title = "\(channelEmoji(channel.name)) \(displayName(channel.name)): M\(channel.milestone) (\(channel.version))"
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.attributedTitle = channelMenuTitle(channel, title: title)

        let submenu = NSMenu()
        submenu.addItem(channelCardItem(channel))
        submenu.addItem(.separator())
        if channel.name == "dev" || channel.name == "canary" {
            submenu.addItem(detailItem(label: "Branch", value: branch, meta: nil, valueColor: branchCountdownColor(channel.schedule?.branch_point), boldValue: true))
            submenu.addItem(.separator())
        }
        submenu.addItem(detailItem(label: "Branch point", value: dateText(channel.schedule?.branch_point), meta: relativeText(channel.schedule?.branch_point)))
        submenu.addItem(detailItem(label: "Beta starts", value: dateText(channel.schedule?.earliest_beta), meta: relativeText(channel.schedule?.earliest_beta)))
        submenu.addItem(detailItem(label: "Beta ends", value: dateText(channel.schedule?.latest_beta), meta: relativeText(channel.schedule?.latest_beta)))
        submenu.addItem(detailItem(label: "Final beta cut", value: dateText(channel.schedule?.final_beta), meta: relativeText(channel.schedule?.final_beta)))
        submenu.addItem(detailItem(label: "Stable", value: dateText(channel.schedule?.stable_date), meta: relativeText(channel.schedule?.stable_date), valueColor: readableGreen, boldValue: true))
        if channel.schedule?.stable_refresh_first != nil {
            submenu.addItem(detailItem(label: "Refresh 1", value: dateText(channel.schedule?.stable_refresh_first), meta: relativeText(channel.schedule?.stable_refresh_first)))
        }
        root.submenu = submenu
        menu.addItem(root)
    }

    private func channelCardItem(_ channel: ChannelInfo) -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 440
        let height: CGFloat = 92
        let view = CardBackgroundView(color: channelColor(channel.name), progress: scheduleProgress(channel.schedule))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let dot = NSTextField(labelWithString: "●")
        dot.frame = NSRect(x: 24, y: 55, width: 18, height: 22)
        dot.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        dot.textColor = channelColor(channel.name)
        view.addSubview(dot)

        let title = NSTextField(labelWithString: "M\(channel.milestone) \(displayName(channel.name))")
        title.frame = NSRect(x: 46, y: 56, width: 160, height: 20)
        title.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        title.textColor = NSColor.labelColor
        view.addSubview(title)

        let version = NSTextField(labelWithString: channel.version)
        version.frame = NSRect(x: 214, y: 57, width: 200, height: 18)
        version.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        version.textColor = NSColor.secondaryLabelColor
        version.alignment = .right
        view.addSubview(version)

        let branch = NSTextField(labelWithString: "Branch: \(dateText(channel.schedule?.branch_point)) (\(relativeText(channel.schedule?.branch_point)))")
        branch.frame = NSRect(x: 24, y: 34, width: 190, height: 17)
        branch.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        branch.textColor = branchCountdownColor(channel.schedule?.branch_point)
        view.addSubview(branch)

        let stable = NSTextField(labelWithString: "Stable: \(dateText(channel.schedule?.stable_date))")
        stable.frame = NSRect(x: 214, y: 34, width: 200, height: 17)
        stable.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stable.textColor = readableGreen
        stable.alignment = .right
        view.addSubview(stable)

        item.view = view
        return item
    }

    private func scheduleProgress(_ schedule: Milestone?) -> CGFloat {
        guard let branch = parseDate(schedule?.branch_point), let stable = parseDate(schedule?.stable_date) else { return 0 }
        let total = stable.timeIntervalSince(branch)
        guard total > 0 else { return 0 }
        return CGFloat((Date().timeIntervalSince(branch)) / total)
    }

    private func channelMenuTitle(_ channel: ChannelInfo, title: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 0)])
        result.addAttribute(.foregroundColor, value: channelColor(channel.name), range: NSRange(location: 0, length: 1))
        result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: (title as NSString).range(of: displayName(channel.name)))
        if channel.name == "dev" || channel.name == "canary" {
            let suffix = "  -  \(branchCountdownText(channel.schedule?.branch_point))"
            result.append(NSAttributedString(string: suffix, attributes: [.foregroundColor: branchCountdownColor(channel.schedule?.branch_point), .font: NSFont.menuFont(ofSize: 0)]))
        }
        return result
    }

    private func branchCountdownColor(_ value: String?) -> NSColor {
        guard let days = daysUntil(value) else { return NSColor.secondaryLabelColor }
        if days < 0 { return NSColor.secondaryLabelColor }
        if days <= 2 { return NSColor(calibratedRed: 0.78, green: 0.16, blue: 0.14, alpha: 1) }
        if days <= 7 { return NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.10, alpha: 1) }
        return readableGreen
    }

    private func detailItem(label: String, value: String, meta: String?, valueColor: NSColor = NSColor.labelColor, boldValue: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 430
        let height: CGFloat = 30
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let labelField = NSTextField(labelWithString: label)
        labelField.frame = NSRect(x: 14, y: 6, width: 118, height: 18)
        labelField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelField.textColor = NSColor.secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail
        view.addSubview(labelField)

        let valueField = NSTextField(labelWithString: value)
        valueField.frame = NSRect(x: 140, y: 5, width: 165, height: 20)
        valueField.font = boldValue ? NSFont.boldSystemFont(ofSize: 14) : NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        valueField.textColor = valueColor
        valueField.lineBreakMode = .byTruncatingTail
        view.addSubview(valueField)

        if let meta {
            let pill = NSTextField(labelWithString: meta)
            pill.frame = NSRect(x: 310, y: 5, width: 106, height: 20)
            pill.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            pill.textColor = relativeColor(meta)
            pill.alignment = .right
            pill.lineBreakMode = .byTruncatingTail
            view.addSubview(pill)
        }

        item.view = view
        return item
    }

    private func relativeColor(_ text: String) -> NSColor {
        relativeColorStatic(text)
    }

    private func addScheduleTimeline(to menu: NSMenu) {
        let root = NSMenuItem(title: "Schedule Timeline", action: nil, keyEquivalent: "")
        root.attributedTitle = coloredTitle("Schedule Timeline", color: NSColor.labelColor, bold: true)
        let submenu = NSMenu()
        submenu.addItem(timelineMenuItem())
        root.submenu = submenu
        menu.addItem(root)
    }

    private func timelineMenuItem() -> NSMenuItem {
        let events = timelineEvents()
        let item = NSMenuItem()
        let milestoneCount = Set(events.map { $0.milestone }).count
        let containerHeight = CGFloat(max(210, events.count * 32 + milestoneCount * 26 + 88))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: containerHeight))

        let title = NSTextField(labelWithString: "Chrome release schedule")
        title.frame = NSRect(x: 18, y: container.bounds.maxY - 32, width: 300, height: 20)
        title.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        title.textColor = timelinePrimaryText
        container.addSubview(title)

        let hint = NSTextField(labelWithString: "Branch, beta, stable, and refresh dates from ChromiumDash")
        hint.frame = NSRect(x: 18, y: container.bounds.maxY - 52, width: 500, height: 16)
        hint.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hint.textColor = timelineSecondaryText
        container.addSubview(hint)

        let timeline = TimelineView(events: events)
        timeline.frame = NSRect(x: 0, y: 0, width: 560, height: container.bounds.height - 56)
        container.addSubview(timeline)

        item.view = container
        return item
    }

    private func timelineEvents() -> [TimelineEvent] {
        var result: [TimelineEvent] = []
        let today = Calendar.current.startOfDay(for: Date())
        let latestPast = Calendar.current.date(byAdding: .day, value: -10, to: today) ?? today
        let latestFuture = Calendar.current.date(byAdding: .day, value: 90, to: today) ?? today

        let visible = visibleMenuBarChannels()
        for channel in channels.filter({ visible.contains($0.name) }).sorted(by: { channelOrder($0.name) < channelOrder($1.name) }) {
            let color = channelColor(channel.name)
            appendEvent(&result, channel: channel, date: parseDate(channel.schedule?.branch_point), title: "Branch point", subtitle: "branch", color: color)
            appendEvent(&result, channel: channel, date: parseDate(channel.schedule?.earliest_beta), title: "Beta starts", subtitle: "beta", color: channelColor("beta"))
            appendEvent(&result, channel: channel, date: parseDate(channel.schedule?.stable_date), title: "Stable release", subtitle: "stable", color: channelColor("stable"))
            appendEvent(&result, channel: channel, date: parseDate(channel.schedule?.stable_refresh_first), title: "Stable refresh", subtitle: "refresh", color: readableGreen)
        }

        return result
            .filter { $0.date >= latestPast && $0.date <= latestFuture }
            .sorted { $0.date < $1.date }
    }

    private func appendEvent(_ events: inout [TimelineEvent], channel: ChannelInfo, date: Date?, title: String, subtitle: String, color: NSColor) {
        guard let date else { return }
        events.append(TimelineEvent(date: date, milestone: channel.milestone, channel: channel.name, title: title, subtitle: subtitle, color: color))
    }

    private func addMilestoneSummary(to menu: NSMenu) {
        let unique = Dictionary(grouping: channels, by: { $0.milestone }).keys.sorted()
        for milestone in unique {
            let names = channels.filter { $0.milestone == milestone }.map { displayName($0.name) }.joined(separator: ", ")
            let schedule = channels.first { $0.milestone == milestone }?.schedule
            let item = disabled("M\(milestone): \(names) | branch \(dateText(schedule?.branch_point)) (\(relativeText(schedule?.branch_point))) | stable \(dateText(schedule?.stable_date))")
            item.attributedTitle = coloredTitle(item.title, color: NSColor.secondaryLabelColor)
            menu.addItem(item)
        }
    }

    private func addCLStatusSection(to menu: NSMenu) {
        let root = NSMenuItem(title: "CL Status", action: nil, keyEquivalent: "")
        root.attributedTitle = coloredTitle("CL Status", color: NSColor.labelColor, bold: true)
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Add CL or Issue...", action: #selector(addStatusBookmark), keyEquivalent: ""))
        if !clBookmarks().isEmpty || !issueBookmarks().isEmpty {
            submenu.addItem(NSMenuItem(title: "Refresh Bookmarks", action: #selector(refreshBookmarksNow), keyEquivalent: ""))
            submenu.addItem(.separator())
            for id in clBookmarks() {
                addCLBookmarkItem(id, to: submenu)
            }
            for id in issueBookmarks() {
                addIssueBookmarkItem(id, to: submenu)
            }
        }
        root.submenu = submenu
        menu.addItem(root)
    }

    private func addCLBookmarkItem(_ id: String, to menu: NSMenu) {
        let target = GerritTarget(id)
        let title: String
        if let info = clInfos[id] {
            title = "CL \(target.displayID): \(clDisplayStatus(info)) - \(info.subject)"
        } else if let error = clErrors[id] {
            title = "CL \(target.displayID): error - \(error)"
        } else {
            title = "CL \(target.displayID): loading"
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = statusMenuTitle(kind: "CL", id: target.displayID, title: title, color: clInfos[id].map { clStatusColor($0) } ?? NSColor.secondaryLabelColor)
        let submenu = NSMenu()
        if let info = clInfos[id] {
            submenu.addItem(detailItem(label: "Status", value: clDisplayStatus(info), meta: nil, valueColor: clStatusColor(info), boldValue: true))
            submenu.addItem(detailItem(label: "Gerrit state", value: info.status, meta: nil))
            submenu.addItem(detailItem(label: "Updated", value: prettyGerritDate(info.updated), meta: nil))
            submenu.addItem(detailItem(label: "Project", value: target.displayProject, meta: nil))
            submenu.addItem(detailItem(label: "Branch", value: info.branch, meta: nil))
            submenu.addItem(detailItem(label: "Owner", value: accountName(info.owner), meta: nil))
            submenu.addItem(messageItem(title: info.subject, body: latestMessageText(info)))
        } else if let error = clErrors[id] {
            submenu.addItem(messageItem(title: "Could not load CL", body: error))
        } else {
            submenu.addItem(disabled("Loading..."))
        }
        submenu.addItem(.separator())
        let open = NSMenuItem(title: "Open in Gerrit", action: #selector(openCL(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = id
        submenu.addItem(open)
        let remove = NSMenuItem(title: "Remove Bookmark", action: #selector(removeCLBookmark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        submenu.addItem(remove)
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addIssueBookmarkItem(_ id: String, to menu: NSMenu) {
        let title: String
        if let info = issueInfos[id] {
            title = "Issue \(id): \(info.title)"
        } else if let error = issueErrors[id] {
            title = "Issue \(id): error - \(error)"
        } else {
            title = "Issue \(id): loading"
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = statusMenuTitle(kind: "Issue", id: id, title: title, color: channelColor("dev"))
        let submenu = NSMenu()
        if let info = issueInfos[id] {
            submenu.addItem(detailItem(label: "Status", value: "Bookmarked", meta: nil, valueColor: channelColor("dev"), boldValue: true))
            submenu.addItem(detailItem(label: "Updated", value: info.updated, meta: nil))
            submenu.addItem(messageItem(title: "Issue \(id)", body: info.title))
        } else if let error = issueErrors[id] {
            submenu.addItem(messageItem(title: "Could not load issue", body: error))
        } else {
            submenu.addItem(disabled("Loading..."))
        }
        submenu.addItem(.separator())
        let open = NSMenuItem(title: "Open in Issues", action: #selector(openIssueBookmark(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = id
        submenu.addItem(open)
        let remove = NSMenuItem(title: "Remove Bookmark", action: #selector(removeIssueBookmark(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        submenu.addItem(remove)
        item.submenu = submenu
        menu.addItem(item)
    }

    private func statusMenuTitle(kind: String, id: String, title: String, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "● \(title)", attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 0)])
        result.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        result.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: (result.string as NSString).range(of: "\(kind) \(id)"))
        return result
    }

    private func messageItem(title: String, body: String) -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 500
        let text = body.isEmpty ? "No messages yet." : body
        let bodyHeight = heightForInsight(text, width: width) + 12
        let height = max(CGFloat(70), bodyHeight + 32)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let titleField = NSTextField(labelWithString: title)
        titleField.frame = NSRect(x: 14, y: height - 26, width: width - 28, height: 18)
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleField.textColor = NSColor.labelColor
        titleField.lineBreakMode = .byTruncatingTail
        view.addSubview(titleField)

        let bodyField = NSTextField(wrappingLabelWithString: text)
        bodyField.frame = NSRect(x: 14, y: 8, width: width - 28, height: height - 38)
        bodyField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        bodyField.textColor = NSColor.secondaryLabelColor
        view.addSubview(bodyField)

        item.view = view
        return item
    }

    private func latestMessageText(_ info: GerritChange) -> String {
        guard let message = info.messages?.last else { return "No messages yet." }
        let author = accountName(message.author)
        let text = message.message.replacingOccurrences(of: "\n\n", with: "\n")
        return "\(author), \(prettyGerritDate(message.date))\n\(text)"
    }

    private func accountName(_ account: GerritAccount?) -> String {
        account?.name ?? account?.email ?? account?.username ?? "unknown"
    }

    private func clDisplayStatus(_ info: GerritChange) -> String {
        switch info.status.uppercased() {
        case "MERGED": return "MERGED"
        case "ABANDONED": return "ABANDONED"
        default:
            if info.mergeable == false { return "MERGE CONFLICT" }
            if info.submittable == true { return "SUBMITTABLE" }
            return "ACTIVE"
        }
    }

    private func clStatusColor(_ info: GerritChange) -> NSColor {
        switch clDisplayStatus(info) {
        case "MERGED", "SUBMITTABLE": return readableGreen
        case "ABANDONED", "MERGE CONFLICT": return NSColor(calibratedRed: 0.72, green: 0.18, blue: 0.14, alpha: 1)
        default: return channelColor("beta")
        }
    }

    private func prettyGerritDate(_ value: String) -> String {
        String(value.prefix(10))
    }

    private func clBookmarks() -> [String] {
        UserDefaults.standard.array(forKey: clBookmarksKey) as? [String] ?? []
    }

    private func setCLBookmarks(_ bookmarks: [String]) {
        UserDefaults.standard.set(bookmarks, forKey: clBookmarksKey)
    }

    private func issueBookmarks() -> [String] {
        UserDefaults.standard.array(forKey: issueBookmarksKey) as? [String] ?? []
    }

    private func setIssueBookmarks(_ bookmarks: [String]) {
        UserDefaults.standard.set(bookmarks, forKey: issueBookmarksKey)
    }

    private func extractCLBookmark(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.allSatisfy({ $0.isNumber }) { return trimmed }
        if let pdfium = firstRegexGroup(#"pdfium-review\.googlesource\.com/c/pdfium/\+/(\d+)"#, in: trimmed) {
            return "pdfium-review.googlesource.com:pdfium:\(pdfium)"
        }
        if let chromium = firstRegexGroup(#"chromium-review\.googlesource\.com/c/chromium/src/\+/(\d+)"#, in: trimmed) {
            return chromium
        }
        let patterns = [#"/\+/(\d+)"#, #"crrev\.com/c/(\d+)"#, #"/c/[^/]+/\+/(\d+)"#]
        for pattern in patterns {
            if let match = firstRegexGroup(pattern, in: trimmed) { return match }
        }
        return nil
    }

    private func extractIssueId(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"issues\.chromium\.org/issues/(\d+)"#, #"bugs\.chromium\.org/p/chromium/issues/detail\?id=(\d+)"#, #"crbug\.com/(\d+)"#, #"^issue[: ]*(\d+)$"#]
        for pattern in patterns {
            if let match = firstRegexGroup(pattern, in: trimmed) { return match }
        }
        return nil
    }

    private func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func refreshBookmarks(rebuild: Bool) async {
        await refreshCLBookmarks(rebuild: false)
        refreshIssueBookmarks()
        if rebuild { rebuildMenu(loading: false, error: nil) }
    }

    private func refreshIssueBookmarks() {
        for id in issueBookmarks() {
            issueInfos[id] = IssueInfo(id: id, title: "Open Chromium issue \(id) for full details", updated: "online")
            issueErrors.removeValue(forKey: id)
        }
    }

    private func refreshCLBookmarks(rebuild: Bool) async {
        let ids = clBookmarks()
        guard !ids.isEmpty else { return }
        await withTaskGroup(of: (String, GerritChange?, String?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        return (id, try await self.gerritService.loadChange(id), nil)
                    } catch {
                        return (id, nil, error.localizedDescription)
                    }
                }
            }
            for await result in group {
                let (id, change, error) = result
                if let change {
                    clInfos[id] = change
                    clErrors.removeValue(forKey: id)
                } else {
                    clErrors[id] = error ?? "Unknown error"
                }
            }
        }
        if rebuild { rebuildMenu(loading: false, error: nil) }
    }

    private func addMenuBarVisibilitySection(to menu: NSMenu) {
        let title = disabled("Show in menu bar")
        title.attributedTitle = coloredTitle("Show in menu bar", color: NSColor.labelColor, bold: true)
        menu.addItem(title)

        let visible = visibleMenuBarChannels()
        for name in ["stable", "beta", "dev", "canary"] {
            let item = NSMenuItem(title: displayName(name), action: #selector(toggleMenuBarChannel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = visible.contains(name) ? .on : .off
            menu.addItem(item)
        }
    }

    private func visibleMenuBarChannels() -> Set<String> {
        guard let saved = UserDefaults.standard.array(forKey: visibleChannelsKey) as? [String], !saved.isEmpty else {
            return defaultVisibleChannels
        }
        return Set(saved)
    }

    private func setVisibleMenuBarChannels(_ visible: Set<String>) {
        UserDefaults.standard.set(Array(visible).sorted { channelOrder($0) < channelOrder($1) }, forKey: visibleChannelsKey)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func refreshNow() { refresh() }

    @objc private func addStatusBookmark() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add CL or Issue Bookmark"
        alert.informativeText = "Paste a CL number, Gerrit URL, crrev.com/c link, or issues.chromium.org URL."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        field.placeholderString = "https://chromium-review.googlesource.com/c/chromium/src/+/7941513"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let paste = NSPasteboard.general.string(forType: .string) ?? ""
        if extractCLBookmark(paste) != nil || extractIssueId(paste) != nil {
            field.stringValue = paste
            field.selectText(nil)
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let id = extractIssueId(field.stringValue) {
            var bookmarks = issueBookmarks()
            if !bookmarks.contains(id) {
                bookmarks.append(id)
                setIssueBookmarks(bookmarks)
            }
        } else if let id = extractCLBookmark(field.stringValue) {
            var bookmarks = clBookmarks()
            if !bookmarks.contains(id) {
                bookmarks.append(id)
                setCLBookmarks(bookmarks)
            }
        } else {
            return
        }
        rebuildMenu(loading: false, error: nil)
        Task { await refreshBookmarks(rebuild: true) }
    }

    @objc private func refreshBookmarksNow() {
        Task { await refreshBookmarks(rebuild: true) }
    }

    @objc private func openCL(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(string: GerritTarget(id).url)!)
    }

    @objc private func removeCLBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setCLBookmarks(clBookmarks().filter { $0 != id })
        clInfos.removeValue(forKey: id)
        clErrors.removeValue(forKey: id)
        rebuildMenu(loading: false, error: nil)
    }

    @objc private func openIssueBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(string: "https://issues.chromium.org/issues/\(id)")!)
    }

    @objc private func removeIssueBookmark(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setIssueBookmarks(issueBookmarks().filter { $0 != id })
        issueInfos.removeValue(forKey: id)
        issueErrors.removeValue(forKey: id)
        rebuildMenu(loading: false, error: nil)
    }

    @objc private func toggleMenuBarChannel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var visible = visibleMenuBarChannels()
        if visible.contains(name) {
            visible.remove(name)
        } else {
            visible.insert(name)
        }
        setVisibleMenuBarChannels(visible)
        updateTitle()
        rebuildMenu(loading: false, error: nil)
    }

    @objc private func openSchedule() {
        NSWorkspace.shared.open(URL(string: "https://chromiumdash.appspot.com/schedule")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct ChromiumBranchesApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
