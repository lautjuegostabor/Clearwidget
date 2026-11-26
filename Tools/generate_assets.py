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
    # Shade only the metal face, not the rectangular crop, indicator, rim or background.
    if name == "OriginalKeyHome":
        from PIL import ImageDraw, ImageChops
        w,h = key.size
        scale = 4
        mask_hi = Image.new("L",(w*scale,h*scale))
        ImageDraw.Draw(mask_hi).rounded_rectangle((3*scale,3*scale,(w-4)*scale,(h-4)*scale),radius=13*scale,fill=255)
        mask = mask_hi.resize((w,h),Image.Resampling.LANCZOS)
        rgb = key.convert("RGB")
        indicator = Image.new("L",(w,h))
        indicator.putdata([int(255 * max(0,min(1,(36-(max(p)-min(p)))/28))) for p in rgb.getdata()])
        mask = ImageChops.multiply(mask,indicator)
        darker = ImageEnhance.Brightness(rgb).enhance(0.96)
        pressed = Image.composite(darker,rgb,mask).convert("RGBA")
        pressed.putalpha(key.getchannel("A"))
        assert pressed.getchannel("A").tobytes() == key.getchannel("A").tobytes()
        assert pressed.getpixel((0,0)) == key.getpixel((0,0))
        assert pressed.tobytes() != key.tobytes()
        assert all(0 <= p[i]-q[i] <= 11 for p,q in zip(key.getdata(),pressed.getdata()) for i in range(3))
        print("Central active key: 4% maximum RGB shading, original alpha and corner preserved")
    else:
        from PIL import ImageDraw
        w,h = key.size
        scale = 4
        mask_hi = Image.new("L", (w*scale,h*scale))
        draw = ImageDraw.Draw(mask_hi)
        # Artwork measured in original pixels; upper/lower face has asymmetric corners.
        r = 82*scale
        left, right = 3*scale, (w-4)*scale
        top, bottom = 3*scale, (h-4)*scale
        draw.rounded_rectangle((left,top,right,bottom),radius=r,
            corners=(name=="OriginalKeyCalendar",name=="OriginalKeyCalendar",name=="OriginalKeyWeather",name=="OriginalKeyWeather"),fill=255)
        # Smooth the smaller corners adjacent to the separator.
        inner = Image.new("L",(w*scale,h*scale))
        ImageDraw.Draw(inner).rounded_rectangle((left,top,right,bottom),radius=13*scale,fill=255)
        from PIL import ImageChops
        mask = ImageChops.multiply(mask_hi,inner).resize((w,h),Image.Resampling.LANCZOS)
        # Preserve colored indicator pixels without leaving a bright halo in the metal.
        # A smooth chroma mask excludes the original saturated green/orange pixels.
        rgb = key.convert("RGB")
        indicator = Image.new("L",(w,h))
        indicator.putdata([int(255 * max(0,min(1,(36-(max(p)-min(p)))/28))) for p in rgb.getdata()])
        mask = ImageChops.multiply(mask,indicator)
        darker = ImageEnhance.Brightness(rgb).enhance(0.83)
        pressed = Image.composite(darker,rgb,mask).convert("RGBA")
        pressed.putalpha(key.getchannel("A"))
        assert pressed.getpixel((0,0)) == key.getpixel((0,0))
        assert pressed.getchannel("A").tobytes() == key.getchannel("A").tobytes()
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

