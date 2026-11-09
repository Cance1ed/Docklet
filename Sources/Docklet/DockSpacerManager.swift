import AppKit

/// Creates and removes the spacer tiles that reserve Docklet's hole inside the Dock.
///
/// The Dock has no plug-in API, so the only way to occupy real estate *inside* it is to
/// append `spacer-tile` entries to `com.apple.dock persistent-apps` and restart the Dock.
/// Docklet then paints into that gap with a fully transparent window, so the Dock's own
/// material shows through and the widget reads as part of the Dock rather than a floating island.
enum DockSpacerManager {
    /// Dock tiles reserved per feed. One keeps Docklet on the Dock's own pitch, so the gap to the
    /// surrounding app icons matches the gap between them.
    static let tilesPerFeed = 1

    /// Makes the spacer run exactly `tileCount` long and restarts the Dock.
    ///
    /// Restarting is skipped when the count already matches, so launching with the gap already in
    /// place — the usual case when Docklet is a login item — costs no flicker.
    @discardableResult
    static func installSlot(tileCount: Int) -> Bool {
        guard spacerIndexes().count != tileCount else { return true }
        guard setSpacerCount(tileCount) else { return false }
        // Do not return until the replacement Dock exists. The panel needs a live AX tree to find
        // the new spacer tiles; laying it out against the old/dead Dock leaves it hidden forever.
        restartDock(waitingUpTo: 3)
        return true
    }

    /// Rewrites `persistent-apps` so it holds exactly `target` spacer tiles.
    ///
    /// The whole array is exported, edited and imported back: `defaults delete` does not accept an
    /// array subscript, so removing a single tile by index silently fails.
    private static func setSpacerCount(_ target: Int) -> Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.dock"),
              var apps = defaults.array(forKey: "persistent-apps") as? [[String: Any]] else { return false }

        let indexes = apps.indices.filter { isSpacer(apps[$0]) }
        if indexes.count > target {
            // Drop from the back so the earlier indexes stay valid.
            for index in indexes.suffix(indexes.count - target).sorted(by: >) {
                apps.remove(at: index)
            }
        } else if indexes.count < target {
            apps.append(contentsOf: Array(repeating: ["tile-type": "spacer-tile"], count: target - indexes.count))
        } else {
            return true
        }

        defaults.set(apps, forKey: "persistent-apps")
        return defaults.synchronize()
    }

    private static func isSpacer(_ tile: [String: Any]) -> Bool {
        let type = tile["tile-type"] as? String
        return type == "spacer-tile" || type == "small-spacer-tile"
    }

    /// Indexes of `spacer-tile` entries inside `persistent-apps`.
    private static func spacerIndexes() -> [Int] {
        guard let defaults = UserDefaults(suiteName: "com.apple.dock"),
              let apps = defaults.array(forKey: "persistent-apps") as? [[String: Any]] else { return [] }
        return apps.indices.filter { isSpacer(apps[$0]) }
    }

    /// Removes the spacer tiles and waits for the Dock to actually come back.
    ///
    /// Used on quit, where the process is about to exit: without waiting, the app can die before
    /// the Dock has reloaded, leaving the gap behind until something else restarts it.
    @discardableResult
    static func removeSlotSynchronously() -> Bool {
        guard !spacerIndexes().isEmpty else { return true }
        guard setSpacerCount(0) else { return false }
        restartDock(waitingUpTo: 3)
        return true
    }

    /// Restarts the Dock so it picks up the new tile list.
    ///
    /// Signals the process directly rather than calling `NSRunningApplication.terminate()`, which
    /// only sends a quit Apple Event — the Dock ignores those and keeps running, so the edited
    /// preferences would never be read and the tiles on screen would not change. `launchd`
    /// immediately relaunches it, which is exactly what `killall Dock` does.
    private static func restartDock(waitingUpTo timeout: TimeInterval = 0) {
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        let pids = docks.map(\.processIdentifier)
        for pid in pids { kill(pid, SIGTERM) }

        guard timeout > 0 else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let live = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            // Wait for a replacement process, not just for the old one to die, so the Dock is
            // already rebuilding from the new preferences by the time this returns.
            if live.contains(where: { !pids.contains($0.processIdentifier) }) { return }
            usleep(50_000)
        }
    }
}
