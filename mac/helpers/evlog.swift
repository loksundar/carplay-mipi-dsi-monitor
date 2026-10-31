import CoreGraphics
import Foundation
// listen-only tap: prints mouse/scroll events for a few seconds
let mask: CGEventMask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .scrollWheel, .mouseMoved]
	.reduce(0) { $0 | (1 << $1.rawValue) }
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
	callback: { _, type, e, _ in
		let extra = type == .scrollWheel ? " dy=\(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))" : ""
		print("\(type.rawValue) @ \(Int(e.location.x)),\(Int(e.location.y))\(extra)"); fflush(stdout)
		return Unmanaged.passUnretained(e) }, userInfo: nil) else { print("no tap"); exit(1) }
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
DispatchQueue.main.asyncAfter(deadline: .now() + Double(CommandLine.arguments[1])!) { exit(0) }
CFRunLoopRun()