# Clear Small and Clear Medium exports share the identical decoded icon pixels.
for name, remote, expected, size in [
    ("ClearWeather0", "r6JPJzfTwDq5DYyxIAVEOKeXqT049f9ZBbXpZgXV.png", "4ff86a4c559fc0c62f529cb7f51149703331af6c86fb3d466f95da0d6d9badae", 200),
    ("ClearWeather1", "PQdB8a6yYKMhKU6ok3lPrI3CaXuGlgkCpciP3U4W.png", "8074865340793ecdfb51f92264e2eaaa14d7a51fc9cf9c3e5b215297b6a3ab77", 200),
    ("ClearWeather2", "s5t0xaHJqfzCver6C6TiRwN83wNhApJ8eo9CBThh.png", "2007ea4a4a6c8501d311737b75fd12b3aee9b4f9a38c58548844d92bd0d5ac0c", 200),
    ("ClearWeather3", "Cgh92sbO7Jcg48Ei8gpwb5sZsyHLeYwinWS3HhFM.png", "b33e639d1df67b8e9c01326f6bbf6cc62f4695a7aa10c8aa593348041b2502f1", 200),
    ("ClearWeather4", "NbfPUyz0hrpOq4VXKMDbqjBV6i3tMOovoWHkAJYf.png", "576a9c68092a78b6823f50a71241e441f8c8d0982cca02d85fa1f662aa7d368f", 200),
    ("ClearWeather5", "nDIrV4n7yuzBcX2sbWoocFECAzQg217DdfoW4qcI.png", "7c5b404c06692877867c4f1a8be8a3e040d8de159c2a1a42aba1e8e46758e0ae", 200),
    ("ClearWeather6", "RCxoSbUVWtTnG705pqbaVCEHtmdnnuxEA3ctPKqz.png", "fa171b800f08ee2a47f0c4dc42dbd351d9b3957ed9b5673de04b4ed74109ceef", 200),
    ("ClearWeather7", "zDlJY1OGjdTxdPR3xvdmI0Og2hVZCuQvAwLNqtZn.png", "2cfc1121f370ed0a034410038b8acbc4c38be5bc62e289cf703cc65980d45475", 200),
    ("ClearWeather8", "Zo2spxrYkD0cyKYP0tnHlSdA9z6C1avdkEzLfoWX.png", "56823a9ced6f7fef7d6472b0d53ef58266abf9eeedda224110b04d0355baef35", 200),
    ("ClearWeather9", "tyPdSetvuAay8jmI2LU5GfaeDmyhlCODAsbA0CmT.png", "bae634e00b78d57ad4c0a29ecdbc1c42c4dd4b0d2fa8c9bfbc80d30885b722d1", 200),
    ("ClearWeather10", "MCvBp2le6fIkJJZMOca5TuMU2SszJWLupcVscIA7.png", "c9afdadf4d5109f8dc2069a5488d07d2bfb5339f5d7c5ddb0d44b72c7be7fc73", 200),
    ("ClearWeather11", "1RyvfJtAFofipslSHMTRYHgtAWkoVfIfFQwzwtuv.png", "0de92061a3650b8a877514d475cdf54cf72cd0e260c121f9f1b3a43be0046273", 200),
    ("ClearSmallDay", "UrkaFMX2m4drMZwDY64w3Fp6xTg9BbjgPXdhPYrK.png", "e6d3aa17ee09d704d3b8c12962c6876dbde615c31941402ecf482c0b8d62b73c", 354),
    ("ClearSmallNight", "5vQgCTu0NWxhrjj7C58qvBZ2BIVmbwwLqOQWUF9q.png", "d7c33962a82260a727a12b6f0b83283f69a0a39cb3767d825c82f48bd35eba00", 354),
]:
    req = urllib.request.Request(SOURCE + remote, headers={"User-Agent":"ClearWidget personal asset build"})
    with urllib.request.urlopen(req, timeout=20) as response:
        raw = response.read(2_000_001)
    assert len(raw) <= 2_000_000
    im = Image.open(io.BytesIO(raw)).convert("RGBA")
    assert im.size == (size,size)
    assert hashlib.sha256(im.tobytes()).hexdigest() == expected, name
    if name in ("ClearSmallDay","ClearSmallNight"):
        # Keep the continuous colored lower-card span intact; erase its black surround.
        transparent = Image.new("RGBA", im.size)
        for y in range(178,338):
            xs = [x for x in range(16,338) if max(im.getpixel((x,y))[:3]) > 60]
            if xs:
                left,right = min(xs),max(xs)+1
                transparent.paste(im.crop((left,y,right,y+1)),(left,y))
        assert transparent.getpixel((177,100))[3] == 0
        assert transparent.getpixel((177,250)) == im.getpixel((177,250))
        im = transparent
    write(name, im)
print("Verified original Clear assets and isolated lower cards.")

# Exact Web URL references from 21 - Clear Small.widgy.
for name, remote in [
    ("Small21Navigator", "SrvbO1wP1a7z3rc2LetJzaJVVklNfCWDu26Rfkug.png"),
    ("Small21Activity", "h1lnjAb2XgD7L3zbOKlN8YI28kbsmfwWTcdguCA2.png"),
    ("Small21Weather", "KSpmICvSRD0VyeqLdSRFWHh5LQHaPn0rQ8Z54Aom.png"),
    ("Small21Calendar", "xQHxPTgsm4QZmWwlASKKSl9TFnMlH0NnMvl4QdG6.png"),
]:
    req = urllib.request.Request(SOURCE + remote, headers={"User-Agent":"ClearWidget personal asset build"})
    with urllib.request.urlopen(req, timeout=25) as response:
        raw = response.read(2_000_001)
    assert len(raw) <= 2_000_000 and raw[:8] == b"\x89PNG\r\n\x1a\n"
    im = Image.open(io.BytesIO(raw)).convert("RGBA")
    assert im.width == im.height and 80 <= im.width <= 2000, (name,im.size)
    print(name, im.size, hashlib.sha256(im.tobytes()).hexdigest())
    write(name, im)
    if name == "Small21Navigator":
        # Integral source-pixel bounds; widget hit target is the matching circular area.
        w,h = im.size
        box = (round(w*1070/1600),round(h*1070/1600),round(w*1490/1600),round(h*1490/1600))
        button = im.crop(box)
        remainder = im.copy()
        remainder.paste((0,0,0,0),box)
        reconstructed = remainder.copy()
        reconstructed.paste(button,box[:2])
        assert reconstructed.tobytes() == im.tobytes()
        write("Small21NavigatorButton",button)
        write("Small21NavigatorRemainder",remainder)
        # Exact normalized coordinates for the actual source pixel boundaries.
        Path("Widget/Small21NavigatorGeometry.swift").write_text(
            "import CoreGraphics\n"
            "enum Small21NavigatorGeometry {\n"
            f"    static let width: CGFloat = {(box[2]-box[0])*1600/w:.12f}\n"
            f"    static let height: CGFloat = {(box[3]-box[1])*1600/h:.12f}\n"
            f"    static let centerX: CGFloat = {(box[0]+box[2])*800/w:.12f}\n"
            f"    static let centerY: CGFloat = {(box[1]+box[3])*800/h:.12f}\n"
            "}\n")
        print("Small21 navigator: source RGBA reconstructs exactly from both regions")
