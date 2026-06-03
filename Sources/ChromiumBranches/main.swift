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
    case "stable": return NSColor.systemGreen
    case "beta": return NSColor.systemBlue
    case "dev": return NSColor.systemOrange
    case "canary": return NSColor.systemYellow
    default: return NSColor.secondaryLabelColor
    }
}

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = ChromiumDataService()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var channels: [ChannelInfo] = []
    private var lastUpdated: Date?
    private var refreshTimer: Timer?
    private let visibleChannelsKey = "visibleMenuBarChannels"
    private let defaultVisibleChannels: Set<String> = ["stable", "beta", "dev", "canary"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "Cr ..."
        statusItem.button?.toolTip = "Chromium branch/channel schedule"
        rebuildMenu(loading: true, error: nil)
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        statusItem.button?.title = "Cr ..."
        rebuildMenu(loading: true, error: nil)
        Task {
            do {
                channels = try await service.load()
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
            for channel in channels {
                addChannel(channel, to: menu)
            }
            menu.addItem(.separator())
            addMilestoneSummary(to: menu)
        }

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

    private func addChannel(_ channel: ChannelInfo, to menu: NSMenu) {
        let branch = branchCountdownText(channel.schedule?.branch_point)
        let title = "\(channelEmoji(channel.name)) \(displayName(channel.name)): M\(channel.milestone) (\(channel.version))"
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.attributedTitle = channelMenuTitle(channel, title: title)

        let submenu = NSMenu()
        if channel.name == "dev" || channel.name == "canary" {
            let item = disabled("Branch countdown: \(branch)")
            item.attributedTitle = coloredTitle("Branch countdown: \(branch)", color: branchCountdownColor(channel.schedule?.branch_point), bold: true)
            submenu.addItem(item)
            submenu.addItem(.separator())
        }
        submenu.addItem(disabled("Branch point: \(dateText(channel.schedule?.branch_point)) (\(relativeText(channel.schedule?.branch_point)))"))
        submenu.addItem(disabled("Beta starts: \(dateText(channel.schedule?.earliest_beta)) (\(relativeText(channel.schedule?.earliest_beta)))"))
        submenu.addItem(disabled("Beta ends: \(dateText(channel.schedule?.latest_beta)) (\(relativeText(channel.schedule?.latest_beta)))"))
        submenu.addItem(disabled("Final beta cut: \(dateText(channel.schedule?.final_beta)) (\(relativeText(channel.schedule?.final_beta)))"))
        submenu.addItem(disabled("Stable: \(dateText(channel.schedule?.stable_date)) (\(relativeText(channel.schedule?.stable_date)))"))
        if channel.schedule?.stable_refresh_first != nil {
            submenu.addItem(disabled("Refresh 1: \(dateText(channel.schedule?.stable_refresh_first))"))
        }
        root.submenu = submenu
        menu.addItem(root)
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
        if days <= 2 { return NSColor.systemRed }
        if days <= 7 { return NSColor.systemOrange }
        return NSColor.systemGreen
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
