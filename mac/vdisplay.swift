// vdisplay - turns the V831 touch screen into an extended macOS display.
//
// Creates a 1600x600 virtual display (private CGVirtualDisplay API), captures it
// with ScreenCaptureKit, and sends changed regions to the device's vdclient over
// TCP (protocol documented in device/vdclient.c). The device dials in, over
// USB-NCM (the Mac gets 169.254.100.2 from the device's DHCP) or WiFi.
// (Outbound connections from unsigned tools to the LAN are blocked by macOS
// Local Network privacy, so the Mac only listens.) Touch contacts coming back are
// turned into mouse clicks, drags, right-clicks and scrolls on that display.
//
// The display only exists while a device is connected (plus VD_LINGER seconds,
// default 60, to ride out a USB->WiFi switch or a device reboot): with nothing
// plugged in there is no invisible screen for windows or the Dock to land on.
// After that the process exits and run_vdisplay.sh starts a fresh, display-less
// one that waits for the next connection.
//
// Needs Screen Recording (capture) and Accessibility (event injection) for the
// app that launches it.

import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import IOKit.pwr_mgt
import ScreenCaptureKit
import UniformTypeIdentifiers

let width = 1600, height = 600
let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["VD_PORT"] ?? "") ?? 9100
let jpegQuality = Double(ProcessInfo.processInfo.environment["VD_QUALITY"] ?? "") ?? 0.8
let debugScroll = ProcessInfo.processInfo.environment["VD_DEBUG"] != nil
let rawMaxPixels = 64 * 64 * 4   // rects up to this many pixels go uncompressed
// Lossless DEFLATE is used unless it is this many times bigger than the JPEG
// (photos, video, translucent blur). USB has ~10 MB/s to spare, WiFi ~0.7 MB/s.
let losslessFactorUSB = Double(ProcessInfo.processInfo.environment["VD_LOSSLESS_USB"] ?? "") ?? 4.0
let losslessFactorWiFi = Double(ProcessInfo.processInfo.environment["VD_LOSSLESS_WIFI"] ?? "") ?? 1.5
let linger = Double(ProcessInfo.processInfo.environment["VD_LINGER"] ?? "") ?? 60

func log(_ s: String) {
	let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
	FileHandle.standardError.write("[\(t)] \(s)\n".data(using: .utf8)!)
}

// MARK: - virtual display

func makeVirtualDisplay() -> CGVirtualDisplay {
	let desc = CGVirtualDisplayDescriptor()
	desc.queue = DispatchQueue.main
	desc.name = "V831 Display"
	desc.maxPixelsWide = UInt32(width)
	desc.maxPixelsHigh = UInt32(height)
	desc.sizeInMillimeters = CGSize(width: 242, height: 91)   // 10.26" 8:3 panel
	desc.productID = 0x0831
	desc.vendorID = 0x1F3A
	desc.serialNum = 1
	desc.terminationHandler = { _, _ in log("virtual display terminated") }

	guard let display = CGVirtualDisplay(descriptor: desc) else {
		log("CGVirtualDisplay creation failed")
		exit(1)
	}
	let settings = CGVirtualDisplaySettings()
	settings.hiDPI = 0
	settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
	if !display.apply(settings) {
		log("applySettings failed")
		exit(1)
	}
	log("virtual display \(display.displayID) created")
	return display
}

/// macOS defaults a new virtual display to some other listed mode (1280x480 here);
/// switch it to native 1600x600 so pixels map 1:1 to the panel.
func setNativeMode(_ id: CGDirectDisplayID) -> Bool {
	let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
	guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode],
	      let mode = modes.first(where: { $0.pixelWidth == width && $0.pixelHeight == height && $0.width == width }) else { return false }
	// Position is left alone: macOS remembers where the user arranged this display.
	if let cur = CGDisplayCopyDisplayMode(id), cur.pixelWidth == width, cur.width == width { return true }
	var config: CGDisplayConfigRef?
	guard CGBeginDisplayConfiguration(&config) == .success else { return false }
	CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
	let ok = CGCompleteDisplayConfiguration(config, .forSession) == .success
	log("set display mode \(width)x\(height): \(ok ? "ok" : "failed")")
	return ok
}

