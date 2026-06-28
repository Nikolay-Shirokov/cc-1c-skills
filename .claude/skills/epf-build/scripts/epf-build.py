#!/usr/bin/env python3
# epf-build v1.4 — Build external data processor or report (EPF/ERF) from XML sources
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


def _ibcmd_timeout():
    raw = os.environ.get("CC_1C_IBCMD_TIMEOUT", "600")
    try:
        timeout = float(raw)
    except ValueError:
        return 600.0
    return timeout if timeout > 0 else None


def _timeout_text(timeout):
    if timeout is None:
        return ""
    return (
        f"Error: ibcmd timeout after {timeout:g}s. "
        "The process may be waiting for authentication; specify -UserName/-Password "
        "or increase CC_1C_IBCMD_TIMEOUT."
    )


def _decode_timeout_output(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def run_ibcmd(v8path, arguments):
    timeout = _ibcmd_timeout()
    try:
        return subprocess.run(
            [v8path] + arguments,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stderr = _decode_timeout_output(exc.stderr)
        message = _timeout_text(timeout)
        if stderr and not stderr.endswith("\n"):
            stderr += "\n"
        return subprocess.CompletedProcess(
            exc.cmd,
            124,
            _decode_timeout_output(exc.stdout),
            stderr + message + "\n",
        )

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Build external data processor or report (EPF/ERF) from XML sources",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="", help="Path to 1cv8.exe or its bin directory")
    parser.add_argument("-InfoBasePath", default="", help="Path to file infobase")
    parser.add_argument("-InfoBaseServer", default="", help="1C server (for server infobase)")
    parser.add_argument("-InfoBaseRef", default="", help="Infobase name on server")
    parser.add_argument("-UserName", default="", help="1C user name")
    parser.add_argument("-Password", default="", help="1C user password")
    parser.add_argument("-SourceFile", required=True, help="Path to root XML source file")
    parser.add_argument("-OutputFile", required=True, help="Path to output EPF/ERF file")
    args = parser.parse_args()

    # --- Resolve V8Path ---
    v8path = resolve_v8path(args.V8Path)
    engine = "ibcmd" if os.path.basename(v8path).lower().startswith("ibcmd") else "1cv8"
    if engine == "ibcmd" and args.InfoBaseServer and args.InfoBaseRef:
        print("Error: ibcmd supports file infobases only (use -InfoBasePath or omit for stub)", file=sys.stderr)
        sys.exit(1)

    # --- Auto-create stub database if no connection specified ---
    auto_created_base = None
    if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        source_dir = os.path.dirname(os.path.abspath(args.SourceFile))
        auto_base_path = os.path.join(tempfile.gettempdir(), f"epf_stub_db_{random.randint(0, 999999)}")
        stub_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stub-db-create.py")
        print("No database specified. Creating temporary stub database...")
        result = subprocess.run(
            [sys.executable, stub_script, "-SourceDir", source_dir, "-V8Path", v8path, "-TempBasePath", auto_base_path],
            capture_output=False,
        )
        if result.returncode != 0:
            print("Error: failed to create stub database", file=sys.stderr)
            sys.exit(1)
        args.InfoBasePath = auto_base_path
        auto_created_base = auto_base_path

    # --- Validate source file ---
    if not os.path.isfile(args.SourceFile):
        print(f"Error: source file not found: {args.SourceFile}", file=sys.stderr)
        sys.exit(1)

    # --- Ensure output directory exists ---
    out_dir = os.path.dirname(args.OutputFile)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir, exist_ok=True)

    # --- Temp dir ---
    temp_dir = os.path.join(tempfile.gettempdir(), f"epf_build_{random.randint(0, 999999)}")
    os.makedirs(temp_dir, exist_ok=True)

    try:
        if engine == "ibcmd":
            # --- ibcmd branch: build EPF/ERF via config import --out ---
            src_dir = os.path.dirname(os.path.abspath(args.SourceFile))
            arguments = ["infobase", "config", "import", src_dir, f"--out={args.OutputFile}", f"--db-path={args.InfoBasePath}"]
            ib_data = tempfile.mkdtemp(prefix="ibcmd_data_")
            atexit.register(shutil.rmtree, ib_data, ignore_errors=True)
            if args.UserName:
                arguments.append(f"--user={args.UserName}")
            if args.Password:
                arguments.append(f"--password={args.Password}")
            arguments.append(f"--data={ib_data}")
            print(f"Running: ibcmd {' '.join(arguments)}")
            result = run_ibcmd(v8path, arguments)
            if result.returncode == 0:
                print(f"External data processor/report built successfully: {args.OutputFile}")
            else:
                print(f"Error building external data processor/report (code: {result.returncode})", file=sys.stderr)
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

        arguments += ["/LoadExternalDataProcessorOrReportFromFiles", args.SourceFile, args.OutputFile]

        # --- Output ---
        out_file = os.path.join(temp_dir, "build_log.txt")
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
            print(f"Build completed successfully: {args.OutputFile}")
        else:
            print(f"Error building (code: {exit_code})", file=sys.stderr)

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
        if auto_created_base and os.path.exists(auto_created_base):
            shutil.rmtree(auto_created_base, ignore_errors=True)


if __name__ == "__main__":
    main()
