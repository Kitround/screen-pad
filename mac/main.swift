// Screen Pad — Mac side: a menu bar app that turns a USB-connected iPad into an extra display.
// Virtual display -> ScreenCaptureKit -> H.264 (VideoToolbox) -> usbmuxd tunnel -> iPad app.
// The iPad app is our own (ipad/main.m) or Yam Display from the App Store: both speak the protocol below.
// The virtual display, capture and encoder only exist while an iPad is connected (see Session).
// Display only by default; with "Touch" (or --touch), taps and drags on the iPad become mouse events.
//
// Protocol, as observed for interoperability with Yam Display 2.x:
// PeerTalk frames, header [u32 version = 1][u32 type][u32 tag][u32 payload size], all big-endian.
//   100 iPad->Mac  device info, plist dictionary (hardwareString, protocolVersion, ...)
//   101 Mac->iPad  text message: [u32 big-endian length][UTF-8], e.g. "Version:... Protocol:1.0.20 H264:1"
//   104 iPad->Mac  event, plist dictionary with "eventName" (ReadyToReceive, DeviceBackground, SingleTap, ...);
//                  x and y are fractions of the screen, origin top-left
//   107 Mac->iPad  H.264 frame, tag 100 on keyframes, see Encoder.yamPayload
// Handshake: iPad 100 -> Mac "Version:..." and "size:WxH" (video size) -> iPad ReadyToReceive -> Mac "startStream:0".
import ApplicationServices
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import ServiceManagement
import VideoToolbox

let devicePort: UInt16 = 23471  // where the iPad app listens
/// English by default, French when it comes first in the user's languages.
let prefersFrench = Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
func tr(_ english: String, _ french: String) -> String { prefersFrench ? french : english }
// ponytail: unsynchronized Bool, written on main, read on the link thread; a stale read only drops one touch.
var touchEnabled = UserDefaults.standard.bool(forKey: "touch") || CommandLine.arguments.contains("--touch")
// Supersampling (HiDPI backing downscaled by the capture) unless the user turned it off.
var smoothing = UserDefaults.standard.object(forKey: "smoothing") as? Bool ?? true

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n <= 0 { throw Failure("write failed") }
            offset += n
        }
    }
}

func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
            if n <= 0 { throw Failure("connection closed") }
            offset += n
        }
    }
    return data
}

// MARK: - usbmuxd (as PeerTalk uses it)

enum USBMux {
    private static func open() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            _ = "/var/run/usbmuxd".withCString { strcpy(path.baseAddress!.assumingMemoryBound(to: CChar.self), $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw Failure(tr("macOS USB service unreachable", "Service USB de macOS injoignable")) }
        return fd
    }

    private static func send(_ fd: Int32, _ message: [String: Any]) throws {
        var message = message
        message["ProgName"] = "ScreenPad"
        message["ClientVersionString"] = "ScreenPad"
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        // Header: length, version 1, type 8 (plist), tag — all little-endian.
        let header = [UInt32(16 + body.count), 1, 8, 1].flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } }
        try writeAll(fd, Data(header) + body)
    }

    private static func receive(_ fd: Int32) throws -> [String: Any] {
        let header = try readExactly(fd, 16)
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let body = try readExactly(fd, Int(length) - 16)
        return try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] ?? [:]
    }

    /// Returns a socket tunnelled to `port` on the first iOS device attached over USB.
    static func connect(port: UInt16) throws -> Int32 {
        let listing = try open()
        defer { close(listing) }
        try send(listing, ["MessageType": "ListDevices"])
        let devices = try receive(listing)["DeviceList"] as? [[String: Any]] ?? []
        guard let deviceID = devices
            .compactMap({ $0["Properties"] as? [String: Any] })
            .first(where: { $0["ConnectionType"] as? String == "USB" })?["DeviceID"] as? Int
        else { throw Failure(tr("Connect the iPad with a USB cable", "Branche l’iPad en USB")) }

        let fd = try open()
        try send(fd, ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(port.bigEndian)])
        guard try receive(fd)["Number"] as? Int == 0 else {
            close(fd)
            throw Failure(tr("Open Screen Pad or Yam Display on the iPad", "Ouvre Screen Pad ou Yam Display sur l’iPad"))
        }
        return fd  // from here on the socket is a raw TCP stream to the iPad app
    }
}

