#!/usr/bin/env python3
# epf-build v1.9 — Build external data processor or report (EPF/ERF) from XML sources
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


def output_nonempty(path):
    """Postcondition: the platform must have produced a non-empty output file.
    Exit code 0 without it (broken/headless env) is a false success — reject it."""
    return os.path.isfile(path) and os.path.getsize(path) > 0


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
            print(f"Running: ibcmd {_redact(' '.join(arguments), args.Password, args.UserName)}")
            result = run_ibcmd([v8path] + arguments, warn_no_user=False)
            exit_code = result.returncode
            out_missing = exit_code == 0 and not output_nonempty(args.OutputFile)
            if out_missing:
                exit_code = 1
            if exit_code == 0:
                print(f"External data processor/report built successfully: {args.OutputFile}")
            elif out_missing:
                print(f"Error: exit code 0 but no non-empty file at {args.OutputFile} — build produced no output", file=sys.stderr)
            else:
                print(f"Error building external data processor/report (code: {exit_code})", file=sys.stderr)
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            sys.exit(exit_code)

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
        print(f"Running: 1cv8.exe {_redact(' '.join(arguments), args.Password, args.UserName)}")
        result = subprocess.run(
            [v8path] + arguments,
            capture_output=True,
            text=True,
        )
        exit_code = result.returncode

        # --- Result ---
        # Postcondition: exit 0 without a non-empty output file is a false success.
        out_missing = exit_code == 0 and not output_nonempty(args.OutputFile)
        if out_missing:
            exit_code = 1
        if exit_code == 0:
            print(f"Build completed successfully: {args.OutputFile}")
        elif out_missing:
            print(f"Error: exit code 0 but no non-empty file at {args.OutputFile} — build produced no output", file=sys.stderr)
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
