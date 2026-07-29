// ClaudeUsageBar — a macOS menu bar app showing Claude's three usage limits.
//
// The numbers are the same ones `/usage` prints inside Claude Code:
//   session       the rolling 5 hour window
//   weekly_all    the 7 day window across all models
//   weekly_scoped the 7 day window for the premium model of the current plan
//
// They come from the account endpoint Claude Code itself polls,
// https://api.anthropic.com/api/oauth/usage, authenticated with the OAuth
// access token that `claude` stores in the login keychain. The token is only
// ever read, never written or refreshed — if it has expired, the app says so
// and leaves re-authentication to `claude` itself.
//
// No third-party dependencies — plain AppKit, built with swiftc.

import AppKit
import Foundation

// MARK: - Credentials

/// Reads the OAuth access token out of the login keychain via /usr/bin/security.
/// The first call shows the standard macOS keychain prompt; "Always Allow"
/// makes it a one-off.
func oauthAccessToken() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    task.standardOutput = out
    task.standardError = Pipe()

    guard (try? task.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }

    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String,
          !token.isEmpty else { return nil }
    return token
}

// MARK: - Model

enum Severity {
    case normal, warning, critical

    /// The API sends a severity, but derive one from the percentage when it is
    /// missing so an older or newer response shape still colours correctly.
    static func from(_ raw: String?, percent: Int) -> Severity {
        switch raw {
        case "critical": return .critical
        case "warning": return .warning
        case "normal": return .normal
        default: return percent >= 90 ? .critical : (percent >= 75 ? .warning : .normal)
        }
    }

    var color: NSColor {
        switch self {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}

struct Limit {
    var kind: String        // session | weekly_all | weekly_scoped
    var label: String       // "Session (5h)", "Weekly (all models)", "Weekly (Opus)"
    var short: String       // "5h", "7d", "Opus" — the menu bar form
    var percent: Int
    var severity: Severity
    var resetsAt: Date?
}

enum Fetch {
    case ok([Limit])
    case noCredentials
    case unauthorized
    case rateLimited
    case failed(String)
}

// MARK: - Dates

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: s) { return d }

    // The API sends microseconds ("…:59.286288+00:00"); ISO8601DateFormatter is
    // only reliable with milliseconds, so drop the fractional part and retry.
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    let stripped = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
    return plain.date(from: stripped)
}

func relative(_ d: Date) -> String {
    let secs = Int(d.timeIntervalSinceNow)
    if secs <= 0 { return "any moment now" }
    let days = secs / 86400, hours = (secs % 86400) / 3600, mins = (secs % 3600) / 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(mins)m" }
    return "in \(mins)m"
}

func clockFormat(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE d MMM, HH:mm"
    return f.string(from: d)
}

// MARK: - Parsing

func parseLimits(_ data: Data) -> [Limit] {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

    var found: [String: Limit] = [:]

    // Preferred shape: a `limits` array, one entry per window.
    if let raw = root["limits"] as? [[String: Any]] {
        for entry in raw {
            guard let kind = entry["kind"] as? String,
                  let percent = (entry["percent"] as? NSNumber)?.intValue else { continue }

            var label: String
            var short: String
            switch kind {
            case "session":
                label = "Session (5h)"; short = "5h"
            case "weekly_all":
                label = "Weekly (all models)"; short = "7d"
            case "weekly_scoped":
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? "premium model"
                label = "Weekly (\(name))"; short = name
            default:
                continue
            }

            found[kind] = Limit(
                kind: kind,
                label: label,
                short: short,
                percent: percent,
                severity: .from(entry["severity"] as? String, percent: percent),
                resetsAt: parseISO(entry["resets_at"] as? String)
            )
        }
    }

    // Fallback to the flat fields, in case `limits` ever goes away.
    func legacy(_ key: String, kind: String, label: String, short: String) {
        guard found[kind] == nil,
              let o = root[key] as? [String: Any],
              let util = (o["utilization"] as? NSNumber)?.doubleValue else { return }
        let percent = Int(util.rounded())
        found[kind] = Limit(kind: kind, label: label, short: short, percent: percent,
                            severity: .from(nil, percent: percent),
                            resetsAt: parseISO(o["resets_at"] as? String))
    }
    legacy("five_hour", kind: "session", label: "Session (5h)", short: "5h")
    legacy("seven_day", kind: "weekly_all", label: "Weekly (all models)", short: "7d")
    legacy("seven_day_opus", kind: "weekly_scoped", label: "Weekly (Opus)", short: "Opus")

    // Always the same order, whatever order the API used.
    return ["session", "weekly_all", "weekly_scoped"].compactMap { found[$0] }
}

