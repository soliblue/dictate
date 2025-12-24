import argparse
import json
import os
from pathlib import Path

from google import genai
from google.genai import types

from config import (
    APP_FEATURES,
    APP_KEYWORDS,
    APP_NAME,
    CATEGORY,
    METADATA_DIR,
    SUPPORTED_LANGUAGES,
)


def get_client():
    api_key = os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_API_KEY")
    if not api_key:
        raise ValueError("Set GOOGLE_API_KEY or GEMINI_API_KEY environment variable")
    return genai.Client(api_key=api_key)


DESCRIPTION_PROMPT = """Generate App Store description content for a macOS app.

App Name: {app_name}
Category: {category}
Target Language: {language}

Key Features:
{features}

Keywords: {keywords}

Generate the following in {language_name}:

1. **Name** (max 30 characters): A catchy app name or subtitle
2. **Subtitle** (max 30 characters): Brief value proposition
3. **Promotional Text** (max 170 characters): Current promotion or highlight
4. **Description** (max 4000 characters): Full app description with:
   - Opening hook (1-2 sentences)
   - Key benefits section
   - Feature list
   - Privacy/security note
   - Call to action
5. **Keywords** (max 100 characters, comma-separated): Search optimization keywords
6. **What's New** (max 4000 characters): Release notes for current version

Format your response as JSON with these exact keys:
- name
- subtitle
- promotional_text
- description
- keywords
- whats_new

Important guidelines:
- Use natural, conversational language appropriate for {language_name}
- Avoid marketing buzzwords and hyperbole
- Focus on user benefits, not just features
- Include relevant emoji sparingly (1-2 max in description)
- Make the description scannable with line breaks
"""

LANGUAGE_NAMES = {
    "en-US": "English (US)",
    "de-DE": "German",
    "es-ES": "Spanish",
    "fr-FR": "French",
    "ja": "Japanese",
    "zh-Hans": "Simplified Chinese",
}


def generate_description(client, language: str = "en-US"):
    language_name = LANGUAGE_NAMES.get(language, language)

    prompt = DESCRIPTION_PROMPT.format(
        app_name=APP_NAME,
        category=CATEGORY,
        language=language,
        language_name=language_name,
        features="\n".join(f"- {f}" for f in APP_FEATURES),
        keywords=", ".join(APP_KEYWORDS),
    )

    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[prompt],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
        ),
    )

    return json.loads(response.text)


def generate_all_descriptions(languages: list = None):
    client = get_client()
    languages = languages or SUPPORTED_LANGUAGES

    METADATA_DIR.mkdir(parents=True, exist_ok=True)

    all_descriptions = {}
    for lang in languages:
        print(f"Generating description for {lang}...")
        desc = generate_description(client, lang)
        all_descriptions[lang] = desc

        output_path = METADATA_DIR / f"description_{lang}.json"
        output_path.write_text(json.dumps(desc, indent=2, ensure_ascii=False))
        print(f"  Saved: {output_path}")

    combined_path = METADATA_DIR / "descriptions_all.json"
    combined_path.write_text(json.dumps(all_descriptions, indent=2, ensure_ascii=False))
    print(f"\nCombined file: {combined_path}")

    return all_descriptions


def validate_description(desc: dict) -> list:
    errors = []

    limits = {
        "name": 30,
        "subtitle": 30,
        "promotional_text": 170,
        "description": 4000,
        "keywords": 100,
        "whats_new": 4000,
    }

    for field, limit in limits.items():
        if field not in desc:
            errors.append(f"Missing field: {field}")
        elif len(desc[field]) > limit:
            errors.append(f"{field}: {len(desc[field])} chars (max {limit})")

    return errors


def print_description(desc: dict, language: str = "en-US"):
    print(f"\n{'='*60}")
    print(f"App Store Description ({language})")
    print(f"{'='*60}")

    print(f"\n📱 Name ({len(desc.get('name', ''))} chars):")
    print(f"   {desc.get('name', 'N/A')}")

    print(f"\n📝 Subtitle ({len(desc.get('subtitle', ''))} chars):")
    print(f"   {desc.get('subtitle', 'N/A')}")

    print(f"\n🎯 Promotional Text ({len(desc.get('promotional_text', ''))} chars):")
    print(f"   {desc.get('promotional_text', 'N/A')}")

    print(f"\n📄 Description ({len(desc.get('description', ''))} chars):")
    print("-" * 40)
    print(desc.get("description", "N/A"))
    print("-" * 40)

    print(f"\n🔍 Keywords ({len(desc.get('keywords', ''))} chars):")
    print(f"   {desc.get('keywords', 'N/A')}")

    print(f"\n🆕 What's New ({len(desc.get('whats_new', ''))} chars):")
    print(desc.get("whats_new", "N/A"))

    errors = validate_description(desc)
    if errors:
        print(f"\n⚠️  Validation errors:")
        for e in errors:
            print(f"   - {e}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate App Store descriptions")
    parser.add_argument("--language", type=str, default="en-US", help="Target language code")
    parser.add_argument("--all", action="store_true", help="Generate for all supported languages")
    parser.add_argument("--validate", type=Path, help="Validate existing description JSON file")
    parser.add_argument("--print", dest="print_desc", type=Path, help="Print formatted description from file")
    args = parser.parse_args()

    if args.validate:
        desc = json.loads(args.validate.read_text())
        errors = validate_description(desc)
        if errors:
            print("Validation errors:")
            for e in errors:
                print(f"  - {e}")
        else:
            print("✓ Description is valid")
    elif args.print_desc:
        desc = json.loads(args.print_desc.read_text())
        print_description(desc)
    elif args.all:
        generate_all_descriptions()
    else:
        client = get_client()
        desc = generate_description(client, args.language)
        METADATA_DIR.mkdir(parents=True, exist_ok=True)
        output_path = METADATA_DIR / f"description_{args.language}.json"
        output_path.write_text(json.dumps(desc, indent=2, ensure_ascii=False))
        print(f"Saved: {output_path}")
        print_description(desc, args.language)