// MARK: - frame store

/// Latest captured frame plus the regions changed since the device last got an update.
final class FrameStore {
	private let lock = NSCondition()
	private var pixels = [UInt8](repeating: 0, count: width * height * 4)
	private var dirty: [CGRect] = []

	func update(from buffer: CVPixelBuffer, dirtyRects: [CGRect]) {
		CVPixelBufferLockBaseAddress(buffer, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
		guard let base = CVPixelBufferGetBaseAddress(buffer),
		      CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return }
		let bpr = CVPixelBufferGetBytesPerRow(buffer)
		lock.lock()
		pixels.withUnsafeMutableBytes { dst in
			for row in 0..<height {
				memcpy(dst.baseAddress! + row * width * 4, base + row * bpr, width * 4)
			}
		}
		dirty.append(contentsOf: dirtyRects)
		lock.signal()
		lock.unlock()
	}

	func markAllDirty() {
		lock.lock()
		dirty = [CGRect(x: 0, y: 0, width: width, height: height)]
		lock.signal()
		lock.unlock()
	}

	/// Waits for changes, then returns the merged changed rects and a snapshot of the frame.
	func take(timeout: TimeInterval) -> (rects: [CGRect], frame: [UInt8])? {
		lock.lock()
		defer { lock.unlock() }
		let deadline = Date().addingTimeInterval(timeout)
		while dirty.isEmpty {
			if !lock.wait(until: deadline) { return nil }
		}
		let rects = mergeRects(dirty)
		dirty.removeAll()
		return (rects, pixels)
	}
}

func crop(_ frame: [UInt8], _ r: CGRect) -> [UInt8] {
	let x = Int(r.minX), y = Int(r.minY), w = Int(r.width), h = Int(r.height)
	var out = [UInt8](repeating: 0, count: w * h * 4)
	frame.withUnsafeBytes { src in
		out.withUnsafeMutableBytes { dst in
			for row in 0..<h {
				memcpy(dst.baseAddress! + row * w * 4, src.baseAddress! + ((y + row) * width + x) * 4, w * 4)
			}
		}
	}
	return out
}

// MARK: - scroll detection ("copy rect")

/// Hash of one row segment; x is 16-px aligned so the 8-byte loads are aligned.
func rowHash(_ base: UnsafeRawPointer, x: Int, y: Int, w: Int) -> UInt64 {
	let p = (base + (y * width + x) * 4).assumingMemoryBound(to: UInt64.self)
	var h: UInt64 = 0xcbf29ce484222325
	for i in 0..<(w / 2) { h = (h ^ p[i]) &* 0x100000001b3 }
	return h
}

/// Vertical shift d of a column slice: new row y == old row y + d (d > 0: content
/// moved up, i.e. scrolled down). Only rows unique in the old slice vote, since
/// blank lines match everywhere.
func sliceShift(_ o: UnsafeRawPointer, _ n: UnsafeRawPointer, x: Int, w: Int, y0: Int, h: Int) -> Int? {
	var oldRow = [UInt64: Int](), repeated = Set<UInt64>()
	for y in y0..<(y0 + h) {
		let hv = rowHash(o, x: x, y: y, w: w)
		if oldRow[hv] != nil { repeated.insert(hv) } else { oldRow[hv] = y }
	}
	var votes = [Int: Int]()
	for y in y0..<(y0 + h) {
		let hv = rowHash(n, x: x, y: y, w: w)
		if !repeated.contains(hv), let oy = oldRow[hv], oy != y { votes[oy - y, default: 0] += 1 }
	}
	let best = votes.max(by: { $0.value < $1.value })
	if debugScroll { log("  slice x=\(x) w=\(w): unique rows \(oldRow.count - repeated.count), best \(best.map { "d=\($0.key) votes=\($0.value)" } ?? "none")") }
	guard let best, best.value >= max(12, h / 8), abs(best.key) < h else { return nil }
	return best.key
}

