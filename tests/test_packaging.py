"""Exercise the package payload without compiling libmdr or requiring root."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PackageTest(unittest.TestCase):
    def test_staged_package_uses_bluez_mpris_service(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            pkg = Path(tmp) / "pkg"
            checkout = src / "mdrctl"
            shutil.copytree(ROOT / "daemon", checkout / "daemon")
            for name in ("LICENSE", "README.md"):
                shutil.copy2(ROOT / name, checkout / name)
            # package() copies the built libraries; their contents are irrelevant
            # to the file ownership conflict that previously blocked installation.
            for name in ("libmdr", "libmdr-bt"):
                library = src / "build" / name / "src" / f"{name}-shared.so"
                library.parent.mkdir(parents=True)
                library.touch()
            subprocess.run(
                ["bash", "-eu", "-c",
                 'source "$1"; srcdir="$2"; pkgdir="$3"; package',
                 "package-test", str(ROOT / "PKGBUILD"), str(src), str(pkg)],
                check=True, capture_output=True, text=True,
            )
            units = pkg / "usr/lib/systemd/user"
            self.assertEqual(
                (pkg / "usr/lib/mdrctl/mdr.py").read_bytes(),
                (ROOT / "daemon/lib/mdr.py").read_bytes(),
                "the package must include the connection fix, not the old tag's binding",
            )
            self.assertEqual(
                sorted(path.name for path in units.iterdir()),
                ["mdrctld.service"],
                "mpris-proxy.service belongs to the bluez-utils dependency",
            )
            unit = (units / "mdrctld.service").read_text()
            self.assertIn("ExecStart=/usr/bin/python3 /usr/bin/mdrctld", unit)
            for token in ("@PYTHON@", "@MDRCTLD@", "@ARGS@"):
                self.assertNotIn(token, unit)
            for executable in ("mdrctl", "mdrctld"):
                self.assertTrue((pkg / "usr/bin" / executable).stat().st_mode & 0o111)
