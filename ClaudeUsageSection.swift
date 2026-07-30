// The Claude usage section: the three limits `/usage` prints inside Claude Code.
//
//   session       the rolling 5 hour window
//   weekly_all    the 7 day window across all models
//   weekly_scoped the 7 day window for the premium model of the current plan
//
// They come from the account endpoint Claude Code itself polls,
// https://api.anthropic.com/api/oauth/usage, authenticated with the OAuth access
// token that `claude` stores in the login keychain. The token is only ever read,
// never written or refreshed — if it has expired, the section says so and leaves
// re-authentication to `claude` itself.
//
// Compiled two ways, from the same source — into MacBar alongside the other
// sections, or into ClaudeUsageBar.app on its own. Both builds supply the host
// that defines BarSection; see build.sh.
//
// Everything lives inside the section type on purpose. Sections from different
// repositories are compiled into one module, so a top-level `Limit` or
// `Severity` here would be free to collide with a top-level type in a sibling.

import AppKit
import Foundation

final class ClaudeUsageSection: NSObject, BarSection {
    let name = "Claude usage"
    let showKey = "showUsage"

    private var timer: Timer?
    private var onUpdate: () -> Void = {}
    private var fetching = false
    private var floorUntil = Date.distantPast    // minimum gap between polls
    private var backoffUntil = Date.distantPast  // set only by a 429

    private var limits: [Limit] = []
    private var lastUpdate: Date?
    private var problem: String?                 // nil while the last fetch succeeded

    // MARK: - Model

    enum Severity {
        case normal, warning, critical

        /// The API sends a severity, but derive one from the percentage when it
        /// is missing so an older or newer response shape still colours
        /// correctly.
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
            case .warning: return Palette.warning
            case .critical: return Palette.critical
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

    // MARK: - Credentials

    /// Reads the OAuth access token out of the login keychain via
    /// /usr/bin/security. The first call shows the standard macOS keychain
    /// prompt; "Always Allow" makes it a one-off.
    static func accessToken() -> String? {
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

    // MARK: - The usage API

    static func parse(_ data: Data) -> [Limit] {
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
                    resetsAt: Fmt.iso(entry["resets_at"] as? String)
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
                                resetsAt: Fmt.iso(o["resets_at"] as? String))
        }
        legacy("five_hour", kind: "session", label: "Session (5h)", short: "5h")
        legacy("seven_day", kind: "weekly_all", label: "Weekly (all models)", short: "7d")
        legacy("seven_day_opus", kind: "weekly_scoped", label: "Weekly (Opus)", short: "Opus")

        // Always the same order, whatever order the API used.
        return ["session", "weekly_all", "weekly_scoped"].compactMap { found[$0] }
    }

    static func fetch(completion: @escaping (Fetch) -> Void) {
        guard let token = accessToken() else {
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
            let limits = parse(data)
            completion(limits.isEmpty ? .failed("no usage limits in response") : .ok(limits))
        }.resume()
    }

    // MARK: - Polling

    func activate(onUpdate: @escaping () -> Void) {
        self.onUpdate = onUpdate
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
    }

    /// `force` skips the polite floor between polls, but not a rate limit —
    /// forcing through one would only deepen it.
    func refresh(force: Bool) {
        guard !fetching else { return }
        let now = Date()
        // Opening the menu triggers a fetch, so without a floor a few flicks of
        // the mouse would be a few requests a second.
        guard now >= backoffUntil, force || now >= floorUntil else { return }

        fetching = true
        // The keychain read can block (and may show a prompt), so keep it off
        // the main thread.
        DispatchQueue.global(qos: .utility).async {
            Self.fetch { result in
                DispatchQueue.main.async {
                    self.fetching = false
                    self.absorb(result)
                    self.onUpdate()
                }
            }
        }
    }

