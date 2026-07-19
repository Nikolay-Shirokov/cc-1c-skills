#!/usr/bin/env python3
# db-load-xml v1.16 — Load 1C configuration from XML files
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import atexit
import glob
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile


def _find_project_v8path():
    """Walk up from CWD to find .v8-project.json and read its v8path."""
    d = os.getcwd()
    while True:
        pf = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pf):
            try:
                with open(pf, encoding="utf-8-sig") as f:
                    data = json.load(f)
                v = data.get("v8path")
                if v:
                    return v
            except Exception:
                pass
            return None
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _version_dir(p):
    """Version dir for both Windows (.../1cv8/<ver>/bin/1cv8.exe) and *nix (.../1cv8/<ver>/1cv8)."""
    parent = os.path.dirname(p)
    if os.path.basename(parent).lower() == "bin":
        parent = os.path.dirname(parent)
    return os.path.basename(parent)


def _version_key(p):
    """Numeric sort key from version dir name."""
    return [int(x) for x in re.findall(r"\d+", _version_dir(p))]


def resolve_v8path(v8path):
    """Resolve path to a 1C executable (1cv8; ibcmd only when given explicitly)."""
    if not v8path:
        v8path = _find_project_v8path()
    if not v8path:
        if os.name == "nt":
            candidates = (
                glob.glob(r"C:\Program Files\1cv8\*\bin\1cv8.exe")
                + glob.glob(r"C:\Program Files (x86)\1cv8\*\bin\1cv8.exe")
            )
        else:
            # PY-only: PS-порт на *nix не исполняется, поэтому *nix-раскладки нет в .ps1.
            candidates = glob.glob("/opt/1cv8/*/1cv8")
        if candidates:
            v8path = max(candidates, key=_version_key)
            print(f"Auto-selected platform {_version_dir(v8path)}: {v8path}")
        else:
            print("Error: 1C executable not found. Specify -V8Path", file=sys.stderr)
            sys.exit(1)
    if os.path.isdir(v8path):
        # PY-only: на *nix исполняемый называется "1cv8" (без .exe); ibcmd — только явным путём.
        exe = "1cv8.exe" if os.name == "nt" else "1cv8"
        v8path = os.path.join(v8path, exe)
    if not os.path.isfile(v8path):
        print(f"Error: 1C executable not found at {v8path}", file=sys.stderr)
        sys.exit(1)
    return v8path


IBCMD_NOUSER_HINT = (
    "[ibcmd] No -UserName/-Password given; the infobase may require authentication. "
    "On Windows ibcmd reads credentials from the console (stdin is ignored), so this "
    "call may block instead of failing. If it does not return promptly, abort and "
    "re-run with -UserName and -Password.\n"
)


def run_ibcmd(cmd, has_username=False, warn_no_user=True):
    """Run an ibcmd command non-interactively.

    input="" closes stdin (EOF) so ibcmd's auth prompt fast-fails instead of hanging.
    On Windows without -UserName ibcmd reads the console directly and may still block —
    that residual case is flagged via IBCMD_NOUSER_HINT (model-facing).
    """
    if warn_no_user and os.name == "nt" and not has_username:
        sys.stderr.write(IBCMD_NOUSER_HINT)
        sys.stderr.flush()
    return subprocess.run(cmd, input="", capture_output=True, encoding="utf-8", errors="replace")


def describe_exit(code):
    """Annotate an abnormal process exit code so a crash isn't reported as a bare number.
    Batch 1C in a broken/headless environment (no GUI session, no license) can crash mid-run
    instead of returning a clean error, possibly leaving the infobase locked or half-mutated."""
    if code is None:
        return ""
    win = {
        3221225477: "0xC0000005 (access violation)", -1073741819: "0xC0000005 (access violation)",
        3221225781: "0xC0000135 (missing DLL)", -1073741515: "0xC0000135 (missing DLL)",
        3221226505: "0xC0000409 (stack overrun)", -1073740791: "0xC0000409 (stack overrun)",
    }
    if code in win:
        return f" — abnormal termination, exception {win[code]}; the infobase may be left in an inconsistent state; verify it before retrying"
    if -64 <= code < 0:
        try:
            import signal
            name = signal.Signals(-code).name
        except (ValueError, AttributeError):
            name = f"signal {-code}"
        return (f" — process terminated by {name} (abnormal termination, not a normal exit); "
                "the infobase may be left in an inconsistent state; verify it before retrying")
    return ""


