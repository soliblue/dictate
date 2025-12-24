import argparse
import json
import os
from io import BytesIO
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image

from config import (
    APP_FEATURES,
    APP_NAME,
    GEMINI_MODELS,
    MACOS_SCREENSHOT_SIZES,
    METADATA_DIR,
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


PROMPT_GENERATION_TEMPLATE = """You are an expert at creating prompts for AI image generation, specifically for macOS App Store screenshots.

App: {app_name}
Features:
{features}

I need you to generate a detailed, highly specific image generation prompt for this screenshot scene:

Scene Name: {scene_name}
Scene Description: {scene_description}
Target Size: {width}x{height} pixels (16:10 aspect ratio)

Requirements for your prompt:
1. Describe a photorealistic macOS Sequoia desktop screenshot
2. Include specific UI elements (menu bar at top, dock if visible, window chrome)
3. Describe exact colors, lighting, and visual style matching Apple's aesthetic
4. Include the app's specific UI elements as described in the scene
5. Mention it should look like an actual screenshot, not a 3D render
6. Specify professional App Store quality - clean, polished, no clutter
7. Include any text that should appear (using exact wording)

The app is a menu bar dictation tool that:
- Shows a microphone icon in the menu bar
- Has a floating glass/frosted pill-shaped launcher panel
- Shows a subtle glow border around the screen when recording (blue) or transcribing (purple)
- Uses SF Symbols style icons

Generate ONLY the image prompt, nothing else. Make it detailed and specific (200-400 words)."""


def generate_prompt_for_scene(client, scene: dict, size: tuple) -> str:
    width, height = size

    prompt = PROMPT_GENERATION_TEMPLATE.format(
        app_name=APP_NAME,
        features="\n".join(f"- {f}" for f in APP_FEATURES),
        scene_name=scene["name"],
        scene_description=scene["description"],
        width=width,
        height=height,
    )

    response = client.models.generate_content(
        model=GEMINI_MODELS["text"],
        contents=[prompt],
    )

    return response.text.strip()


def generate_all_prompts(client, scenes: list = None, size: tuple = None) -> dict:
    scenes = scenes or SCREENSHOT_SCENES
    size = size or MACOS_SCREENSHOT_SIZES[0]

    prompts = {}
    for scene in scenes:
        print(f"  Generating prompt for '{scene['name']}'...")
        prompts[scene["name"]] = generate_prompt_for_scene(client, scene, size)

    return prompts


def save_prompts(prompts: dict):
    METADATA_DIR.mkdir(parents=True, exist_ok=True)
    output_path = METADATA_DIR / "screenshot_prompts.json"
    output_path.write_text(json.dumps(prompts, indent=2))
    print(f"Saved prompts: {output_path}")
    return output_path


def load_prompts() -> dict:
    prompts_path = METADATA_DIR / "screenshot_prompts.json"
    if prompts_path.exists():
        return json.loads(prompts_path.read_text())
    return {}


def generate_screenshot(client, prompt: str, size: tuple, reference_image: Image = None) -> bytes:
    width, height = size

    full_prompt = f"""Generate a macOS App Store screenshot.
Exact dimensions: {width}x{height} pixels (16:10 aspect ratio).

{prompt}

Critical requirements:
- Photorealistic macOS Sequoia interface
- No watermarks, badges, or promotional overlays
- Sharp, high-quality rendering suitable for App Store
- Proper macOS UI chrome (menu bar, window decorations)
"""

    contents = [full_prompt]
    if reference_image:
        contents.append(reference_image)

    response = client.models.generate_content(
        model=GEMINI_MODELS["image"],
        contents=contents,
        config=types.GenerateContentConfig(response_modalities=["image", "text"]),
    )

    for part in response.candidates[0].content.parts:
        if part.inline_data:
            return part.inline_data.data
    return None


def resize_to_exact(image_data: bytes, target_size: tuple) -> bytes:
    img = Image.open(BytesIO(image_data))
    resized = img.resize(target_size, Image.Resampling.LANCZOS)
    output = BytesIO()
    resized.save(output, format="PNG", optimize=True)
    return output.getvalue()


def generate_all_screenshots(scenes: list = None, sizes: list = None, regenerate_prompts: bool = False):
    client = get_client()
    app_icon = load_app_icon()

    scenes = scenes or SCREENSHOT_SCENES
    sizes = sizes or [MACOS_SCREENSHOT_SIZES[0]]

    print("\n📝 Step 1: Generating prompts with LLM...")
    print("-" * 40)

    existing_prompts = load_prompts() if not regenerate_prompts else {}
    prompts = {}

    for scene in scenes:
        if scene["name"] in existing_prompts and not regenerate_prompts:
            print(f"  Using cached prompt for '{scene['name']}'")
            prompts[scene["name"]] = existing_prompts[scene["name"]]
        else:
            print(f"  Generating prompt for '{scene['name']}'...")
            prompts[scene["name"]] = generate_prompt_for_scene(client, scene, sizes[0])

    save_prompts({**existing_prompts, **prompts})

    print("\n🖼️  Step 2: Generating images with Nano Banana Pro...")
    print("-" * 40)

    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)

    generated = []
    for scene in scenes:
        prompt = prompts[scene["name"]]

        for size in sizes:
            print(f"  Generating {scene['name']} at {size[0]}x{size[1]}...")

            image_data = generate_screenshot(client, prompt, size, app_icon)
            if not image_data:
                print(f"    ❌ Failed to generate {scene['name']}")
                continue

            image_data = resize_to_exact(image_data, size)

            filename = f"{scene['name']}_{size[0]}x{size[1]}.png"
            output_path = SCREENSHOTS_DIR / filename
            output_path.write_bytes(image_data)
            print(f"    ✅ Saved: {output_path.name}")
            generated.append(output_path)

    return generated


