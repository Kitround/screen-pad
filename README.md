<p align="center"><img src=".github/icon.png" width="128" height="128" alt=""></p>
<h1 align="center">Screen Pad</h1>
<p align="center">Turn an old iPad into an extra display for your Mac, over USB.</p>

Screen Pad gives the first iPads, from the iPad 2 and the first iPad mini on, a second life as a Mac display:

- **On the Mac**, a menu bar app creates a virtual display and streams it to the iPad as H.264 video.
- **On the iPad**, a free app shows it, and switches the backlight off while the Mac's displays sleep. It needs a jailbreak; if you'd rather not, the paid [Yam Display](https://apps.apple.com/us/app/yam-display/id1024395134) app from the App Store works too.

## Requirements

- A Mac with macOS 14 or later, and a USB cable.
- For the free iPad app: an iPad 2, iPad 3, iPad mini 1 or iPad 4 on iOS 9.
- On iOS 7.1 or 8, on a newer iPad, or without a jailbreak: the paid Yam Display app (iOS 7.1 or later).

Tested on an iPad mini 1 with iOS 9.3.5, with both iPad apps (Yam Display 2.2).

## Install

### Mac

1. Download `screenpad-mac.zip` from the [latest release](https://github.com/Kitround/screenpad/releases/latest), unzip it and move **Screen Pad** to Applications.
2. Open it. The first time, macOS blocks it because it isn't notarized: open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**. Screen Pad lives in the menu bar.
3. The first time an iPad connects, macOS asks to let Screen Pad record the screen: turn it on in **System Settings › Privacy & Security › Screen Recording**, then quit and reopen Screen Pad from its menu bar icon.

### iPad, option 1: free app (jailbreak)

The jailbreak runs in Safari, without a computer; it's at your own risk.

1. In Safari on the iPad, open `http://carbon.sep.lol` and tap **Run**. It often takes a few tries: if Safari reloads the page, or if the iPad restarts and Cydia isn't on the home screen, try again.
2. On iOS 9.3.5 or 9.3.6, open Cydia, search for **iocaste untether** and install it, so the jailbreak survives a restart. Don't leave Cydia until it's done.
3. In Cydia, tap **Sources › Edit › Add**, enter `https://kitround.github.io/screenpad/`, then install **Screen Pad**.

More on the jailbreak: [Carbon guide](https://ios.cfw.guide/using-carbon).

### iPad, option 2: Yam Display (paid, no jailbreak)

Buy [Yam Display](https://apps.apple.com/us/app/yam-display/id1024395134) on the App Store and use it instead of the free app. You don't need Yam's own Mac app: don't run it alongside Screen Pad.

## Use

Plug the iPad into the Mac and open Screen Pad (or Yam Display) on the iPad. It shows up in **System Settings › Displays**, where you can arrange it. From the menu bar icon:

- **Display Size**: the iPad's own size, or a larger desktop drawn smaller.
- **Smoothing**: draws at 2× then scales down, for sharper text. On by default.
- **Touch**: taps and drags on the iPad control the Mac's pointer (macOS asks for Accessibility access). Off by default: it's a display, not a tablet.
- **Open at Login**.

## Build from source

- Mac app: `make install` (needs the Xcode Command Line Tools).
- iPad app: `make deb` builds the Cydia package (needs Xcode; downloads the iOS 9.3 SDK from [theos/sdks](https://github.com/theos/sdks)). `make ipad-install` installs it over SSH through USB, with OpenSSH on the iPad and `iproxy 2222:22` running on the Mac.

## License

[MIT](LICENSE). Screen Pad isn't affiliated with Yam Display; it speaks the same protocol for interoperability.