/// Finds a block inside r that scrolled vertically between old and new.
/// Returns the destination rect (in the new frame) and the source y it came from.
func detectScroll(old: [UInt8], new: [UInt8], in r: CGRect) -> (dst: CGRect, srcY: Int)? {
	let rx = Int(r.minX), y0 = Int(r.minY), rw = Int(r.width), h = Int(r.height)
	guard h >= 64, rw >= 128 else { return nil }
	return old.withUnsafeBytes { ob in
		new.withUnsafeBytes { nb in
			let o = ob.baseAddress!, n = nb.baseAddress!
			let sw = min(256, rw / 16 * 16)
			// try a slice in the middle, then at the quarter points
			for frac in [0.5, 0.25, 0.75] {
				let sx = rx + max(0, min(rw - sw, Int(Double(rw) * frac) / 16 * 16 - sw / 2))
				guard let d = sliceShift(o, n, x: sx, w: sw, y0: y0, h: h) else { continue }
				// rows whose shifted source lies on screen
				let ya = max(y0, -d), yb = min(y0 + h, height - d)
				guard yb - ya >= 32 else { continue }
				// longest run of rows that match under the shift, within the slice
				func rowMatches(_ y: Int, _ bx: Int, _ bw: Int) -> Bool {
					memcmp(n + (y * width + bx) * 4, o + ((y + d) * width + bx) * 4, bw * 4) == 0
				}
				var best = (start: 0, len: 0), runStart = -1
				for y in ya...yb {
					let ok = y < yb && rowMatches(y, sx, sw)
					if ok && runStart < 0 { runStart = y }
					if !ok && runStart >= 0 {
						if y - runStart > best.len { best = (runStart, y - runStart) }
						runStart = -1
					}
				}
				// grow sideways in 16-px columns while (nearly) every row of that run still
				// matches; anything the move gets wrong is caught by the exact diff afterwards
				func columnMatches(_ bx: Int) -> Bool {
					let hits = (best.start..<(best.start + best.len)).filter { rowMatches($0, bx, 16) }.count
					return hits * 10 >= best.len * 9
				}
				var xa = sx, xb = sx + sw
				while xa - 16 >= rx && columnMatches(xa - 16) { xa -= 16 }
				while xb + 16 <= rx + rw && columnMatches(xb) { xb += 16 }
				guard best.len >= 32 else { continue }
				if debugScroll { log("  scroll d=\(d): block x \(xa)..\(xb), rows \(best.start)..<\(best.start + best.len)") }
				return (CGRect(x: xa, y: best.start, width: xb - xa, height: best.len), best.start + d)
			}
			return nil
		}
	}
}

enum Op {
	case tile(CGRect)
	case copy(dst: CGRect, srcY: Int)   // same x/width as dst
}

/// Turns changed rects into copy + tile operations against what the device shows
/// (`sent`), updating `sent` to match.
func plan(_ rects: [CGRect], frame: [UInt8], sent: inout [UInt8]) -> [Op] {
	var ops: [Op] = []
	for r in rects {
		guard let (dst, srcY) = detectScroll(old: sent, new: frame, in: r) else {
			ops.append(.tile(r))
			continue
		}
		let x0 = Int(r.minX), y0 = Int(r.minY), w0 = Int(r.width), h = Int(r.height)
		let x = Int(dst.minX), w = Int(dst.width)
		ops.append(.copy(dst: dst, srcY: srcY))
		// apply the move to our copy of the device screen
		let block = crop(sent, CGRect(x: x, y: srcY, width: w, height: Int(dst.height)))
		sent.withUnsafeMutableBytes { s in
			block.withUnsafeBytes { b in
				for row in 0..<Int(dst.height) {
					memcpy(s.baseAddress! + ((Int(dst.minY) + row) * width + x) * 4, b.baseAddress! + row * w * 4, w * 4)
				}
			}
		}
		// whatever still differs (newly revealed lines, cursor, ...) goes as tiles,
		// diffed per column strip so rows changed only beside the block don't
		// resend the block
		let strips = [(x0, x - x0), (x, w), (x + w, x0 + w0 - x - w)].filter { $0.1 > 0 }
		frame.withUnsafeBytes { f in
			sent.withUnsafeBytes { s in
				for (sx, sw) in strips {
					var bandStart = -1, lastDiff = -100
					for y in y0...(y0 + h) {
						let differs = y < y0 + h && memcmp(f.baseAddress! + (y * width + sx) * 4, s.baseAddress! + (y * width + sx) * 4, sw * 4) != 0
						if differs {
							if bandStart < 0 { bandStart = y }
							lastDiff = y
						} else if bandStart >= 0 && (y - lastDiff > 16 || y == y0 + h) {
							ops.append(.tile(CGRect(x: sx, y: bandStart, width: sw, height: lastDiff + 1 - bandStart)))
							bandStart = -1
						}
					}
				}
			}
		}
	}
	for case let .tile(r) in ops {
		let px = crop(frame, r)
		sent.withUnsafeMutableBytes { s in
			px.withUnsafeBytes { p in
				for row in 0..<Int(r.height) {
					memcpy(s.baseAddress! + ((Int(r.minY) + row) * width + Int(r.minX)) * 4, p.baseAddress! + row * Int(r.width) * 4, Int(r.width) * 4)
				}
			}
		}
	}
	return ops
}