// MARK: - Link to the iPad

final class Link {
    private let queue = DispatchQueue(label: "link")
    private var fd: Int32 = -1
    private let lock = NSLock()  // guards the three below, read from the capture queue
    private var streaming = false  // video only flows once the iPad sent ReadyToReceive
    private var pendingVideo = 0  // frames handed to `queue` but not written yet
    private var encoder: Encoder?
    /// Called on the link thread when an iPad says hello; returns the video size to announce, nil to hang up.
    var onHello: (_ info: [String: Any]) -> (width: Int, height: Int)? = { _ in nil }
    var onGoodbye: () -> Void = {}
    var onStatus: (_ text: String, _ active: Bool) -> Void = { _, _ in }

    func start() {
        Thread { self.run() }.start()
    }

    func setEncoder(_ encoder: Encoder?) { lock.withLock { self.encoder = encoder } }

    /// False while the iPad is not showing the stream or USB is behind: the encoder then skips frames whole,
    /// which keeps the H.264 stream decodable, and catches up with the latest one once the link drains.
    /// Also false for an encoder that is no longer the current one (replaced after sleep), so it stays silent.
    func wantsVideo(from encoder: Encoder) -> Bool {
        lock.withLock { streaming && pendingVideo < 2 && self.encoder === encoder }
    }

    private func run() {
        var lastStatus = ""
        while true {
            do {
                let socket = try USBMux.connect(port: devicePort)
                var one: Int32 = 1
                setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                queue.sync { fd = socket }
                lastStatus = "connected"
                onStatus(tr("iPad connected", "iPad connecté"), false)
                readInput(socket)  // blocks until the connection drops
                setStreaming(false, status: nil)
                onGoodbye()
            } catch {
                let status = "\(error)"
                if status != lastStatus { onStatus(status, false) }
                lastStatus = status
            }
            queue.sync {
                if fd >= 0 { close(fd) }
                fd = -1
            }
            sleep(1)
        }
    }

    func send(type: UInt32, tag: UInt32 = 0, _ payload: Data, video: Bool = false) {
        if video { lock.withLock { pendingVideo += 1 } }
        queue.async {
            if self.fd >= 0 {
                var message = Data()
                for word in [1, type, tag, UInt32(payload.count)] { withUnsafeBytes(of: word.bigEndian) { message.append(contentsOf: $0) } }
                message.append(payload)
                if (try? writeAll(self.fd, message)) == nil { shutdown(self.fd, SHUT_RDWR) }
            }
            guard video else { return }
            let encoder = self.lock.withLock { () -> Encoder? in
                self.pendingVideo -= 1
                return self.pendingVideo == 0 ? self.encoder : nil
            }
            if let encoder { captureQueue.async { encoder.catchUp() } }
        }
    }

    func sendText(_ text: String) {
        print("-> \(text)")
        let utf8 = Data(text.utf8)
        send(type: 101, withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { Data($0) } + utf8)
    }

    /// Announces a new video size; the iPad app reconfigures its decoder and answers ReadyToReceive again.
    func announce(width: Int, height: Int) {
        lock.withLock { streaming = false }
        sendText("size:\(width)x\(height)")
    }

    private func setStreaming(_ on: Bool, status: String?) {
        let encoder = lock.withLock { () -> Encoder? in
            streaming = on
            return self.encoder
        }
        if let status { onStatus(status, on) }
        if on, let encoder { captureQueue.async { encoder.restart() } }
    }

