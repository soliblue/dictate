import argparse
import os
from pathlib import Path

from google import genai
from google.genai import types

DOWNLOADS = Path.home() / "Downloads"

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ref", type=Path, required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    print(f"Generating: {args.prompt}...")

    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    response = client.models.generate_content(
        model=os.environ.get("GEMINI_MODEL", "gemini-2.0-flash-exp"),
        contents=[
            types.Content(
                parts=[
                    types.Part(text=f"Generate an icon in the exact same style as the reference image. The icon should be: {args.prompt}. Keep the same color palette, line thickness, shading style, and overall aesthetic."),
                    types.Part(inline_data=types.Blob(mime_type="image/png", data=args.ref.read_bytes())),
                ]
            )
        ],
        config=types.GenerateContentConfig(response_modalities=["image", "text"]),
    )

    for part in response.candidates[0].content.parts:
        if part.inline_data:
            output_path = DOWNLOADS / f"{args.output}_generated.png"
            output_path.write_bytes(part.inline_data.data)
            print(f"Generated: {output_path}")
