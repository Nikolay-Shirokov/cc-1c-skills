#!/usr/bin/env python3
# db-cfe-admin v1.0 — Configuration extensions in a 1C infobase: list, check, properties, delete
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

# Общий блок группы db-*: реквизиты хранилища, дополнительные аргументы, запуск платформы.
# Копии держит одинаковыми tests/skills/check-inline-drift.mjs — правку вносить в навык-эталон.

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


# --- Additional platform arguments ---
V8_OWNED_KEYS = [
    "DESIGNER", "ENTERPRISE", "CREATEINFOBASE", "CONFIG",
    "/F", "/S", "/N", "/P", "/Out", "/DisableStartupDialogs",
    "/UseTemplate", "/AddToList", "/Execute", "/C", "/URL", "/UC",
    "/DumpIB", "/RestoreIB", "/DumpCfg", "/LoadCfg",
    "/DumpConfigToFiles", "/LoadConfigFromFiles", "/UpdateDBCfg",
    "/DumpExternalDataProcessorOrReportToFiles", "/LoadExternalDataProcessorOrReportFromFiles",
]
IBCMD_OWNED_KEYS = [
    "--db-path", "--data", "--out", "--file", "--load", "--restore",
    "--import", "--export", "--apply", "--force", "--create-database",
    "--user", "--password",
]
V8_SECRET_KEYS = ["/P", "/UC", "/WSP", "/AWSP", "/ConfigurationRepositoryP"]
IBCMD_SECRET_KEYS = ["--password", "--token", "--db-pwd"]


# --- Реквизиты хранилища из .v8-project.json ---
# Модель их не передаёт: скрипт сопоставляет параметры соединения с записью в databases[]
# и берёт repository оттуда. Тот же приём, что в cf-edit.py (сопоставление по configSrc).
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

def same_path(a, b):
    if not a or not b:
        return False
    try:
        return os.path.abspath(a).rstrip("\\/").lower() == os.path.abspath(b).rstrip("\\/").lower()
    except Exception:
        return False


def find_project_database(args):
    """Запись базы в реестре, соответствующая переданному соединению. None, если не найдена."""
    pf = _sg_find_v8project(os.getcwd())
    if not pf:
        return None
    try:
        with open(pf, encoding="utf-8-sig") as f:
            proj = json.load(f)
    except Exception:
        return None
    for db in proj.get("databases") or []:
        if args.InfoBasePath and db.get("path") and same_path(db["path"], args.InfoBasePath):
            return db
        if args.InfoBaseServer and args.InfoBaseRef and db.get("server") and db.get("ref"):
            if (db["server"].lower() == args.InfoBaseServer.lower()
                    and db["ref"].lower() == args.InfoBaseRef.lower()):
                return db
    return None


def resolve_repository_settings(args):
    """Возвращает dict path/user/password/from_registry. Явные -Repository* сильнее реестра."""
    db_rec = find_project_database(args)
    rec = None
    if db_rec:
        if args.Extension:
            # У расширения СВОЁ хранилище со своим путём (проверено): выбирается парой
            # /ConfigurationRepositoryF"<путь расширения>" + -Extension "<Имя>".
            for ext in db_rec.get("extensions") or []:
                if (ext.get("name") or "").lower() == args.Extension.lower():
                    rec = ext.get("repository")
                    break
        else:
            rec = db_rec.get("repository")
    path = args.RepositoryPath or ((rec or {}).get("path") or None)
    user = args.RepositoryUser or ((rec or {}).get("user") or None)
    # Пустой пароль = отсутствующий: 1С требует опускать ключ целиком, а не передавать пустое значение.
    pwd = args.RepositoryPassword or ((rec or {}).get("password") or None)
    return {
        "path": path.strip().strip('"') if path else None,
        "user": user,
        "password": pwd,
        "from_registry": bool(rec and rec.get("path")),
    }


def repository_args(repo):
    """Ключи доступа к хранилищу. Форма — кавычки ВНУТРИ токена, как у /N и /P."""
    a = []
    if not repo or not repo.get("path"):
        return a
    a.append('/ConfigurationRepositoryF"%s"' % repo["path"])
    if repo.get("user"):
        a.append('/ConfigurationRepositoryN"%s"' % repo["user"])
    if repo.get("password"):
        a.append('/ConfigurationRepositoryP"%s"' % repo["password"])
    return a


def arg_key_match(token, key):
    """Token matches a key when it equals it, or starts with it and the next character
    is not a letter — catches glued /N"user" and --password=x, while keeping
    /ClearCache distinct from /C."""
    if len(token) < len(key):
        return False
    if token[: len(key)].lower() != key.lower():
        return False
    if len(token) == len(key):
        return True
    return not token[len(key)].isalpha()