    private func readInput(_ fd: Int32) {
        while let header = try? readExactly(fd, 16) {
            let words = (0..<4).map { i in header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) } }
            guard words[3] < 1 << 24, let body = try? readExactly(fd, Int(words[3])) else { return }
            let plist = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any] ?? [:]
            switch words[1] {
            case 100:
                print("<- device info \(plist)")
                guard let size = onHello(plist) else { return }
                sendText("Version:2.4.8.4 OS:\(macOSVersion) Hardware:\(macModel) Protocol:1.0.20 H264:1")
                announce(width: size.width, height: size.height)
            case 104:
                handleEvent(plist)
            default:
                print("<- ignored frame type \(words[1]), \(body.count) bytes")
            }
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        let name = event["eventName"] as? String ?? ""
        let point = (event["x"] as? Double ?? 0, event["y"] as? Double ?? 0)
        switch name {
        case "SingleTap", "TwoFingerSingleTap", "Dragged", "Scrolled", "HoverEvent": break
        default: print("<- event \(event)")
        }
        switch name {
        case "ReadyToReceive":
            sendText("startStream:0")  // 0 = USB connection mode
            setStreaming(true, status: tr("iPad display active", "Écran iPad actif"))
        case "DeviceForeground": setStreaming(true, status: tr("iPad display active", "Écran iPad actif"))
        case "DeviceBackground", "DeviceLocked", "DeviceTerminate": setStreaming(false, status: tr("iPad asleep", "iPad en veille"))
        case "SingleTap" where touchEnabled: click(at: point, button: .left)
        case "TwoFingerSingleTap" where touchEnabled: click(at: point, button: .right)
        case "Dragged" where touchEnabled:
            let type: CGEventType = event["startOfDrag"] as? Bool == true ? .leftMouseDown
                : event["endOfDrag"] as? Bool == true ? .leftMouseUp : .leftMouseDragged
            postMouse(type, at: point)
        default:
            break  // ponytail: scroll, zoom and keyboard events unused on purpose (a display, not a tablet)
        }
    }
}

let macOSVersion: String = {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}()

let macModel: String = {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}()

// MARK: - iPad models

struct Size: Equatable {
    let width: Int, height: Int
    var name: String { "\(width) × \(height)" }
}

/// Desktop sizes offered per iPad family, landscape, in points (the first one is the iPad's own, the same choices
/// as Yam Display), plus the largest video the iPad can show.
struct Model {
    let family: String
    let sizes: [Size]
    private(set) var maxVideo: Size

