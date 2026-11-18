# CopyBar

A tiny macOS menu bar app that keeps an eye on Finder copies.

Finder's copy progress window is easy to lose behind other windows. CopyBar shows the
progress in the menu bar, notifies you when a copy ends, and keeps a history of past copies
that you can undo.

> **Status: early.** Built and tested on macOS 27 (Apple Silicon) with Finder in French.
> The menus are in French only for now. No signed download yet: you build it yourself.

## Features

- **Progress in the menu bar**: percentage while a copy runs, with a counter when several run at once.
- **Notification** when a copy ends, telling finished from interrupted.
- **Bring the progress window back** to the front from the menu.
- **History** of the last 50 copies: what was copied, from where, to where, size, file count, duration, speed.
- **Undo**: a copy goes to the Trash (originals untouched), a move is put back where it came from.
  Always asks first, and only offered when the original was positively identified.

## Install

Requires macOS 13 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/alnilam-404/copybar.git
cd copybar
./build.sh
open CopyBar.app
```

On first launch, grant two permissions:

1. **Accessibility** (System Settings › Privacy & Security › Accessibility). Required: this is how CopyBar reads Finder's progress window.
2. **Notifications**, optional.

A locally built app is ad hoc signed, so macOS asks for Accessibility again after each rebuild.

## How it works

Finder has no API for copy progress. CopyBar reads Finder's progress window through the
accessibility API once per second. For the history, it finds the real paths on disk: Finder
stamps every item being copied with a creation date of January 24, 1984, and its windows
expose the folders they display.

All of this relies on **undocumented Finder behaviour** that Apple can change in any macOS
release. Expect breakage; reports are welcome.

## Limitations

- Copies shorter than 2–3 seconds never show a progress window, so they are not seen.
- Paths are only found when the destination folder is visible in a Finder window (or is the Desktop, a volume, or a standard home folder).
- On network volumes, small items of a multi-item copy can be missing from the history entry.
- Not tested on Intel Macs, other macOS versions, or other Finder languages.
- Cannot be distributed on the Mac App Store (it needs to read another app's interface).

## Development

Single Swift file, AppKit, no Xcode project. `build.sh` compiles and signs; `outils/` holds
small accessibility probes used for testing. Detailed design notes, pitfalls and test
procedures are in [docs/NOTES.fr.md](docs/NOTES.fr.md) (French).

## License

[MIT](LICENSE)
