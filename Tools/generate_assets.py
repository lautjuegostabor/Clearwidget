#!/usr/bin/env python3
"""Build-time extraction from original artwork; no asset networking on iPhone.
Use the two original PNGs provided by the user if present in OriginalAssets/,
otherwise retrieve the exact source URLs in the Widgy export. Verify decoded RGBA.
"""
from pathlib import Path
from PIL import Image, ImageEnhance
import hashlib, io, json, urllib.request

ROOT = Path("Widget/Assets.xcassets")
ROOT.mkdir(parents=True, exist_ok=True)
(ROOT/"Contents.json").write_text(json.dumps({"info":{"author":"xcode","version":1}}))
SOURCE = "https://widgy.fra1.digitaloceanspaces.com/images/"
def load(filename, remote, expected):
    local = Path("OriginalAssets") / filename
    if local.is_file():
        raw = local.read_bytes()
    else:
        req = urllib.request.Request(SOURCE + remote, headers={"User-Agent":"ClearWidget personal asset build"})
        with urllib.request.urlopen(req, timeout=20) as response:
            raw = response.read(2_000_001)
    assert len(raw) <= 2_000_000, "Unexpected asset size"
    image = Image.open(io.BytesIO(raw)).convert("RGBA")
    assert image.size == (1480,708), f"Unexpected dimensions: {filename} {image.size}"
    assert hashlib.sha256(image.tobytes()).hexdigest() == expected, f"Pixels differ from supplied reference: {filename}"
    return image

def write(name, im):
    folder = ROOT / (name+".imageset")
    folder.mkdir(exist_ok=True)
    im.save(folder/"asset.png", optimize=True)
    (folder/"Contents.json").write_text(json.dumps({
        "images":[{"filename":"asset.png","idiom":"universal"}],
        "info":{"author":"xcode","version":1}}))

frame = load("IMG_6090.png","7R3g3RfRAH2QLb7w8jh8ZKA167WGOrAkHm7UoQYy.png","ac8a7c257f1500ce5cfc953d5a1c5ec0ad9fb50444113447af28b936b91174ff")
home = load("IMG_6089.png","UFlmOgcgQ9OTTlYsK1ttviDKbygEJN0U2wYjbEkq.png","87f099b59f696372c9c9fd66dbdcda91da5d565460fb1de7de1a99867e975b8b")
assert frame.getpixel((740,354))[3] == 51 and home.getpixel((740,354))[3] == 0
base = frame.copy()
# Crops tessellate with no gap and preserve the exact normal-state image.
boxes = [("OriginalKeyCalendar",(1248,99,1421,275)),
         ("OriginalKeyHome",(1248,275,1421,431)),
         ("OriginalKeyWeather",(1248,431,1421,605))]
for name, box in boxes:
    key = frame.crop(box)
    write(name,key)
    # Only a restrained static luminance change. Preserve original alpha and texture.
    pressed = ImageEnhance.Brightness(key.convert("RGB")).enhance(0.91).convert("RGBA")
    pressed.putalpha(key.getchannel("A"))
    write(name+"On",pressed)
    base.paste((0,0,0,0),box)
write("OriginalFrame",base)
write("OriginalHome",home.crop((150,288,1060,441)))
# Pixel-identical reconstruction of normal rail, before selected-state shading.
restored = base.copy()
for name, box in boxes:
    restored.paste(frame.crop(box),box[:2])
assert restored.tobytes() == frame.tobytes()
# Calendar uses the requested system red, not a color from the original.
write("TodayRed",Image.new("RGBA",(96,76),(0,0,0,0)))
from PIL import ImageDraw
red = Image.new("RGBA",(96*3,76*3),(0,0,0,0))
ImageDraw.Draw(red).rounded_rectangle((0,0,96*3-1,76*3-1),radius=13*3,fill="#FF3B30")
write("TodayRed",red.resize((96,76),Image.Resampling.LANCZOS))
print("Verified exact original RGBA pixels, alpha and rail reconstruction.")