    /// `info` is the iPad's hello (frame 100): hardwareString, plus viewSize and screenScale for its screen.
    init(info: [String: Any]) {
        let hardware = info["hardwareString"] as? String ?? ""
        func any(_ ids: String) -> Bool { ids.split(separator: " ").contains { $0 == hardware } }
        let fourThree = [Size(width: 1024, height: 768), Size(width: 1366, height: 1024),
                         Size(width: 1436, height: 1080), Size(width: 1916, height: 1436)]
        if any("iPad1,1 iPad2,1 iPad2,2 iPad2,3 iPad2,4 iPad2,5 iPad2,6 iPad2,7") {  // A5 decoder: 1024x768 video at most
            (family, sizes, maxVideo) = ("iPad2", [fourThree[0], Size(width: 2048, height: 1536)], fourThree[0])
        } else if any("iPad6,7 iPad6,8 iPad7,1 iPad7,2 iPad7,3 iPad7,4 iPad11,3 iPad11,4 iPad8,5 iPad8,6 iPad8,7 iPad8,8 "
                      + "iPad8,11 iPad8,12 iPad13,8 iPad13,9 iPad13,10 iPad13,11 iPad14,5 iPad14,6 iPad14,10 iPad14,11 "
                      + "iPad16,5 iPad16,6 iPad15,5 iPad15,6 iPad17,3 iPad17,4 iPad16,10 iPad16,11") {
            (family, sizes, maxVideo) = ("iPadPro", fourThree, Size(width: 2732, height: 2048))
        } else if any("iPad14,1 iPad14,2 iPad16,1 iPad16,2") {
            (family, sizes, maxVideo) = ("iPadMini6G", [Size(width: 1133, height: 744), Size(width: 1510, height: 992),
                                                       Size(width: 2266, height: 1488), Size(width: 2732, height: 1794)],
                                         Size(width: 2266, height: 1488))
        } else if any("iPad16,3 iPad16,4 iPad17,1 iPad17,2") {
            (family, sizes, maxVideo) = ("iPad11M4", [Size(width: 1210, height: 834), Size(width: 1613, height: 1112),
                                                     Size(width: 2420, height: 1668), Size(width: 2768, height: 1908)],
                                         Size(width: 2420, height: 1668))
        } else if any("iPad8,1 iPad8,2 iPad8,3 iPad8,4 iPad8,9 iPad8,10 iPad13,1 iPad13,2 iPad13,4 iPad13,5 iPad13,6 "
                      + "iPad13,7 iPad13,16 iPad13,17 iPad13,18 iPad13,19 iPad14,3 iPad14,4 iPad14,8 iPad14,9 iPad15,3 "
                      + "iPad15,4 iPad15,7 iPad15,8 iPad16,8 iPad16,9") {
            (family, sizes, maxVideo) = ("iPadPro11", [Size(width: 1194, height: 834), Size(width: 1592, height: 1112),
                                                      Size(width: 2388, height: 1668), Size(width: 2732, height: 1908)],
                                         Size(width: 2388, height: 1668))
        } else if hardware.hasPrefix("iPad3,") {
            // A5X/A6X: H.264 decoding tops out below the Retina size (Yam sends JPEG there); we cap the video.
            (family, sizes, maxVideo) = ("iPad", fourThree, Size(width: 1600, height: 1200))
        } else {
            (family, sizes, maxVideo) = ("iPad", fourThree, Size(width: 2048, height: 1536))
        }
        // Prefer the screen the iPad reports, landscape, still under the A5X/A6X H.264 cap above.
        if let view = info["viewSize"] as? [String: Any], let w = view["Width"] as? Int, let h = view["Height"] as? Int,
           let scale = info["screenScale"] as? Int, w > 0, h > 0 {
            let screen = Size(width: max(w, h) * scale, height: min(w, h) * scale)
            if !hardware.hasPrefix("iPad3,") || screen.width < maxVideo.width { maxVideo = screen }
        }
    }

    /// The size picked in the menu for this family, the iPad's own by default.
    var selected: Size {
        let saved = UserDefaults.standard.string(forKey: "size." + family)
        return sizes.first { $0.name == saved } ?? sizes[0]
    }

    /// The video sent to the iPad: the desktop's pixels, shrunk to what the iPad shows.
    func video(for size: Size, smoothing: Bool) -> Size {
        let scale = min(1, Double(maxVideo.width) / Double(size.width * (smoothing ? 2 : 1)))
        let pixels = Double(size.width * (smoothing ? 2 : 1)) * scale
        let even = { (x: Double) in Int(x / 2) * 2 }  // H.264 wants even dimensions
        return Size(width: even(pixels), height: even(pixels * Double(size.height) / Double(size.width)))
    }
}

// MARK: - Touch input -> mouse

// ponytail: unsynchronized, written on main, read on the link thread; a stale read only misplaces one touch.
var activeDisplayID: CGDirectDisplayID = 0
var screensAsleep = false  // main thread only

func postMouse(_ type: CGEventType, at point: (Double, Double), button: CGMouseButton = .left) {
    let bounds = CGDisplayBounds(activeDisplayID)
    let location = CGPoint(x: bounds.minX + point.0 * bounds.width, y: bounds.minY + point.1 * bounds.height)
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)?
        .post(tap: .cghidEventTap)
}

func click(at point: (Double, Double), button: CGMouseButton) {
    postMouse(button == .left ? .leftMouseDown : .rightMouseDown, at: point, button: button)
    postMouse(button == .left ? .leftMouseUp : .rightMouseUp, at: point, button: button)
}

