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

# Original Glass Small 7 weather artwork, verified against inspected RGBA pixels.
for i, (remote, expected) in enumerate([
    ("l5uszPIABjtFcowSYdiyukHqgd6SmcAfg2KuiCFD.png", "225b7808fb923efb55bdd9f43e2193415bec5ad317c163b3aa61052aab4dde72"),
    ("qz81wqOzqlhXMdI3F7wdRuiAHzaTHpjnyWA3kL57.png", "0bae4bd6f9f2cfa80ddf82bc9b39e0f3af06e456b248174e629cefc8d802aa19"),
    ("e16AjvFsyVknYN2jXwNYUG9iHVxnQitnIWDeU0xE.png", "46706a5e285d2a8b571b2f08df53d9ab410123ef1fb8f9b93f2441cf10b242f6"),
    ("LjDt6yhXuio1zCqqx69x7xSvyUcFWToxctO0z2PL.png", "7d3ab2e586306e415cae5e6fa61c8aefc309fcc8685f989cb13a30ea81b03869"),
    ("at6h1sLS1pM8llCXnkwOtUIYWeZsBUOKd1Rhe202.png", "ad9a0614fe3a07f482e27c564bf6ff1cb790aae3e895b1644d770d39ad076081"),
    ("piji8PCnVmZLYXGjxz92ocULGTP71WbvOwdl06Fy.png", "86e856b5d3fad03f87a1ae87e18c1202c83515b21c58afe91c6f469303cc33b3"),
    ("CKKPt7hNnS0lxq7R9waJLSVxM7s6tG6a4OzlgBbE.png", "422cd57dab6fea222ce2c1535841227c51622ed043640a8dc726656d4291927c"),
    ("TkTUBhIVDvFcVAz31ZFGcHtxHPuNSA7ay4Etp7cm.png", "41ff9cab13735ad787c1b382d3f564aa010b4949a735b2e6ed737dc4f13c9948"),
    ("E6khoTlQxL6Rq9VsR3UjnGLjNHach4ZWxzKFvkVH.png", "40b93451ddb4e426d2b9ed4e814fe7a1ea268cb5156916b5a67e1b4f594a9ef2"),
    ("IdV96DiFsgooXkBdYe4kAZpEGXS8v5duMK92uWhI.png", "b50a9f06f86d634d018707832ce807c3478a7787273212f0bb573d369c8fbdc5"),
    ("Jb9qPVQTwDjXfFuz8ttylIAM7Fvacd0t2AxV907U.png", "239df1e1f9186e7f61aaca8d40b595f3fe275da084152fa4ca44210c1a922d4a"),
]):
    req = urllib.request.Request(SOURCE + remote, headers={"User-Agent":"ClearWidget personal asset build"})
    with urllib.request.urlopen(req, timeout=20) as response:
        raw = response.read(200_001)
    assert len(raw) <= 200_000
    im = Image.open(io.BytesIO(raw)).convert("RGBA")
    assert im.width == 90 and 90 <= im.height <= 95
    assert hashlib.sha256(im.tobytes()).hexdigest() == expected, f"Weather artwork differs: {i}"
    write(f"GlassWeather{i}", im)
print("Verified all 11 original Glass Small 7 weather images.")
