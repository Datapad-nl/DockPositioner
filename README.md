# DockPositioner

DockPositioner is a macOS menu bar app that gives every monitor its own Dock, on any edge, including edges where macOS will not put its own Dock. macOS has one Dock, and puts it only on an outer edge of the whole desktop: a Dock on an edge where two monitors touch ends up on the other monitor. DockPositioner draws its own Dock instead, on every monitor that has a profile switched on, each on its own edge with its own settings, all at the same time.

## Features

- Per-monitor position, icon size, magnification and auto-hide.
- Hide the system Dock while DockPositioner runs.
- Keep windows out of the Dock.
- Right-click menu per item.
- Badges, with a bounce on new ones.
- A speaker mark on apps that play sound.
- Trash full or empty state, and Empty Trash.
- Start at login.

## Requirements

- macOS 14 or later.
- Xcode or a Swift toolchain, to build.

## Build and run

```sh
swift build          # debug build
swift test           # unit tests
scripts/build-app.sh # release build -> build/DockPositioner.app
open build/DockPositioner.app
```

There is no prebuilt download yet; build from source.

The app has no Dock icon; it lives in the menu bar.

`scripts/build-app.sh` picks the signing identity like this:

- If `CODESIGN_IDENTITY` is set, it is used as given; `CODESIGN_IDENTITY=-` signs ad-hoc.
- If it is not set, the script uses `Developer ID Application: Datapad B.V. (3FZVG3KWR3)` when that identity is in the keychain (`security find-identity -v -p codesigning` lists it). Otherwise it signs ad-hoc and prints a line saying so.

The Accessibility permission is tied to the signature, and an ad-hoc signature changes on every build, so with ad-hoc builds the permission has to be granted again after each build. To keep it, sign every build with the same identity by setting `CODESIGN_IDENTITY`.

## Release

```sh
NOTARY_PROFILE=<profile> scripts/release.sh
```

This builds the app, checks that it is signed with a Developer ID Application identity and the hardened runtime, zips it, has Apple notarise it, staples the ticket and zips it again. The result is `build/DockPositioner-<version>.zip` (the version comes from `CFBundleShortVersionString` in `scripts/build-app.sh`); the script prints the path and the SHA-256. Without `NOTARY_PROFILE` it is a dry run: the zip is signed but not notarised. A release is never ad-hoc signed.

One-time setup, on the machine that releases:

```sh
xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <team-id>
```

It asks for an app-specific password (create one at appleid.apple.com) and stores the credentials in your keychain under `<profile>`. Nothing is stored in the repository.

Normal builds signed with a Developer ID now use the hardened runtime too, with the entitlements in `scripts/DockPositioner.entitlements` (Apple events, for Empty Trash).

## Permissions

None is needed for the basic Dock.

"Keep windows out of the Dock" needs the Accessibility permission (System Settings > Privacy & Security > Accessibility); switching it on asks for it, and the menu shows a button to that setting until it is granted. The same permission lets the right-click menu list an app's windows and shows the badges (whether "Keep windows out of the Dock" is on or not); without it the windows are left out and there are no badges and no bouncing. "Empty Trash" asks Finder to empty the Trash (Finder shows its own confirmation), which needs the Automation permission for Finder; macOS asks for it the first time (System Settings > Privacy & Security > Automation). If it is denied, Empty Trash does nothing. Nothing else needs a permission.

## What it does

