import CoreGraphics
let id = CGDirectDisplayID(CommandLine.arguments[1])!
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(id, opts) as! [CGDisplayMode]
let cur = CGDisplayCopyDisplayMode(id)!
print("current: \(cur.width)x\(cur.height) px \(cur.pixelWidth)x\(cur.pixelHeight)")
for m in modes { print("mode \(m.width)x\(m.height) pixels \(m.pixelWidth)x\(m.pixelHeight) @\(m.refreshRate) usable=\(m.isUsableForDesktopGUI())") }
print("bounds: \(CGDisplayBounds(id))")
