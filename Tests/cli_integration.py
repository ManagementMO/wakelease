import concurrent.futures
import json
import os
from pathlib import Path
import select
import shutil
import shlex
import pty
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time
import unittest


class CLIIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[1]
        binaries = Path(os.environ.get("WAKELEASE_BIN_DIR", root / ".build/source-testing/debug"))
        cls.cli = str(binaries / "wakelease")
        cls.daemon_binary = str(binaries / "WakeLeaseDaemon")
        version = subprocess.run([cls.cli, "version"], capture_output=True, text=True, timeout=5)
        if not version.stdout.startswith("wakelease "):
            raise AssertionError("The new CLI is not built; refusing to launch an upstream daemon.")
        cls.directory = tempfile.TemporaryDirectory(prefix="wl-")
        os.chmod(cls.directory.name, 0o700)
        cls.environment = dict(os.environ, WAKELEASE_STATE_DIR=cls.directory.name)
        cls.start_daemon()

    @classmethod
    def start_daemon(cls):
        cls.daemon = subprocess.Popen(
            [cls.daemon_binary, "--simulate", "--state-dir", cls.directory.name],
            env=cls.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        if not select.select([cls.daemon.stdout], [], [], 10)[0]:
            cls.daemon.kill()
            raise AssertionError("Simulation daemon did not become ready")
        ready = cls.daemon.stdout.readline()
        if "ready (simulation)" not in ready:
            cls.daemon.kill()
            raise AssertionError("Daemon did not explicitly confirm simulation mode: " + ready)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "daemon"):
            cls.daemon.terminate()
            try:
                cls.daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                cls.daemon.kill()
                cls.daemon.wait(timeout=5)
            cls.daemon.stdout.close()
            cls.daemon.stderr.close()
        if hasattr(cls, "directory"):
            cls.directory.cleanup()

    def cli_run(self, *args, **kwargs):
        return subprocess.run([self.cli, *args], env=self.environment, capture_output=True, text=True, timeout=10, **kwargs)

    def status(self):
        result = self.cli_run("status", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def setUp(self):
        self.cli_run("resume")
        self.cli_run("release", "--all")

    def protocol(self, request):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(Path(self.directory.name) / "cli.sock"))
            body = json.dumps(dict(version=1, **request)).encode()
            connection.sendall(struct.pack(">I", len(body)) + body)
            def receive(count):
                data = b""
                while len(data) < count:
                    part = connection.recv(count - len(data))
                    if not part:
                        raise AssertionError("Truncated protocol response")
                    data += part
                return data
            size = struct.unpack(">I", receive(4))[0]
            self.assertLessEqual(size, 2 * 1024 * 1024)
            return json.loads(receive(size))

    def configure(self, preferences):
        stamp = json.loads(self.cli_run("acquire", "settings-stamp", "--ttl", "120", "--json").stdout)
        lease = stamp["lease"]
        return self.protocol(dict(operation="configure", bootID=stamp["status"]["snapshot"]["bootID"],
                                  issuedAt=lease["deadline"] - lease["ttlSeconds"], preferences=preferences))

    def test_generated_agent_commands_execute_from_installed_configurations(self):
        cases = [("claude-code", ".claude/settings.json", "UserPromptSubmit", "Stop"),
                 ("codex", ".codex/hooks.json", "UserPromptSubmit", "Stop"),
                 ("cursor", ".cursor/hooks.json", "beforeSubmitPrompt", "stop"),
                 ("gemini-cli", ".gemini/settings.json", "BeforeAgent", "AfterAgent")]
        for source, filename, start_event, stop_event in cases:
            with self.subTest(source=source), tempfile.TemporaryDirectory(prefix="wl-hook-exec-") as home:
                installed = self.cli_run("integrations", "install", source, "--home", home, "--state-dir", str(Path(home) / "receipts"), "--yes")
                self.assertEqual(installed.returncode, 0, installed.stderr)
                hooks = json.loads((Path(home) / filename).read_text())["hooks"]
                payload = json.dumps(dict(session_id="fixture", turn_id="turn", conversation_id="fixture", generation_id="turn"))
                for event, expected in [(start_event, 1), (stop_event, 0)]:
                    entry = hooks[event][0]
                    command = entry.get("command") or entry["hooks"][0]["command"]
                    result = subprocess.run(["/bin/sh", "-c", command], input=payload, env=self.environment, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.status()["snapshot"]["effectiveCount"], expected)
        with tempfile.TemporaryDirectory(prefix="wl-cline-exec-") as home:
            installed = self.cli_run("integrations", "install", "cline", "--home", home, "--state-dir", str(Path(home) / "receipts"), "--yes")
            self.assertEqual(installed.returncode, 0, installed.stderr)
            for event, expected in [("TaskStart", 1), ("TaskComplete", 0)]:
                path = Path(home) / "Documents/Cline/Hooks" / event
                result = subprocess.run([str(path)], input='{"taskId":"fixture-task"}', env=self.environment, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.status()["snapshot"]["effectiveCount"], expected)

    def test_generated_hermes_commands_execute_as_literal_argument_vectors(self):
        recipe = self.cli_run("hooks", "generate", "--source", "hermes")
        self.assertEqual(recipe.returncode, 0, recipe.stderr)
        commands = [json.loads(line.split(": ", 1)[1]) for line in recipe.stdout.splitlines() if line.startswith("    - command: ")]
        self.assertEqual(len(commands), 2)
        for command, expected in zip(commands, [1, 0]):
            result = subprocess.run(shlex.split(command), input='{"session_id":"hermes-fixture"}', env=self.environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], expected)

    def test_generated_opencode_plugin_executes_documented_event_fixtures(self):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node is required for the generated plugin fixture")
        with tempfile.TemporaryDirectory(prefix="wl-opencode-exec-") as home:
            installed = self.cli_run("integrations", "install", "opencode", "--home", home, "--state-dir", str(Path(home) / "receipts"), "--yes")
            self.assertEqual(installed.returncode, 0, installed.stderr)
            script = Path(__file__).resolve().parent / "opencode_plugin_smoke.mjs"
            plugin = Path(home) / ".config/opencode/plugins/wakelease.ts"
            result = subprocess.run([node, str(script), str(plugin), self.cli], env=self.environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_generated_custom_recipes_namespace_and_release_work(self):
        recipes = []
        work_id = "same work; $(literal)"
        environment = dict(self.environment, JOB_KEY=work_id)
        for source in ["custom-first", "custom-second"]:
            result = self.cli_run("hooks", "generate", "--source", source, "--session-variable", "JOB_KEY", "--for", "2m", "--display", "--json")
            self.assertEqual(result.returncode, 0, result.stderr)
            recipe = json.loads(result.stdout)
            self.assertEqual(recipe["version"], 1)
            self.assertEqual(recipe["ttlSeconds"], 120)
            recipes.append(recipe)
            start = recipe["steps"][0]["command"]
            subprocess.run(["/bin/sh", "-c", start], env=environment, check=True, timeout=10)
        snapshot = self.status()["snapshot"]
        self.assertEqual(snapshot["effectiveCount"], 2)
        self.assertTrue(snapshot["demand"]["display"])
        self.assertEqual({item["key"] for item in snapshot["leases"]}, {source + ":" + work_id for source in ["custom-first", "custom-second"]})
        for count, recipe in zip([1, 0], recipes):
            stop = next(step["command"] for step in recipe["steps"] if step["operation"] == "release")
            subprocess.run(["/bin/sh", "-c", stop], env=environment, check=True, timeout=10)
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], count)
        missing = dict(environment)
        missing.pop("JOB_KEY")
        subprocess.run(["/bin/sh", "-c", recipes[0]["steps"][0]["command"]], env=missing, check=True, timeout=10)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_custom_generator_interactive_terminal_does_not_install(self):
        pid, master = pty.fork()
        if pid == 0:
            os.execve(self.cli, [self.cli, "hooks", "generate", "--interactive"], self.environment)
        waited = False
        output = b""
        try:
            deadline = time.monotonic() + 10
            while b"Source ID" not in output:
                self.assertLess(time.monotonic(), deadline, output)
                if select.select([master], [], [], 0.1)[0]:
                    output += os.read(master, 4096)
            os.write(master, b"custom-interactive\nWORK_UNIT\n2m\nBeginWork\nEndWork\nmy-executable\ny\n")
            while True:
                self.assertLess(time.monotonic(), deadline, output)
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        output += os.read(master, 8192)
                    except OSError:
                        pass
                result, status = os.waitpid(pid, os.WNOHANG)
                if result:
                    waited = True
                    break
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output)
            self.assertIn(b"BeginWork [acquire]", output)
            self.assertIn(b"'custom-interactive:'\"${WORK_UNIT}\"", output)
            self.assertIn(b" --display", output)
            self.assertIn(b"Nothing was installed", output)
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)
        finally:
            if not waited:
                os.kill(pid, signal.SIGTERM)
                os.waitpid(pid, 0)
            os.close(master)

    def test_custom_generator_rejects_invalid_or_interactive_pipe_options(self):
        for options in [["--for", "0"], ["--session-variable", "ID:-x"], ["--interactive"], ["--home", self.directory.name]]:
            result = self.cli_run("hooks", "generate", "--source", "custom-tool", *options, input="")
            self.assertNotEqual(result.returncode, 0, options)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_settings_change_is_live_and_persists_across_restart(self):
        original = self.protocol(dict(operation="settings"))["preferences"]
        updated = json.loads(json.dumps(original))
        updated["policy"]["waitingPolicy"] = "sleep"
        try:
            response = self.configure(updated)
            self.assertTrue(response["ok"], response)
            self.cli_run("wait", "settings-stamp")
            self.assertFalse(self.status()["snapshot"]["demand"]["system"])
            self.daemon.terminate()
            self.daemon.wait(timeout=10)
            self.daemon.stdout.close()
            self.daemon.stderr.close()
            self.start_daemon()
            self.assertEqual(self.protocol(dict(operation="settings"))["preferences"]["policy"]["waitingPolicy"], "sleep")
        finally:
            self.assertTrue(self.configure(original)["ok"])

    def test_doctor_json_is_read_only_and_scoped(self):
        result = self.cli_run("doctor", "--json", "--home", self.directory.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["mode"], "simulation")
        self.assertTrue(any(item["id"] == "powerControl" and item["level"] == "skipped" for item in report["checks"]))
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_doctor_reports_malformed_integration_without_overwriting(self):
        with tempfile.TemporaryDirectory(prefix="wl-doctor-") as home:
            config = Path(home) / ".claude/settings.json"
            config.parent.mkdir()
            config.write_text('{"hooks":[]}')
            result = self.cli_run("doctor", "--json", "--home", home)
            self.assertEqual(result.returncode, 1)
            report = json.loads(result.stdout)
            self.assertTrue(any(item["id"] == "integration.claude-code" and item["level"] == "failure" for item in report["checks"]))
            self.assertEqual(config.read_text(), '{"hooks":[]}')

    def test_uninstall_dry_run_does_not_release_work(self):
        self.cli_run("acquire", "dry-run-work")
        result = self.cli_run("uninstall", "--dry-run", "--home", self.directory.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("confirm SleepDisabled OFF", result.stdout)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 1)

    def test_development_binaries_refuse_production_modes(self):
        if os.getuid() == 0:
            self.skipTest("This test requires an unprivileged developer account")
        helper = str(Path(self.daemon_binary).with_name("WakeLeaseHelper"))
        rejected = subprocess.run([helper], capture_output=True, text=True, timeout=5)
        self.assertEqual(rejected.returncode, 78)
        self.assertIn("No power settings were changed", rejected.stderr)
        rejected = subprocess.run([self.daemon_binary], env=self.environment, capture_output=True, text=True, timeout=5)
        self.assertEqual(rejected.returncode, 78)

    def test_help(self):
        result = self.cli_run("--help")
        self.assertEqual(result.returncode, 0)
        for command in ("acquire", "renew", "wait", "release", "hold", "run", "watch", "doctor"):
            self.assertIn(command, result.stdout)

    def test_reference_count(self):
        for key in ("a", "b"):
            self.assertEqual(self.cli_run("acquire", key, "--source", "future-tool").returncode, 0)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 2)
        self.cli_run("release", "a")
        self.assertTrue(self.status()["snapshot"]["demand"]["system"])
        self.cli_run("release", "b")
        self.assertFalse(self.status()["snapshot"]["demand"]["system"])

    def test_run_preserves_arguments_stdin_and_exit_status(self):
        result = self.cli_run("run", "--", "/usr/bin/printf", "%s", "a b; $HOME")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "a b; $HOME")
        result = self.cli_run("run", "--", "/bin/cat", input="hello\n")
        self.assertEqual(result.stdout, "hello\n")
        result = self.cli_run("run", "--", "/bin/sh", "-c", "exit 17")
        self.assertEqual(result.returncode, 17)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_run_forwards_termination(self):
        child = subprocess.Popen(
            [self.cli, "run", "--", sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(60)"],
            env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertTrue(select.select([child.stdout], [], [], 5)[0])
            self.assertEqual(child.stdout.readline().strip(), "ready")
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=5), 143)
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            child.stdout.close()
            child.stderr.close()

    def test_ttl_expires_without_another_request(self):
        self.assertEqual(self.cli_run("hold", "--for", "1s").returncode, 0)
        time.sleep(1.3)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_watch_releases_when_process_exits(self):
        job = subprocess.Popen(["/bin/sleep", "0.5"])
        result = self.cli_run("watch", "--pid", str(job.pid))
        job.wait(timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_watch_cancellation_releases_without_killing_job(self):
        job = subprocess.Popen(["/bin/sleep", "60"])
        watcher = subprocess.Popen([self.cli, "watch", "--pid", str(job.pid)], env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while self.status()["snapshot"]["effectiveCount"] != 1:
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            watcher.terminate()
            self.assertEqual(watcher.wait(timeout=5), 143)
            self.assertIsNone(job.poll())
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)
        finally:
            if watcher.poll() is None:
                watcher.kill()
                watcher.wait(timeout=5)
            watcher.stdout.close()
            watcher.stderr.close()
            job.terminate()
            job.wait(timeout=5)

    def test_run_preserves_controlling_terminal_and_ctrl_c(self):
        pid, master = pty.fork()
        if pid == 0:
            os.execve(self.cli, [self.cli, "run", "--", sys.executable, "-c", "import os,time; print('TTY', os.isatty(0), os.isatty(1), os.isatty(2), flush=True); time.sleep(60)"], self.environment)
        waited = False
        try:
            output = b""
            deadline = time.monotonic() + 5
            while b"TTY True True True" not in output:
                self.assertLess(time.monotonic(), deadline, output)
                if select.select([master], [], [], 0.1)[0]:
                    output += os.read(master, 4096)
            os.write(master, b"\x03")
            while True:
                result, status = os.waitpid(pid, os.WNOHANG)
                if result:
                    waited = True
                    break
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            self.assertEqual(os.waitstatus_to_exitcode(status), 130)
            self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)
        finally:
            if not waited:
                os.kill(pid, signal.SIGTERM)
                os.waitpid(pid, 0)
            os.close(master)

    def test_missing_executable_does_not_leak(self):
        result = self.cli_run("run", "--", "/this-command-does-not-exist-wakelease")
        self.assertEqual(result.returncode, 127)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_concurrent_clients_and_latency(self):
        def acquire(index):
            start = time.perf_counter()
            result = self.cli_run("acquire", "concurrent-" + str(index))
            self.assertEqual(result.returncode, 0, result.stderr)
            return (time.perf_counter() - start) * 1000
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            measurements = list(pool.map(acquire, range(24)))
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 24)
        print("Concurrent CLI latency: median=%.1fms p95=%.1fms" % (statistics.median(measurements), sorted(measurements)[22]))

    def test_daemon_crash_recovery(self):
        self.assertEqual(self.cli_run("acquire", "survivor", "--ttl", "60").returncode, 0)
        self.daemon.kill()
        self.daemon.wait(timeout=5)
        self.daemon.stdout.close()
        self.daemon.stderr.close()
        type(self).start_daemon()
        self.assertEqual([lease["key"] for lease in self.status()["snapshot"]["leases"]], ["survivor"])

    def test_malformed_client_does_not_kill_daemon(self):
        for body in (b"not json", b'{"version":99,"operation":"status"}'):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(3)
                client.connect(str(Path(self.directory.name) / "cli.sock"))
                client.sendall(struct.pack(">I", len(body)) + body)
                self.assertTrue(client.recv(4))
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(Path(self.directory.name) / "cli.sock"))
            client.sendall(struct.pack(">I", 0xFFFFFFFF))
        self.assertEqual(self.status()["mode"], "simulation")

    def test_hooks_are_turn_scoped_and_fail_soft(self):
        cursor = json.dumps({"conversation_id": "chat", "generation_id": "turn", "prompt": "private-content"})
        self.assertEqual(self.cli_run("hook", "cursor", "start", input=cursor).returncode, 0)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 1)
        self.assertEqual(self.cli_run("hook", "cursor", "stop", input=cursor).returncode, 0)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)
        result = self.cli_run("hook", "claude-code", "start", input="malformed")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {})
        self.assertNotIn("private-content", result.stdout + result.stderr)

    def test_subagent_hook_outlives_parent_stop(self):
        parent = json.dumps({"session_id": "parent"})
        child = json.dumps({"session_id": "parent", "agent_id": "child"})
        self.cli_run("hook", "claude-code", "start", input=parent)
        self.cli_run("hook", "claude-code", "subagent-start", input=child)
        self.cli_run("hook", "claude-code", "stop", input=parent)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 1)
        self.cli_run("hook", "claude-code", "subagent-stop", input=child)
        self.assertEqual(self.status()["snapshot"]["effectiveCount"], 0)

    def test_integration_cli_round_trip_uses_fake_home(self):
        with tempfile.TemporaryDirectory(prefix="wl-home-") as home:
            target = Path(home) / ".claude/settings.json"
            target.parent.mkdir()
            original = '{"userSetting": "keep"}'
            target.write_text(original)
            preview = self.cli_run("integrations", "install", "claude-code", "--home", home, "--dry-run")
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertEqual(target.read_text(), original)
            installed = self.cli_run("integrations", "install", "claude-code", "--home", home, "--yes")
            self.assertEqual(installed.returncode, 0, installed.stderr)
            removed = self.cli_run("integrations", "uninstall", "claude-code", "--home", home, "--yes")
            self.assertEqual(removed.returncode, 0, removed.stderr)
            self.assertEqual(target.read_text(), original)

    def test_local_mcp_creates_independent_display_lease(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "clientInfo": {"name": "test", "version": "1"}, "capabilities": {}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "keep_display_awake", "arguments": {"reason": "fixture background work", "minutes": 1}}},
        ]
        result = self.cli_run("mcp", input="\n".join(map(json.dumps, messages)) + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], [1, 2, 3])
        tools = {tool["name"] for tool in replies[1]["result"]["tools"]}
        self.assertEqual(tools, {"keep_system_awake", "keep_display_awake", "release_wake_lease", "get_wake_status"})
        self.assertFalse(replies[2]["result"]["isError"])
        self.assertTrue(self.status()["snapshot"]["demand"]["display"])

    def test_doctor_reports_simulation_honestly(self):
        result = self.cli_run("doctor", "--home", self.directory.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("simulation", result.stdout.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
