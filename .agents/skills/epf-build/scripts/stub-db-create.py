#!/usr/bin/env python3
# stub-db-create v1.8 — Create temp 1C infobase with metadata stubs for EPF/ERF build
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import random
import re
import subprocess
import sys
import tempfile
import uuid


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
        print(f"Error: {param or 'path'} contains a quote character: {value}", file=sys.stderr)
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
    """
    if os.name == "nt":
        cmd = '"' + v8path + '" ' + " ".join(arguments)
    else:
        cmd = [v8path] + arguments
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
        sys.stderr.write(IBCMD_NOUSER_HINT)
        sys.stderr.flush()
    r = subprocess.run(cmd, input=b"", capture_output=True)
    r.stdout = decode_platform_bytes(r.stdout)
    r.stderr = decode_platform_bytes(r.stderr)
    return r


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
                file=sys.stderr,
            )
            sys.exit(1)
        for k in owned:
            if arg_key_match(tok, k):
                hint = f" (use {hints[k]})" if hints and k in hints else ""
                print(
                    f"Error: {k} is controlled by the skill and cannot be passed via {param}{hint}",
                    file=sys.stderr,
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
            file=sys.stderr,
        )
        sys.exit(1)
    if engine != "ibcmd" and ibcmd_extra:
        print(
            "Error: -AdditionalIbcmdArguments applies to ibcmd only; the selected engine is 1cv8 "
            "(use -AdditionalV8Arguments)",
            file=sys.stderr,
        )
        sys.exit(1)
    if engine == "ibcmd":
        extra = project_extra_args("ibcmdargs") + list(ibcmd_extra)
    else:
        extra = project_extra_args("v8args") + list(v8_extra)
    if extra:
        assert_extra_args(extra, engine, hints)
    return extra


def new_uuid():
    return str(uuid.uuid4())


def scan_ref_types(source_dir):
    """Scan XML files for reference/object/recordset types. Returns {metaType: {name: True}}."""
    type_map = {}

    ref_pattern = re.compile(
        r'(?:cfg:|d\dp1:)(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef'
        r'|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef'
        r'|ExchangePlanRef|BusinessProcessRef|TaskRef)'
        r'\.([A-Za-z\u0400-\u04FF\d_]+)'
    )
    obj_pattern = re.compile(
        r'(?:cfg:|d\dp1:)(CatalogObject|DocumentObject|ChartOfAccountsObject'
        r'|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesObject'
        r'|ExchangePlanObject|BusinessProcessObject|TaskObject)'
        r'\.([A-Za-z\u0400-\u04FF\d_]+)'
    )
    rs_pattern = re.compile(
        r'(?:cfg:|d\dp1:)(InformationRegisterRecordSet|AccumulationRegisterRecordSet'
        r'|AccountingRegisterRecordSet|CalculationRegisterRecordSet)'
        r'\.([A-Za-z\u0400-\u04FF\d_]+)'
    )
    char_pattern = re.compile(r'cfg:Characteristic\.([A-Za-z\u0400-\u04FF\d_]+)')
    dt_pattern = re.compile(r'cfg:DefinedType\.([A-Za-z\u0400-\u04FF\d_]+)')

    ref_map = {
        'CatalogRef': 'Catalog', 'DocumentRef': 'Document', 'EnumRef': 'Enum',
        'ChartOfAccountsRef': 'ChartOfAccounts',
        'ChartOfCharacteristicTypesRef': 'ChartOfCharacteristicTypes',
        'ChartOfCalculationTypesRef': 'ChartOfCalculationTypes',
        'ExchangePlanRef': 'ExchangePlan', 'BusinessProcessRef': 'BusinessProcess', 'TaskRef': 'Task',
    }
    obj_map = {
        'CatalogObject': 'Catalog', 'DocumentObject': 'Document',
        'ChartOfAccountsObject': 'ChartOfAccounts',
        'ChartOfCharacteristicTypesObject': 'ChartOfCharacteristicTypes',
        'ChartOfCalculationTypesObject': 'ChartOfCalculationTypes',
        'ExchangePlanObject': 'ExchangePlan', 'BusinessProcessObject': 'BusinessProcess', 'TaskObject': 'Task',
    }
    rs_map = {
        'InformationRegisterRecordSet': 'InformationRegister',
        'AccumulationRegisterRecordSet': 'AccumulationRegister',
        'AccountingRegisterRecordSet': 'AccountingRegister',
        'CalculationRegisterRecordSet': 'CalculationRegister',
    }

    for dirpath, _, filenames in os.walk(source_dir):
        for fn in filenames:
            if not fn.endswith('.xml'):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, 'r', encoding='utf-8-sig') as f:
                    content = f.read()
            except Exception:
                continue

            for m in ref_pattern.finditer(content):
                mt = ref_map[m.group(1)]
                type_map.setdefault(mt, {})[m.group(2)] = True
            for m in obj_pattern.finditer(content):
                mt = obj_map[m.group(1)]
                type_map.setdefault(mt, {})[m.group(2)] = True
            for m in rs_pattern.finditer(content):
                mt = rs_map[m.group(1)]
                type_map.setdefault(mt, {})[m.group(2)] = True
            for m in char_pattern.finditer(content):
                type_map.setdefault('ChartOfCharacteristicTypes', {})[m.group(1)] = True
            for m in dt_pattern.finditer(content):
                type_map.setdefault('DefinedType', {})[m.group(1)] = True

    return type_map


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


def detect_stub_format_version(source_dir):
    """Версия формата заглушечной конфигурации.

    Заглушке нужна САМАЯ НИЗКАЯ работающая версия, а не версия исходников: ограничение платформы
    одностороннее — она читает формат не новее себя. Отсюда min(версия исходников, 2.17): на 2.17+
    заглушка остаётся 2.17 (как было), а под исходники 2.13-2.16 опускается до их версии, иначе
    конфигурация не загрузится платформой, которая эти исходники и выгрузила («Неизвестная версия
    формата 2.17 загружаемого файла», замерено на 8.3.20).

    Версию исходников берём из корня собираемого объекта (ExternalDataProcessor/ExternalReport);
    вложенные файлы — запасной вариант, если корень почему-то не попался.
    """
    root_version = ""
    any_version = ""
    ver_pattern = re.compile(r'<MetaDataObject[^>]+version="(\d+\.\d+)"')
    root_pattern = re.compile(r'<(ExternalDataProcessor|ExternalReport)[ >]')
    for dirpath, _, filenames in os.walk(source_dir):
        for fn in filenames:
            if not fn.endswith('.xml'):
                continue
            try:
                with open(os.path.join(dirpath, fn), 'r', encoding='utf-8-sig') as f:
                    content = f.read()
            except Exception:
                continue
            m = ver_pattern.search(content)
            if not m:
                continue
            if not any_version:
                any_version = m.group(1)
            if not root_version and root_pattern.search(content):
                root_version = m.group(1)
    src_version = root_version or any_version or "2.17"
    src_rank = format_rank(src_version)
    return src_version if 0 < src_rank < format_rank("2.17") else "2.17"


# Режим совместимости заглушки — по той же логике, что и версия формата. Платформа отказывается
# работать с конфигурацией, чей режим выше её самой («Для работы с конфигурацией необходима версия
# платформы не меньше, чем 8.3.24»), и тогда объекты заглушки в базу не попадают: загрузка
# рапортует успех, а сборка падает на «Неизвестное имя типа». Ступени — лестница версий формата
# из docs/1c-configuration-spec.md.
COMPAT_BY_FORMAT = {
    "2.13": "Version8_3_20",
    "2.14": "Version8_3_21",
    "2.15": "Version8_3_22",
    "2.16": "Version8_3_23",
}


def stub_compatibility_mode(format_version):
    return COMPAT_BY_FORMAT.get(format_version, "Version8_3_24")


def scan_register_columns(source_dir):
    """Scan Form.xml for register record set columns referenced via DataPath.
    Returns {"RegisterType.RegisterName": {"col1": True, "col2": True}}."""
    import xml.etree.ElementTree as ET

    register_columns = {}
    std_cols = {'LineNumber', 'Period', 'Recorder', 'Active', 'RecordType'}
    rs_type_map = {
        'InformationRegisterRecordSet': 'InformationRegister',
        'AccumulationRegisterRecordSet': 'AccumulationRegister',
        'AccountingRegisterRecordSet': 'AccountingRegister',
        'CalculationRegisterRecordSet': 'CalculationRegister',
    }
    rs_pattern = re.compile(
        r'^(?:cfg:|d\dp1:)(InformationRegisterRecordSet|AccumulationRegisterRecordSet'
        r'|AccountingRegisterRecordSet|CalculationRegisterRecordSet)\.(.+)$'
    )
    dp_pattern = re.compile(r'<DataPath>([A-Za-z\u0400-\u04FF\d_]+)\.([A-Za-z\u0400-\u04FF\d_]+)</DataPath>')

    ns = {
        'v8': 'http://v8.1c.ru/8.1/data/core',
        'f': 'http://v8.1c.ru/8.3/xcf/logform',
    }

    for dirpath, _, filenames in os.walk(source_dir):
        for fn in filenames:
            if fn != 'Form.xml':
                continue
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, 'r', encoding='utf-8-sig') as fh:
                    content = fh.read()
            except Exception:
                continue
            if '<Attributes>' not in content:
                continue

            # Parse form attributes to find register recordset types
            reg_attr_map = {}  # formAttrName -> "RegisterType.RegisterName"
            try:
                root = ET.fromstring(content)
                for attr_node in root.iter('{http://v8.1c.ru/8.3/xcf/logform}Attribute'):
                    attr_name = attr_node.get('name', '')
                    for type_node in attr_node.iter('{http://v8.1c.ru/8.1/data/core}Type'):
                        m = rs_pattern.match(type_node.text or '')
                        if m:
                            reg_type = rs_type_map[m.group(1)]
                            reg_key = f"{reg_type}.{m.group(2)}"
                            reg_attr_map[attr_name] = reg_key
                            register_columns.setdefault(reg_key, {})
            except Exception:
                continue

            # Find DataPath references like "AttrName.ColumnName"
            for m in dp_pattern.finditer(content):
                attr_name, col_name = m.group(1), m.group(2)
                if attr_name in reg_attr_map and col_name not in std_cols:
                    register_columns[reg_attr_map[attr_name]][col_name] = True

    return register_columns


NS = (
    'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
    'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" '
    'xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
    'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" '
    'xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
    'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" '
    'xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
    'xmlns:v8="http://v8.1c.ru/8.1/data/core" '
    'xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
    'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" '
    'xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
    'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" '
    'xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
    'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" '
    'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
)

CLASS_IDS = [
    "9cd510cd-abfc-11d4-9434-004095e12fc7",
    "9fcd25a0-4822-11d4-9414-008048da11f9",
    "e3687481-0a87-462c-a166-9f34594f9bba",
    "9de14907-ec23-4a07-96f0-85521cb6b53b",
    "51f2d5d8-ea4d-4064-8892-82951750031e",
    "e68182ea-4237-4383-967f-90c1e3370bc7",
    "fb282519-d103-4dd3-bc12-cb271d631dfc",
]

GT_DEFS = {
    'Catalog': [('CatalogObject','Object'),('CatalogRef','Ref'),('CatalogSelection','Selection'),('CatalogList','List'),('CatalogManager','Manager')],
    'Document': [('DocumentObject','Object'),('DocumentRef','Ref'),('DocumentSelection','Selection'),('DocumentList','List'),('DocumentManager','Manager')],
    'Enum': [('EnumRef','Ref'),('EnumManager','Manager'),('EnumList','List')],
    'ChartOfAccounts': [('ChartOfAccountsObject','Object'),('ChartOfAccountsRef','Ref'),('ChartOfAccountsSelection','Selection'),('ChartOfAccountsList','List'),('ChartOfAccountsManager','Manager')],
    'ChartOfCharacteristicTypes': [('ChartOfCharacteristicTypesObject','Object'),('ChartOfCharacteristicTypesRef','Ref'),('ChartOfCharacteristicTypesSelection','Selection'),('ChartOfCharacteristicTypesList','List'),('Characteristic','Characteristic'),('ChartOfCharacteristicTypesManager','Manager')],
    'ChartOfCalculationTypes': [('ChartOfCalculationTypesObject','Object'),('ChartOfCalculationTypesRef','Ref'),('ChartOfCalculationTypesSelection','Selection'),('ChartOfCalculationTypesList','List'),('ChartOfCalculationTypesManager','Manager')],
    'ExchangePlan': [('ExchangePlanObject','Object'),('ExchangePlanRef','Ref'),('ExchangePlanSelection','Selection'),('ExchangePlanList','List'),('ExchangePlanManager','Manager')],
    'BusinessProcess': [('BusinessProcessObject','Object'),('BusinessProcessRef','Ref'),('BusinessProcessSelection','Selection'),('BusinessProcessList','List'),('BusinessProcessManager','Manager')],
    'Task': [('TaskObject','Object'),('TaskRef','Ref'),('TaskSelection','Selection'),('TaskList','List'),('TaskManager','Manager')],
    'InformationRegister': [('InformationRegisterRecord','Record'),('InformationRegisterManager','Manager'),('InformationRegisterSelection','Selection'),('InformationRegisterList','List'),('InformationRegisterRecordSet','RecordSet'),('InformationRegisterRecordKey','RecordKey'),('InformationRegisterRecordManager','RecordManager')],
    'AccumulationRegister': [('AccumulationRegisterRecord','Record'),('AccumulationRegisterManager','Manager'),('AccumulationRegisterSelection','Selection'),('AccumulationRegisterList','List'),('AccumulationRegisterRecordSet','RecordSet'),('AccumulationRegisterRecordKey','RecordKey')],
    'AccountingRegister': [('AccountingRegisterRecord','Record'),('AccountingRegisterManager','Manager'),('AccountingRegisterSelection','Selection'),('AccountingRegisterExtDimensions','ExtDimensions'),('AccountingRegisterList','List'),('AccountingRegisterRecordSet','RecordSet'),('AccountingRegisterRecordKey','RecordKey')],
    'CalculationRegister': [('CalculationRegisterRecord','Record'),('CalculationRegisterManager','Manager'),('CalculationRegisterSelection','Selection'),('CalculationRegisterList','List'),('CalculationRegisterRecordSet','RecordSet'),('CalculationRegisterRecordKey','RecordKey')],
    'DefinedType': [('DefinedType','DefinedType')],
}

META_INFO = {
    'Catalog': ('Catalog', 'Catalogs'),
    'Document': ('Document', 'Documents'),
    'Enum': ('Enum', 'Enums'),
    'ChartOfAccounts': ('ChartOfAccounts', 'ChartsOfAccounts'),
    'ChartOfCharacteristicTypes': ('ChartOfCharacteristicTypes', 'ChartsOfCharacteristicTypes'),
    'ChartOfCalculationTypes': ('ChartOfCalculationTypes', 'ChartsOfCalculationTypes'),
    'ExchangePlan': ('ExchangePlan', 'ExchangePlans'),
    'BusinessProcess': ('BusinessProcess', 'BusinessProcesses'),
    'Task': ('Task', 'Tasks'),
    'InformationRegister': ('InformationRegister', 'InformationRegisters'),
    'AccumulationRegister': ('AccumulationRegister', 'AccumulationRegisters'),
    'AccountingRegister': ('AccountingRegister', 'AccountingRegisters'),
    'CalculationRegister': ('CalculationRegister', 'CalculationRegisters'),
    'DefinedType': ('DefinedType', 'DefinedTypes'),
}

STD_ATTRS_BY_TYPE = {
    'Catalog': ['PredefinedDataName','Predefined','Ref','DeletionMark','IsFolder','Owner','Parent','Description','Code'],
    'Document': ['Posted','Ref','DeletionMark','Date','Number'],
    'Enum': ['Order','Ref'],
    'ChartOfAccounts': ['PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','Parent','Order','Type','OffBalance'],
    'ChartOfCharacteristicTypes': ['PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','Parent','ValueType'],
    'ChartOfCalculationTypes': ['PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','ActionPeriodIsBasic'],
    'ExchangePlan': ['Ref','DeletionMark','Code','Description','ThisNode','SentNo','ReceivedNo'],
    'BusinessProcess': ['Ref','DeletionMark','Date','Number','Started','Completed','HeadTask'],
    'Task': ['Ref','DeletionMark','Date','Number','Executed','Description','RoutePoint','BusinessProcess'],
    'InformationRegister': ['Active','LineNumber','Recorder','Period'],
    'AccumulationRegister': ['Active','LineNumber','Recorder','Period'],
    'AccountingRegister': ['Active','Period','Recorder','LineNumber','Account'],
    'CalculationRegister': ['Active','Recorder','LineNumber','RegistrationPeriod','CalculationType','ReversingEntry'],
}

STD_ATTR_BODY = """\t\t\t\t<xr:LinkByType/>
\t\t\t\t<xr:FillChecking>DontCheck</xr:FillChecking>
\t\t\t\t<xr:MultiLine>false</xr:MultiLine>
\t\t\t\t<xr:FillFromFillingValue>false</xr:FillFromFillingValue>
\t\t\t\t<xr:CreateOnInput>Auto</xr:CreateOnInput>
\t\t\t\t<xr:MaxValue xsi:nil="true"/>
\t\t\t\t<xr:ToolTip/>
\t\t\t\t<xr:ExtendedEdit>false</xr:ExtendedEdit>
\t\t\t\t<xr:Format/>
\t\t\t\t<xr:ChoiceForm/>
\t\t\t\t<xr:QuickChoice>Auto</xr:QuickChoice>
\t\t\t\t<xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>
\t\t\t\t<xr:EditFormat/>
\t\t\t\t<xr:PasswordMode>false</xr:PasswordMode>
\t\t\t\t<xr:DataHistory>Use</xr:DataHistory>
\t\t\t\t<xr:MarkNegatives>false</xr:MarkNegatives>
\t\t\t\t<xr:MinValue xsi:nil="true"/>
\t\t\t\t<xr:Synonym/>
\t\t\t\t<xr:Comment/>
\t\t\t\t<xr:FullTextSearch>Use</xr:FullTextSearch>
\t\t\t\t<xr:ChoiceParameterLinks/>
\t\t\t\t<xr:FillValue xsi:nil="true"/>
\t\t\t\t<xr:Mask/>
\t\t\t\t<xr:ChoiceParameters/>"""


def build_std_attrs(meta_type):
    attrs = STD_ATTRS_BY_TYPE.get(meta_type)
    if not attrs:
        return ''
    lines = ['\t\t\t<StandardAttributes>']
    for a in attrs:
        lines.append(f'\t\t\t\t<xr:StandardAttribute name="{a}">')
        lines.append(STD_ATTR_BODY)
        lines.append(f'\t\t\t\t</xr:StandardAttribute>')
    lines.append('\t\t\t</StandardAttributes>')
    return '\n'.join(lines) + '\n'


def build_internal_info(meta_type, obj_name):
    gts = GT_DEFS.get(meta_type)
    if not gts:
        return ''
    lines = ['\t\t<InternalInfo>']
    if meta_type == 'ExchangePlan':
        lines.append(f'\t\t\t<xr:ThisNode>{new_uuid()}</xr:ThisNode>')
    for prefix, cat in gts:
        full = f'{prefix}.{obj_name}'
        lines.append(f'\t\t\t<xr:GeneratedType name="{full}" category="{cat}">')
        lines.append(f'\t\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
        lines.append(f'\t\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
        lines.append(f'\t\t\t</xr:GeneratedType>')
    lines.append('\t\t</InternalInfo>')
    return '\n'.join(lines)


# Properties templates per type — returns the Properties content (without <Properties> tags)
PROPS = {}

PROPS['Catalog'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<Hierarchical>false</Hierarchical>
\t\t\t<HierarchyType>HierarchyFoldersAndItems</HierarchyType>
\t\t\t<LimitLevelCount>false</LimitLevelCount>
\t\t\t<LevelCount>2</LevelCount>
\t\t\t<FoldersOnTop>true</FoldersOnTop>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Owners/>
\t\t\t<SubordinationUse>ToItems</SubordinationUse>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CodeType>String</CodeType>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
\t\t\t<CodeSeries>WholeCatalog</CodeSeries>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultFolderForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<DefaultFolderChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryFolderForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<AuxiliaryFolderChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['Enum'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
{sa}\t\t\t<Characteristics/>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"""

