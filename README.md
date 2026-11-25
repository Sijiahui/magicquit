<p align="center">
  <img src="MagicQuit/Assets.xcassets/Image.imageset/256.png" width="128" alt="MagicQuit icon">
</p>

<h1 align="center">MagicQuit</h1>

<p align="center">Automatically quits or restarts idle apps from the macOS menu bar.</p>

---

This fork of [MagicQuit](https://github.com/BigBerny/magicquit) keeps the native menu bar interface and adds:

- **Per-app actions.** Select **Off**, **Quit**, or **Restart** next to each app. **Restart** requests a normal quit and reopens the app in the background after the original process exits. If the app is still open after 20 seconds, MagicQuit skips the relaunch. Window and document restoration depend on the app.
- **Two idle modes.** **Per App** is the default and tracks each app separately. **Whole Mac** uses one countdown based on keyboard and pointing-device inactivity. Time spent asleep does not count. The timeout ranges from 15 minutes to 48 hours, including a 3-hour option. The default is 8 hours.
- **Simplified Chinese.** The menu, settings, and countdowns follow the macOS app language. English is also available.

## Install

Download the universal ZIP from this fork’s [Releases page](https://github.com/Sijiahui/magicquit/releases), unzip it, and drag `MagicQuit.app` into `/Applications`. It requires macOS 14 or later and supports Apple silicon and Intel Macs.

Fork builds are ad hoc signed and are not notarized by Apple. macOS may block the first launch. Download future fork versions from Releases.

## Usage

- Click the menu bar icon to see running apps and choose an action for each. The reset button resets that app’s timer in **Per App** mode.
- Choose the idle mode, timeout, and login behavior in **Settings**.
- **Quit on last window close** is a separate setting. It requests a normal quit when an app’s last window closes. Apps set to **Off** and apps on the window-quitting exclusion list stay open.

### 简体中文

点击菜单栏图标，为每个应用选择「不处理」「退出」或「重启」。在「设置 → 通用」中可选择按应用或按整机计时，并将空闲时长设为 3 小时。重启前会等待原进程正常退出。应用若卡在保存提示，超过 20 秒就跳过后台重开。

### Accessibility permission

The window-close feature uses the Accessibility API to count an app's windows, including minimized windows. Grant access in **System Settings → Privacy & Security → Accessibility** if you enable it. Idle actions require no Accessibility permission.

## How it quits apps

MagicQuit always quits apps politely (the equivalent of ⌘Q). Apps with unsaved changes will ask you to save instead of losing data; MagicQuit never force-kills anything.

## Building

Open `MagicQuit.xcodeproj` in Xcode 16 or later and build the `MagicQuit` scheme. Unit tests: `xcodebuild test -scheme MagicQuit`.

## License

[License](LICENSE)
