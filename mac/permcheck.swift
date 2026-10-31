// Reports (and requests) the two permissions the display daemon needs.
import CoreGraphics
import ApplicationServices

let screen = CGPreflightScreenCaptureAccess()
let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let ax = AXIsProcessTrustedWithOptions(axOpts)
print("screen recording: \(screen ? "GRANTED" : "missing")")
print("accessibility:    \(ax ? "GRANTED" : "missing")")
if !screen { _ = CGRequestScreenCaptureAccess() }
