#!/usr/bin/env python3
# db-load-xml v1.3 — Load 1C configuration from XML files
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import glob
import os
import random
import shutil
import subprocess
import sys
import tempfile


def resolve_v8path(v8path):
    """Resolve path to 1cv8.exe."""
    if not v8path:
        candidates = glob.glob(r"C:\Program Files\1cv8\*\bin\1cv8.exe")
        if candidates:
            candidates.sort()
            return candidates[-1]
        else:
            print("Error: 1cv8.exe not found. Specify -V8Path", file=sys.stderr)
            sys.exit(1)
    elif os.path.isdir(v8path):
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

    # --- Validate connection ---
    if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
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
            generated_list_file = None
            if args.ListFile:
                # Use provided list file
                if not os.path.isfile(args.ListFile):
                    print(f"Error: list file not found: {args.ListFile}", file=sys.stderr)
                    sys.exit(1)
                generated_list_file = args.ListFile
            else:
                # Generate from -Files parameter
                file_list = [f.strip() for f in args.Files.split(",") if f.strip()]
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
