#!/usr/bin/env python3
# cfe-diff v2.2 — Analyze 1C configuration extension (CFE): borrowed objects, interceptors, own members, form changes
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys
from lxml import etree

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


MD_NS = "http://v8.1c.ru/8.3/MDClasses"
MD_NSMAP = {"md": MD_NS, "v8": "http://v8.1c.ru/8.1/data/core", "xr": "http://v8.1c.ru/8.3/xcf/readable"}

# Detail budget: below it the whole report (summaries + details) is printed in one go;
# above it only summaries, and -Name opens the details of chosen objects.
DETAIL_BUDGET = 80

# --- Type -> directory mapping ---

CHILD_TYPE_DIR_MAP = {
    "Catalog": "Catalogs",
    "Document": "Documents",
    "Enum": "Enums",
    "CommonModule": "CommonModules",
    "CommonPicture": "CommonPictures",
    "CommonCommand": "CommonCommands",
    "CommonTemplate": "CommonTemplates",
    "ExchangePlan": "ExchangePlans",
    "Report": "Reports",
    "DataProcessor": "DataProcessors",
    "InformationRegister": "InformationRegisters",
    "AccumulationRegister": "AccumulationRegisters",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfAccounts": "ChartsOfAccounts",
    "AccountingRegister": "AccountingRegisters",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes",
    "CalculationRegister": "CalculationRegisters",
    "BusinessProcess": "BusinessProcesses",
    "Task": "Tasks",
    "Subsystem": "Subsystems",
    "Role": "Roles",
    "Constant": "Constants",
    "FunctionalOption": "FunctionalOptions",
    "DefinedType": "DefinedTypes",
    "FunctionalOptionsParameter": "FunctionalOptionsParameters",
    "CommonForm": "CommonForms",
    "DocumentJournal": "DocumentJournals",
    "SessionParameter": "SessionParameters",
    "StyleItem": "StyleItems",
    "EventSubscription": "EventSubscriptions",
    "ScheduledJob": "ScheduledJobs",
    "SettingsStorage": "SettingsStorages",
    "FilterCriterion": "FilterCriteria",
    "CommandGroup": "CommandGroups",
    "DocumentNumerator": "DocumentNumerators",
    "Sequence": "Sequences",
    "ExternalDataSource": "ExternalDataSources",
    "IntegrationService": "IntegrationServices",
    "CommonAttribute": "CommonAttributes",
    "Style": "Styles",
    "XDTOPackage": "XDTOPackages",
    "WebService": "WebServices",
    "HTTPService": "HTTPServices",
    "WSReference": "WSReferences",
    "Bot": "Bots",
    "PaletteColor": "PaletteColors",
}

# ============================================================
# BSL helpers — verbatim copies from cfe-patch-method (kept identical by check-inline-drift)
# ============================================================

# Built-in language keywords in both spellings. The platform accepts either one in any module
# (pairs taken from the platform string tables), so a module written in English is ordinary
# source, not a broken one: we must read both and emit the spelling we read.
def bsl_keywords():
    return {
        "ru": {
            "Async": "Асинх", "Proc": "Процедура", "EndProc": "КонецПроцедуры",
            "Func": "Функция", "EndFunc": "КонецФункции", "Val": "Знач",
            "Region": "Область", "EndRegion": "КонецОбласти",
            "If": "Если", "Then": "Тогда", "ElsIf": "ИначеЕсли", "Else": "Иначе", "EndIf": "КонецЕсли",
            # Platform spells the negation "Не"; we emit "НЕ" as this skill always has —
            # the language is case-insensitive, and the lower case would churn every snapshot.
            "And": "И", "Or": "Или", "Not": "НЕ",
            "Insert": "Вставка", "EndInsert": "КонецВставки", "Delete": "Удаление", "EndDelete": "КонецУдаления",
            "Before": "Перед", "After": "После", "Around": "Вместо", "Control": "ИзменениеИКонтроль",
            "Proceed": "ПродолжитьВызов", "Return": "Возврат",
            # Not a keyword: name of the local the generated Instead-stub declares. Lives here so
            # that the language of emitted text is decided in exactly one place.
            "ResultVar": "Результат",
            "Directives": ["НаКлиенте", "НаСервере", "НаСервереБезКонтекста", "НаКлиентеНаСервереБезКонтекста", "НаКлиентеНаСервере"],
        },
        "en": {
            "Async": "Async", "Proc": "Procedure", "EndProc": "EndProcedure",
            "Func": "Function", "EndFunc": "EndFunction", "Val": "Val",
            "Region": "Region", "EndRegion": "EndRegion",
            "If": "If", "Then": "Then", "ElsIf": "ElsIf", "Else": "Else", "EndIf": "EndIf",
            "And": "And", "Or": "Or", "Not": "Not",
            "Insert": "Insert", "EndInsert": "EndInsert", "Delete": "Delete", "EndDelete": "EndDelete",
            "Before": "Before", "After": "After", "Around": "Around", "Control": "ChangeAndValidate",
            "Proceed": "ProceedWithCall", "Return": "Return",
            "ResultVar": "Result",
            "Directives": ["AtClient", "AtServer", "AtServerNoContext", "AtClientAtServerNoContext", "AtClientAtServer"],
        },
    }


BSL_KW = bsl_keywords()


# Regex alternation for a keyword in both spellings
def kw_alt(key):
    return '(?:' + BSL_KW["ru"][key] + '|' + BSL_KW["en"][key] + ')'


# Parse interceptor annotations present in a module. Type is normalized to the Russian spelling
# so everything downstream stays single-language; raw keeps what the file actually says.
def get_interceptors(lines):
    kw = BSL_KW
    keys = ("Before", "After", "Control", "Around")
    alt = []
    norm = {}
    for k in keys:
        alt.append(kw["ru"][k])
        alt.append(kw["en"][k])
        norm[kw["ru"][k].lower()] = kw["ru"][k]
        norm[kw["en"][k].lower()] = kw["ru"][k]
    pat = re.compile(r'^&(' + '|'.join(alt) + r')\("([^"]+)"\)', re.IGNORECASE)
    result = []
    for i in range(len(lines)):
        m = pat.match(lines[i].strip())
        if m:
            raw = m.group(1)
            result.append({"type": norm[raw.lower()], "raw": raw, "method": m.group(2), "line": i})
    return result


# ============================================================
# Form notation — verbatim copies from form-info (kept identical by check-inline-drift)
# ============================================================

NSMAP = {
    "d": "http://v8.1c.ru/8.3/xcf/logform",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "v8ui": "http://v8.1c.ru/8.1/data/ui",
    "xr": "http://v8.1c.ru/8.3/xcf/readable",
    "xs": "http://www.w3.org/2001/XMLSchema",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "cfg": "http://v8.1c.ru/8.1/data/enterprise/current-config",
    "dcsset": "http://v8.1c.ru/8.1/data-composition-system/settings",
    "dcscor": "http://v8.1c.ru/8.1/data-composition-system/core",
}

# --- Skip elements ---

SKIP_ELEMENTS = {
    "ExtendedTooltip",
    "ContextMenu",
    "AutoCommandBar",
    "SearchStringAddition",
    "ViewStatusAddition",
    "SearchControlAddition",
}


