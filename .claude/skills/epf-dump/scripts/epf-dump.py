#!/usr/bin/env python3
# epf-dump v1.3 — Dump external data processor or report (EPF/ERF) to XML sources
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
        description="Dump external data processor or report (EPF/ERF) to XML sources",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="", help="Path to 1cv8.exe or its bin directory")
    parser.add_argument("-InfoBasePath", default="", help="Path to file infobase")
    parser.add_argument("-InfoBaseServer", default="", help="1C server (for server infobase)")
    parser.add_argument("-InfoBaseRef", default="", help="Infobase name on server")
    parser.add_argument("-UserName", default="", help="1C user name")
    parser.add_argument("-Password", default="", help="1C user password")
    parser.add_argument("-InputFile", required=True, help="Path to EPF/ERF file")
    parser.add_argument("-OutputDir", required=True, help="Directory for dumped XML sources")
    parser.add_argument(
        "-Format",
        default="Hierarchical",
        choices=["Hierarchical", "Plain"],
        help="Dump format (default: Hierarchical)",
    )
    args = parser.parse_args()

    # --- Resolve V8Path ---
    v8path = resolve_v8path(args.V8Path)
    engine = "ibcmd" if os.path.basename(v8path).lower().startswith("ibcmd") else "1cv8"

    # --- Validate database connection ---
    if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        print("Error: database connection required. Specify -InfoBasePath or -InfoBaseServer/-InfoBaseRef", file=sys.stderr)
        print("Dump in an empty database loses reference types (CatalogRef, DocumentRef, etc.) irreversibly.")
        sys.exit(1)
    if engine == "ibcmd":
        if not args.InfoBasePath:
            print("Error: ibcmd supports file infobases only (use -InfoBasePath)", file=sys.stderr)
            sys.exit(1)
        if args.Format == "Plain":
            print("Error: ibcmd config export supports hierarchical format only (use -Format Hierarchical or 1cv8)", file=sys.stderr)
            sys.exit(1)

    # --- Validate input file ---
    if not os.path.isfile(args.InputFile):
        print(f"Error: input file not found: {args.InputFile}", file=sys.stderr)
        sys.exit(1)

    # --- Ensure output directory exists ---
    if not os.path.exists(args.OutputDir):
        os.makedirs(args.OutputDir, exist_ok=True)

    # --- Temp dir ---
    temp_dir = os.path.join(tempfile.gettempdir(), f"epf_dump_{random.randint(0, 999999)}")
    os.makedirs(temp_dir, exist_ok=True)

    try:
        if engine == "ibcmd":
            # --- ibcmd branch: dump EPF/ERF via config export --file ---
            arguments = ["infobase", "config", "export", f"--file={args.InputFile}", args.OutputDir, f"--db-path={args.InfoBasePath}"]
            ib_data = tempfile.mkdtemp(prefix="ibcmd_data_")
            atexit.register(shutil.rmtree, ib_data, ignore_errors=True)
            arguments.append(f"--data={ib_data}")
            print(f"Running: ibcmd {' '.join(arguments)}")
            result = subprocess.run([v8path] + arguments, capture_output=True, encoding="utf-8", errors="replace")
            if result.returncode == 0:
                print(f"External data processor/report dumped successfully to: {args.OutputDir}")
            else:
                print(f"Error dumping external data processor/report (code: {result.returncode})", file=sys.stderr)
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            sys.exit(result.returncode)

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

        arguments += ["/DumpExternalDataProcessorOrReportToFiles", args.OutputDir, args.InputFile]
        arguments += ["-Format", args.Format]

        # --- Output ---
        out_file = os.path.join(temp_dir, "dump_log.txt")
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

        # --- Result ---
        if exit_code == 0:
            print(f"Dump completed successfully to: {args.OutputDir}")
        else:
            print(f"Error dumping (code: {exit_code})", file=sys.stderr)

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
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