def project_extra_args(name):
    """v8args / ibcmdargs from .v8-project.json — same upward walk as v8path."""
    d = os.getcwd()
    while True:
        pf = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pf):
            try:
                with open(pf, encoding="utf-8-sig") as f:
                    data = json.load(f)
                v = data.get(name)
                if v:
                    return [str(x) for x in v]
            except Exception:
                pass
            return []
        parent = os.path.dirname(d)
        if parent == d:
            return []
        d = parent


def assert_extra_args(extra, engine, hints):
    """The platform accepts only one batch operation, and a duplicate connection or
    output key fails with an opaque 1C error — reject what the skill owns itself."""
    param = "-AdditionalIbcmdArguments" if engine == "ibcmd" else "-AdditionalV8Arguments"
    owned = IBCMD_OWNED_KEYS if engine == "ibcmd" else V8_OWNED_KEYS
    for tok in extra:
        if engine == "ibcmd" and not tok.startswith("-"):
            print(
                f"Error: '{tok}' is a positional token — pass values as --key=value "
                f"({param} cannot extend the ibcmd command)",
            )
            sys.exit(1)
        for k in owned:
            if arg_key_match(tok, k):
                hint = f" (use {hints[k]})" if hints and k in hints else ""
                print(
                    f"Error: {k} is controlled by the skill and cannot be passed via {param}{hint}",
                )
                sys.exit(1)


def format_args_for_display(arglist, engine):
    """Redact values of secret-prone keys in glued, =-joined and separate forms.
    Matching here is a plain prefix (no letter rule): over-masking costs nothing,
    a leaked password does."""
    keys = IBCMD_SECRET_KEYS if engine == "ibcmd" else V8_SECRET_KEYS
    res = []
    mask_next = False
    for tok in arglist:
        if mask_next:
            res.append("***")
            mask_next = False
            continue
        hit = None
        for k in keys:
            if tok[: len(k)].lower() == k.lower():
                hit = k
                break
        if hit is None:
            res.append(tok)
        elif len(tok) == len(hit):
            res.append(tok)
            mask_next = True
        elif tok[len(hit)] == "=":
            res.append(hit + "=***")
        else:
            res.append(hit + "***")
    return res


def extract_extra_args(argv, known_opts):
    """argparse refuses values that start with '-' (every ibcmd key does), so pull the two
    escape-hatch lists out of argv by hand: after the flag, take everything up to the next
    declared skill option. Returns (remaining_argv, v8_extra, ibcmd_extra)."""
    rest, v8, ibcmd = [], [], []
    i = 0
    while i < len(argv):
        low = argv[i].lower()
        if low in ("-additionalv8arguments", "-additionalibcmdarguments"):
            target = v8 if low == "-additionalv8arguments" else ibcmd
            i += 1
            while i < len(argv) and argv[i].lower() not in known_opts:
                target.append(argv[i])
                i += 1
            continue
        rest.append(argv[i])
        i += 1
    return rest, v8, ibcmd


def resolve_extra_args(engine, v8_extra, ibcmd_extra, hints):
    """Pick the argument list for the selected engine and validate it. An explicitly
    passed parameter for the other engine is an error; the same keys coming from
    .v8-project.json simply do not apply — a project may describe both engines.

    Comma-separated elements are split apart: PowerShell's -File cannot bind an array,
    so that form is the documented one and both ports must accept it. A value containing
    a comma is not supported."""
    v8_extra = [p for tok in v8_extra for p in str(tok).split(",") if p]
    ibcmd_extra = [p for tok in ibcmd_extra for p in str(tok).split(",") if p]
    if engine == "ibcmd" and v8_extra:
        print(
            "Error: -AdditionalV8Arguments applies to 1cv8 only; the selected engine is ibcmd "
            "(use -AdditionalIbcmdArguments)",
        )
        sys.exit(1)
    if engine != "ibcmd" and ibcmd_extra:
        print(
            "Error: -AdditionalIbcmdArguments applies to ibcmd only; the selected engine is 1cv8 "
            "(use -AdditionalV8Arguments)",
        )
        sys.exit(1)
    if engine == "ibcmd":
        extra = project_extra_args("ibcmdargs") + list(ibcmd_extra)
    else:
        extra = project_extra_args("v8args") + list(v8_extra)
    if extra:
        assert_extra_args(extra, engine, hints)
    return extra


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
            print("Error: 1C executable not found. Specify -V8Path")
            sys.exit(1)
    if os.path.isdir(v8path):
        # PY-only: на *nix исполняемый называется "1cv8" (без .exe); ibcmd — только явным путём.
        exe = "1cv8.exe" if os.name == "nt" else "1cv8"
        v8path = os.path.join(v8path, exe)
    if not os.path.isfile(v8path):
        print(f"Error: 1C executable not found at {v8path}")
        sys.exit(1)
    return v8path


