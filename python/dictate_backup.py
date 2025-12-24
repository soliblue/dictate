import sounddevice as sd
import numpy as np
import mlx_whisper
import threading
import subprocess
import rumps
import logging
import queue
import time
import math
import objc
from pynput import keyboard
from pynput.keyboard import Controller, Key
from AppKit import NSWorkspace, NSWindow, NSView, NSScreen, NSColor, NSBezierPath, NSMakeRect, NSApplication
from AppKit import NSWindowStyleMaskBorderless, NSWindowCollectionBehaviorFullScreenAuxiliary, NSWindowCollectionBehaviorIgnoresCycle, NSWindowCollectionBehaviorMoveToActiveSpace, NSWorkspaceActiveSpaceDidChangeNotification
from AppKit import NSBeep, NSFont, NSForegroundColorAttributeName, NSFontAttributeName, NSMakePoint
from Quartz import CGShieldingWindowLevel
from pathlib import Path
from datetime import datetime
from Foundation import NSObject, NSString
from PyObjCTools import AppHelper

HOTKEY = keyboard.Key.alt_r
SAMPLE_RATE = 16000
MODEL = "mlx-community/whisper-large-v3-mlx"
MIN_RECORD_SECONDS = 0.3
TRANSCRIPTS_DIR = Path.home() / ".dictate_transcripts"
ICONS_DIR = Path(__file__).parent / "icons" / "menubar"
LOG_FILE = Path(__file__).parent / "dictate.log"
ENABLE_GLOW = True
ENABLE_TOAST = True
ENABLE_NOTIFICATIONS = True
ENABLE_BEEP = True
TOAST_SIZE = 140
TOAST_DURATION_SECONDS = 0.7

LOG_FILE.parent.mkdir(exist_ok=True)
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("dictate")


CORNER_SIZE = 60

class CornerView(NSView):
    def initWithFrame_corner_(self, frame, corner):
        self = objc.super(CornerView, self).initWithFrame_(frame)
        self.corner = corner
        self.intensity = 0.8
        return self

    def setIntensity_(self, value):
        self.intensity = value
        self.setNeedsDisplay_(True)

    def drawRect_(self, rect):
        NSColor.clearColor().set()
        NSBezierPath.fillRect_(rect)
        size = rect.size.width
        for i in range(int(size)):
            progress = i / size
            alpha = self.intensity * (1 - progress) * 0.8
            NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.8 - progress * 0.3, 0.6 - progress * 0.4, alpha).set()
            if self.corner == 0:
                NSBezierPath.fillRect_(NSMakeRect(0, size - 1 - i, size - i, 1))
                NSBezierPath.fillRect_(NSMakeRect(0, 0, 1, size - i))
            elif self.corner == 1:
                NSBezierPath.fillRect_(NSMakeRect(i, size - 1 - i, size - i, 1))
                NSBezierPath.fillRect_(NSMakeRect(size - 1, 0, 1, size - i))
            elif self.corner == 2:
                NSBezierPath.fillRect_(NSMakeRect(0, i, size - i, 1))
                NSBezierPath.fillRect_(NSMakeRect(0, i, 1, size - i))
            else:
                NSBezierPath.fillRect_(NSMakeRect(i, i, size - i, 1))
                NSBezierPath.fillRect_(NSMakeRect(size - 1, i, 1, size - i))


class ToastView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(ToastView, self).initWithFrame_(frame)
        self.alpha = 0.85
        return self

    def drawRect_(self, rect):
        NSColor.clearColor().set()
        NSBezierPath.fillRect_(rect)
        inset = 12
        w = rect.size.width - (inset * 2)
        h = rect.size.height - (inset * 2)
        bg = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(inset, inset, w, h), 20, 20
        )
        NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.2, 0.2, self.alpha).set()
        bg.fill()
        text = NSString.stringWithString_("REC")
        attrs = {
            NSFontAttributeName: NSFont.boldSystemFontOfSize_(36),
            NSForegroundColorAttributeName: NSColor.whiteColor(),
        }
        size = text.sizeWithAttributes_(attrs)
        text.drawAtPoint_withAttributes_(
            NSMakePoint((rect.size.width - size.width) / 2, (rect.size.height - size.height) / 2),
            attrs,
        )


