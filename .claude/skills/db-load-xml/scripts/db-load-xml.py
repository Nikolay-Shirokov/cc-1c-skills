#!/usr/bin/env python3
# db-load-xml v1.9 — Load 1C configuration from XML files
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


def _version_key(p):
    """Numeric sort key from version dir name (.../1cv8/<ver>/bin/1cv8.exe)."""
    ver = os.path.basename(os.path.dirname(os.path.dirname(p)))
    return [int(x) for x in re.findall(r"\d+", ver)]


def resolve_v8path(v8path):
    """Resolve path to 1cv8.exe."""
    if not v8path:
        v8path = _find_project_v8path()
    if not v8path:
        candidates = (
            glob.glob(r"C:\Program Files\1cv8\*\bin\1cv8.exe")
            + glob.glob(r"C:\Program Files (x86)\1cv8\*\bin\1cv8.exe")
        )
        if candidates:
            v8path = max(candidates, key=_version_key)
            ver = os.path.basename(os.path.dirname(os.path.dirname(v8path)))
            print(f"Auto-selected platform {ver}: {v8path}")
        else:
            print("Error: 1cv8.exe not found. Specify -V8Path", file=sys.stderr)
            sys.exit(1)
    if os.path.isdir(v8path):
        v8path = os.path.join(v8path, "1cv8.exe")
    if not os.path.isfile(v8path):
        print(f"Error: 1cv8.exe not found at {v8path}", file=sys.stderr)
        sys.exit(1)
    return v8path


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
        arguments.append(f"--data={ib_data}")
        print(f"Running: ibcmd {' '.join(arguments)}")
        result = subprocess.run([v8path] + arguments, capture_output=True, encoding="utf-8", errors="replace")
        if result.returncode != 0:
            print(f"Error loading configuration from files (code: {result.returncode})", file=sys.stderr)
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
            apply_args.append(f"--data={ib_data}")
            print(f"Running: ibcmd {' '.join(apply_args)}")
            ar = subprocess.run([v8path] + apply_args, capture_output=True, encoding="utf-8", errors="replace")
            exit_code = ar.returncode
            if exit_code == 0:
                print("Database configuration updated successfully")
            else:
                print(f"Error updating database configuration (code: {exit_code})", file=sys.stderr)
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
        print(f"Running: 1cv8.exe {' '.join(arguments)}")
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
            print(f"Error loading configuration (code: {exit_code})", file=sys.stderr)

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
