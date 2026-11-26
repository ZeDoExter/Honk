#!/usr/bin/env python3
"""./honk — the Honk developer CLI (setup/doctor/new/dev/build/test).

Zero dependencies beyond Python 3. Run from anywhere; HONK_ROOT resolves to
this file's directory (override with $HONK_ROOT).
"""

import os
import shutil
import subprocess
import sys
import time

HONK_ROOT = os.path.abspath(os.environ.get(
    "HONK_ROOT", os.path.dirname(os.path.realpath(__file__))))
IS_WIN = os.name == "nt"


def goose_bin():
    if IS_WIN:
        p = os.path.join(HONK_ROOT, "goose_repo", "build", "Release", "goose.exe")
    else:
        p = os.path.join(HONK_ROOT, "goose_repo", "build-linux", "goose")
    return p if os.path.isfile(p) else shutil.which("goose")


def run(cmd, cwd=None, capture=False, env=None):
    return subprocess.run(cmd, cwd=cwd or HONK_ROOT, capture_output=capture,
                          text=True, env=env or os.environ)


def toolchain_fingerprint():
    """Canonical toolchain record: goose version/HEAD, cc, honk HEAD."""
    gb = goose_bin()
    goose_ver, goose_head = "", ""
    if gb:
        r = run([gb, "--version"], capture=True)
        goose_ver = r.stdout.strip() or r.stderr.strip()
        goose_head = git_head(os.path.join(HONK_ROOT, "goose_repo"))
    cc = shutil.which("gcc") or shutil.which("cc") or ""
    gcc_ver = ""
    if cc:
        r = run([cc, "--version"], capture=True)
        gcc_ver = (r.stdout.strip().splitlines() or [""])[0]
    return {
        "goose": goose_ver,
        "goose_head": goose_head,
        "goose_pinned": PINNED_GOOSE,
        "cc": gcc_ver,
        "honk_head": git_head(HONK_ROOT),
    }


def write_build_info(out_bin, asan):
    """Stamp a `<binary>.build-info` audit sidecar next to build output."""
    try:
        fp = toolchain_fingerprint()
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(out_bin + ".build-info", "w") as f:
            f.write(f"honk: {fp['honk_head']}\n")
            f.write(f"goose: {fp['goose']}\n")
            f.write(f"goose-head: {fp['goose_head']}\n")
            f.write(f"cc: {fp['cc']}\n")
            f.write(f"asan: {asan}\n")
            f.write(f"built-at: {ts}\n")
    except OSError:
        pass


def cmd_doctor(_args):
    print(f"Honk root: {HONK_ROOT}")
    ok = True

    def check(name, found, hint):
        nonlocal ok
        print(f"  [{'OK' if found else 'MISS'}] {name}" + ("" if found else f" — {hint}"))
        ok = ok and found

    check("OS is Linux/WSL2", not IS_WIN, "Honk servers need Linux epoll (use WSL2 on Windows)")
    check("python3", bool(shutil.which("python3")), "install Python 3")
    check("gcc/cc", bool(shutil.which("gcc") or shutil.which("cc")), "apt install gcc")
    gb = goose_bin()
    check("goose compiler", bool(gb), "build goose_repo first (see goose_repo README)")
    if gb:
        r = run([gb, "--version"], capture=True)
        print(f"        {r.stdout.strip() or r.stderr.strip()}")
        fp = toolchain_fingerprint()
        pinned = bool(fp["goose_head"]) and fp["goose_head"] == PINNED_GOOSE
        check(f"goose pinned ({PINNED_GOOSE[:9]})", pinned,
              f"got {(fp['goose_head'] or 'unknown')[:9]} — run ./honk setup")
        gclean = git_clean(os.path.join(HONK_ROOT, "goose_repo"))
        print(f"  [{'OK' if gclean else 'WARN'}] goose checkout clean"
              + ("" if gclean else " — local mods make builds unreproducible"))
        print(f"        cc: {fp['cc'] or 'unknown'}")
        print(f"        honk: {(fp['honk_head'] or 'unknown')[:9]}")
    wrk = shutil.which("wrk") or os.path.expanduser("~/.local/bin/wrk")
    has_wrk = os.path.isfile(wrk) if wrk else False
    print(f"  [{'OK' if has_wrk else 'opt.'}] wrk load generator"
          + ("" if has_wrk else " — needed only for bench/ (cargo install wrk)"))
    sys_sqlite = os.path.isfile("/usr/include/sqlite3.h")
    usr_sqlite = os.path.isfile(os.path.expanduser("~/.local/sqlite3/usr/include/sqlite3.h"))
    print(f"  [{'OK' if sys_sqlite or usr_sqlite else 'opt.'}] sqlite3 dev files"
          + (" (system)" if sys_sqlite else " (~/.local)" if usr_sqlite else
             " — needed only for SQLite apps (apt install libsqlite3-dev)"))
    return 0 if ok else 1