// MARK: - H.264 encoder

final class Encoder {
    private var session: VTCompressionSession?  // nil after an error: rebuilt on the next frame
    private var failures = 0
    private let link: Link
    private var forceKeyframe = true
    private var lastFrame: CVPixelBuffer?  // re-sent on (re)start and after skips, so a static screen still shows up
    private var skipped = false
    private var blanked = false
    private let size: Size

    init(link: Link, size: Size) {
        self.link = link
        self.size = size
    }

    private func makeSession() -> VTCompressionSession? {
        var session: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                   codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return nil }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,  // A5 decodes up to High 4.1
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            // Headroom so edges stay sharp while things move; scaled with the picture, 16 Mb/s at 1024x768.
            kVTCompressionPropertyKey_AverageBitRate: max(16_000_000, size.width * size.height * 20),
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 120,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        return session
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    /// Call on `captureQueue` only. The hardware encoder can be invalidated across Mac sleep: start over with a
    /// fresh session and a keyframe, re-sending the current picture a few times so a static screen recovers too.
    private func fail(_ status: OSStatus) {
        print("\(Date()) encoder error \(status), new session")
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        forceKeyframe = true
        failures += 1
        if failures <= 3 { resend() }
    }

    /// Call on `captureQueue` only.
    func encode(_ frame: CVPixelBuffer, at time: CMTime) {
        lastFrame = frame
        if !blanked { send(frame, at: time) }
    }

    /// Call on `captureQueue` only: shows black instead of the desktop (Mac screens asleep), or the desktop again.
    func blank(_ on: Bool) {
        blanked = on
        restart()
    }

    /// Call on `captureQueue` only: the iPad (re)started showing the stream.
    func restart() {
        forceKeyframe = true
        resend()
    }

    /// Call on `captureQueue` only: the link drained, send the latest frame if one was skipped.
    func catchUp() {
        if skipped { resend() }
    }

    private func resend() {
        if let frame = blanked ? blackFrame : lastFrame { send(frame, at: CMClockGetTime(CMClockGetHostTimeClock())) }
    }

    private lazy var blackFrame: CVPixelBuffer? = {
        var black: CVPixelBuffer?
        CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &black)
        guard let black else { return nil }
        CVPixelBufferLockBaseAddress(black, [])
        for (plane, value) in [(0, 16), (1, 128)] {  // video-range black: Y 16, Cb/Cr 128
            memset(CVPixelBufferGetBaseAddressOfPlane(black, plane), Int32(value),
                   CVPixelBufferGetBytesPerRowOfPlane(black, plane) * CVPixelBufferGetHeightOfPlane(black, plane))
        }
        CVPixelBufferUnlockBaseAddress(black, [])
        return black
    }()

    private func send(_ frame: CVPixelBuffer, at time: CMTime) {
        skipped = !link.wantsVideo(from: self)
        guard !skipped else { return }
        if session == nil { session = makeSession() }
        guard let session else { return fail(kVTInvalidSessionErr) }
        let options = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: time, duration: .invalid,
            frameProperties: options, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return captureQueue.async { self.fail(status) } }
            captureQueue.async { self.failures = 0 }
            self.send(sample: sample)
        }
        if status != noErr { fail(status) }
    }

    private func send(sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var frame = Data(count: CMBlockBufferGetDataLength(block))
        frame.withUnsafeMutableBytes {
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        var chunks: [(marker: UInt8, bytes: Data)] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for (index, marker) in [(0, UInt8(0x27)), (1, UInt8(0x28))] {  // SPS, PPS
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard let pointer else { return }
                chunks.append((marker, Data(bytes: pointer, count: size)))
            }
        }
        chunks.append((isKeyframe ? 0x25 : 0x21, frame))
        link.send(type: 107, tag: isKeyframe ? 100 : 0, Encoder.yamPayload(chunks), video: true)
    }

    /// Frame layout: [u32 little-endian size of the rest][u32 little-endian 1], then for each
    /// chunk 00 00 00 01, a marker byte (0x27 SPS, 0x28 PPS, 0x25 keyframe, 0x21 frame) and the bytes as
    /// VideoToolbox gives them (parameter sets raw, frame data AVCC).
    static func yamPayload(_ chunks: [(marker: UInt8, bytes: Data)]) -> Data {
        var body = Data()
        for chunk in chunks {
            body.append(contentsOf: [0, 0, 0, 1, chunk.marker])
            body.append(chunk.bytes)
        }
        var payload = Data()
        for word in [UInt32(body.count), 1] { withUnsafeBytes(of: word.littleEndian) { payload.append(contentsOf: $0) } }
        return payload + body
    }
}

