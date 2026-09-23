# Clip History

A native macOS menu bar clipboard manager. Press **Control–Option–V** (`⌃⌥V`), search your history, and click an entry or press **Return** to reuse it.

Built with SwiftUI and AppKit, with no third-party dependencies.

## Features

- Search text, images, and file references by preview or source app.
- Paste directly into the previous app, or switch to copying back to the clipboard.
- Configure the global shortcut, retention period, entry limit, and launch at login.
- Apply retention edits together, with confirmation before removing saved clips.
- Keep history locally, encrypted with AES-256-GCM and a key stored in macOS Keychain.
- Skip clipboard items marked confidential or transient; pause capture or clear history from Settings.
- Show fixed copy timestamps without per-entry ticking timers.

## Download and install

Download **Clip-History-macOS-AppleSilicon.zip** from the [latest release](https://github.com/Vuzee01/clip-history/releases/latest), unzip it, and move **Clip History.app** to `/Applications`. The packaged app requires an **Apple silicon Mac** running macOS 13 or later. Repository access is required to download private releases.

Open the app, enable clipboard access if requested, then press `⌃⌥V`. For direct paste, enable Accessibility as described below. Local builds are ad-hoc signed and not notarized; see [Package for sharing](#package-for-sharing) for distribution details.

## Build and run

Requires macOS 13 or later, Swift 6 or later, Apple Command Line Tools or Xcode, and Python 3 for the toolchain compatibility helper. The build script creates a native app for the build Mac's architecture, not a universal binary.

```sh
git clone git@github.com:Vuzee01/clip-history.git
cd clip-history
zsh scripts/build.sh
open "dist/Clip History.app"
```

The app runs in the menu bar. Move it to `/Applications` before enabling **Launch at login**. Reopen it with `⌃⌥V` or the clipboard icon.

The build script creates the icon and signs the app locally. Its compatibility helper works around stale Swift package interfaces and duplicate bridging module maps in some Command Line Tools installations, without modifying system files.

## Permissions and direct paste

On macOS versions with clipboard privacy, click **Allow access**, then choose **Always Allow** for Clip History under **System Settings → Privacy & Security → Paste from Other Apps**. Only new copies are captured after launch; background polling does not repeatedly request permission.

The **Paste immediately** switch appears below search and in Settings. The preference is remembered:

- **On:** selecting an entry pastes into the previously active app. Click **Enable Accessibility…** and grant Clip History access in System Settings first.
- **Off:** selecting an entry restores it to the clipboard. Paste later with `⌘V`.

Without Accessibility permission, selecting an entry still copies it. Capture and the global shortcut do not need that permission. `⌘Return` and right-click → **Copy** always copy without direct paste.

### Permission stops working after a rebuild

Local ad-hoc builds change the app's signature, which can invalidate its previous permission even when the system switch appears enabled. Quit Clip History, remove its entry from **System Settings → Privacy & Security → Accessibility** (called **Device Control and Data Access** on macOS 27), reopen the current build, and grant access again.

Alternatively, while the app is quit, reset only its Accessibility entry:

```sh
tccutil reset Accessibility local.cliphistory.app
```

Then reopen the app and enable access. A rebuild may also require approving Keychain access again.

## Controls

| Action | Control |
| --- | --- |
| Show or hide history | `⌃⌥V` or menu bar clipboard icon |
| Search | Type in the search field |
| Select an entry | `↑` / `↓` |
| Use selected entry | Return or click |
| Copy without direct paste | `⌘Return` or right-click → Copy |
| Use one of the first nine results | `⌘1` through `⌘9` |
| Delete selected entry | `⌘Delete` or right-click → Delete |
| Close | Escape or click outside |
| Settings | Gear button or `⌘,` |
| Change shortcut | Settings → Global shortcut |

Global shortcuts require Control or Command plus another modifier and a letter or number. Single-modifier combinations such as `⌘C`, `⌘V`, `⌘Q`, and Option–letter are rejected; unsafe shortcuts saved by older versions fall back to `⌃⌥V`.

## Storage and automatic purge

History defaults to **24 hours and 200 entries**. Settings supports retention from **1 to 8,760 hours**, up to **500 entries**, and a pause switch. Copying identical content again moves it to the top and restarts its retention period; reusing an existing entry does not.

Expired entries are purged on launch, wake, opening history, applying retention settings, and every 30 seconds while running. Editing settings does not change retention until you click **Apply retention changes**; changes that remove saved clips require confirmation. Purging cannot happen while the app is quit or the Mac is asleep; overdue entries are removed when it resumes. Purging history does not clear the system clipboard. Fixed timestamps do not affect expiry.

- **Formats:** text with available RTF/HTML representations, one image representation per item (PNG preferred, TIFF fallback), and file references. Oversized representations are skipped while smaller usable formats are retained. File contents are not archived; moved or deleted files may no longer paste. Unsupported formats are skipped.
- **Limits:** 100 items and 8 MiB of retained representations per clip, and 32 MiB of clipboard payloads in the history. Size/count exclusions produce a notice in the picker. Multi-item copies are skipped if any item has no usable representation, to avoid restoring an incomplete selection.
- **Store:** `~/Library/Application Support/ClipHistory/history.encrypted`, an atomically written encrypted snapshot. Encoding, encryption, and disk writes run on a serial background actor after 750 ms without a change. Quitting flushes pending changes; a save failure offers a chance to keep the app running. File permissions are restricted and the folder is excluded from backups. Snapshots now have a version; existing unversioned history still loads, and unknown versions are left untouched.
- **Key:** a random 256-bit key in the login Keychain, service `local.cliphistory.encryption`, account `history-key`. It is device-only and is not included in app packages.
- **Privacy:** no network code or cloud sync. macOS Universal Clipboard is a separate system feature. Confidential/transient markers are respected, but an unmarked password or secret can still be captured.
- **Encryption boundary:** encryption protects the saved file at rest, including any copies of that file. It is not a security boundary against processes running as your logged-in user that can access the key or the app's memory.
- **Screen sharing:** assume the picker is visible in recordings and shared screens. Apple's [`NSWindow.SharingType.none`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum) is a legacy constant that macOS no longer uses; it does not provide a reliable privacy guarantee.

Storage failures appear in the app. Storage retries on wake, session activation, and periodic maintenance, as well as through the Retry button. Unreadable history is not silently overwritten. If the key is permanently lost or the store is corrupt, intentionally deleting the encrypted store while the app is quit starts fresh; this destroys the saved history and is not a fix for a temporarily locked Keychain.

Capture checks the pasteboard change count every 0.6 seconds and reads content only after a change. Permission checks run on activation/opening, during periodic maintenance, and before reading changed clipboard content. An unchanged purge does not trigger a history redraw.

Source-app labels are best-effort: another app can become frontmost between a copy and the next poll. Copies while Clip History owns keyboard focus are skipped. Background capture still requires `alwaysAllow` on systems exposing clipboard permissions: Apple's [default behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default) can prompt, so polling must not assume it is permission. Cross-version checks on macOS 15.4 and later remain part of release testing.

## Checks and demo

```sh
zsh scripts/test.sh
```

The package has a SwiftPM test target (`swift test` with a working Xcode toolchain). The script uses SwiftPM when XCTest is available and otherwise runs the same checks directly with `swiftc`, supporting Command Line Tools-only installations. Both app and checks compile in Swift 6 mode. macOS CI runs the checks, builds the app, verifies its signature, and uploads an app ZIP with a SHA-256 checksum as a workflow artifact.

Checks use isolated pasteboards and temporary encrypted files, without reading your clipboard or using your Keychain. Coverage includes capture/restore, rich text, images, multiple files, required confidential markers, deduplication, expiry boundaries, size/count limits, encryption, nonce freshness, tampering, wrong keys, unchanged purges, lazy image formats, retention confirmation, unsafe shortcuts, legacy storage versions, deferred writes, quit flushing, and save retries. Run from a normal macOS terminal so pasteboard services are available.

To preview synthetic history, quit the regular app first, then run:

```sh
open "dist/Clip History.app" --args --demo
```

Demo mode does not capture or save live clipboard history, and selections restore only to its private test pasteboard.

For a manual check, copy two pieces of text, open history, search, and select an entry. Verify direct paste and copy-only mode, Caps Lock with `⌘1`/`⌘Delete`, and Return/arrow keys while composing Chinese or Japanese search text. Check shortcut and retention preferences after relaunching, including canceling a destructive change. Check launch at login after moving the app to its permanent location.

## Package for sharing

GitHub Actions handles builds and releases. Every branch push, pull request, or manual **Build and release** run produces a downloadable Apple silicon app artifact, retained for 14 days. Pushing a `v*` tag also publishes the tested ZIP and `SHA256SUMS` as a GitHub release. The tag must match `CFBundleShortVersionString` in `Resources/Info.plist`; release notes come from the annotated tag.

To publish the next version, update `CFBundleShortVersionString` and increment `CFBundleVersion`, commit and push those changes, then create and push the matching tag:

```sh
git tag -a v1.1.3 -m "Describe the changes in this release."
git push origin v1.1.3
```

Publishing uses GitHub's built-in workflow token; no personal access token is needed. Releases use the same ad-hoc signing as local builds, so Developer ID signing and notarization remain separate distribution work.

To package a local build manually after building:

```sh
ditto -c -k --sequesterRsrc --keepParent "dist/Clip History.app" "dist/Clip-History-macOS.zip"
```

The ZIP contains the app, not your clipboard history or Keychain key. The local build is ad-hoc signed and not notarized, so another Mac may block it. Use Developer ID signing and Apple notarization for normal distribution without that unverified-developer warning. Recipients need an app built for their Mac's architecture.

Build output, packages, editor state, credentials, and local clipboard data are excluded by `.gitignore`.

## Source layout

| Path | Purpose |
| --- | --- |
| `Sources/ClipHistory/App.swift` | App lifecycle, menu bar, global shortcut, picker, and direct paste |
| `Sources/ClipHistory/ClipboardModel.swift` | Clipboard polling, preferences, permission state, and persistence coordination |
| `Sources/ClipHistory/History.swift` | Clip formats, retention, size limits, and encrypted storage |
| `Sources/ClipHistory/Views.swift` | History picker and Settings |
| `Resources/Info.plist` | App metadata |
| `scripts/` | Build, icon generation, toolchain helper, and checks |
| `Tests/ClipHistoryTests/HistoryTests.swift` | Runnable clipboard, storage, and idle-update checks |
