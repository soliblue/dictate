import argparse
import os
from pathlib import Path

import requests
from PIL import Image

def remove_bg_api(input_path: Path, output_path: Path) -> bool:
    response = requests.post(
        "https://api.remove.bg/v1.0/removebg",
        files={"image_file": input_path.read_bytes()},
        data={"size": "auto"},
        headers={"X-Api-Key": os.environ["REMOVEBG_API_KEY"]},
    )
    if response.status_code == 200:
        output_path.write_bytes(response.content)
        print(f"Background removed (API) -> {output_path}")
        return True
    elif response.status_code == 402:
        return False
    return False


def remove_bg_local(input_path: Path, output_path: Path) -> bool:
    from rembg import remove, new_session
    session = new_session("birefnet-general")
    img = Image.open(input_path)
    result = remove(img, session=session)
    result.save(output_path)
    print(f"Background removed (BiRefNet) -> {output_path}")
    return True


def remove_background(input_path: Path, output_path: Path) -> bool:
    if os.environ.get("REMOVEBG_API_KEY"):
        if remove_bg_api(input_path, output_path):
            return True
        print("remove.bg API limit reached, using BiRefNet fallback...")
    return remove_bg_local(input_path, output_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output_name", nargs="?")
    parser.add_argument("--remove-bg", action="store_true")
    args = parser.parse_args()

    input_path = args.input
    output_name = args.output_name or input_path.stem.replace("-removebg-preview", "").replace(".png", "")
    output_dir = input_path.parent

    if args.remove_bg:
        nobg_path = output_dir / f"{output_name}_nobg.png"
        if remove_background(input_path, nobg_path):
            input_path = nobg_path

    img = Image.open(input_path)
    w, h = img.size

    img.save(output_dir / f"{output_name}.png", "PNG")
    img.resize((w // 2, h // 2), Image.LANCZOS).save(output_dir / f"{output_name}_half.png", "PNG")
    img.resize((w // 4, h // 4), Image.LANCZOS).save(output_dir / f"{output_name}_quarter.png", "PNG")

    print(f"{output_name}: {w}x{h} -> {w // 2}x{h // 2} -> {w // 4}x{h // 4}")