class ScreenToast:
    def __init__(self):
        self.windows = []
        self.behavior = (
            NSWindowCollectionBehaviorMoveToActiveSpace |
            NSWindowCollectionBehaviorFullScreenAuxiliary |
            NSWindowCollectionBehaviorIgnoresCycle
        )

    def show(self):
        self.build_windows()
        for window in self.windows:
            window.orderFrontRegardless()
        threading.Timer(
            TOAST_DURATION_SECONDS,
            lambda: AppHelper.callAfter(self.hide),
        ).start()

    def hide(self):
        for window in self.windows:
            window.orderOut_(None)
            window.close()
        self.windows = []

    def build_windows(self):
        self.hide()
        for screen in NSScreen.screens():
            sf = screen.frame()
            x = sf.origin.x + (sf.size.width - TOAST_SIZE) / 2
            y = sf.origin.y + (sf.size.height - TOAST_SIZE) / 2
            window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                NSMakeRect(x, y, TOAST_SIZE, TOAST_SIZE), NSWindowStyleMaskBorderless, 2, False
            )
            window.setLevel_(CGShieldingWindowLevel())
            window.setOpaque_(False)
            window.setBackgroundColor_(NSColor.clearColor())
            window.setIgnoresMouseEvents_(True)
            window.setHasShadow_(False)
            window.setCollectionBehavior_(self.behavior)
            window.setCanHide_(False)
            window.setHidesOnDeactivate_(False)
            window.setContentView_(ToastView.alloc().initWithFrame_(NSMakeRect(0, 0, TOAST_SIZE, TOAST_SIZE)))
            self.windows.append(window)


class SpaceObserver(NSObject):
    def initWithGlow_(self, glow):
        self = objc.super(SpaceObserver, self).init()
        if self is None:
            return None
        self.glow = glow
        return self

    def spaceDidChange_(self, notification):
        if self.glow.animating:
            self.glow.rebuild()


class ScreenGlow:
    def __init__(self):
        self.windows = []
        self.views = []
        self.animating = False
        self.phase = 0.0
        self.behavior = (
            NSWindowCollectionBehaviorMoveToActiveSpace |
            NSWindowCollectionBehaviorFullScreenAuxiliary |
            NSWindowCollectionBehaviorIgnoresCycle
        )
        self.build_windows()
        self.space_observer = SpaceObserver.alloc().initWithGlow_(self)
        NSWorkspace.sharedWorkspace().notificationCenter().addObserver_selector_name_object_(
            self.space_observer,
            "spaceDidChange:",
            NSWorkspaceActiveSpaceDidChangeNotification,
            None,
        )

    def build_windows(self):
        self.clear_windows()
        for screen in NSScreen.screens():
            sf = screen.frame()
            corners = [
                (sf.origin.x, sf.origin.y + sf.size.height - CORNER_SIZE, 0),
                (sf.origin.x + sf.size.width - CORNER_SIZE, sf.origin.y + sf.size.height - CORNER_SIZE, 1),
                (sf.origin.x, sf.origin.y, 2),
                (sf.origin.x + sf.size.width - CORNER_SIZE, sf.origin.y, 3),
            ]
            for x, y, corner in corners:
                window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                    NSMakeRect(x, y, CORNER_SIZE, CORNER_SIZE), NSWindowStyleMaskBorderless, 2, False
                )
                window.setLevel_(CGShieldingWindowLevel())
                window.setOpaque_(False)
                window.setBackgroundColor_(NSColor.clearColor())
                window.setIgnoresMouseEvents_(True)
                window.setHasShadow_(False)
                window.setCollectionBehavior_(self.behavior)
                window.setCanHide_(False)
                window.setHidesOnDeactivate_(False)
                view = CornerView.alloc().initWithFrame_corner_(NSMakeRect(0, 0, CORNER_SIZE, CORNER_SIZE), corner)
                window.setContentView_(view)
                self.windows.append(window)
                self.views.append(view)

    def clear_windows(self):
        for window in self.windows:
            window.orderOut_(None)
            window.close()
        self.windows = []
        self.views = []

    def show(self):
        if self.animating:
            self.rebuild()
            return
        self.rebuild()
        self.animating = True
        threading.Thread(target=self.animate, daemon=True).start()

    def hide(self):
        self.animating = False
        for window in self.windows:
            window.orderOut_(None)

    def rebuild(self):
        self.build_windows()
        self.refresh()

    def refresh(self):
        for window in self.windows:
            window.orderFrontRegardless()

    def animate(self):
        while self.animating:
            t = self.phase
            beat = (math.sin(t * 4) ** 8 + math.sin(t * 4 + 0.3) ** 8) * 0.5
            intensity = 0.5 + beat * 0.5
            for view in self.views:
                view.setIntensity_(intensity)
            self.phase += 0.15
            time.sleep(0.03)


