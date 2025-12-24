import argparse
import json
import plistlib
from pathlib import Path

from config import (
    APP_FEATURES,
    APP_KEYWORDS,
    APP_NAME,
    BUNDLE_ID,
    CATEGORY,
    MACOS_SCREENSHOT_SIZES,
    METADATA_DIR,
    OUTPUT_DIR,
    SCREENSHOTS_DIR,
    SUBCATEGORY,
    SUPPORTED_LANGUAGES,
    VERSION,
    WHISPER_APP_DIR,
)


def get_version_from_xcode():
    project_path = WHISPER_APP_DIR / "Whisper.xcodeproj" / "project.pbxproj"
    if not project_path.exists():
        return VERSION

    content = project_path.read_text()
    import re
    match = re.search(r'MARKETING_VERSION\s*=\s*([^;]+);', content)
    return match.group(1).strip() if match else VERSION


def get_build_number():
    project_path = WHISPER_APP_DIR / "Whisper.xcodeproj" / "project.pbxproj"
    if not project_path.exists():
        return "1"

    content = project_path.read_text()
    import re
    match = re.search(r'CURRENT_PROJECT_VERSION\s*=\s*([^;]+);', content)
    return match.group(1).strip() if match else "1"


def collect_screenshots():
    screenshots = {}

    if not SCREENSHOTS_DIR.exists():
        return screenshots

    for size in MACOS_SCREENSHOT_SIZES:
        size_key = f"{size[0]}x{size[1]}"
        screenshots[size_key] = []

        for png in SCREENSHOTS_DIR.glob(f"*_{size_key}.png"):
            screenshots[size_key].append({
                "filename": png.name,
                "path": str(png),
                "scene": png.stem.replace(f"_{size_key}", ""),
            })

    return screenshots


def collect_descriptions():
    descriptions = {}

    if not METADATA_DIR.exists():
        return descriptions

    for lang in SUPPORTED_LANGUAGES:
        desc_file = METADATA_DIR / f"description_{lang}.json"
        if desc_file.exists():
            descriptions[lang] = json.loads(desc_file.read_text())

    return descriptions


def generate_fastlane_metadata():
    fastlane_dir = OUTPUT_DIR / "fastlane" / "metadata"
    fastlane_dir.mkdir(parents=True, exist_ok=True)

    descriptions = collect_descriptions()

    lang_mapping = {
        "en-US": "en-US",
        "de-DE": "de-DE",
        "es-ES": "es-ES",
        "fr-FR": "fr-FR",
        "ja": "ja",
        "zh-Hans": "zh-Hans",
    }

    for lang_code, desc in descriptions.items():
        fastlane_lang = lang_mapping.get(lang_code, lang_code)
        lang_dir = fastlane_dir / fastlane_lang
        lang_dir.mkdir(exist_ok=True)

        (lang_dir / "name.txt").write_text(desc.get("name", APP_NAME))
        (lang_dir / "subtitle.txt").write_text(desc.get("subtitle", ""))
        (lang_dir / "promotional_text.txt").write_text(desc.get("promotional_text", ""))
        (lang_dir / "description.txt").write_text(desc.get("description", ""))
        (lang_dir / "keywords.txt").write_text(desc.get("keywords", ""))
        (lang_dir / "release_notes.txt").write_text(desc.get("whats_new", ""))

    print(f"Generated Fastlane metadata: {fastlane_dir}")
    return fastlane_dir


def generate_app_store_connect_json():
    version = get_version_from_xcode()
    build = get_build_number()
    descriptions = collect_descriptions()
    screenshots = collect_screenshots()

    metadata = {
        "app": {
            "bundleId": BUNDLE_ID,
            "name": APP_NAME,
            "primaryCategory": CATEGORY,
            "secondaryCategory": SUBCATEGORY,
        },
        "version": {
            "versionString": version,
            "buildNumber": build,
            "releaseType": "MANUAL",
        },
        "localizations": {},
        "screenshots": {},
    }

    for lang, desc in descriptions.items():
        metadata["localizations"][lang] = {
            "name": desc.get("name", APP_NAME),
            "subtitle": desc.get("subtitle", ""),
            "promotionalText": desc.get("promotional_text", ""),
            "description": desc.get("description", ""),
            "keywords": desc.get("keywords", ""),
            "whatsNew": desc.get("whats_new", ""),
        }

    for size, items in screenshots.items():
        metadata["screenshots"][size] = [
            {"filename": item["filename"], "scene": item["scene"]}
            for item in items
        ]

    output_path = METADATA_DIR / "app_store_connect.json"
    METADATA_DIR.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(metadata, indent=2))
    print(f"Generated App Store Connect metadata: {output_path}")
    return output_path


def generate_summary():
    version = get_version_from_xcode()
    build = get_build_number()
    descriptions = collect_descriptions()
    screenshots = collect_screenshots()

    print("\n" + "=" * 60)
    print("📱 APP STORE METADATA SUMMARY")
    print("=" * 60)

    print(f"\n🏷️  App: {APP_NAME}")
    print(f"📦 Bundle ID: {BUNDLE_ID}")
    print(f"🔢 Version: {version} (Build {build})")
    print(f"📂 Category: {CATEGORY} > {SUBCATEGORY}")

    print(f"\n🌍 Localizations ({len(descriptions)}):")
    for lang, desc in descriptions.items():
        name = desc.get("name", "N/A")
        subtitle = desc.get("subtitle", "N/A")
        print(f"   • {lang}: {name} - {subtitle}")

    print(f"\n🖼️  Screenshots:")
    total = 0
    for size, items in screenshots.items():
        if items:
            print(f"   • {size}: {len(items)} screenshots")
            total += len(items)
    if total == 0:
        print("   • No screenshots generated yet")
    else:
        print(f"   Total: {total} screenshots")

    print(f"\n✨ Key Features:")
    for feat in APP_FEATURES[:5]:
        print(f"   • {feat}")

    print(f"\n🔍 Keywords: {', '.join(APP_KEYWORDS[:5])}...")

    print("\n" + "=" * 60)


def export_for_transporter():
    metadata = json.loads((METADATA_DIR / "app_store_connect.json").read_text())

    transporter_dir = OUTPUT_DIR / "transporter"
    transporter_dir.mkdir(parents=True, exist_ok=True)

    package = {
        "data": {
            "type": "appStoreVersionLocalizations",
            "attributes": metadata.get("localizations", {}),
        }
    }

    output_path = transporter_dir / "metadata.json"
    output_path.write_text(json.dumps(package, indent=2))
    print(f"Generated Transporter package: {output_path}")
    return output_path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Manage App Store metadata")
    parser.add_argument("--summary", action="store_true", help="Show metadata summary")
    parser.add_argument("--fastlane", action="store_true", help="Generate Fastlane metadata")
    parser.add_argument("--json", action="store_true", help="Generate App Store Connect JSON")
    parser.add_argument("--transporter", action="store_true", help="Export for Transporter")
    parser.add_argument("--all", action="store_true", help="Generate all formats")
    args = parser.parse_args()

    if args.all or args.summary:
        generate_summary()

    if args.all or args.fastlane:
        generate_fastlane_metadata()

    if args.all or args.json:
        generate_app_store_connect_json()

    if args.all or args.transporter:
        generate_app_store_connect_json()
        export_for_transporter()

    if not any([args.summary, args.fastlane, args.json, args.transporter, args.all]):
        generate_summary()