def _redact(text, *secrets):
    """Redact literal secret values (password, user) from a display string —
    precise, never touches lookalike paths."""
    for s in secrets:
        if s:
            text = text.replace(s, "***")
    return text


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Load 1C configuration from XML files",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="", help="Path to 1cv8.exe or its bin directory")
    parser.add_argument("-InfoBasePath", default="", help="Path to file infobase")
    parser.add_argument("-InfoBaseServer", default="", help="1C server (for server infobase)")
    parser.add_argument("-InfoBaseRef", default="", help="Infobase name on server")
    parser.add_argument("-UserName", default="", help="1C user name")
    parser.add_argument("-Password", default="", help="1C user password")
    parser.add_argument("-ConfigDir", required=True, help="Directory with XML configuration sources")
    parser.add_argument(
        "-Mode",
        default="Full",
        choices=["Full", "Partial"],
        help="Load mode (default: Full)",
    )
    parser.add_argument("-Files", default="", help="Comma-separated relative file paths (for Partial mode)")
    parser.add_argument("-ListFile", default="", help="Path to file list (alternative to -Files, for Partial mode)")
    parser.add_argument("-Extension", default="", help="Extension name to load")
    parser.add_argument("-AllExtensions", action="store_true", help="Load all extensions")
    parser.add_argument(
        "-Format",
        default="Hierarchical",
        choices=["Hierarchical", "Plain"],
        help="File format (default: Hierarchical)",
    )
    parser.add_argument("-UpdateDB", action="store_true", help="Also update database configuration after load")
    parser.add_argument(
        "-StrictLog",
        action="store_true",
        help="Treat silent rejection warnings in the log as errors (elevate exit code to 1)",
    )
    args = parser.parse_args()

    # --- Resolve V8Path ---
    v8path = resolve_v8path(args.V8Path)

    engine = "ibcmd" if os.path.basename(v8path).lower().startswith("ibcmd") else "1cv8"

    # --- Validate connection ---
    if engine == "ibcmd":
        if not args.InfoBasePath:
            print("Error: ibcmd supports file infobases only (use -InfoBasePath)", file=sys.stderr)
            sys.exit(1)
    elif not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        print("Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef", file=sys.stderr)
        sys.exit(1)

    # --- Validate config dir ---
    if not os.path.exists(args.ConfigDir):
        print(f"Error: config directory not found: {args.ConfigDir}", file=sys.stderr)
        sys.exit(1)

    # --- Validate Partial mode ---
    if args.Mode == "Partial" and not args.Files and not args.ListFile:
        print("Error: -Files or -ListFile required for Partial mode", file=sys.stderr)
        sys.exit(1)

    # --- ibcmd branch (file infobase only; hierarchical full-directory import) ---
    if engine == "ibcmd":
        if args.Format == "Plain":
            print("Error: ibcmd config import supports hierarchical format only (use -Format Hierarchical or 1cv8)", file=sys.stderr)
            sys.exit(1)
        if args.AllExtensions:
            arguments = ["infobase", "config", "import", "all-extensions", args.ConfigDir, f"--db-path={args.InfoBasePath}"]
        elif args.Mode == "Partial" or args.Files or args.ListFile:
            # partial: import specific files (relative to ConfigDir)
            if args.ListFile:
                if not os.path.isfile(args.ListFile):
                    print(f"Error: list file not found: {args.ListFile}", file=sys.stderr)
                    sys.exit(1)
                with open(args.ListFile, encoding="utf-8-sig") as f:
                    file_list = [ln.strip() for ln in f if ln.strip()]
            elif args.Files:
                file_list = [p.strip() for p in args.Files.split(",") if p.strip()]
            else:
                file_list = []
            if not file_list:
                print("Error: -Files or -ListFile required for partial import", file=sys.stderr)
                sys.exit(1)
            arguments = ["infobase", "config", "import", "files"] + file_list
            arguments += [f"--base-dir={args.ConfigDir}", f"--db-path={args.InfoBasePath}"]
            if args.Extension:
                arguments.append(f"--extension={args.Extension}")
        else:
            arguments = ["infobase", "config", "import", f"--db-path={args.InfoBasePath}"]
            if args.Extension:
                arguments.append(f"--extension={args.Extension}")
            arguments.append(args.ConfigDir)
        ib_data = tempfile.mkdtemp(prefix="ibcmd_data_")
        atexit.register(shutil.rmtree, ib_data, ignore_errors=True)
        if args.UserName:
            arguments.append(f"--user={args.UserName}")
        if args.Password:
            arguments.append(f"--password={args.Password}")
        arguments.append(f"--data={ib_data}")
        print(f"Running: ibcmd {_redact(' '.join(arguments), args.Password, args.UserName)}")
        result = run_ibcmd([v8path] + arguments, bool(args.UserName))
        if result.returncode != 0:
            print(f"Error loading configuration from files (code: {result.returncode}){describe_exit(result.returncode)}", file=sys.stderr)
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            sys.exit(result.returncode)
        print(f"Configuration loaded successfully from: {args.ConfigDir}")
        if result.stdout:
            print(result.stdout)
        exit_code = 0
        if args.UpdateDB:
            apply_args = ["infobase", "config", "apply", f"--db-path={args.InfoBasePath}", "--force"]
            if args.UserName:
                apply_args.append(f"--user={args.UserName}")
            if args.Password:
                apply_args.append(f"--password={args.Password}")
            apply_args.append(f"--data={ib_data}")
            print(f"Running: ibcmd {_redact(' '.join(apply_args), args.Password, args.UserName)}")
            ar = run_ibcmd([v8path] + apply_args, bool(args.UserName))
            exit_code = ar.returncode
            if exit_code == 0:
                print("Database configuration updated successfully")
            else:
                print(f"Error updating database configuration (code: {exit_code}){describe_exit(exit_code)}", file=sys.stderr)
            if ar.stdout:
                print(ar.stdout)
            if ar.stderr:
                print(ar.stderr, file=sys.stderr)
        sys.exit(exit_code)

    # --- Temp dir ---
    temp_dir = os.path.join(tempfile.gettempdir(), f"db_load_xml_{random.randint(0, 999999)}")
    os.makedirs(temp_dir, exist_ok=True)

    try:
        # --- Build arguments ---
        arguments = ["DESIGNER"]

        if args.InfoBaseServer and args.InfoBaseRef:
            arguments += ["/S", f"{args.InfoBaseServer}/{args.InfoBaseRef}"]
        else:
            arguments += ["/F", args.InfoBasePath]

        if args.UserName:
            arguments.append(f"/N{args.UserName}")
        if args.Password:
            arguments.append(f"/P{args.Password}")

        arguments += ["/LoadConfigFromFiles", args.ConfigDir]

        if args.Mode == "Full":
            print("Executing full configuration load...")
        else:
            print("Executing partial configuration load...")

            # Build list file
            if args.ListFile:
                if not os.path.isfile(args.ListFile):
                    print(f"Error: list file not found: {args.ListFile}", file=sys.stderr)
                    sys.exit(1)
                with open(args.ListFile, encoding="utf-8-sig") as f:
                    raw_list = [ln.strip() for ln in f if ln.strip()]
            else:
                raw_list = [f.strip() for f in args.Files.split(",") if f.strip()]

            # Support-state service files are NOT partially loadable — exclude with a hint.
            support_re = re.compile(r"ParentConfigurations\.bin$|(^|[\\/])ConfigDumpInfo\.xml$")
            support_files = [x for x in raw_list if support_re.search(x)]
            file_list = [x for x in raw_list if not support_re.search(x)]
            if support_files:
                print("[ВНИМАНИЕ] Служебные файлы состояния поддержки исключены из частичной загрузки (частично не грузятся):", file=sys.stderr)
                for sf in support_files:
                    print(f"  - {sf}", file=sys.stderr)
                print("  Смена состояния поддержки применяется только полной загрузкой: -Mode Full.", file=sys.stderr)
            if not file_list:
                print("Error: после исключения служебных файлов поддержки загружать нечего. Для смены поддержки используйте -Mode Full.", file=sys.stderr)
                sys.exit(1)
            generated_list_file = os.path.join(temp_dir, "load_list.txt")
            with open(generated_list_file, "w", encoding="utf-8-sig") as f:
                f.write("\n".join(file_list))
            print(f"Files to load: {len(file_list)}")
            for fl in file_list:
                print(f"  {fl}")

            arguments += ["-listFile", generated_list_file]
            arguments.append("-partial")
            arguments.append("-updateConfigDumpInfo")

        arguments += ["-Format", args.Format]

        # --- Extensions ---
        if args.Extension:
            arguments += ["-Extension", args.Extension]
        elif args.AllExtensions:
            arguments.append("-AllExtensions")

        # --- UpdateDB ---
        if args.UpdateDB:
            arguments.append("/UpdateDBCfg")

        # --- Output ---
        out_file = os.path.join(temp_dir, "load_log.txt")
        arguments += ["/Out", out_file]
        arguments.append("/DisableStartupDialogs")

        # --- Execute ---
        print(f"Running: 1cv8.exe {_redact(' '.join(arguments), args.Password, args.UserName)}")
        result = subprocess.run(
            [v8path] + arguments,
            capture_output=True,
            text=True,
        )
        exit_code = result.returncode

        # --- Read log ---
        log_content = ""
        if os.path.isfile(out_file):
            try:
                with open(out_file, "r", encoding="utf-8-sig") as f:
                    log_content = f.read()
            except Exception:
                log_content = ""

        # --- Scan log for silent rejections ---
        # Platform often writes load-time rejections into /Out but exits with code 0.
        # These patterns flag cases where metadata was dropped or rejected silently.
        fatal_log_patterns = [
            "Неверное свойство объекта метаданных",
            "не входит в состав объекта метаданных",
            "Неизвестное имя типа",
            "Неизвестный объект метаданных",
            "Ни один из документов не является регистратором для регистра",
            "Неверное значение перечисления",
            "не может быть приведен к типу",
        ]
        silent_failures = []
        if log_content:
            for line in log_content.splitlines():
                for pat in fatal_log_patterns:
                    if pat in line:
                        silent_failures.append(line.strip())
                        break

        # --- Result ---
        # Default: mirror platform's verdict via exit code. Log content (including any
        # rejection warnings) is always printed to stdout for visibility. With -StrictLog,
        # elevate exit code to 1 when rejection patterns are found even if platform said 0.
        if exit_code == 0:
            print("Load completed successfully")
        else:
            print(f"Error loading configuration (code: {exit_code}){describe_exit(exit_code)}", file=sys.stderr)

        if log_content:
            print("--- Log ---")
            print(log_content)
            print("--- End ---")

        if silent_failures:
            suffix = "" if args.StrictLog else " (pass -StrictLog to treat as error)"
            print(
                f"[warning] log contains {len(silent_failures)} rejection(s) — "
                f"platform loaded config but dropped properties/refs{suffix}",
                file=sys.stderr,
            )
            for f in silent_failures:
                print(f"  {f}", file=sys.stderr)
            if args.StrictLog and exit_code == 0:
                exit_code = 1

        sys.exit(exit_code)

    finally:
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
