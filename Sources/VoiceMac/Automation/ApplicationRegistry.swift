import AppKit
import Foundation

struct InstalledApplication: Sendable, Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String
    let url: URL

    var id: String { bundleIdentifier }
}

/// Index of installed applications, with fuzzy name resolution.
///
/// Built once at launch (off the main actor) so "open chrome" can be resolved
/// and launched without touching the filesystem or the network.
actor ApplicationRegistry {
    private var applications: [InstalledApplication] = []
    private var byBundleID: [String: InstalledApplication] = [:]
    private var didScan = false

    /// Spoken forms that will never fuzzy-match the real bundle name.
    /// Values are matched against app names, so one alias can cover variants.
    private static let aliases: [String: String] = [
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "browser": "Safari",
        "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "code": "Visual Studio Code",
        "visual studio": "Visual Studio Code",
        "terminal": "Terminal",
        "iterm": "iTerm",
        "finder": "Finder",
        "slack": "Slack",
        "notes": "Notes",
        "mail": "Mail",
        "calendar": "Calendar",
        "messages": "Messages",
        "imessage": "Messages",
        "whatsapp": "WhatsApp",
        "spotify": "Spotify",
        "zoom": "zoom.us",
        "teams": "Microsoft Teams",
        "word": "Microsoft Word",
        "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint",
        "outlook": "Microsoft Outlook",
        "preview": "Preview",
        "photos": "Photos",
        "music": "Music",
        "settings": "System Settings",
        "system settings": "System Settings",
        "system preferences": "System Settings",
        "preferences": "System Settings",
        "activity monitor": "Activity Monitor",
        "xcode": "Xcode",
        "figma": "Figma",
        "notion": "Notion",
        "obsidian": "Obsidian",
        "discord": "Discord",
        "telegram": "Telegram",
        "postman": "Postman",
        "docker": "Docker",
        "firefox": "Firefox",
        "edge": "Microsoft Edge",
        "arc": "Arc",
        "brave": "Brave Browser",
        "calculator": "Calculator",
        "app store": "App Store",
    ]

    private static let searchDirectories: [URL] = {
        var dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
            // Safari and other cryptex-delivered system apps live here; the
            // /Applications entries for them are hidden symlinks.
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
        ]
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            dirs.append(home.appendingPathComponent("Applications"))
        }
        return dirs
    }()

    // MARK: Scan

    func refresh() {
        let started = ContinuousClock.now
        var found: [String: InstalledApplication] = [:]

        for directory in Self.searchDirectories {
            scan(directory, depth: 0, into: &found)
        }

        applications = found.values.sorted { $0.name < $1.name }
        byBundleID = found
        didScan = true

        let elapsed = ContinuousClock.now - started
        log(.app, "application registry: \(applications.count) apps indexed in \(elapsed.milliseconds) ms")
    }

    private func scan(_ directory: URL, depth: Int, into found: inout [String: InstalledApplication]) {
        guard depth <= 2 else { return }
        // `.skipsHiddenFiles` is deliberately NOT set: /Applications/Safari.app
        // is a hidden symlink, and skipping hidden entries loses Safari
        // entirely. Filtering on the `.app` extension keeps out the noise.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return }

        for entry in entries {
            if entry.pathExtension == "app" {
                if let app = describe(entry) {
                    // First writer wins: /Applications beats /System duplicates.
                    if found[app.bundleIdentifier] == nil {
                        found[app.bundleIdentifier] = app
                    }
                }
                continue
            }

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Don't follow symlinked directories — they can point back up the
            // tree and turn a bounded scan into a long one.
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            scan(entry, depth: depth + 1, into: &found)
        }
    }

    private func describe(_ url: URL) -> InstalledApplication? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return nil }

        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        return InstalledApplication(name: name, bundleIdentifier: bundleID, url: url)
    }

    // MARK: Lookup

    func all() -> [InstalledApplication] { applications }

    func application(bundleIdentifier: String) -> InstalledApplication? {
        byBundleID[bundleIdentifier]
    }

    /// Minimum score we accept, so "open the" does not launch "Theatre".
    static let matchThreshold = 0.62

    /// Resolves a spoken app name. Returns nil rather than a bad guess.
    func resolve(_ spoken: String) -> InstalledApplication? {
        guard didScan else { refresh(); return resolve(spoken) }

        let query = Fuzzy.normalize(spoken)
        guard !query.isEmpty else { return nil }

        // Alias table first — it encodes knowledge fuzzy matching cannot infer
        // (that "code" means Visual Studio Code, not "Image Capture").
        if let aliasTarget = Self.aliases[query] {
            if let exact = applications.first(where: {
                Fuzzy.normalize($0.name) == Fuzzy.normalize(aliasTarget)
            }) {
                return exact
            }
            if let close = bestMatch(for: aliasTarget), close.score >= 0.8 {
                return close.app
            }
        }

        guard let best = bestMatch(for: spoken) else { return nil }
        guard best.score >= Self.matchThreshold else {
            log(.router, "no app match for \"\(spoken)\" (best \(best.app.name) @ \(String(format: "%.2f", best.score)))")
            return nil
        }
        return best.app
    }

    /// Ranked matches, used when we want to show the user alternatives.
    func rank(_ spoken: String, limit: Int = 5) -> [(app: InstalledApplication, score: Double)] {
        applications
            .map { ($0, Fuzzy.score(query: spoken, candidate: $0.name)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { (app: $0.0, score: $0.1) }
    }

    private func bestMatch(for spoken: String) -> (app: InstalledApplication, score: Double)? {
        var best: (InstalledApplication, Double)?
        for app in applications {
            var score = Fuzzy.score(query: spoken, candidate: app.name)

            // The last path component sometimes differs from the display name
            // ("Google Chrome.app" vs "Chrome"), so try it too.
            let fileName = app.url.deletingPathExtension().lastPathComponent
            if fileName != app.name {
                score = max(score, Fuzzy.score(query: spoken, candidate: fileName) * 0.98)
            }

            if best == nil || score > best!.1 {
                best = (app, score)
            }
        }
        guard let best else { return nil }
        return (app: best.0, score: best.1)
    }

    /// Terminology hint for the STT model: the app names we most want
    /// recognised correctly. Capped so the prompt stays small.
    func sttPromptBias(limit: Int = 40) -> String {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
        let prioritised = applications.sorted { a, b in
            let aRunning = running.contains(a.name)
            let bRunning = running.contains(b.name)
            if aRunning != bRunning { return aRunning }
            return a.name < b.name
        }
        let names = prioritised.prefix(limit).map(\.name)
        return names.joined(separator: ", ")
    }
}

extension Duration {
    var milliseconds: Int {
        Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
    }
}
