"""Exercise the embedded helper with real pipes and simulated Wayland events."""
import os
from pathlib import Path
import struct
import unittest


source = (Path(__file__).resolve().parents[1] / "main.lua").read_text()
helper = source.split("HELPER = [==[\n", 1)[1].split("\n]==]", 1)[0]
namespace = {}
exec(compile(helper.rsplit("\ntry:\n    sys.exit(main(*sys.argv[1:]))", 1)[0],
             "<embedded-helper>", "exec"), namespace)
Clipboard = namespace["Clipboard"]
Superseded = namespace["Superseded"]
OWNER = namespace["OWNER_TYPE"]
GNOME = "x-special/gnome-copied-files"
EXPECTED = {GNOME: "cut\nfile:///old.txt"}


class Transport(Clipboard):
    """Keep offer/clear/receive intact; replace compositor socket operations."""

    def __init__(self, *, change_before=False, change_during_read=False, marker=b"1234"):
        self.selection = 10
        self.offers = {10: [OWNER, GNOME], 20: ["text/plain"]}
        self.manager, self.device = 3, 4
        self.pending = change_before
        self.change_during_read = change_during_read
        self.marker = marker
        self.selection_writes = []

    def new(self, handler):
        return 5

    def roundtrip(self):
        if self.pending:
            self.selection = 20
            self.pending = False

    def send(self, obj, opcode, *args, fd=None):
        if fd is not None:
            mime = namespace["Reader"](b"".join(args)).string()
            payload = self.marker if mime == OWNER else EXPECTED[GNOME].encode()
            # The old source accepted the request; its pipe data may arrive
            # after another app takes ownership and queues a selection event.
            if self.change_during_read:
                self.pending = True
            os.write(fd, payload)
        elif obj == self.device and opcode == 0:
            self.selection_writes.append(struct.unpack("=I", args[0])[0])


class OwnershipTests(unittest.TestCase):
    def test_passive_update_with_same_owner(self):
        clipboard = Transport()
        clipboard.offer([["text/plain", "updated"]], owner="1234")
        self.assertEqual(clipboard.selection_writes, [5])

    def test_passive_update_rejects_replacement(self):
        for timing in ("change_before", "change_during_read"):
            with self.subTest(timing=timing):
                clipboard = Transport(**{timing: True})
                with self.assertRaises(Superseded):
                    clipboard.offer([["text/plain", "updated"]], owner="1234")
                self.assertEqual(clipboard.selection_writes, [])

    def test_passive_update_rejects_different_or_empty_marker(self):
        for marker in (b"5678", b""):
            with self.subTest(marker=marker):
                clipboard = Transport(marker=marker)
                with self.assertRaises(Superseded):
                    clipboard.offer([["text/plain", "updated"]], owner="1234")
                self.assertEqual(clipboard.selection_writes, [])

    def test_active_yank_can_take_ownership(self):
        clipboard = Transport(change_before=True)
        clipboard.offer([["text/plain", "updated"]])
        self.assertEqual(clipboard.selection_writes, [5])

    def test_clear_preserves_replacements(self):
        for timing in ("change_before", "change_during_read"):
            with self.subTest(timing=timing):
                clipboard = Transport(**{timing: True})
                clipboard.roundtrip()
                clipboard.clear(EXPECTED)
                self.assertEqual(clipboard.selection_writes, [])

    def test_clear_unchanged_cut(self):
        clipboard = Transport()
        clipboard.clear(EXPECTED)
        self.assertEqual(clipboard.selection_writes, [0])


if __name__ == "__main__":
    unittest.main()