IBCMD_NOUSER_HINT = (
    "[ibcmd] No -UserName/-Password given; the infobase may require authentication. "
    "On Windows ibcmd reads credentials from the console (stdin is ignored), so this "
    "call may block instead of failing. If it does not return promptly, abort and "
    "re-run with -UserName and -Password.\n"
)


def decode_platform_bytes(data):
    """ibcmd writes UTF-8 (checked on 8.3.24, 8.3.27, 8.5), a crashing 1cv8 may still emit
    OEM text. Decode strictly as UTF-8 and fall back to cp866 on invalid bytes — the locale
    code page (what text=True uses) mangles both."""
    if not data:
        return ""
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp866", errors="replace")


def assert_infobase_exists(path):
    """These skills work on a ready infobase. Saying so up front beats the platform's
    "Неверные или отсутствующие параметры соединения" after a launch."""
    if not path:
        return
    if not os.path.isfile(os.path.join(path, "1Cv8.1CD")):
        print(f"Error: information base not found at {path} (no 1Cv8.1CD)")
        sys.exit(1)


def clean_path(value, param=""):
    """Forgive what is unambiguous in a path the caller passed: surrounding whitespace,
    surrounding quotes that survived shell parsing, a trailing separator. A quote left
    inside afterwards cannot be part of a real path — reject it by name instead of letting
    1C answer with its opaque "Неверные или отсутствующие параметры соединения"."""
    if not value:
        return value
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1].strip()
    if len(v) > 3 and v[-1] in "\\/":
        v = v[:-1]
    if '"' in v:
        print(f"Error: {param or 'path'} contains a quote character: {value}")
        sys.exit(1)
    return v


def quote_if_needed(token):
    """Extra arguments come from the caller unquoted; the 1cv8 command line is joined
    verbatim, so a token with a space needs quotes of its own."""
    if token and (" " in token or "\t" in token) and '"' not in token:
        return f'"{token}"'
    return token


def run_v8(v8path, arguments):
    """Run 1cv8 in batch mode and capture its console output.

    The arguments carry their own quotes inside the value (File="C:\\a b") — that is where
    1C's parser expects them, on Windows and on *nix alike. Windows list2cmdline would
    escape those quotes, so there the command line is handed over ready-made.

    На POSIX аргументы уходят СПИСКОМ, и кавычки, нужные для склейки на Windows, стали бы
    частью значения: путь с пробелом платформа не находит («Неопределена информационная
    база»), многословный -comment теряет молча. Поэтому здесь снимается ОДИН слой
    обрамляющих кавычек. Склеенные ключи (/N"user", /ConfigurationRepositoryF"путь",
    File="…") не задеты: у них кавычки внутри токена, а не по краям.
    """
    if os.name == "nt":
        cmd = '"' + v8path + '" ' + " ".join(arguments)
    else:
        def strip_framing_quotes(a):
            # Кавычки, которыми мы обрамляем значения ради склейки на Windows, на POSIX
            # становятся ЧАСТЬЮ значения. Проверено на darwin: путь с пробелом отдельным
            # токеном даёт «Неопределена информационная база», а склеенный
            # /ConfigurationRepositoryF"путь с пробелом" — «завершилось с ошибкой»;
            # без кавычек обе формы работают.
            if len(a) > 1 and a[0] == '"' and a[-1] == '"':
                return a[1:-1]                       # "значение" отдельным токеном
            if a[0:1] == "/" and a[-1:] == '"' and '"' in a[:-1]:
                i = a.index('"')
                return a[:i] + a[i + 1:-1]           # /N"имя" -> /Nимя
            return a                                 # File="…" не трогаем: там кавычки —
                                                     # часть синтаксиса строки соединения,
                                                     # и с ними на POSIX всё работает
        cmd = [v8path] + [strip_framing_quotes(a) for a in arguments]
    r = subprocess.run(cmd, input=b"", capture_output=True)
    r.stdout = decode_platform_bytes(r.stdout)
    r.stderr = decode_platform_bytes(r.stderr)
    return r


def print_platform_output(result):
    """Print what the platform wrote to the console as its own labelled block. Silence stays
    silent: in batch mode 1cv8 reports through /Out and prints nothing here."""
    text = ((result.stdout or "") + (result.stderr or "")).rstrip()
    if not text:
        return
    limit = 65536
    if len(text) > limit:
        text = f"[... обрезано, показаны последние {limit} символов ...]\n" + text[-limit:]
    print("--- Вывод платформы ---")
    print(text)
    print("--- End ---")


