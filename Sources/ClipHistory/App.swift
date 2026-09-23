import AppKit
import Carbon
import SwiftUI

struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey), key: "V")
    static let requirement = "Use Control or Command plus another modifier and a letter or number."

    var isSafe: Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        return modifiers & ~allowed == 0 && modifiers.nonzeroBitCount >= 2
            && modifiers & UInt32(controlKey | cmdKey) != 0
            && key.count == 1 && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers?.uppercased(), characters.count == 1,
              characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        keyCode = UInt32(event.keyCode)
        key = characters
        modifiers = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)] where flags.contains(flag) {
            modifiers |= UInt32(carbon)
        }
        guard isSafe else { return nil }
    }
}

final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    @MainActor var onPress: (() -> Void)?

    @MainActor
    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @MainActor func register(_ shortcut: Shortcut) -> Bool {
        guard shortcut.isSafe else { return false }
        var newReference: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x434C4950, id: 1)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &newReference) == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = newReference
        return true
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    lazy var model = ClipboardModel(demo: CommandLine.arguments.contains("--demo"))
    private let hotkey = GlobalShortcut()
    private var statusItem: NSStatusItem!
    private var panel: HistoryPanel!
    private var settingsWindow: NSWindow?
    private var previousApp: NSRunningApplication?
    private var pasteTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.cliphistory.app")
        if !CommandLine.arguments.contains("--demo"), others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Clip History", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(); editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clip History")
            button.toolTip = "Clip History · \(model.shortcut.label)"
            button.target = self
            button.action = #selector(toggleHistory)
        }
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 530),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clip History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PickerView(model: model, choose: { [weak self] clip, copyOnly in
            self?.choose(clip, copyOnly: copyOnly)
        }, dismiss: { [weak self] in self?.dismiss() }, settings: { [weak self] in self?.showSettings() }))
        hotkey.onPress = { [weak self] in self?.toggleHistory() }
        model.onShortcutChange = { [weak self] shortcut in
            guard let self else { return false }
            if shortcut == self.model.shortcut { return true }
            let registered = self.hotkey.register(shortcut)
            if registered { self.statusItem.button?.toolTip = "Clip History · \(shortcut.label)" }
            return registered
        }
        if !hotkey.register(model.shortcut) { model.notice = "Your shortcut is in use. Open Settings to choose another. The menu bar button still works." }
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        if firstLaunch || model.demo || model.error != nil || model.needsClipboardAccess { showHistory() }
        if !model.demo { UserDefaults.standard.set(true, forKey: "hasLaunched") }
    }

    @objc private func toggleHistory() {
        if panel.isVisible { dismiss() } else { showHistory() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel != nil { showHistory() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissions()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard panel != nil else { return .terminateNow }
        let wasPaused = model.paused
        model.paused = true
        pasteTask?.cancel()
        Task {
            var canQuit = await model.flushStorage()
            if !canQuit {
                let alert = NSAlert()
                alert.messageText = "History changes could not be saved"
                alert.informativeText = "Quitting now may lose recent copies or leave deleted clips on disk."
                alert.addButton(withTitle: "Keep Running")
                alert.addButton(withTitle: "Quit Anyway")
                canQuit = alert.runModal() == .alertSecondButtonReturn
            }
            if !canQuit { model.paused = wasPaused }
            sender.reply(toApplicationShouldTerminate: canQuit)
        }
        return .terminateLater
    }

    private func showHistory() {
        pasteTask?.cancel()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        model.refreshPermissions()
        model.purge()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + frame.height * 0.1))
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .pickerOpened, object: nil)
    }

    private func dismiss() {
        model.notice = nil
        panel.orderOut(nil)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp?.processIdentifier {
            previousApp?.activate(options: .activateIgnoringOtherApps)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { model.notice = nil; panel.orderOut(nil) }
    }

    private func choose(_ clip: Clip, copyOnly: Bool) {
        pasteTask?.cancel()
        guard model.copy(clip) else { return }
        let target = previousApp
        let shouldPaste = !copyOnly && model.directPaste && AXIsProcessTrusted() && !model.demo
        if !copyOnly && model.directPaste && !AXIsProcessTrusted() {
            model.notice = "Copied. Press ⌘V to paste, or use Enable Accessibility in the history window for instant paste."
            return
        }
        if shouldPaste && (target == nil || target?.isTerminated == true) {
            model.notice = "Copied. Switch to your app and press ⌘V to paste."
            return
        }
        model.notice = nil
        dismiss()
        guard shouldPaste, let target, !target.isTerminated else { return }
        pasteTask = Task { @MainActor in
            // Wait for focus and released shortcut modifiers before sending a single ⌘V.
            for _ in 0..<20 {
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
                let flags = CGEventSource.flagsState(.combinedSessionState)
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { continue }
                let source = CGEventSource(stateID: .privateState)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { break }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                return
            }
            showHistory()
            model.notice = "Copied, but instant paste did not finish. Switch to your app and press ⌘V."
        }
    }

    private func showSettings() {
        pasteTask?.cancel()
        model.refreshPermissions()
        panel.orderOut(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Clip History Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let pickerOpened = Notification.Name("ClipHistory.pickerOpened")
}

#if !CLIP_HISTORY_CHECKS
@main
enum ClipHistoryApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
