#!/usr/bin/env python3
# v8-xsd-fetch v1.0 — Download 1C platform XSD schemas (dump format) into .v8-xsd
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Загрузка XSD-схем формата выгрузки 1С по версиям формата.

Скачивает schemas/designer/<версия>/*.xsd из репозитория yellow-hammer/namespace-forest
в каталог схем проекта: -OutPath, иначе xsdPath из .v8-project.json, иначе .v8-xsd
рядом с .v8-project.json (нет его — в текущем каталоге).
"""
import argparse
import json
import os
import re
import shutil
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

REPO = "yellow-hammer/namespace-forest"
REPO_URL = "https://github.com/" + REPO
TIMEOUT = 60

# Текст README — в templates/ навыка, одна копия на оба порта
README_TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "templates", "README.md")


def ci_parse_args(parser, argv=None):
    """parse_args по правилам PS: имена параметров и значения choices регистронезависимы."""
    argv = list(sys.argv[1:] if argv is None else argv)
    names = {s.lower(): s for a in parser._actions for s in a.option_strings}
    for i, tok in enumerate(argv):
        if tok.startswith('-') and tok.lower() in names:
            argv[i] = names[tok.lower()]
    # choices — зеркало [ValidateSet]; канонизируем ДО разбора, иначе argparse отвергнет регистр
    choice_map = {}
    for a in parser._actions:
        if a.choices:
            for s in a.option_strings:
                choice_map[s] = {str(c).lower(): c for c in a.choices}
    for i in range(len(argv) - 1):
        m = choice_map.get(argv[i])
        if m and argv[i + 1].lower() in m:
            argv[i + 1] = m[argv[i + 1].lower()]
    return parser.parse_args(argv)


def _sg_find_v8project(start_dir):
    d = start_dir
    for _ in range(20):
        if not d:
            break
        pj = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pj):
            return pj
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def fail(msg):
    print("Error: " + msg)
    sys.exit(1)


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "v8-xsd-fetch"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def main():
    parser = argparse.ArgumentParser(description="Download 1C platform XSD schemas into .v8-xsd", allow_abbrev=False)
    # Списком одной строкой — паритет с PS: powershell -File не связывает массивы
    parser.add_argument("-Versions", default="")
    parser.add_argument("-OutPath", default="")
    parser.add_argument("-Ref", default="main")
    parser.add_argument("-Force", action="store_true")
    parser.add_argument("-List", action="store_true")
    args = ci_parse_args(parser)
    ref = args.Ref

    # --- Версии: проверяем до сети ---
    wanted = []
    if args.Versions:
        for v in re.split(r"[,;\s]+", args.Versions):
            if not v:
                continue
            if not re.match(r"^\d+\.\d+$", v):
                fail("неверная версия формата '%s' (ожидается вида 2.20)" % v)
            if v not in wanted:
                wanted.append(v)

    # --- Каталог схем ---
    cwd = os.getcwd()
    pj = _sg_find_v8project(cwd)
    if args.OutPath:
        target = args.OutPath if os.path.isabs(args.OutPath) else os.path.join(cwd, args.OutPath)
    elif pj:
        pj_dir = os.path.dirname(pj)
        try:
            with open(pj, encoding="utf-8-sig") as f:
                cfg = json.load(f)
        except Exception:
            cfg = None
        xsd_path = cfg.get("xsdPath") if isinstance(cfg, dict) else None
        if xsd_path:
            target = xsd_path if os.path.isabs(xsd_path) else os.path.join(pj_dir, xsd_path)
        else:
            target = os.path.join(pj_dir, ".v8-xsd")
    else:
        target = os.path.join(cwd, ".v8-xsd")
    target = os.path.abspath(target)
    if os.path.isfile(target):
        fail("каталог схем '%s' — это файл" % target)

    # --- Состав репозитория ---
    try:
        tree = json.loads(http_get("https://api.github.com/repos/%s/git/trees/%s?recursive=1"
                                   % (REPO, urllib.parse.quote(ref, safe=""))).decode("utf-8"))
    except Exception as e:
        fail("не удалось получить состав %s@%s: %s\nСкачайте вручную каталоги schemas/designer/<версия> из %s в '%s'"
             % (REPO, ref, e, REPO_URL, target))
    commit = tree.get("sha", "")

    by_version = {}
    for node in tree.get("tree", []):
        if node.get("type") != "blob":
            continue
        m = re.match(r"^schemas/designer/(\d+\.\d+)/([^/]+\.xsd)$", node.get("path", ""))
        if not m:
            continue
        by_version.setdefault(m.group(1), []).append({"path": node["path"], "name": m.group(2)})
    available = sorted(by_version.keys(), key=version_key)
    if not available:
        fail("в %s@%s нет каталогов schemas/designer/<версия>" % (REPO, ref))

    if args.List:
        print("Версии формата в %s@%s:" % (REPO, ref))
        for v in available:
            mark = "  (есть локально)" if os.path.isdir(os.path.join(target, v)) else ""
            print("  %s — %d схем%s" % (v, len(by_version[v]), mark))
        print("Каталог схем: " + target)
        sys.exit(0)

    if not wanted:
        wanted = list(available)
    missing = [v for v in wanted if v not in available]
    if missing:
        fail("версии %s нет в %s@%s (есть: %s)" % (", ".join(missing), REPO, ref, ", ".join(available)))

    # --- Загрузка ---
    os.makedirs(target, exist_ok=True)
    fetched = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Происхождение — по версиям: уже лежащие файлы без -Force не перекачиваются, поэтому коммит
    # версии обновляем, только когда её файлы действительно скачаны в этом запуске
    src_path = os.path.join(target, "source.json")
    src_vers = {}
    if os.path.isfile(src_path):
        try:
            with open(src_path, encoding="utf-8-sig") as fh:
                old = json.load(fh)
            if isinstance(old.get("versions"), dict):
                for k, e in old["versions"].items():
                    e = e if isinstance(e, dict) else {}
                    src_vers[k] = {"ref": str(e.get("ref") or ""), "commit": str(e.get("commit") or ""),
                                   "fetched": str(e.get("fetched") or "")}
        except Exception:
            pass

    total_new = 0
    for v in sorted(wanted, key=version_key):
        vdir = os.path.join(target, v)
        os.makedirs(vdir, exist_ok=True)
        got = kept = 0
        for f in by_version[v]:
            dest = os.path.join(vdir, f["name"])
            if os.path.exists(dest) and not args.Force:
                kept += 1
                continue
            # Файлы берём по коммиту, а не по ветке: весь набор — из одного состояния репозитория
            url = "https://raw.githubusercontent.com/%s/%s/%s" % (REPO, commit, f["path"])
            try:
                data = http_get(url)
            except Exception as e:
                fail("не удалось скачать %s: %s" % (f["path"], e))
            with open(dest, "wb") as out:
                out.write(data)
            got += 1
        total_new += got
        if got > 0:
            src_vers[v] = {"ref": ref, "commit": commit, "fetched": fetched}
        line = "  %s: скачано %d" % (v, got)
        if kept > 0:
            line += ", уже было %d" % kept
        print(line)

    # --- README и source.json ---
    readme_path = os.path.join(target, "README.md")
    if not os.path.exists(readme_path) and os.path.isfile(README_TEMPLATE):
        shutil.copyfile(README_TEMPLATE, readme_path)
    local_versions = sorted((d for d in os.listdir(target)
                             if re.match(r"^\d+\.\d+$", d) and os.path.isdir(os.path.join(target, d))),
                            key=version_key)
    # Руками, а не json.dumps: форматирование совпадает с PS-мастером.
    # Версия без записи о происхождении (скопирована вручную) — с пустыми полями.
    def esc_json(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    ver_lines = []
    for v in local_versions:
        e = src_vers.get(v) or {"ref": "", "commit": "", "fetched": ""}
        ver_lines.append('    "%s": { "ref": "%s", "commit": "%s", "fetched": "%s" }'
                         % (v, esc_json(e["ref"]), esc_json(e["commit"]), esc_json(e["fetched"])))
    ver_block = "{\n" + ",\n".join(ver_lines) + "\n  }" if ver_lines else "{}"
    src_json = '{\n  "repository": "%s",\n  "versions": %s\n}\n' % (REPO_URL, ver_block)
    with open(src_path, "w", encoding="utf-8", newline="\n") as out:
        out.write(src_json)

    print("Схемы: %s (скачано файлов: %d)" % (target, total_new))


if __name__ == "__main__":
    main()