def run_ibcmd(cmd, has_username=False, warn_no_user=True):
    """Run an ibcmd command non-interactively.

    input="" closes stdin (EOF) so ibcmd's auth prompt fast-fails instead of hanging.
    On Windows without -UserName ibcmd reads the console directly and may still block —
    that residual case is flagged via IBCMD_NOUSER_HINT (model-facing).
    """
    if warn_no_user and os.name == "nt" and not has_username:
        sys.stdout.write(IBCMD_NOUSER_HINT)
        sys.stderr.flush()
    r = subprocess.run(cmd, input=b"", capture_output=True)
    r.stdout = decode_platform_bytes(r.stdout)
    r.stderr = decode_platform_bytes(r.stderr)
    return r


def describe_exit(code):
    """Annotate an abnormal process exit code so a crash isn't reported as a bare number.
    Batch 1C in a broken/headless environment (no GUI session, no license) can crash mid-run
    instead of returning a clean error, possibly leaving the infobase locked or half-mutated."""
    if code is None:
        return ""
    win = {
        3221225477: "0xC0000005 (access violation)", -1073741819: "0xC0000005 (access violation)",
        3221225781: "0xC0000135 (missing DLL)", -1073741515: "0xC0000135 (missing DLL)",
        3221226505: "0xC0000409 (stack overrun)", -1073740791: "0xC0000409 (stack overrun)",
    }
    if code in win:
        return f" — abnormal termination, exception {win[code]}; the infobase may be left in an inconsistent state; verify it before retrying"
    if -64 <= code < 0:
        try:
            import signal
            name = signal.Signals(-code).name
        except (ValueError, AttributeError):
            name = f"signal {-code}"
        return (f" — process terminated by {name} (abnormal termination, not a normal exit); "
                "the infobase may be left in an inconsistent state; verify it before retrying")
    return ""


def _redact(text, *secrets):
    """Redact literal secret values (password, user) from a display string —
    precise, never touches lookalike paths."""
    for s in secrets:
        if s:
            text = text.replace(s, "***")
    return text


KNOWN_COMMANDS = ["list", "check", "set-properties", "delete"]
KNOWN_CHECKS = ["apply", "modules", "config"]
KNOWN_CONTEXTS = ["ThinClient", "WebClient", "MobileClient", "MobileClientStandalone", "MobileAppClient",
                  "Server", "MobileAppServer", "ExternalConnection", "ExternalConnectionServer",
                  "ThickClientManagedApplication", "ThickClientServerManagedApplication",
                  "ThickClientOrdinaryApplication", "ThickClientServerOrdinaryApplication"]

PROP_RU = {
    "safe-mode": "безопасный режим",
    "active": "активно",
    "unsafe-action-protection": "защита от опасных действий",
    "used-in-distributed-infobase": "используется в РИБ",
    "scope": "область действия",
    "security-profile-name": "профиль безопасности",
    "purpose": "назначение",
    "version": "версия",
}
FLAG_RU = {"yes": "да", "no": "нет"}
SCOPE_RU = {"infobase": "Информационная база", "data-separation": "Область данных"}
PURPOSE_RU = {"customization": "Адаптация", "add-on": "Дополнение", "patch": "Исправление"}


def prop_ru(key):
    return PROP_RU.get(key, key)


def flag_value(value):
    return "yes" if str(value).lower() in ("on", "yes", "+") else "no"


def format_prop_value(key, value):
    if value is None or value == "":
        return ""
    v = str(value)
    if key == "scope" and v in SCOPE_RU:
        return SCOPE_RU[v]
    if key == "purpose" and v in PURPOSE_RU:
        return PURPOSE_RU[v]
    return FLAG_RU.get(v, v)


def parse_ibcmd_records(text):
    """Вывод ibcmd: строки «ключ : значение», записи разделены пустой строкой."""
    records = []
    cur = {}
    for line in (text or "").splitlines():
        if not line.strip():
            if cur:
                records.append(cur)
                cur = {}
            continue
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key = key.strip()
        val = val.strip().strip('"')
        if key:
            cur[key] = val
    if cur:
        records.append(cur)
    return records