    private func absorb(_ result: Fetch) {
        let now = Date()
        switch result {
        case .ok(let limits):
            self.limits = limits
            lastUpdate = now
            problem = nil
            floorUntil = now.addingTimeInterval(15)
        case .noCredentials:
            problem = "Not signed in — run `claude auth login` in a terminal"
            floorUntil = now.addingTimeInterval(60)
        case .unauthorized:
            problem = "Token expired — start `claude` in a terminal to refresh it"
            floorUntil = now.addingTimeInterval(60)
        case .rateLimited:
            problem = "Rate limited by the usage API — pausing for 5 minutes"
            backoffUntil = now.addingTimeInterval(300)
        case .failed(let why):
            problem = "Could not reach the usage API (\(why))"
            floorUntil = now.addingTimeInterval(60)
        }
    }

    // MARK: - Menu bar

    func titleSegments(compact: Bool) -> [Segment] {
        if limits.isEmpty {
            return [.value(problem == nil ? "…" : "⚠︎")]
        }

        var segments: [Segment] = []
        // Stale numbers are still worth showing; the marker says they are stale.
        if problem != nil { segments.append(.value("⚠︎ ", color: Palette.warning)) }

        for (i, limit) in limits.enumerated() {
            // Compact drops the window labels and tightens the separator, so all
            // three readings cost about as much width as one other section:
            // "42·61·18%".
            if i > 0 { segments.append(.label(compact ? "·" : " · ")) }
            if !compact { segments.append(.label("\(limit.short) ")) }
            let percent = compact && i < limits.count - 1 ? "\(limit.percent)" : "\(limit.percent)%"
            segments.append(.value(percent, color: limit.severity.color))
        }
        return segments
    }

    // MARK: - Dropdown

    func menuRows() -> [NSMenuItem] {
        var rows: [NSMenuItem] = []

        if let problem = problem {
            rows.append(MenuKit.alert(problem))
        }

        if limits.isEmpty {
            rows.append(MenuKit.note(problem == nil ? "Loading usage…" : "No usage data yet"))
        } else {
            let labelWidth = (limits.map { $0.label.count }.max() ?? 0) + 2
            rows.append(contentsOf: limits.map { row($0, labelWidth: labelWidth) })
            for limit in limits {
                guard let resets = limit.resetsAt else { continue }
                rows.append(MenuKit.note("\(limit.short) resets \(Fmt.clock(resets))  (\(Fmt.relative(resets)))"))
            }
        }

        rows.append(MenuKit.note(lastUpdate.map { "Updated \(Fmt.clock($0))" } ?? "Never updated"))
        rows.append(MenuKit.action("Open Usage on claude.ai", #selector(openDashboard), key: "u", target: self))
        return rows
    }

    /// One usage line: label, bar, percentage. Monospaced so the bars line up.
    private func row(_ limit: Limit, labelWidth: Int) -> NSMenuItem {
        let text = Fmt.pad(limit.label, to: labelWidth) + Fmt.gauge(limit.percent)
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

    // MARK: - Terminal

    func snapshot(_ completion: @escaping ([String], Bool) -> Void) {
        Self.fetch { result in
            switch result {
            case .ok(let limits):
                let width = (limits.map { $0.label.count }.max() ?? 0) + 2
                completion(limits.map { limit in
                    let resets = limit.resetsAt.map { "resets \(Fmt.clock($0)) (\(Fmt.relative($0)))" } ?? ""
                    return Fmt.pad(limit.label, to: width) + Fmt.gauge(limit.percent)
                        + String(format: " %3d%%  ", limit.percent) + resets
                }, true)
            case .noCredentials:
                completion(["not signed in — run `claude auth login` in a terminal"], false)
            case .unauthorized:
                completion(["token expired — start `claude` in a terminal to refresh it"], false)
            case .rateLimited:
                completion(["rate limited by the usage API — try again in a few minutes"], false)
            case .failed(let why):
                completion(["could not reach the usage API: \(why)"], false)
            }
        }
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
    }
}
