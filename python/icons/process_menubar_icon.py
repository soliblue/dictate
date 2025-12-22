from PIL import Image
from pathlib import Path
import argparse

MENUBAR_SIZE = 44

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    img = Image.open(args.input).convert("RGBA")

    width, height = img.size
    max_dim = max(width, height)
    square = Image.new("RGBA", (max_dim, max_dim), (0, 0, 0, 0))
    square.paste(img, ((max_dim - width) // 2, (max_dim - height) // 2))

    square = square.resize((MENUBAR_SIZE, MENUBAR_SIZE), Image.LANCZOS)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    square.save(args.output)
    print(f"Saved: {args.output}")
