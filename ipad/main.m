// ScreenPad — iPad side: open-source stand-in for the Yam Display iPad app (iPad mini 1, iOS 9, armv7 and up).
// Speaks the Yam Display protocol, so the Mac app in mac/ serves this app and Yam alike (wire format at the top of
// mac/main.swift). Listens on localhost:23471, reached from the Mac through usbmuxd, shows the H.264 stream with
// AVSampleBufferDisplayLayer (hardware decode) and sends taps and drags back (used when the Mac's "Touch" is on).
// Beyond Yam: while the Mac's screens sleep it sends "screenOff" (only to this app, recognized by "screenPadVersion"
// in the hello: Yam 2.2 shows its white waiting screen) and the backlight goes down until "screenOn": brightness 0,
// and fully off on a jailbroken iPad with the ScreenPad Backlight tweak (ipad/backlight.m) in SpringBoard.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#include <arpa/inet.h>
#include <notify.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <unistd.h>

#define PORT 23471  // Yam's

static BOOL readAll(int fd, void *buffer, size_t count) {
    uint8_t *p = buffer;
    while (count > 0) {
        ssize_t n = read(fd, p, count);
        if (n <= 0) return NO;
        p += n;
        count -= n;
    }
    return YES;
}

static BOOL writeAll(int fd, const void *buffer, size_t count) {
    const uint8_t *p = buffer;
    while (count > 0) {
        ssize_t n = write(fd, p, count);
        if (n <= 0) return NO;
        p += n;
        count -= n;
    }
    return YES;
}

@interface ScreenView : UIView
@end

@implementation ScreenView
+ (Class)layerClass { return [AVSampleBufferDisplayLayer class]; }
@end

@interface ViewController : UIViewController
@end

@implementation ViewController {
    AVSampleBufferDisplayLayer *_layer;
    UILabel *_waiting;
    NSData *_hello;
    int _fd;                              // @synchronized (self)
    CMVideoFormatDescriptionRef _format;  // reader thread only
    BOOL _macAsleep;                      // main thread only: the Mac sent screenOff
    CGFloat _brightness;                  // main thread only: the user's while we hold it at 0, else -1
    CFAbsoluteTime _keyframeAsked;        // main thread only
}

