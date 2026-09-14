import ast
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]


def main():
    problems = []
    for directory in ["Scripts", "Tests"]:
        for source in (ROOT / directory).glob("*.py"):
            ast.parse(source.read_text(), filename=str(source))
    documents = [ROOT / name for name in ["README.md", "CONTRIBUTING.md", "SECURITY.md", "UPSTREAM.md", "CHANGELOG.md", "AGENTS.md"]]
    for name in ["ARCHITECTURE.md", "THREAT_MODEL.md", "INTEGRATIONS.md", "LEASE_PROTOCOL.md", "POWER_MANAGEMENT.md", "TESTING.md", "RELEASE.md"]:
        if not (ROOT / "Docs" / name).is_file():
            problems.append("Missing required documentation: Docs/" + name)
    documents.extend((ROOT / "Docs").glob("*.md"))
    for document in documents:
        text = document.read_text()
        links = re.findall(r"\]\(([^)]+)\)", text) + re.findall(r'<img[^>]+src="([^"]+)"', text)
        for link in links:
            parsed = urlsplit(link)
            if parsed.scheme or not parsed.path or link.startswith("#"):
                continue
            target = document.parent / unquote(parsed.path)
            if not target.exists():
                problems.append(f"Broken local link in {document.relative_to(ROOT)}: {link}")
    license_text = (ROOT / "LICENSE").read_text()
    if "Copyright (c) 2026 kageroumado" not in license_text or "MIT License" not in license_text:
        problems.append("Original MIT notice was lost")
    readme = (ROOT / "README.md").read_text()
    for retired in ["rx no. 006", "readme-typing-svg", "adrafinil/releases/latest", ".github/adrafinil-icon.png"]:
        if retired in readme:
            problems.append("Retired upstream branding/download in README: " + retired)
    project = (ROOT / "Adrafinil.xcodeproj/project.pbxproj").read_text()
    for expected in ["objectVersion = 77;", "preferredProjectObjectVersion = 77;", "path = WakeLeaseApp;", "path = WakeLease.app;", "PRODUCT_NAME = WakeLeaseDaemon;", "PRODUCT_NAME = WakeLeaseHelper;", "MACOSX_DEPLOYMENT_TARGET = 15.4;"]:
        if expected not in project:
            problems.append("Xcode product layout is missing: " + expected)
    for directory, role, filename in [("AdrafinilDaemon", "daemon", "LaunchAgent.plist"), ("AdrafinilHelper", "helper", "LaunchDaemon.plist")]:
        launch = plistlib.loads((ROOT / directory / filename).read_bytes())
        if launch["Label"] != "org.wakelease." + role or "WakeLease" not in launch["BundleProgram"]:
            problems.append("Wrong launch identity: " + directory)
        info = plistlib.loads((ROOT / directory / "Info.plist").read_bytes())
        if info["CFBundleIdentifier"] != "org.wakelease." + role or info["LSMinimumSystemVersion"] != "15.4":
            problems.append("Wrong embedded component metadata: " + directory)
    icons = ROOT / "WakeLeaseApp/Assets.xcassets/AppIcon.appiconset"
    for image in json.loads((icons / "Contents.json").read_text())["images"]:
        data = (icons / image["filename"]).read_bytes()
        expected = int(image["size"].split("x")[0]) * int(image["scale"].rstrip("x"))
        if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (expected, expected):
            problems.append("Wrong icon geometry: " + image["filename"])
    subprocess.run(["git", "diff", "--check"], cwd=ROOT, check=True)
    if problems:
        raise SystemExit("\n".join(problems))
    print(f"Repository checks passed: {len(documents)} documents, retained license, product identities, Python syntax and icon geometry.")


if __name__ == "__main__":
    main()
