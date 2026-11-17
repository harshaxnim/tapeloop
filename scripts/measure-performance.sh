#!/usr/bin/env bash
# Measures the running Tapeloop for a while (default 60 s): CPU, wake-ups, disk writes, memory, threads, leaks.
# Uses the kernel's own per-process accounting (proc_pid_rusage), which is where Activity Monitor's figures come
# from. Needs python3 (part of the Xcode command line tools). Usage: scripts/measure-performance.sh [seconds]
set -euo pipefail
SECONDS_TO_MEASURE="${1:-60}"
PID="$(pgrep -x Tapeloop || true)"
if [[ -z "$PID" ]]; then
  echo "Tapeloop is not running. Open it, let it record for a minute, then run this again." >&2
  exit 1
fi

echo "Measuring Tapeloop (pid $PID) for $SECONDS_TO_MEASURE seconds…"
python3 - "$PID" "$SECONDS_TO_MEASURE" <<'EOF'
import ctypes, sys, time
libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
U = ctypes.c_uint64
names = ("user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint "
         "proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups "
         "child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten "
         "qos_default qos_maintenance qos_background qos_utility qos_legacy qos_user_initiated qos_user_interactive "
         "billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles "
         "billed_energy serviced_energy interval_max_phys_footprint runnable_time").split()
class R(ctypes.Structure): _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, U) for n in names]
class TB(ctypes.Structure): _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
tb = TB(); libc.mach_timebase_info(ctypes.byref(tb)); ns = tb.numer / tb.denom
def read(pid):
    r = R()
    if libc.proc_pid_rusage(pid, 4, ctypes.byref(r)) != 0: sys.exit("Could not read the process (did it quit?)")
    return r
pid, secs = int(sys.argv[1]), float(sys.argv[2])
a = read(pid); t0 = time.time(); time.sleep(secs); b = read(pid); dt = time.time() - t0
d = lambda f: getattr(b, f) - getattr(a, f)
cpu = (d("user_time") + d("system_time")) * ns / 1e9
print(f"CPU            {100 * cpu / dt:.2f} % of one core ({cpu:.2f} s in {dt:.0f} s)")
print(f"Wake-ups       {d('pkg_idle_wkups') / dt:.1f} a second from idle, {d('interrupt_wkups') / dt:.1f} a second in all")
print(f"Disk written   {d('diskio_byteswritten')} bytes ({d('logical_writes')} logical writes)")
print(f"Memory         {b.phys_footprint / 1e6:.1f} MB now, {b.lifetime_max_phys_footprint / 1e6:.1f} MB at most since launch")
EOF
echo "Threads        $(ps -M -p "$PID" | tail -n +2 | wc -l | tr -d ' ')"
echo "Leaks          $(leaks "$PID" 2>/dev/null | grep -Eo '[0-9]+ leaks for [0-9]+ total leaked bytes' || echo 'leaks could not inspect the process')"
echo
echo "Memory is Activity Monitor's \"Memory\" figure and includes the audio Tapeloop holds (about 22 MB per hour per"
echo "source at the default quality). See docs/PERFORMANCE.md for the reference figures."
