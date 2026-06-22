#!/usr/bin/env python3
# db-dump-xml v1.5 — Dump 1C configuration to XML files
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
        description="Dump 1C configuration to XML files",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="", help="Path to 1cv8.exe or its bin directory")
    parser.add_argument("-InfoBasePath", default="", help="Path to file infobase")
    parser.add_argument("-InfoBaseServer", default="", help="1C server (for server infobase)")
    parser.add_argument("-InfoBaseRef", default="", help="Infobase name on server")
    parser.add_argument("-UserName", default="", help="1C user name")
    parser.add_argument("-Password", default="", help="1C user password")
    parser.add_argument("-ConfigDir", required=True, help="Directory for configuration dump")
    parser.add_argument(
        "-Mode",
        default="Changes",
        choices=["Full", "Changes", "Partial", "UpdateInfo"],
        help="Dump mode (default: Changes)",
    )
    parser.add_argument("-Objects", default="", help="Comma-separated metadata object names (for Partial mode)")
    parser.add_argument("-Extension", default="", help="Extension name to dump")
    parser.add_argument("-AllExtensions", action="store_true", help="Dump all extensions")
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

    # --- Validate connection ---
    if engine == "ibcmd":
        if not args.InfoBasePath:
            print("Error: ibcmd supports file infobases only (use -InfoBasePath)", file=sys.stderr)
            sys.exit(1)
    elif not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        print("Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef", file=sys.stderr)
        sys.exit(1)

    # --- Validate Partial mode ---
    if args.Mode == "Partial" and not args.Objects:
        print("Error: -Objects required for Partial mode", file=sys.stderr)
        sys.exit(1)

    # --- Create output dir if needed ---
    if not os.path.exists(args.ConfigDir):
        os.makedirs(args.ConfigDir, exist_ok=True)
        print(f"Created output directory: {args.ConfigDir}")

    # --- ibcmd branch (file infobase only; hierarchical Full/Changes) ---
    if engine == "ibcmd":
        if args.Format == "Plain":
            print("Error: ibcmd config export supports hierarchical format only (use -Format Hierarchical or 1cv8)", file=sys.stderr)
            sys.exit(1)
        if args.AllExtensions:
            arguments = ["infobase", "config", "export", "all-extensions", args.ConfigDir, f"--db-path={args.InfoBasePath}"]
        elif args.Mode == "UpdateInfo":
            print("Error: ibcmd config export does not support Mode UpdateInfo; use 1cv8", file=sys.stderr)
            sys.exit(1)
        elif args.Mode == "Partial":
            obj_list = [o.strip() for o in args.Objects.split(",") if o.strip()]
            arguments = ["infobase", "config", "export", "objects"] + obj_list
            arguments += [f"--out={args.ConfigDir}", f"--db-path={args.InfoBasePath}"]
            if args.Extension:
                arguments.append(f"--extension={args.Extension}")
        else:
            arguments = ["infobase", "config", "export", f"--db-path={args.InfoBasePath}"]
            if args.Extension:
                arguments.append(f"--extension={args.Extension}")
            arguments.append(args.ConfigDir)
        ib_data = tempfile.mkdtemp(prefix="ibcmd_data_")
        atexit.register(shutil.rmtree, ib_data, ignore_errors=True)
        arguments.append(f"--data={ib_data}")
        print(f"Running: ibcmd {' '.join(arguments)}")
        result = subprocess.run([v8path] + arguments, capture_output=True, encoding="utf-8", errors="replace")
        if result.returncode == 0:
            print(f"Configuration exported successfully to: {args.ConfigDir}")
        else:
            print(f"Error exporting configuration (code: {result.returncode})", file=sys.stderr)
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(result.returncode)

    # --- Temp dir ---
    temp_dir = os.path.join(tempfile.gettempdir(), f"db_dump_xml_{random.randint(0, 999999)}")
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

        arguments += ["/DumpConfigToFiles", args.ConfigDir]
        arguments += ["-Format", args.Format]

        if args.Mode == "Full":
            print("Executing full configuration dump...")
        elif args.Mode == "Changes":
            print("Executing incremental configuration dump...")
            arguments.append("-update")
            arguments.append("-force")
        elif args.Mode == "Partial":
            print("Executing partial configuration dump...")
            object_list = [obj.strip() for obj in args.Objects.split(",") if obj.strip()]

            list_file = os.path.join(temp_dir, "dump_list.txt")
            with open(list_file, "w", encoding="utf-8-sig") as f:
                f.write("\n".join(object_list))

            arguments += ["-listFile", list_file]
            print(f"Objects to dump: {len(object_list)}")
            for obj in object_list:
                print(f"  {obj}")
        elif args.Mode == "UpdateInfo":
            print("Updating ConfigDumpInfo.xml...")
            arguments.append("-configDumpInfoOnly")

        # --- Extensions ---
        if args.Extension:
            arguments += ["-Extension", args.Extension]
        elif args.AllExtensions:
            arguments.append("-AllExtensions")

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
            print("Dump completed successfully")
            print(f"Configuration dumped to: {args.ConfigDir}")
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
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