// MARK: - Capture

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let encoder: Encoder
    private var stream: SCStream?
    private var stopped = false  // main thread, like start and stop
    var onStop: () -> Void = {}

    init(encoder: Encoder) { self.encoder = encoder }

    func start(displayID: CGDirectDisplayID, size: Size) async throws {
        var display: SCDisplay?
        for _ in 0..<20 where display == nil {  // the new display takes a moment to reach ScreenCaptureKit
            display = try await SCShareableContent.current.displays.first { $0.displayID == displayID }
            if display == nil { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard let display else { throw Failure("virtual display not visible to ScreenCaptureKit") }

        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.queueDepth = 5
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        guard !stopped else { return try await stream.stopCapture() }  // stopped while starting
        self.stream = stream
    }

    func stop() {
        stopped = true
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("\(Date()) capture stopped: \(error)")
        DispatchQueue.main.async { self.onStop() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = sample.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete
        else { return }
        encoder.encode(frame, at: sample.presentationTimeStamp)
    }
}

// MARK: - Session

/// Everything that exists only while an iPad is connected. Main thread only.
final class Session {
    let model: Model
    let ownApp: Bool  // our open-source iPad app (ipad/) rather than Yam
    private let display: CGVirtualDisplay
    private var capture: Capture?
    private var encoder: Encoder?
    private(set) var video: Size

    init?(model: Model, ownApp: Bool) {
        let largest = model.sizes.max { $0.width < $1.width }!
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Screen Pad"
        descriptor.maxPixelsWide = UInt32(largest.width * 2)  // room for every size drawn at 2x (smoothing)
        descriptor.maxPixelsHigh = UInt32(largest.height * 2)
        descriptor.sizeInMillimeters = CGSize(width: 160, height: 120)
        descriptor.vendorID = 0x5350
        descriptor.productID = 1
        descriptor.serialNum = 1
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = model.sizes.map { CGVirtualDisplayMode(width: UInt32($0.width), height: UInt32($0.height), refreshRate: 60)! }
        guard let display = CGVirtualDisplay(descriptor: descriptor), display.applySettings(settings) else { return nil }
        self.model = model
        self.ownApp = ownApp
        self.display = display
        self.video = model.video(for: model.selected, smoothing: smoothing)
        activeDisplayID = display.displayID
    }

    /// Picks the menu's size, drawn at 2x (smoothing; hidden from the default mode list) or at 1x.
    /// Fails until the new display is online, as macOS starts it in its first mode.
    private func applyDisplayMode() -> Bool {
        let size = model.selected, scale = smoothing ? 2 : 1
        let modes = CGDisplayCopyAllDisplayModes(display.displayID,
                                                 [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
        guard let mode = (modes as? [CGDisplayMode])?
            .first(where: { $0.width == size.width && $0.pixelWidth == size.width * scale })
        else { return false }
        return CGDisplaySetDisplayMode(display.displayID, mode, nil) == .success
    }

    func start() {
        let encoder = Encoder(link: link, size: video)
        let capture = Capture(encoder: encoder)
        self.capture = capture
        self.encoder = encoder
        link.setEncoder(encoder)
        if screensAsleep { blank(true) }
        // ponytail: retries every second for as long as macOS keeps stopping the capture; no backoff.
        capture.onStop = { [weak self, weak capture] in
            guard let self, let capture, capture === self.capture else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restart(because: "capture stopped") }
        }
        Task { @MainActor in
            do {
                for _ in 0..<20 where !applyDisplayMode() { try await Task.sleep(nanoseconds: 250_000_000) }
                try await capture.start(displayID: display.displayID, size: video)
            } catch {
                print("\(error)")
                menuBar.show(tr("Allow Screen Recording, then reopen Screen Pad", "Autorise l’enregistrement de l’écran, puis relance Screen Pad"),
                             needsPermission: true)
            }
        }
    }

    /// Size or smoothing changed in the menu.
    func reconfigure() {
        let newVideo = model.video(for: model.selected, smoothing: smoothing)
        guard newVideo != video else { _ = applyDisplayMode(); return }
        stop()
        video = newVideo
        start()
        link.announce(width: video.width, height: video.height)
    }

    func stop() {
        link.setEncoder(nil)
        capture?.stop()
        capture = nil
        encoder = nil
    }

    /// Fresh capture and encoder on the same display and iPad connection, as quitting and reopening did:
    /// after Mac sleep the old ones can be dead (frozen or black picture while touches still work).
    func restart(because reason: String) {
        print("\(Date()) restarting capture: \(reason)")
        stop()
        start()
    }

    /// Black on the iPad while the Mac's screens sleep: Yam's "screenOff" would show its white waiting screen.
    /// Our own iPad app takes Yam's "screenOff"/"screenOn" to turn its backlight down and back up.
    func blank(_ on: Bool) {
        if ownApp { link.sendText(on ? "screenOff" : "screenOn") }
        guard let encoder else { return }
        captureQueue.async { encoder.blank(on) }
    }
}

// MARK: - Menu bar

final class MenuBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: tr("Starting…", "Démarrage…"), action: nil, keyEquivalent: "")
    private let sizeItem = NSMenuItem(title: tr("Display Size", "Taille d’affichage"), action: nil, keyEquivalent: "")
    private let touchItem = NSMenuItem(title: tr("Touch", "Tactile"), action: #selector(toggleTouch), keyEquivalent: "")
    private let smoothingItem = NSMenuItem(title: tr("Smoothing", "Lissage"), action: #selector(toggleSmoothing), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: tr("Open at Login", "Ouvrir à l’ouverture de session"), action: #selector(toggleLogin), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: tr("Allow Screen Recording…", "Autoriser l’enregistrement de l’écran…"),
                                            action: #selector(openScreenRecordingSettings), keyEquivalent: "")

    override init() {
        super.init()
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "Screen Pad"
        for menuItem in [touchItem, smoothingItem, loginItem, permissionItem] { menuItem.target = self }
        permissionItem.isHidden = true
        sizeItem.submenu = NSMenu()
        let menu = NSMenu()
        menu.items = [statusLine, .separator(), sizeItem, smoothingItem, touchItem, .separator(), loginItem,
                      permissionItem, .separator(),
                      NSMenuItem(title: tr("Quit Screen Pad", "Quitter Screen Pad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]
        item.menu = menu
        show(tr("Starting…", "Démarrage…"))
        refresh()
    }

    /// Call on the main queue.
    func show(_ status: String, active: Bool = false, needsPermission: Bool = false) {
        print(status)
        statusLine.title = status
        item.button?.appearsDisabled = !active
        permissionItem.isHidden = !needsPermission
    }

    /// Call on the main queue, also when the iPad comes or goes.
    func refresh() {
        touchItem.state = touchEnabled ? .on : .off
        smoothingItem.state = smoothing ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let submenu = sizeItem.submenu!
        submenu.removeAllItems()
        guard let model = session?.model else {
            submenu.addItem(NSMenuItem(title: tr("Connect an iPad", "Branche un iPad"), action: nil, keyEquivalent: ""))
            return
        }
        for (index, size) in model.sizes.enumerated() {
            let entry = NSMenuItem(title: size.name + (index == 0 ? tr(" (iPad size)", " (taille de l’iPad)") : ""),
                                   action: #selector(pickSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = size.name
            entry.state = size == model.selected ? .on : .off
            submenu.addItem(entry)
        }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let session else { return }
        UserDefaults.standard.set(sender.representedObject as? String, forKey: "size." + session.model.family)
        session.reconfigure()
        refresh()
    }

    @objc private func toggleSmoothing() {
        smoothing.toggle()
        UserDefaults.standard.set(smoothing, forKey: "smoothing")
        session?.reconfigure()
        refresh()
    }

    @objc private func toggleTouch() {
        touchEnabled.toggle()
        UserDefaults.standard.set(touchEnabled, forKey: "touch")
        if touchEnabled {  // mouse events need Accessibility; this shows macOS's prompt when it is missing
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        refresh()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            show(tr("Open at Login: ", "Ouverture de session : ") + error.localizedDescription)
        }
        refresh()
    }

    @objc private func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
if isatty(STDOUT_FILENO) == 0 {  // launched from Finder: keep a log of the last run
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let log = logs.appendingPathComponent("Screen Pad.log"), previous = logs.appendingPathComponent("Screen Pad.previous.log")
    try? FileManager.default.removeItem(at: previous)
    try? FileManager.default.moveItem(at: log, to: previous)  // a relaunch must not erase what went wrong
    freopen(log.path, "w", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon (LSUIElement does the same for the bundle)
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
    let alert = NSAlert()
    alert.messageText = tr("Screen Pad is already running", "Screen Pad tourne déjà")
    alert.informativeText = tr("Another copy of Screen Pad is open: its icon is in the menu bar.",
                               "Une autre copie de Screen Pad est ouverte : son icône est dans la barre des menus.")
    alert.runModal()
    exit(0)
}

// Layout check: size 6 = 5 framing bytes + 1 data byte.
precondition(Encoder.yamPayload([(0x21, Data([9]))]) == Data([6, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0x21, 9]))
// Model check: the iPad mini 1 gets 1024x768 video whatever the desktop size.
precondition(Model(info: ["hardwareString": "iPad2,5"]).video(for: Size(width: 2048, height: 1536), smoothing: true) == Size(width: 1024, height: 768))

let captureQueue = DispatchQueue(label: "capture")
let menuBar = MenuBar()
var session: Session?  // main thread only
let link = Link()
link.onStatus = { text, active in DispatchQueue.main.async { menuBar.show(text, active: active) } }
link.onHello = { info in
    DispatchQueue.main.sync {
        session?.stop()
        session = Session(model: Model(info: info), ownApp: info["screenPadVersion"] != nil)
        guard let session else {
            menuBar.show(tr("Couldn’t create the virtual display", "Impossible de créer l’écran virtuel"))
            return nil
        }
        print("\(info["hardwareString"] ?? "?"): family \(session.model.family), desktop \(session.model.selected.name), video \(session.video.name)")
        session.start()
        menuBar.refresh()
        return (session.video.width, session.video.height)
    }
}
link.onGoodbye = {
    DispatchQueue.main.async {
        session?.stop()
        session = nil  // releasing the CGVirtualDisplay removes the screen
        menuBar.refresh()
    }
}
// Mac screens asleep: black on the iPad. "screenOff" goes to our iPad app only: Yam Display 2.2 answers it with
// its white waiting screen.
let screens = NSWorkspace.shared.notificationCenter
screens.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
    screensAsleep = true
    session?.blank(true)
}
screens.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
    screensAsleep = false
    session?.blank(false)  // our iPad app's backlight back up; the restart below replaces the blanked encoder
    session?.restart(because: "screens woke")
}
screens.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    session?.restart(because: "Mac woke")
}
link.start()
app.run()
