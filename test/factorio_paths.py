"""Where Factorio lives on this machine, for the test scripts (no other dependencies).

  factorio_exe   FACTORIO_EXE, else the first Steam library that has the game
  game_data      the game's data folder (next to bin/)
  write_data     FACTORIO_WRITE_DATA, else what the game's config-path.cfg / config.ini say, else %APPDATA%/Factorio
  user_mods      FACTORIO_MODS, else <write_data>/mods
  script_output  <write_data>/script-output

headless() runs one test case (a scenario mod) in a headless game; main() is a mod's whole test/run.py.
game() runs the game and catches crashes and hangs; base_save() is the map the cases share.
"""
import argparse
import atexit
import ctypes
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
import _thread
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

os.environ.setdefault("FSE_OFF", "1")  # (games started from here run plain even with the fse loader installed)

STEAM_GUESSES = [Path(p) / "steamapps/common/Factorio" for p in (
    "C:/Program Files (x86)/Steam", "C:/Program Files/Steam", "D:/SteamLibrary", "E:/SteamLibrary", "F:/SteamLibrary",
    "G:/SteamLibrary")]


def _game_root():
    if os.environ.get("FACTORIO_EXE"):
        return Path(os.environ["FACTORIO_EXE"]).parents[2]
    for g in STEAM_GUESSES:
        if (g / "bin/x64/factorio.exe").exists():
            return g
    return STEAM_GUESSES[0]


def _write_data(root):
    if os.environ.get("FACTORIO_WRITE_DATA"):
        return Path(os.environ["FACTORIO_WRITE_DATA"])
    appdata = Path(os.environ.get("APPDATA", Path.home() / "AppData/Roaming")) / "Factorio"
    try:
        cfgpath = (root / "config-path.cfg").read_text(encoding="utf-8")
        m = re.search(r"^config-path=(.*)$", cfgpath, re.M)
        config_dir = m.group(1).strip() if m else "__PATH__system-write-data__/config"
        config_dir = config_dir.replace("__PATH__system-write-data__", str(appdata)).replace(
            "__PATH__executable__", str(root / "bin/x64"))
        ini = (Path(config_dir) / "config.ini").read_text(encoding="utf-8")
        m = re.search(r"^write-data=(.*)$", ini, re.M)
        if m:
            return Path(m.group(1).strip().replace("__PATH__system-write-data__", str(appdata))
                        .replace("__PATH__executable__", str(root / "bin/x64")))
    except OSError:
        pass
    return appdata


_root = _game_root()
_write = _write_data(_root)
PATHS = {"factorio_exe": Path(os.environ.get("FACTORIO_EXE") or _root / "bin/x64/factorio.exe"),
         "game_data": _root / "data", "write_data": _write,
         "user_mods": Path(os.environ.get("FACTORIO_MODS") or _write / "mods"),
         "script_output": _write / "script-output"}


def run_dir(path):
    """a write-data folder for headless runs, with its own config.ini, so tests never touch the game's own"""
    path.mkdir(parents=True, exist_ok=True)
    ini = path / "config.ini"
    # (without the version line the game calls the file invalid and asks, over the main menu, to reset it)
    text = f"; version=13\n[path]\nread-data={PATHS['game_data'].as_posix()}\nwrite-data={path.as_posix()}\n"
    cur = ini.read_text(encoding="utf-8") if ini.exists() else ""
    if "; version=" not in cur or f"write-data={path.as_posix()}" not in cur:
        ini.write_text(text, encoding="utf-8")  # (written again when the folder has moved)
    return path


BASE_MODS = ["base", "elevated-rails", "quality", "space-age"]


def _repo():
    """this dev repo's root (the folder with fse/mods and mods/), or None"""
    for p in Path(__file__).resolve().parents:
        if (p / "fse" / "mods").is_dir() and (p / "mods").is_dir():
            return p
    return None


