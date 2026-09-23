import AppKit
import CryptoKit
import Carbon
#if !CLIP_HISTORY_CHECKS
import XCTest
@testable import ClipHistory

final class HistoryTests: XCTestCase {
    @MainActor func testRegressionChecks() async throws { try await HistoryChecks.main() }
}
#endif

private struct CheckFailure: Error {
    let message: String
}

private func expect(_ condition: Bool, _ message: String = "Check failed", file: StaticString = #file, line: UInt = #line) throws {
    if !condition { throw CheckFailure(message: "\(file):\(line): \(message)") }
}

private func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(message: "\(file):\(line): Expected a non-nil value") }
    return value
}

private func expectThrows(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(message: "Expected an error")
}

#if CLIP_HISTORY_CHECKS
@main
#endif
@MainActor
struct HistoryChecks {
    static func main() async throws {
        try testIdlePurgeDoesNotRedrawHistory()
        try testCaptureRestorePrivacyExpiryAndEncryptedPersistence()
        try testLimitsRichTextImagesAndMultipleFiles()
        try testFormatBudgetKeepsUsefulRepresentations()
        try testRetentionRequiresCommitAndConfirmation()
        try testShortcutsCannotStealCommonTyping()
        try await testLegacyAndFutureHistoryVersions()
        try await testDebouncedPersistenceFlushAndRetry()
        print("All 8 clipboard, storage, retention, and shortcut regression checks passed.")
    }

