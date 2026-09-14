import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "@earendil-works/pi-coding-agent@0.83.0"
INTEGRITY = "sha512-uYhF+FsZxogoSX/AxBcUdiY+ZklubwaXyAoEGA2eQwsHcyEAhUYIKh/WLXe/a8+k8eTCmxb+ZN2Zo9mzQtzbWw=="


def main():
    build = ROOT / ".build"
    build.mkdir(exist_ok=True)
    destination = build / "pi-host"
    with tempfile.TemporaryDirectory(prefix="host-fixture-", dir=build) as temporary:
        result = subprocess.run(["npm", "pack", PACKAGE, "--json", "--ignore-scripts", "--pack-destination", temporary], cwd=ROOT,
                                check=True, capture_output=True, text=True)
        entry = json.loads(result.stdout)[0]
        filename = entry["filename"]
        if Path(filename).name != filename:
            raise SystemExit("Unsafe fixture archive name")
        archive = Path(temporary) / filename
        digest = "sha512-" + base64.b64encode(hashlib.sha512(archive.read_bytes()).digest()).decode()
        if digest != INTEGRITY:
            raise SystemExit("Pinned Pi fixture archive checksum did not match")
        subprocess.run(["npm", "install", "--prefix", str(destination), "--no-save", "--package-lock=false", "--ignore-scripts",
                        "--no-audit", "--no-fund", "--before=2026-09-07", str(archive)], cwd=ROOT, check=True)
    installed = json.loads((destination / "node_modules/@earendil-works/pi-coding-agent/package.json").read_text())
    if installed["version"] != "0.83.0":
        raise SystemExit("Unexpected Pi fixture version")
    print("Pinned Pi 0.83.0 host fixture installed; package scripts were disabled. This is not a product dependency.")


if __name__ == "__main__":
    main()
