import sounddevice as sd
import numpy as np
import mlx_whisper
import threading
import subprocess
import rumps
import logging
from pynput import keyboard
from pynput.keyboard import Controller, Key
from AppKit import NSEvent, NSWindow, NSView, NSColor, NSBezierPath, NSFont, NSString, NSMakeRect, NSObject
from AppKit import NSWindowStyleMaskBorderless, NSStatusWindowLevel
from PyObjCTools import AppHelper
from pathlib import Path
from datetime import datetime
import objc

HOTKEY = keyboard.Key.alt_r
SAMPLE_RATE = 16000
MODEL = "mlx-community/whisper-large-v3-mlx"
MIN_RECORD_SECONDS = 0.3
TRANSCRIPTS_DIR = Path.home() / ".dictate_transcripts"
ICONS_DIR = Path(__file__).parent / "icons" / "menubar"
LOG_FILE = Path(__file__).parent / "dictate.log"

LOG_FILE.parent.mkdir(exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("dictate")


class LoadingView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(LoadingView, self).initWithFrame_(frame)
        return self

    def drawRect_(self, rect):
        NSColor.clearColor().set()
        NSBezierPath.fillRect_(rect)

        NSColor.blackColor().colorWithAlphaComponent_(0.8).set()
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(rect, 8, 8)
        path.fill()

        attrs = {
            "NSFont": NSFont.systemFontOfSize_(14),
            "NSColor": NSColor.whiteColor()
        }
        text = NSString.stringWithString_("...")
        text.drawAtPoint_withAttributes_((12, 8), attrs)


class LoadingIndicator:
    def __init__(self):
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 44, 30),
            NSWindowStyleMaskBorderless,
            2,
            False
        )
        self.window.setLevel_(NSStatusWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.clearColor())
        self.window.setIgnoresMouseEvents_(True)
        self.window.setHasShadow_(True)

        self.view = LoadingView.alloc().initWithFrame_(NSMakeRect(0, 0, 44, 30))
        self.window.setContentView_(self.view)

    def show(self):
        def _show():
            pos = NSEvent.mouseLocation()
            self.window.setFrameOrigin_((pos.x + 10, pos.y - 40))
            self.window.orderFront_(None)
        AppHelper.callAfter(_show)

    def hide(self):
        AppHelper.callAfter(lambda: self.window.orderOut_(None))


class DictateApp(rumps.App):
    def __init__(self):
        super().__init__("", icon=str(ICONS_DIR / "loading.png"), quit_button=None, template=False)
        self.record_button = rumps.MenuItem("Start Recording", callback=self.toggle_recording)
        self.recent_menu = rumps.MenuItem("Recent Transcriptions")
        self.recent_transcriptions = []
        self.menu = [self.record_button, self.recent_menu, None, rumps.MenuItem("Quit", callback=self.quit_app)]
        self.recording = False
        self.audio_data = []
        self.typer = Controller()
        self.loading = LoadingIndicator()
        self.load_recent_transcriptions()

        mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), path_or_hf_repo=MODEL)
        self.icon = str(ICONS_DIR / "mic.png")

        self.stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype=np.float32, callback=self.audio_callback)
        self.stream.start()
        self.listener = keyboard.Listener(on_press=self.on_press, on_release=self.on_release)
        self.listener.start()

    def load_recent_transcriptions(self):
        if TRANSCRIPTS_DIR.exists():
            files = sorted(TRANSCRIPTS_DIR.glob("*.txt"), key=lambda f: f.stat().st_mtime, reverse=True)[:5]
            self.recent_transcriptions = [(f.stem, f.read_text()) for f in files]
        self.update_recent_menu()

    def update_recent_menu(self):
        self.recent_menu.clear()
        if not self.recent_transcriptions:
            self.recent_menu.add(rumps.MenuItem("No transcriptions yet", callback=None))
            return
        for timestamp, text in self.recent_transcriptions:
            preview = text[:50] + "..." if len(text) > 50 else text
            preview = preview.replace("\n", " ")
            item = rumps.MenuItem(preview, callback=lambda _, t=text: self.copy_transcription(t))
            self.recent_menu.add(item)

    def copy_transcription(self, text):
        subprocess.run(["pbcopy"], input=text.encode(), check=True)
        rumps.notification("Dictate", "Copied!", text[:100] + ("..." if len(text) > 100 else ""))

    def audio_callback(self, indata, frames, time, status):
        if self.recording:
            self.audio_data.append(indata.copy())

    def on_press(self, key):
        if key == HOTKEY and not self.recording:
            self.start_recording()

    def on_release(self, key):
        if key == HOTKEY and self.recording:
            self.stop_recording()

    def toggle_recording(self, _):
        if self.recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        self.audio_data = []
        self.recording = True
        self.icon = str(ICONS_DIR / "speaking.png")
        self.record_button.title = "Stop Recording"
        logger.info("Recording started")

    def stop_recording(self):
        self.recording = False
        self.icon = str(ICONS_DIR / "mic.png")
        self.record_button.title = "Start Recording"
        logger.info("Recording stopped")
        if self.audio_data:
            self.loading.show()
            threading.Thread(target=self.transcribe_and_paste, daemon=True).start()
        else:
            logger.info("Stop pressed but no audio captured")

    def transcribe_and_paste(self):
        if not self.audio_data:
            logger.info("Transcribe called with no audio data")
            self.loading.hide()
            return

        audio = np.concatenate(self.audio_data, axis=0).flatten().astype(np.float32)
        duration = len(audio) / SAMPLE_RATE
        logger.info(f"Audio captured: {len(audio)} samples ({duration:.2f}s)")
        if duration < MIN_RECORD_SECONDS:
            logger.info("Audio too short, skipping transcription")
            rumps.notification("Dictate", "Recording too short", "Hold Option+R a bit longer")
            self.loading.hide()
            return

        result = mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language="en")
        text = result["text"].strip()
        logger.info(f"Transcription returned {len(text)} characters")

        if text:
            TRANSCRIPTS_DIR.mkdir(exist_ok=True)
            timestamp = datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
            transcript_path = TRANSCRIPTS_DIR / f"{timestamp}.txt"
            transcript_path.write_text(text)
            subprocess.run(["pbcopy"], input=text.encode(), check=True)
            with self.typer.pressed(Key.cmd):
                self.typer.tap("v")
            self.recent_transcriptions.insert(0, (timestamp, text))
            self.recent_transcriptions = self.recent_transcriptions[:5]
            self.update_recent_menu()
            logger.info(f"Transcript saved to {transcript_path}")
        else:
            rumps.notification("Dictate", "No transcription result", "Try again or speak longer")
            logger.info("No text returned from transcription")

        self.loading.hide()

    def quit_app(self, _):
        self.stream.stop()
        self.listener.stop()
        rumps.quit_application()


if __name__ == "__main__":
    DictateApp().run()
