import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[1]
TOOLS = {
    "swiftformat": ("nicklockwood/SwiftFormat", "0.63.0", "swiftformat.zip", "28c7802e11fa5ae113d903066439c6bb1be20a8ac1ad9709c42616a7e273fb0f"),
    "swiftlint": ("realm/SwiftLint", "0.65.1", "portable_swiftlint.zip", "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"),
}


def tool(name):
    repository, version, archive, checksum = TOOLS[name]
    directory = ROOT / ".build/tools"
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / archive
    if not archive.exists():
        subprocess.run(["gh", "release", "download", version, "--repo", repository, "--pattern", archive.name, "--dir", str(directory)], check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise SystemExit("Tool archive checksum mismatch: " + archive.name)
    with zipfile.ZipFile(archive) as contents:
        data = contents.read(name)
    executable = directory / name
    if executable.exists() and executable.read_bytes() != data:
        raise SystemExit("Existing tool differs from the pinned archive: " + name)
    if not executable.exists():
        executable.write_bytes(data)
        executable.chmod(0o755)
    return executable


def main():
    parser = argparse.ArgumentParser(description="Use pinned, checksum-verified formatting tools without a global installation.")
    parser.add_argument("--bootstrap-only", action="store_true")
    parser.add_argument("--format", action="store_true")
    args = parser.parse_args()
    formatter, linter = tool("swiftformat"), tool("swiftlint")
    if args.bootstrap_only:
        return
    formatting = [str(formatter), "."]
    if args.format:
        formatting.extend(["--header", "ignore", "--disable", "blockComments,wrapSingleLineComments"])
    else:
        formatting.append("--lint")
    result = subprocess.run(formatting, cwd=ROOT)
    environment = dict(os.environ)
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    if (developer / "usr/lib/sourcekitdInProc.framework/Versions/A/sourcekitdInProc").is_file():
        environment.setdefault("XCODE_DEFAULT_TOOLCHAIN_OVERRIDE", str(developer))
    lint = subprocess.run([str(linter), "lint", "--quiet"], cwd=ROOT, env=environment)
    raise SystemExit(result.returncode or lint.returncode)


if __name__ == "__main__":
    main()
