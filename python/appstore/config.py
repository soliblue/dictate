from pathlib import Path

APP_NAME = "Whisper"
BUNDLE_ID = "soli.whisper.Whisper"
VERSION = "1.0.0"

PROJECT_ROOT = Path(__file__).parent.parent.parent
WHISPER_APP_DIR = PROJECT_ROOT / "Whisper"
OUTPUT_DIR = PROJECT_ROOT / "python" / "appstore" / "output"
SCREENSHOTS_DIR = OUTPUT_DIR / "screenshots"
METADATA_DIR = OUTPUT_DIR / "metadata"

MACOS_SCREENSHOT_SIZES = [
    (2880, 1800),
    (2560, 1600),
    (1440, 900),
    (1280, 800),
]

SUPPORTED_LANGUAGES = [
    "en-US",
    "de-DE",
    "es-ES",
    "fr-FR",
    "ja",
    "zh-Hans",
]

APP_FEATURES = [
    "Hold Right Option key to start dictating",
    "On-device transcription with WhisperKit (large-v3 model)",
    "Auto-paste transcribed text to any app",
    "Multi-language support (14 languages)",
    "Recent transcriptions history",
    "Auto-send option (press Enter after paste)",
    "Visual feedback with screen glow effects",
    "Menu bar app - always accessible",
    "Privacy-focused - no data leaves your Mac",
]

APP_KEYWORDS = [
    "dictation",
    "transcription",
    "speech to text",
    "voice typing",
    "whisper",
    "AI",
    "offline",
    "privacy",
    "accessibility",
    "productivity",
]

CATEGORY = "Productivity"
SUBCATEGORY = "Utilities"

SCREENSHOT_SCENES = [
    {
        "name": "hero",
        "prompt": "macOS menu bar app called Whisper showing a microphone icon in the menu bar, with a floating glass panel in the center of the screen showing 'hold right ⌥ to dictate' text. Clean macOS desktop with subtle gradient background. Professional app screenshot style.",
    },
    {
        "name": "recording",
        "prompt": "macOS screen with a subtle blue glow border around the edges, indicating active recording. A small floating pill-shaped glass panel in the center shows a pulsing microphone icon. The screen has a code editor open showing where text will be pasted. Professional screenshot.",
    },
    {
        "name": "transcribing",
        "prompt": "macOS screen with a subtle purple glow border, showing transcription in progress. A floating panel with sparkle/ellipsis animation. A messaging app is visible in the background. Professional app screenshot demonstrating AI transcription.",
    },
    {
        "name": "languages",
        "prompt": "macOS menu bar dropdown showing language selection menu with options like Auto-detect, English, German, Spanish, French, Japanese, Chinese. Clean Apple-style menu design. Professional screenshot.",
    },
    {
        "name": "result",
        "prompt": "macOS screen showing a text editor or notes app with transcribed text that was just pasted. The text shows natural conversational content. Clean, professional app screenshot showing the result of voice dictation.",
    },
]

GEMINI_MODELS = {
    "fast": "gemini-2.5-flash-image",
    "pro": "gemini-3-pro-image-preview",
}
