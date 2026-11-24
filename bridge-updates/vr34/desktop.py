"""Explicit paired desktop session. Capture primary monitor and bounded input only."""
import base64
import ctypes
import io
import json
import sys
import threading
import time
from PIL import ImageGrab, Image

user32 = ctypes.windll.user32
user32.SetProcessDPIAware()
last_size = None
sequence = 0
keys = {"enter": 13, "backspace": 8, "escape": 27, "tab": 9, "left": 37, "up": 38, "right": 39, "down": 40}

_focus_lock = threading.Lock()
_focus_event = threading.Event()
_focus_token = None
_focus_result = {"focusKnown": False, "focusEditable": False}
_focus_worker_started = False


def editable_element(element, value_interface=None):
    """Read only editing capability, never field names, values or passwords."""
    if not element or not element.CurrentIsEnabled or not element.CurrentIsKeyboardFocusable:
        return False
    kind = int(element.CurrentControlType)
    if kind not in (50004, 50030):
        return False
    try:
        pattern = element.GetCurrentPattern(10002)
        if pattern and value_interface:
            return not bool(pattern.QueryInterface(value_interface).CurrentIsReadOnly)
    except Exception:
        pass
    return kind == 50004


def focused_editable():
    try:
        from pywinauto.uia_defines import IUIA
        uia = IUIA()
        return editable_element(uia.iuia.GetFocusedElement(), uia.ui_automation_client.IUIAutomationValuePattern)
    except Exception:
        return False


def _focus_loop():
    global _focus_result
    while True:
        _focus_event.wait()
        _focus_event.clear()
        with _focus_lock:
            token = _focus_token
        time.sleep(0.08)  # Let Windows finish changing focus after mouse-up.
        editable = focused_editable()
        with _focus_lock:
            if token == _focus_token:
                _focus_result = {"focusKnown": True, "focusEditable": editable, "focusToken": token}


def schedule_focus_check(token):
    global _focus_token, _focus_result, _focus_worker_started
    if not isinstance(token, str) or not 1 <= len(token) <= 64:
        return
    with _focus_lock:
        _focus_token = token
        _focus_result = {"focusKnown": False, "focusEditable": False, "focusToken": token}
        if not _focus_worker_started:
            _focus_worker_started = True
            threading.Thread(target=_focus_loop, name="jarvis-desktop-focus", daemon=True).start()
    _focus_event.set()


def focus_status():
    with _focus_lock:
        return dict(_focus_result)


def point(job):
    x, y = job.get("x"), job.get("y")
    if isinstance(x, bool) or isinstance(y, bool) or not isinstance(x, (int, float)) or not isinstance(y, (int, float)) or not 0 <= x <= 1 or not 0 <= y <= 1:
        raise ValueError("Invalid point")
    return round(x * (last_size[0] - 1)), round(y * (last_size[1] - 1))


class Keyboard(ctypes.Structure):
    _fields_ = [("virtual", ctypes.c_ushort), ("scan", ctypes.c_ushort), ("flags", ctypes.c_ulong), ("time", ctypes.c_ulong), ("extra", ctypes.c_size_t)]

class Mouse(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long), ("data", ctypes.c_ulong), ("flags", ctypes.c_ulong), ("time", ctypes.c_ulong), ("extra", ctypes.c_size_t)]

class Payload(ctypes.Union):
    _fields_ = [("keyboard", Keyboard), ("mouse", Mouse)]

class Input(ctypes.Structure):
    _fields_ = [("type", ctypes.c_ulong), ("payload", Payload)]

def execute(job):
    global last_size, sequence
    action = job.get("action")
    if action == "frame":
        image = ImageGrab.grab(all_screens=False)
        last_size = image.size
        image.thumbnail((1280, 800), Image.Resampling.BILINEAR)
        output = io.BytesIO()
        image.convert("RGB").save(output, format="JPEG", quality=65)
        data = output.getvalue()
        if len(data) > 240_000:
            raise ValueError("Desktop frame too large")
        sequence += 1
        return {"image": base64.b64encode(data).decode(), "width": image.width, "height": image.height, "sequence": sequence, **focus_status()}
    if last_size is None or type(job.get("sequence")) is not int or job.get("sequence") != sequence:
        raise ValueError("Desktop frame expired")
    if action == "click":
        user32.SetCursorPos(*point(job))
        user32.mouse_event(2, 0, 0, 0, 0)
        user32.mouse_event(4, 0, 0, 0, 0)
        schedule_focus_check(job.get("focusToken"))
    elif action == "scroll":
        delta = job.get("delta")
        if type(delta) is not int or abs(delta) > 5:
            raise ValueError("Invalid scroll")
        if "x" in job or "y" in job:
            user32.SetCursorPos(*point(job))
        user32.mouse_event(0x0800, 0, 0, ctypes.c_uint32(delta * 120), 0)
    elif action == "key" and job.get("key") in keys:
        key = keys[job["key"]]
        user32.keybd_event(key, 0, 0, 0)
        user32.keybd_event(key, 0, 2, 0)
    elif action == "text":
        text = job.get("text")
        if not isinstance(text, str) or not 1 <= len(text) <= 500:
            raise ValueError("Invalid text")
        encoded = text.encode("utf-16-le")
        events = []
        for index in range(0, len(encoded), 2):
            unit = int.from_bytes(encoded[index:index + 2], "little")
            events.extend([Input(1, Payload(keyboard=Keyboard(0, unit, 4, 0, 0))), Input(1, Payload(keyboard=Keyboard(0, unit, 6, 0, 0)))])
        array = (Input * len(events))(*events)
        if user32.SendInput(len(events), array, ctypes.sizeof(Input)) != len(events):
            raise OSError("Input was blocked")
    else:
        raise ValueError("Invalid desktop action")
    return {"applied": True, "sequence": sequence}

if __name__ == "__main__":
    for line in sys.stdin:
        if len(line) > 4096:
            break
        try:
            job = json.loads(line)
            result = execute(job)
            print(json.dumps({"ok": True, **result}), flush=True)
        except Exception:
            print(json.dumps({"ok": False, "message": "Não consegui capturar ou controlar a área de trabalho. Confira se o Windows está desbloqueado."}), flush=True)