func fetchUsage(completion: @escaping (Fetch) -> Void) {
    guard let token = oauthAccessToken() else {
        completion(.noCredentials)
        return
    }

    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 20

    URLSession.shared.dataTask(with: req) { data, response, error in
        if let error = error {
            completion(.failed(error.localizedDescription))
            return
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            completion(.unauthorized)
            return
        }
        if code == 429 {
            completion(.rateLimited)
            return
        }
        guard code == 200, let data = data else {
            completion(.failed("HTTP \(code)"))
            return
        }
        let limits = parseLimits(data)
        completion(limits.isEmpty ? .failed("no usage limits in response") : .ok(limits))
    }.resume()
}

// MARK: - Rendering helpers

func bar(_ percent: Int, width: Int = 14) -> String {
    let filled = max(0, min(width, Int((Double(percent) / 100 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func pad(_ s: String, to n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var fetching = false
    private var floorUntil = Date.distantPast    // minimum gap between polls
    private var backoffUntil = Date.distantPast  // set only by a 429

    private var limits: [Limit] = []
    private var lastUpdate: Date?
    private var problem: String?          // nil while the last fetch succeeded

    private let compactKey = "compactTitle"
    private var compact: Bool {
        get { UserDefaults.standard.bool(forKey: compactKey) }
        set { UserDefaults.standard.set(newValue, forKey: compactKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = symbol()
            button.imagePosition = .imageLeading
        }
        // One menu instance for the life of the app, rebuilt in place. Swapping
        // in a fresh NSMenu would be a problem when a refresh lands while the
        // menu is on screen.
        menu.delegate = self
        statusItem.menu = menu
        render()
        fetch(force: true)

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetch(force: false)
        }
    }

    /// The nicest gauge symbol available on the running macOS, or nothing.
    private func symbol() -> NSImage? {
        for name in ["gauge.with.dots.needle.bottom.50percent", "gauge.medium", "gauge", "speedometer"] {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Claude usage") {
                return image
            }
        }
        return nil
    }

    // MARK: Data

    /// Menu item and keyboard shortcut. Skips the polite floor between polls,
    /// but not a rate limit — forcing through one would only deepen it.
    @objc private func refreshNow() { fetch(force: true) }

    private func fetch(force: Bool) {
        guard !fetching else { return }
        let now = Date()
        // Opening the menu triggers a fetch, so without a floor a few flicks of
        // the mouse would be a few requests a second.
        guard now >= backoffUntil, force || now >= floorUntil else { return }

        fetching = true
        // The keychain read can block (and may show a prompt), so keep it off
        // the main thread.
        DispatchQueue.global(qos: .utility).async {
            fetchUsage { result in
                DispatchQueue.main.async {
                    self.fetching = false
                    let now = Date()
                    switch result {
                    case .ok(let limits):
                        self.limits = limits
                        self.lastUpdate = now
                        self.problem = nil
                        self.floorUntil = now.addingTimeInterval(15)
                    case .noCredentials:
                        self.problem = "Not signed in — run `claude auth login` in a terminal"
                        self.floorUntil = now.addingTimeInterval(60)
                    case .unauthorized:
                        self.problem = "Token expired — start `claude` in a terminal to refresh it"
                        self.floorUntil = now.addingTimeInterval(60)
                    case .rateLimited:
                        self.problem = "Rate limited by the usage API — pausing for 5 minutes"
                        self.backoffUntil = now.addingTimeInterval(300)
                    case .failed(let why):
                        self.problem = "Could not reach the usage API (\(why))"
                        self.floorUntil = now.addingTimeInterval(60)
                    }
                    self.render()
                }
            }
        }
    }

    // MARK: Menu bar title

    private func render() {
        renderTitle()
        renderMenu()
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }

        // The menu bar is translucent, so whatever wallpaper is behind it shows
        // through. Semi-transparent colours (secondaryLabelColor and friends)
        // wash out badly against a light or colourful background, so everything
        // here is drawn at full opacity and the hierarchy comes from size and
        // weight instead: small regular labels, larger semibold numbers.
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let title = NSMutableAttributedString()

        func append(_ s: String, font: NSFont = NSFont.menuBarFont(ofSize: 12), color: NSColor = .labelColor) {
            title.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }

        append(" ")

        if limits.isEmpty {
            append(problem == nil ? "…" : "⚠︎", font: valueFont)
            button.attributedTitle = title
            return
        }

        // Stale numbers are still worth showing; the marker says they are stale.
        if problem != nil { append("⚠︎ ", font: valueFont, color: .systemOrange) }

        for (i, limit) in limits.enumerated() {
            if i > 0 { append(" · ", font: labelFont) }
            if !compact { append("\(limit.short) ", font: labelFont) }
            append("\(limit.percent)%", font: valueFont, color: limit.severity.color)
        }
        button.attributedTitle = title
    }

    // MARK: Dropdown

    private func renderMenu() {
        menu.removeAllItems()

        if let problem = problem {
            menu.addItem(note(problem, color: .systemOrange))
            menu.addItem(.separator())
        }

        if limits.isEmpty {
            menu.addItem(note(problem == nil ? "Loading usage…" : "No usage data yet"))
        } else {
            let labelWidth = (limits.map { $0.label.count }.max() ?? 0) + 2
            for limit in limits {
                menu.addItem(row(limit, labelWidth: labelWidth))
            }
            menu.addItem(.separator())
            for limit in limits {
                guard let resets = limit.resetsAt else { continue }
                menu.addItem(note("\(limit.short) resets \(clockFormat(resets))  (\(relative(resets)))"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(note(lastUpdate.map { "Updated \(clockFormat($0))" } ?? "Never updated"))
        menu.addItem(item("Refresh Now", #selector(refreshNow), "r"))
        menu.addItem(item("Open Usage on claude.ai", #selector(openDashboard), "o"))

        let toggle = item("Compact Menu Bar Display", #selector(toggleCompact), "")
        toggle.state = compact ? .on : .off
        menu.addItem(toggle)

        menu.addItem(.separator())
        menu.addItem(item("Quit ClaudeUsageBar", #selector(quit), "q"))
    }

    /// One usage line: label, bar, percentage. Monospaced so the bars line up.
    private func row(_ limit: Limit, labelWidth: Int) -> NSMenuItem {
        let text = pad(limit.label, to: labelWidth) + bar(limit.percent)
            + String(format: " %3d%%", limit.percent)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        // Colour only the bar and the number, so the label stays readable.
        let coloured = NSRange(location: labelWidth, length: text.count - labelWidth)
        attributed.addAttribute(.foregroundColor, value: limit.severity.color, range: coloured)

        // Kept enabled (rather than a dimmed, disabled row) so the colours show
        // at full strength; clicking opens the full breakdown on the web.
        let mi = NSMenuItem(title: text, action: #selector(openDashboard), keyEquivalent: "")
        mi.attributedTitle = attributed
        mi.target = self
        return mi
    }

    private func note(_ text: String, color: NSColor = .secondaryLabelColor) -> NSMenuItem {
        let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        mi.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: color])
        mi.isEnabled = false
        return mi
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    // MARK: Actions

    func menuWillOpen(_ menu: NSMenu) {
        fetch(force: false)
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }

    @objc private func toggleCompact() {
        compact = !compact
        render()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Terminal mode

/// `ClaudeUsageBar --print` writes the same three readings to stdout and exits,
/// which is handy from a shell and keeps the formatting path testable.
if CommandLine.arguments.contains("--print") {
    let done = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    fetchUsage { result in
        switch result {
        case .ok(let limits):
            let width = (limits.map { $0.label.count }.max() ?? 0) + 2
            for limit in limits {
                let resets = limit.resetsAt.map { "resets \(clockFormat($0)) (\(relative($0)))" } ?? ""
                print(pad(limit.label, to: width) + bar(limit.percent)
                      + String(format: " %3d%%  ", limit.percent) + resets)
            }
        case .noCredentials:
            print("not signed in — run `claude auth login` in a terminal"); status = 1
        case .rateLimited:
            print("rate limited by the usage API — try again in a few minutes"); status = 1
        case .unauthorized:
            print("token expired — start `claude` in a terminal to refresh it"); status = 1
        case .failed(let why):
            print("could not reach the usage API: \(why)"); status = 1
        }
        done.signal()
    }
    done.wait()
    exit(status)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
