import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from PIL import Image

spec = importlib.util.spec_from_file_location("desktop", Path(__file__).parents[1] / "server/desktop.py")
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)

class DesktopTests(unittest.TestCase):
    def setUp(self):
        desktop.last_size = None
        desktop.sequence = 0
        self.os = patch.object(desktop, "user32", Mock()).start()
        self.focus = patch.object(desktop, "schedule_focus_check", Mock()).start()
        self.addCleanup(patch.stopall)

    def frame(self):
        with patch.object(desktop.ImageGrab, "grab", return_value=Image.new("RGB", (1920, 1080), "blue")):
            return desktop.execute({"action": "frame"})

    def test_frame_and_primary_monitor_coordinates(self):
        frame = self.frame()
        self.assertEqual(frame["width"], 1280)
        self.assertEqual(frame["height"], 720)
        desktop.execute({"action": "click", "x": .5, "y": .5, "sequence": frame["sequence"]})
        self.os.SetCursorPos.assert_called_once_with(960, 540)
        self.assertEqual(self.os.mouse_event.call_count, 2)

    def test_stale_or_outside_click_never_reaches_os(self):
        frame = self.frame()
        for job in [{"x": -1, "y": .5, "sequence": frame["sequence"]}, {"x": .5, "y": .5, "sequence": 0}, {"x": .5, "y": .5, "sequence": True}, {"x": True, "y": .5, "sequence": frame["sequence"]}]:
            with self.assertRaises(ValueError):
                desktop.execute({"action": "click", **job})
        self.os.SetCursorPos.assert_not_called()

    def test_unicode_typing_and_invalid_actions(self):
        frame = self.frame()
        self.os.SendInput.side_effect = lambda count, events, size: count
        desktop.execute({"action": "text", "text": "olá", "sequence": frame["sequence"]})
        self.assertEqual(self.os.SendInput.call_args.args[0], 6)
        with self.assertRaises(ValueError):
            desktop.execute({"action": "shell", "sequence": frame["sequence"]})

    def test_scroll_positions_pointer_and_never_clicks(self):
        frame = self.frame()
        desktop.execute({"action": "scroll", "x": .25, "y": .75, "delta": -2, "sequence": frame["sequence"]})
        self.os.SetCursorPos.assert_called_once_with(480, 809)
        self.assertEqual(self.os.mouse_event.call_count, 1)
        self.assertEqual(self.os.mouse_event.call_args.args[0], 0x0800)
        self.focus.assert_not_called()

    def test_invalid_scroll_does_not_move_pointer(self):
        frame = self.frame()
        for job in [{"delta": True}, {"delta": 6}, {"delta": 2, "x": -1, "y": .5}]:
            with self.assertRaises(ValueError):
                desktop.execute({"action": "scroll", "sequence": frame["sequence"], **job})
        self.os.SetCursorPos.assert_not_called()
        self.os.mouse_event.assert_not_called()

    def test_focus_token_scheduled_after_click_without_reading_text(self):
        frame = self.frame()
        desktop.execute({"action": "click", "x": .5, "y": .5, "focusToken": "test-token", "sequence": frame["sequence"]})
        self.focus.assert_called_once_with("test-token")
        element = Mock(CurrentIsEnabled=True, CurrentIsKeyboardFocusable=True, CurrentControlType=50004)
        element.GetCurrentPattern.side_effect = RuntimeError("Pattern not exposed")
        self.assertTrue(desktop.editable_element(element))
        element.CurrentControlType = 50000
        self.assertFalse(desktop.editable_element(element))
        element.CurrentControlType = 50004
        element.CurrentIsEnabled = False
        self.assertFalse(desktop.editable_element(element))

    def test_readonly_field_does_not_open_keyboard(self):
        element = Mock(CurrentIsEnabled=True, CurrentIsKeyboardFocusable=True, CurrentControlType=50004)
        element.GetCurrentPattern.return_value.QueryInterface.return_value.CurrentIsReadOnly = True
        self.assertFalse(desktop.editable_element(element, object()))