PINNED_GOOSE = "2239b92eb2ae0e8f390f98640b09ff57a17698fc"
GOOSE_UPSTREAM = "https://github.com/aardappel/goose.git"


def git_head(repo):
    try:
        r = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"],
                           capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def git_clean(repo):
    try:
        r = subprocess.run(["git", "-C", repo, "status", "--porcelain",
                            "--untracked-files=no"],
                           capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0 and r.stdout.strip() == ""


def cmd_setup(_args):
    """Fresh-clone bootstrap: fetch + pin + build Goose, then verify."""
    if IS_WIN:
        print("Windows native setup is not automated: install MSVC + CMake,",
              "build goose_repo/ manually, or (recommended) use WSL2 and re-run",
              "./honk setup there.", file=sys.stderr)
        return 1
    repo = os.path.join(HONK_ROOT, "goose_repo")
    want_bin = os.path.join(repo, "build-linux", "goose")
    if os.path.isfile(want_bin) and git_head(repo) == PINNED_GOOSE:
        print("goose already built at pinned commit; verifying...")
        return cmd_doctor([])
    for tool, pkg in (("git", "git"), ("cmake", "cmake"),
                      ("g++", "g++"), ("python3", "python3")):
        if not shutil.which(tool):
            print(f"missing {tool}: run",
                  "'sudo apt-get install -y git cmake g++ python3 make' first",
                  file=sys.stderr)
            return 1
    if not os.path.isdir(os.path.join(repo, ".git")):
        print(f"cloning {GOOSE_UPSTREAM} ...")
        r = run(["git", "clone", GOOSE_UPSTREAM, repo])
        if r.returncode != 0:
            return 1
    if git_head(repo) != PINNED_GOOSE:
        print(f"checking out pinned goose {PINNED_GOOSE[:9]} ...")
        if run(["git", "-C", repo, "fetch", "origin"]).returncode != 0:
            return 1
        if run(["git", "-C", repo, "checkout", PINNED_GOOSE]).returncode != 0:
            print("checkout failed (local changes in goose_repo?)",
                  file=sys.stderr)
            return 1
    jobs = str(os.cpu_count() or 4)
    print("configuring goose (cmake) ...")
    if run(["cmake", "-B", "build-linux", "-DCMAKE_BUILD_TYPE=Release"],
           cwd=repo).returncode != 0:
        return 1
    print(f"building goose (-j{jobs}, a few minutes) ...")
    if run(["cmake", "--build", "build-linux", "--config", "Release",
            "-j", jobs], cwd=repo).returncode != 0:
        return 1
    return cmd_doctor([])


HONK_GIT_SOURCE = "ZeDoExter/Honk@v1.0.0"

SCAFFOLD_MAIN = '''// {name} -- a Honk application (no .build file needed).
//
// Run:    ./honk dev {name}        (auto-reload on save)
// Build:  ./honk build {name} --release

import std;
import honk from "{source}";

fn main() {{
    let port = honk::arg_port(18080);
    print("{name} listening on port ", port);
    flush_stdout();
    honk::listen(port) {{ app =>
        app.get("/", "Hello from {name}!");
        app.get("/users/:id") {{
            app.json() {{ j => j.set("id", app.param("id")); }};
        }};
        app.post("/users") {{
            app.require_str("name") {{ n =>
                let age, has_age = app.body_int("age");
                if !has_age {{
                    app.json_error(400, "name (string) and age (int) are required");
                }} else {{
                    app.created_json() {{ j =>
                        j.set("created", true);
                        j.set("name", n);
                        j.set("age", age);
                    }};
                }}
            }};
        }};
    }};
}}
'''


def portable_source(dest_dir, use_git=False):
    if use_git:
        return HONK_GIT_SOURCE
    try:
        rel = os.path.relpath(HONK_ROOT, dest_dir).replace("\\", "/")
        if not rel.startswith("."):
            rel = "./" + rel
        return rel
    except ValueError:
        return HONK_ROOT.replace("\\", "/")


def cmd_new(args):
    use_git = False
    pos = []
    for a in args:
        if a == "--git":
            use_git = True
        elif a.startswith("-"):
            print(f"error: unknown flag {a} (supported: --git)", file=sys.stderr)
            return 2
        else:
            pos.append(a)
    if len(pos) != 1:
        print("usage: ./honk new <app-name> [--git]  (aliases: init)", file=sys.stderr)
        return 2
    dest = os.path.abspath(pos[0])
    if os.path.exists(dest):
        print(f"error: {dest} already exists", file=sys.stderr)
        return 1
    os.makedirs(dest)
    src = portable_source(dest, use_git=use_git)
    with open(os.path.join(dest, "main.goose"), "w") as f:
        f.write(SCAFFOLD_MAIN.format(name=os.path.basename(dest), source=src))
    print(f"scaffolded {dest}/main.goose (import honk from \"{src}\")")
    print(f"  ./honk dev {dest}     # run with auto-reload")
    print(f"  ./honk build {dest} --release")
    return 0


def resolve_app(path):
    """Return (app_dir, goose_file, app_name) for a path-or-cwd app."""
    if path and path.endswith(".goose"):
        app_dir = os.path.dirname(os.path.abspath(path)) or os.getcwd()
        goose_file = os.path.abspath(path)
    else:
        app_dir = os.path.abspath(path or os.getcwd())
        cands = [os.path.join(app_dir, n) for n in ("main.goose", "app.goose")]
        goose_file = next((c for c in cands if os.path.isfile(c)), None)
        if goose_file is None:
            print(f"error: no main.goose/app.goose in {app_dir}", file=sys.stderr)
            return None
    return app_dir, goose_file, os.path.splitext(os.path.basename(goose_file))[0]


def sqlite_env():
    """CPATH/LIBRARY_PATH for a user-space sqlite3 (no-op if system-wide)."""
    base = os.path.expanduser("~/.local/sqlite3/usr")
    inc = os.path.join(base, "include")
    lib = os.path.join(base, "lib", "x86_64-linux-gnu")
    env = {}
    if os.path.isfile(os.path.join(inc, "sqlite3.h")):
        prev = os.environ.get("CPATH")
        env["CPATH"] = inc + (":" + prev if prev else "")
    if os.path.lexists(os.path.join(lib, "libsqlite3.so")):
        prev = os.environ.get("LIBRARY_PATH")
        env["LIBRARY_PATH"] = lib + (":" + prev if prev else "")
    return env


def uses_sqlite(goose_file):
    try:
        with open(goose_file) as f:
            return "honk_sqlite" in f.read()
    except OSError:
        return False


def build_app(goose_file, out_bin, asan=False):
    gb = goose_bin()
    if not gb:
        return False, "goose compiler not found (run ./honk doctor)"
    env = dict(os.environ)
    env.update(sqlite_env())
    if not asan:
        r = run([gb, "build", goose_file, "-o", out_bin], capture=True, env=env)
        ok = r.returncode == 0
        if ok:
            write_build_info(out_bin, asan=False)
        return ok, (r.stdout + r.stderr)[-3000:]
    stem = os.path.splitext(out_bin)[0]
    standalone = stem + ".standalone.c"
    r = run([gb, "-o", standalone, "--standalone", goose_file], capture=True, env=env)
    if r.returncode != 0:
        return False, (r.stdout + r.stderr)[-3000:]
    shim = os.path.join(HONK_ROOT, "src", "shim")
    rt = os.path.join(HONK_ROOT, "goose_repo", "src", "runtime")
    cc = shutil.which("gcc") or "cc"
    srcs = [f"{shim}/honk_shim.c", f"{shim}/picohttpparser.c"]
    libs = ["-lm", "-pthread", "-ldl"]
    if uses_sqlite(goose_file):
        srcs.append(f"{shim}/honk_sqlite_shim.c")
        libs.append("-lsqlite3")
    r = run([cc, "-O1", "-g", "-fsanitize=address,undefined",
             "-fno-sanitize-recover=all", f"-I{shim}", f"-I{rt}", standalone,
             *srcs, "-o", out_bin, *libs], capture=True, env=env)
    try:
        os.remove(standalone)
    except OSError:
        pass
    ok = r.returncode == 0
    if ok:
        write_build_info(out_bin, asan=True)
    return ok, (r.stdout + r.stderr)[-3000:]


def cmd_build(args):
    path, asan = None, False
    for a in args:
        if a == "--asan":
            asan = True
        elif a == "--release":
            pass
        elif a.startswith("-"):
            print(f"error: unknown flag {a}", file=sys.stderr)
            return 2
        else:
            path = a
    app = resolve_app(path)
    if app is None:
        return 2
    app_dir, goose_file, name = app
    dist = os.path.join(app_dir, "dist")
    os.makedirs(dist, exist_ok=True)
    out = os.path.join(dist, name + ("_asan" if asan else ""))
    print(f"building {goose_file} -> {out} ({'asan' if asan else 'release'}) ...")
    t0 = time.time()
    ok, log = build_app(goose_file, out, asan=asan)
    dt = time.time() - t0
    if not ok:
        print(log)
        print("BUILD FAILED", file=sys.stderr)
        return 1
    kb = os.path.getsize(out) / 1024
    print(f"built in {dt:.1f}s: {out} ({kb:.1f} KiB)")
    return 0


WATCH_EXTS = (".goose", ".c", ".h", ".sql", ".build")
COMPILED_EXTS = (".goose", ".c", ".h", ".build")


def watch_mtimes(dirs):
    out = {}
    for app_dir in dirs:
        for root, _ds, files in os.walk(app_dir):
            if "node_modules" in root or ".git" in root:
                continue
            for fn in files:
                if fn.endswith(WATCH_EXTS):
                    p = os.path.join(root, fn)
                    try:
                        out[p] = os.path.getmtime(p)
                    except OSError:
                        pass
    return out


def cmd_dev(args):
    sys.stdout.reconfigure(line_buffering=True)
    rest = list(args)
    extra_watch = []
    while "--watch" in rest:
        wi = rest.index("--watch")
        if wi + 1 >= len(rest):
            print("error: --watch needs a directory", file=sys.stderr)
            return 2
        extra_watch.append(rest.pop(wi + 1))
        rest.pop(wi)
    path = rest[0] if rest and not rest[0].startswith("-") else None
    extra = [a for a in rest if a != path]
    app = resolve_app(path)
    if app is None:
        return 2
    app_dir, goose_file, name = app
    out = os.path.join(app_dir, f".honk-dev-{name}")
    watch_dirs = [app_dir] + [d if os.path.isabs(d) else os.path.abspath(d)
                              for d in extra_watch]
    print(f"dev {goose_file} (rebuild on save, Ctrl-C to stop)")
    proc = None

    def spawn():
        nonlocal proc
        proc = subprocess.Popen([out] + extra, cwd=app_dir)
        print(f"[dev] up: {out} (pid {proc.pid})")

    def start():
        ok, log = build_app(goose_file, out)
        if not ok:
            print(log)
            print("[dev] build failed — fix and save to retry")
            return
        spawn()

    def stop():
        nonlocal proc
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        proc = None

    start()
    known = watch_mtimes(watch_dirs)
    try:
        while True:
            time.sleep(0.3)
            if proc and proc.poll() is not None:
                print(f"[dev] process exited (code {proc.returncode}) — waiting for changes")
                proc = None
            now = watch_mtimes(watch_dirs)
            if now != known:
                changed = [p for p in set(now) | set(known) if now.get(p) != known.get(p)]
                known = now
                if any(p.endswith(COMPILED_EXTS) for p in changed):
                    print("[dev] change detected — rebuilding...")
                    stop()
                    start()
                else:
                    print("[dev] data-only change — restarting...")
                    stop()
                    if os.path.isfile(out):
                        spawn()
                    else:
                        start()
    except KeyboardInterrupt:
        print("\n[dev] stopping")
    finally:
        stop()
        try:
            os.remove(out)
        except OSError:
            pass
    return 0


def cmd_test(_args):
    gb = goose_bin()
    if not gb:
        print("error: goose compiler not found (run ./honk doctor)", file=sys.stderr)
        return 1
    fails = []

    def gate(title, fn):
        print(f"\n### {title}")
        try:
            fn()
        except subprocess.CalledProcessError as e:
            print(f"FAILED (exit {e.returncode})")
            fails.append(title)
            return
        print("PASS")

    def build(goose_src, out):
        env = dict(os.environ)
        env.update(sqlite_env())
        r = run([gb, "build", goose_src, "-o", out], capture=True, env=env)
        if r.returncode != 0:
            print((r.stdout + r.stderr)[-2000:])
            raise subprocess.CalledProcessError(r.returncode, goose_src)

    def build_asan(goose_src, out):
        ok, log = build_app(goose_file=goose_src, out_bin=out, asan=True)
        if not ok:
            print(log[-2000:])
            raise subprocess.CalledProcessError(1, goose_src)

    def suite(cmd):
        r = run(cmd)
        if r.returncode != 0:
            raise subprocess.CalledProcessError(r.returncode, cmd)

    gate("build: servers + stack + unit + helpers + dsl + net + fullstack-test + quickstart + fullstack", lambda: [
        build("src/server_minimal.goose", "src/server_minimal"),
        build("src/server.goose", "src/server"),
        build("test/test_stack_discipline.goose", "test/test_stack_discipline"),
        build("test/test_unit_app.goose", "test/test_unit_app"),
        build("test/helpers_app.goose", "test/helpers_app"),
        build("test/app_dsl.goose", "test/app_dsl"),
        build("test/app_net.goose", "test/app_net"),
        build("test/app_fullstack.goose", "test/app_fullstack"),
        build("examples/quickstart/app.goose", "examples/quickstart/app"),
        build("examples/fullstack_todo/app.goose", "examples/fullstack_todo/app"),
    ])
    gate("stack discipline 900k turns",
         lambda: suite(["./test/test_stack_discipline"]))
    gate("in-memory unit suite (Release)",
         lambda: suite(["./test/test_unit_app"]))
    gate("transport suite (Release)",
         lambda: suite(["python3", "test/test_transport.py", "./src/server_minimal"]))
    gate("framework suite (Release)",
         lambda: suite(["python3", "test/test_framework.py", "./src/server", "18210", "Release"]))
    gate("web-helper suite (Release)",
         lambda: suite(["python3", "test/test_web.py", "./test/helpers_app", "18420", "Release"]))
    gate("app-dsl + runtime suite (Release)",
         lambda: suite(["python3", "test/test_dsl.py", "./test/app_dsl", "18430", "Release"]))
    gate("net suite (Release)",
         lambda: suite(["python3", "test/test_net.py", "./test/app_net", "18470", "Release"]))
    gate("build: ASan server + unit + helpers + dsl + net + fullstack-test + fullstack", lambda: [
        build_asan("src/server.goose", "src/server_asan"),
        build_asan("test/test_unit_app.goose", "test/test_unit_app_asan"),
        build_asan("test/helpers_app.goose", "test/helpers_app_asan"),
        build_asan("test/app_dsl.goose", "test/app_dsl_asan"),
        build_asan("test/app_net.goose", "test/app_net_asan"),
        build_asan("test/app_fullstack.goose", "test/app_fullstack_asan"),
        build_asan("examples/fullstack_todo/app.goose", "examples/fullstack_todo/app_asan"),
    ])
    gate("in-memory unit suite (ASan+UBSan+LSan)",
         lambda: suite(["./test/test_unit_app_asan"]))
    gate("framework suite (ASan+UBSan+LSan)",
         lambda: suite(["python3", "test/test_framework.py", "./src/server_asan", "18310", "ASan"]))
    gate("web-helper suite (ASan+UBSan+LSan)",
         lambda: suite(["python3", "test/test_web.py", "./test/helpers_app_asan", "18421", "ASan"]))
    gate("app-dsl + runtime suite (ASan+UBSan+LSan)",
         lambda: suite(["python3", "test/test_dsl.py", "./test/app_dsl_asan", "18460", "ASan"]))
    gate("net suite (ASan+UBSan+LSan)",
         lambda: suite(["python3", "test/test_net.py", "./test/app_net_asan", "18471", "ASan"]))
    gate("fullstack suite (Release)",
         lambda: suite(["python3", "test/test_fullstack.py", "./test/app_fullstack", "18440", "Release"]))
    gate("fullstack suite (ASan+UBSan+LSan)",
         lambda: suite(["python3", "test/test_fullstack.py", "./test/app_fullstack_asan", "18450", "ASan"]))

    print(f"\n{'ALL GREEN' if not fails else 'FAILURES: ' + ', '.join(fails)}")
    return 0 if not fails else 1


def main(argv):
    cmds = {"doctor": cmd_doctor, "setup": cmd_setup, "new": cmd_new, "init": cmd_new,
            "dev": cmd_dev, "build": cmd_build, "test": cmd_test}
    if len(argv) < 2 or argv[1] not in cmds:
        print("usage: ./honk {setup|doctor|new|dev|build|test} [...]", file=sys.stderr)
        return 2
    return cmds[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
