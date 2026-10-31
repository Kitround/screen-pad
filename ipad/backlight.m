// ScreenPad Backlight — tweak loaded into SpringBoard by MobileSubstrate (jailbroken iPad only).
// At brightness 0 the LCD backlight stays on, and backboardd only lets the system app (SpringBoard) switch it off
// ("Only system apps can use _BKHIDXXSetBacklightFactorWithFadeDuration"), so the ScreenPad app asks us with a
// Darwin notification while the Mac's screens sleep, and again to bring the light back.
#import <Foundation/Foundation.h>
#include <notify.h>

void BKSHIDServicesSetBacklightFactorWithFadeDuration(float factor, int fadeDuration, bool silently);

// Any process can post the notification: only switch off for the ScreenPad app in front.
static BOOL screenPadInFront(void) {
    id springBoard = [NSClassFromString(@"UIApplication") performSelector:@selector(sharedApplication)];
    SEL front = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    if (![springBoard respondsToSelector:front]) return YES;  // ponytail: unknown SpringBoard, trust the caller
    id app = [springBoard performSelector:front];
    return [[app performSelector:@selector(bundleIdentifier)] isEqual:@"fr.krnd.screenpad"];
}

__attribute__((constructor)) static void start(void) {
    int token;
    notify_register_dispatch("fr.krnd.screenpad.backlight.off", &token, dispatch_get_main_queue(), ^(int t) {
        if (screenPadInFront()) BKSHIDServicesSetBacklightFactorWithFadeDuration(0, 0, false);
    });
    notify_register_dispatch("fr.krnd.screenpad.backlight.on", &token, dispatch_get_main_queue(), ^(int t) {
        BKSHIDServicesSetBacklightFactorWithFadeDuration(1, 0, false);
    });
}
