#!/bin/zsh
# Build the Mac display daemon and the small test helpers.
set -e
cd "${0:A:h}"
swiftc -O -swift-version 5 -import-objc-header CGVirtualDisplay.h vdisplay.swift -o vdisplay \
	-framework CoreGraphics -framework ScreenCaptureKit -framework ApplicationServices -framework IOKit
swiftc -O permcheck.swift -o permcheck
for t in evlog modes mousepos place; do swiftc -O helpers/$t.swift -o helpers/$t; done
cc -O2 -o helpers/conntest helpers/conntest.c
ls -la vdisplay permcheck helpers/{evlog,modes,mousepos,place,conntest}
