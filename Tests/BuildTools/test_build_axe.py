"""Check build isolation without running any upstream build or cleanup command."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class BuildIsolationTests(unittest.TestCase):
    def test_inherited_configuration_cannot_redirect_upstream_cleanup(self):
        script = Path(__file__).resolve().parents[2] / "scripts/build-axe.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            shutil.copy2(script, root / "scripts/build-axe.sh")
            mocks = root / "mocks"
            mocks.mkdir()
            capture = root / "captured.json"
            keys = ["AXE_ENV_FILE", "IDB_CHECKOUT_DIR", "IDB_GIT_URL", "IDB_GIT_REF",
                    "IDB_UPSTREAM_BASE_REF", "BUILD_OUTPUT_DIR", "DERIVED_DATA_PATH",
                    "BUILD_XCFRAMEWORK_DIR", "TEMP_DIR"]
            mock = f'''#!{sys.executable}
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "git" and args[0] == "clone":
    pathlib.Path(args[-1], ".git").mkdir(parents=True)
elif name == "git" and "rev-parse" in args:
    print("30f4bfa9bc81817906a60fadedbc913d7314b7e1" if pathlib.Path(args[1]).name == "source" else "604c51013438f0c3603b720a05a44b7c5b8f286d")
elif name == "xcrun":
    print("/mock/toolchain")
elif name == "swiftc":
    print("mock compiler")
elif name == "bash":
    pathlib.Path({str(capture)!r}).write_text(json.dumps({{key: os.environ.get(key) for key in {keys!r}}}))
    assert args == ["scripts/build.sh", "clean"], args
    sys.exit(99)
'''
            for name in ["git", "xcodegen", "xcrun", "swiftc", "bash"]:
                path = mocks / name
                path.write_text(mock)
                path.chmod(0o755)
            outside = root / "must-survive"
            outside.mkdir()
            marker = outside / "marker"
            marker.write_text("unchanged")
            environment = dict(os.environ, PATH=f"{mocks}:/usr/bin:/bin")
            environment.update({key: str(outside) for key in keys})
            result = subprocess.run(["/bin/bash", str(root / "scripts/build-axe.sh")],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 99, result.stderr)
            actual = json.loads(capture.read_text())
            tool = root / ".build/tools/axe"
            self.assertEqual(actual, {
                "AXE_ENV_FILE": "/dev/null",
                "IDB_CHECKOUT_DIR": str(tool / "idb"),
                "IDB_GIT_URL": "https://github.com/cameroncooke/idb.git",
                "IDB_GIT_REF": "604c51013438f0c3603b720a05a44b7c5b8f286d",
                "IDB_UPSTREAM_BASE_REF": "e682506725e9efefb9c43b8b917c0b12eb2a5939",
                "BUILD_OUTPUT_DIR": str(tool / "source/build_products"),
                "DERIVED_DATA_PATH": str(tool / "source/build_derived_data"),
                "BUILD_XCFRAMEWORK_DIR": str(tool / "source/build_products/XCFrameworks"),
                "TEMP_DIR": str(tool / "tmp"),
            })
            self.assertEqual(marker.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
