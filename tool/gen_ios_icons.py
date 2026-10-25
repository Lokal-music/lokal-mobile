#!/usr/bin/env python3
"""Build declared iPhone alternate icons from the existing Lokal brand assets."""
import json
import os
from pathlib import Path
from PIL import Image
import gen_lokal_launcher_icons as brand

root = Path(__file__).resolve().parents[1]
os.chdir(root)
brand.source_bytes()  # Validate the same pinned artwork as Android/desktop.
base = Image.open(brand.LOGO).convert('RGBA')
sticker = Image.open(brand.STICKER).convert('RGBA')
for accent, color in brand.ACCENTS.items():
    name = 'Lokal' + accent.capitalize()
    folder = root / 'ios/Runner/Assets.xcassets' / (name + '.appiconset')
    folder.mkdir(parents=True, exist_ok=True)
    image = brand.tinted(base, sticker, color)
    opaque = Image.new('RGBA', image.size, brand.BACKGROUND)
    opaque.alpha_composite(image)
    opaque.convert('RGB').resize((1024, 1024), Image.Resampling.LANCZOS).save(folder / 'icon.png', optimize=True)
    (folder / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}],
        'info': {'author': 'xcode', 'version': 1},
    }, indent=2) + '\n')
print(f'Generated {len(brand.ACCENTS)} opaque iPhone alternate icons from Lokal artwork.')
