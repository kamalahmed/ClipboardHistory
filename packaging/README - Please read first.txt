ClipboardHistory — quick start
==============================

What it is
----------
A free clipboard manager for the Mac menu bar. It remembers what you copy
(text and images) so you can paste any of it later.

Requirements
------------
* A Mac with Apple Silicon (M1, M2, M3, M4…). Intel Macs are not supported
  by this build.
* macOS 14 Sonoma or newer.

Install
-------
1. Open ClipboardHistory.dmg
2. Drag ClipboardHistory into the Applications folder shortcut.

First launch
------------
Just double-click it. The app is signed with an Apple Developer ID and
notarized by Apple, so macOS opens it like any other app — no warnings.

Using it
--------
* The app lives in the MENU BAR (clipboard icon, top-right of your screen)
  — it has no Dock icon. On the very first launch it shows the history
  window once so you know it's running.
* Press Cmd+Shift+V anywhere to open your clipboard history.
* Type to search, arrow keys to select, Return to paste.
* Right-click the menu bar icon for Settings.

Optional permissions
--------------------
* Accessibility — ONLY needed if you want the app to paste for you
  automatically after picking an item. Without it, picking an item just
  copies it and you press Cmd+V yourself. Grant it in
  System Settings > Privacy & Security > Accessibility.
* The app needs NO other permissions. It never sends your data anywhere;
  everything is stored on your Mac in
  ~/Library/Application Support/ClipboardHistory/

Notes
-----
* Passwords copied from password managers (1Password, Bitwarden, etc.)
  are automatically NOT recorded.
* To keep it running after a restart, turn on "Launch at login" in
  Settings.
* There is no auto-update — to update, replace the app with a newer copy.