def _info(src):
    """a mod's info.json (folder or zip), {} when it can't be read"""
    try:
        if src.is_dir():
            return json.loads((src / "info.json").read_text(encoding="utf-8-sig"))
        import zipfile
        with zipfile.ZipFile(src) as z:
            inner = min((n for n in z.namelist() if n.count("/") == 1 and n.endswith("/info.json")), key=len)
            return json.loads(z.read(inner).decode("utf-8-sig"))
    except Exception:  # (OSError, bad JSON, a broken zip)
        return {}


def source_mods():
    """our own mods in this repo, {info.json name: folder}: fse/mods/*, mods/*, bpgen/mod/*"""
    root, found = _repo(), {}
    if root:
        for parent in (root / "fse" / "mods", root / "mods", root / "bpgen" / "mod"):
            for d in sorted(parent.glob("*/info.json")):
                found.setdefault(_info(d.parent).get("name") or d.parent.name, d.parent)
    return found


def _bare(path):
    """a mod's file name without .zip (a folder <name>_1.2.3 keeps its last number: Path.stem would drop it)"""
    return path.stem if path.suffix == ".zip" else path.name


def _version_key(path):
    return [int(n) for n in re.findall(r"\d+", _bare(path))]


def user_mod(name):
    """the mod `name` for a test (--with): our source folder in this repo (by info.json name, else folder name), else
    from the game's own mods folder: a folder <name> or <name>_<version> (the newest), else the newest <name>_*.zip"""
    ours = source_mods()
    if name in ours:
        return ours[name]
    root = _repo()
    for parent in ((root / "fse" / "mods", root / "mods", root / "bpgen" / "mod") if root else ()):
        if (parent / name / "info.json").exists():
            return parent / name
    um = PATHS["user_mods"]
    if (um / name / "info.json").exists():
        return um / name
    found = [p for p in um.glob(name + "_*") if (p / "info.json").exists() or p.suffix == ".zip"]
    found = [p for p in found if re.fullmatch(re.escape(name) + r"_\d+\.\d+\.\d+", _bare(p))]
    if not found:
        raise FileNotFoundError(f"mod {name!r}: not in this repo (fse/mods, mods, bpgen/mod) nor in {um}")
    return max(found, key=_version_key)


def with_deps(mods, have=()):
    """`mods` ({name: folder or zip}) plus the mods they require (info.json dependencies without ?/(?)/!), found
    by user_mod; the game's own mods and the names in `have` are left out, so are ones that can't be found"""
    out, todo, skip = dict(mods), list(mods), {"core", *BASE_MODS, *have}
    while todo:
        for dep in _info(out[todo.pop()]).get("dependencies", []):
            dep = dep.strip()
            if dep[:1] in "?!(":
                continue
            name = re.split(r"\s*(?:[<>=]=?)\s*", dep.lstrip("~ ").strip())[0].strip()
            if name and name not in skip and name not in out:
                try:
                    out[name] = user_mod(name)
                except (FileNotFoundError, ValueError):
                    continue
                todo.append(name)
    return out


def stage_mods(md, mods, base=BASE_MODS):
    """`mods` ({name: folder or zip}) copied into the mod folder `md` (emptied first), with a mod-list.json"""
    shutil.rmtree(md, ignore_errors=True)
    md.mkdir(parents=True)
    for name, src in mods.items():
        if src.is_dir():
            shutil.copytree(src, md / name, ignore=shutil.ignore_patterns("test", ".git", "__pycache__"))
        else:
            shutil.copy(src, md)
    (md / "mod-list.json").write_text(json.dumps({"mods": [{"name": n, "enabled": True} for n in [*base, *mods]]}))


CRASH_LINES = ("Factorio crashed", "Unexpected error occurred")
VERDICT = re.compile(r"^(ALL PASS|\d+ FAILED)\s*$", re.M)  # a case's last line: once written, its game can stop
_live = set()  # games running now, killed when this script exits (Ctrl+C included)


def _kill(p):
    subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
    p.wait()


