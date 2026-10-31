import CoreGraphics
let id = CGDirectDisplayID(CommandLine.arguments[1])!
var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayOrigin(cfg, id, Int32(CommandLine.arguments[2])!, Int32(CommandLine.arguments[3])!)
print(CGCompleteDisplayConfiguration(cfg, .permanently) == .success ? "ok" : "failed")
