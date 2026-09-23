import AppKit
import CryptoKit

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

@main
struct HistoryChecks {
    static func main() throws {
        try testCaptureRestorePrivacyExpiryAndEncryptedPersistence()
        try testLimitsRichTextImagesAndMultipleFiles()
        try testIdlePurgeDoesNotRedrawHistory()
        print("All clipboard, encryption, and idle-update checks passed.")
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
        for marker in Clip.ignored {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(secret, forType: .string)
            // New macOS versions reject historical marker names that are not UTIs.
            guard item.setData(Data(), forType: .init(marker)) else { continue }
            board.writeObjects([item])
            try expect(Clip.capture(from: board, source: "Test") == nil, marker)
        }
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
}