atexit.register(lambda: [_kill(p) for p in list(_live)])
if os.name == "nt":  # no "factorio.exe has stopped working" box for a crashed test game (the games inherit this)
    ctypes.windll.kernel32.SetErrorMode(0x8003)


def game(args, log, timeout, done=None):
    """Run the game (`args`: what follows the exe) with its output in the file `log`; returns (status, output).
    status: "ok"; "error" (exit code or an error line); "crash" (killed a minute after the crash line, so the stack
    trace gets written but a crash box can't hold it up); "hang" (killed after `timeout` s).
    done(), asked five times a second, stops the game early ("ok") once it is true."""
    with open(log, "wb") as f:
        # (below normal priority: test games only get the CPU the desktop isn't using)
        p = subprocess.Popen([str(PATHS["factorio_exe"]), *map(str, args)], stdout=f, stderr=subprocess.STDOUT,
                             creationflags=subprocess.BELOW_NORMAL_PRIORITY_CLASS)
    _live.add(p)
    t0, crashed, status, out = time.time(), None, None, ""
    with open(log, "rb") as rd:
        while p.poll() is None:
            time.sleep(0.2)
            new = rd.read().decode("utf-8", "replace")
            out += new
            if crashed is None and any(c in out[-len(new) - 40:] for c in CRASH_LINES):
                crashed = time.time()
            if crashed and time.time() - crashed > 60:
                status = "crash"
            elif not crashed and done and done():
                status = "ok"
            elif time.time() - t0 > timeout:
                status = "hang"
            if status:
                _kill(p)
                break
        out += rd.read().decode("utf-8", "replace")
    _live.discard(p)
    if any(c in out for c in CRASH_LINES):
        return "crash", out
    if status:
        return status, out
    return ("error" if p.returncode or "non-recoverable" in out or "Error" in out else "ok"), out


ERROR_LINE = re.compile(r"^\s*\d+\.\d+ Error .*$", re.M)


_stopped, _watchers = [], []


def _on_stop(signum, frame):
    if _stopped:
        raise SystemExit(_stopped[0])
    raise KeyboardInterrupt


def _stop(why, text):
    """(from the watching thread) every game killed, then SystemExit in the main thread: its finally blocks run"""
    for p in list(_live):
        _kill(p)
    _stopped.append(f"\n{why}\n    " + "\n    ".join(text.strip().splitlines()[:60]))
    if _exiting:  # (the script is done already: _finish reports it)
        return
    _thread.interrupt_main(signal.SIGINT)
    time.sleep(60)  # (the main thread stuck somewhere that can't be interrupted)
    print(_stopped[0], flush=True)
    os._exit(1)


SKIP_INTRO_MOD = "zzzz-test-skip-intro"
SKIP_INTRO_LUA = """-- (put in by the test runner) no crash-site cutscene: at its end the game pauses until the player presses Tab
script.on_init(function()
  local fp = remote.interfaces["freeplay"]
  if fp then
    if fp.set_skip_intro then remote.call("freeplay", "set_skip_intro", true) end
    if fp.set_disable_crashsite then remote.call("freeplay", "set_disable_crashsite", true) end
  end
end)
"""


def add_skip_intro(md):
    """Into the mod folder `md` (with its mod-list.json): a mod that skips freeplay's crash-site intro. Its on_init
    runs when the game loads a save it isn't in yet too, before the player is made, so a save made without it works."""
    sm = md / SKIP_INTRO_MOD
    sm.mkdir(parents=True, exist_ok=True)
    (sm / "info.json").write_text(json.dumps({"name": SKIP_INTRO_MOD, "version": "0.0.1", "title": SKIP_INTRO_MOD,
                                              "author": "tests", "factorio_version": "2.0"}))
    (sm / "control.lua").write_text(SKIP_INTRO_LUA)
    ml = md / "mod-list.json"
    lst = json.loads(ml.read_text()) if ml.exists() else {"mods": []}
    if not any(m["name"] == SKIP_INTRO_MOD for m in lst["mods"]):
        lst["mods"].append({"name": SKIP_INTRO_MOD, "enabled": True})
        ml.write_text(json.dumps(lst))


