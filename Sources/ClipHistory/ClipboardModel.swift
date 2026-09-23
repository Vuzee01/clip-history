import AppKit
import SwiftUI
import ServiceManagement

final class ClipboardModel: ObservableObject {
    @Published private(set) var history = History()
    @Published var error: String?
    @Published var notice: String?
    @Published var needsClipboardAccess = false
    @Published var accessibilityEnabled = AXIsProcessTrusted()
    @Published var paused = false { didSet { lastChange = pasteboard.changeCount } }
    @Published var hours: Double { didSet { UserDefaults.standard.set(hours, forKey: "retentionHours"); purge() } }
    @Published var limit: Int { didSet { UserDefaults.standard.set(limit, forKey: "historyLimit"); purge() } }
    @Published var directPaste: Bool { didSet { UserDefaults.standard.set(directPaste, forKey: "directPaste") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var shortcut: Shortcut
    var onShortcutChange: ((Shortcut) -> Bool)?
    private var vault: Vault?
    private var timer: Timer?
    private var lastChange: Int
    private var lastPurge = Date.distantPast
    private var saveFailed = false
    private let pasteboard: NSPasteboard
    let demo: Bool

    init(demo: Bool = false) {
        self.demo = demo
        pasteboard = demo ? .withUniqueName() : .general
        lastChange = pasteboard.changeCount
        let defaults = UserDefaults.standard
        let savedHours = defaults.double(forKey: "retentionHours")
        hours = savedHours.isFinite && (1...8_760).contains(savedHours) ? savedHours : 24
        let savedLimit = defaults.integer(forKey: "historyLimit")
        limit = (1...500).contains(savedLimit) ? savedLimit : 200
        directPaste = defaults.object(forKey: "directPaste") as? Bool ?? true
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        if demo {
            for (text, source) in [("A little less friction. A little more flow.", "Notes"), ("https://developer.apple.com/swift/", "Safari"), ("Meeting notes\n• Ship the simple version\n• Keep everything on this Mac", "Notes")] {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                if let clip = Clip.capture(from: pasteboard, source: source) { history.insert(clip, hours: hours, limit: limit) }
            }
            return
        }
        retryStorage()
        updateClipboardAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 0.15
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if demo { pasteboard.releaseGlobally() }
    }

    func retryStorage() {
        if vault != nil { save(); return }
        do {
            let opened = try Vault.open()
            var loaded = try opened.load()
            loaded.purge(hours: hours, limit: limit)
            try opened.save(loaded)
            vault = opened
            history = loaded
            saveFailed = false
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func setShortcut(_ value: Shortcut) {
        guard onShortcutChange?(value) == true else {
            notice = "That shortcut is in use. Try another combination."
            return
        }
        shortcut = value
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "shortcut")
        notice = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                notice = "Allow Clip History in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { notice = "Could not change login setting: \(error.localizedDescription)" }
    }

    func requestClipboardAccess() {
        // One explicit read lets macOS present its permission dialog; never prompt in the polling loop.
        _ = pasteboard.string(forType: .string)
        updateClipboardAccess()
        if needsClipboardAccess {
            notice = "Choose Always Allow for Clip History in System Settings → Privacy & Security → Paste from Other Apps."
        }
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityEnabled = AXIsProcessTrustedWithOptions(options)
    }

    private func updateClipboardAccess() {
        if #available(macOS 15.4, *) {
            let needsAccess = pasteboard.accessBehavior != .alwaysAllow
            if needsClipboardAccess != needsAccess { needsClipboardAccess = needsAccess }
        }
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        if accessibilityEnabled != trusted { accessibilityEnabled = trusted }
        updateClipboardAccess()
    }

    @objc private func wokeUp() { purge(); poll() }

    func poll() {
        if Date().timeIntervalSince(lastPurge) >= 30 { refreshPermissions(); purge() }
        guard !paused, vault != nil else {
            lastChange = pasteboard.changeCount
            return
        }
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        updateClipboardAccess()
        guard !needsClipboardAccess else { lastChange = change; return }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown app"
        let clip = Clip.capture(from: pasteboard, source: source)
        guard pasteboard.changeCount == change else { return }
        lastChange = change
        if let clip {
            history.insert(clip, hours: hours, limit: limit)
            save()
        }
    }

    func purge() {
        lastPurge = Date()
        var pruned = history
        let changed = pruned.purge(hours: hours, limit: limit)
        if changed { history = pruned }
        if changed || saveFailed { save() }
    }

    func delete(_ id: UUID) {
        history.clips.removeAll { $0.id == id }
        save()
    }

    func clear() {
        history.clips.removeAll()
        save()
    }

    func copy(_ clip: Clip) -> Bool {
        purge()
        guard history.clips.contains(where: { $0.id == clip.id }) else { return false }
        guard clip.restore(to: pasteboard) else {
            notice = "Could not write to the clipboard. Try again."
            return false
        }
        lastChange = pasteboard.changeCount
        return true
    }

    private func save() {
        guard !demo, let vault else { return }
        do {
            try vault.save(history)
            saveFailed = false
            error = nil
        } catch {
            saveFailed = true
            self.error = "History changes could not be saved, including deletions: \(error.localizedDescription)"
        }
    }
}