- Per monitor: position (left, bottom or right edge of that monitor), auto-hide, magnification and icon size.
- Items, like the system Dock: Finder, the apps pinned in the system Dock, other running apps, the folders from the right side of the system Dock (such as Downloads), and the Trash. A dot marks running apps; the name shows when the pointer is over an icon.
- Badges: an app's badge in the system Dock (such as an unread count) shows as a red badge on its icon's top-right corner, read every two seconds from the system Dock through Accessibility. When a badge appears, or its number goes up, the icon bounces away from its screen edge three times and rests, on every monitor's Dock. A badge that goes down or disappears, badges already there when DockPositioner starts or gets the Accessibility permission, and the app in front do not bounce. A bounce on an auto-hidden Dock does not bring the Dock out. The "Bounce icons on new badges" toggle in the menu bar window (on by default) switches the bounce off; badges are always shown.
- Sound: an app that is playing sound gets a small white speaker in a dark circle on its icon's bottom-right corner, on every monitor's Dock. Sound from an app's helper processes (such as a browser's) counts for the app. It is read every second from Core Audio and needs no permission (macOS 14.2 or later; on macOS 14.0 and 14.1 there is no speaker). The mark goes away after the app has been quiet for about two seconds. The "Show speaker on apps playing sound" toggle in the menu bar window (on by default) switches the speaker off, and then nothing is read from Core Audio.
- Click an app to launch or activate it, a folder or the Trash to open it in Finder.
- Right-click (or Control-click) an item for its menu, built when it opens:
  - A running app: its windows (with the Accessibility permission; minimised ones marked with a diamond; choosing one brings it forward), Options > "Keep in Dock" (checked when pinned; choosing it pins or unpins) and "Show in Finder", then "Hide" (or "Show" when hidden) and "Quit" ("Force Quit" when Option is held as the menu opens). Finder has no "Keep in Dock" and no "Quit".
  - A pinned app that is not running: "Open", Options > "Remove from Dock" and "Show in Finder".
  - A folder: "Open", "Show in Finder". The Trash: "Open", "Empty Trash".
  - "Keep in Dock" and "Remove from Dock" change the system Dock's own list (`persistent-apps`) and restart the system Dock, so both Docks keep the same apps.
- Auto-hide: the Dock slides off its edge and comes back when the pointer reaches that edge of that monitor, also where the edge touches another monitor.
- "Hide system Dock" keeps the system Dock out of the way: DockPositioner sets the system Dock to auto-hide with a very long delay, and puts your own `autohide` and `autohide-delay` values back when you switch it off or quit DockPositioner. The setting is remembered.
- "Keep windows out of the Dock" (off by default, remembered): a window whose edge is flush with a Dock's screen edge, such as a zoomed (title bar double-click) or tiled window, gets that edge moved to the inside of the Dock, so the window gets a little smaller. This happens shortly after the window stops moving or resizing, and once over all windows when you switch it on or change a profile or the monitors. Windows that merely overlap the Dock, full-screen and minimised windows, and monitors whose Dock auto-hides are left alone.
- "Start at login" registers DockPositioner as a login item through macOS; the switch shows what macOS reports (also under System Settings > General > Login Items), not a saved setting.
  macOS registers the app at its current location, so put it where it will stay (for example /Applications) before switching this on.
- Profiles are kept per display UUID, also for monitors that are currently disconnected.

## Known limits

- The Dock does not reserve screen space (macOS has no public way to do that). With "Keep windows out of the Dock" on, windows can still go under it when dragged there freely, on monitors whose Dock auto-hides, and in apps that refuse to be resized or moved.
- The folders are read from the system Dock; change them there. Apps can be pinned and unpinned from the right-click menu, which restarts the system Dock. No drag and drop, no reordering, no folder stacks, no minimized windows.
- The right-click menu lacks what other apps cannot reproduce with public APIs: an app's own Dock-menu items (such as New Window and recent documents), "Assign To" desktops, "Show All Windows" and "Open at Login".
- Badges and bouncing follow the badges in the system Dock, which macOS shows through Accessibility. An app that asks for attention without changing its badge (for example a finished download, or a dialog waiting in an app in the background) makes the system Dock's icon bounce, but there is no public way for another app to see that, so DockPositioner's icon does not bounce. A badge change can take up to two seconds to show.
- The speaker shows that an app has an audio output open and running, which is not always sound you can hear: an app that plays silence, or that is muted inside the app or by the system volume, still shows it, and some apps keep their output running for a while after they go quiet. Sound from a process outside any app in the Dock (such as `afplay` in Terminal) shows no speaker.
- Magnification enlarges icons in place; neighbouring icons do not move aside.
- The Trash icon is full or empty from the link count of `~/.Trash` and `<volume>/.Trashes/<uid>`, because listing them needs Full Disk Access. A stray `.DS_Store` is subtracted when it can be seen, so the icon is exact; it can lag by up to two seconds. A folder that cannot be stat'ed counts as empty.
- Restarting the system Dock (when switching "Hide system Dock", or pinning or unpinning an app) takes a moment.
- If DockPositioner is stopped without quitting (a crash, `kill -9`), the system Dock stays hidden until DockPositioner runs again; it then restores the values when "Hide system Dock" is off, or keeps the saved ones for later.

## Licence

MIT. See `LICENSE`.