- (void)loadView {
    UIView *view = [ScreenView new];
    view.backgroundColor = [UIColor blackColor];
    _layer = (AVSampleBufferDisplayLayer *)view.layer;
    _waiting = [[UILabel alloc] initWithFrame:view.bounds];
    _waiting.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    BOOL french = [[NSLocale preferredLanguages].firstObject hasPrefix:@"fr"];
    _waiting.text = french ? @"ScreenPad\n\nBranchez l’iPad au Mac avec le câble USB\net ouvrez ScreenPad sur le Mac."
                           : @"ScreenPad\n\nConnect the iPad to the Mac with a USB cable\nand open ScreenPad on the Mac.";
    _waiting.textColor = [UIColor grayColor];
    _waiting.backgroundColor = [UIColor blackColor];  // covers the last picture, which iOS 9 keeps after a flush
    _waiting.textAlignment = NSTextAlignmentCenter;
    _waiting.numberOfLines = 0;
    [view addSubview:_waiting];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    UITapGestureRecognizer *twoFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    twoFingerTap.numberOfTouchesRequired = 2;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.maximumNumberOfTouches = 1;
    for (UIGestureRecognizer *recognizer in @[tap, twoFingerTap, pan]) [view addGestureRecognizer:recognizer];
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _fd = -1;
    _brightness = -1;
    struct utsname system;
    uname(&system);
    CGSize size = [UIScreen mainScreen].bounds.size;
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    // Yam's hello (frame 100): the Mac picks sizes from the model and the landscape screen in pixels.
    _hello = [NSPropertyListSerialization dataWithPropertyList:@{
        @"hardwareString": @(system.machine), @"protocolVersion": @"1.0.20", @"screenPadVersion": version,
        @"viewSize": @{@"Width": @((int)MAX(size.width, size.height)), @"Height": @((int)MIN(size.width, size.height))},
        @"screenScale": @((int)[UIScreen mainScreen].scale)} format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(foreground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [NSThread detachNewThreadSelector:@selector(serve) toTarget:self withObject:nil];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

#pragma mark - Backlight and app state (main thread)

- (void)setDimmed:(BOOL)dimmed {
    UIScreen *screen = [UIScreen mainScreen];
    if (dimmed && _brightness < 0) {
        _brightness = screen.brightness;
        screen.brightness = 0;
        notify_post("fr.krnd.screenpad.backlight.off");  // the tweak, if installed
    } else if (!dimmed && _brightness >= 0) {
        notify_post("fr.krnd.screenpad.backlight.on");
        screen.brightness = _brightness;
        _brightness = -1;
    }
}

- (void)background {
    [self sendEvent:@{@"eventName": @"DeviceBackground"}];  // the Mac stops the video
    [self setDimmed:NO];  // never leave the iPad dark outside the app
}

- (void)foreground {
    [self sendEvent:@{@"eventName": @"DeviceForeground"}];  // the Mac resumes with a keyframe
    [self setDimmed:_macAsleep];
}

#pragma mark - Touch (Yam's events, x and y as fractions of the screen)

- (CGPoint)fraction:(CGPoint)point {
    // ponytail: fractions of the view, not of the picture; equal while the video has the iPad's aspect ratio.
    CGSize size = self.view.bounds.size;
    return CGPointMake(MAX(0, MIN(1, point.x / size.width)), MAX(0, MIN(1, point.y / size.height)));
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    CGPoint p = [self fraction:[tap locationInView:self.view]];
    NSString *name = tap.numberOfTouchesRequired == 2 ? @"TwoFingerSingleTap" : @"SingleTap";
    [self sendEvent:@{@"eventName": name, @"x": @(p.x), @"y": @(p.y)}];
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    CGPoint p = [pan locationInView:self.view];
    if (pan.state == UIGestureRecognizerStateBegan) {  // recognized after some movement: press where the finger landed
        CGPoint moved = [pan translationInView:self.view];
        p = CGPointMake(p.x - moved.x, p.y - moved.y);
    }
    p = [self fraction:p];
    NSMutableDictionary *event = [@{@"eventName": @"Dragged", @"x": @(p.x), @"y": @(p.y)} mutableCopy];
    if (pan.state == UIGestureRecognizerStateBegan) event[@"startOfDrag"] = @YES;
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) event[@"endOfDrag"] = @YES;
    [self sendEvent:event];
}

#pragma mark - Connection

// PeerTalk frame: [u32 version 1][u32 type][u32 tag][u32 payload size], big-endian, then the payload.
- (void)send:(uint32_t)type payload:(NSData *)payload {
    uint32_t header[4] = {htonl(1), htonl(type), 0, htonl((uint32_t)payload.length)};
    @synchronized (self) {
        if (_fd < 0) return;
        if (!writeAll(_fd, header, sizeof header) || !writeAll(_fd, payload.bytes, payload.length)) shutdown(_fd, SHUT_RDWR);
    }
}

- (void)sendEvent:(NSDictionary *)event {
    [self send:104 payload:[NSPropertyListSerialization dataWithPropertyList:event format:NSPropertyListBinaryFormat_v1_0
                                                                      options:0 error:NULL]];
}

- (void)serve {
    int yes = 1;
    for (;;) {
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
        struct sockaddr_in address = {0};
        address.sin_len = sizeof address;
        address.sin_family = AF_INET;
        address.sin_port = htons(PORT);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listener, (struct sockaddr *)&address, sizeof address) < 0 || listen(listener, 1) < 0) {
            close(listener);  // Yam still holding the port, for one
            sleep(1);
            continue;
        }
        int fd;
        while ((fd = accept(listener, NULL, NULL)) >= 0) {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes);
            if (_format) CFRelease(_format);
            _format = NULL;
            @synchronized (self) { _fd = fd; }
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_waiting.hidden = YES;
                self->_macAsleep = NO;  // a new Mac session says it again if its screens sleep
                [self setDimmed:NO];
            });
            [self send:100 payload:_hello];
            [self readFrom:fd];
            @synchronized (self) { _fd = -1; }
            close(fd);
            // Stays dark if the Mac went to sleep: the link drops then, and leaving the app brings the light back.
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_layer flushAndRemoveImage];
                self->_waiting.hidden = NO;
            });
        }
        close(listener);  // accept fails after the app was suspended: rebuild the listener
    }
}

