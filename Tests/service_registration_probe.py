import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]


def ephemeral_identity(directory, keychain):
    if os.environ.get("CI") != "true" or os.environ.get("WAKELEASE_REGISTRATION_PROBE") != "approved-disposable-runner":
        raise RuntimeError("Certificate fixtures are restricted to approved disposable CI")
    password = secrets.token_hex(24)
    environment = dict(os.environ, WAKELEASE_EPHEMERAL_PASSWORD=password)
    config = directory / "certificate.cnf"
    config.write_text("[req]\nprompt=no\ndistinguished_name=identity\nx509_extensions=extensions\n[identity]\nCN=WakeLease Disposable CI Publisher\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n")
    key = directory / "identity.key"
    certificate = directory / "identity.pem"
    encoded_key = directory / "identity.der"
    commands = [
        ["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "2", "-config", str(config), "-keyout", str(key), "-out", str(certificate)],
        ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", str(key), "-outform", "DER", "-out", str(encoded_key)],
        ["security", "create-keychain", "-p", password, str(keychain)],
        ["security", "unlock-keychain", "-p", password, str(keychain)],
        ["security", "import", str(encoded_key), "-k", str(keychain), "-t", "priv", "-f", "pkcs8", "-x", "-T", "/usr/bin/codesign"],
        ["security", "import", str(certificate), "-k", str(keychain)],
        ["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)],
    ]
    for command in commands:
        try:
            result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            raise RuntimeError("Disposable certificate setup timed out in " + command[0]) from None
        if result.returncode:
            raise RuntimeError("Disposable certificate setup failed in " + command[0] + ": " + result.stderr.replace(password, "[redacted]"))
    os.chmod(key, 0o600)
    os.chmod(encoded_key, 0o600)
    fingerprint = subprocess.check_output(["openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1"], text=True).strip().split("=", 1)[1].replace(":", "")
    return ["--sign", fingerprint, "--keychain", str(keychain), "--timestamp=none"]


def build_apps(directory, app_binary, helper_binary, signing):
    apps = []
    for launch in ["direct", "launch-services"]:
        identifier = "org.wakelease.registration-probe." + uuid.uuid4().hex
        app = directory / (launch + ".app")
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        executable = contents / "MacOS/RegistrationProbe"
        shutil.copy2(app_binary, executable)
        for kind, folder, filename in [("agent", "LaunchAgents", "ProbeAgent.plist"), ("daemon", "LaunchDaemons", "ProbeDaemon.plist")]:
            location = contents / "Library" / folder
            location.mkdir(parents=True)
            helper = location / "HarmlessHelper"
            shutil.copy2(helper_binary, helper)
            plist = {"Label": identifier + "." + kind, "BundleProgram": "Contents/Library/" + folder + "/HarmlessHelper",
                     "RunAtLoad": True, "KeepAlive": False, "ProcessType": "Background", "AssociatedBundleIdentifiers": [identifier]}
            (location / filename).write_bytes(plistlib.dumps(plist))
            subprocess.run(["codesign", "--force", *signing, "--identifier", identifier + "." + kind, str(helper)], check=True, timeout=15)
        info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "RegistrationProbe", "CFBundleName": "WakeLease CI Registration Probe",
                "CFBundlePackageType": "APPL", "LSUIElement": True, "NSPrincipalClass": "NSApplication", "LSMinimumSystemVersion": "13.0"}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", *signing, str(app)], check=True, timeout=15)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=15)
        apps.append((launch, app, executable))
    return apps


def probe_launches(directory, temporary, apps):
    reports = []
    for launch, app, executable in apps:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=15)
        result = directory / (launch + ".json")
        cleanup = directory / (launch + "-cleanup.json")
        try:
            if launch == "direct":
                command = [str(executable), "probe", str(result)]
            else:
                command = ["open", "-n", "-g", "-W", "--env", "CI=true", "--env", "WAKELEASE_REGISTRATION_PROBE=approved-disposable-runner",
                           "--env", "RUNNER_TEMP=" + str(temporary), str(app), "--args", "probe", str(result)]
            process = subprocess.run(command, capture_output=True, text=True, timeout=60)
            if result.is_file():
                report = json.loads(result.read_text())
            else:
                report = {"launchError": process.stderr, "returncode": process.returncode}
            report["launch"] = launch
            reports.append(report)
        finally:
            subprocess.run([str(executable), "cleanup", str(cleanup)], check=True, capture_output=True, text=True, timeout=60)
            cleanup_report = json.loads(cleanup.read_text())
            if not cleanup_report["cleanupOK"]:
                raise SystemExit("Dummy service cleanup failed")
        print(json.dumps(reports[-1], sort_keys=True), flush=True)
    return reports


def main():
    if os.environ.get("CI") != "true" or os.environ.get("WAKELEASE_REGISTRATION_PROBE") != "approved-disposable-runner":
        raise SystemExit("Refusing registration outside explicitly approved disposable CI")
    signature = os.environ.get("WAKELEASE_PROBE_SIGNATURE", "adhoc")
    if signature not in ["adhoc", "self-issued"]:
        raise SystemExit("Unknown probe signature type")
    if signature == "self-issued" and os.environ.get("WAKELEASE_CERTIFICATE_TRUST_PROBE") != "approved-disposable-runner":
        raise SystemExit("Temporary certificate trust requires separate CI approval")
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    destination = temporary / "wakelease-registration-results.json"
    with tempfile.TemporaryDirectory(prefix="wakelease-registration-", dir=temporary) as directory:
        directory = Path(directory)
        app_binary = directory / "RegistrationProbe"
        helper_binary = directory / "HarmlessHelper"
        for source, output in [("ProbeMain.swift", app_binary), ("HarmlessHelper.swift", helper_binary)]:
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(ROOT / "Tests/ServiceRegistrationProbe" / source),
                            "-o", str(output)], check=True, timeout=90)
        keychain = directory / "disposable.keychain-db"
        certificate = directory / "identity.pem"
        trusted = False
        try:
            signing = ephemeral_identity(directory, keychain) if signature == "self-issued" else ["--sign", "-"]
            if signature == "self-issued":
                trusted = True
                subprocess.run(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "codeSign", "-a", "/usr/bin/codesign",
                                "-k", str(keychain), str(certificate)], check=True, capture_output=True, timeout=30)
                subprocess.run(["security", "find-identity", "-p", "codesigning", str(keychain)], check=True, timeout=15)
            apps = build_apps(directory, app_binary, helper_binary, signing)
            if trusted:
                subprocess.run(["sudo", "-n", "security", "remove-trusted-cert", "-d", str(certificate)], check=True, capture_output=True, timeout=30)
                trusted = False
            reports = probe_launches(directory, temporary, apps)
            destination.write_text(json.dumps({"signature": signature, "trustRemovedBeforeExecution": True, "reports": reports}, indent=2) + "\n")
        finally:
            try:
                if trusted:
                    subprocess.run(["sudo", "-n", "security", "remove-trusted-cert", "-d", str(certificate)], check=True, capture_output=True, timeout=30)
            finally:
                if keychain.exists():
                    subprocess.run(["security", "delete-keychain", str(keychain)], check=True, capture_output=True, timeout=15)


if __name__ == "__main__":
    main()
