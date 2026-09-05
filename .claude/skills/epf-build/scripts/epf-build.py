#!/usr/bin/env python3
# epf-build v1.17 — Build external data processor or report (EPF/ERF) from XML sources
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import atexit
import glob
import io
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

# Регистронезависимый ввод — паритет с PS1: в PowerShell имена параметров и [ValidateSet]
# регистр не различают, в argparse совпадение точное.
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
# Пакетные команды платформы. В одной командной строке DESIGNER выполняет ТОЛЬКО ПОСЛЕДНЮЮ,
# остальные молча отбрасывает (проверено на 8.3.24: /LoadConfigFromFiles вместе с
# /CheckCanApplyConfigurationExtensions завершились кодом 0 с пустым логом, и загрузка НЕ
# состоялась). Такая команда в дополнительных аргументах подменяет собой операцию навыка, а навык
# отчитывается успехом. Дополнительные аргументы — это опции, а не режимы.
V8_BATCH_KEYS = [
    "/CheckConfig", "/CheckModules", "/CheckCanApplyConfigurationExtensions",
    "/DumpDBCfgList", "/DeleteCfg", "/UpdateCfg", "/CompareCfg", "/MergeCfg",
    "/ManageCfgSupport", "/RollbackCfg", "/ConvertFiles",
]