_exiting = False


@atexit.register
def _finish():
    """at exit, wait for the watchers of games that just ended: an error in a game's last lines still fails the run"""
    global _exiting
    _exiting = True
    for t in _watchers:
        t.join(10)
    if _stopped:
        print(_stopped[0], flush=True)
        os._exit(1)


def watch_game(args, expect=(), timeout=900, **popen):
    """Popen(args) for a real game window, watched from a thread through the factorio-current.log in its --config
    folder (that is its write-data, see run_dir). On an error line (a mod that failed to load, a missing file, a
    script error: the popup the user would see) or a crash, or when it still runs after `timeout` s, every game
    this script started is killed and the script exits 1 with the reason. `expect`: regexes of error lines that
    are part of the test. The game's --mod-directory gets add_skip_intro's mod. Returns the Popen."""
    log = Path(args[args.index("--config") + 1]).parent / "factorio-current.log"
    if "--mod-directory" in args:
        add_skip_intro(Path(args[args.index("--mod-directory") + 1]))
    t0 = time.time()
    signal.signal(signal.SIGINT, _on_stop)
    popen.setdefault("stdout", subprocess.DEVNULL)
    popen.setdefault("stderr", subprocess.DEVNULL)
    p = subprocess.Popen(args, **popen)
    _live.add(p)

    def read(pos):
        try:
            st = log.stat()
            if st.st_mtime < t0 - 2:  # (still the last run's log: the game hasn't started writing yet)
                return 0, ""
            if st.st_size < pos:  # (a new log: the game restarted itself)
                pos = 0
            with open(log, "rb") as f:
                f.seek(pos)
                new = f.read()
            return pos + len(new), new.decode("utf-8", "replace")
        except OSError:
            return pos, ""

    def watch():
        pos, out, crashed = 0, "", None
        while True:
            time.sleep(0.5)
            ended = p.poll() is not None  # (asked before the read, so the game's last lines are always looked at)
            before = pos
            pos, new = read(pos)
            if pos < before:
                out = ""
            start = out.rfind("\n") + 1  # (only the new lines are looked at)
            out += new
            if crashed is None and any(c in out[start:] for c in CRASH_LINES):
                crashed = time.time()
            if crashed and (ended or time.time() - crashed > 60):
                return _stop(f"CRASH: the game crashed (log: {log})", _crash_text(out + read(pos)[1]))
            if not crashed:
                for m in ERROR_LINE.finditer(out, start):
                    if not any(re.search(e, m.group()) for e in expect):
                        if not ended:
                            time.sleep(2)  # (the rest of it: a Lua stack trace)
                        return _stop(f"ERROR in the game (log: {log})", (out + read(pos)[1])[m.start():][:4000])
            if ended and not crashed:
                _live.discard(p)
                return
            if time.time() - t0 > timeout:
                return _stop(f"HANG: the game still runs after {timeout} s (log: {log})", out[-2000:])

    _watchers.append(threading.Thread(target=watch, daemon=True))
    _watchers[-1].start()
    return p


TEST_SEED = 1  # (the map every case plays on; a case can pass on one map and fail on another: try --seed random)


def base_save(run, base=BASE_MODS, seed=TEST_SEED):
    """A new map (map seed `seed`) with just the `base` mods, in the folder `run`, shared by every case: each case then
    starts the game once instead of twice (its mods join the map when it loads, and their on_init runs then), and every
    run plays on the same map. Made again when the game updates."""
    run = run_dir(run)
    exe = PATHS["factorio_exe"]
    tag = hashlib.md5(f"{base} {seed} {exe.stat().st_mtime_ns}".encode()).hexdigest()[:8]
    save = run / f"base-{tag}.zip"
    if save.exists():
        return save
    md = run / "base-mods"
    stage_mods(md, {}, base)
    tmp = run / f"base-{tag}-{os.getpid()}.zip"
    gen = run / "map-gen-settings.json"
    gen.write_text(json.dumps({"seed": seed}))
    status, out = game(["--config", run / "config.ini", "--mod-directory", md, "--map-gen-settings", gen,
                        "--create", tmp], run / "base.log", 300)
    if status != "ok" or not tmp.exists():
        raise RuntimeError("couldn't make the test map:\n" + out[-3000:])
    for old in run.glob("base-*.zip"):
        if old != tmp:
            old.unlink(missing_ok=True)
    os.replace(tmp, save)
    return save