# --- Helper: extract multilang text ---


def format_type(type_node):
    if type_node is None or len(type_node) == 0:
        return ""

    type_set = type_node.find("v8:TypeSet", NSMAP)
    if type_set is not None:
        val = type_set.text or ""
        if val.startswith("cfg:"):
            val = val[4:]
        return val

    types = type_node.findall("v8:Type", NSMAP)
    if len(types) == 0:
        return ""

    parts = []
    for t in types:
        raw = t.text or ""
        if raw == "xs:string":
            sq = type_node.find("v8:StringQualifiers/v8:Length", NSMAP)
            al = type_node.find("v8:StringQualifiers/v8:AllowedLength", NSMAP)
            length = int(sq.text) if sq is not None and sq.text else 0
            if al is not None and al.text == "Fixed":
                parts.append(f"string({length},fixed)")
            elif length > 0:
                parts.append(f"string({length})")
            else:
                parts.append("string")
        elif raw == "xs:decimal":
            nq = type_node.find("v8:NumberQualifiers", NSMAP)
            if nq is not None:
                d = nq.find("v8:Digits", NSMAP)
                f = nq.find("v8:FractionDigits", NSMAP)
                s = nq.find("v8:AllowedSign", NSMAP)
                digits = d.text if d is not None and d.text else "0"
                frac = f.text if f is not None and f.text else "0"
                if s is not None and s.text == "Nonnegative":
                    parts.append(f"decimal({digits},{frac},nonneg)")
                else:
                    parts.append(f"decimal({digits},{frac})")
            else:
                # Без квалификаторов платформа читает число как 0,0; голое decimal значило бы 10,0
                parts.append("decimal(0,0)")
        elif raw == "xs:boolean":
            parts.append("boolean")
        elif raw == "xs:dateTime":
            dq = type_node.find("v8:DateQualifiers/v8:DateFractions", NSMAP)
            if dq is not None:
                frac_text = dq.text or ""
                if frac_text == "Date":
                    parts.append("date")
                elif frac_text == "Time":
                    parts.append("time")
                else:
                    parts.append("dateTime")
            else:
                parts.append("dateTime")
        elif raw == "xs:binary":
            parts.append("binary")
        elif raw.startswith("cfg:") or re.match(r'^d\d+p\d+:', raw):
            parts.append(re.sub(r'^(?:cfg|d\d+p\d+):', '', raw))
        elif raw == "v8:ValueTable":
            parts.append("ValueTable")
        elif raw == "v8:ValueTree":
            parts.append("ValueTree")
        elif raw == "v8:ValueListType":
            parts.append("ValueList")
        elif raw == "v8:TypeDescription":
            parts.append("TypeDescription")
        elif raw == "v8:Universal":
            parts.append("Universal")
        elif raw == "v8:FixedArray":
            parts.append("FixedArray")
        elif raw == "v8:FixedStructure":
            parts.append("FixedStructure")
        elif raw == "v8ui:FormattedString":
            parts.append("FormattedString")
        elif raw == "v8ui:Picture":
            parts.append("Picture")
        elif raw == "v8ui:Color":
            parts.append("Color")
        elif raw == "v8ui:Font":
            parts.append("Font")
        elif raw.startswith("dcsset:"):
            parts.append(raw.replace("dcsset:", "DCS."))
        elif raw.startswith("dcssch:"):
            parts.append(raw.replace("dcssch:", "DCS."))
        elif raw.startswith("dcscor:"):
            parts.append(raw.replace("dcscor:", "DCS."))
        else:
            parts.append(raw)

    return " | ".join(parts)


def get_element_tag(node):
    local_name = etree.QName(node.tag).localname
    if local_name == "UsualGroup":
        group_node = node.find("d:Group", NSMAP)
        orient = ""
        if group_node is not None:
            g_text = group_node.text or ""
            if g_text == "Vertical":
                orient = ":V"
            elif g_text == "Horizontal":
                orient = ":H"
            elif g_text == "AlwaysHorizontal":
                orient = ":AH"
            elif g_text == "AlwaysVertical":
                orient = ":AV"
        beh = node.find("d:Behavior", NSMAP)
        collapse = ""
        if beh is not None and beh.text == "Collapsible":
            collapse = ",collapse"
        return f"[Group{orient}{collapse}]"
    elif local_name == "InputField":
        return "[Input]"
    elif local_name == "CheckBoxField":
        return "[Check]"
    elif local_name == "LabelDecoration":
        return "[Label]"
    elif local_name == "LabelField":
        return "[LabelField]"
    elif local_name == "PictureDecoration":
        return "[Picture]"
    elif local_name == "PictureField":
        return "[PicField]"
    elif local_name == "CalendarField":
        return "[Calendar]"
    elif local_name == "Table":
        return "[Table]"
    elif local_name == "Button":
        return "[Button]"
    elif local_name == "CommandBar":
        return "[CmdBar]"
    elif local_name == "Pages":
        return "[Pages]"
    elif local_name == "Page":
        return "[Page]"
    elif local_name == "Popup":
        return "[Popup]"
    elif local_name == "ButtonGroup":
        return "[BtnGroup]"
    elif local_name == "ColumnGroup":
        return "[ColGroup]"
    elif local_name == "AutoCommandBar":
        return "[CmdBar]"
    elif local_name == "ContextMenu":
        return "[ContextMenu]"
    else:
        return f"[{local_name}]"


# ============================================================
# Common helpers
# ============================================================

def localname(el):
    return etree.QName(el).localname


def elem_children(node):
    return [c for c in node if isinstance(c.tag, str)]


def inner_text(node):
    return "".join(node.itertext())


# Drop the extension name prefix at the start of identifiers. Applied to BOTH sides of every
# comparison, so a change carried over with the prefix dropped and one carried over with the
# prefix kept compare equal alike.
def remove_ext_prefix(text, prefix):
    if not prefix or not text:
        return text
    return re.sub(r'(?<!\w)' + re.escape(prefix) + r'(?=\w)', '', text, flags=re.IGNORECASE)


def get_short(s, n=40):
    t = re.sub(r'\s+', ' ', s or "").strip()
    if len(t) > n:
        return t[:n] + "…"
    return t


def plural(n, word):
    if n == 1:
        return "1 " + word
    return "%d %ss" % (n, word)


def rel_path(root, full):
    return os.path.relpath(os.path.abspath(full), os.path.abspath(root)).replace("\\", "/")


def path_key(p):
    return os.path.normcase(os.path.abspath(p))


