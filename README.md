# Ferry

A menu bar app that moves files and whole folders, of any type, between your Mac and an Android phone, in both directions. You don't need a shared Wi-Fi network.

| Way | Connection | Speed | Needs on the phone |
|---|---|---|---|
| **USB cable** | Direct, no network | Fastest | Pick "File transfer" once when you plug in |
| **Phone's browser** | Direct, over the phone's hotspot (or any Wi-Fi you share) | Fast | Scan a QR code; nothing to install |
| **Quick Share** | Phone and Mac on the same Wi-Fi network | Fast | Nothing; the Mac shows up in Quick Share |

Why not cable-free Quick Share without a shared network: Quick Share finds devices over Bluetooth and links them with Wi-Fi Direct. macOS doesn't let apps use either, so no Mac app can do it. The browser page over the phone's hotspot is the wireless substitute.

## Download

**[Download Ferry for macOS (Ferry-1.0.dmg)](https://github.com/ahk24/ferry/releases/latest/download/Ferry-1.0.dmg)**. It needs macOS 14 or later.

1. Open the DMG and drag **Ferry** onto **Applications**.
2. On first launch, macOS will say Ferry "can't be opened" because it isn't notarized by Apple. Click **Done**. Then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Ferry.

To build it yourself instead (needs the Xcode command line tools):

```bash
./scripts/build-app.sh --install   # builds and copies Ferry.app to ~/Applications
./scripts/make-dmg.sh              # builds dist/Ferry-<version>.dmg
```

Ferry lives in the menu bar (⇄ icon). macOS may ask for:

- **Local Network:** needed for the browser page and Quick Share.
- **Downloads folder access:** needed the first time something is saved there.
- **Incoming connections:** if your firewall is on.

The app is signed only for this Mac, so macOS may ask again after you rebuild it.

## Send to the phone

Drop files or folders onto the ⇄ icon. You can also open the menu and click **Send files or folders**, or right-click files in Finder and choose **Open With → Ferry**. A window offers:

- **By USB cable:** one click; everything lands in the phone's Download folder, folders included.
- **Phone's browser:** the files appear on Ferry's page on the phone, each with a Download button, plus "Download all".
- **Quick Share:** works only on a shared Wi-Fi network.

## Get files from the phone

- **By cable:** click **Browse phone**. Use the shortcuts (Camera, Screenshots, Downloads, Documents, WhatsApp) or browse the folders. Select files or folders and click **Copy to Mac**. You can also drop Mac files into that window to copy them into the open folder.
- **Phone's browser:** click **Phone's browser** in the menu and follow the three steps: turn on the hotspot, join it from the Mac, scan the code. On the phone, tap **Choose files**. Any type works. Android's browser can't pick whole folders, so for folders use the cable.
- **Quick Share:** works only on a shared Wi-Fi network.

Everything you receive is saved to Downloads; to choose another folder, click **Change…** in the menu.

## How it works

| Part | Files |
|---|---|
| Cable: Android's USB file-transfer protocol (MTP), spoken directly over IOUSBHost | `Sources/FerryCore/Cable/` |
| Browser page: a small web server; every request needs the key from the QR code | `Sources/FerryCore/Web/` |
| Quick Share protocol: discovery, UKEY2 key exchange, encryption, transfers | `Sources/FerryCore/*.swift` |
| Menu bar app (SwiftUI in AppKit windows) | `Sources/Ferry/` |

These details are deliberate:

- **Image Capture's helper.** macOS's helper `ptpcamerad` claims any phone in file-transfer mode the moment it's plugged in. Ferry stops it when it holds the phone. It's a per-user helper, and macOS restarts it when another app needs it.
- **Window sizing.** Windows are sized by measuring their content, not by SwiftUI's automatic sizing. On this macOS version, automatic sizing can loop inside AppKit's layout pass and abort the app. That was the cause of the crash in the first version.
- **Untrusted names.** File names from the phone are cleaned so they can't escape the save folder.
- **Quarantine.** Received files are quarantine-marked like any download, so Gatekeeper checks them before they open.

## Checks

```bash
swift run ferry-selftest
```

This runs 57 checks with no phone needed: protocol constants, the encodings, Quick Share transfers between two copies of Ferry on this Mac (files, folders, a decline), and the browser page (upload, download, wrong key).

```bash
swift run ferry-selftest cable
```

This runs the live cable test, with your phone plugged in and unlocked. It browses the phone, copies a test folder with a 20 MB file to the phone and back, checks every byte, and deletes the test folder from the phone.

```bash
.build/debug/Ferry --render-previews /tmp/ferry-previews
```

This draws every window with sample data to PNG files.

`--open send|menu|wireless|browse|offer` opens a window at launch, for testing.

The protocol details come from the reverse-engineering notes in [NearDrop](https://github.com/grishka/NearDrop) by grishka. Ferry's code is written independently.
