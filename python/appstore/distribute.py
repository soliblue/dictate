import argparse
import os
import subprocess
import sys
from pathlib import Path

from config import (
    APP_NAME,
    METADATA_DIR,
    OUTPUT_DIR,
    SCREENSHOTS_DIR,
    SUPPORTED_LANGUAGES,
    WHISPER_APP_DIR,
)


def check_requirements():
    missing = []

    api_key = os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_API_KEY")
    if not api_key:
        missing.append("GOOGLE_API_KEY or GEMINI_API_KEY environment variable")

    required_packages = ["google-genai", "pillow"]
    for pkg in required_packages:
        try:
            __import__(pkg.replace("-", "_").replace("google-genai", "google.genai"))
        except ImportError:
            missing.append(f"Python package: {pkg}")

    if missing:
        print("❌ Missing requirements:")
        for m in missing:
            print(f"   • {m}")
        return False

    print("✅ All requirements satisfied")
    return True


def generate_screenshots(all_sizes: bool = False, regenerate_prompts: bool = False):
    print("\n" + "=" * 60)
    print("🖼️  GENERATING SCREENSHOTS (Nano Banana Pro)")
    print("=" * 60)

    from screenshots import generate_all_screenshots
    from config import MACOS_SCREENSHOT_SIZES

    sizes = MACOS_SCREENSHOT_SIZES if all_sizes else [MACOS_SCREENSHOT_SIZES[0]]
    generated = generate_all_screenshots(sizes=sizes, regenerate_prompts=regenerate_prompts)

    print(f"\n✅ Generated {len(generated)} screenshots")
    return generated


def generate_descriptions(languages: list = None):
    print("\n" + "=" * 60)
    print("📝 GENERATING DESCRIPTIONS")
    print("=" * 60)

    from descriptions import generate_all_descriptions

    languages = languages or SUPPORTED_LANGUAGES
    descriptions = generate_all_descriptions(languages)

    print(f"\n✅ Generated descriptions for {len(descriptions)} languages")
    return descriptions


def generate_metadata():
    print("\n" + "=" * 60)
    print("📋 GENERATING METADATA")
    print("=" * 60)

    from metadata import (
        generate_app_store_connect_json,
        generate_fastlane_metadata,
        generate_summary,
    )

    generate_app_store_connect_json()
    generate_fastlane_metadata()
    generate_summary()

    print("\n✅ Metadata generated")


def build_app(configuration: str = "Release"):
    print("\n" + "=" * 60)
    print("🔨 BUILDING APP")
    print("=" * 60)

    project_path = WHISPER_APP_DIR / "Whisper.xcodeproj"

    if not project_path.exists():
        print(f"❌ Project not found: {project_path}")
        return False

    build_dir = OUTPUT_DIR / "build"
    build_dir.mkdir(parents=True, exist_ok=True)

    cmd = [
        "xcodebuild",
        "-project", str(project_path),
        "-scheme", "Whisper",
        "-configuration", configuration,
        "-derivedDataPath", str(build_dir),
        "-destination", "generic/platform=macOS",
        "clean", "build",
    ]

    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"❌ Build failed:\n{result.stderr}")
        return False

    print("✅ Build successful")
    return True


def archive_app():
    print("\n" + "=" * 60)
    print("📦 ARCHIVING APP")
    print("=" * 60)

    project_path = WHISPER_APP_DIR / "Whisper.xcodeproj"
    archive_path = OUTPUT_DIR / "archives" / f"{APP_NAME}.xcarchive"
    archive_path.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        "xcodebuild",
        "-project", str(project_path),
        "-scheme", "Whisper",
        "-configuration", "Release",
        "-archivePath", str(archive_path),
        "archive",
    ]

    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"❌ Archive failed:\n{result.stderr}")
        return None

    print(f"✅ Archive created: {archive_path}")
    return archive_path


def export_ipa(archive_path: Path):
    print("\n" + "=" * 60)
    print("📤 EXPORTING FOR APP STORE")
    print("=" * 60)

    export_path = OUTPUT_DIR / "export"
    export_path.mkdir(parents=True, exist_ok=True)

    export_options = OUTPUT_DIR / "ExportOptions.plist"
    if not export_options.exists():
        import plistlib
        options = {
            "method": "app-store-connect",
            "destination": "upload",
            "signingStyle": "automatic",
        }
        export_options.write_bytes(plistlib.dumps(options))

    cmd = [
        "xcodebuild",
        "-exportArchive",
        "-archivePath", str(archive_path),
        "-exportPath", str(export_path),
        "-exportOptionsPlist", str(export_options),
    ]

    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"❌ Export failed:\n{result.stderr}")
        return None

    print(f"✅ Exported to: {export_path}")
    return export_path


