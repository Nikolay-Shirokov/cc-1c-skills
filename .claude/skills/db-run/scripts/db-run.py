#!/usr/bin/env python3
# db-run v1.1 — Launch 1C:Enterprise
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import glob
import json
import os
import re
import subprocess
import sys


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
    """Return version dir for both Windows bin layout and Unix platform layout."""
    parent = os.path.dirname(p)
    if os.path.basename(parent).lower() == "bin":
        parent = os.path.dirname(parent)
    return os.path.basename(parent)


def _version_key(p):
    """Numeric sort key from version dir name (.../1cv8/<ver>/1cv8)."""
    return [int(x) for x in re.findall(r"\d+", _version_dir(p))]


def _v8_executable_names():
    if os.name == "nt":
        return ["1cv8.exe", "1cv8c.exe", "ibcmd.exe"]
    return ["1cv8", "1cv8c", "ibcmd"]


def _v8_candidates():
    if os.name == "nt":
        return (
            glob.glob(r"C:\Program Files\1cv8\*\bin\1cv8.exe")
            + glob.glob(r"C:\Program Files (x86)\1cv8\*\bin\1cv8.exe")
        )
    candidates = []
    for exe_name in _v8_executable_names():
        candidates.extend(glob.glob(os.path.join("/opt/1cv8", "*", exe_name)))
    return candidates


def resolve_v8path(v8path):
    """Resolve path to a 1C executable."""
    if not v8path:
        v8path = _find_project_v8path()
    if not v8path:
        candidates = _v8_candidates()
        if candidates:
            v8path = max(candidates, key=_version_key)
            print(f"Auto-selected platform {_version_dir(v8path)}: {v8path}")
        else:
            print("Error: 1C executable not found. Specify -V8Path", file=sys.stderr)
            sys.exit(1)
    if os.path.isdir(v8path):
        for exe_name in _v8_executable_names():
            candidate = os.path.join(v8path, exe_name)
            if os.path.isfile(candidate):
                v8path = candidate
                break
        else:
            tried = ", ".join(_v8_executable_names())
            print(f"Error: 1C executable not found in {v8path} (tried: {tried})", file=sys.stderr)
            sys.exit(1)
    if not os.path.isfile(v8path):
        print(f"Error: 1C executable not found at {v8path}", file=sys.stderr)
        sys.exit(1)
    return v8path


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Launch 1C:Enterprise",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="")
    parser.add_argument("-InfoBasePath", default="")
    parser.add_argument("-InfoBaseServer", default="")
    parser.add_argument("-InfoBaseRef", default="")
    parser.add_argument("-UserName", default="")
    parser.add_argument("-Password", default="")
    parser.add_argument("-Execute", default="")
    parser.add_argument("-CParam", default="")
    parser.add_argument("-URL", default="")
    args = parser.parse_args()

    v8path = resolve_v8path(args.V8Path)

    # --- Validate connection ---
    if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        print("Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef", file=sys.stderr)
        sys.exit(1)

    # --- Build arguments ---
    arguments = ["ENTERPRISE"]

    if args.InfoBaseServer and args.InfoBaseRef:
        arguments.extend(["/S", f"{args.InfoBaseServer}/{args.InfoBaseRef}"])
    else:
        arguments.extend(["/F", args.InfoBasePath])

    if args.UserName:
        arguments.append(f"/N{args.UserName}")
    if args.Password:
        arguments.append(f"/P{args.Password}")

    # --- Optional params ---
    execute = args.Execute
    if execute:
        ext = os.path.splitext(execute)[1].lower()
        if ext == ".erf":
            print("[WARN] /Execute does not support ERF files (external reports).")
            print(f"       Open the report via File -> Open: {execute}")
            print("       Launching database without /Execute.")
            execute = ""

    if execute:
        arguments.extend(["/Execute", execute])
    if args.CParam:
        arguments.extend(["/C", args.CParam])
    if args.URL:
        arguments.extend(["/URL", args.URL])

    arguments.append("/DisableStartupDialogs")

    # --- Execute (background, no wait) ---
    print(f"Running: 1cv8.exe {' '.join(arguments)}")
    subprocess.Popen([v8path] + arguments)
    print("1C:Enterprise launched")


if __name__ == "__main__":
    main()
