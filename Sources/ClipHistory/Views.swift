import AppKit
import Carbon
import ImageIO
import SwiftUI

private let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.40, green: 0.80, blue: 0.67, alpha: 1)
        : NSColor(srgbRed: 0.12, green: 0.48, blue: 0.39, alpha: 1)
})

struct PickerView: View {
    @ObservedObject var model: ClipboardModel
    let choose: (Clip, Bool) -> Void
    let dismiss: () -> Void
    let settings: () -> Void
    @State private var query = ""
    @State private var selection: UUID?
    @State private var keyMonitor: Any?
    @State private var clips: [Clip] = []
    @FocusState private var searchFocused: Bool

    private func filterClips() {
        clips = model.history.clips.filter { query.isEmpty || $0.preview.localizedStandardContains(query) || $0.source.localizedStandardContains(query) || $0.kind.localizedStandardContains(query) }
        if !clips.contains(where: { $0.id == selection }) { selection = clips.first?.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clipboard.fill").font(.system(size: 22)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip History").font(.system(size: 17, weight: .semibold))
                    Text(model.demo ? "Preview · sample history" : "Everything you copied. Within reach.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.shortcut.label).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 16)) }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your clipboard…", text: $query).textFieldStyle(.plain)
                    .font(.system(size: 16)).focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(13).background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                .padding(.horizontal, 18).padding(.bottom, 14)

            HStack {
                Toggle("Paste immediately", isOn: $model.directPaste)
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
                    .help("On: paste into the previous app. Off: copy to the clipboard for later.")
                Spacer()
                Text(model.directPaste ? "Into the previous app" : "Copy to clipboard only")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 22).padding(.bottom, 12)

            if model.directPaste && !model.accessibilityEnabled {
                HStack {
                    Text("Allow Accessibility for instant paste. Until then, clicking copies.")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Enable Accessibility…") { model.requestAccessibilityAccess() }
                        .controlSize(.small)
                }.padding(10).background(accent.opacity(0.08)).padding(.horizontal, 18).padding(.bottom, 10)
            }

            if let error = model.error {
                banner(error, symbol: "exclamationmark.triangle")
                Button("Retry encrypted storage") { model.retryStorage() }.padding(.bottom, 8)
            }
            if model.needsClipboardAccess {
                HStack {
                    Text("Allow clipboard access to start saving history.").font(.callout)
                    Spacer()
                    Button("Allow access") { model.requestClipboardAccess() }
                }.padding(12).background(accent.opacity(0.08)).padding(.horizontal, 18).padding(.bottom, 8)
            }
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }.padding(10).background(accent.opacity(0.08)).padding(.horizontal, 18).padding(.bottom, 8)
            }

            HStack {
                Text(query.isEmpty ? "RECENT" : "RESULTS").font(.system(size: 10, weight: .semibold)).tracking(1.4)
                Text("\(clips.count)").font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                Spacer()
                Text(model.paused ? "Capture paused" : "Auto-purge after \(retentionLabel)").font(.system(size: 11))
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.bottom, 8)

            if clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.7))
                    Text(query.isEmpty ? "Your next copy starts here" : "No matching clips").font(.system(size: 17, weight: .medium))
                    Text(query.isEmpty ? "Copy text, an image, or files.\nPress \(model.shortcut.label) to find them again." : "Try a different word or app name.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                                Button { selection = clip.id; choose(clip, false) } label: {
                                    ClipRow(clip: clip, index: index, selected: selection == clip.id)
                                }.buttonStyle(.plain).id(clip.id)
                                    .accessibilityLabel("\(clip.preview), \(clip.source)")
                                    .contextMenu {
                                        Button("Copy") { choose(clip, true) }
                                        Button("Delete", role: .destructive) { model.delete(clip.id) }
                                    }
                            }
                        }.padding(.horizontal, 12).padding(.bottom, 8)
                    }
                    .onChange(of: selection) { id in if let id { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 14) {
                Label("Encrypted on this Mac", systemImage: "lock.shield").foregroundStyle(accent)
                Spacer()
                Text("↑↓ select")
                Text(model.directPaste && model.accessibilityEnabled ? "↩ paste" : "↩ copy")
                Text("esc close")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 620, height: 530)
        .background(.regularMaterial)
        .tint(accent)
        .onChange(of: query) { _ in filterClips(); selection = clips.first?.id }
        .onChange(of: model.history.clips.map(\.id)) { _ in
            filterClips()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pickerOpened)) { _ in
            query = ""; selection = clips.first?.id; searchFocused = true
        }
        .onAppear {
            filterClips()
            searchFocused = true
            selection = clips.first?.id
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window is HistoryPanel else { return event }
                return handle(event) ? nil : event
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    }

    private var retentionLabel: String {
        model.hours >= 24 && model.hours.truncatingRemainder(dividingBy: 24) == 0 ? "\(Int(model.hours / 24))d" : "\(Int(model.hours))h"
    }

    private func banner(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18).padding(.bottom, 8)
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Let the input method finish composition before interpreting picker commands.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == UInt16(kVK_Escape) { dismiss(); return true }
        if flags.isEmpty && (event.keyCode == UInt16(kVK_DownArrow) || event.keyCode == UInt16(kVK_UpArrow)) {
            guard !clips.isEmpty else { return true }
            let index = clips.firstIndex { $0.id == selection } ?? 0
            selection = clips[max(0, min(clips.count - 1, index + (event.keyCode == UInt16(kVK_DownArrow) ? 1 : -1)))].id
            return true
        }
        if event.keyCode == UInt16(kVK_Return), let clip = clips.first(where: { $0.id == selection }) {
            choose(clip, flags.contains(.command)); return true
        }
        if flags == .command, let number = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(number), clips.count >= number {
            choose(clips[number - 1], false); return true
        }
        if flags == .command, event.keyCode == UInt16(kVK_Delete), let selection {
            model.delete(selection); return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "," { settings(); return true }
        return false
    }
}

