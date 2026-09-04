#!/usr/bin/env python3
# db-repo v1.14 — 1C configuration repository operations
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# NB: движок только 1cv8 — ibcmd работу с хранилищем не поддерживает (нет такого режима).
"""Работа с хранилищем конфигурации 1С.

Захват и помещение объектов, получение изменений, подключение базы к хранилищу,
история версий, администрирование хранилища.
"""

import argparse
import glob
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile


# --- Additional platform arguments ---
# Свои ключи: доп. аргументами нельзя ни подсунуть вторую пакетную операцию, ни подменить
# реквизиты хранилища. Список команд перечислен поимённо — arg_key_match считает совпадением
# только точное имя или имя с не-буквой следом, поэтому общий префикс ключи не покрыл бы.
V8_OWNED_KEYS = [
    "DESIGNER", "ENTERPRISE", "CREATEINFOBASE", "CONFIG",
    "/F", "/S", "/N", "/P", "/Out", "/DisableStartupDialogs", "/DisableStartupMessages",
    "/ConfigurationRepositoryF", "/ConfigurationRepositoryN", "/ConfigurationRepositoryP",
    "/ConfigurationRepositoryLock", "/ConfigurationRepositoryUnlock",
    "/ConfigurationRepositoryCommit", "/ConfigurationRepositoryUpdateCfg",
    "/ConfigurationRepositoryBindCfg", "/ConfigurationRepositoryUnbindCfg",
    "/ConfigurationRepositoryDumpCfg", "/ConfigurationRepositoryReport",
    "/ConfigurationRepositoryCreate", "/ConfigurationRepositoryAddUser",
    "/ConfigurationRepositoryCopyUsers", "/ConfigurationRepositorySetLabel",
    "/ConfigurationRepositoryOptimizeData", "/ConfigurationRepositoryClearCache",
    "/ConfigurationRepositoryClearLocalCache", "/ConfigurationRepositoryClearGlobalCache",
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

IBCMD_OWNED_KEYS = []
V8_SECRET_KEYS = ["/P", "/UC", "/WSP", "/AWSP", "/ConfigurationRepositoryP", "-Pwd"]
IBCMD_SECRET_KEYS = []

# Известные ключи хранилища — всё, что начинается с /ConfigurationRepository и не совпало с ними,
# это опечатка или усечение. Отдельная проверка нужна потому, что усечённый ключ платформа НЕ
# считает ошибкой: она открывает конфигуратор интерактивно и висит вечно (в /Out только BOM).
REPO_KNOWN_KEYS = [k for k in V8_OWNED_KEYS if k.startswith("/ConfigurationRepository")]


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



def assert_no_truncated_repo_keys(arglist):
    for tok in arglist:
        if not tok.lower().startswith("/configurationrepository"):
            continue
        if not any(arg_key_match(tok, k) for k in REPO_KNOWN_KEYS):
            print("Error: unknown configuration repository key '%s' — the platform would open "
                  "the Designer interactively and hang instead of failing" % tok)
            sys.exit(1)


def resolve_extra_args(v8_extra, hints):
    """Движок только 1cv8, поэтому ветки ibcmd (в остальных db-* она есть) здесь нет."""
    extra = project_extra_args("v8args") + list(v8_extra)
    if extra:
        assert_extra_args(extra, "1cv8", hints)
        assert_no_truncated_repo_keys(extra)
    return extra


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


# --- Список объектов ---
# Наружу — один формат: плоский список имён, как у db-dump-xml -Mode Partial -Objects.
# Платформенный XML (http://v8.1c.ru/8.3/config/objects) генерируется здесь и модели не показывается.
#
# Нормализовать имена не нужно: платформа принимает и русские, и английские имена типов
# (Catalog.Склады → «Объект захвачен: Справочник.Склады») и подчинённые пути в обеих раскладках.
CONFIG_ROOT_ALIASES = ["Конфигурация", "Configuration"]

# Подчинённые сущности, которые НЕ являются объектами хранилища: в XML владельца они записаны
# вложенным определением, своего файла и UUID у них нет — захватывать нечего. Отдельными объектами
# регистрируются только те, кто записан ССЫЛКОЙ по имени: форма, макет, команда.
# Платформа на такой запрос отвечает «Загруженный список объектов пуст» — без имени и без причины.
INLINE_CHILD_KINDS = [
    "Реквизит", "Attribute",
    "СтандартныйРеквизит", "StandardAttribute",
    "РеквизитАдресации", "AddressingAttribute",
    "ТабличнаяЧасть", "TabularSection",
    "Измерение", "Dimension",
    "Ресурс", "Resource",
    "Графа", "Column",
    "ЗначениеПеречисления", "EnumValue",
    "ПризнакУчета", "ПризнакУчёта", "AccountingFlag",
    "ПризнакУчетаСубконто", "ПризнакУчётаСубконто", "ExtDimensionAccountingFlag",
]


def xml_attr(value):
    return (value.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def requested_objects(args):
    """Плоский список имён из -Objects и/или -ObjectsFile. Пустой список = вся конфигурация."""
    out = []
    if args.Objects:
        out += [s.strip() for s in args.Objects.split(",") if s.strip()]
    if args.ObjectsFile:
        if not os.path.exists(args.ObjectsFile):
            print("Error: -ObjectsFile not found: %s" % args.ObjectsFile)
            sys.exit(1)
        with open(args.ObjectsFile, encoding="utf-8-sig") as f:
            out += [s.strip() for s in f.read().splitlines()
                    if s.strip() and not s.strip().startswith("#")]
    seen = {}
    uniq = []
    for name in out:
        if name.lower() not in seen:
            seen[name.lower()] = True
            uniq.append(name)
    return uniq


def resolve_lockable_objects(names):
    """Заменяет части объекта на сам объект. Это не сужение и не расширение запроса: владелец —
    минимально возможная единица захвата для того, что просили."""
    out = []
    notes = []
    for n in names:
        segs = n.split(".")
        resolved = n
        if len(segs) >= 3 and segs[2] in INLINE_CHILD_KINDS:
            resolved = "%s.%s" % (segs[0], segs[1])
            notes.append("%s -> %s" % (n, resolved))
        if resolved not in out:
            out.append(resolved)
    if notes:
        print("[note] части объекта отдельно не захватываются — взят объект-владелец:")
        for x in notes:
            print("  %s" % x)
    return out


def write_objects_list_xml(names, path, with_children):
    """Пишет платформенный XML со списком объектов, возвращает путь к файлу."""
    child = "true" if with_children else "false"
    lines = ['<Objects xmlns="http://v8.1c.ru/8.3/config/objects" version="1.0">']
    for n in names:
        if n in CONFIG_ROOT_ALIASES:
            # Корень конфигурации — отдельный элемент. Нужен, чтобы добавить или удалить объект:
            # без захвата корня частичная загрузка нового объекта не проходит.
            lines.append('    <Configuration includeChildObjects="%s"/>' % child)
            continue
        esc = xml_attr(n)
        is_subsystem = bool(re.match(r"^(Подсистема|Subsystem)\.", n))
        if is_subsystem and with_children:
            # includeChildObjects у подсистемы означает вложенные ПОДСИСТЕМЫ, а её состав
            # подтягивает только вложенный <Subsystem> — поэтому под -WithChildren нужны оба.
            lines.append('    <Object fullName="%s" includeChildObjects="true">' % esc)
            lines.append('        <Subsystem includeObjectsFromSubordinateSubsystems="true"/>')
            lines.append('    </Object>')
        else:
            lines.append('    <Object fullName="%s" includeChildObjects="%s"/>' % (esc, child))
    lines.append('</Objects>')
    with open(path, "w", encoding="utf-8-sig", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return path


# --- Разбор лога операции ---
# Платформа отчитывается ПОСТРОЧНО, и код возврата про фактический результат не говорит:
# захват не атомарен (код 1 при реально захваченном объекте), а все no-op'ы дают код 0.
def read_repo_log(log_text):
    r = {
        "locked": [], "locked_by_other": [], "received": [], "committed": [],
        "unchanged": [], "unlocked": [], "not_locked": [], "modified": [], "missing": [],
        "has_operation_block": False, "raw": log_text,
    }
    if not log_text:
        return r
    in_missing = False
    for raw in log_text.splitlines():
        line = raw.strip()
        if not line:
            in_missing = False
            continue
        if re.match(r"^-+\s*Начало операции с хранилищем", line):
            r["has_operation_block"] = True
            in_missing = False
            continue
        if re.match(r"^-+\s*Операция с хранилищем", line):
            in_missing = False
            continue
        if line.startswith("Объекты, отсутствующие в обеих конфигурациях"):
            in_missing = True
            continue
        if in_missing:
            r["missing"].append(line)
            continue
        m = re.match(r"^Объект захвачен для редактирования другим пользователем:\s*(.+?)\s*\((.+?)\)\s*$", line)
        if m:
            r["locked_by_other"].append({"name": m.group(1), "holder": m.group(2)})
            continue
        for pattern, key in (
            (r"^Объект захвачен для редактирования:\s*(.+)$", "locked"),
            (r"^Объект получен из хранилища:\s*(.+)$", "received"),
            (r"^Объект помещен в хранилище:\s*(.+)$", "committed"),
            (r"^Объект не был изменен:\s*(.+)$", "unchanged"),
            (r"^Захват объекта отменен:\s*(.+)$", "unlocked"),
            (r"^Объект не захвачен для редактирования:\s*(.+)$", "not_locked"),
            (r"^Объект '(.+?)' был изменен", "modified"),
        ):
            m = re.match(pattern, line)
            if m:
                r[key].append(m.group(1).strip())
                break
    return r


# --- Полученные объекты → готовая команда перевыгрузки ---
# Захват и обновление МОЛЧА подтягивают свежие версии в локальную конфигурацию. Если после этого
# загрузить старые исходники, чужие изменения откатятся без единой ошибки. Выгрузку не делаем сами
# (она затрёт локальные правки) — печатаем готовую команду.
def owner_objects(names):
    owners = []
    for n in names:
        parts = n.split(".")
        if len(parts) == 1:
            continue  # корень конфигурации: частично по имени не выгружается
        owner = "%s.%s" % (parts[0], parts[1]) if len(parts) > 2 else n
        if owner not in owners:
            owners.append(owner)
    return owners


def print_received_warning(received):
    if not received:
        return
    print("")
    print("[warning] локальная конфигурация изменена, получено объектов из хранилища: %d" % len(received))
    for n in received[:LIST_LIMIT]:
        print("  %s" % n)
    if len(received) > LIST_LIMIT:
        print("  … и ещё %d" % (len(received) - LIST_LIMIT))
    owners = owner_objects(received)
    has_root = any(len(n.split(".")) == 1 for n in received)
    if owners:
        list_path = os.path.join(tempfile.gettempdir(), "db-repo-received.txt")
        with open(list_path, "w", encoding="utf-8-sig", newline="\n") as f:
            f.write("\n".join(owners) + "\n")
        print("Исходники в проекте устарели по этим объектам. Перевыгрузите их ПЕРЕД правкой,")
        print("иначе частичная загрузка старых исходников молча откатит чужие изменения:")
        print('  /db-dump-xml <база> <каталог> -Mode Partial -ObjectsFile "%s"' % list_path)
    if has_root:
        print("Получен корень конфигурации — по имени он частично не выгружается,")
        print("используйте /db-dump-xml -Mode Changes.")


# --- Подкоманды ---
# Ключ выбирается по таблице: произвольный ключ задать нельзя. Неизвестная подкоманда — ошибка,
# а не проброс: платформа на неизвестный ключ открывает конфигуратор и висит.
COMMAND_KEYS = {
    "lock": "/ConfigurationRepositoryLock",
    "unlock": "/ConfigurationRepositoryUnlock",
    "commit": "/ConfigurationRepositoryCommit",
    "update": "/ConfigurationRepositoryUpdateCfg",
    "connect": "/ConfigurationRepositoryBindCfg",
    "disconnect": "/ConfigurationRepositoryUnbindCfg",
    "report": "/ConfigurationRepositoryReport",
    "dump-cfg": "/ConfigurationRepositoryDumpCfg",
    "create": "/ConfigurationRepositoryCreate",
    "add-user": "/ConfigurationRepositoryAddUser",
    "copy-users": "/ConfigurationRepositoryCopyUsers",
    "set-label": "/ConfigurationRepositorySetLabel",
    "optimize": "/ConfigurationRepositoryOptimizeData",
    "clear-cache": "/ConfigurationRepositoryClearCache",
}

# Прощающий ввод: синонимы намеренно НЕ документируются, в SKILL.md одна каноничная форма.
COMMAND_ALIASES = {
    "capture": "lock", "захватить": "lock",
    "release": "unlock", "отменить-захват": "unlock",
    "put": "commit", "поместить": "commit",
    "pull": "update", "получить": "update", "update-cfg": "update",
    "bind": "connect",
    "dumpcfg": "dump-cfg", "dump": "dump-cfg",
    "adduser": "add-user", "copyusers": "copy-users", "setlabel": "set-label",
    "clearcache": "clear-cache", "optimize-data": "optimize",
}


def resolve_command(raw):
    c = raw.strip().lower()
    # unbind отличается от unlock одной буквой, а последствия разные: отмена захвата против
    # отключения базы от хранилища. Молча угадывать нельзя.
    if c == "unbind":
        print("Error: 'unbind' is ambiguous — did you mean 'unlock' (release captured objects) "
              "or 'disconnect' (detach the base from the repository)?")
        sys.exit(1)
    c = COMMAND_ALIASES.get(c, c)
    if c not in COMMAND_KEYS:
        print("Error: unknown command '%s'. Known: %s" % (raw, ", ".join(sorted(COMMAND_KEYS))))
        sys.exit(1)
    return c


# --- Вердикт ---
# Код возврата платформы про фактический результат не говорит: захват и помещение НЕ атомарны
# (код 1 при реально захваченном объекте), а все no-op'ы дают код 0. Меряем не «изменилось ли»,
# а «достигнуто ли запрошенное»: достигнуто, в том числе уже было — 0; частично — 0 с поимённым
# предупреждением; не достигнуто ничего — 1.
def object_key(name):
    """Ключ для сопоставления запрошенного с тем, что назвала платформа. Имена типов в паре
    «запрос ↔ лог» бывают на разных языках: платформа ПРИНИМАЕТ Catalog.Номенклатура, а
    ОТВЕЧАЕТ всегда Справочник.Номенклатура. Поэтому сравниваем только собственные имена —
    нечётные сегменты пути; они в обеих раскладках одинаковы, и карта типов не нужна.
    Цена приёма: Справочник.Х и Документ.Х дают один ключ. Влияет только на формулировку
    вердикта, не на выполненную операцию."""
    segs = name.split(".")
    own = segs[1::2]
    if not own:
        own = [segs[0]]
    return ".".join(own).lower()


# Операция над всей конфигурацией перечисляет тысячи объектов. Печатаем начало списка,
# остальное кладём в файл: модели нужен факт и путь, а не простыня.
LIST_LIMIT = 20


def save_object_list(names, key):
    if not key:
        key = "objects"
    path = os.path.join(tempfile.gettempdir(), "db-repo-%s.txt" % key)
    with open(path, "w", encoding="utf-8-sig", newline="\n") as f:
        f.write("\n".join(names) + "\n")
    return path


def print_repo_objects(title, names, file_key="objects"):
    if not names:
        return
    print("%s (%d):" % (title, len(names)))
    for n in names[:LIST_LIMIT]:
        print("  %s" % n)
    if len(names) > LIST_LIMIT:
        path = save_object_list(names, file_key)
        print("  … и ещё %d; полный список: %s" % (len(names) - LIST_LIMIT, path))


def write_repo_verdict(cmd, log, platform_exit, requested, report_format="", output_file=""):
    if log["missing"]:
        print("Error: objects not found in the configuration:")
        for n in log["missing"][:LIST_LIMIT]:
            print("  %s" % n)
        if len(log["missing"]) > LIST_LIMIT:
            print("  … и ещё %d; полный список: %s"
                  % (len(log["missing"]) - LIST_LIMIT, save_object_list(log["missing"], "missing")))
        print("Возможные причины:")
        print("  - опечатка в имени. Принимаются обе формы: Справочник.Номенклатура и Catalog.Номенклатура")
        print("  - база отстала от хранилища, объект появился позже — выполните /db-repo update")
        print("  - это не объект хранилища: реквизиты, табличные части, измерения и ресурсы")
        print("    отдельно не захватываются — указывайте объект-владельца")
        return 1

    if cmd == "lock":
        # Порядок вывода: факты, затем вердикт, и только потом совет. Совет длинный, и
        # между фактами и вердиктом он прятал бы главную строку.
        print_repo_objects("Захвачено", log["locked"], "locked")
        if log["locked_by_other"]:
            print("Не удалось захватить (%d):" % len(log["locked_by_other"]))
            for o in log["locked_by_other"][:LIST_LIMIT]:
                print("  %s — держит %s" % (o["name"], o["holder"]))
            if len(log["locked_by_other"]) > LIST_LIMIT:
                path = save_object_list(
                    ["%s — %s" % (o["name"], o["holder"]) for o in log["locked_by_other"]], "blocked")
                print("  … и ещё %d; полный список: %s"
                      % (len(log["locked_by_other"]) - LIST_LIMIT, path))
        if not log["locked"] and log["locked_by_other"]:
            # «Уже захвачено мной» платформа не печатает вовсе, поэтому отличить его от
            # «не захвачено» по логу нельзя — сверяем с тем, что просили. Заняты ВСЕ
            # запрошенные объекты только тогда, когда каждый из них назван занятым.
            blocked = {object_key(o["name"]) for o in log["locked_by_other"]}
            asked = [object_key(n) for n in requested]
            all_blocked = (not asked) or all(k in blocked for k in asked)
            if all_blocked:
                print("Захват не выполнен: все запрошенные объекты заняты.")
                print_received_warning(log["received"])
                return 1
            print("[warning] часть запрошенного занята другими; остальное уже было захвачено вами.")
            print("          Захваченное можно править: код возврата 0 именно поэтому.")
            print_received_warning(log["received"])
            return 0
        if not log["locked"] and platform_exit == 0:
            # Захват уже захваченного СОБОЙ: платформа не печатает ни блока операции, ни строк.
            print("Объекты уже захвачены вами — изменений не потребовалось.")
            print_received_warning(log["received"])
            return 0
        if not log["locked"]:
            print("Захват не выполнен (код %s)%s" % (platform_exit, describe_exit(platform_exit)))
            print_received_warning(log["received"])
            return 1
        if log["locked_by_other"]:
            print("[warning] захват выполнен частично — перечисленные выше объекты остались у других пользователей.")
            print("          Захваченное можно править: код возврата 0 именно поэтому.")
            print_received_warning(log["received"])
            return 0
        print_received_warning(log["received"])
        return platform_exit

    if cmd == "unlock":
        # Отмена захвата атомарна: при локальных изменениях платформа отменяет операцию целиком.
        if platform_exit != 0:
            if log["modified"]:
                print("Отмена захвата не выполнена: у объектов есть локальные изменения (%d):" % len(log["modified"]))
                for n in log["modified"][:LIST_LIMIT]:
                    print("  %s" % n)
                if len(log["modified"]) > LIST_LIMIT:
                    print("  … и ещё %d; полный список: %s"
                          % (len(log["modified"]) - LIST_LIMIT, save_object_list(log["modified"], "modified")))
                print("Поместите их (/db-repo commit) либо откажитесь от них: -Force перезапишет "
                      "объекты версией из хранилища.")
            else:
                print("Отмена захвата не выполнена (код %s)%s" % (platform_exit, describe_exit(platform_exit)))
            return 1
        print_repo_objects("Захват отменён", log["unlocked"], "unlocked")
        print_repo_objects("Не были захвачены — снимать нечего", log["not_locked"], "not-locked")
        if not log["unlocked"]:
            print("Изменений не потребовалось.")
        print_received_warning(log["received"])
        return 0

    if cmd == "commit":
        if platform_exit != 0:
            # Платформа отдаёт голую «Ошибка помещения изменений объектов в хранилище» —
            # ни объекта, ни причины, одинаково для всех причин. Диагностику даём свою.
            print("Помещение не выполнено (код %s)%s" % (platform_exit, describe_exit(platform_exit)))
            print("Платформа не называет причину. Проверьте:")
            print("  - захвачен ли объект вами: /db-repo lock")
            print("  - не держит ли его другой пользователь")
            print("  - есть ли у пользователя хранилища право на помещение")
            return 1
        print_repo_objects("Помещено в хранилище", log["committed"], "committed")
        print_repo_objects("Без изменений — не помещались", log["unchanged"], "unchanged")
        if not log["committed"]:
            print("Новая версия в хранилище НЕ создана: помещать было нечего.")
        return 0

    if cmd == "update":
        if platform_exit != 0:
            print("Получение изменений не выполнено (код %s)%s" % (platform_exit, describe_exit(platform_exit)))
            return 1
        if not log["has_operation_block"]:
            # У подключённой базы лог всегда содержит блок операции — даже когда получать нечего.
            # Его отсутствие означает, что база к хранилищу НЕ подключена, а тогда эта команда
            # молча заменяет всю конфигурацию содержимым хранилища и рапортует успех.
            print("Error: the platform reported success but printed no repository operation block.")
            print("       Похоже, база НЕ подключена к хранилищу — в этом случае команда заменяет")
            print("       всю конфигурацию базы содержимым хранилища. Проверьте состояние базы.")
            return 1
        print_repo_objects("Получено из хранилища", log["received"], "received")
        if not log["received"]:
            print("Изменений в хранилище нет — конфигурация уже актуальна.")
            return 0
        print_received_warning(log["received"])
        return 0

    if platform_exit != 0:
        print("Команда '%s' завершилась с ошибкой (код %s)%s"
              % (cmd, platform_exit, describe_exit(platform_exit)))
        # Подключение базы, у которой конфигурация уже есть, платформа отклоняет без
        # подсказки — а действие ровно одно, и оно необратимо.
        if "связанная с данным хранилищем" in (log.get("raw") or ""):
            print("[hint] за этим пользователем хранилища уже числится другая база.")
            print("       Подключить всё равно — -ForceBindAlreadyBindedUser.")
        if "Конфигурация не пустая" in (log.get("raw") or ""):
            print("[hint] в базе уже есть конфигурация. Замена её конфигурацией из хранилища —")
            print("       -ForceReplaceCfg. Операция необратима: спросите подтверждение у пользователя.")
            print("       Если база уже была подключена, понадобится ещё -ForceBindAlreadyBindedUser.")
        return 1
    print("Команда '%s' выполнена." % cmd)
    if cmd == "report" and report_format == "txt" and os.path.exists(output_file):
        with open(output_file, encoding="utf-8-sig") as f:
            lines = f.read().rstrip().splitlines()
        # Короткий отчёт печатаем целиком, длинный — не печатаем ВОВСЕ. Обрезанный отчёт
        # по версиям опаснее длинного: он читается как полный ответ, и по куску легко
        # заключить «объект не менялся». Список объектов при обрезке хотя бы очевидно неполон.
        if len(lines) <= 100:
            print("--- %s ---" % output_file)
            print(chr(10).join(lines))
            print("--- End ---")
        else:
            print("Отчёт не печатается целиком (строк: %d): %s" % (len(lines), output_file))
            print("Сузьте выборку: -NBegin -1 (только последняя версия), -NBegin/-NEnd (диапазон),")
            print("-DateBegin/-DateEnd (период), -GroupByObject (сводка по объектам).")
    return 0

def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="1C configuration repository operations",
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
    parser.add_argument("-Extension", default="")
    parser.add_argument("-Objects", default="")
    parser.add_argument("-ObjectsFile", default="")
    parser.add_argument("-WithChildren", action="store_true")
    # Операция над ВСЕЙ конфигурацией. Отдельный флаг, а не умолчание при забытом -Objects:
    # захват всей конфигурации на большой базе идёт долго и блокирует работу всей команде.
    parser.add_argument("-All", dest="All", action="store_true")
    parser.add_argument("-Comment", default="")
    parser.add_argument("-KeepLocked", action="store_true")
    parser.add_argument("-Force", action="store_true")
    parser.add_argument("-Revised", action="store_true")
    parser.add_argument("-Version", dest="Version", default="")
    parser.add_argument("-OutputFile", default="")
    # --- report ---
    parser.add_argument("-NBegin", default="")
    parser.add_argument("-NEnd", default="")
    parser.add_argument("-DateBegin", default="")
    parser.add_argument("-DateEnd", default="")
    parser.add_argument("-GroupByObject", action="store_true")
    parser.add_argument("-GroupByComment", action="store_true")
    parser.add_argument("-ReportFormat", default="txt", choices=["txt", "mxl"])
    # --- users ---
    parser.add_argument("-NewUser", default="")
    parser.add_argument("-NewUserPassword", default="")
    parser.add_argument("-Rights", default="", choices=[
        "", "ReadOnly", "LockObjects", "ManageConfigurationVersions", "Administration"])
    parser.add_argument("-RestoreDeletedUser", action="store_true")
    parser.add_argument("-SourcePath", default="")
    parser.add_argument("-SourceUser", default="")
    parser.add_argument("-SourcePassword", default="")
    # --- create / connect ---
    parser.add_argument("-NoBind", action="store_true")
    parser.add_argument("-AllowConfigurationChanges", action="store_true")
    parser.add_argument("-ChangesAllowedRule", default="", choices=[
        "", "ObjectNotEditable", "ObjectIsEditableSupportEnabled", "ObjectNotSupported"])
    parser.add_argument("-ChangesNotRecommendedRule", default="", choices=[
        "", "ObjectNotEditable", "ObjectIsEditableSupportEnabled", "ObjectNotSupported"])
    parser.add_argument("-ForceReplaceCfg", action="store_true")
    parser.add_argument("-ForceBindAlreadyBindedUser", action="store_true")
    parser.add_argument("-Label", default="")
    parser.add_argument("-CacheScope", default="local", choices=["local", "global", "db"])
    parser.add_argument("-AdditionalV8Arguments", nargs="*", default=[],
                        help="Extra 1cv8 arguments, e.g. /UseHwLicenses+")
    known_opts = {s.lower() for a in parser._actions for s in a.option_strings}
    argv, v8_extra, _ = extract_extra_args(sys.argv[1:], known_opts)
    args = ci_parse_args(parser, argv)

    args.V8Path = clean_path(args.V8Path, "-V8Path")
    args.InfoBasePath = clean_path(args.InfoBasePath, "-InfoBasePath")
    assert_infobase_exists(args.InfoBasePath)
    v8path = resolve_v8path(args.V8Path)

    if not args.Command:
        print("Error: -Command is required. Known: %s" % ", ".join(sorted(COMMAND_KEYS)))
        sys.exit(1)
    cmd = resolve_command(args.Command)

    if not args.InfoBasePath and not (args.InfoBaseServer and args.InfoBaseRef):
        print("Error: specify -InfoBasePath, or -InfoBaseServer together with -InfoBaseRef")
        sys.exit(1)

    repo = resolve_repository_settings(args)
    if not repo["path"]:
        if args.Extension:
            print("Error: repository path for extension '%s' is unknown — add extensions[].repository "
                  "to the database record in .v8-project.json, or pass -RepositoryPath" % args.Extension)
            print("       Note: an extension has its OWN repository with its own path.")
        else:
            print("Error: repository path is unknown — add repository to the database record "
                  "in .v8-project.json, or pass -RepositoryPath")
        sys.exit(1)

    # Подтверждение деструктивных операций спрашивает модель (см. SKILL.md) — так же, как у полной
    # загрузки в db-load-xml. Здесь остаётся только то, что моделью не проверяется: команда update на
    # базе, про которую реестр не знает, что она подключена к хранилищу. На НЕподключённой базе
    # UpdateCfg молча заменяет всю конфигурацию содержимым хранилища и рапортует успех.
    if cmd == "update" and not repo["from_registry"] and not args.RepositoryPath:
        print("Error: the database record in .v8-project.json declares no repository — refusing to run update")
        print("       On a base NOT bound to a repository this command silently REPLACES the whole configuration")
        print("       with the repository content and still reports success.")
        sys.exit(1)

    object_aware = ["lock", "unlock", "commit", "update"]
    requested = resolve_lockable_objects(requested_objects(args))
    if requested and cmd not in object_aware:
        print("Error: -Objects/-ObjectsFile does not apply to '%s'" % cmd)
        sys.exit(1)

    # Операции над всей конфигурацией требуют явного -All. Умолчанием это быть не может: захват
    # всей конфигурации на большой базе идёт долго и блокирует работу всей команде, а получается
    # такой вызов от одного забытого -Objects.
    whole_config_aware = ["lock", "unlock", "commit"]
    if args.All and requested:
        print("Error: -All (whole configuration) contradicts -Objects/-ObjectsFile — pick one")
        sys.exit(1)
    if cmd in whole_config_aware and not requested and not args.All:
        print("Error: '%s' without -Objects would affect the WHOLE configuration." % cmd)
        print('       Укажите объекты: -Objects "Справочник.Номенклатура"')
        print("       Это и нужно — подтвердите явно: -All")
        sys.exit(1)
    # Корень с подчинёнными — это тоже вся конфигурация, хотя выглядит как «захвачу корень».
    if args.WithChildren:
        root_asked = [n for n in requested if n in CONFIG_ROOT_ALIASES]
        if root_asked:
            print("Error: '%s' with -WithChildren means the WHOLE configuration, not just its root." % root_asked[0])
            print("       Нужен только корень (чтобы добавить или удалить объект) — уберите -WithChildren.")
            print("       Нужна вся конфигурация — вызовите с -All вместо -Objects.")
            sys.exit(1)

    if cmd == "report" and not args.OutputFile:
        # Отчёт печатается в вывод, поэтому путь нужен только если его хотят сохранить.
        args.OutputFile = os.path.join(tempfile.gettempdir(), "db-repo-report.%s" % args.ReportFormat)
    if cmd == "dump-cfg" and not args.OutputFile:
        print("Error: -OutputFile (path to the .cf file) is required for dump-cfg")
        sys.exit(1)
    if cmd == "add-user" and (not args.NewUser or not args.Rights):
        print("Error: -NewUser and -Rights are required for add-user")
        sys.exit(1)
    if cmd == "copy-users" and (not args.SourcePath or not args.SourceUser):
        print("Error: -SourcePath and -SourceUser are required for copy-users")
        sys.exit(1)
    if cmd == "set-label" and not args.Label:
        print("Error: -Label is required for set-label")
        sys.exit(1)

    arg_hints = {
        "/F": "-InfoBasePath",
        "/S": "-InfoBaseServer + -InfoBaseRef",
        "/N": "-UserName",
        "/P": "-Password",
    }
    extra_args = resolve_extra_args(v8_extra, arg_hints)

    temp_dir = os.path.join(tempfile.gettempdir(), "db_repo_%d" % random.randint(1, 2 ** 31))
    os.makedirs(temp_dir, exist_ok=True)
    try:
        # --- Соединение ---
        arguments = ["DESIGNER"]
        if args.InfoBaseServer and args.InfoBaseRef:
            arguments += ["/S", '"%s/%s"' % (args.InfoBaseServer, args.InfoBaseRef)]
        else:
            arguments += ["/F", '"%s"' % args.InfoBasePath]
        if args.UserName:
            arguments.append('/N"%s"' % args.UserName)
        if args.Password:
            arguments.append('/P"%s"' % args.Password)
        arguments += repository_args(repo)

        # --- Команда ---
        key = COMMAND_KEYS[cmd]
        if cmd == "clear-cache":
            key = {"local": "/ConfigurationRepositoryClearLocalCache",
                   "global": "/ConfigurationRepositoryClearGlobalCache",
                   "db": "/ConfigurationRepositoryClearCache"}[args.CacheScope]
        arguments.append(key)

        if cmd in ("dump-cfg", "report"):
            arguments.append('"%s"' % args.OutputFile)

        if cmd in object_aware and requested:
            objects_xml = write_objects_list_xml(
                requested, os.path.join(temp_dir, "objects.xml"), args.WithChildren)
            arguments += ["-Objects", '"%s"' % objects_xml]

        if cmd == "lock":
            if args.Revised:
                arguments.append("-revised")
        elif cmd == "unlock":
            if args.Force:
                arguments.append("-force")
        elif cmd == "commit":
            if args.Comment:
                # Многострочный комментарий задаётся своим -comment на каждую строку.
                for line in args.Comment.splitlines():
                    arguments += ["-comment", '"%s"' % line]
            if args.KeepLocked:
                arguments.append("-keepLocked")
            if args.Force:
                arguments.append("-force")
        elif cmd == "update":
            if args.Version:
                arguments += ["-v", args.Version]
            if args.Revised:
                arguments.append("-revised")
            if args.Force:
                arguments.append("-force")
        elif cmd == "connect":
            if args.ForceBindAlreadyBindedUser:
                arguments.append("-forceBindAlreadyBindedUser")
            if args.ForceReplaceCfg:
                arguments.append("-forceReplaceCfg")
        elif cmd == "disconnect":
            if args.Force:
                arguments.append("-force")
        elif cmd == "dump-cfg":
            if args.Version:
                arguments += ["-v", args.Version]
        elif cmd == "report":
            if args.NBegin:
                arguments += ["-NBegin", args.NBegin]
            if args.NEnd:
                arguments += ["-NEnd", args.NEnd]
            if args.DateBegin:
                arguments += ["-DateBegin", '"%s"' % args.DateBegin]
            if args.DateEnd:
                arguments += ["-DateEnd", '"%s"' % args.DateEnd]
            if args.GroupByObject:
                arguments.append("-GroupByObject")
            if args.GroupByComment:
                arguments.append("-GroupByComment")
            arguments += ["-ReportFormat", args.ReportFormat]
        elif cmd == "create":
            if args.AllowConfigurationChanges:
                arguments.append("-AllowConfigurationChanges")
            if args.ChangesAllowedRule:
                arguments += ["-ChangesAllowedRule", args.ChangesAllowedRule]
            if args.ChangesNotRecommendedRule:
                arguments += ["-ChangesNotRecommendedRule", args.ChangesNotRecommendedRule]
            if args.NoBind:
                arguments.append("-NoBind")
        elif cmd == "add-user":
            arguments += ["-User", '"%s"' % args.NewUser]
            if args.NewUserPassword:
                arguments += ["-Pwd", '"%s"' % args.NewUserPassword]
            arguments += ["-Rights", args.Rights]
            if args.RestoreDeletedUser:
                arguments.append("-RestoreDeletedUser")
        elif cmd == "copy-users":
            arguments += ["-Path", '"%s"' % args.SourcePath]
            arguments += ["-User", '"%s"' % args.SourceUser]
            if args.SourcePassword:
                arguments += ["-Pwd", '"%s"' % args.SourcePassword]
            if args.RestoreDeletedUser:
                arguments.append("-RestoreDeletedUser")
        elif cmd == "set-label":
            if args.Version:
                arguments += ["-v", args.Version]
            arguments += ["-name", '"%s"' % args.Label]
            if args.Comment:
                for line in args.Comment.splitlines():
                    arguments += ["-comment", '"%s"' % line]

        if args.Extension:
            arguments += ["-Extension", '"%s"' % args.Extension]

        log_file = os.path.join(temp_dir, "repo_log.txt")
        arguments += ["/Out", '"%s"' % log_file]
        arguments.append("/DisableStartupDialogs")
        arguments.append("/DisableStartupMessages")
        arguments += extra_args

        secrets = [args.Password, repo["password"], args.NewUserPassword, args.SourcePassword]
        print("Running: 1cv8.exe %s"
              % _redact(" ".join(format_args_for_display(arguments, "1cv8")), *secrets))
        result = run_v8(v8path, arguments)
        exit_code = result.returncode

        log_text = ""
        if os.path.exists(log_file):
            # /Out — всегда UTF-8 с BOM.
            with open(log_file, encoding="utf-8-sig") as f:
                log_text = f.read()
        log = read_repo_log(log_text)
        verdict = write_repo_verdict(cmd, log, exit_code, requested,
                                     args.ReportFormat, args.OutputFile)
        # Разбор мог не покрыть причину (у commit её вовсе нет в логе) — при отказе показываем сырой лог.
        if verdict != 0 and log_text.strip():
            # Лог операции над всей конфигурацией — тысячи строк. Показываем хвост: итог и причина
            # отказа платформа пишет в конце.
            log_lines = log_text.rstrip().splitlines()
            log_limit = 200
            print("--- Log ---")
            if len(log_lines) > log_limit:
                print("[... показаны последние %d строк из %d ...]" % (log_limit, len(log_lines)))
                log_lines = log_lines[-log_limit:]
            print("\n".join(log_lines))
            print("--- End ---")
        # Реестр — не формальность: без repository реквизиты придётся передавать в каждом вызове,
        # а update откажется работать вовсе. Модель об этом не вспомнит, поэтому даём готовый блок.
        # «Соединение не установлено» у сетевого хранилища означает не отсутствие реквизитов,
        # а недоступный сервер — трактовка «добавьте repository» увела бы не туда.
        if verdict != 0 and "Соединение с хранилищем конфигурации не установлено" in log_text:
            if re.match(r"^tcp://", repo["path"] or ""):
                print("[hint] сервер хранилища недоступен по адресу %s." % repo["path"])
                print("       Проверьте, запущен ли сервер хранилища и верен ли порт (по умолчанию 1542).")
            elif re.match(r"^https?://", repo["path"] or ""):
                print("[hint] хранилище недоступно по адресу %s." % repo["path"])
                print("       Проверьте веб-сервер и публикацию хранилища.")
            else:
                print("[hint] хранилище недоступно по пути %s — проверьте путь и реквизиты."
                      % repo["path"])

        # Признак — что путь задали аргументом: значит в реестре его нет (или он другой).
        if verdict == 0 and cmd in ("create", "connect") and args.RepositoryPath:
            json_path = repo["path"].replace("\\", "\\\\")
            print("")
            print("[note] допишите хранилище в запись базы в .v8-project.json (см. /db-list):")
            if args.Extension:
                print('  "extensions": [ { "name": "%s", "repository": { "path": "%s", "user": "%s", '
                      '"password": "<пароль>" } } ]' % (args.Extension, json_path, repo["user"] or ""))
            else:
                print('  "repository": { "path": "%s", "user": "%s", "password": "<пароль>" }'
                      % (json_path, repo["user"] or ""))
        print_platform_output(result)
        sys.exit(verdict)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