/// Clamp to the screen, snap to a 16px grid, merge overlapping/near rects, and
/// fall back to one full-screen rect when most of the screen changed.
func mergeRects(_ input: [CGRect]) -> [CGRect] {
	let screen = CGRect(x: 0, y: 0, width: width, height: height)
	var rects = input.compactMap { r -> CGRect? in
		let c = r.intersection(screen)
		if c.isNull || c.isEmpty { return nil }
		let x0 = floor(c.minX / 16) * 16, y0 = floor(c.minY / 16) * 16
		let x1 = min(ceil(c.maxX / 16) * 16, CGFloat(width)), y1 = min(ceil(c.maxY / 16) * 16, CGFloat(height))
		return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
	}
	var merged = true
	while merged {
		merged = false
		outer: for i in 0..<rects.count {
			for j in (i + 1)..<rects.count {
				let u = rects[i].union(rects[j])
				let separate = rects[i].width * rects[i].height + rects[j].width * rects[j].height
				if rects[i].insetBy(dx: -16, dy: -16).intersects(rects[j]) || u.width * u.height < separate * 1.3 {
					rects[i] = u
					rects.remove(at: j)
					merged = true
					break outer
				}
			}
		}
	}
	let area = rects.reduce(0) { $0 + $1.width * $1.height }
	if area > screen.width * screen.height * 0.5 || rects.count > 24 { return [screen] }
	return rects
}

func jpeg(_ bgra: [UInt8], width w: Int, height h: Int) -> Data? {
	let data = Data(bgra)
	guard let provider = CGDataProvider(data: data as CFData),
	      let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
	                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
	                          bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
	                                                   CGImageAlphaInfo.noneSkipFirst.rawValue),
	                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
	else { return nil }
	let out = NSMutableData()
	guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
	CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
	return CGImageDestinationFinalize(dest) ? out as Data : nil
}

// MARK: - capture

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
	let store: FrameStore
	var stream: SCStream?
	init(store: FrameStore) { self.store = store }

	func start(displayID: CGDirectDisplayID, attempt: Int = 0) {
		if !setNativeMode(displayID) {
			if attempt < 20 {
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(displayID: displayID, attempt: attempt + 1) }
				return
			}
			log("could not set \(width)x\(height) mode, capture will be scaled")
		}
		SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
			guard let display = content?.displays.first(where: { $0.displayID == displayID }) else {
				if attempt < 20 {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start(displayID: displayID, attempt: attempt + 1) }
				} else {
					log("virtual display not visible to ScreenCaptureKit: \(String(describing: error))")
					exit(1)
				}
				return
			}
			let cfg = SCStreamConfiguration()
			cfg.width = width
			cfg.height = height
			cfg.pixelFormat = kCVPixelFormatType_32BGRA
			cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
			cfg.queueDepth = 5
			cfg.showsCursor = true
			let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
			do {
				try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
			} catch {
				log("addStreamOutput: \(error)")
				exit(1)
			}
			stream.startCapture { error in
				if let error { log("startCapture: \(error)"); exit(1) }
				log("capturing display \(displayID)")
			}
			self.stream = stream
		}
	}

	func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
		guard type == .screen, sb.isValid,
		      let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
		      let info = attachments.first,
		      let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
		      let buffer = CMSampleBufferGetImageBuffer(sb) else { return }
		let rects = (info[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
			?? [CGRect(x: 0, y: 0, width: width, height: height)]
		store.update(from: buffer, dirtyRects: rects)
	}

	func stream(_ stream: SCStream, didStopWithError error: Error) {
		log("capture stopped: \(error)")
		exit(1)
	}
}

