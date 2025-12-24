import argparse
import os
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image

from config import (
    APP_NAME,
    GEMINI_MODELS,
    MACOS_SCREENSHOT_SIZES,
    SCREENSHOT_SCENES,
    SCREENSHOTS_DIR,
    WHISPER_APP_DIR,
)


def get_client():
    api_key = os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("Set GOOGLE_API_KEY or GEMINI_API_KEY environment variable")
    return genai.Client(api_key=api_key)


def load_app_icon():
    icon_path = WHISPER_APP_DIR / "Whisper" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_512x512@2x.png"
    return Image.open(icon_path) if icon_path.exists() else None


def generate_screenshot(client, scene: dict, size: tuple, model: str = "fast", reference_image: Image = None):
    width, height = size

    base_prompt = f"""Generate a macOS App Store screenshot for an app called "{APP_NAME}".
The screenshot must be exactly {width}x{height} pixels with a 16:10 aspect ratio.
Style: Clean, professional macOS screenshot suitable for the Mac App Store.
The app is a menu bar dictation tool that uses AI for speech-to-text.

Scene description: {scene['prompt']}

Requirements:
- Photorealistic macOS Sequoia interface
- No watermarks or logos except the app itself
- High quality, sharp rendering
- Proper macOS UI elements (menu bar, windows, etc.)
"""

    contents = [base_prompt]
    if reference_image:
        contents.append(reference_image)

    response = client.models.generate_content(
        model=GEMINI_MODELS[model],
        contents=contents,
        config=types.GenerateContentConfig(response_modalities=["image", "text"]),
    )

    for part in response.candidates[0].content.parts:
        if part.inline_data:
            return part.inline_data.data
    return None


def resize_to_exact(image_data: bytes, target_size: tuple) -> bytes:
    from io import BytesIO
    img = Image.open(BytesIO(image_data))
    resized = img.resize(target_size, Image.Resampling.LANCZOS)
    output = BytesIO()
    resized.save(output, format="PNG", optimize=True)
    return output.getvalue()


def generate_all_screenshots(model: str = "fast", scenes: list = None, sizes: list = None):
    client = get_client()
    app_icon = load_app_icon()

    scenes = scenes or SCREENSHOT_SCENES
    sizes = sizes or [MACOS_SCREENSHOT_SIZES[0]]

    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)

    generated = []
    for scene in scenes:
        for size in sizes:
            print(f"Generating {scene['name']} at {size[0]}x{size[1]}...")

            image_data = generate_screenshot(client, scene, size, model, app_icon)
            if not image_data:
                print(f"  Failed to generate {scene['name']}")
                continue

            image_data = resize_to_exact(image_data, size)

            filename = f"{scene['name']}_{size[0]}x{size[1]}.png"
            output_path = SCREENSHOTS_DIR / filename
            output_path.write_bytes(image_data)
            print(f"  Saved: {output_path}")
            generated.append(output_path)

    return generated


def generate_from_template(template_path: Path, text_overlay: str = None):
    client = get_client()
    template = Image.open(template_path)

    prompt = f"""Take this macOS screenshot template and make it look like a real App Store screenshot.
Keep the same layout and design, but enhance it to look professional and polished.
App name: {APP_NAME}
"""
    if text_overlay:
        prompt += f"\nAdd this promotional text: {text_overlay}"

    response = client.models.generate_content(
        model=GEMINI_MODELS["pro"],
        contents=[prompt, template],
        config=types.GenerateContentConfig(response_modalities=["image", "text"]),
    )

    for part in response.candidates[0].content.parts:
        if part.inline_data:
            return part.inline_data.data
    return None


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate App Store screenshots")
    parser.add_argument("--model", choices=["fast", "pro"], default="fast", help="Gemini model to use")
    parser.add_argument("--scene", type=str, help="Generate specific scene only")
    parser.add_argument("--size", type=str, help="Generate specific size only (e.g., 2880x1800)")
    parser.add_argument("--all-sizes", action="store_true", help="Generate all screenshot sizes")
    parser.add_argument("--template", type=Path, help="Use existing screenshot as template")
    args = parser.parse_args()

    if args.template:
        print(f"Enhancing template: {args.template}")
        result = generate_from_template(args.template)
        if result:
            output = SCREENSHOTS_DIR / f"{args.template.stem}_enhanced.png"
            SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
            output.write_bytes(result)
            print(f"Saved: {output}")
    else:
        scenes = [s for s in SCREENSHOT_SCENES if s["name"] == args.scene] if args.scene else None

        if args.size:
            w, h = map(int, args.size.split("x"))
            sizes = [(w, h)]
        elif args.all_sizes:
            sizes = MACOS_SCREENSHOT_SIZES
        else:
            sizes = None

        generated = generate_all_screenshots(model=args.model, scenes=scenes, sizes=sizes)
        print(f"\nGenerated {len(generated)} screenshots")