def upload_to_app_store(export_path: Path):
    print("\n" + "=" * 60)
    print("🚀 UPLOADING TO APP STORE CONNECT")
    print("=" * 60)

    pkg_files = list(export_path.glob("*.pkg"))
    if not pkg_files:
        print("❌ No .pkg file found for upload")
        return False

    pkg_path = pkg_files[0]

    cmd = [
        "xcrun", "altool",
        "--upload-app",
        "-f", str(pkg_path),
        "-t", "macos",
        "--apiKey", os.environ.get("APP_STORE_API_KEY", ""),
        "--apiIssuer", os.environ.get("APP_STORE_API_ISSUER", ""),
    ]

    if not os.environ.get("APP_STORE_API_KEY"):
        print("⚠️  APP_STORE_API_KEY not set - skipping upload")
        print("   Set APP_STORE_API_KEY and APP_STORE_API_ISSUER to enable upload")
        return False

    print(f"Running: xcrun altool --upload-app ...")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"❌ Upload failed:\n{result.stderr}")
        return False

    print("✅ Upload successful!")
    return True


def full_distribution(skip_build: bool = False, skip_upload: bool = False):
    print("\n" + "=" * 60)
    print(f"🚀 FULL DISTRIBUTION PIPELINE FOR {APP_NAME}")
    print("=" * 60)

    if not check_requirements():
        return False

    generate_screenshots(all_sizes=False)
    generate_descriptions()
    generate_metadata()

    if not skip_build:
        if not build_app():
            return False

        archive_path = archive_app()
        if not archive_path:
            return False

        export_path = export_ipa(archive_path)
        if not export_path:
            return False

        if not skip_upload:
            upload_to_app_store(export_path)

    print("\n" + "=" * 60)
    print("✅ DISTRIBUTION COMPLETE")
    print("=" * 60)

    print(f"\n📁 Output directory: {OUTPUT_DIR}")
    print(f"   • Screenshots: {SCREENSHOTS_DIR}")
    print(f"   • Metadata: {METADATA_DIR}")

    return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Automate App Store distribution for Whisper",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python distribute.py --full                    # Full pipeline
  python distribute.py --screenshots             # Generate screenshots only
  python distribute.py --descriptions            # Generate descriptions only
  python distribute.py --metadata               # Generate metadata only
  python distribute.py --full --skip-build      # Assets only, no build
  python distribute.py --full --skip-upload     # Build but don't upload

Environment variables:
  GOOGLE_API_KEY        Gemini API key for AI generation
  APP_STORE_API_KEY     App Store Connect API key
  APP_STORE_API_ISSUER  App Store Connect API issuer
        """
    )

    parser.add_argument("--check", action="store_true", help="Check requirements only")
    parser.add_argument("--screenshots", action="store_true", help="Generate screenshots")
    parser.add_argument("--screenshots-all-sizes", action="store_true", help="Generate all screenshot sizes")
    parser.add_argument("--regenerate-prompts", action="store_true", help="Force regenerate LLM prompts")
    parser.add_argument("--descriptions", action="store_true", help="Generate descriptions")
    parser.add_argument("--descriptions-lang", type=str, nargs="+", help="Languages to generate")
    parser.add_argument("--metadata", action="store_true", help="Generate metadata")
    parser.add_argument("--build", action="store_true", help="Build the app")
    parser.add_argument("--archive", action="store_true", help="Archive the app")
    parser.add_argument("--full", action="store_true", help="Full distribution pipeline")
    parser.add_argument("--skip-build", action="store_true", help="Skip build step in full pipeline")
    parser.add_argument("--skip-upload", action="store_true", help="Skip upload step in full pipeline")

    args = parser.parse_args()

    if args.check:
        sys.exit(0 if check_requirements() else 1)

    if args.screenshots:
        generate_screenshots(all_sizes=args.screenshots_all_sizes, regenerate_prompts=args.regenerate_prompts)

    if args.descriptions:
        generate_descriptions(languages=args.descriptions_lang)

    if args.metadata:
        generate_metadata()

    if args.build:
        build_app()

    if args.archive:
        archive_app()

    if args.full:
        full_distribution(skip_build=args.skip_build, skip_upload=args.skip_upload)

    if not any([args.check, args.screenshots, args.descriptions, args.metadata,
                args.build, args.archive, args.full]):
        parser.print_help()