# Lines of a module as [System.IO.File]::ReadAllLines gives them
def read_bsl_lines(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8-sig", errors="replace", newline="") as f:
        text = f.read()
    if text == "":
        return []
    lines = re.split(r'\r\n|\r|\n', text)
    if lines and lines[-1] == "" and (text.endswith("\n") or text.endswith("\r")):
        lines.pop()
    return lines


# Declaration following an annotation (context directives and other annotations may sit between)
def find_decl_after(lines, ann_idx):
    decl_re = re.compile(r'^\s*(?:' + kw_alt("Async") + r'\s+)?(?:' + kw_alt("Proc") + '|' + kw_alt("Func") + r')\s+([\w]+)\s*\(', re.IGNORECASE)
    last = min(len(lines) - 1, ann_idx + 5)
    for j in range(ann_idx + 1, last + 1):
        t = lines[j].strip()
        m = decl_re.match(t)
        if m:
            return {"name": m.group(1), "idx": j}
        if t != "" and not t.startswith("&") and not t.startswith("//"):
            break
    return None


# ============================================================
# Metadata objects
# ============================================================

def read_xml(path):
    parser = etree.XMLParser(remove_blank_text=False)
    return etree.parse(path, parser)


def read_md_object(path):
    if not path or not os.path.isfile(path):
        return None
    root = read_xml(path).getroot()
    el = None
    for c in root:
        if isinstance(c.tag, str):
            el = c
            break
    if el is None:
        return None
    return {"el": el, "props": el.find("md:Properties", MD_NSMAP), "children": el.find("md:ChildObjects", MD_NSMAP)}


def read_configuration_props(d):
    path = os.path.join(d, "Configuration.xml")
    if not os.path.isfile(path):
        return None
    root = read_xml(path).getroot()
    props = root.find(".//md:Configuration/md:Properties", MD_NSMAP)

    def get(n):
        x = props.find("md:" + n, MD_NSMAP) if props is not None else None
        return (x.text or "") if x is not None else ""

    return {
        "dir": d,
        "name": get("Name"),
        "prefix": get("NamePrefix"),
        "purpose": get("ConfigurationExtensionPurpose"),
        "is_extension": props is not None and props.find("md:ConfigurationExtensionPurpose", MD_NSMAP) is not None,
        "child_objects": root.find(".//md:Configuration/md:ChildObjects", MD_NSMAP),
    }


def test_adopted_node(node):
    if node is None:
        return False
    props = node if localname(node) == "Properties" else node.find("md:Properties", MD_NSMAP)
    if props is None:
        return False
    ob = props.find("md:ObjectBelonging", MD_NSMAP)
    return ob is not None and ob.text == "Adopted"


def md_child_name(node):
    n = node.find("md:Properties/md:Name", MD_NSMAP)
    if n is not None:
        return n.text or ""
    return inner_text(node).strip()


def has_element_child(node):
    return any(isinstance(c.tag, str) for c in node)


def kind_word(name):
    return re.sub(r'(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ', name).lower()


# Context of one object of the extension
def get_obj_context(ext_dir, typ, name):
    if typ not in CHILD_TYPE_DIR_MAP:
        return {"known": False}
    d = CHILD_TYPE_DIR_MAP[typ]
    f = os.path.join(ext_dir, d, name + ".xml")
    md = read_md_object(f)
    return {
        "known": True, "type": typ, "name": name, "id": typ + "." + name, "dir": d,
        "obj_dir": os.path.join(ext_dir, d, name), "file": f,
        "md": md, "exists": md is not None,
        "borrowed": md is not None and test_adopted_node(md["props"]),
    }


# Forms of an object: borrowed ones carry <BaseForm>; a common form is a form itself
def get_obj_forms(ctx):
    forms = []
    if ctx["type"] == "CommonForm":
        forms.append({"label": "Form", "name": ctx["name"], "xml": os.path.join(ctx["obj_dir"], "Ext", "Form.xml"),
                      "module": os.path.join(ctx["obj_dir"], "Ext", "Form", "Module.bsl"), "own": not ctx["borrowed"], "dir": ctx["obj_dir"]})
        return forms
    if ctx["md"] is None or ctx["md"]["children"] is None:
        return forms
    for c in elem_children(ctx["md"]["children"]):
        if localname(c) != "Form":
            continue
        fn = inner_text(c).strip()
        fdir = os.path.join(ctx["obj_dir"], "Forms", fn)
        desc = read_md_object(os.path.join(ctx["obj_dir"], "Forms", fn + ".xml"))
        own = not (desc is not None and test_adopted_node(desc["props"]))
        forms.append({"label": "Form." + fn, "name": fn, "xml": os.path.join(fdir, "Ext", "Form.xml"),
                      "module": os.path.join(fdir, "Ext", "Form", "Module.bsl"), "own": own, "dir": fdir})
    return forms


# .bsl modules of a borrowed object, without those of its own forms and commands (they move as a whole)
def get_obj_modules(ctx, forms):
    if not os.path.isdir(ctx["obj_dir"]):
        return []
    skip_dirs = []
    for f in forms:
        if f["own"] and ctx["type"] != "CommonForm":
            skip_dirs.append(path_key(f["dir"]))
    if ctx["md"] is not None and ctx["md"]["children"] is not None:
        for c in elem_children(ctx["md"]["children"]):
            if localname(c) != "Command":
                continue
            if not test_adopted_node(c):
                skip_dirs.append(path_key(os.path.join(ctx["obj_dir"], "Commands", md_child_name(c))))
    found = []
    for dirpath, dirnames, filenames in os.walk(ctx["obj_dir"]):
        for fn in filenames:
            if fn.lower().endswith(".bsl"):
                found.append(os.path.join(dirpath, fn))
    res = []
    for full in sorted(found, key=lambda p: rel_path(ctx["obj_dir"], p)):
        k = path_key(full)
        if any(k.startswith(sd + os.sep) for sd in skip_dirs):
            continue
        res.append(full)
    return res


# ============================================================
# Form diff: main part of a borrowed form against its <BaseForm>
# ============================================================

def read_form_doc(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        return read_xml(path)
    except Exception:
        return None


def is_form_element(n):
    return isinstance(n.tag, str) and "name" in n.attrib and "id" in n.attrib


# Named form elements of a part (form root or BaseForm), in document order. Elements nest through
# ChildItems and through named companions (context menu, tooltip, command bar of a table).
def add_form_elements(node, parent_name, ancestors, idx):
    kids = []
    for c in node:
        if not isinstance(c.tag, str):
            continue
        if localname(c) == "ChildItems":
            for cc in c:
                if is_form_element(cc):
                    kids.append(cc)
        elif is_form_element(c):
            kids.append(c)
    names = [k.get("name") for k in kids]
    for i, k in enumerate(kids):
        nm = names[i]
        if nm.lower() in idx:
            continue
        idx[nm.lower()] = {"name": nm, "node": k, "parent": parent_name, "ancestors": ancestors,
                           "siblings": names, "pos": i, "has_kids": False}
        add_form_elements(k, nm, list(ancestors) + [nm], idx)
    if parent_name and parent_name.lower() in idx and kids:
        idx[parent_name.lower()]["has_kids"] = True


def form_element_index(part):
    idx = {}
    add_form_elements(part, "", [], idx)
    return idx


# Elements of the longest common subsequence of two name orders (case-insensitive)
def lcs_set(a, b):
    n = len(a)
    m = len(b)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            if a[i].lower() == b[j].lower():
                dp[i][j] = dp[i + 1][j + 1] + 1
            else:
                dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
    s = set()
    i = 0
    j = 0
    while i < n and j < m:
        if a[i].lower() == b[j].lower():
            s.add(a[i].lower())
            i += 1
            j += 1
        elif dp[i + 1][j] >= dp[i][j + 1]:
            i += 1
        else:
            j += 1
    return s


# Elements the extension moved: a new parent, or out of the common order among the siblings
# (one element moved must not make its neighbours look moved too)
def get_moved_set(mi, bi):
    moved = set()
    groups = {}
    for key, rec in mi.items():
        if key not in bi:
            continue
        pm = rec["parent"]
        pb = bi[key]["parent"]
        if pm.lower() != pb.lower():
            moved.add(key)
            continue
        groups.setdefault("|" + pm.lower(), []).append(rec["name"])
    for g, main_order in groups.items():
        if len(main_order) < 2:
            continue
        in_group = set(x.lower() for x in main_order)
        base_order = [r["name"] for r in bi.values() if r["name"].lower() in in_group]
        keep = lcs_set(main_order, base_order)
        for x in main_order:
            if x.lower() not in keep:
                moved.add(x.lower())
    return moved


FORM_STRUCTURAL = ("ChildItems", "Attributes", "Commands", "Parameters", "Events", "CommandInterface", "BaseForm")


# Property tags of an element (or of the form root): child elements that are not elements themselves
def get_prop_map(node, root=False):
    m = {}
    for c in node:
        if not isinstance(c.tag, str):
            continue
        ln = localname(c)
        if ln in ("ChildItems", "Events"):
            continue
        if root and ln in FORM_STRUCTURAL:
            continue
        if is_form_element(c):
            continue
        key = ln
        i = 2
        while key in m:
            key = "%s#%d" % (ln, i)
            i += 1
        m[key] = c
    return m


def _ws(s):
    return re.sub(r'\s+', ' ', s or "").strip()


# Canonical text of a node: whitespace, ids, xmlns and namespace-prefix spelling do not matter
def node_canon(n):
    if not isinstance(n.tag, str):
        return ""
    attrs = sorted("%s=%s" % (etree.QName(k).localname, v) for k, v in n.attrib.items() if etree.QName(k).localname != "id")
    kids = []
    t = _ws(n.text)
    if t:
        kids.append(t)
    for c in n:
        s = node_canon(c)
        if s:
            kids.append(s)
        tt = _ws(c.tail)
        if tt:
            kids.append(tt)
    head = (" " + " ".join(attrs)) if attrs else ""
    return "<" + localname(n) + head + ">" + "".join(kids) + "</>"


def cmp_key(node, prefix):
    if node is None:
        return None
    c = re.sub(r'(?<![\w])(?:cfg|d\d+p\d+):', '', node_canon(node))
    return remove_ext_prefix(c, prefix)


def prop_display(node):
    if node is None:
        return ""
    content = node.find("v8:item/v8:content", NSMAP)
    if content is not None:
        return '"' + get_short(inner_text(content), 40) + '"'
    if has_element_child(node):
        return "{…}"
    return get_short(inner_text(node), 40)


def event_list(node):
    res = []
    if node is None:
        return res
    for e in node.findall("d:Events/d:Event", NSMAP):
        res.append({"name": e.get("name", ""), "call_type": e.get("callType", ""), "handler": inner_text(e).strip()})
    return res


def event_key_set(events):
    return set(("%s|%s" % (e["name"], e["call_type"])).lower() for e in events)


def section_map(root, section, item):
    m = {}
    for x in root.findall("d:%s/d:%s" % (section, item), NSMAP):
        nm = x.get("name", "")
        if nm and nm.lower() not in m:
            m[nm.lower()] = (nm, x)
    return m


def get_form_diff(form_xml):
    doc = read_form_doc(form_xml)
    if doc is None:
        return None
    root = doc.getroot()
    base = root.find("d:BaseForm", NSMAP)
    r = {"is_borrowed": base is not None, "root": root, "elements": [], "removed": [], "Attributes": [], "columns": [], "Commands": [],
         "Parameters": [], "events": [], "form_props": [], "blocks": [], "appearance": [], "total": 0, "main_index": None}
    if base is None:
        return r
    mi = form_element_index(root)
    bi = form_element_index(base)
    r["main_index"] = mi
    moved_set = get_moved_set(mi, bi)
    for key, m in mi.items():
        name = m["name"]
        if key not in bi:
            # Context menu / tooltip that come with an added element carry nothing of their own
            if localname(m["node"]) in SKIP_ELEMENTS and m["parent"] and m["parent"].lower() not in bi and not m["has_kids"]:
                continue
            r["elements"].append({"kind": "added", "rec": m, "props": [], "moved": False, "old_parent": ""})
            continue
        b = bi[key]
        pm = get_prop_map(m["node"])
        pb = get_prop_map(b["node"])
        props = []
        for k in pm:
            if k not in pb:
                props.append({"key": k, "old": None, "new": pm[k]})
            elif cmp_key(pm[k], "") != cmp_key(pb[k], ""):
                props.append({"key": k, "old": pb[k], "new": pm[k]})
        for k in pb:
            if k not in pm:
                props.append({"key": k, "old": pb[k], "new": None})
        moved = key in moved_set
        if props or moved:
            r["elements"].append({"kind": "changed" if props else "moved", "rec": m, "props": props, "moved": moved, "old_parent": b["parent"]})
        base_ev = event_key_set(event_list(b["node"]))
        for e in event_list(m["node"]):
            if ("%s|%s" % (e["name"], e["call_type"])).lower() not in base_ev:
                r["events"].append({"scope": name, "name": e["name"], "call_type": e["call_type"], "handler": e["handler"]})
    for key, b in bi.items():
        if key in mi:
            continue
        # A companion comes and goes with its element
        if localname(b["node"]) in SKIP_ELEMENTS and b["parent"] and b["parent"].lower() not in mi:
            continue
        r["removed"].append(b["name"])

    # Form events
    base_ev = event_key_set(event_list(base))
    for e in event_list(root):
        if ("%s|%s" % (e["name"], e["call_type"])).lower() not in base_ev:
            r["events"].append({"scope": "", "name": e["name"], "call_type": e["call_type"], "handler": e["handler"]})

    # Attributes, commands, parameters added by the extension; a command present in both parts that
    # gained an action with callType is the configuration's command intercepted (changed)
    for sec, item in (("Attributes", "Attribute"), ("Commands", "Command"), ("Parameters", "Parameter")):
        mm = section_map(root, sec, item)
        bm = section_map(base, sec, item)
        for k, (nm, x) in mm.items():
            changed = k in bm
            # An attribute of the configuration the extension adds columns to (a value table)
            if changed and item == "Attribute":
                had = {(c.get("name") or "").lower() for c in bm[k][1].findall("d:Columns/d:Column", NSMAP)}
                for c in x.findall("d:Columns/d:Column", NSMAP):
                    cn = c.get("name")
                    if not cn or cn.lower() in had:
                        continue
                    ft = format_type(c.find("d:Type", NSMAP))
                    r["columns"].append({"attr": nm, "name": cn, "info": (": " + ft) if ft else "", "node": c})
            if changed and item != "Command":
                continue
            base_acts = set()
            if changed:
                for a in bm[k][1].findall("d:Action", NSMAP):
                    base_acts.add(("%s|%s" % (a.get("callType", ""), inner_text(a).strip())).lower())
            info = ""
            actions = []
            if item == "Command":
                acts = []
                for a in x.findall("d:Action", NSMAP):
                    ct = a.get("callType", "")
                    h = inner_text(a).strip()
                    if changed and (not ct or ("%s|%s" % (ct, h)).lower() in base_acts):
                        continue
                    actions.append({"handler": h, "call_type": ct})
                    acts.append("%s[%s]" % (h, ct) if ct else h)
                if changed and not actions:
                    continue
                if acts:
                    info = " -> " + ", ".join(acts)
            else:
                ft = format_type(x.find("d:Type", NSMAP))
                if ft:
                    info = ": " + ft
            r[sec].append({"name": nm, "info": info, "actions": actions, "changed": changed, "node": x})

    # Conditional appearance, rule by rule: the main part holds the whole form's rules, BaseForm the
    # configuration's at the borrowing — a rule only in the main part is added, only in BaseForm removed
    def ca_rules(part):
        return [(cmp_key(it, ""), it) for it in part.findall("d:Attributes/d:ConditionalAppearance/dcsset:item", NSMAP)]
    mr = ca_rules(root)
    br = ca_rules(base)
    left = [k for k, _ in br]
    for k, it in mr:
        if k in left:
            left.remove(k)
        else:
            r["appearance"].append({"kind": "added", "key": k, "node": it})
    left = [k for k, _ in mr]
    for k, it in br:
        if k in left:
            left.remove(k)
        else:
            r["appearance"].append({"kind": "removed", "key": k, "node": it})

    # Whole blocks: command interface
    for bname, xp in (("CommandInterface", "d:CommandInterface"),):
        mn = root.find(xp, NSMAP)
        bn = base.find(xp, NSMAP)
        if cmp_key(mn, "") != cmp_key(bn, ""):
            r["blocks"].append({"name": bname, "xpath": xp, "node": mn})

    # Form properties
    pm = get_prop_map(root, root=True)
    pb = get_prop_map(base, root=True)
    for k in pm:
        if k not in pb:
            r["form_props"].append({"key": k, "old": None, "new": pm[k]})
        elif cmp_key(pm[k], "") != cmp_key(pb[k], ""):
            r["form_props"].append({"key": k, "old": pb[k], "new": pm[k]})
    for k in pb:
        if k not in pm:
            r["form_props"].append({"key": k, "old": pb[k], "new": None})

    r["total"] = (len(r["elements"]) + len(r["removed"]) + len(r["Attributes"]) + len(r["columns"]) + len(r["Commands"]) + len(r["Parameters"])
                  + len(r["events"]) + len(r["form_props"]) + len(r["blocks"]) + len(r["appearance"]))
    return r


def appearance_text(rule):
    """A conditional appearance rule in short: the fields it colours and the parameters it sets."""
    fields = [inner_text(f).strip() for f in rule.findall("dcsset:selection/dcsset:item/dcsset:field", NSMAP)]
    params = [inner_text(p).strip() for p in rule.findall("dcsset:appearance/dcscor:item/dcscor:parameter", NSMAP)]
    return "%s: %s" % (", ".join(fields) if fields else "(form)", ", ".join(params))




def prop_change_text(p):
    k = p["key"]
    if p["old"] is None:
        return "+%s=%s" % (k, prop_display(p["new"]))
    if p["new"] is None:
        return "-" + k
    return "%s: %s→%s" % (k, prop_display(p["old"]), prop_display(p["new"]))


def element_binding(node):
    dp = node.find("d:DataPath", NSMAP)
    if dp is not None and inner_text(dp).strip():
        return " -> " + inner_text(dp).strip()
    cn = node.find("d:CommandName", NSMAP)
    if cn is not None and inner_text(cn).strip() and inner_text(cn).strip() != "0":
        return " -> " + inner_text(cn).strip()
    return ""


def events_inline(node):
    evs = event_list(node)
    if not evs:
        return ""
    parts = [("%s[%s]" % (e["name"], e["call_type"])) if e["call_type"] else e["name"] for e in evs]
    return " {" + ", ".join(parts) + "}"


def move_text(ch):
    rec = ch["rec"]
    after = rec["siblings"][rec["pos"] - 1] if rec["pos"] > 0 else ""
    pos = ("after: " + after) if after else "first"
    if rec["parent"].lower() != ch["old_parent"].lower():
        to = rec["parent"] if rec["parent"] else "(form)"
        return "moved to %s (%s)" % (to, pos)
    return "moved (%s)" % pos


# One line per element change, in form-info notation
def element_change_text(ch):
    rec = ch["rec"]
    tag = get_element_tag(rec["node"])
    if ch["kind"] == "added":
        after = (" (after: %s)" % rec["siblings"][rec["pos"] - 1]) if rec["pos"] > 0 else " (first)"
        return "+ %s %s%s%s%s" % (tag, rec["name"], element_binding(rec["node"]), after, events_inline(rec["node"]))
    parts = [prop_change_text(p) for p in ch["props"]]
    if ch["moved"]:
        parts.append(move_text(ch))
    mark = "~" if ch["kind"] == "changed" else ">"
    return "%s %s %s: %s" % (mark, tag, rec["name"], "; ".join(parts))


def event_text(e):
    ct = ("[%s]" % e["call_type"]) if e["call_type"] else ""
    scope = (e["scope"] + ".") if e["scope"] else ""
    return "%s%s%s -> %s" % (scope, e["name"], ct, e["handler"])


def form_diff_headline(diff, label):
    if diff["total"] == 0:
        return label + " (borrowed, unchanged)"
    return "%s (borrowed): %s" % (label, form_diff_parts(diff))


def form_diff_parts(diff):
    added = len([c for c in diff["elements"] if c["kind"] == "added"])
    changed = len(diff["elements"]) - added
    parts = []
    if added:
        parts.append("+" + plural(added, "element"))
    if changed:
        parts.append("~" + plural(changed, "element"))
    if diff["Attributes"]:
        parts.append("+" + plural(len(diff["Attributes"]), "attribute"))
    if diff["columns"]:
        parts.append("+" + plural(len(diff["columns"]), "column"))
    cmd_changed = len([c for c in diff["Commands"] if c.get("changed")])
    cmd_added = len(diff["Commands"]) - cmd_changed
    if cmd_added:
        parts.append("+" + plural(cmd_added, "command"))
    if cmd_changed:
        parts.append("~" + plural(cmd_changed, "command"))
    if diff["Parameters"]:
        parts.append("+" + plural(len(diff["Parameters"]), "parameter"))
    if diff["events"]:
        parts.append(plural(len(diff["events"]), "event"))
    if diff["form_props"]:
        parts.append(re.sub(r'propertys$', 'properties', plural(len(diff["form_props"]), "form property")))
    for b in diff["blocks"]:
        parts.append("~" + b["name"])
    ca_added = len([a for a in diff["appearance"] if a["kind"] == "added"])
    ca_removed = len(diff["appearance"]) - ca_added
    if ca_added:
        parts.append("+" + plural(ca_added, "appearance rule"))
    if ca_removed:
        parts.append("-" + plural(ca_removed, "appearance rule"))
    if diff["removed"]:
        parts.append("!%d removed" % len(diff["removed"]))
    return ", ".join(parts)


# Overview rendering: changed elements as a tree with their ancestors for context
def format_form_diff(diff, label, ind):
    lines = [ind + form_diff_headline(diff, label)]
    if diff["total"] == 0:
        return lines
    if diff["elements"]:
        lines.append(ind + "  Elements:")
        printed = []
        for ch in diff["elements"]:
            anc = list(ch["rec"]["ancestors"])
            common = 0
            while common < len(anc) and common < len(printed) and anc[common].lower() == printed[common].lower():
                common += 1
            for d in range(common, len(anc)):
                an = diff["main_index"][anc[d].lower()]["node"]
                lines.append("%s    %s%s %s" % (ind, "  " * d, get_element_tag(an), anc[d]))
            lines.append("%s    %s%s" % (ind, "  " * len(anc), element_change_text(ch)))
            printed = anc + [ch["rec"]["name"]]
    for sec in ("Attributes", "Commands", "Parameters"):
        if not diff[sec]:
            continue
        lines.append("%s  %s:" % (ind, sec))
        for x in diff[sec]:
            lines.append("%s    %s %s%s" % (ind, "~" if x.get("changed") else "+", x["name"], x["info"]))
        if sec == "Attributes":
            for c in diff["columns"]:
                lines.append("%s    + %s.%s%s" % (ind, c["attr"], c["name"], c["info"]))
    # Columns added to an attribute of the configuration, when the form adds no attribute of its own
    if not diff["Attributes"] and diff["columns"]:
        lines.append(ind + "  Attributes:")
        for c in diff["columns"]:
            lines.append("%s    + %s.%s%s" % (ind, c["attr"], c["name"], c["info"]))
    if diff["appearance"]:
        lines.append(ind + "  Conditional appearance:")
        for a in diff["appearance"]:
            lines.append("%s    %s rule %s" % (ind, "+" if a["kind"] == "added" else "-", appearance_text(a["node"])))
    if diff["events"]:
        lines.append(ind + "  Events:")
        for e in diff["events"]:
            lines.append(ind + "    " + event_text(e))
    if diff["form_props"] or diff["blocks"]:
        lines.append(ind + "  Form:")
        for p in diff["form_props"]:
            lines.append(ind + "    ~ " + prop_change_text(p))
        for b in diff["blocks"]:
            lines.append("%s    ~ %s changed" % (ind, b["name"]))
    if diff["removed"]:
        lines.append("%s  ! removed (unexpected): %s" % (ind, ", ".join(diff["removed"])))
    return lines


# Handlers bound with callType (events, command actions): they are interceptors, not own methods
def call_type_handlers(diff):
    s = set()
    if diff:
        for e in diff["events"]:
            if e["handler"]:
                s.add(e["handler"].lower())
        for c in diff["Commands"]:
            for a in c["actions"]:
                if a["call_type"] and a["handler"]:
                    s.add(a["handler"].lower())
    return s


# ============================================================
# Overview of one object
# ============================================================

def get_proc_decls(lines):
    """Declarations of a module: name and line index of each procedure and function."""
    pat = re.compile(r'^\s*(?:' + kw_alt("Async") + r'\s+)?(?:' + kw_alt("Proc") + '|' + kw_alt("Func")
                     + r')\s+([\w]+)\s*\(', re.IGNORECASE)
    res = []
    for i, line in enumerate(lines):
        m = pat.match(line)
        if m:
            res.append({"name": m.group(1), "idx": i})
    return res


def get_top_code_line(lines):
    """First line of code outside the methods of a module (module variables, main program code), -1
    if none: comments, directives (&...) and preprocessor lines (#...) do not count."""
    decl_re = re.compile(r'^\s*(?:' + kw_alt("Async") + r'\s+)?(?:' + kw_alt("Proc") + '|' + kw_alt("Func")
                         + r')\s+[\w]+\s*\(', re.IGNORECASE)
    end_re = re.compile(r'^\s*(?:' + kw_alt("EndProc") + '|' + kw_alt("EndFunc") + r')\b', re.IGNORECASE)
    in_proc = False
    for i, line in enumerate(lines):
        t = line.strip()
        if in_proc:
            if end_re.match(t):
                in_proc = False
            continue
        if decl_re.match(t):
            in_proc = True
            continue
        if t == "" or t.startswith("//") or t.startswith("&") or t.startswith("#"):
            continue
        return i
    return -1


def get_module_changes(lines, skip_handlers):
    """What a module of a borrowed object brings: interceptors (with the method each one declares)
    and own methods, that is neither interceptors nor handlers bound in Form.xml (skip_handlers)."""
    ics = []
    ic_procs = set()
    for ic in get_interceptors(lines):
        decl = find_decl_after(lines, ic["line"])
        if decl:
            ic_procs.add(decl["name"].lower())
        ics.append({"ic": ic, "decl": decl})
    own = [d for d in get_proc_decls(lines) if d["name"].lower() not in ic_procs and d["name"].lower() not in skip_handlers]
    return {"interceptors": ics, "own": own, "top_code": get_top_code_line(lines)}


def get_own_child_list(ctx):
    """Own sub-objects of a borrowed object, named: kind, name, the type of an attribute. The own
    attributes of a borrowed tabular section come as Section.Attribute with in = the section; those of
    an own section come with in = '*' (a part of it, not counted apart)."""
    res = []
    if ctx["md"] is None or ctx["md"]["children"] is None:
        return res

    def fmt(node, name, in_):
        w = kind_word(localname(node))
        t = node.find("md:Properties/md:Type", MD_NSMAP)
        ft = format_type(t) if t is not None else ""
        return {"kind": w, "text": "%s %s%s" % (w, name, (": " + ft) if ft else ""), "in": in_}

    for c in elem_children(ctx["md"]["children"]):
        if not has_element_child(c):
            # <Form>Имя</Form>, <Template>Имя</Template>: ownership is in the sub-object descriptor
            nm = inner_text(c).strip()
            desc = read_md_object(os.path.join(ctx["obj_dir"], localname(c) + "s", nm + ".xml"))
            if desc is not None and test_adopted_node(desc["props"]):
                continue
            w = kind_word(localname(c))
            res.append({"kind": w, "text": "%s %s" % (w, nm), "in": ""})
            continue
        nm = md_child_name(c)
        own = not test_adopted_node(c)
        if own:
            res.append(fmt(c, nm, ""))
        sub = c.find("md:ChildObjects", MD_NSMAP)
        if sub is None:
            continue
        for sc in elem_children(sub):
            if not own and test_adopted_node(sc):
                continue
            res.append(fmt(sc, "%s.%s" % (nm, md_child_name(sc)), "*" if own else nm))
    return res


def get_subsystem_content(md):
    """Content of a borrowed subsystem: the objects the extension adds to it (Type.Name)."""
    res = []
    if md is None or md["props"] is None:
        return res
    content = md["props"].find("md:Content", MD_NSMAP)
    if content is None:
        return res
    for i in content:
        if isinstance(i.tag, str) and localname(i) == "Item":
            t = inner_text(i).strip()
            if t:
                res.append(t)
    return res


def format_overview_details(items):
    """Overview details, grouped by file like the cfe-transfer report: modules with their interceptors and
    own methods, the object's XML with its own sub-objects, Form.xml with the tree of changes vs
    BaseForm."""
    lines = []
    order = []
    by_sec = {}
    for it in items:
        s = it.get("section") or ""
        if s not in by_sec:
            by_sec[s] = []
            order.append(s)
        by_sec[s].append(it)
    lay = section_layout(order)

    def emit(s):
        its = by_sec[s]
        pad = "      " if s else "    "
        if s:
            tree = [it for it in its if it.get("head")]
            lines.append("    %s%s" % (s, (": " + tree[0]["head"]) if tree else ":"))
        for it in its:
            if it.get("head"):
                lines.extend(it["lines"])
                continue
            loc = ("  " + it["loc"]) if it.get("loc") else ""
            lines.append("%s%s%s" % (pad, it["text"], loc))

    for s in lay["plain"]:
        emit(s)
    for f in lay["forms"]:
        for s in f["secs"]:
            emit(s)
    return lines


def overview_object(ext, obj):
    oid = "%s.%s" % (obj["type"], obj["name"])
    ctx = get_obj_context(ext["dir"], obj["type"], obj["name"])
    if not ctx["known"]:
        return {"id": oid, "kind": "?", "summary": "[?]          %s — unknown type" % oid, "details": []}
    if not ctx["exists"]:
        return {"id": oid, "kind": "?", "summary": "[?]          %s — file not found" % oid, "details": []}
    if not ctx["borrowed"]:
        parts = []
        if ctx["md"]["children"] is not None:
            cnt = {}
            for c in elem_children(ctx["md"]["children"]):
                w = kind_word(localname(c))
                cnt[w] = cnt.get(w, 0) + 1
            parts = [plural(v, w) for w, v in cnt.items()]
        tail = (" — " + ", ".join(parts)) if parts else ""
        return {"id": oid, "kind": "own", "summary": "[OWN]        " + oid + tail, "details": []}

    items = []
    forms = get_obj_forms(ctx)
    diffs = {}
    changed_forms = 0
    bad_forms = 0
    for f in forms:
        if f["own"]:
            continue
        d = get_form_diff(f["xml"])
        if d is None or not d["is_borrowed"]:
            # A borrowed form must carry its BaseForm: without it there is nothing to compare with
            if not os.path.isfile(f["xml"]):
                why = "Form.xml not found"
            elif d is None:
                why = "Form.xml cannot be read"
            else:
                why = "no BaseForm — cannot compare"
            bad_forms += 1
            items.append({"section": rel_path(ext["dir"], f["xml"]), "text": why, "loc": ""})
            continue
        diffs[path_key(f["module"])] = d
        if d["total"] == 0:
            continue
        changed_forms += 1
        # The headline of the tree goes to the section header, the rest under it
        tree = format_form_diff(d, f["label"], "    ")
        items.append({"section": rel_path(ext["dir"], f["xml"]), "head": form_diff_parts(d), "lines": tree[1:]})
    ic_count = 0
    own_methods = 0
    top_code = 0
    for bsl in get_obj_modules(ctx, forms):
        lines = read_bsl_lines(bsl)
        if lines is None:
            continue
        rel = rel_path(ext["dir"], bsl)
        k = path_key(bsl)
        skip = call_type_handlers(diffs[k]) if k in diffs else set()
        mc = get_module_changes(lines, skip)
        if mc["top_code"] >= 0:
            top_code += 1
            items.append({"section": rel, "text": "module code outside methods", "loc": ":%d" % (mc["top_code"] + 1)})
        for x in mc["interceptors"]:
            ic_count += 1
            items.append({"section": rel, "text": '&%s("%s")' % (x["ic"]["raw"], x["ic"]["method"]), "loc": ":%d" % (x["ic"]["line"] + 1)})
        for o in mc["own"]:
            own_methods += 1
            items.append({"section": rel, "text": "method " + o["name"], "loc": ":%d" % (o["idx"] + 1)})
    obj_rel = rel_path(ext["dir"], ctx["file"])
    kinds = {}
    for k in get_own_child_list(ctx):
        items.append({"section": obj_rel, "text": k["text"], "loc": ""})
        # Parts of an own sub-object go with it; additions to a borrowed one are counted per owner
        if k["in"] == "*":
            continue
        kk = (k["kind"], k["in"])
        kinds[kk] = kinds.get(kk, 0) + 1
    content = 0
    if obj["type"] == "Subsystem":
        for c in get_subsystem_content(ctx["md"]):
            items.append({"section": obj_rel, "text": "content " + c, "loc": ""})
            content += 1

    sp = []
    if ic_count:
        sp.append(plural(ic_count, "interceptor"))
    if own_methods:
        sp.append(plural(own_methods, "own method"))
    if top_code:
        sp.append("module code")
    for (w, in_), v in kinds.items():
        sp.append("own " + plural(v, w) + ((" in " + in_) if in_ else ""))
    if content:
        sp.append(plural(content, "content item"))
    if changed_forms:
        sp.append(plural(changed_forms, "form") + " changed")
    if bad_forms:
        sp.append(plural(bad_forms, "form") + " not compared")
    # Borrowed only as a dependency (a type, a picture, a style of the extension's own code)
    unchanged = not items
    tail = " — no changes" if unchanged else " — " + ", ".join(sp)
    return {"id": oid, "type": obj["type"], "kind": "borrowed", "unchanged": unchanged,
            "summary": "[BORROWED]   " + oid + tail, "details": format_overview_details(items)}


# ============================================================
# Run
# ============================================================

def section_layout(order):
    """Order of detail sections: plain files first, then each form with its
    Form.xml before its Module.bsl."""
    plain = []
    forms = []
    secs_of = {}
    for s in order:
        m = re.match(r'^(.*)/Ext/Form(?:\.xml|/Module\.bsl)$', s)
        fd = m.group(1) if m else ""
        if not fd:
            plain.append(s)
            continue
        if fd not in secs_of:
            secs_of[fd] = []
            forms.append(fd)
        secs_of[fd].append(s)
    return {"plain": plain, "forms": [{"dir": fd, "secs": sorted(secs_of[fd], key=lambda x: 0 if x.endswith(".xml") else 1)} for fd in forms]}


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def resolve_input_path(p):
    p = p.strip()
    if not os.path.isabs(p):
        p = os.path.join(os.getcwd(), p)
    if os.path.isfile(p):
        p = os.path.dirname(p)
    return p


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Analyze 1C configuration extension (CFE): borrowed objects, interceptors, own members, form changes", allow_abbrev=False)
    parser.add_argument("-ExtensionPath", required=True, help="Extension dump root, comma-separated list, or folder of extensions")
    parser.add_argument("-ConfigPath", default="", help="Not used: kept so that an old transfer-check call gets the hint")
    parser.add_argument("-Mode", default="overview", help="overview")
    parser.add_argument("-Name", default="", help="Objects to detail: Type.Name[,Type.Name]")
    parser.add_argument("-Limit", type=int, default=150)
    parser.add_argument("-Offset", type=int, default=0)
    parser.add_argument("-Expand", default="", help="List folded borrowed objects: Type.Name or *")
    parser.add_argument("-OutFile", default="")
    args = ci_parse_args(parser)

    # The transfer check moved to its own skill: an old call gets pointed there instead of a bare error
    mode_key = args.Mode.strip().lower()
    if mode_key in ("check-transfer", "transfer", "b"):
        die("Transfer check moved: use /cfe-transfer -ExtensionPath <path> -ConfigPath <path>")
    if mode_key not in ("overview", "a"):
        die("Invalid -Mode '%s'. Expected: overview" % args.Mode)

    # -ExtensionPath: an extension, a comma-separated list, or a folder whose subfolders are extensions.
    ext_dirs = []
    for raw in [x.strip() for x in args.ExtensionPath.split(",") if x.strip()]:
        p = resolve_input_path(raw)
        if os.path.isfile(os.path.join(p, "Configuration.xml")):
            cp = read_configuration_props(p)
            if not cp["is_extension"]:
                die("Not an extension (no ConfigurationExtensionPurpose): " + p)
            ext_dirs.append(p)
            continue
        if not os.path.isdir(p):
            die("Extension not found: " + p)
        found = []
        for sub in sorted(os.listdir(p)):
            sp = os.path.join(p, sub)
            if not os.path.isdir(sp):
                continue
            cp = read_configuration_props(sp)
            if cp and cp["is_extension"]:
                found.append(sp)
        if not found:
            die("Extension Configuration.xml not found: %s (and no extension subfolders)" % os.path.join(p, "Configuration.xml"))
        ext_dirs += found
    if not ext_dirs:
        die("No extension given in -ExtensionPath")

    # -ConfigPath is kept so that a call written for the old transfer check reaches the hint above
    # instead of failing on an unknown parameter; the overview does not use it

    name_filter = [x.strip() for x in args.Name.split(",") if x.strip()] if args.Name else []
    expand_list = [x.strip() for x in args.Expand.split(",") if x.strip()] if args.Expand else []

    def name_match(oid):
        if not name_filter:
            return True
        for f in name_filter:
            if oid.lower() == f.lower():
                return True
            if "." not in f and oid[oid.index(".") + 1:].lower() == f.lower():
                return True
        return False

    exts = []
    matched_ids = set()
    for d in ext_dirs:
        cp = read_configuration_props(d)
        ext = {"dir": d, "name": cp["name"], "prefix": cp["prefix"], "purpose": cp["purpose"], "objects": [],
               "borrowed": 0, "own": 0, "matched": 0}
        if cp["child_objects"] is not None:
            for child in elem_children(cp["child_objects"]):
                if localname(child) == "Language":
                    continue
                obj = {"type": localname(child), "name": (child.text or "").strip()}
                oid = "%s.%s" % (obj["type"], obj["name"])
                if not name_match(oid):
                    continue
                matched_ids.add(oid.lower())
                ext["matched"] += 1
                rec = overview_object(ext, obj)
                if rec["kind"] == "borrowed":
                    ext["borrowed"] += 1
                elif rec["kind"] == "own":
                    ext["own"] += 1
                # A borrowed object without changes is folded into the summary unless asked for
                # (-Expand * lists them in the summary instead)
                rec["asked"] = bool(name_filter) or any(t.lower() == rec["id"].lower() for t in expand_list)
                ext["objects"].append(rec)
        # -Name narrows the report: an extension without a matching object stays out of it
        if name_filter and ext["matched"] == 0:
            continue
        exts.append(ext)

    # --- Detail decision ---
    full_count = 0
    for ext in exts:
        full_count += 3
        for o in ext["objects"]:
            if o.get("unchanged") and not o.get("asked"):
                continue
            full_count += 1 + len(o["details"])
    show_details = bool(name_filter) or full_count <= DETAIL_BUDGET

    # --- Body ---
    body = []
    for ext in exts:
        body.append("=== cfe-diff overview: %s (%s) ===" % (ext["name"], ext["purpose"]))
        if ext["prefix"]:
            body.append("NamePrefix: " + ext["prefix"])
        body.append("")
        shown = 0
        for o in ext["objects"]:
            if o.get("unchanged") and not o.get("asked"):
                continue
            body.append(o["summary"])
            shown += 1
            if show_details:
                body += o["details"]
        if shown == 0:
            if ext["objects"]:
                body.append("No changes in borrowed objects.")
            else:
                body.append("No objects (besides Language) in extension.")
        body.append("")

    # --- Footer: always printed, after the body (output is often read from its tail) ---
    footer = []
    unch_folded = False
    for ext in exts:
        unch = [o for o in ext["objects"] if o.get("unchanged")]
        bp = (" (%d changed, %d without changes)" % (ext["borrowed"] - len(unch), len(unch))) if unch else ""
        footer.append("=== Summary %s: %d borrowed%s, %d own objects ===" % (ext["name"], ext["borrowed"], bp, ext["own"]))
        if unch:
            by_type = {}
            # One shown in the body (asked for by -Name or -Expand Type.Name) is not folded
            for o in (o for o in unch if not o.get("asked")):
                by_type.setdefault(o["type"], []).append(o["id"][len(o["type"]) + 1:])
            if not by_type:
                pass
            elif "*" in expand_list:
                footer.append("Borrowed without changes:")
                for t, names in by_type.items():
                    footer.append("    %s: %s" % (t, ", ".join(names)))
            else:
                footer.append("Borrowed without changes: " + ", ".join("%s %d" % (t, len(n)) for t, n in by_type.items()))
                unch_folded = True
    for f in name_filter:
        hit = False
        for k in matched_ids:
            if k == f.lower() or ("." not in f and k[k.index(".") + 1:] == f.lower()):
                hit = True
                break
        if not hit:
            footer.append("[INFO] -Name: no object matches '%s'" % f)
    if not show_details:
        footer.append("Details omitted (%d lines in full). Use -Name <Type.Name>[,<Type.Name>] for item details." % full_count)
    if unch_folded:
        footer.append("Hint: use -Expand * to list borrowed objects without changes")

    # --- Pagination of the body; the footer stays ---
    total = len(body)
    out = []
    offset = args.Offset
    limit = args.Limit
    if offset > 0 and offset >= total:
        out.append("[INFO] Offset %d exceeds total lines (%d)." % (offset, total))
    else:
        end = min(total, offset + limit)
        if end > offset:
            out += body[offset:end]
        if end < total:
            out.append("[TRUNCATED] Shown %d of %d lines. Use -Offset %d to continue." % (end - offset, total, end))
            out.append("")
    out += footer

    if args.OutFile:
        out_file = args.OutFile
        if not os.path.isabs(out_file):
            out_file = os.path.join(os.getcwd(), out_file)
        # Same bytes as [IO.File]::WriteAllLines in the .ps1: UTF-8 with BOM, CRLF, trailing newline
        with open(out_file, "w", encoding="utf-8-sig", newline="") as fh:
            fh.write("\r\n".join(out) + "\r\n")
        print("Output written to " + out_file)
    else:
        for l in out:
            print(l)

    sys.exit(0)


if __name__ == "__main__":
    main()
