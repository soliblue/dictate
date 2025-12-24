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
        "description": "Main hero shot showing the app's primary interface - the floating launcher panel with dictation prompt",
    },
    {
        "name": "recording",
        "description": "Active recording state with blue glow border and microphone icon, code editor in background",
    },
    {
        "name": "transcribing",
        "description": "Transcription in progress with purple glow border and sparkle animation, messaging app in background",
    },
    {
        "name": "languages",
        "description": "Language selection dropdown menu showing all 14 supported languages",
    },
    {
        "name": "result",
        "description": "Final result - transcribed text pasted into a notes or text editor app",
    },
]

DEFAULT_IMAGE_MODEL = "pro"

GEMINI_MODELS = {
    "text": "gemini-2.5-flash",
    "image": "gemini-3-pro-image-preview",
}
