import AppKit
@preconcurrency import ApplicationServices
import SwiftUI
import ServiceManagement

@MainActor
final class ClipboardModel: ObservableObject {
    @Published private(set) var history = History()
    @Published var error: String?
    @Published var notice: String?
    @Published var needsClipboardAccess = false
    @Published var accessibilityEnabled = AXIsProcessTrusted()
    @Published var paused = false { didSet { lastChange = pasteboard.changeCount } }
    @Published private(set) var hours: Double
    @Published private(set) var limit: Int
    @Published var directPaste: Bool { didSet { UserDefaults.standard.set(directPaste, forKey: "directPaste") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var shortcut: Shortcut
    var onShortcutChange: ((Shortcut) -> Bool)?
    private let storage: HistoryStorage
    private var storageReady = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    private var revision = 0
    private var timer: Timer?
    private var lastChange: Int
    private var lastPurge = Date.distantPast
    private var saveFailed = false
    private let pasteboard: NSPasteboard
    let demo: Bool

    init(demo: Bool = false, storage: HistoryStorage = HistoryStorage(), pasteboard: NSPasteboard? = nil) {
        self.demo = demo
        self.storage = storage
        self.pasteboard = pasteboard ?? (demo ? .withUniqueName() : .general)
        lastChange = self.pasteboard.changeCount
        let defaults = UserDefaults.standard
        let savedHours = defaults.double(forKey: "retentionHours")
        hours = savedHours.isFinite && (1...8_760).contains(savedHours) ? savedHours : 24
        let savedLimit = defaults.integer(forKey: "historyLimit")
        limit = (1...500).contains(savedLimit) ? savedLimit : 200
        directPaste = defaults.object(forKey: "directPaste") as? Bool ?? true
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        if !shortcut.isSafe { shortcut = .default }
        if demo {
            for (text, source) in [("A little less friction. A little more flow.", "Notes"), ("https://developer.apple.com/swift/", "Safari"), ("Meeting notes\n• Ship the simple version\n• Keep everything on this Mac", "Notes")] {
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                if let clip = Clip.capture(from: self.pasteboard, source: source) { history.insert(clip, hours: hours, limit: limit) }
            }
            return
        }
        retryStorage()
        updateClipboardAccess()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.15
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    deinit {
        // Owned and released by the main-actor app delegate (or main-actor checks).
        MainActor.assumeIsolated {
            timer?.invalidate()
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            if demo { pasteboard.releaseGlobally() }
        }
    }

    func retryStorage() {
        guard !demo else { return }
        if storageReady { save(); return }
        guard loadTask == nil else { return }
        loadTask = Task {
            defer { loadTask = nil }
            do {
                var loaded = try await storage.load()
                let changed = loaded.purge(hours: hours, limit: limit)
                history = loaded
                storageReady = true
                saveFailed = false
                error = nil
                lastChange = pasteboard.changeCount
                if changed { save() }
            } catch { self.error = error.localizedDescription }
        }
    }

    func retentionRemovalCount(hours: Double, limit: Int) -> Int {
        var pruned = history
        pruned.purge(hours: hours, limit: limit)
        return history.clips.count - pruned.clips.count
    }

    @discardableResult
    func applyRetention(hours: Double, limit: Int, confirmRemoval: Bool = false) -> Bool {
        let hours = hours.isFinite ? max(1, min(hours.rounded(), 8_760)) : 24
        let limit = max(1, min(limit, 500))
        guard confirmRemoval || retentionRemovalCount(hours: hours, limit: limit) == 0 else { return false }
        self.hours = hours
        self.limit = limit
        if !demo {
            UserDefaults.standard.set(self.hours, forKey: "retentionHours")
            UserDefaults.standard.set(self.limit, forKey: "historyLimit")
        }
        purge()
        return true
    }

    func setShortcut(_ value: Shortcut) {
        guard value.isSafe else { notice = Shortcut.requirement; return }
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
            // On the general pasteboard, .default may prompt; never trigger that from a timer.
            let needsAccess = pasteboard.accessBehavior != .alwaysAllow
            if needsClipboardAccess != needsAccess { needsClipboardAccess = needsAccess }
        }
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        if accessibilityEnabled != trusted { accessibilityEnabled = trusted }
        updateClipboardAccess()
    }

    @objc private func wokeUp() {
        if !storageReady || saveFailed { retryStorage() }
        purge()
        poll()
    }

    func poll() {
        if Date().timeIntervalSince(lastPurge) >= 30 {
            if !storageReady { retryStorage() }
            refreshPermissions()
            purge()
        }
        guard !paused, storageReady else {
            lastChange = pasteboard.changeCount
            return
        }
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        updateClipboardAccess()
        guard !needsClipboardAccess else { lastChange = change; return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSApp?.keyWindow == nil else { lastChange = change; return }
        let source = frontmost?.localizedName ?? "Unknown app"
        var limitNotice: String?
        let clip = Clip.capture(from: pasteboard, source: source, onLimit: { limitNotice = $0 })
        guard pasteboard.changeCount == change else { return }
        lastChange = change
        if let limitNotice { notice = limitNotice }
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
        guard !demo, storageReady else { return }
        dirty = true
        revision += 1
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
                try await storage.save(history)
                guard !Task.isCancelled else { return }
                dirty = false
                saveFailed = false
                error = nil
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                reportSaveFailure(error)
            }
        }
    }

    // Also used before quitting so the debounce never loses the last change.
    func flushStorage() async -> Bool {
        await loadTask?.value
        guard !demo, storageReady else { return true }
        while dirty {
            saveTask?.cancel()
            await saveTask?.value
            let savingRevision = revision
            do {
                try await storage.save(history)
                if revision == savingRevision { dirty = false }
                saveFailed = false
                error = nil
            } catch {
                reportSaveFailure(error)
                return false
            }
        }
        return true
    }

    private func reportSaveFailure(_ error: Error) {
        saveFailed = true
        self.error = "History changes could not be saved, including deletions: \(error.localizedDescription)"
    }
}