- (void)readFrom:(int)fd {
    uint32_t header[4];
    while (readAll(fd, header, sizeof header)) {
        uint32_t type = ntohl(header[1]), length = ntohl(header[3]);
        if (length > (16 << 20)) return;
        uint8_t *body = malloc(length + 1);
        if (!readAll(fd, body, length)) { free(body); return; }
        if (type == 107) {
            [self enqueueYamFrame:body length:length];  // takes ownership of body
            continue;
        }
        if (type == 101) [self handleText:body length:length];
        free(body);
    }
}

// Frame 101: [u32 big-endian length][UTF-8].
- (void)handleText:(const uint8_t *)body length:(size_t)length {
    uint32_t count;
    if (length < 4) return;
    memcpy(&count, body, 4);
    count = ntohl(count);
    if (count > length - 4) return;
    NSString *text = [[NSString alloc] initWithBytes:body + 4 length:count encoding:NSUTF8StringEncoding];
    if ([text hasPrefix:@"size:"]) {  // new video size: drop the old picture and ask for the stream again
        dispatch_async(dispatch_get_main_queue(), ^{ [self->_layer flush]; });
        [self sendEvent:@{@"eventName": @"ReadyToReceive"}];
    } else if ([text isEqualToString:@"screenOff"] || [text isEqualToString:@"screenOn"]) {
        BOOL asleep = [text isEqualToString:@"screenOff"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_macAsleep = asleep;
            [self setDimmed:asleep];
        });
    }  // "Version:...", "startStream:0": nothing to do
}

// Frame 107 (Encoder.yamPayload on the Mac): [u32 LE size][u32 LE 1], then chunks 00 00 00 01 + marker + bytes:
// 0x27 SPS and 0x28 PPS (raw NAL units, so the next start code ends them), then 0x25 keyframe or 0x21 frame,
// AVCC data up to the end.
- (void)enqueueYamFrame:(uint8_t *)body length:(size_t)length {
    static const uint8_t start[4] = {0, 0, 0, 1};
    const uint8_t *sets[2] = {NULL, NULL};
    size_t sizes[2] = {0, 0};
    size_t i = 8;
    while (i + 5 <= length && memcmp(body + i, start, 4) == 0) {
        uint8_t marker = body[i + 4];
        i += 5;
        if (marker == 0x25 || marker == 0x21) {
            if (sets[0] && sets[1]) [self setParameterSets:sets sizes:sizes];
            [self enqueueFrame:body offset:i length:length];
            return;
        }
        size_t end = i;
        while (end + 4 <= length && memcmp(body + end, start, 4) != 0) end++;
        if (end + 4 > length) end = length;
        if (marker == 0x27 || marker == 0x28) {
            sets[marker - 0x27] = body + i;
            sizes[marker - 0x27] = end - i;
        }
        i = end;
    }
    free(body);
}

- (void)setParameterSets:(const uint8_t **)sets sizes:(size_t *)sizes {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &format) != noErr) return;
    if (_format && CMFormatDescriptionEqual(format, _format)) {  // same stream: keep the layer's format
        CFRelease(format);
        return;
    }
    if (_format) CFRelease(_format);
    _format = format;
}

// The AVCC frame is body[offset..<length]; the block buffer frees body.
- (void)enqueueFrame:(uint8_t *)body offset:(size_t)offset length:(size_t)length {
    if (!_format) { free(body); return; }
    CMBlockBufferRef block = NULL;
    size_t size = length - offset;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, body, length, kCFAllocatorMalloc, NULL, offset, size, 0, &block)
        != kCMBlockBufferNoErr) {
        free(body);
        return;
    }
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreate(NULL, block, true, NULL, NULL, _format, 1, 0, NULL, 1, &size, &sample);
    CFRelease(block);
    if (status != noErr) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                         kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    AVSampleBufferDisplayLayer *layer = _layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [layer flush];
            // The decoder starts over from a keyframe, which the Mac only sends every 120 frames or when asked:
            // ReadyToReceive makes it send one now. ponytail: once a second at most, so a stream the decoder
            // never takes can't turn into a keyframe loop.
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - self->_keyframeAsked > 1) {
                self->_keyframeAsked = now;
                [self sendEvent:@{@"eventName": @"ReadyToReceive"}];
            }
        }
        [layer enqueueSampleBuffer:sample];
        CFRelease(sample);
    });
}

@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [ViewController new];
    [self.window makeKeyAndVisible];
    application.idleTimerDisabled = YES;  // it's a monitor: never auto-lock
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
