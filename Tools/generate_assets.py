#!/usr/bin/env python3
"""Generate small local vector assets. No third-party assets or runtime rasterization."""
from pathlib import Path
import json

root = Path("Widget/Assets.xcassets")
root.mkdir(parents=True, exist_ok=True)
(root/"Contents.json").write_text(json.dumps({"info":{"author":"xcode","version":1}}))

def image(name, w, h, content):
    folder = root / (name + ".imageset")
    folder.mkdir(exist_ok=True)
    (folder/"asset.svg").write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{content}</svg>')
    (folder/"Contents.json").write_text(json.dumps({
        "images":[{"filename":"asset.svg","idiom":"universal"}],
        "info":{"author":"xcode","version":1},
        "properties":{"preserves-vector-representation":True}
    }))

image("TodayRed",96,76,'<rect x="0" y="0" width="96" height="76" rx="13" fill="#FF3B30"/>')
image("HomeOrange",96,96,'<defs><linearGradient id="g" x1="0" x2="0.7" y1="0" y2="1"><stop stop-color="#FF7135"/><stop offset="1" stop-color="#FF3920"/></linearGradient></defs><circle cx="48" cy="48" r="47" fill="url(#g)" stroke="#FF9360" stroke-width="1"/>')
defs = '''<defs><linearGradient id="metal" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#F9F9F9"/><stop offset="0.56" stop-color="#E8E8E8"/><stop offset="1" stop-color="#DADADA"/></linearGradient><linearGradient id="edge" x1="0" x2="1" y1="0" y2="1"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#A6A6A6"/></linearGradient></defs>'''
for name, path, height, indicator, outline in [
    ("KeyCalendar","M1 123 V65 A62 62 0 0 1 125 65 V123 Q125 127 120 127 H6 Q1 127 1 123Z",128,"#68FF26","#4BCE13"),
    ("KeyHome","M1 10 Q1 1 10 1 H116 Q125 1 125 10 V100 Q125 109 116 109 H10 Q1 109 1 100Z",110,"#969696","#727272"),
    ("KeyWeather","M1 5 Q1 1 6 1 H120 Q125 1 125 5 V63 A62 62 0 0 1 1 63Z",128,"#FF4B2B","#D43B24")]:
    y=height/2-4
    image(name,126,height,defs+f'<path d="{path}" fill="url(#metal)" stroke="#FDFDFD" stroke-width="1.8"/><rect x="49" y="{y}" width="28" height="8" rx="4" fill="{indicator}" stroke="{outline}" stroke-width="0.8"/><path d="M52 {y+1.5} H74" stroke="#FFFFFF" stroke-opacity="0.4" stroke-width="1"/>')
image("RailMetal",144,380,'<defs><linearGradient id="r" x1="0" x2="1" y1="0" y2="1"><stop stop-color="#ECECEC"/><stop offset="0.3" stop-color="#969696"/><stop offset="0.65" stop-color="#D1D1D1"/><stop offset="1" stop-color="#767676"/></linearGradient></defs><rect x="1" y="1" width="142" height="378" rx="71" fill="url(#r)" stroke="#D5D5D5" stroke-width="2"/><rect x="7" y="7" width="130" height="366" rx="65" fill="#343434" stroke="#F1F1F1" stroke-width="1.2"/>')