def _crash_text(out):
    i = min((out.find(c) for c in CRASH_LINES if c in out), default=0)
    return "\n".join(out[max(0, out.rfind("\n", 0, i)):].strip().splitlines()[:60])


FILES_MOD = "zzzz-test-files"
FILE_LINE = re.compile(r"TEST-FILE __(.+?)__/(.+?)\s*$", re.M)
FILES_LUA = """-- every "__mod__/path" of these mods that a prototype points at, logged for the test runner to check:
-- a headless game never loads graphics or sounds, so it doesn't notice one that is missing
local check, seen, found = {%s}, {}, {}
local function walk(t)
  if seen[t] then return end
  seen[t] = true
  for _, v in pairs(t) do
    if type(v) == "table" then walk(v)
    elseif type(v) == "string" and not found[v] and check[v:match("^__(.-)__/") or ""] then
      found[v] = true
      log("TEST-FILE " .. v)
    end
  end
end
walk(data.raw)
"""


def add_files_check(md, names):
    """Into the staged mod folder `md`: a mod that logs the files the mods `names` point at (see missing_files)."""
    fm = md / FILES_MOD
    fm.mkdir(exist_ok=True)
    (fm / "info.json").write_text(json.dumps({"name": FILES_MOD, "version": "0.0.1", "title": FILES_MOD,
                                              "author": "tests", "factorio_version": "2.0",
                                              "dependencies": ["? " + n for n in names]}))
    (fm / "data-final-fixes.lua").write_text(FILES_LUA % ", ".join(f'["{n}"] = true' for n in names))
    ml = md / "mod-list.json"
    lst = json.loads(ml.read_text())
    lst["mods"].append({"name": FILES_MOD, "enabled": True})
    ml.write_text(json.dumps(lst))


def _exists_exact(root, rel):
    """rel (a/b/c.png) under root, with each name's case as written (Windows doesn't care, a zip on Linux does)"""
    cur = root
    for part in rel.split("/"):
        try:
            if part not in os.listdir(cur):
                return False
        except OSError:
            return False
        cur = cur / part
    return True


def missing_files(md, log):
    """the "__mod__/path"s logged by add_files_check's mod that aren't in the staged folder `md` (case counts)"""
    return sorted({f"__{m}__/{f}" for m, f in FILE_LINE.findall(log)
                   if (md / m).is_dir() and not _exists_exact(md / m, f)})


def headless(run, mods, case, ticks, base=BASE_MODS, save=None, timeout=None):
    """Copy `mods` ({name: folder or zip}) into <run>/headless-mods and run the case's map (`save`, else
    base_save(run)) `ticks` ticks headless, or until script-output/<case>.txt ends in "ALL PASS" / "<n> FAILED".
    Returns (status, text). status: PASS (no error logged, the result file exists without a FAIL line, every file the
    mods' prototypes point at exists); FAIL;
    CRASH (text: the game's stack trace); HANG (still running after `timeout` s, default 1 min + 1 s per 300 ticks)."""
    run = run_dir(run)
    md = run / "headless-mods"
    stage_mods(md, mods, base)
    add_files_check(md, [n for n, src in mods.items() if src.is_dir()])
    out = run / "script-output" / (case + ".txt")
    out.unlink(missing_ok=True)
    save = save or base_save(run, base)

    def result():
        return out.read_text(encoding="utf-8", errors="replace") if out.exists() else ""

    status, log = game(["--config", run / "config.ini", "--mod-directory", md, "--benchmark", save,
                        "--benchmark-ticks", ticks, "--disable-audio"], run / "stdout.txt",
                       timeout or 60 + ticks / 300, lambda: VERDICT.search(result()))
    text = result()
    if status == "crash":
        return "CRASH", _crash_text(log)
    if status == "hang":
        return "HANG", (text or "no result") + "\n" + log[-1500:]
    if status == "error":
        return "FAIL", log[-3000:]
    missing = missing_files(md, log)
    if missing:
        return "FAIL", (text or "no result") + "\nmissing files (the game would fail to load them):\n  " + "\n  ".join(missing)
    return ("PASS" if text and "FAIL" not in text else "FAIL"), text or "no result"