PROPS['InformationRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<DefaultRecordForm/>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryRecordForm/>
\t\t\t<AuxiliaryListForm/>
{sa}\t\t\t<InformationRegisterPeriodicity>Nonperiodical</InformationRegisterPeriodicity>
\t\t\t<WriteMode>Independent</WriteMode>
\t\t\t<MainFilterOnPeriod>false</MainFilterOnPeriod>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<EnableTotalsSliceFirst>false</EnableTotalsSliceFirst>
\t\t\t<EnableTotalsSliceLast>false</EnableTotalsSliceLast>
\t\t\t<RecordPresentation/>
\t\t\t<ExtendedRecordPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['AccumulationRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<RegisterType>Balance</RegisterType>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
{sa}\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<EnableTotalsSplitting>true</EnableTotalsSplitting>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>"""

PROPS['AccountingRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<ChartOfAccounts/>
\t\t\t<Correspondence>false</Correspondence>
{sa}\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<EnableTotalsSplitting>true</EnableTotalsSplitting>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>"""

PROPS['CalculationRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<ChartOfCalculationTypes/>
{sa}\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>"""

PROPS['ChartOfAccounts'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeMask/>
\t\t\t<CodeLength>20</CodeLength>
\t\t\t<DescriptionLength>100</DescriptionLength>
\t\t\t<CodeSeries>WholeCatalog</CodeSeries>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<DefaultFolderForm/>
\t\t\t<DefaultFolderChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<AuxiliaryFolderForm/>
\t\t\t<AuxiliaryFolderChoiceForm/>
\t\t\t<AutoOrderByCode>true</AutoOrderByCode>
\t\t\t<OrderLength>5</OrderLength>
\t\t\t<MaxExtDimensionCount>0</MaxExtDimensionCount>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['ChartOfCharacteristicTypes'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
\t\t\t<CharacteristicExtValues/>
\t\t\t<Type>
\t\t\t\t<v8:Type>xs:boolean</v8:Type>
\t\t\t\t<v8:Type>xs:string</v8:Type>
\t\t\t\t<v8:StringQualifiers>
\t\t\t\t\t<v8:Length>0</v8:Length>
\t\t\t\t\t<v8:AllowedLength>Variable</v8:AllowedLength>
\t\t\t\t</v8:StringQualifiers>
\t\t\t\t<v8:Type>xs:decimal</v8:Type>
\t\t\t\t<v8:NumberQualifiers>
\t\t\t\t\t<v8:Digits>15</v8:Digits>
\t\t\t\t\t<v8:FractionDigits>2</v8:FractionDigits>
\t\t\t\t\t<v8:AllowedSign>Any</v8:AllowedSign>
\t\t\t\t</v8:NumberQualifiers>
\t\t\t\t<v8:Type>xs:dateTime</v8:Type>
\t\t\t\t<v8:DateQualifiers>
\t\t\t\t\t<v8:DateFractions>DateTime</v8:DateFractions>
\t\t\t\t</v8:DateQualifiers>
\t\t\t</Type>
\t\t\t<Hierarchical>false</Hierarchical>
\t\t\t<FoldersOnTop>true</FoldersOnTop>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultFolderForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<DefaultFolderChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryFolderForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<AuxiliaryFolderChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['ChartOfCalculationTypes'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CodeType>String</CodeType>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
\t\t\t<CodeSeries>WholeCatalog</CodeSeries>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DependenceOnCalculationTypes>NotDepend</DependenceOnCalculationTypes>
\t\t\t<BaseCalculationTypes/>
\t\t\t<ActionPeriodUse>false</ActionPeriodUse>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['ExchangePlan'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
{sa}\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DistributedInfoBase>false</DistributedInfoBase>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['BusinessProcess'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Numerator/>
\t\t\t<NumberType>String</NumberType>
\t\t\t<NumberLength>11</NumberLength>
\t\t\t<NumberAllowedLength>Variable</NumberAllowedLength>
\t\t\t<NumberPeriodicity>Year</NumberPeriodicity>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
{sa}\t\t\t<Characteristics/>
\t\t\t<Task/>
\t\t\t<CreateTaskInPrivilegedMode>false</CreateTaskInPrivilegedMode>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['Task'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Numerator/>
\t\t\t<NumberType>String</NumberType>
\t\t\t<NumberLength>11</NumberLength>
\t\t\t<NumberAllowedLength>Variable</NumberAllowedLength>
\t\t\t<NumberPeriodicity>Year</NumberPeriodicity>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DescriptionLength>25</DescriptionLength>
{sa}\t\t\t<Characteristics/>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<Addressing/>
\t\t\t<MainAddressingAttribute/>
\t\t\t<CurrentUserAlias/>
\t\t\t<CurrentUserValue/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['DefinedType'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<Type>
\t\t\t\t<v8:Type>xs:string</v8:Type>
\t\t\t\t<v8:StringQualifiers>
\t\t\t\t\t<v8:Length>0</v8:Length>
\t\t\t\t\t<v8:AllowedLength>Variable</v8:AllowedLength>
\t\t\t\t</v8:StringQualifiers>
\t\t\t</Type>"""


def build_doc_props(obj_name, std_attrs, reg_records_xml):
    return f"""\t\t\t<Name>{obj_name}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Numerator/>
\t\t\t<NumberType>String</NumberType>
\t\t\t<NumberLength>11</NumberLength>
\t\t\t<NumberAllowedLength>Variable</NumberAllowedLength>
\t\t\t<NumberPeriodicity>Year</NumberPeriodicity>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
{std_attrs}\t\t\t<Characteristics/>
\t\t\t<BasedOn/>
\t\t\t<InputByString/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<Posting>Allow</Posting>
\t\t\t<RealTimePosting>Deny</RealTimePosting>
\t\t\t<RegisterRecordsDeletion>AutoDelete</RegisterRecordsDeletion>
\t\t\t<RegisterRecordsWritingOnPost>WriteModified</RegisterRecordsWritingOnPost>
\t\t\t<SequenceFilling>AutoFill</SequenceFilling>
\t\t\t{reg_records_xml}
\t\t\t<PostInPrivilegedMode>true</PostInPrivilegedMode>
\t\t\t<UnpostInPrivilegedMode>true</UnpostInPrivilegedMode>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""


def write_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

    parser = argparse.ArgumentParser(description='Create temp 1C infobase with metadata stubs')
    parser.add_argument('-SourceDir', required=True)
    parser.add_argument('-V8Path', required=True)
    parser.add_argument('-TempBasePath', default='')
    parser.add_argument('-AdditionalV8Arguments', nargs='*', default=[],
                        help='Extra 1cv8 arguments, e.g. /UseHwLicenses+')
    parser.add_argument('-AdditionalIbcmdArguments', nargs='*', default=[],
                        help='Extra ibcmd arguments in --key=value form')
    known_opts = {s.lower() for a in parser._actions for s in a.option_strings}
    argv, v8_extra, ibcmd_extra = extract_extra_args(sys.argv[1:], known_opts)
    args = parser.parse_args(argv)

    args.SourceDir = clean_path(args.SourceDir, "-SourceDir")
    args.V8Path = clean_path(args.V8Path, "-V8Path")
    args.TempBasePath = clean_path(args.TempBasePath, "-TempBasePath")

    type_map = scan_ref_types(args.SourceDir)
    register_columns = scan_register_columns(args.SourceDir)
    has_ref_types = len(type_map) > 0
    stub_format_version = detect_stub_format_version(args.SourceDir)
    stub_compat = stub_compatibility_mode(stub_format_version)
    ns_decl = f'{NS} version="{stub_format_version}"'

    temp_base = args.TempBasePath or os.path.join(tempfile.gettempdir(), f'epf_stub_db_{random.randint(0,999999)}')

    # Add registrator stub document if needed
    registrator_types = ['AccumulationRegister', 'AccountingRegister', 'CalculationRegister']
    needs_registrator = any(rt in type_map and len(type_map[rt]) > 0 for rt in registrator_types)
    if needs_registrator:
        type_map.setdefault('Document', {})['\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430'] = True  # ЗаглушкаРегистратора

    if has_ref_types:
        cfg_dir = os.path.join(temp_base, 'cfg')
        os.makedirs(cfg_dir, exist_ok=True)

        # Configuration.xml
        uuid_cfg = new_uuid()
        uuid_lang = new_uuid()
        co_ids = [new_uuid() for _ in range(7)]

        co_xml = ''
        for i in range(7):
            co_xml += f'\n\t\t\t<xr:ContainedObject>\n\t\t\t\t<xr:ClassId>{CLASS_IDS[i]}</xr:ClassId>\n\t\t\t\t<xr:ObjectId>{co_ids[i]}</xr:ObjectId>\n\t\t\t</xr:ContainedObject>'

        child_xml = '\n\t\t\t<Language>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</Language>'  # Русский
        for meta_type, names in type_map.items():
            if meta_type not in META_INFO:
                continue
            tag = META_INFO[meta_type][0]
            for name in names:
                child_xml += f'\n\t\t\t<{tag}>{name}</{tag}>'

        cfg_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {ns_decl}>
\t<Configuration uuid="{uuid_cfg}">
\t\t<InternalInfo>{co_xml}
\t\t</InternalInfo>
\t\t<Properties>
\t\t\t<Name>StubConfig</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<NamePrefix/>
\t\t\t<ConfigurationExtensionCompatibilityMode>{stub_compat}</ConfigurationExtensionCompatibilityMode>
\t\t\t<DefaultRunMode>ManagedApplication</DefaultRunMode>
\t\t\t<UsePurposes>
\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
\t\t\t</UsePurposes>
\t\t\t<ScriptVariant>Russian</ScriptVariant>
\t\t\t<DefaultRoles/>
\t\t\t<Vendor/>
\t\t\t<Version/>
\t\t\t<UpdateCatalogAddress/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<UseManagedFormInOrdinaryApplication>false</UseManagedFormInOrdinaryApplication>
\t\t\t<UseOrdinaryFormInManagedApplication>false</UseOrdinaryFormInManagedApplication>
\t\t\t<AdditionalFullTextSearchDictionaries/>
\t\t\t<CommonSettingsStorage/>
\t\t\t<ReportsUserSettingsStorage/>
\t\t\t<ReportsVariantsStorage/>
\t\t\t<FormDataSettingsStorage/>
\t\t\t<DynamicListsUserSettingsStorage/>
\t\t\t<URLExternalDataStorage/>
\t\t\t<Content/>
\t\t\t<DefaultReportForm/>
\t\t\t<DefaultReportVariantForm/>
\t\t\t<DefaultReportSettingsForm/>
\t\t\t<DefaultReportAppearanceTemplate/>
\t\t\t<DefaultDynamicListSettingsForm/>
\t\t\t<DefaultSearchForm/>
\t\t\t<DefaultDataHistoryChangeHistoryForm/>
\t\t\t<DefaultDataHistoryVersionDataForm/>
\t\t\t<DefaultDataHistoryVersionDifferencesForm/>
\t\t\t<DefaultCollaborationSystemUsersChoiceForm/>
\t\t\t<RequiredMobileApplicationPermissions/>
\t\t\t<UsedMobileApplicationFunctionalities/>
\t\t\t<StandaloneConfigurationRestrictionRoles/>
\t\t\t<MobileApplicationURLs/>
\t\t\t<AllowedIncomingShareRequestTypes/>
\t\t\t<MainClientApplicationWindowMode>Normal</MainClientApplicationWindowMode>
\t\t\t<DefaultInterface/>
\t\t\t<DefaultStyle/>
\t\t\t<DefaultLanguage>Language.\u0420\u0443\u0441\u0441\u043a\u0438\u0439</DefaultLanguage>
\t\t\t<BriefInformation/>
\t\t\t<DetailedInformation/>
\t\t\t<Copyright/>
\t\t\t<VendorInformationAddress/>
\t\t\t<ConfigurationInformationAddress/>
\t\t\t<DataLockControlMode>Managed</DataLockControlMode>
\t\t\t<ObjectAutonumerationMode>NotAutoFree</ObjectAutonumerationMode>
\t\t\t<ModalityUseMode>DontUse</ModalityUseMode>
\t\t\t<SynchronousPlatformExtensionAndAddInCallUseMode>DontUse</SynchronousPlatformExtensionAndAddInCallUseMode>
\t\t\t<InterfaceCompatibilityMode>Taxi</InterfaceCompatibilityMode>
\t\t\t<DatabaseTablespacesUseMode>DontUse</DatabaseTablespacesUseMode>
\t\t\t<CompatibilityMode>{stub_compat}</CompatibilityMode>
\t\t\t<DefaultConstantsForm/>
\t\t</Properties>
\t\t<ChildObjects>{child_xml}
\t\t</ChildObjects>
\t</Configuration>
</MetaDataObject>
"""
        write_bom(os.path.join(cfg_dir, 'Configuration.xml'), cfg_xml)

        # Language
        lang_dir = os.path.join(cfg_dir, 'Languages')
        os.makedirs(lang_dir, exist_ok=True)
        lang_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {ns_decl}>
\t<Language uuid="{uuid_lang}">
\t\t<Properties>
\t\t\t<Name>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<LanguageCode>ru</LanguageCode>
\t\t</Properties>
\t</Language>
</MetaDataObject>
"""
        write_bom(os.path.join(lang_dir, '\u0420\u0443\u0441\u0441\u043a\u0438\u0439.xml'), lang_xml)

        # Metadata stubs
        for meta_type, names in type_map.items():
            if meta_type not in META_INFO:
                continue
            tag, dirname = META_INFO[meta_type]
            obj_dir = os.path.join(cfg_dir, dirname)
            os.makedirs(obj_dir, exist_ok=True)

            for obj_name in names:
                obj_uuid = new_uuid()
                internal_xml = build_internal_info(meta_type, obj_name)
                if internal_xml:
                    internal_xml = '\n' + internal_xml

                sa = build_std_attrs(meta_type)

                if meta_type == 'Document':
                    rr_xml = '<RegisterRecords/>'
                    if obj_name == '\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430':  # ЗаглушкаРегистратора
                        rr_lines = []
                        for rt in registrator_types:
                            if rt in type_map:
                                for rn in type_map[rt]:
                                    rr_lines.append(f'\t\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{rt}.{rn}</xr:Item>')
                        if rr_lines:
                            rr_xml = '<RegisterRecords>\n' + '\n'.join(rr_lines) + '\n\t\t\t</RegisterRecords>'
                    props_xml = build_doc_props(obj_name, sa, rr_xml)
                elif meta_type in PROPS:
                    props_xml = PROPS[meta_type](obj_name, sa)
                else:
                    props_xml = f'\t\t\t<Name>{obj_name}</Name>\n\t\t\t<Synonym/>\n\t\t\t<Comment/>'

                # ChildObjects — varies by type
                if meta_type == 'DefinedType':
                    child_obj_xml = ''
                elif meta_type == 'InformationRegister':
                    reg_key = f'InformationRegister.{obj_name}'
                    cols = list(register_columns.get(reg_key, {}).keys()) or ['\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430']
                    parts = []
                    for i, col in enumerate(cols):
                        u = new_uuid()
                        if i == 0:
                            parts.append(f"""\t\t\t<Dimension uuid="{u}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>{col}</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:string</v8:Type><v8:StringQualifiers><v8:Length>10</v8:Length><v8:AllowedLength>Variable</v8:AllowedLength></v8:StringQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/>
\t\t\t\t\t<FillFromFillingValue>false</FillFromFillingValue><FillValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<Master>false</Master><MainFilter>true</MainFilter><DenyIncompleteValues>false</DenyIncompleteValues>
\t\t\t\t\t<Indexing>DontIndex</Indexing><FullTextSearch>Use</FullTextSearch><DataHistory>Use</DataHistory>
\t\t\t\t</Properties>
\t\t\t</Dimension>""")
                        else:
                            parts.append(f"""\t\t\t<Attribute uuid="{u}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>{col}</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:string</v8:Type><v8:StringQualifiers><v8:Length>10</v8:Length><v8:AllowedLength>Variable</v8:AllowedLength></v8:StringQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/>
\t\t\t\t\t<FillFromFillingValue>false</FillFromFillingValue><FillValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<Indexing>DontIndex</Indexing><FullTextSearch>Use</FullTextSearch><DataHistory>Use</DataHistory>
\t\t\t\t</Properties>
\t\t\t</Attribute>""")
                    child_obj_xml = '\n\t\t<ChildObjects>\n' + '\n'.join(parts) + '\n\t\t</ChildObjects>'
                elif meta_type in ('AccumulationRegister', 'AccountingRegister', 'CalculationRegister'):
                    reg_key = f'{meta_type}.{obj_name}'
                    cols = list(register_columns.get(reg_key, {}).keys())
                    parts = []
                    # Required stub Resource
                    parts.append(f"""\t\t\t<Resource uuid="{new_uuid()}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:decimal</v8:Type><v8:NumberQualifiers><v8:Digits>15</v8:Digits><v8:FractionDigits>2</v8:FractionDigits><v8:AllowedSign>Any</v8:AllowedSign></v8:NumberQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t\t</Properties>
\t\t\t</Resource>""")
                    # Form-referenced columns as Dimensions
                    for col in cols:
                        parts.append(f"""\t\t\t<Dimension uuid="{new_uuid()}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>{col}</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:string</v8:Type><v8:StringQualifiers><v8:Length>10</v8:Length><v8:AllowedLength>Variable</v8:AllowedLength></v8:StringQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t\t</Properties>
\t\t\t</Dimension>""")
                    child_obj_xml = '\n\t\t<ChildObjects>\n' + '\n'.join(parts) + '\n\t\t</ChildObjects>'
                else:
                    child_obj_xml = '\n\t\t<ChildObjects/>'

                obj_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {ns_decl}>
\t<{tag} uuid="{obj_uuid}">{internal_xml}
\t\t<Properties>
{props_xml}
\t\t</Properties>{child_obj_xml}
\t</{tag}>
</MetaDataObject>
"""
                write_bom(os.path.join(obj_dir, f'{obj_name}.xml'), obj_xml)

        print(f'Generated stub configuration with {len(type_map)} metadata types')
        if register_columns:
            print('WARNING: Register column categories (Dimension/Resource/Attribute) are guessed. Form field bindings may not survive round-trip through a real database.')

    # Stub via ibcmd (one call: create [--import --apply])
    stub_engine = "ibcmd" if os.path.basename(args.V8Path).lower().startswith("ibcmd") else "1cv8"

    # --- Resolve additional arguments for the selected engine ---
    arg_hints = {"/F": "-TempBasePath", "--db-path": "-TempBasePath"}
    extra_args = resolve_extra_args(stub_engine, v8_extra, ibcmd_extra, arg_hints)
    if stub_engine == "ibcmd":
        import shutil
        print(f'Creating infobase (ibcmd): {temp_base}')
        ib_data = tempfile.mkdtemp(prefix="stub_data_")
        ib_args = [args.V8Path, 'infobase', 'create', f'--db-path={temp_base}', '--create-database']
        if has_ref_types:
            ib_args += [f'--import={os.path.join(temp_base, "cfg")}', '--apply', '--force']
        ib_args.append(f'--data={ib_data}')
        ib_args.extend(extra_args)
        result = run_ibcmd(ib_args, warn_no_user=False)
        shutil.rmtree(ib_data, ignore_errors=True)
        if result.returncode != 0:
            if result.stdout:
                print(result.stdout)
            if result.stderr:
                print(result.stderr, file=sys.stderr)
            print(f'Failed to create stub infobase (code: {result.returncode})', file=sys.stderr)
            sys.exit(1)
        if has_ref_types:
            import shutil
            shutil.rmtree(os.path.join(temp_base, 'cfg'), ignore_errors=True)
        print(f'[OK] Stub database created: {temp_base}')
        print(temp_base)
        sys.exit(0)

    # Create infobase
    print(f'Creating infobase: {temp_base}')
    result = run_v8(args.V8Path, ['CREATEINFOBASE', f'File="{temp_base}"', '/DisableStartupDialogs']
                    + [quote_if_needed(a) for a in extra_args])
    if result.returncode != 0:
        print_platform_output(result)
        print(f'Failed to create infobase (code: {result.returncode})', file=sys.stderr)
        sys.exit(1)

    if has_ref_types:
        cfg_dir = os.path.join(temp_base, 'cfg')
        # LoadConfigFromFiles
        print('Loading configuration from files...')
        result = run_v8(args.V8Path, ['DESIGNER', f'/F"{temp_base}"', '/LoadConfigFromFiles', f'"{cfg_dir}"',
                                      '/DisableStartupDialogs'] + [quote_if_needed(a) for a in extra_args])
        if result.returncode != 0:
            print_platform_output(result)
            print(f'Failed to load config (code: {result.returncode})', file=sys.stderr)
            sys.exit(1)

        # UpdateDBCfg
        print('Updating database configuration...')
        update_log = os.path.join(tempfile.gettempdir(), 'stub_update_log.txt')
        result = run_v8(args.V8Path, ['DESIGNER', f'/F"{temp_base}"', '/UpdateDBCfg', '/Out', f'"{update_log}"',
                                      '/DisableStartupDialogs'] + [quote_if_needed(a) for a in extra_args])
        if result.returncode != 0:
            if os.path.isfile(update_log):
                try:
                    with open(update_log, 'r', encoding='utf-8-sig') as f:
                        print(f.read())
                except Exception:
                    pass
            print_platform_output(result)
            print(f'Failed to update DB config (code: {result.returncode})', file=sys.stderr)
            sys.exit(1)

        # Cleanup cfg dir
        import shutil
        shutil.rmtree(cfg_dir, ignore_errors=True)

    print(f'[OK] Stub database created: {temp_base}')
    print(temp_base)


if __name__ == '__main__':
    main()