// MARK: - touch -> mouse

/// Turns raw contact frames into clicks, drags, right-clicks (long press) and scrolls.
final class TouchInput {
	let displayID: CGDirectDisplayID
	private enum State { case idle, pending, dragging, scrolling, consumed }
	private var state = State.idle
	private var start = CGPoint.zero, last = CGPoint.zero, startTime = Date()
	private var lastScroll = CGPoint.zero
	private var longPressTimer: DispatchWorkItem?

	init(displayID: CGDirectDisplayID) { self.displayID = displayID }

	private func global(_ p: CGPoint) -> CGPoint {
		let b = CGDisplayBounds(displayID)
		return CGPoint(x: b.minX + p.x * b.width / CGFloat(width), y: b.minY + p.y * b.height / CGFloat(height))
	}

	private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
		let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: global(p), mouseButton: button)
		e?.setIntegerValueField(.mouseEventClickState, value: clicks)
		e?.post(tap: .cghidEventTap)
	}

	func handle(_ contacts: [CGPoint]) {
		DispatchQueue.main.async { self.process(contacts) }
	}

	/// The link dropped mid-gesture: release a held button (a drag would otherwise
	/// stay pressed) but don't turn a half-finished tap into a click.
	func cancel() {
		DispatchQueue.main.async {
			self.longPressTimer?.cancel()
			if self.state == .dragging { self.post(.leftMouseUp, self.last) }
			self.state = .idle
		}
	}

	private func process(_ contacts: [CGPoint]) {
		switch contacts.count {
		case 0:
			longPressTimer?.cancel()
			if state == .pending {
				post(.leftMouseDown, start)
				post(.leftMouseUp, start)
			} else if state == .dragging {
				post(.leftMouseUp, last)
			}
			state = .idle
		case 1:
			let p = contacts[0]
			switch state {
			case .idle:
				state = .pending
				start = p; last = p; startTime = Date()
				post(.mouseMoved, p)
				let timer = DispatchWorkItem { [weak self] in
					guard let self, self.state == .pending else { return }
					self.post(.rightMouseDown, self.start, button: .right)
					self.post(.rightMouseUp, self.start, button: .right)
					self.state = .consumed
				}
				longPressTimer = timer
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timer)
			case .pending:
				if hypot(p.x - start.x, p.y - start.y) > 12 {
					longPressTimer?.cancel()
					post(.leftMouseDown, start)
					post(.leftMouseDragged, p)
					state = .dragging
				}
				last = p
			case .dragging:
				post(.leftMouseDragged, p)
				last = p
			case .scrolling, .consumed:
				break
			}
		default:
			longPressTimer?.cancel()
			let mid = CGPoint(x: (contacts[0].x + contacts[1].x) / 2, y: (contacts[0].y + contacts[1].y) / 2)
			if state == .dragging { post(.leftMouseUp, last) }
			if state != .scrolling {
				state = .scrolling
				lastScroll = mid
				post(.mouseMoved, mid)
				return
			}
			let dx = Int32(mid.x - lastScroll.x), dy = Int32(mid.y - lastScroll.y)
			if dx != 0 || dy != 0 {
				CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
					.post(tap: .cghidEventTap)
				lastScroll = mid
			}
		}
	}
}

// MARK: - server