private struct ClipRow: View {
    let clip: Clip
    let index: Int
    let selected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image = thumbnail {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: clip.symbol).font(.system(size: 17)).foregroundStyle(accent)
                }
            }.frame(width: 38, height: 38).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(clip.preview).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(clip.source)
                    Text("·")
                    Text(clip.copiedAt.formatted(date: .abbreviated, time: .shortened))
                    if clip.kind != "Text" { Text("·"); Text(clip.kind) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if index < 9 { Text("⌘\(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
        }.padding(.horizontal, 12).padding(.vertical, 11)
            .background(selected ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? accent.opacity(0.22) : .clear))
            .contentShape(Rectangle())
            .task(id: clip.id) { thumbnail = makeThumbnail() }
    }

    private func makeThumbnail() -> NSImage? {
        guard let data = clip.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 80,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct SettingsView: View {
    @ObservedObject var model: ClipboardModel
    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var confirmClear = false
    @State private var draftHours = 24.0
    @State private var draftLimit = 200
    @State private var confirmRetention = false
    @State private var removalCount = 0

    var body: some View {
        Form {
            Section("Open history") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    Button(recording ? "Press shortcut…" : model.shortcut.label) { recording.toggle() }
                        .help(Shortcut.requirement + " Escape cancels.")
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Paste immediately when selecting a clip", isOn: $model.directPaste)
                Text(model.directPaste ? "Click or press Return to paste into the previous app." : "Click or press Return to copy to the clipboard. Paste later with ⌘V.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.directPaste {
                    HStack {
                        Text(model.accessibilityEnabled ? "Accessibility access is enabled." : "Direct paste needs Accessibility access. Copy always works.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Enable Accessibility…") { model.requestAccessibilityAccess() }
                    }
                }
            }
            Section("Automatic purge") {
                Picker("Keep history for", selection: $draftHours) {
                    Text("1 hour").tag(1.0)
                    Text("24 hours").tag(24.0)
                    Text("7 days").tag(168.0)
                    Text("30 days").tag(720.0)
                    if ![1.0, 24, 168, 720].contains(draftHours) { Text("\(Int(draftHours)) hours").tag(draftHours) }
                }
                HStack {
                    Text("Custom hours")
                    Spacer()
                    TextField("Hours", value: $draftHours, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing).frame(width: 65)
                        .accessibilityLabel("Custom retention in hours")
                        .onChange(of: draftHours) { value in
                            let safe = value.isFinite ? max(1, min(value.rounded(), 8_760)) : 24
                            if safe != value { draftHours = safe }
                        }
                    Stepper("Retention hours", value: $draftHours, in: 1...8_760, step: 1).labelsHidden()
                }
                Picker("Maximum entries", selection: $draftLimit) {
                    ForEach([50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
                }
                HStack {
                    Button("Apply retention changes") {
                        if !model.applyRetention(hours: draftHours, limit: draftLimit) {
                            removalCount = model.retentionRemovalCount(hours: draftHours, limit: draftLimit)
                            confirmRetention = true
                        }
                    }.disabled(draftHours == model.hours && draftLimit == model.limit)
                    Button("Reset") { draftHours = model.hours; draftLimit = model.limit }
                }
                Text("Expired clips are removed within 30 seconds while running, and on launch or wake. This does not clear the system clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Pause clipboard capture", isOn: $model.paused)
                Text("History stays on this Mac, encrypted with AES-256-GCM. The key stays in Keychain. Password-manager clips marked confidential are skipped; unmarked secrets may still be captured.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Clear history…", role: .destructive) { confirmClear = true }
                    Spacer()
                    Text("\(model.history.clips.count) saved clips").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.notice ?? model.error { Text(message).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("Clip History · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Clip History") { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped).tint(accent).frame(width: 490, height: 600)
        .confirmationDialog("Delete all saved clipboard history?", isPresented: $confirmClear) {
            Button("Delete all history", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This cannot be undone. Your current system clipboard is kept.") }
        .confirmationDialog("Apply retention changes?", isPresented: $confirmRetention) {
            Button("Apply and delete clips", role: .destructive) {
                model.applyRetention(hours: draftHours, limit: draftLimit, confirmRemoval: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("These settings currently remove \(removalCount) saved clips. Deletion cannot be undone.") }
        .onAppear {
            draftHours = model.hours
            draftLimit = model.limit
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard recording, event.window?.title == "Clip History Settings" else { return event }
                if event.keyCode == UInt16(kVK_Escape) { recording = false; return nil }
                if let shortcut = Shortcut(event: event) { model.setShortcut(shortcut); recording = false }
                else { model.notice = Shortcut.requirement }
                return nil
            }
        }
        .onDisappear {
            recording = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        }
    }
}
