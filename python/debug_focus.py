import time
from datetime import datetime
from pathlib import Path
from AppKit import NSWorkspace
import Quartz

LOG_FILE = Path(__file__).parent / "focus_debug.log"

def get_frontmost_window():
    options = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    window_list = Quartz.CGWindowListCopyWindowInfo(options, Quartz.kCGNullWindowID)

    for window in window_list:
        if window.get(Quartz.kCGWindowLayer, 0) == 0:
            return {
                "owner": window.get(Quartz.kCGWindowOwnerName, ""),
                "name": window.get(Quartz.kCGWindowName, ""),
                "id": window.get(Quartz.kCGWindowNumber, 0),
                "pid": window.get(Quartz.kCGWindowOwnerPID, 0),
                "bounds": window.get(Quartz.kCGWindowBounds, {}),
            }
    return None

def get_focus_info():
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    window = get_frontmost_window()

    return {
        "app_name": app.localizedName(),
        "app_bundle": app.bundleIdentifier(),
        "app_pid": app.processIdentifier(),
        "window": window,
    }

if __name__ == "__main__":
    print(f"Logging focus info to: {LOG_FILE}")
    print("Click around different windows/tabs. Press Ctrl+C to stop.\n")

    last_info = None

    with open(LOG_FILE, "w") as f:
        f.write(f"Focus Debug Log - {datetime.now()}\n{'='*60}\n\n")

        while True:
            info = get_focus_info()
            info_str = str(info)

            if info_str != last_info:
                timestamp = datetime.now().strftime("%H:%M:%S")
                line = f"[{timestamp}] App: {info['app_name']} ({info['app_bundle']})\n"
                if info['window']:
                    line += f"           Window: {info['window']['name']!r} (id={info['window']['id']})\n"
                    line += f"           Bounds: {info['window']['bounds']}\n"
                line += "\n"

                print(line)
                f.write(line)
                f.flush()
                last_info = info_str

            time.sleep(0.2)
