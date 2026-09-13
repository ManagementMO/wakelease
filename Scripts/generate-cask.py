import argparse
import re
from urllib.parse import urlsplit


def url(value):
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or any(ord(char) < 32 for char in value):
        raise argparse.ArgumentTypeError("Use a public HTTPS URL without embedded credentials or control characters")
    return value


def quote(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def main():
    parser = argparse.ArgumentParser(description="Print a reviewable Homebrew cask only after real release URLs/checksums exist.")
    parser.add_argument("--url", required=True, type=url)
    parser.add_argument("--homepage", required=True, type=url)
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--arch", required=True, choices=["arm64", "x86_64", "universal"])
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.version):
        parser.error("Use a semantic release version")
    if not re.fullmatch(r"[a-fA-F0-9]{64}", args.sha256):
        parser.error("--sha256 must be the actual archive's SHA-256")
    lines = [
        'cask "wakelease" do',
        "  version " + quote(args.version),
        "  sha256 " + quote(args.sha256.lower()),
        "", "  url " + quote(args.url),
        '  name "WakeLease"',
        '  desc "Work-scoped wake leases for local jobs"',
        "  homepage " + quote(args.homepage),
        "", "  depends_on macos: :sequoia",
    ]
    if args.arch != "universal":
        lines.append("  depends_on arch: :" + args.arch)
    lines.extend([
        "", "  preflight do",
        '    raise "WakeLease requires macOS 15.4 or later" if MacOS.version < MacOSVersion.new("15.4")',
        "  end", "", '  app "WakeLease.app"', "",
        "  uninstall script: {",
        '    executable: "#{appdir}/WakeLease.app/Contents/MacOS/WakeLease",',
        '    args: ["--uninstall", "--yes"],',
        "    sudo: false,", "    must_succeed: true,", "  }", "end",
    ])
    print("\n".join(lines))


if __name__ == "__main__":
    main()