def write_table(headers, rows):
    widths = []
    for i, h in enumerate(headers):
        w = len(h)
        for row in rows:
            w = max(w, len(str(row[i])))
        widths.append(w)
    print(("  " + "".join(h.ljust(widths[i] + 2) for i, h in enumerate(headers))).rstrip())
    for row in rows:
        print(("  " + "".join(str(c).ljust(widths[i] + 2) for i, c in enumerate(row))).rstrip())


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Configuration extensions in a 1C infobase",
        allow_abbrev=False,
    )
    parser.add_argument("-Command", default="")
    parser.add_argument("-V8Path", default="")
    parser.add_argument("-InfoBasePath", default="")
    parser.add_argument("-InfoBaseServer", default="")
    parser.add_argument("-InfoBaseRef", default="")
    parser.add_argument("-UserName", default="")
    parser.add_argument("-Password", default="")
    parser.add_argument("-RepositoryPath", default="")
    parser.add_argument("-RepositoryUser", default="")
    parser.add_argument("-RepositoryPassword", default="")
    parser.add_argument("-Name", default=None)
    parser.add_argument("-All", action="store_true")
    parser.add_argument("-Checks", default="")
    parser.add_argument("-Context", default="")
    # Тристабильные флаги: on включить, off выключить, не указан — не трогать.
    # Значение "-" через powershell.exe -File парсер съедает молча (проверено), поэтому
    # каноническая форма словесная; "+"/"-" принимаются, но в инструкции не значатся.
    for flag in ("-SafeMode", "-Active", "-UnsafeActionProtection", "-UsedInDistributedInfobase"):
        parser.add_argument(flag, default="", choices=["", "on", "off", "yes", "no", "+", "-"])
    parser.add_argument("-Scope", default="", choices=["", "infobase", "data-separation"])
    parser.add_argument("-SecurityProfile", default=None)
    parser.add_argument("-AdditionalV8Arguments", nargs="*", default=[],
                        help="Extra 1cv8 arguments, e.g. /UseHwLicenses+")
    parser.add_argument("-AdditionalIbcmdArguments", nargs="*", default=[],
                        help="Extra ibcmd arguments in --key=value form")
    known_opts = {s.lower() for a in parser._actions for s in a.option_strings}
    argv, v8_extra, ibcmd_extra = extract_extra_args(sys.argv[1:], known_opts)
    args = ci_parse_args(parser, argv)

    args.V8Path = clean_path(args.V8Path, "-V8Path")
    args.InfoBasePath = clean_path(args.InfoBasePath, "-InfoBasePath")
    assert_infobase_exists(args.InfoBasePath)

    v8path = resolve_v8path(args.V8Path)

    # --- Утилиты платформы: нужны обе, выбор по команде ---
    # -V8Path указывает на каталог bin либо на любой из двух файлов; второй берётся соседом.
    bin_dir = os.path.dirname(v8path)
    leaf = os.path.basename(v8path)
    # Расширение файла сохраняем: на Windows это .exe, на *nix его нет, в тестах — .cmd/.sh.
    suffix = os.path.splitext(leaf)[1]
    if leaf.lower().startswith("ibcmd"):
        ibcmd_exe = v8path
        v8_exe = os.path.join(bin_dir, "1cv8" + suffix)
    else:
        v8_exe = v8path
        ibcmd_exe = os.path.join(bin_dir, "ibcmd" + suffix)
    has_v8 = os.path.isfile(v8_exe)
    has_ibcmd = os.path.isfile(ibcmd_exe)

    # --- Разбор и проверка команды ---
    cmd = (args.Command or "").strip().lower()
    if not cmd:
        print("Error: specify a command: " + " | ".join(KNOWN_COMMANDS))
        sys.exit(1)
    if cmd not in KNOWN_COMMANDS:
        print("Error: unknown command '%s' (expected: %s)" % (args.Command, " | ".join(KNOWN_COMMANDS)))
        sys.exit(1)

    # Пустое имя платформа трактует разрушительно: /DeleteCfg -Extension "" удаляет первое
    # расширение из списка и рапортует успех. Пустое значение до платформы не доходит.
    if args.Name is not None and not args.Name.strip():
        print("Error: -Name is empty; omit it to address all extensions, or pass a name")
        sys.exit(1)
    name = args.Name.strip() if args.Name else ""
    has_name = bool(name)

    if args.All and cmd != "delete":
        print("Error: -All applies to delete only (list and check address all extensions when -Name is omitted)")
        sys.exit(1)
    if cmd == "delete":
        if has_name and args.All:
            print("Error: -Name and -All are mutually exclusive - pass one or the other")
            sys.exit(1)
        if not has_name and not args.All:
            print("Error: specify -Name <extension> or -All (an omitted name never means all)")
            sys.exit(1)
    if cmd == "set-properties" and not has_name:
        print("Error: set-properties needs -Name <extension>")
        sys.exit(1)

    # --- Проверки (-Checks) и контексты (-Context) ---
    check_list = [c.strip().lower() for c in args.Checks.split(",") if c.strip()] if args.Checks else []
    for c in check_list:
        if c not in KNOWN_CHECKS:
            print("Error: unknown check '%s' (expected: %s)" % (c, ", ".join(KNOWN_CHECKS)))
            sys.exit(1)
    if not check_list:
        check_list = ["apply", "modules"]

    context_list = []
    if args.Context:
        for c in [x.strip() for x in args.Context.split(",") if x.strip()]:
            match = next((k for k in KNOWN_CONTEXTS if k.lower() == c.lower()), None)
            if not match:
                print("Error: unknown context '%s' (expected: %s)" % (c, ", ".join(KNOWN_CONTEXTS)))
                sys.exit(1)
            context_list.append(match)
    if args.Context and check_list and "modules" not in check_list:
        print("Error: -Context applies to the syntax check - add 'modules' to -Checks")
        sys.exit(1)
    if not context_list:
        context_list = ["ThinClient", "Server"]

    # --- Свойства для set-properties ---
    prop_flags = []
    if args.SafeMode:
        prop_flags.append(("safe-mode", flag_value(args.SafeMode)))
    if args.Active:
        prop_flags.append(("active", flag_value(args.Active)))
    if args.UnsafeActionProtection:
        prop_flags.append(("unsafe-action-protection", flag_value(args.UnsafeActionProtection)))
    if args.UsedInDistributedInfobase:
        prop_flags.append(("used-in-distributed-infobase", flag_value(args.UsedInDistributedInfobase)))
    if args.Scope:
        prop_flags.append(("scope", args.Scope))
    if args.SecurityProfile is not None:
        prop_flags.append(("security-profile-name", args.SecurityProfile))
    if cmd == "set-properties" and not prop_flags:
        print("Error: set-properties needs at least one property (-SafeMode, -Active, "
              "-UnsafeActionProtection, -UsedInDistributedInfobase, -Scope, -SecurityProfile)")
        sys.exit(1)

    # --- Соединение ---
    if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        print("Error: specify -InfoBasePath or -InfoBaseServer + -InfoBaseRef")
        sys.exit(1)

    # --- Дополнительные аргументы: у каждой утилиты свои ---
    arg_hints = {
        "/F": "-InfoBasePath",
        "/S": "-InfoBaseServer + -InfoBaseRef",
        "/N": "-UserName",
        "/P": "-Password",
        "--db-path": "-InfoBasePath",
        "--user": "-UserName",
        "--password": "-Password",
    }
    v8_extra_args = resolve_extra_args("1cv8", v8_extra, [], arg_hints)
    ib_extra_args = resolve_extra_args("ibcmd", [], ibcmd_extra, arg_hints)
    if ibcmd_extra and cmd in ("check", "delete"):
        print("Error: -AdditionalIbcmdArguments does not apply to '%s' - it runs the Designer only" % cmd)
        sys.exit(1)

    # Общий блок хранилища адресует расширение через args.Extension (у расширения своё
    # хранилище) — зеркало $Extension = $Name из PS-порта.
    args.Extension = name
    repo = resolve_repository_settings(args)
    base_label = args.InfoBasePath if args.InfoBasePath else "%s/%s" % (args.InfoBaseServer, args.InfoBaseRef)

    def invoke_designer(op_args):
        """Соединение, реквизиты хранилища и /Out навык держит сам."""
        if not has_v8:
            print("Error: 1C executable not found at %s" % v8_exe)
            sys.exit(1)
        temp_dir = tempfile.mkdtemp(prefix="db_cfe_admin_")
        try:
            arguments = ["DESIGNER"]
            if args.InfoBaseServer and args.InfoBaseRef:
                arguments += ["/S", '"%s/%s"' % (args.InfoBaseServer, args.InfoBaseRef)]
            else:
                arguments += ["/F", '"%s"' % args.InfoBasePath]
            if args.UserName:
                arguments.append('/N"%s"' % args.UserName)
            if args.Password:
                arguments.append('/P"%s"' % args.Password)
            # База под хранилищем не примет НИ ОДНОЙ операции конфигуратора без этих реквизитов.
            arguments += repository_args(repo)
            arguments += op_args
            out_file = os.path.join(temp_dir, "out.txt")
            arguments += ["/Out", '"%s"' % out_file, "/DisableStartupDialogs"]
            arguments += v8_extra_args
            print("Running: 1cv8.exe " + _redact(" ".join(format_args_for_display(arguments, "1cv8")),
                                                 args.Password, args.UserName, repo.get("password")))
            r = run_v8(v8_exe, arguments)
            log = ""
            if os.path.isfile(out_file):
                with open(out_file, encoding="utf-8-sig", errors="replace") as f:
                    log = f.read().strip()
            return {"exit": r.returncode, "log": log, "result": r}
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def invoke_ibcmd(op_args):
        arguments = [ibcmd_exe] + list(op_args) + ["--db-path=%s" % args.InfoBasePath]
        if args.UserName:
            arguments.append("--user=%s" % args.UserName)
        if args.Password:
            arguments.append("--password=%s" % args.Password)
        arguments += ib_extra_args
        print("Running: ibcmd " + _redact(" ".join(format_args_for_display(arguments[1:], "ibcmd")),
                                          args.Password, args.UserName))
        r = run_ibcmd(arguments, has_username=bool(args.UserName), warn_no_user=False)
        return {"exit": r.returncode, "result": r}

    def platform_failure(res, what):
        print("Error: %s (code: %s)%s" % (what, res["exit"], describe_exit(res["exit"])))
        if res.get("log"):
            print("--- Log ---")
            print(res["log"])
            print("--- End ---")
        print_platform_output(res["result"])

    def properties_unavailable_reason():
        if not args.InfoBasePath:
            return "свойства читает ibcmd, а он подключается к файловой базе (--db-path)"
        if not has_ibcmd:
            return "рядом с 1cv8 нет ibcmd (%s) - эта установка платформы его не содержит" % ibcmd_exe
        return None

    def get_extension_properties():
        """Словарь «имя расширения» -> запись свойств. Пустой, если ibcmd недоступен."""
        if properties_unavailable_reason():
            return {}
        r = invoke_ibcmd(["infobase", "config", "extension", "list"])
        if r["exit"] != 0:
            return {}
        out = {}
        for rec in parse_ibcmd_records((r["result"].stdout or "") + (r["result"].stderr or "")):
            if rec.get("name"):
                out[rec["name"]] = rec
        return out

    def get_extension_names():
        """Имена расширений базы - Конфигуратором: работает и без ibcmd, и на серверной базе."""
        r = invoke_designer(["/DumpDBCfgList", "-AllExtensions"])
        if r["exit"] != 0:
            platform_failure(r, "cannot list extensions")
            sys.exit(1)
        return [x.strip() for x in r["log"].splitlines() if x.strip()]

    def prop_cell(rec, key):
        if rec is None:
            return "—"
        if rec.get(key):
            return format_prop_value(key, rec[key])
        return ""

    # ========================================================================
    # Команды
    # ========================================================================

    if cmd == "list":
        names = get_extension_names()
        if has_name:
            names = [n for n in names if n.lower() == name.lower()]
            if not names:
                print("[РАСШИРЕНИЯ] %s   (0)" % base_label)
                print("  расширение '%s' в базе не найдено" % name)
                sys.exit(1)
        print("[РАСШИРЕНИЯ] %s   (%d)" % (base_label, len(names)))
        if not names:
            print("  расширений нет")
            sys.exit(0)
        props = get_extension_properties()
        reason = properties_unavailable_reason()
        rows = []
        for n in names:
            rec = props.get(n)
            rows.append([n,
                         prop_cell(rec, "purpose"),
                         prop_cell(rec, "active"),
                         prop_cell(rec, "safe-mode"),
                         prop_cell(rec, "unsafe-action-protection"),
                         prop_cell(rec, "used-in-distributed-infobase"),
                         prop_cell(rec, "scope")])
        write_table(["Имя", "Назначение", "Активно", "Безопасный режим", "Защита", "РИБ", "Область"], rows)
        if reason:
            print("  свойства недоступны: %s" % reason)
        sys.exit(0)

    if cmd == "check":
        # Список расширений заранее не запрашиваем: платформа сама отвечает «расширение не
        # найдено», а лишний запуск конфигуратора стоит дороже разницы в формулировке.
        target = name if has_name else None
        if target:
            print("[ПРОВЕРКА] %s · %s" % (base_label, target))
        else:
            print("[ПРОВЕРКА] %s · все расширения" % base_label)

        failed = 0
        done = 0
        rows = []

        if "apply" in check_list:
            op_args = ["/CheckCanApplyConfigurationExtensions"]
            if target:
                op_args += ["-Extension", '"%s"' % target]
            r = invoke_designer(op_args)
            done += 1
            log_lines = [x for x in r["log"].splitlines() if x.strip()]
            if r["exit"] == 0:
                rows.append(["применимость", "ОК", "", []])
            elif r["exit"] == 1:
                failed += 1
                rows.append(["применимость", "ОШИБКА", "", log_lines])
            else:
                failed += 1
                rows.append(["применимость", "СБОЙ", "код %s%s" % (r["exit"], describe_exit(r["exit"])), log_lines])

        # modules и config - одна и та же команда платформы с разным набором флагов, поэтому
        # при запросе обеих делается ОДИН запуск. Без флагов контекста платформа рапортует
        # «ошибок не обнаружено» на заведомо сломанном модуле - набор всегда явный.
        want_modules = "modules" in check_list
        want_config = "config" in check_list
        if want_modules or want_config:
            op_args = ["/CheckConfig"]
            if want_modules:
                op_args += ["-" + c for c in context_list]
            if want_config:
                op_args += ["-ConfigLogIntegrity", "-IncorrectReferences", "-UnreferenceProcedures",
                            "-HandlersExistence", "-EmptyHandlers"]
            if target:
                op_args += ["-Extension", '"%s"' % target]
            else:
                op_args.append("-AllExtensions")
            r = invoke_designer(op_args)
            label = "модули и конфигурация" if (want_modules and want_config) else ("модули" if want_modules else "конфигурация")
            done += 1
            log_lines = [x for x in r["log"].splitlines() if x.strip()]
            if r["exit"] == 0:
                rows.append([label, "ОК", "(%s)" % ", ".join(context_list) if want_modules else "", []])
            elif r["exit"] in (1, 101):
                failed += 1
                rows.append([label, "ОШИБКА", "", log_lines])
            else:
                failed += 1
                rows.append([label, "СБОЙ", "код %s%s" % (r["exit"], describe_exit(r["exit"])), log_lines])

        # Сообщения платформы печатаются построчно под своей проверкой: они называют расширение и
        # место ошибки, и при нескольких расширениях склейка в одну строку нечитаема.
        w = max(len(row[0]) for row in rows) if rows else 0
        for row in rows:
            line = "  " + row[0].ljust(w + 2) + row[1].ljust(9)
            if row[2]:
                line += row[2]
            print(line.rstrip())
            for msg in row[3]:
                print("      " + msg.strip())
        if failed:
            print("Итог: провалено %d из %d" % (failed, done))
            sys.exit(1)
        print("Итог: пройдено %d из %d" % (done, done))
        sys.exit(0)

    if cmd == "set-properties":
        reason = properties_unavailable_reason()
        if reason:
            print("Error: cannot set properties - %s" % reason)
            sys.exit(1)
        before = get_extension_properties()
        if name not in before:
            print("Error: extension '%s' not found in the infobase" % name)
            sys.exit(1)
        op_args = ["infobase", "config", "extension", "update", "--name=%s" % name]
        for key, val in prop_flags:
            op_args.append("--%s=%s" % (key, val))
        r = invoke_ibcmd(op_args)
        if r["exit"] != 0:
            print("Error: cannot set properties (code: %s)%s" % (r["exit"], describe_exit(r["exit"])))
            print_platform_output(r["result"])
            sys.exit(1)
        # Постусловие: состояние перечитывается, а не берётся из кода возврата.
        after = get_extension_properties()
        if name not in after:
            print("Error: extension '%s' disappeared after the update" % name)
            sys.exit(1)
        print("[СВОЙСТВА] %s · %s" % (base_label, name))
        changed = 0
        stale = []
        for key, val in prop_flags:
            was = format_prop_value(key, before[name].get(key, ""))
            now = format_prop_value(key, after[name].get(key, ""))
            want = format_prop_value(key, val)
            if was != now:
                print("  " + prop_ru(key).ljust(30) + "%s → %s" % (was, now))
                changed += 1
            elif now != want:
                stale.append("%s: просили '%s', в базе осталось '%s'" % (prop_ru(key), want, now))
        if stale:
            for s in stale:
                print("  " + s)
            print("Итог: изменено %d, не применено %d" % (changed, len(stale)))
            sys.exit(1)
        if changed == 0:
            print("  свойства уже в этом состоянии")
        print("Итог: изменено %d" % changed)
        sys.exit(0)

    if cmd == "delete":
        names = get_extension_names()
        if not names:
            print("[УДАЛЕНИЕ] %s" % base_label)
            print("  расширений нет - удалять нечего")
            sys.exit(0)
        if has_name:
            targets = [n for n in names if n.lower() == name.lower()]
            if not targets:
                print("Error: extension '%s' not found in the infobase" % name)
                sys.exit(1)
        else:
            targets = names
        print("[УДАЛЕНИЕ] %s   (будет удалено: %d)" % (base_label, len(targets)))
        for t in targets:
            # Имя непустое по построению: пустое отбито разбором, список получен от платформы.
            r = invoke_designer(["/DeleteCfg", "-Extension", '"%s"' % t])
            if r["exit"] != 0:
                platform_failure(r, "cannot delete extension '%s'" % t)
                sys.exit(1)
            print("  удалено: %s" % t)
        # Постусловие: список перечитывается - код возврата платформы ничего не доказывает.
        rest = get_extension_names()
        for t in targets:
            if [n for n in rest if n.lower() == t.lower()]:
                print("Error: platform reported success, but '%s' is still in the infobase" % t)
                sys.exit(1)
        print("Итог: удалено %d, осталось %d" % (len(targets), len(rest)))
        sys.exit(0)


if __name__ == "__main__":
    main()
