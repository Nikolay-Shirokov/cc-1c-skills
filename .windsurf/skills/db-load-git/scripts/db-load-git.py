#!/usr/bin/env python3
# db-load-git v1.3 — Load Git changes into 1C database
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import glob
import os
import random
import re
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


def get_object_xml_from_subfile(relative_path):
    """Map sub-file path (BSL, HTML, etc.) to object XML path."""
    parts = re.split(r"[\\/]", relative_path)
    if len(parts) >= 2:
        return f"{parts[0]}/{parts[1]}.xml"
    return None


def run_git(config_dir, git_args):
    """Run a git command in config_dir and return output lines on success."""
    result = subprocess.run(
        ["git"] + git_args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        cwd=config_dir,
    )
    if result.returncode == 0:
        return [line for line in result.stdout.splitlines() if line.strip()]
    return []


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Load Git changes into 1C database",
        allow_abbrev=False,
    )
    parser.add_argument("-V8Path", default="", help="Path to 1cv8.exe or its bin directory")
    parser.add_argument("-InfoBasePath", default="", help="Path to file infobase")
    parser.add_argument("-InfoBaseServer", default="", help="1C server (for server infobase)")
    parser.add_argument("-InfoBaseRef", default="", help="Infobase name on server")
    parser.add_argument("-UserName", default="", help="1C user name")
    parser.add_argument("-Password", default="", help="1C user password")
    parser.add_argument("-ConfigDir", required=True, help="Directory with XML configuration (git repo)")
    parser.add_argument(
        "-Source",
        default="All",
        choices=["All", "Staged", "Unstaged", "Commit"],
        help="Change source (default: All)",
    )
    parser.add_argument("-CommitRange", default="", help="Commit range (for Source=Commit), e.g. HEAD~3..HEAD")
    parser.add_argument("-Extension", default="", help="Extension name to load")
    parser.add_argument("-AllExtensions", action="store_true", help="Load all extensions")
    parser.add_argument(
        "-Format",
        default="Hierarchical",
        choices=["Hierarchical", "Plain"],
        help="File format (default: Hierarchical)",
    )
    parser.add_argument("-DryRun", action="store_true", help="Only show what would be loaded (no actual load)")
    parser.add_argument("-UpdateDB", action="store_true", help="Also update database configuration after load")
    args = parser.parse_args()

    # --- Resolve V8Path (skip if DryRun) ---
    v8path = None
    if not args.DryRun:
        v8path = resolve_v8path(args.V8Path)

    # --- Validate connection (skip if DryRun) ---
    if not args.DryRun:
        if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
            print("Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef", file=sys.stderr)
            sys.exit(1)

    # --- Validate config dir ---
    if not os.path.exists(args.ConfigDir):
        print(f"Error: config directory not found: {args.ConfigDir}", file=sys.stderr)
        sys.exit(1)

    # --- Validate Commit mode ---
    if args.Source == "Commit" and not args.CommitRange:
        print("Error: -CommitRange required for Source=Commit", file=sys.stderr)
        sys.exit(1)

    # --- Check git ---
    try:
        subprocess.run(["git", "--version"], capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("Error: git not found in PATH", file=sys.stderr)
        sys.exit(1)

    # --- Get changed files from Git ---
    changed_files = []

    if args.Source == "Staged":
        print("Getting staged changes...")
        changed_files += run_git(args.ConfigDir, ["diff", "--cached", "--name-only", "--relative"])
    elif args.Source == "Unstaged":
        print("Getting unstaged changes...")
        changed_files += run_git(args.ConfigDir, ["diff", "--name-only", "--relative"])
        changed_files += run_git(args.ConfigDir, ["ls-files", "--others", "--exclude-standard"])
    elif args.Source == "Commit":
        print(f"Getting changes from {args.CommitRange}...")
        changed_files += run_git(args.ConfigDir, ["diff", "--name-only", "--relative", args.CommitRange])
    elif args.Source == "All":
        print("Getting all uncommitted changes...")
        changed_files += run_git(args.ConfigDir, ["diff", "--cached", "--name-only", "--relative"])
        changed_files += run_git(args.ConfigDir, ["diff", "--name-only", "--relative"])
        changed_files += run_git(args.ConfigDir, ["ls-files", "--others", "--exclude-standard"])

    # Deduplicate and filter blanks
    changed_files = list(dict.fromkeys(f for f in changed_files if f.strip()))

    if len(changed_files) == 0:
        print("No changes found")
        sys.exit(0)

    print(f"Git changes detected: {len(changed_files)} files")

    # --- Filter and map to config files ---
    config_files = []

    for file in changed_files:
        file = file.strip().replace("\\", "/")
        if not file:
            continue

        # Skip service files
        if file == "ConfigDumpInfo.xml":
            continue

        full_path = os.path.join(args.ConfigDir, file)

        if file.endswith(".xml"):
            # XML file — add directly if exists
            if os.path.exists(full_path):
                if file not in config_files:
                    config_files.append(file)
        else:
            # Non-XML (BSL, HTML, etc.) — map to parent object XML + include all Ext/ files
            object_xml = get_object_xml_from_subfile(file)
            if object_xml:
                full_xml_path = os.path.join(args.ConfigDir, object_xml)
                if os.path.exists(full_xml_path):
                    if object_xml not in config_files:
                        config_files.append(object_xml)
                    if os.path.exists(full_path) and file not in config_files:
                        config_files.append(file)

                    # Add all files from Ext/ directory of the object
                    parts = re.split(r"[\\/]", file)
                    if len(parts) >= 2:
                        ext_dir = os.path.join(args.ConfigDir, parts[0], parts[1], "Ext")
                        if os.path.isdir(ext_dir):
                            for root, dirs, files in os.walk(ext_dir):
                                for fname in files:
                                    abs_path = os.path.join(root, fname)
                                    rel_path = os.path.relpath(abs_path, args.ConfigDir).replace("\\", "/")
                                    if rel_path not in config_files:
                                        config_files.append(rel_path)

    if len(config_files) == 0:
        print("No configuration files found in changes")
        sys.exit(0)

    print(f"Files for loading: {len(config_files)}")
    for f in config_files:
        print(f"  {f}")

    # --- DryRun: stop here ---
    if args.DryRun:
        print("")
        print("DryRun mode - no changes applied")
        sys.exit(0)

    # --- Temp dir ---
    temp_dir = os.path.join(tempfile.gettempdir(), f"db_load_git_{random.randint(0, 999999)}")
    os.makedirs(temp_dir, exist_ok=True)

    try:
        # --- Write list file (UTF-8 with BOM) ---
        list_file = os.path.join(temp_dir, "load_list.txt")
        with open(list_file, "w", encoding="utf-8-sig") as f:
            f.write("\n".join(config_files))

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
        arguments += ["-listFile", list_file]
        arguments += ["-Format", args.Format]
        arguments.append("-partial")
        arguments.append("-updateConfigDumpInfo")

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
        print("")
        print("Executing partial configuration load...")
        print(f"Running: 1cv8.exe {' '.join(arguments)}")

        result = subprocess.run(
            [v8path] + arguments,
            capture_output=True,
            text=True,
        )
        exit_code = result.returncode

        # --- Result ---
        print("")
        if exit_code == 0:
            print("Load completed successfully")
        else:
            print(f"Error loading configuration (code: {exit_code})", file=sys.stderr)

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