def main(run_py, cases, base=BASE_MODS, user_mods=()):
    """A mod's test/run.py. `cases` is {case: ticks}, the first one the default.
      run.py [CASE [TICKS]] [--with MOD]   one case in test/run (MOD: another mod, see user_mod)
      run.py --all [-j N]                  every case, N games at once (default 4), each in test/run/all/<case>
    A case stops early once its result ends in "ALL PASS" / "<n> FAILED". --timeout S: a case still running after
    S seconds is a HANG (default 1 min + 1 s per 300 ticks). --seed N: play on another map (random: a new one).
    Exits 1 when a case fails, crashes or hangs."""
    here = Path(run_py).resolve().parent
    mod = here.parent
    mod_name = json.loads((mod / "info.json").read_text(encoding="utf-8"))["name"]  # (may differ from the folder's)
    ap = argparse.ArgumentParser(usage=main.__doc__.splitlines()[1].strip() + "\n       "
                                 + main.__doc__.splitlines()[2].strip())
    ap.add_argument("case", nargs="?", default=next(iter(cases)))
    ap.add_argument("ticks", nargs="?", type=int)
    ap.add_argument("--with", dest="extra", action="append", default=[])
    ap.add_argument("--all", action="store_true")
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("--timeout", type=float)
    ap.add_argument("--seed", default=str(TEST_SEED))
    a = ap.parse_args()
    # (keyed by info.json name: --with trash-slot finds mods/trash-slot, which the game knows as wx-trash-slot)
    extra = {}
    for n in [*user_mods, *a.extra]:
        src = user_mod(n)
        extra[_info(src).get("name") or n] = src
    extra = with_deps(extra, have=[mod_name])
    seed = random.randrange(2 ** 32) if a.seed == "random" else int(a.seed)
    save = base_save(here / "run", base, seed)
    if seed != TEST_SEED:
        print("map seed", seed, flush=True)

    def one(case, ticks, run):
        try:
            return headless(run, {mod_name: mod, **extra, case: here / case}, case, ticks, base, save, a.timeout)
        except Exception:  # (a broken case shouldn't take the other cases down with it)
            return "FAIL", traceback.format_exc()

    if not a.all:
        status, text = one(a.case, a.ticks or cases.get(a.case) or next(iter(cases.values())), here / "run")
        print(text)
        if status != "PASS":
            print(status, a.case)
        sys.exit(0 if status == "PASS" else 1)
    start, failed = time.time(), []

    def timed(c, t):
        t0 = time.time()
        return (*one(c, t, here / "run" / "all" / c), time.time() - t0)

    with ThreadPoolExecutor(a.j) as pool:
        # longest first, so a slow one doesn't start last
        jobs = {pool.submit(timed, c, t): c for c, t in sorted(cases.items(), key=lambda ct: -ct[1])}
        for f in as_completed(jobs):
            status, text, took = f.result()
            print(f"{status} {jobs[f]} ({took:.0f} s)", flush=True)
            if status != "PASS":
                failed.append(f"{jobs[f]} ({status})")
                print("    " + "\n    ".join(text.strip().splitlines()[-25:]), flush=True)
    print(f"{len(cases) - len(failed)}/{len(cases)} passed in {time.time() - start:.0f} s"
          + (": failed " + ", ".join(sorted(failed)) if failed else ""))
    sys.exit(1 if failed else 0)
