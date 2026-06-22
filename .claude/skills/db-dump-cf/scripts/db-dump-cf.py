#!/usr/bin/env python3
# db-dump-cf v1.3 — Dump 1C configuration to CF file
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
        description="Dump 1C configuration to CF file",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="")
    parser.add_argument("-InfoBasePath", default="")
    parser.add_argument("-InfoBaseServer", default="")
    parser.add_argument("-InfoBaseRef", default="")
    parser.add_argument("-UserName", default="")
    parser.add_argument("-Password", default="")
    parser.add_argument("-OutputFile", required=True)
    parser.add_argument("-Extension", default="")
    parser.add_argument("-AllExtensions", action="store_true")
    args = parser.parse_args()

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

    # --- Ensure output directory exists ---
    out_dir = os.path.dirname(args.OutputFile)
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    # --- ibcmd branch (file infobase only) ---
    if engine == "ibcmd":
        if args.AllExtensions:
            print("Error: ibcmd config save does not support -AllExtensions (use -Extension)", file=sys.stderr)
            sys.exit(1)
        arguments = ["infobase", "config", "save", f"--db-path={args.InfoBasePath}"]
        if args.Extension:
            arguments.append(f"--extension={args.Extension}")
        arguments.append(args.OutputFile)
        ib_data = tempfile.mkdtemp(prefix="ibcmd_data_")
        atexit.register(shutil.rmtree, ib_data, ignore_errors=True)
        arguments.append(f"--data={ib_data}")
        print(f"Running: ibcmd {' '.join(arguments)}")
        result = subprocess.run([v8path] + arguments, capture_output=True, encoding="utf-8", errors="replace")
        if result.returncode == 0:
            print(f"Configuration dumped successfully to: {args.OutputFile}")
        else:
            print(f"Error dumping configuration (code: {result.returncode})", file=sys.stderr)
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(result.returncode)

    # --- Temp dir ---
    temp_dir = os.path.join(tempfile.gettempdir(), f"db_dump_cf_{random.randint(0, 999999)}")
    os.makedirs(temp_dir, exist_ok=True)

    try:
        # --- Build arguments ---
        arguments = ["DESIGNER"]

        if args.InfoBaseServer and args.InfoBaseRef:
            arguments.extend(["/S", f"{args.InfoBaseServer}/{args.InfoBaseRef}"])
        else:
            arguments.extend(["/F", args.InfoBasePath])

        if args.UserName:
            arguments.append(f"/N{args.UserName}")
        if args.Password:
            arguments.append(f"/P{args.Password}")

        arguments.extend(["/DumpCfg", args.OutputFile])

        # --- Extensions ---
        if args.Extension:
            arguments.extend(["-Extension", args.Extension])
        elif args.AllExtensions:
            arguments.append("-AllExtensions")

        # --- Output ---
        out_file = os.path.join(temp_dir, "dump_cf_log.txt")
        arguments.extend(["/Out", out_file])
        arguments.append("/DisableStartupDialogs")

        # --- Execute ---
        print(f"Running: 1cv8.exe {' '.join(arguments)}")
        result = subprocess.run(
            [v8path] + arguments,
            capture_output=True,
            text=True,
        )
        exit_code = result.returncode

        # --- Result ---
        if exit_code == 0:
            print(f"Configuration dumped successfully to: {args.OutputFile}")
        else:
            print(f"Error dumping configuration (code: {exit_code})", file=sys.stderr)

        if os.path.isfile(out_file):
            try:
                with open(out_file, "r", encoding="utf-8-sig") as f:
                    log_content = f.read()
                if log_content:
                    print("--- Log ---")
                    print(log_content)
                    print("--- End ---")
            except Exception:
                pass

        sys.exit(exit_code)

    finally:
        if os.path.isdir(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