def regenerate_single(scene_name: str, custom_prompt: str = None):
    client = get_client()
    app_icon = load_app_icon()

    scene = next((s for s in SCREENSHOT_SCENES if s["name"] == scene_name), None)
    if not scene:
        print(f"❌ Unknown scene: {scene_name}")
        return None

    size = MACOS_SCREENSHOT_SIZES[0]

    if custom_prompt:
        prompt = custom_prompt
    else:
        print(f"Generating new prompt for '{scene_name}'...")
        prompt = generate_prompt_for_scene(client, scene, size)

    print(f"\nPrompt:\n{prompt[:200]}...\n")
    print(f"Generating image...")

    image_data = generate_screenshot(client, prompt, size, app_icon)
    if not image_data:
        print("❌ Failed to generate image")
        return None

    image_data = resize_to_exact(image_data, size)

    SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    filename = f"{scene_name}_{size[0]}x{size[1]}.png"
    output_path = SCREENSHOTS_DIR / filename
    output_path.write_bytes(image_data)
    print(f"✅ Saved: {output_path}")

    prompts = load_prompts()
    prompts[scene_name] = prompt
    save_prompts(prompts)

    return output_path


def show_prompts():
    prompts = load_prompts()
    if not prompts:
        print("No prompts generated yet. Run with --generate-prompts first.")
        return

    for name, prompt in prompts.items():
        print(f"\n{'='*60}")
        print(f"Scene: {name}")
        print(f"{'='*60}")
        print(prompt)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate App Store screenshots with AI")
    parser.add_argument("--generate-prompts", action="store_true", help="Generate prompts only (no images)")
    parser.add_argument("--regenerate-prompts", action="store_true", help="Force regenerate all prompts")
    parser.add_argument("--show-prompts", action="store_true", help="Show cached prompts")
    parser.add_argument("--scene", type=str, help="Generate specific scene only")
    parser.add_argument("--custom-prompt", type=str, help="Use custom prompt for scene")
    parser.add_argument("--size", type=str, help="Generate specific size (e.g., 2880x1800)")
    parser.add_argument("--all-sizes", action="store_true", help="Generate all screenshot sizes")
    args = parser.parse_args()

    if args.show_prompts:
        show_prompts()
    elif args.generate_prompts:
        client = get_client()
        prompts = generate_all_prompts(client)
        save_prompts(prompts)
        print("\n✅ Prompts generated and saved")
    elif args.scene:
        regenerate_single(args.scene, args.custom_prompt)
    else:
        if args.size:
            w, h = map(int, args.size.split("x"))
            sizes = [(w, h)]
        elif args.all_sizes:
            sizes = MACOS_SCREENSHOT_SIZES
        else:
            sizes = None

        generated = generate_all_screenshots(
            sizes=sizes,
            regenerate_prompts=args.regenerate_prompts,
        )
        print(f"\n✅ Generated {len(generated)} screenshots")
