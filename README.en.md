# LaunchGrid

Launch Mac apps from a familiar icon grid, organize folders, and inspect an app's resource use and network connections. Fullscreen and resizable window modes share the same tools.

[Download the latest release](https://github.com/CacinieP/launchgrid/releases/latest) · [中文](README.md) · [0.4.2 release notes](doc/releases/0.4.2.md) · [Feedback](https://github.com/CacinieP/launchgrid/issues/new/choose)

<img src="doc/screenshots/apps.png" width="820" alt="LaunchGrid application grid"/>

## Download and requirements

- **macOS 26 or later**, Apple Silicon or Intel.
- Download a DMG from [GitHub Releases](https://github.com/CacinieP/launchgrid/releases/latest), drag LaunchGrid into **Applications**, and open it. Official distributions use Developer ID signing and Apple notarization; check the release page for the available version and assets.
- LaunchGrid stays in the menu bar and has no Dock icon. Its menu provides panel shortcuts, Settings, and Quit.

## First use

1. Press **F4** to open the grid; some keyboards require **fn**. If it does not respond, open Settings from the menu bar to choose another shortcut and check conflicts.
2. Search by app name, Chinese pinyin, initials, or a custom alias. Press **Down** to select, then use arrow keys and **Return** to launch. **Esc** hides the panel.
3. Drag to reorder apps. Use the context menu to create folders and move apps in or out. The **Layout** menu backs up and restores your layout.
4. Right-click an app to inspect CPU, memory, related processes and visible connections, or request a normal quit.

Choose fullscreen or window as the default presentation in the menu. **Command-F4** opens window mode directly. Window size and position are remembered; closing it leaves LaunchGrid in the menu bar. Settings also controls launch at login and all shortcuts.

## Main features

| Panel | Default shortcut | Purpose |
|---|---|---|
| Apps | F4 | Search and launch, reorder, single-level folders, aliases, layout backups |
| Processes | Option-F4 | Inspect CPU/memory, search by name or PID, terminate or force quit |
| Clipboard | Shift-F4 | Optional text history, search, copy or paste back |
| Network | Shift-Option-F4 | Rates and connections, DNS checks, on-demand diagnostics and repairs |

The app inventory updates automatically after installations or removals. Legacy Launchpad import requires a surviving Apple database with a supported schema and matches only installed apps. Deleted databases cannot be reconstructed. Folders are one level deep; clipboard images and files are not collected.

| Processes | Clipboard |
|---|---|
| <img src="doc/screenshots/processes.png" width="420" alt="Process panel"/> | <img src="doc/screenshots/clipboard.png" width="420" alt="Clipboard panel"/> |

| Network traffic | Diagnostics |
|---|---|
| <img src="doc/screenshots/network-traffic.png" width="420" alt="Network traffic"/> | <img src="doc/screenshots/network-diagnostics.png" width="420" alt="Network diagnostics"/> |

## Modules, privacy, and permissions

**Clipboard history is off for new installations.** Enabling it records newly copied plain text in the background. You can disable or pause collection, exclude apps, or confirm clearing all history. Copies made while disabled or paused are not imported later. Upgrades with existing history retain the previous enabled behavior and show a notice in Settings.

History stays on this Mac as **unencrypted JSON**, with file permissions `0600`, seven-day retention and a 200-entry limit. Sources are estimated from the foreground app. Excluding an app also removes its matching history. Sensitive content is skipped only when the source app marks it; not every secret can be detected. Disabling collection does not clear existing history.

**The network module is optional.** Regular sampling runs only while the network panel or an app inspector is visible. Hidden/disabled time is excluded from recorded totals. Connection visibility depends on macOS permissions; CPU values are system averages. Manual DNS probes and diagnostics send real requests. DNS changes and repairs explain their impact and request administrator authorization when needed.

App launching and global shortcuts do not require Accessibility access. **Automatic paste-back does**; authorize it in System Settings → Privacy & Security → Accessibility, or use Copy and paste manually.

## Updates

Daily stable-release checks are enabled by default and can be disabled in Settings. You can also check manually. Checks contact GitHub; **downloading and installing requires a separate click**.

The updater can verify and replace writable installations in `/Applications` or `~/Applications`, then offers a restart. Use the [release page](https://github.com/CacinieP/launchgrid/releases/latest) for other locations or unsupported assets. Automatic rollback after a failed application launch is not provided.

## Feedback and development

[Report a bug or request a feature](https://github.com/CacinieP/launchgrid/issues/new/choose) with the app/macOS versions and reproduction steps. Do not include clipboard contents, credentials, or complete connection logs. The [one-week trial checklist](doc/USER_TESTING.md) helps collect real usage feedback.

Developer documentation is in **[doc/](doc/README.md)**: [development](doc/development.md), [architecture](doc/architecture.md), [technical decisions](doc/decisions.md), and [releasing](doc/releasing.md). Technical guides are primarily in Chinese.

## License

Version **0.4.2 and later use AGPL-3.0-only**; see [LICENSE](LICENSE). Copyright © 2026 CacinieP. Historical tags retain their own license records.

The app includes the complete license and exact source commit URL. Releases include a corresponding source archive; Settings → About links to the source and license.
