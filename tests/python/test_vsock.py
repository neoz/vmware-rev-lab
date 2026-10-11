import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "mcp"))
import vsock  # noqa: E402

CATALOG = """
Winsock Catalog Provider Entry
------------------------------------------------------
Entry Type:                         Base Service Provider
Description:                        Hyper-V RAW
Address Family:                     34

Winsock Catalog Provider Entry
------------------------------------------------------
Entry Type:                         Base Service Provider
Description:                        vSockets STREAM
Provider Path:                      %windir%\\system32\\vsocklib.dll
Address Family:                     28
"""


class ParseAfTests(unittest.TestCase):
    def test_finds_vsockets_stream(self):
        self.assertEqual(vsock.parse_af(CATALOG), 28)

    def test_missing_provider_names_the_problem(self):
        with self.assertRaisesRegex(OSError, "vSockets STREAM provider not found"):
            vsock.parse_af("Description: Hyper-V RAW\nAddress Family: 34\n")


if __name__ == "__main__":
    unittest.main()