    static func testIdlePurgeDoesNotRedrawHistory() throws {
        let model = ClipboardModel(demo: true)
        let original = model.history.clips
        var updates = 0
        let subscription = model.objectWillChange.sink { updates += 1 }
        for _ in 0..<10 { model.purge() }
        try expect(model.history.clips == original)
        try expect(updates == 0, "An idle purge must not trigger SwiftUI redraws")
        withExtendedLifetime(subscription) {}
    }
    static func testCaptureRestorePrivacyExpiryAndEncryptedPersistence() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let secret = "test-only private clipboard sentence"
        board.setString(secret, forType: .string)
        let clip = try unwrap(Clip.capture(from: board, source: "Test", now: now))
        try expect(clip.preview == secret)
        var checkedMarkers = Set<String>()
        for marker in Clip.ignored {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(secret, forType: .string)
            // New macOS versions reject historical marker names that are not UTIs.
            guard item.setData(Data(), forType: .init(marker)) else {
                print("macOS rejected legacy clipboard marker: \(marker)")
                continue
            }
            checkedMarkers.insert(marker)
            board.writeObjects([item])
            try expect(Clip.capture(from: board, source: "Test") == nil, marker)
        }
        try expect(checkedMarkers.isSuperset(of: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]),
                   "The supported privacy markers must actually be exercised")
        try expect(clip.restore(to: board))
        try expect(board.string(forType: .string) == secret)

        var history = History()
        history.insert(clip, hours: 24, limit: 200, now: now)
        var duplicate = clip
        duplicate.id = UUID()
        duplicate.copiedAt = now.addingTimeInterval(10)
        history.insert(duplicate, hours: 24, limit: 200, now: duplicate.copiedAt)
        try expect(history.clips.count == 1)
        try expect(history.clips.first?.id == duplicate.id)
        try expect(!history.purge(hours: 24, limit: 200, now: now.addingTimeInterval(86_409)))
        try expect(history.purge(hours: 24, limit: 200, now: now.addingTimeInterval(86_410)))
        try expect(history.clips.isEmpty)
        history.insert(clip, hours: 24, limit: 200, now: now)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(url: folder.appendingPathComponent("history.encrypted"), key: SymmetricKey(size: .bits256))
        try expect(vault.load().clips.isEmpty)
        try vault.save(history)
        try expect(vault.load().clips == history.clips)
        let encrypted = try Data(contentsOf: vault.url)
        try expect(encrypted.range(of: Data(secret.utf8)) == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: vault.url.path)[.posixPermissions] as? Int
        try expect(permissions == 0o600)
        try vault.save(history)
        try expect(Data(contentsOf: vault.url) != encrypted, "Every save must use a fresh nonce")
        let wrongKey = Vault(url: vault.url, key: SymmetricKey(size: .bits256))
        try expectThrows { _ = try wrongKey.load() }
        var damaged = encrypted
        damaged[damaged.count / 2] ^= 1
        try damaged.write(to: vault.url)
        try expectThrows { _ = try vault.load() }
        try expect(Data(contentsOf: vault.url) == damaged, "Failed load must leave the file untouched")
        try vault.save(History())
        try expect(vault.load().clips.isEmpty)
    }

    static func testLimitsRichTextImagesAndMultipleFiles() throws {
        let now = Date()
        var history = History()
        for i in 0..<5 {
            let clip = Clip(copiedAt: now.addingTimeInterval(Double(i)), source: "Test", items: [["public.utf8-plain-text": Data("\(i)".utf8)]], preview: "\(i)", kind: "Text")
            history.insert(clip, hours: 24, limit: 3, now: now)
        }
        try expect(history.clips.map(\.preview) == ["4", "3", "2"])
        try expect(history.purge(hours: 1, limit: 3, now: now.addingTimeInterval(3_604)))
        try expect(history.clips.isEmpty)

        let big = Data(repeating: 1, count: Clip.maximumBytes)
        history.clips = (0..<5).map { _ in Clip(copiedAt: now, source: "Test", items: [["public.png": big]], preview: "Image", kind: "Image") }
        history.purge(hours: 24, limit: 500, now: now)
        try expect(history.clips.count == 4)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSPasteboardItem()
        rich.setString("Hello", forType: .string)
        rich.setString("<b>Hello</b>", forType: .html)
        board.writeObjects([rich])
        let text = try unwrap(Clip.capture(from: board, source: "Test"))
        try expect(text.restore(to: board))
        try expect(board.string(forType: .html) == "<b>Hello</b>")

        board.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        let imageItem = NSPasteboardItem()
        imageItem.setData(try unwrap(image.tiffRepresentation), forType: .tiff)
        board.writeObjects([imageItem])
        let imageClip = try unwrap(Clip.capture(from: board, source: "Test"))
        try expect(imageClip.kind == "Image")
        try expect(imageClip.restore(to: board))
        try expect(NSImage(pasteboard: board) != nil)

        board.clearContents()
        let files = ["file:///tmp/one.txt", "file:///tmp/two.txt"].map { url in
            let item = NSPasteboardItem(); item.setString(url, forType: .fileURL); return item
        }
        board.writeObjects(files)
        let fileClip = try unwrap(Clip.capture(from: board, source: "Finder"))
        try expect(fileClip.preview == "one.txt, two.txt")
        try expect(fileClip.restore(to: board))
        try expect(board.pasteboardItems?.count == 2)

        board.clearContents()
        board.setData(Data(repeating: 0, count: Clip.maximumBytes + 1), forType: .png)
        try expect(Clip.capture(from: board, source: "Test") == nil)
    }

    static func testFormatBudgetKeepsUsefulRepresentations() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let oversized = Data(repeating: 0, count: Clip.maximumBytes + 1)
        let item = NSPasteboardItem()
        item.setString("Excel range", forType: .string)
        item.setData(oversized, forType: .rtf)
        item.setString("<table>range</table>", forType: .html)
        item.setData(Data([1, 2, 3]), forType: .png)
        let provider = ImageProvider()
        item.setDataProvider(provider, forTypes: [.tiff])
        try expect(board.writeObjects([item]))
        var warning: String?
        let clip = try unwrap(Clip.capture(from: board, source: "Excel", onLimit: { warning = $0 }))
        try expect(warning != nil)
        try expect(clip.preview == "Excel range")
        try expect(clip.items[0][NSPasteboard.PasteboardType.rtf.rawValue] == nil)
        try expect(clip.items[0][NSPasteboard.PasteboardType.html.rawValue] != nil)
        try expect(clip.items[0][NSPasteboard.PasteboardType.png.rawValue] != nil)
        try expect(clip.items[0][NSPasteboard.PasteboardType.tiff.rawValue] == nil)
        try expect(provider.requests == 0, "An available PNG must avoid requesting TIFF from the source app")

        board.clearContents()
        let fallback = NSPasteboardItem()
        fallback.setData(oversized, forType: .png)
        fallback.setData(Data([4, 5]), forType: .tiff)
        board.writeObjects([fallback])
        let fallbackClip = try unwrap(Clip.capture(from: board, source: "Test"))
        try expect(fallbackClip.items[0].count == 1)
        try expect(fallbackClip.items[0][NSPasteboard.PasteboardType.tiff.rawValue] != nil)

        board.clearContents()
        board.setData(oversized, forType: .string)
        warning = nil
        try expect(Clip.capture(from: board, source: "Test", onLimit: { warning = $0 }) == nil)
        try expect(warning != nil, "Oversized text must explain why capture was skipped")
    }

    static func testRetentionRequiresCommitAndConfirmation() throws {
        let model = ClipboardModel(demo: true)
        let clips = model.history.clips
        let hours = model.hours
        let limit = model.limit
        try expect(model.retentionRemovalCount(hours: 24, limit: 1) == clips.count - 1)
        try expect(!model.applyRetention(hours: 24, limit: 1))
        try expect(model.history.clips == clips && model.hours == hours && model.limit == limit)
        try expect(model.applyRetention(hours: 24, limit: 1, confirmRemoval: true))
        try expect(model.history.clips.count == 1 && model.limit == 1)
        try expect(model.applyRetention(hours: .infinity, limit: 9_000))
        try expect(model.hours == 24 && model.limit == 500)
    }

    static func testShortcutsCannotStealCommonTyping() throws {
        for modifiers in [cmdKey, optionKey, controlKey, shiftKey, optionKey | shiftKey] {
            for (keyCode, key) in [(kVK_ANSI_C, "C"), (kVK_ANSI_V, "V"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_A, "A")] {
                let shortcut = Shortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), key: key)
                try expect(!shortcut.isSafe, shortcut.label)
                try expect(!GlobalShortcut().register(shortcut), "Unsafe shortcuts must be rejected before Carbon registration")
            }
        }
        try expect(Shortcut.default.isSafe)
        let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option, .capsLock],
                                               timestamp: 0, windowNumber: 0, context: nil, characters: "v",
                                               charactersIgnoringModifiers: "v", isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
        try expect(Shortcut(event: event) == .default)
        let model = ClipboardModel(demo: true)
        var registrations = 0
        model.onShortcutChange = { _ in registrations += 1; return true }
        model.setShortcut(Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), key: "C"))
        try expect(registrations == 0 && model.notice == Shortcut.requirement)
    }

    static func testLegacyAndFutureHistoryVersions() async throws {
        let encoder = PropertyListEncoder()
        let history = History(clips: [Clip(source: "Test", items: [["public.utf8-plain-text": Data([65])]], preview: "A", kind: "Text")])
        var plist = try unwrap(PropertyListSerialization.propertyList(from: encoder.encode(history), format: nil) as? [String: Any])
        try expect(plist["version"] as? Int == 1)
        plist.removeValue(forKey: "version")
        let legacy = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try expect(PropertyListDecoder().decode(History.self, from: legacy).clips == history.clips)
        plist["version"] = 2
        let future = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try expectThrows { _ = try PropertyListDecoder().decode(History.self, from: future) }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(url: folder.appendingPathComponent("history.encrypted"), key: SymmetricKey(size: .bits256))
        let storage = HistoryStorage(vault: vault)
        try unwrap(AES.GCM.seal(legacy, using: vault.key).combined).write(to: vault.url)
        try expect(try await storage.load().clips == history.clips)
        let encryptedFuture = try unwrap(AES.GCM.seal(future, using: vault.key).combined)
        try encryptedFuture.write(to: vault.url)
        do {
            _ = try await storage.load()
            throw CheckFailure(message: "A future history version must not load")
        } catch VaultError.unsupportedVersion(2) { }
        do {
            try await storage.save(History())
            throw CheckFailure(message: "A failed load must prevent writes")
        } catch VaultError.invalidFile { }
        try expect(Data(contentsOf: vault.url) == encryptedFuture)
    }

    static func testDebouncedPersistenceFlushAndRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = Vault(url: folder.appendingPathComponent("history.encrypted"), key: SymmetricKey(size: .bits256))
        let clip = Clip(source: "Test", items: [["public.utf8-plain-text": Data([65])]], preview: "A", kind: "Text")
        try vault.save(History(clips: [clip]))
        let encrypted = try Data(contentsOf: vault.url)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let model = ClipboardModel(storage: HistoryStorage(vault: vault), pasteboard: board)
        model.paused = true
        try expect(await model.flushStorage())
        try expect(Data(contentsOf: vault.url) == encrypted, "Opening unchanged history must not rewrite it")
        try expect(model.history.clips == [clip])
        model.delete(clip.id)
        model.clear()
        try expect(Data(contentsOf: vault.url) == encrypted, "Rapid changes must wait for the debounce")
        try expect(await model.flushStorage())
        try expect(vault.load().clips.isEmpty, "Quit must flush the latest snapshot, including deletions")
        let flushed = try Data(contentsOf: vault.url)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try expect(Data(contentsOf: vault.url) == flushed, "A canceled delayed save must not run after the flush")

        try FileManager.default.removeItem(at: folder)
        model.clear()
        try expect(!(await model.flushStorage()))
        try expect(model.error != nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.retryStorage()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try expect(vault.load().clips.isEmpty && model.error == nil)
    }
}

private final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
    var requests = 0
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requests += 1
        item.setData(Data([9]), forType: type)
    }
}