class DictateApp(rumps.App):
    def __init__(self):
        super().__init__("", icon=str(ICONS_DIR / "loading.png"), quit_button=None, template=False)
        self.record_button = rumps.MenuItem("Start Recording", callback=self.toggle_recording)
        self.menu = [self.record_button, None, rumps.MenuItem("Quit", callback=self.quit_app)]
        self.recording = False
        self.audio_data = []
        self.typer = Controller()
        self.source_app = None
        self.glow = ScreenGlow()
        self.toast = ScreenToast()
        self.blink_timer = rumps.Timer(self.blink_icon, 0.5)
        self.blink_state = False
        self.work_queue = queue.Queue()
        threading.Thread(target=self.transcription_worker, daemon=True).start()
        self.work_queue.put(("warmup",))

        self.stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype=np.float32, callback=self.audio_callback)
        self.stream.start()
        self.listener = keyboard.Listener(on_press=self.on_press, on_release=self.on_release)
        self.listener.start()

    def transcription_worker(self):
        while True:
            task = self.work_queue.get()
            if task[0] == "warmup":
                mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), path_or_hf_repo=MODEL)
                self.icon = str(ICONS_DIR / "mic.png")
            elif task[0] == "transcribe":
                self.do_transcription()

    def audio_callback(self, indata, frames, time_info, status):
        if self.recording:
            self.audio_data.append(indata.copy())

    def on_press(self, key):
        if key == HOTKEY and not self.recording:
            AppHelper.callAfter(self.start_recording)

    def on_release(self, key):
        if key == HOTKEY and self.recording:
            AppHelper.callAfter(self.stop_recording)

    def toggle_recording(self, _):
        if self.recording:
            self.stop_recording()
        else:
            self.start_recording()

    def start_recording(self):
        self.audio_data = []
        self.source_app = NSWorkspace.sharedWorkspace().frontmostApplication()
        self.recording = True
        self.icon = str(ICONS_DIR / "speaking.png")
        self.record_button.title = "Stop Recording"
        self.blink_timer.start()
        if ENABLE_GLOW:
            self.glow.show()
        if ENABLE_TOAST:
            self.toast.show()
        if ENABLE_NOTIFICATIONS:
            rumps.notification("Dictate", "Recording", "Recording started", sound=False)
        if ENABLE_BEEP:
            NSBeep()
        logger.info("Recording started")

    def stop_recording(self):
        self.recording = False
        self.blink_timer.stop()
        self.blink_state = False
        self.icon = str(ICONS_DIR / "mic.png")
        self.record_button.title = "Start Recording"
        if ENABLE_GLOW:
            self.glow.hide()
        if ENABLE_TOAST:
            self.toast.hide()
        if ENABLE_NOTIFICATIONS:
            rumps.notification("Dictate", "Recording", "Recording stopped", sound=False)
        if ENABLE_BEEP:
            NSBeep()
        logger.info("Recording stopped")
        if self.audio_data:
            self.work_queue.put(("transcribe",))

    def blink_icon(self, _):
        if not self.recording:
            return
        self.blink_state = not self.blink_state
        icon = "speaking.png" if self.blink_state else "mic.png"
        self.icon = str(ICONS_DIR / icon)

    def paste_text(self, text):
        if self.source_app:
            self.source_app.activateWithOptions_(2)
            time.sleep(0.05)
        subprocess.run(["pbcopy"], input=text.encode(), check=True)
        with self.typer.pressed(Key.cmd):
            self.typer.tap("v")

    def do_transcription(self):
        if not self.audio_data:
            return

        audio = np.concatenate(self.audio_data, axis=0).flatten().astype(np.float32)
        duration = len(audio) / SAMPLE_RATE
        logger.info(f"Audio captured: {len(audio)} samples ({duration:.2f}s)")

        if duration < MIN_RECORD_SECONDS:
            logger.info("Audio too short")
            rumps.notification("Dictate", "Recording too short", "Hold Option+R a bit longer")
            return

        result = mlx_whisper.transcribe(audio, path_or_hf_repo=MODEL, language="en")
        text = result["text"].strip()
        logger.info(f"Transcription: {len(text)} chars")

        if text:
            self.paste_text(text)
            TRANSCRIPTS_DIR.mkdir(exist_ok=True)
            (TRANSCRIPTS_DIR / f"{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.txt").write_text(text)
        else:
            rumps.notification("Dictate", "No transcription", "Try again")

        self.source_app = None

    def quit_app(self, _):
        self.stream.stop()
        self.listener.stop()
        rumps.quit_application()


if __name__ == "__main__":
    DictateApp().run()
