import argparse
import json
import os
from pathlib import Path

import requests
from PIL import Image

ASSETS_DIR = Path(__file__).parent.parent / "Whisper" / "Whisper" / "Assets.xcassets" / "AppIcon.appiconset"

MAC_ICON_SIZES = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]

def remove_bg_api(input_path: Path, output_path: Path) -> bool:
    response = requests.post(
        "https://api.remove.bg/v1.0/removebg",
        files={"image_file": input_path.read_bytes()},
        data={"size": "auto"},
        headers={"X-Api-Key": os.environ["REMOVEBG_API_KEY"]},
    )
    if response.status_code == 200:
        output_path.write_bytes(response.content)
        print(f"Background removed -> {output_path}")
        return True
    return False

def create_mac_icons(source_path: Path, output_dir: Path) -> list:
    img = Image.open(source_path)
    if img.mode != "RGBA":
        img = img.convert("RGBA")

    images = []
    for size, scale in MAC_ICON_SIZES:
        pixel_size = size * scale
        resized = img.resize((pixel_size, pixel_size), Image.LANCZOS)
        filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        resized.save(output_dir / filename, "PNG")
        images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": filename})
        print(f"Created: {filename} ({pixel_size}x{pixel_size})")

    return images

def update_contents_json(output_dir: Path, images: list):
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (output_dir / "Contents.json").write_text(json.dumps(contents, indent=2))
    print(f"Updated: Contents.json")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--remove-bg", action="store_true")
    parser.add_argument("--output-dir", type=Path, default=ASSETS_DIR)
    args = parser.parse_args()

    input_path = args.input

    if args.remove_bg:
        nobg_path = input_path.parent / f"{input_path.stem}_nobg.png"
        if remove_bg_api(input_path, nobg_path):
            input_path = nobg_path

    images = create_mac_icons(input_path, args.output_dir)
    update_contents_json(args.output_dir, images)
    print(f"\nApp icons created in: {args.output_dir}")
