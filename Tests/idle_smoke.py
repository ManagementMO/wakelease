import ctypes
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest


class TaskInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint64) for name in ["virtual", "resident", "user", "system", "threads_user", "threads_system"]] + [(name, ctypes.c_int32) for name in ["policy", "faults", "pageins", "cow", "messages_sent", "messages_received", "mach_calls", "unix_calls", "switches", "threads", "running", "priority"]]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def sample(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidinfo
    function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    function.restype = ctypes.c_int
    info = TaskInfo()
    size = ctypes.sizeof(info)
    if function(pid, 4, 0, ctypes.byref(info), size) != size:
        raise OSError(ctypes.get_errno(), "Could not inspect the owned test daemon")
    return info


def seconds_per_tick():
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    function = library.mach_timebase_info
    function.argtypes = [ctypes.POINTER(Timebase)]
    function.restype = ctypes.c_int
    info = Timebase()
    if function(ctypes.byref(info)) != 0 or not info.denom:
        raise RuntimeError("Mach timebase is unavailable")
    return info.numer / info.denom / 1_000_000_000


class IdleSmoke(unittest.TestCase):
    def test_simulated_daemon_has_no_busy_idle_loop(self):
        root = Path(__file__).resolve().parents[1]
        binary = Path(os.environ.get("WAKELEASE_BIN_DIR", root / ".build/source-testing/debug")) / "WakeLeaseDaemon"
        with tempfile.TemporaryDirectory(prefix="wl-idle-") as directory:
            environment = dict(os.environ, WAKELEASE_STATE_DIR=directory)
            process = subprocess.Popen([str(binary), "--simulate", "--state-dir", directory], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(select.select([process.stdout], [], [], 10)[0], "Simulation daemon did not become ready")
                self.assertIn("ready (simulation)", process.stdout.readline())
                time.sleep(1)
                before = sample(process.pid)
                started = time.monotonic()
                time.sleep(5)
                after = sample(process.pid)
                elapsed = time.monotonic() - started
                self.assertIsNone(process.poll(), "Simulation daemon exited while idle")
                cpu = (after.user + after.system - before.user - before.system) * seconds_per_tick()
                report = dict(scope="simulation daemon only; no privileged power, real sensors or UI", seconds=round(elapsed, 3), cpu_percent=round(cpu / elapsed * 100, 4), resident_mib=round(after.resident / 1024 / 1024, 2), mach_tick_seconds=seconds_per_tick())
                print("Idle sample: " + json.dumps(report, sort_keys=True))
                self.assertGreaterEqual(cpu, 0, report)
                self.assertLess(report["cpu_percent"], 2.0, report)
                self.assertLess(report["resident_mib"], 256, report)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                process.stdout.close()
                process.stderr.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
