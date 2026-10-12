# Screen Pad: an iPad as an extra display for the Mac, over USB.
#   make install       Mac app: build, copy to /Applications and open it
#   make run           Mac app: run it here, logs in the terminal
#   make deb           iPad app + backlight tweak as a Cydia package, and the Cydia source in build/ipad/repo
#   make ipad-install  install that package on a jailbroken iPad over SSH through USB, then restart SpringBoard
#   make release       Mac app zip and iPad package in build/release

-include local.mk  # optional, untracked: SIGN, IPAD_SSH

# A stable identity ("Apple Development: …") keeps the Screen Recording permission across rebuilds; ad hoc loses it.
SIGN    ?= -
APP     := build/Screen Pad.app
VERSION := $(shell plutil -extract CFBundleShortVersionString raw mac/Info.plist)

.PHONY: app run install clean ipad deb ipad-install release

app: build/AppIcon.icns
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	for arch in arm64 x86_64; do \
		swiftc -swift-version 5 -O -target $$arch-apple-macos14.0 -import-objc-header mac/CGVirtualDisplay.h \
			mac/main.swift -o build/screenpad-$$arch || exit 1; \
	done
	lipo -create build/screenpad-arm64 build/screenpad-x86_64 -output "$(APP)/Contents/MacOS/Screen Pad"
	cp mac/Info.plist "$(APP)/Contents/"
	cp build/AppIcon.icns build/icons/MenuBarIcon.png build/icons/MenuBarIcon@2x.png "$(APP)/Contents/Resources/"
	codesign -f -s "$(SIGN)" "$(APP)"

build/AppIcon.icns: mac/icon.swift
	rm -rf build/icons && mkdir -p build/icons
	swift mac/icon.swift build/icons
	iconutil -c icns build/icons/AppIcon.iconset -o $@

run: app
	"$(APP)/Contents/MacOS/Screen Pad"

install: app
	-pkill -x "Screen Pad"
	rm -rf "/Applications/Screen Pad.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/Screen Pad.app"

clean:
	rm -rf build

# --- iPad (ipad/): jailbroken iPad, iOS 9, armv7. Xcode 26 can no longer link armv7, so this uses the iOS 9.3 SDK
# from theos/sdks with Xcode's clang called directly.

XCODE    := /Applications/Xcode.app/Contents/Developer
CLANG    := $(XCODE)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang
SDK9     := build/sdks/iPhoneOS9.3.sdk
IPAD_APP := build/ipad/ScreenPad.app
TWEAK    := build/ipad/ScreenPadBacklight.dylib
IOS      := -target armv7-apple-ios9.0 -isysroot $(SDK9) -O2
# Through `iproxy 2222:22` (libimobiledevice). The iPad's OpenSSH 6.7 only offers ssh-rsa host keys.
IPAD_SSH ?= ssh -p 2222 -o HostKeyAlgorithms=+ssh-rsa root@127.0.0.1

$(SDK9):
	mkdir -p build/sdks
	curl -fL https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS9.3.sdk.tar.xz | tar -xJ -C build/sdks
	# theos strips liblaunch.tbd but libSystem re-exports it; an empty stub satisfies ld.
	printf -- '---\narchs: [ armv7, armv7s, arm64 ]\nplatform: ios\ninstall-name: /usr/lib/system/liblaunch.dylib\ncurrent-version: 765.1.8\ncompatibility-version: 1\n...\n' \
		> $(SDK9)/usr/lib/system/liblaunch.tbd

ipad: $(IPAD_APP)/ScreenPad

$(IPAD_APP)/ScreenPad: ipad/main.m ipad/Info.plist build/AppIcon.icns | $(SDK9)
	mkdir -p $(IPAD_APP)
	$(CLANG) $(IOS) -fobjc-arc -framework Foundation -framework UIKit -framework AVFoundation -framework CoreMedia \
		ipad/main.m -o $@ 2>&1 | grep -v "but linking in .tbd file\|libclang_rt.ios.a" || true
	test -f $@
	cp ipad/Info.plist build/icons/AppIcon76x76*.png build/icons/AppIcon83.5x83.5*.png $(IPAD_APP)/
	codesign -f -s - $(IPAD_APP)

# Screen Pad Backlight, loaded into SpringBoard: only SpringBoard may switch the backlight off.
$(TWEAK): ipad/backlight.m | $(SDK9)
	mkdir -p build/ipad
	$(CLANG) $(IOS) -dynamiclib -framework Foundation -F$(SDK9)/System/Library/PrivateFrameworks \
		-framework BackBoardServices ipad/backlight.m -o $@ 2>&1 | grep -v "but linking in .tbd file\|libclang_rt.ios.a" || true
	test -f $@
	codesign -f -s - $@

deb: ipad $(TWEAK)
	python3 -I ipad/package.py $(IPAD_APP) $(TWEAK) build/icons/AppIcon76x76@2x.png build/ipad/repo

ipad-install: deb
	cat build/ipad/repo/debs/screenpad_*.deb | $(IPAD_SSH) \
		'cat > /tmp/screenpad.deb && dpkg -i /tmp/screenpad.deb && rm /tmp/screenpad.deb && killall -9 SpringBoard'

release: deb
	$(MAKE) app SIGN=-  # ad hoc: a personal "Apple Development" certificate would carry its owner's name
	rm -rf build/release && mkdir -p build/release
	ditto -c -k --keepParent "$(APP)" "build/release/screenpad-$(VERSION)-mac.zip"
	cp build/ipad/repo/debs/*.deb build/release/