func readFull(_ fd: Int32, _ n: Int) -> [UInt8]? {
	var buf = [UInt8](repeating: 0, count: n)
	var got = 0
	while got < n {
		let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
		if r <= 0 { return nil }
		got += r
	}
	return buf
}

func writeFull(_ fd: Int32, _ data: Data) -> Bool {
	data.withUnsafeBytes { p in
		var off = 0
		while off < data.count {
			let r = write(fd, p.baseAddress! + off, data.count - off)
			if r <= 0 { return false }
			off += r
		}
		return true
	}
}

extension Data {
	mutating func le16(_ v: Int) { append(UInt8(v & 0xff)); append(UInt8((v >> 8) & 0xff)) }
	mutating func le32(_ v: Int) { le16(v & 0xffff); le16((v >> 16) & 0xffff) }
}

func serve(store: FrameStore, connected: @escaping (Bool) -> TouchInput?) {
	let ls = socket(AF_INET, SOCK_STREAM, 0)
	var one: Int32 = 1
	setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
	var addr = sockaddr_in()
	addr.sin_family = sa_family_t(AF_INET)
	addr.sin_port = port.bigEndian
	addr.sin_addr.s_addr = INADDR_ANY
	let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ls, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
	guard ok == 0, listen(ls, 1) == 0 else { log("cannot listen on \(port)"); exit(1) }
	log("listening on :\(port)")

	while true {
		var peer = sockaddr_in()
		var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
		let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(ls, $0, &plen) } }
		if c < 0 { continue }
		setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
		setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
		// detect a dead link (USB unplugged) even when the screen is static, so the
		// device can come back over WiFi; we only serve one device at a time
		var idle: Int32 = 4, intvl: Int32 = 2, cnt: Int32 = 3
		setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
		setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
		setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, socklen_t(MemoryLayout<Int32>.size))
		setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &cnt, socklen_t(MemoryLayout<Int32>.size))
		guard let hello = readFull(c, 8), hello[0...3] == [86, 68, 48, 49] else { close(c); continue }
		let from = String(cString: inet_ntoa(peer.sin_addr))
		log("device connected from \(from) (\(Int(hello[4]) | Int(hello[5]) << 8)x\(Int(hello[6]) | Int(hello[7]) << 8))")
		let touch = connected(true)!
		handleClient(c, store: store, touch: touch, usb: from.hasPrefix("169.254."))
		touch.cancel()
		close(c)
		log("device disconnected")
		_ = connected(false)
	}
}