IBCMD_OWNED_KEYS = [
    "--db-path", "--data", "--out", "--file", "--load", "--restore",
    "--import", "--export", "--apply", "--force", "--create-database",
    "--user", "--password",
]
V8_SECRET_KEYS = ["/P", "/UC", "/WSP", "/AWSP"]
IBCMD_SECRET_KEYS = ["--password", "--token", "--db-pwd"]


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
        if engine != "ibcmd":
            for b in V8_BATCH_KEYS:
                if arg_key_match(tok, b):
                    print(
                        f"Error: {b} is a batch command; passed via {param} it would replace "
                        f"the skill's own operation (a command line runs only its last batch command)",
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


# --- Проверка исходников платформой ---
# Сборка .epf/.erf ничего не проверяет: /LoadExternalDataProcessorOrReportFromFiles упаковывает XML
# и модули не компилирует, поэтому сломанный модуль доезжает до пользователя и падает при открытии
# обработки. Прямой команды «проверь внешнюю обработку» у платформы нет, но объект КОНФИГУРАЦИИ она
# проверяет — поэтому обработка кладётся в конфигурацию временной базы (stub-db-create
# -EmbedSourceFile) и спрашивается штатной /CheckConfig.
#
# Запуск отдельный и только через 1cv8: у ibcmd такой команды нет, а в одной командной строке
# DESIGNER выполняет лишь последнюю пакетную команду.
def get_check_flags(checks, contexts):
    flags = []
    if 'modules' in checks:
        for c in contexts:
            flags.append('-' + c)
    if 'handlers' in checks:
        flags.append('-HandlersExistence')
    if 'unreferenced' in checks:
        flags.append('-UnreferenceProcedures')
    if 'empty-handlers' in checks:
        flags.append('-EmptyHandlers')
    if 'config' in checks:
        flags += ['-ConfigLogIntegrity', '-IncorrectReferences']
    return flags


# Платформа называет объект своим именем внутри конфигурации; модели нужен путь к исходнику.
# Путь СКЛЕИВАЕТСЯ по конвенции выгрузки, поэтому возвращается только существующий файл:
# выдуманный путь хуже отсутствующего — модель пойдёт открывать файл, которого нет.
def resolve_source_path(line, source_dir):
    candidate = None
    m = re.search(r'(?:\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430|\u041e\u0442\u0447\u0435\u0442|DataProcessor|Report)\.([^.]+)\.(?:\u0424\u043e\u0440\u043c\u0430|Form)\.([^.]+)\.', line)
    if m:
        candidate = os.path.join(source_dir, m.group(1), 'Forms', m.group(2), 'Ext', 'Form', 'Module.bsl')
    if candidate is None:
        m = re.search(r'(?:\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430|\u041e\u0442\u0447\u0435\u0442|DataProcessor|Report)\.([^.]+)\.(?:\u041c\u043e\u0434\u0443\u043b\u044c\u041e\u0431\u044a\u0435\u043a\u0442\u0430|ObjectModule)', line)
        if m:
            candidate = os.path.join(source_dir, m.group(1), 'Ext', 'ObjectModule.bsl')
    if candidate is None:
        m = re.search(r'(?:\u041e\u0431\u0440\u0430\u0431\u043e\u0442\u043a\u0430|\u041e\u0442\u0447\u0435\u0442|DataProcessor|Report)\.([^.]+)\.(?:\u041c\u043e\u0434\u0443\u043b\u044c\u041c\u0435\u043d\u0435\u0434\u0436\u0435\u0440\u0430|ManagerModule)', line)
        if m:
            candidate = os.path.join(source_dir, m.group(1), 'Ext', 'ManagerModule.bsl')
    if candidate and os.path.isfile(candidate):
        return candidate
    return None


# True, если платформа нашла проблемы — вызывающий не собирает артефакт.
def invoke_source_check(exe, base_path, flags, source_dir, extra_args):
    exe_dir = os.path.dirname(exe)
    exe_leaf = os.path.basename(exe)
    if exe_leaf.lower().startswith('ibcmd'):
        v8 = os.path.join(exe_dir, '1cv8' + os.path.splitext(exe)[1])
    else:
        v8 = exe
    if not os.path.exists(v8):
        print(f'[note] source check skipped: 1cv8 not found at {v8}')
        return False
    d = os.path.join(tempfile.gettempdir(), f'epf_check_{random.randint(0, 999999)}')
    os.makedirs(d, exist_ok=True)
    try:
        out_file = os.path.join(d, 'check_log.txt')
        a = (['DESIGNER', '/F', f'"{base_path}"', '/CheckConfig'] + flags
             + ['/Out', f'"{out_file}"', '/DisableStartupDialogs']
             + [quote_if_needed(x) for x in extra_args])
        print(f'Running: 1cv8.exe {" ".join(a)}')
        result = run_v8(v8, a)
        lines = []
        if os.path.isfile(out_file):
            try:
                with io.open(out_file, encoding='utf-8-sig', errors='replace') as fh:
                    raw = fh.read()
                lines = [l for l in raw.splitlines() if l.strip()]
            except Exception:
                lines = []
        # Платформа отвечает 101 на найденные проблемы; «Ошибок не обнаружено» приходит с кодом 0.
        if result.returncode == 0:
            return False
        print('Error: \u043f\u043b\u0430\u0442\u0444\u043e\u0440\u043c\u0430 \u043d\u0430\u0448\u043b\u0430 \u043f\u0440\u043e\u0431\u043b\u0435\u043c\u044b \u0432 \u0438\u0441\u0445\u043e\u0434\u043d\u0438\u043a\u0430\u0445 \u2014 \u0441\u0431\u043e\u0440\u043a\u0430 \u043e\u0442\u043c\u0435\u043d\u0435\u043d\u0430')
        # Пустой лог при ненулевом коде — отказ не по находкам (база занята, нет лицензии); молчать нельзя.
        if not lines:
            print(f'  платформа вернула код {result.returncode} без сообщений')
        for l in lines:
            print(f'  {l.rstrip()}')
            src_path = resolve_source_path(l, source_dir)
            if src_path:
                print(f'    -> {src_path}')
        return True
    finally:
        shutil.rmtree(d, ignore_errors=True)


# Проверять ли исходники: -Checks off сильнее настройки проекта externalCheck.
def get_source_check_list(checks):
    known = ['modules', 'handlers', 'unreferenced', 'empty-handlers', 'config']
    if checks:
        lst = [c.strip().lower() for c in checks.split(',') if c.strip()]
        if 'off' in lst:
            return []
        for c in lst:
            if c not in known:
                print(f'Error: unknown check \'{c}\' (expected: {", ".join(known)} or off)')
                sys.exit(1)
        return lst
    pf = _sg_find_v8project(os.getcwd())
    if pf:
        try:
            with open(pf, encoding='utf-8-sig') as fh:
                proj = json.load(fh)
            if 'externalCheck' in proj and not proj['externalCheck']:
                return []
        except Exception:
            pass
    return ['modules', 'handlers']


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
    # Что проверить в исходниках перед сборкой: modules (синтаксис в контекстах), handlers,
    # unreferenced, empty-handlers, config; off — не проверять. По умолчанию modules,handlers.
    parser.add_argument("-Checks", default="")
    # Контексты синтаксической проверки. По умолчанию ThinClient,Server.
    parser.add_argument("-Context", default="")
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
    args.SourceFile = clean_path(args.SourceFile, "-SourceFile")
    args.OutputFile = clean_path(args.OutputFile, "-OutputFile")

    # --- Resolve V8Path ---
    v8path = resolve_v8path(args.V8Path)
    engine = "ibcmd" if os.path.basename(v8path).lower().startswith("ibcmd") else "1cv8"

    # --- Resolve additional arguments for the selected engine ---
    arg_hints = {
        "/F": "-InfoBasePath",
        "/S": "-InfoBaseServer + -InfoBaseRef",
        "/N": "-UserName",
        "/P": "-Password",
        "--db-path": "-InfoBasePath",
        "--user": "-UserName",
        "--password": "-Password",
    }
    extra_args = resolve_extra_args(engine, v8_extra, ibcmd_extra, arg_hints)
    if engine == "ibcmd" and args.InfoBaseServer and args.InfoBaseRef:
        print("Error: ibcmd supports file infobases only (use -InfoBasePath or omit for stub)")
        sys.exit(1)

    # --- Что проверяем в исходниках перед сборкой ---
    check_list = get_source_check_list(args.Checks)
    context_list = [c.strip() for c in args.Context.split(',') if c.strip()] if args.Context else []
    if not context_list:
        context_list = ['ThinClient', 'Server']
    elif check_list and 'modules' not in check_list:
        print('Error: -Context задан, но в -Checks нет modules — контексты относятся только к ней')
        sys.exit(1)
    source_dir = os.path.dirname(os.path.abspath(args.SourceFile))

    def new_stub_base(base_path, embed):
        # The stub runs its own platform processes (CREATEINFOBASE, LoadConfigFromFiles,
        # UpdateDBCfg) — they need the same extra arguments as the final build. Only the
        # explicit ones are forwarded: the stub reads .v8-project.json itself.
        stub_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "stub-db-create.py")
        stub_cmd = [sys.executable, stub_script, "-SourceDir", source_dir, "-V8Path", v8path,
                    "-TempBasePath", base_path]
        if embed:
            stub_cmd += ["-EmbedSourceFile", args.SourceFile]
        if v8_extra:
            stub_cmd += ["-AdditionalV8Arguments"] + list(v8_extra)
        if ibcmd_extra:
            stub_cmd += ["-AdditionalIbcmdArguments"] + list(ibcmd_extra)
        return subprocess.run(stub_cmd, capture_output=False).returncode

    # --- Auto-create stub database if no connection specified ---
    auto_created_base = None
    check_base = None
    check_base_path = None
    if not args.InfoBasePath and (not args.InfoBaseServer or not args.InfoBaseRef):
        auto_base_path = os.path.join(tempfile.gettempdir(), f"epf_stub_db_{random.randint(0, 999999)}")
        print("No database specified. Creating temporary stub database...")
        if new_stub_base(auto_base_path, bool(check_list)) != 0:
            # С внедрённой обработкой база падает прежде всего из-за самих исходников
            # (пример: DefaultForm на несуществующую форму) — говорить про базу значит увести не туда.
            if check_list:
                print('Error: платформа не приняла исходники при подготовке проверки — сборка отменена')
                print('  сообщение платформы выше; имя объекта в нём конфигурационное: DataProcessor/Report = проверяемая внешняя обработка/отчёт')
            else:
                print("Error: failed to create stub database")
            sys.exit(1)
        args.InfoBasePath = auto_base_path
        auto_created_base = auto_base_path
        if check_list:
            check_base_path = auto_base_path
    elif check_list:
        # Базу указали снаружи: класть проверяемую обработку в чужую конфигурацию нельзя, поэтому под
        # проверку поднимается своя временная база, а сборка идёт на указанной.
        check_base = os.path.join(tempfile.gettempdir(), f"epf_check_db_{random.randint(0, 999999)}")
        print("Creating temporary database for the source check...")
        if new_stub_base(check_base, True) != 0:
            print('Error: платформа не приняла исходники при подготовке проверки — сборка отменена')
            print('  сообщение платформы выше; имя объекта в нём конфигурационное: DataProcessor/Report = проверяемая внешняя обработка/отчёт')
            sys.exit(1)
        check_base_path = check_base

    # --- Validate source file ---
    if not os.path.isfile(args.SourceFile):
        print(f"Error: source file not found: {args.SourceFile}")
        sys.exit(1)

    # --- Проверка исходников платформой: сломанный .epf до пользователя доезжать не должен ---
    if check_list and check_base_path:
        # Проверку ведёт 1cv8, поэтому ibcmd-шные дополнительные аргументы ей не отдаём.
        check_extra = [] if engine == "ibcmd" else extra_args
        found = invoke_source_check(v8path, check_base_path,
                                    get_check_flags(check_list, context_list), source_dir, check_extra)
        if found:
            if auto_created_base and os.path.exists(auto_created_base):
                shutil.rmtree(auto_created_base, ignore_errors=True)
            if check_base and os.path.exists(check_base):
                shutil.rmtree(check_base, ignore_errors=True)
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
            arguments.extend(extra_args)
            print(f"Running: ibcmd {_redact(' '.join(format_args_for_display(arguments, engine)), args.Password, args.UserName)}")
            result = run_ibcmd([v8path] + arguments, warn_no_user=False)
            exit_code = result.returncode
            out_missing = exit_code == 0 and not output_nonempty(args.OutputFile)
            if out_missing:
                exit_code = 1
            if exit_code == 0:
                print(f"External data processor/report built successfully: {args.OutputFile}")
            elif out_missing:
                print(f"Error: exit code 0 but no non-empty file at {args.OutputFile} — build produced no output")
            else:
                print(f"Error building external data processor/report (code: {exit_code})")
            sys.exit(exit_code)

        # --- Build arguments ---
        arguments = ["DESIGNER"]

        if args.InfoBaseServer and args.InfoBaseRef:
            arguments += ["/S", f'"{args.InfoBaseServer}/{args.InfoBaseRef}"']
        else:
            arguments += ["/F", f'"{args.InfoBasePath}"']

        if args.UserName:
            arguments.append(f'/N"{args.UserName}"')
        if args.Password:
            arguments.append(f'/P"{args.Password}"')

        arguments += ["/LoadExternalDataProcessorOrReportFromFiles", f'"{args.SourceFile}"', f'"{args.OutputFile}"']

        # --- Output ---
        out_file = os.path.join(temp_dir, "build_log.txt")
        arguments += ["/Out", f'"{out_file}"']
        arguments.append("/DisableStartupDialogs")
        arguments.extend(quote_if_needed(a) for a in extra_args)

        # --- Execute ---
        print(f"Running: 1cv8.exe {_redact(' '.join(format_args_for_display(arguments, engine)), args.Password, args.UserName)}")
        result = run_v8(v8path, arguments)
        exit_code = result.returncode

        # --- Result ---
        # Postcondition: exit 0 without a non-empty output file is a false success.
        out_missing = exit_code == 0 and not output_nonempty(args.OutputFile)
        if out_missing:
            exit_code = 1
        if exit_code == 0:
            print(f"Build completed successfully: {args.OutputFile}")
        elif out_missing:
            print(f"Error: exit code 0 but no non-empty file at {args.OutputFile} — build produced no output")
        else:
            print(f"Error building (code: {exit_code})")

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

        print_platform_output(result)
        sys.exit(exit_code)

    finally:
        if os.path.exists(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)
        if auto_created_base and os.path.exists(auto_created_base):
            shutil.rmtree(auto_created_base, ignore_errors=True)
        if check_base and os.path.exists(check_base):
            shutil.rmtree(check_base, ignore_errors=True)


if __name__ == "__main__":
    main()
