"""Convert a raw BGRA /dev/fb0 dump (1600x600) from the device into a PNG."""
import sys
from PIL import Image

raw = open(sys.argv[1], "rb").read()
Image.frombytes("RGBA", (1600, 600), raw[: 1600 * 600 * 4], "raw", "BGRA").convert("RGB").save(sys.argv[2])