func handleClient(_ c: Int32, store: FrameStore, touch: TouchInput, usb: Bool) {
	let losslessFactor = usb ? losslessFactorUSB : losslessFactorWiFi
	// up to 2 unacknowledged frames: the next one transfers while the device decodes.
	// (Created at 0 and signalled: libdispatch traps if a semaphore is freed below
	// its initial value, which is the normal state after a disconnect.)
	let acks = DispatchSemaphore(value: 0)
	acks.signal()
	acks.signal()
	var alive = true
	var timings = [0, 0, 0, 0]   // device: total, decode, copy, pan (ms)

	// reader: acks and touch contacts
	Thread.detachNewThread {
		while alive, let type = readFull(c, 1) {
			if type[0] == UInt8(ascii: "A"), let d = readFull(c, 8) {
				timings = (0..<4).map { Int(d[$0 * 2]) | Int(d[$0 * 2 + 1]) << 8 }
				acks.signal()
			} else if type[0] == UInt8(ascii: "T"), let n = readFull(c, 1), let pts = readFull(c, Int(n[0]) * 4) {
				touch.handle((0..<Int(n[0])).map { i in
					CGPoint(x: Int(pts[i * 4]) | Int(pts[i * 4 + 1]) << 8, y: Int(pts[i * 4 + 2]) | Int(pts[i * 4 + 3]) << 8)
				})
			} else { break }
		}
		alive = false
		acks.signal()
	}

	store.markAllDirty()
	var sent = [UInt8](repeating: 0, count: width * height * 4)   // what the device shows
	var frames = 0, bytes = 0, statsStart = Date()
	var encStats = [0, 0, 0, 0]   // rects sent as raw / JPEG / DEFLATE / copy
	var lastSizes = (z: 0, j: 0)
	while alive {
		if acks.wait(timeout: .now() + 10) == .timedOut { log("ack timeout"); break }
		guard alive, let (rects, frame) = store.take(timeout: 1) else { acks.signal(); continue }
		// this is a plain thread: without a pool the per-frame ImageIO/NSData
		// objects are autoreleased into nothing and leak (~300 MB/min)
		let msg: Data = autoreleasepool {
			let ops = plan(rects, frame: frame, sent: &sent)
			var msg = Data([UInt8(ascii: "F")])
			msg.le16(ops.count)
			for op in ops {
				var r: CGRect, enc = 0, payload: Data
				switch op {
				case let .copy(dst, srcY):
					r = dst; enc = 3
					payload = Data(); payload.le16(Int(dst.minX)); payload.le16(srcY)
				case let .tile(t):
					r = t
					let w = Int(t.width), h = Int(t.height), px = crop(frame, t)
					payload = Data(px)
					if w * h > rawMaxPixels {
						let z = try? (payload as NSData).compressed(using: .zlib) as Data   // raw DEFLATE
						let j = jpeg(px, width: w, height: h)
						lastSizes = (z?.count ?? 0, j?.count ?? 0)
						if let z, z.count <= Int(Double(j?.count ?? Int.max / 4) * losslessFactor) {
							enc = 2; payload = z
						} else if let j {
							enc = 1; payload = j
						}
					}
				}
				encStats[enc] += 1
				msg.le16(Int(r.minX)); msg.le16(Int(r.minY)); msg.le16(Int(r.width)); msg.le16(Int(r.height))
				msg.append(UInt8(enc)); msg.le32(payload.count)
				msg.append(payload)
			}
			return msg
		}
		if !writeFull(c, msg) { break }
		frames += 1; bytes += msg.count
		let dt = Date().timeIntervalSince(statsStart)
		if dt >= 5 {
			log(String(format: "%.1f fps, %.0f KB/s, last frame %d rects %d KB, device total %d ms (decode %d, copy %d, pan %d), raw/jpeg/lossless/copy %d/%d/%d/%d (last z %d KB vs j %d KB)",
			           Double(frames) / dt, Double(bytes) / dt / 1024, rects.count, msg.count / 1024,
			           timings[0], timings[1], timings[2], timings[3], encStats[0], encStats[1], encStats[2], encStats[3],
			           lastSizes.z / 1024, lastSizes.j / 1024))
			frames = 0; bytes = 0; statsStart = Date(); encStats = [0, 0, 0, 0]
		}
	}
	alive = false
	shutdown(c, SHUT_RDWR)
}

// MARK: - main

guard CGPreflightScreenCaptureAccess() else { log("Screen Recording permission missing"); exit(1) }
if !AXIsProcessTrusted() { log("warning: Accessibility permission missing, touch input disabled") }

let store = FrameStore()
let capture = Capture(store: store)
var display: CGVirtualDisplay?   // created on the first connection
var touch: TouchInput?
var generation = 0               // bumped on every connect/disconnect
var noSleep: IOPMAssertionID = 0

/// Called by the server thread on connect (returns the touch injector) and disconnect.
func connected(_ up: Bool) -> TouchInput? {
	DispatchQueue.main.sync {
		generation += 1
		if up {
			if display == nil {
				let d = makeVirtualDisplay()
				display = d
				touch = TouchInput(displayID: d.displayID)
				capture.start(displayID: d.displayID)
				// like caffeinate -i, only while the screen is in use
				IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
				                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "V831 display connected" as CFString, &noSleep)
			}
		} else {
			let gen = generation
			DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
				if generation == gen {
					log("no device for \(Int(linger)) s, removing the display")
					exit(0)
				}
			}
		}
		return touch
	}
}

log("waiting for the device (no display until it connects)")
Thread.detachNewThread { serve(store: store, connected: connected) }
signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }
RunLoop.main.run()
