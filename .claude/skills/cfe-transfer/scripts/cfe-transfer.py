#!/usr/bin/env python3
# cfe-transfer v1.9 — Transfer of 1C configuration extension (CFE) changes into the main configuration: check and transfer
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
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


# Spelling language of a recognized keyword. English is the discriminator: a Russian keyword
# never equals an English one, so anything else is 'ru'.
def bsl_lang(word):
    w = word.strip().lower()
    for k in ("Async", "Proc", "EndProc", "Func", "EndFunc", "Region", "If", "Insert", "Delete",
              "Before", "After", "Around", "Control"):
        if BSL_KW["en"][k].lower() == w:
            return "en"
    return "ru"


# Edit marker kind at the start of a line: Insert/Delete/EndInsert/EndDelete, None if none.
# The marker owns the start of the line only — a trailing comment does not bother the platform
# and must not bother us either.
def bsl_marker_kind(line):
    kw = BSL_KW
    for k in ("EndInsert", "EndDelete", "Insert", "Delete"):
        if re.match(r'^\s*#(?:' + kw["ru"][k] + '|' + kw["en"][k] + r')\b', line, re.IGNORECASE):
            return k
    return None


CONTEXT_RE = re.compile(
    r'^&(' + '|'.join(BSL_KW["ru"]["Directives"] + BSL_KW["en"]["Directives"]) + r')\s*$',
    re.IGNORECASE
)


def split_top_level(text, sep=","):
    result = []
    depth = 0
    in_str = False
    buf = []
    for ch in text:
        if in_str:
            buf.append(ch)
            if ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            buf.append(ch)
            continue
        if ch == '(':
            depth += 1
            buf.append(ch)
            continue
        if ch == ')':
            depth -= 1
            buf.append(ch)
            continue
        if ch == sep and depth == 0:
            result.append("".join(buf))
            buf = []
            continue
        buf.append(ch)
    result.append("".join(buf))
    return result


def is_context_directive(trimmed):
    return bool(CONTEXT_RE.match(trimmed))


def read_signature(lines, start_idx):
    """Return (params_text, end_line_idx) or None."""
    depth = 0
    in_str = False
    open_found = False
    params = []
    for li in range(start_idx, len(lines)):
        line = lines[li]
        for ch in line:
            if in_str:
                if open_found:
                    params.append(ch)
                if ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
                if open_found:
                    params.append(ch)
                continue
            if ch == '(':
                depth += 1
                if not open_found:
                    open_found = True
                else:
                    params.append(ch)
                continue
            if ch == ')':
                depth -= 1
                if depth == 0:
                    return ("".join(params), li)
                params.append(ch)
                continue
            if open_found:
                params.append(ch)
        if open_found and depth >= 1:
            params.append("\r\n")
    return None


def effective_condition(frame, lang):
    kw_not = BSL_KW[lang]["Not"]
    kw_and = BSL_KW[lang]["And"]
    conds = frame["conds"]
    n = len(conds)
    if frame["in_else"]:
        return (" %s " % kw_and).join("%s (%s)" % (kw_not, c) for c in conds)
    if n == 1:
        return conds[0]
    parts = ["%s (%s)" % (kw_not, conds[j]) for j in range(n - 1)]
    parts.append(conds[n - 1])
    return (" %s " % kw_and).join(parts)


def get_enclosing_chain(lines, target_idx, lang):
    re_region = re.compile(r'^#' + kw_alt("Region") + r'\s+(\S+)', re.IGNORECASE)
    re_end_region = re.compile(r'^#' + kw_alt("EndRegion"), re.IGNORECASE)
    re_if = re.compile(r'^#' + kw_alt("If") + r'\s+(.+?)\s+' + kw_alt("Then"), re.IGNORECASE)
    re_elsif = re.compile(r'^#' + kw_alt("ElsIf") + r'\s+(.+?)\s+' + kw_alt("Then"), re.IGNORECASE)
    re_else = re.compile(r'^#' + kw_alt("Else") + r'(\s|$)', re.IGNORECASE)
    re_endif = re.compile(r'^#' + kw_alt("EndIf"), re.IGNORECASE)
    stack = []
    for i in range(target_idx):
        t = lines[i].strip()
        m = re_region.match(t)
        if m:
            stack.append({"kind": "region", "name": m.group(1)})
            continue
        if re_end_region.match(t):
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "region":
                    del stack[k]
                    break
            continue
        m = re_if.match(t)
        if m:
            stack.append({"kind": "if", "conds": [m.group(1).strip()], "in_else": False})
            continue
        m = re_elsif.match(t)
        if m:
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "if":
                    stack[k]["conds"].append(m.group(1).strip())
                    stack[k]["in_else"] = False
                    break
            continue
        if re_else.match(t):
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "if":
                    stack[k]["in_else"] = True
                    break
            continue
        if re_endif.match(t):
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "if":
                    del stack[k]
                    break
            continue
    chain = []
    for f in stack:
        if f["kind"] == "region":
            chain.append({"kind": "region", "name": f["name"]})
        else:
            chain.append({"kind": "if", "cond": effective_condition(f, lang)})
    return chain


def extract_method(lines, method_name):
    decl_re = re.compile(
        r'^\s*(' + kw_alt("Async") + r'\s+)?(' + kw_alt("Proc") + '|' + kw_alt("Func") + r')\s+('
        + re.escape(method_name) + r')\s*\(',
        re.IGNORECASE,
    )
    for i in range(len(lines)):
        m = decl_re.match(lines[i])
        if not m:
            continue
        is_async = bool(m.group(1))
        keyword = m.group(2)
        canonical = m.group(3)
        lang = bsl_lang(keyword)
        is_function = keyword.lower() in (BSL_KW["ru"]["Func"].lower(), BSL_KW["en"]["Func"].lower())

        sig = read_signature(lines, i)
        if not sig:
            raise ValueError("Не удалось разобрать сигнатуру метода '%s'" % method_name)
        params_text, sig_end = sig

        param_names = []
        if params_text.strip():
            for seg in split_top_level(params_text):
                s = re.sub(r'^' + kw_alt("Val") + r'\s+', '', seg.strip(), flags=re.IGNORECASE)
                mm = re.match(r'^([\w]+)', s)
                if mm:
                    param_names.append(mm.group(1))

        end_re = re.compile(r'^\s*' + (kw_alt("EndFunc") if is_function else kw_alt("EndProc")) + r'\b',
                            re.IGNORECASE)
        body_start = sig_end + 1
        body_end = -1
        for j in range(body_start, len(lines)):
            if end_re.match(lines[j]):
                body_end = j
                break
        if body_end < 0:
            raise ValueError("Не найден конец метода '%s'" % method_name)
        body_lines = lines[body_start:body_end]

        context = ""
        if i >= 1:
            prev = lines[i - 1].strip()
            if is_context_directive(prev):
                context = prev

        chain = get_enclosing_chain(lines, i, lang)

        return {
            "canonical": canonical,
            "lang": lang,
            "is_function": is_function,
            "is_async": is_async,
            "params_text": params_text,
            "param_names": param_names,
            "context": context,
            "body_lines": body_lines,
            "chain": chain,
            "decl_idx": i,
            "sig_end_idx": sig_end,
            "body_end_idx": body_end,
        }
    return None


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


def get_proc_names(lines):
    names = []
    pat = re.compile(r'^\s*(?:' + kw_alt("Async") + r'\s+)?(?:' + kw_alt("Proc") + '|' + kw_alt("Func")
                     + r')\s+([\w]+)\s*\(', re.IGNORECASE)
    for line in lines:
        m = pat.match(line)
        if m:
            names.append(m.group(1))
    return names


def normalize(line):
    return re.sub(r'\s+', ' ', line).strip()


def parse_marked_body(body_lines):
    v1 = []
    ops = []
    i = 0
    n = len(body_lines)
    while i < n:
        kind = bsl_marker_kind(body_lines[i])
        if kind == "Insert":
            # Marker lines are kept verbatim: they carry the author's spelling, indent and — since
            # a tail comment is legal — the note explaining the edit. Re-emitting a bare keyword
            # would silently drop that note on -Actualize.
            open_line = body_lines[i]
            ins = []
            i += 1
            while i < n and bsl_marker_kind(body_lines[i]) != "EndInsert":
                ins.append(body_lines[i])
                i += 1
            close_line = body_lines[i] if i < n else None
            i += 1
            ops.append({"kind": "insert", "after": len(v1) - 1, "lines": ins,
                        "open": open_line, "close": close_line})
        elif kind == "Delete":
            open_line = body_lines[i]
            start_idx = len(v1)
            i += 1
            dels = []
            while i < n and bsl_marker_kind(body_lines[i]) != "EndDelete":
                dels.append(body_lines[i])
                v1.append(body_lines[i])
                i += 1
            close_line = body_lines[i] if i < n else None
            i += 1
            ops.append({"kind": "delete", "start": start_idx, "end": len(v1) - 1, "lines": dels,
                        "open": open_line, "close": close_line})
        else:
            v1.append(body_lines[i])
            i += 1
    return {"v1": v1, "ops": ops}


def find_unique_index(v2norm, key):
    found = -1
    for k in range(len(v2norm)):
        if v2norm[k] == key:
            if found >= 0:
                return -1
            found = k
    return found


def find_unique_run(v2norm, keys):
    if not keys:
        return -1
    found = -1
    for k in range(len(v2norm) - len(keys) + 1):
        if v2norm[k:k + len(keys)] == keys:
            if found >= 0:
                return -1
            found = k
    return found


def test_significant(norm_line):
    """A significant line carries code: non-empty and not a whole-line comment (//).
    Blank/comment-only lines are cosmetic — transparent to anchor/absorption matching."""
    return norm_line != "" and not norm_line.startswith("//")


def significant_projection(norm):
    """Project normalized lines to significant-only. Returns (sig_values, orig_indices)."""
    sig = []
    idx = []
    for i, ln in enumerate(norm):
        if test_significant(ln):
            sig.append(ln)
            idx.append(i)
    return sig, idx


def test_run_at(hay, keys, at):
    """True if normalized run `keys` sits in `hay` starting exactly at index `at` (contiguous)."""
    if not keys or at < 0 or at + len(keys) > len(hay):
        return False
    return hay[at:at + len(keys)] == keys


def test_delete_absorbed(v2norm, before_ctx, after_ctx, mid=()):
    """True if a deletion is already applied in v2: before/after context now enclose exactly `mid`
    (nothing for a plain deletion, the inserted code for a replacement), or the missing side sits
    at a body boundary (None = boundary)."""
    mid = list(mid)
    n = len(mid)
    for i in range(len(v2norm) - n + 1):
        if before_ctx is not None:
            if i == 0 or v2norm[i - 1] != before_ctx:
                continue
        elif i != 0:
            break
        if v2norm[i:i + n] != mid:
            continue
        e = i + n
        if after_ctx is not None:
            if e < len(v2norm) and v2norm[e] == after_ctx:
                return True
        elif e == len(v2norm):
            return True
    return False


def get_absorbed_in_place(ops, v1norm, v2norm, v2sig, payloads):
    """Edits already carried into the main configuration in place: v2 holds "line before + inserted
    code + line after" (significant lines). A deletion together with the insertions right next to it
    (only blanks/comments between) is one replacement: its context lines are no longer adjacent and
    the insert's own anchor was the deleted text, so neither edit is recognised alone. A plain insert
    is checked the same way, because the payload sitting at its spot splits its anchor and the anchor
    search may then land on a look-alike elsewhere. Returns the set of op indices absorbed.
    payloads: op index -> significant normalized lines of that insert."""
    hit = set()
    for d, op in enumerate(ops):
        if op["kind"] != "delete":
            continue
        # No check that the deleted lines are gone from the whole method: the new code may well
        # repeat them (a call wrapped into a condition). The contiguous run below settles it.
        b_idx = -1
        for z in range(op["start"] - 1, -1, -1):
            if test_significant(v1norm[z]):
                b_idx = z
                break
        a_idx = len(v1norm)
        for z in range(op["end"] + 1, len(v1norm)):
            if test_significant(v1norm[z]):
                a_idx = z
                break
        group = []
        mid = []
        for i, o in enumerate(ops):
            if o["kind"] == "insert" and b_idx <= o["after"] < a_idx:
                group.append(i)
                mid.extend(payloads.get(i, []))
        if not mid:
            continue
        b_ctx = v1norm[b_idx] if b_idx >= 0 else None
        a_ctx = v1norm[a_idx] if a_idx < len(v1norm) else None
        if test_delete_absorbed(v2sig, b_ctx, a_ctx, mid):
            hit.add(d)
            hit.update(group)
    for i, op in enumerate(ops):
        if op["kind"] != "insert" or i in hit:
            continue
        mid = payloads.get(i, [])
        if not mid:
            continue
        b_ctx = None
        for z in range(op["after"], -1, -1):
            if test_significant(v1norm[z]):
                b_ctx = v1norm[z]
                break
        a_ctx = None
        for z in range(op["after"] + 1, len(v1norm)):
            if test_significant(v1norm[z]):
                a_ctx = v1norm[z]
                break
        if test_delete_absorbed(v2sig, b_ctx, a_ctx, mid):
            hit.add(i)
    return hit


def resolve_insertion_point_exact(v2norm, before_lines, after_lines):
    """Exact two-sided resolution over the given array.
    Returns index to insert-after (-1 = top), or None if ambiguous/conflict."""
    nb = len(before_lines)
    na = len(after_lines)

    # Tier A: adjacent pair (before[-1] then after[0] in v2), widening symmetrically
    if nb >= 1 and na >= 1:
        cands = [k for k in range(len(v2norm) - 1)
                 if v2norm[k] == before_lines[-1] and v2norm[k + 1] == after_lines[0]]
        if len(cands) == 1:
            return cands[0]
        if len(cands) > 1:
            w = 1
            while len(cands) > 1 and (w < nb or w < na):
                w += 1
                filtered = []
                for k in cands:
                    ok = True
                    if w <= nb:
                        if k - (w - 1) < 0 or v2norm[k - (w - 1)] != before_lines[nb - w]:
                            ok = False
                    if ok and w <= na:
                        if k + w >= len(v2norm) or v2norm[k + w] != after_lines[w - 1]:
                            ok = False
                    if ok:
                        filtered.append(k)
                if not filtered:
                    break
                cands = filtered
            if len(cands) == 1:
                return cands[0]
            return None

    # Tier B: one side changed -> single-side uniqueness
    if nb >= 1:
        bk = find_unique_index(v2norm, before_lines[-1])
        if bk >= 0:
            return bk
    if na >= 1:
        ak = find_unique_index(v2norm, after_lines[0])
        if ak >= 0:
            return ak - 1
    return None


def resolve_insertion_point(v2norm, before_lines, after_lines):
    """Exact first (comments/blanks included — keeps the insert's position relative to a stable
    comment); on failure, retry on significant lines only (transparent to vendor-added blanks/
    comments) and map back to a full-v2 index. Returns insert-after idx or None."""
    k = resolve_insertion_point_exact(v2norm, before_lines, after_lines)
    if k is not None:
        return k
    sig, idx = significant_projection(v2norm)
    bs = [x for x in before_lines if test_significant(x)]
    as_ = [x for x in after_lines if test_significant(x)]
    ksig = resolve_insertion_point_exact(sig, bs, as_)
    if ksig is None:
        return None
    if ksig < 0:
        return -1
    return idx[ksig]


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


# Name lookup: the exact name first, then the name without the extension prefix
def find_name_in(names, name, prefix):
    for c in names:
        if c.lower() == name.lower():
            return c
    s = get_name_key(name, prefix).lower()
    for c in names:
        if get_name_key(c, prefix).lower() == s:
            return c
    return None


# All names that may stand for name: the same name first, then those equal without the prefixes
def find_names_in(names, name, prefix):
    res = [c for c in names if c.lower() == name.lower()]
    s = get_name_key(name, prefix).lower()
    res += [c for c in names if c.lower() != name.lower() and get_name_key(c, prefix).lower() == s]
    return res


# A name compared without the extension prefix and, when the project has them, without the
# development prefixes: the transfer may give an own name either way (see get_target_name)
def get_name_key(name, prefix):
    t = remove_ext_prefix(name, prefix)
    if DEV_RE is not None:
        t = DEV_RE.sub("", t)
    return t


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


def get_method_safe(lines, method_name):
    if lines is None or not method_name:
        return None
    try:
        return extract_method(lines, method_name)
    except Exception:
        return None


# Comparable form of a code line: normalized, without the extension prefix, lower case (the language
# ignores case; lowering here also keeps the copied matchers' -eq and Python's == in agreement)
def code_key(line, prefix):
    t = remove_ext_prefix(line, prefix)
    if DEV_RE is not None:
        t = DEV_RE.sub("", t)
    return normalize(t).lower()


# Significant lines of a body as code keys
def sig_lines(lines, prefix):
    out = []
    for l in lines:
        n = code_key(l, prefix)
        if test_significant(n):
            out.append(n)
    return out


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
# Transfer of method changes
# ============================================================

# &ИзменениеИКонтроль: each #Вставка/#Удаление is classified the way cfe-patch-method -Check does
# (absorbed = already in the main configuration, pending = still to carry over, disputed = the
# anchor or the deleted lines changed). None when the method has no edits with code.
def get_temp_mark(line):
    """Developer's mark "not for transfer" (a workaround for an extension limitation, a one-off fix):
    a comment whose text starts with «Временно» or «Не переносить» (case and spaces ignored), the
    reason may follow. Returns the reason ('' when none) or None when the line is not such a mark."""
    i = line.find("//")
    if i < 0:
        return None
    t = line[i:].lstrip("/").strip()
    # The form's own mark (get_form_temp_marks) names form items, not the method below it
    if re.match(r'(?i)не\s*переносить\s+элементы\s+формы', t):
        return None
    m = re.match(r'(?i)(?:не\s*переносить|временно)(?![^\W])\s*[:\-–—]?\s*(.*)$', t)
    return m.group(1).strip() if m else None


def get_form_temp_marks(lines):
    """Form items kept out of the transfer: "// Не переносить элементы формы: Имя1, Имя2 — причина" among the
    comment lines the form module starts with, before its variables and methods. Lower-case name -> reason."""
    res = {}
    for line in lines or []:
        t = line.strip()
        if t == "" or t.startswith("#"):
            continue
        if not t.startswith("//"):
            break
        m = re.match(r'^//+\s*(?i:не\s*переносить\s+элементы\s+формы)\s*:\s*(.+)$', t)
        if not m:
            continue
        body, why = m.group(1), ""
        sep = re.search(r'\s+[—–-]\s+', body)
        if sep:
            why = body[sep.end():].strip()
            body = body[:sep.start()]
        for n in body.split(","):
            n = n.strip()
            if n:
                res[n.lower()] = why
    return res


def get_method_temp_mark(lines, method, above_only=False):
    """Mark of a whole method: in the comment lines right above it (annotations and directives
    skipped) or in the comment lines the body starts with. above_only for &ИзменениеИКонтроль: its
    body is a copy of the original, so a comment there is the configuration's, not the developer's
    mark."""
    for z in range(method["decl_idx"] - 1, -1, -1):
        t = lines[z].strip()
        if t.startswith("&"):
            continue
        if not t.startswith("//"):
            break
        m = get_temp_mark(t)
        if m is not None:
            return m
    if above_only:
        return None
    for l in method["body_lines"]:
        t = l.strip()
        if t == "":
            continue
        if not t.startswith("//"):
            break
        m = get_temp_mark(t)
        if m is not None:
            return m
    return None


def get_block_temp_mark(op):
    """Mark of one #Вставка/#Удаление block: a tail comment on its opening marker or the comment
    lines an insert starts with (the lines of a deletion are the configuration's code, not the
    developer's)."""
    if op.get("open"):
        m = get_temp_mark(op["open"])
        if m is not None:
            return m
    if op["kind"] != "insert":
        return None
    for l in op["lines"]:
        t = l.strip()
        if t == "":
            continue
        if not t.startswith("//"):
            break
        m = get_temp_mark(t)
        if m is not None:
            return m
    return None


def fmt_temp_why(mark):
    return (" — " + mark) if mark else ""


def set_temp_mark(item, mark, label):
    """A method marked "not for transfer": still carried over -> stays TRANSFERRED with a note (a
    workaround moved into the configuration is worth a look); otherwise -> TEMPORARY."""
    if mark is None or not item:
        return item
    if item["status"] == "TRANSFERRED":
        item["text"] += " (marked temporary)"
        item["marked"] = True
        return item
    t = new_item("TEMPORARY", label + fmt_temp_why(mark), item["loc"], item["group"])
    # The plan stays: code that calls a temporary method must know it is not coming
    if item.get("plan"):
        t["plan"] = item["plan"]
    return t


def test_payload_beside(v2sig, mid, before_ctx, after_ctx):
    """Insert payload sitting right after its line before, or right before its line after, anywhere in
    v2 (significant lines; None side is not checked). Looser than the in-place check: one neighbour is
    enough and the spot need not be unique. For an insert not found at its anchor: the anchor may be
    lost (a payload repeated in the method leaves the search nothing to go on) or resolved to a
    look-alike elsewhere. Only a neighbour with content counts (see TRIVIAL_RE)."""
    # A block closer or a bare jump stands next to anything: as a neighbour it proves nothing
    if before_ctx is not None and TRIVIAL_RE.search(before_ctx):
        before_ctx = None
    if after_ctx is not None and TRIVIAL_RE.search(after_ctx):
        after_ctx = None
    if before_ctx is None and after_ctx is None:
        return False
    n = len(mid)
    for i in range(len(v2sig) - n + 1):
        if v2sig[i:i + n] != mid:
            continue
        if before_ctx is not None and i > 0 and v2sig[i - 1] == before_ctx:
            return True
        if after_ctx is not None and i + n < len(v2sig) and v2sig[i + n] == after_ctx:
            return True
    return False


def run_count(hay, keys):
    """How many times the run `keys` occurs in `hay` (contiguous, overlapping counted)."""
    n = len(keys)
    if n == 0:
        return 0
    return sum(1 for i in range(len(hay) - n + 1) if hay[i:i + n] == keys)


def dispute_reason(kind, line, key, side, v2norm):
    """Why an edit is disputed, with the line to look at: the insert's neighbour (and whether the
    configuration keeps it commented out) or the first deleted line."""
    txt = get_short(line, 60)
    if kind == "delete":
        return "deleted lines changed in config: " + txt
    if not key:
        return "insert anchor changed in config"
    commented = any(l.startswith("//") and re.sub(r'^/+\s*', '', l) == key for l in v2norm)
    how = "commented out" if commented else "changed"
    return "line %s insert %s in config: %s" % (side, how, txt)


def find_commented_run(v2norm, keys, before_ctx, after_ctx):
    """A deletion carried over by commenting the lines out, at its own place: its significant lines stand in
    v2norm as a run of // comments (blank lines and other comments — the frame, //-blank lines — between
    them allowed, code not), with the deleted block's line before right above the run or its line after
    right below it (None: a body boundary). One neighbour is enough: the replacing code may follow the
    run. Returns the index of the run's last line in v2norm, -1 when there is none."""
    if not keys:
        return -1
    run = []

    def check():
        for s in range(len(run) - len(keys) + 1):
            if [c for c, _ in run[s:s + len(keys)]] != keys:
                continue
            first = run[s][1]
            last = run[s + len(keys) - 1][1]
            b = next((v2norm[z] for z in range(first - 1, -1, -1) if test_significant(v2norm[z])), None)
            a = next((v2norm[z] for z in range(last + 1, len(v2norm)) if test_significant(v2norm[z])), None)
            if b == before_ctx or a == after_ctx:
                return last
        return -1

    for i, l in enumerate(v2norm):
        if l == "":
            continue
        if l.startswith("//"):
            c = re.sub(r'\s+', ' ', l[2:]).strip()
            if test_significant(c):
                run.append((c, i))
            continue
        r = check()
        if r >= 0:
            return r
        run = []
    return check()


def find_run_in_context(v2norm, v2sig, v2map, keys, sig_keys, before_ctx, after_ctx):
    """Where deleted lines that occur more than once stand between the same neighbours as in the original:
    the index in v2norm when exactly one occurrence does, else -1."""
    n = len(sig_keys)
    if n == 0:
        return -1
    lead = 0
    while lead < len(keys) and not test_significant(keys[lead]):
        lead += 1
    found = -1
    for i in range(len(v2sig) - n + 1):
        if not test_run_at(v2sig, sig_keys, i):
            continue
        if before_ctx is not None:
            if i == 0 or v2sig[i - 1] != before_ctx:
                continue
        elif i != 0:
            continue
        e = i + n
        if after_ctx is not None:
            if e >= len(v2sig) or v2sig[e] != after_ctx:
                continue
        elif e != len(v2sig):
            continue
        at = v2map[i] - lead
        if not test_run_at(v2norm, keys, at):
            continue
        if found >= 0:
            return -1
        found = at
    return found


def get_control_transfer(ext_method, cfg_method, prefix):
    parsed = parse_marked_body(ext_method["body_lines"])
    ops = parsed["ops"]
    v1norm = [code_key(x, prefix) for x in parsed["v1"]]
    v2norm = [code_key(x, prefix) for x in cfg_method["body_lines"]]
    v2sig, v2map = significant_projection(v2norm)
    v1sig = significant_projection(v1norm)[0]
    absorbed = 0
    pending = 0
    disputed = []
    temp = 0
    temp_why = None
    marked_done = 0
    # Per edit, for -Mode transfer: the result and where it goes in the configuration's body
    plan = []
    payloads = {i: [x for x in (code_key(y, prefix) for y in o["lines"]) if test_significant(x)]
                for i, o in enumerate(ops) if o["kind"] == "insert"}
    replaced = get_absorbed_in_place(ops, v1norm, v2norm, v2sig, payloads)
    deleted = set()
    for o in ops:
        if o["kind"] == "delete":
            deleted.update(range(o["start"], o["end"] + 1))
    # Lines of deletions found carried over (an insert anchored to them cannot be pending elsewhere)
    deleted_done = {}
    for oi, op in enumerate(ops):
        # res: "absorbed", "pending" or the reason the edit is disputed
        if op["kind"] == "insert":
            payload_sig = payloads[oi]
            # A comment-only insert carries nothing to transfer
            if not payload_sig:
                continue
            k = None
            if oi in replaced:
                res = "absorbed"
            else:
                after = op["after"]
                before_lines = v1norm[max(0, after - 2):after + 1] if after >= 0 else []
                after_lines = v1norm[after + 1:after + 4]
                k = resolve_insertion_point(v2norm, before_lines, after_lines)
                # The looser checks below accept the payload only as new code: the configuration has it
                # more times than the original method (an insert repeating a line next to it otherwise
                # finds that very line)
                is_new = run_count(v2sig, payload_sig) > run_count(v1sig, payload_sig)
                if k is None:
                    is_absorbed = is_new and find_unique_run(v2sig, payload_sig) >= 0
                else:
                    sig_start = sum(1 for j in v2map if j <= k)
                    is_absorbed = test_run_at(v2sig, payload_sig, sig_start)
                # Neighbours of the insert in the edited method: deleted lines are not there
                b_idx = next((z for z in range(after, -1, -1) if z not in deleted and test_significant(v1norm[z])), -1)
                a_idx = next((z for z in range(after + 1, len(v1norm)) if z not in deleted and test_significant(v1norm[z])), -1)
                b_ctx = v1norm[b_idx] if b_idx >= 0 else None
                a_ctx = v1norm[a_idx] if a_idx >= 0 else None
                # Not at the anchor: the anchor found by its line after leaves the carried-over code right
                # before the spot; otherwise the payload next to a neighbour with content, anywhere
                if not is_absorbed and is_new and k is not None:
                    is_absorbed = test_run_at(v2sig, payload_sig, sig_start - len(payload_sig))
                if not is_absorbed and is_new:
                    is_absorbed = test_payload_beside(v2sig, payload_sig, b_ctx, a_ctx)
                # Anchored to deleted lines whose deletion is carried over already: the spot is right after the
                # commented-out lines, with nothing but comments up to it and the insert's line after next.
                # Anywhere else the anchor is a look-alike, and code at the spot means the insert went over
                # differently.
                free_spot = False
                done_at = deleted_done.get(op["after"], -1)
                if k is not None and done_at >= 0 and k >= done_at:
                    free_spot = not any(test_significant(v2norm[z]) for z in range(done_at + 1, k + 1))
                    nx = next((v2norm[z] for z in range(k + 1, len(v2norm)) if test_significant(v2norm[z])), None)
                    if nx != a_ctx:
                        free_spot = False
                # Lines that stand anywhere (КонецЕсли;, Возврат;) prove nothing by being elsewhere
                plain = all(TRIVIAL_RE.search(x) for x in payload_sig)
                if is_absorbed:
                    res = "absorbed"
                elif k is not None and op["after"] in deleted_done and not free_spot:
                    res = "inserted code next to the carried-over deletion differs in config"
                # Not at the anchor, yet the configuration has the code more times than the original: carried
                # over to another spot (other code may have come in between). Writing it would make a copy.
                elif k is not None and is_new and not plain:
                    res = "inserted code is in config already, elsewhere in the method"
                elif k is not None:
                    res = "pending"
                elif b_idx >= 0:
                    res = dispute_reason("insert", parsed["v1"][b_idx], b_ctx, "before", v2norm)
                elif a_idx >= 0:
                    res = dispute_reason("insert", parsed["v1"][a_idx], a_ctx, "after", v2norm)
                else:
                    res = dispute_reason("insert", "", "", "", v2norm)
        else:
            p = -1
            if oi in replaced:
                res = "absorbed"
            else:
                keys = v1norm[op["start"]:op["end"] + 1]
                sig_keys = [x for x in keys if test_significant(x)]
                before_ctx = None
                for z in range(op["start"] - 1, -1, -1):
                    if test_significant(v1norm[z]):
                        before_ctx = v1norm[z]
                        break
                after_ctx = None
                for z in range(op["end"] + 1, len(v1norm)):
                    if test_significant(v1norm[z]):
                        after_ctx = v1norm[z]
                        break
                # Deleted text that stays in the method elsewhere — moved into an insert of the method, or one
                # of its repeats — is found by the search below even once the deletion is done. Then the
                # closed-up neighbours decide, provided the configuration holds the text as many times as
                # the original would after the edits: one less, plus the inserts that carry it.
                ins_runs = sum(run_count(payloads[pk], sig_keys) for pk in payloads)
                v1_runs = run_count(v1sig, sig_keys)
                live_left = bool(sig_keys) and run_count(v2sig, sig_keys) == v1_runs - 1 + ins_runs
                stays = live_left and (ins_runs > 0 or v1_runs > 1)
                # Commented out at its own place, and the code left as often as after the edit: carried over.
                # Looked at first — a line the edit moves into its own insert is there as code too, and
                # deleting it would break the carried-over insert. An old comment elsewhere does not count.
                c_at = find_commented_run(v2norm, sig_keys, before_ctx, after_ctx) if live_left else -1
                if c_at >= 0:
                    res = "absorbed"
                elif stays and test_delete_absorbed(v2sig, before_ctx, after_ctx):
                    res = "absorbed"
                elif find_unique_run(v2norm, keys) >= 0:
                    p = find_unique_run(v2norm, keys)
                    res = "pending"
                elif v1_runs > 1 and find_run_in_context(v2norm, v2sig, v2map, keys, sig_keys, before_ctx, after_ctx) >= 0:
                    p = find_run_in_context(v2norm, v2sig, v2map, keys, sig_keys, before_ctx, after_ctx)
                    res = "pending"
                else:
                    if test_delete_absorbed(v2sig, before_ctx, after_ctx):
                        res = "absorbed"
                    else:
                        first = next((x for x in op["lines"] if test_significant(normalize(x))), "")
                        res = dispute_reason("delete", first, "", "", v2norm)
        # Where the carried-over deletion stands in the configuration: the last commented line, -1 unknown
        if op["kind"] == "delete" and res == "absorbed":
            at = -1 if oi in replaced else c_at
            for m in range(op["start"], op["end"] + 1):
                deleted_done[m] = at
        # A block marked "not for transfer" counts as temporary only while it is not in the configuration
        mark = get_block_temp_mark(op)
        pk = k if op["kind"] == "insert" else p
        if mark is not None and res != "absorbed":
            plan.append({"op": op, "res": "temp", "at": pk})
            temp += 1
            if temp_why is None:
                temp_why = mark
            continue
        plan.append({"op": op, "res": res, "at": pk})
        if res == "absorbed":
            absorbed += 1
            if mark is not None:
                marked_done += 1
        elif res == "pending":
            pending += 1
        else:
            disputed.append(res)
    n = absorbed + pending + len(disputed)
    if n == 0:
        if temp > 0:
            return {"status": "TEMPORARY", "count": plural(temp, "edit"), "note": temp_why, "plan": plan}
        return None
    count = "%d/%d edits" % (absorbed, n)
    if temp > 0:
        count += ", %d temporary" % temp
    if disputed:
        more = " (+%d more)" % (len(disputed) - 1) if len(disputed) > 1 else ""
        return {"status": "DIVERGED", "count": count, "note": disputed[0] + more, "plan": plan}
    if absorbed == n:
        st = "TRANSFERRED"
    elif absorbed == 0:
        st = "NOT_TRANSFERRED"
    else:
        st = "PARTIAL"
    note = ("%d marked temporary" % marked_done) if marked_done else ""
    return {"status": st, "count": count, "note": note, "marked": marked_done > 0, "plan": plan}


# &Перед/&После/&Вместо and form event interceptors: there is no marked original to compare with,
# so the interceptor's code lines are looked up, in order, in the body of the target method.
# Plumbing (ПродолжитьВызов and the return of its result) is not part of the fix and is skipped;
# the interceptor's parameters are renamed to the original's by position.
TRIVIAL_RE = re.compile(r'^(?:КонецЕсли|Иначе|КонецЦикла|КонецПопытки|Исключение|Возврат|Продолжить|Прервать|EndIf|Else|EndDo|EndTry|Except|Return|Continue|Break)\s*;?$', re.IGNORECASE)


def get_heuristic_transfer(ext_method, cfg_method, prefix):
    proceed_re = re.compile(kw_alt("Proceed") + r'\s*\(', re.IGNORECASE)
    ep = ext_method["param_names"]
    cp = cfg_method["param_names"]
    # Parameters renamed in code only: a literal or a comment that mentions one stays as written, the
    # way the transfer writes it. One pass for all names: renaming one by one would rename again a
    # name already renamed when the two lists overlap (Источник, Отказ -> Отказ, Режим)
    renames = {}
    for i in range(min(len(ep), len(cp))):
        if ep[i].lower() != cp[i].lower():
            renames[ep[i].lower()] = cp[i]
    result_vars = []
    lines = []
    for l in rename_code_words(ext_method["body_lines"], renames):
        n = code_key(l, prefix)
        if not test_significant(n):
            continue
        if proceed_re.search(n):
            m = re.match(r'^([\w]+)\s*=', n)
            if m:
                result_vars.append(m.group(1))
            continue
        lines.append(n)
    if result_vars:
        ret_re = re.compile(r'^' + kw_alt("Return") + r'\s+(?:' + '|'.join(re.escape(v) for v in result_vars) + r')\s*;?$', re.IGNORECASE)
        lines = [x for x in lines if not ret_re.search(x)]
    # Block closers and bare jumps match anywhere — they would only inflate the score
    meaningful = [x for x in lines if not TRIVIAL_RE.search(x)]
    if meaningful:
        lines = meaningful
    if not lines:
        return None
    hay = sig_lines(cfg_method["body_lines"], prefix)
    found = 0
    j = 0
    for l in lines:
        for k in range(j, len(hay)):
            if hay[k] == l:
                found += 1
                j = k + 1
                break
    return {"found": found, "total": len(lines)}


def heuristic_status(h):
    if h["found"] == h["total"]:
        return "TRANSFERRED"
    if h["found"] == 0:
        return "NOT_TRANSFERRED"
    return "PARTIAL"


def new_item(status, text, loc="", group=""):
    return {"status": status, "text": text, "loc": loc, "group": group}


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


# Comparable type of an attribute: the set of its types without namespace and extension prefixes
def md_type_key(node, prefix):
    t = node.find("md:Properties/md:Type", MD_NSMAP)
    if t is None:
        return ""
    parts = []
    for c in elem_children(t):
        if localname(c) not in ("Type", "TypeSet"):
            continue
        parts.append(remove_ext_prefix(re.sub(r'^[\w]+:', '', inner_text(c).strip()), prefix))
    return " | ".join(sorted(parts))


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


def index_names(idx):
    return [r["name"] for r in idx.values()]


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


# Nearest preceding sibling of a record that the other side knows (names compared without the prefix)
def get_prev_known(rec, other_names, prefix):
    for i in range(rec["pos"] - 1, -1, -1):
        hit = find_name_in(other_names, rec["siblings"][i], prefix)
        if hit:
            return hit
    return ""


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


def lower_or_none(s):
    return s.lower() if s is not None else None


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
                had = {c.get("name") for c in bm[k][1].findall("d:Columns/d:Column", NSMAP)}
                for c in x.findall("d:Columns/d:Column", NSMAP):
                    cn = c.get("name")
                    if not cn or cn in had:
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
            r[sec].append({"name": nm, "info": info, "actions": actions, "changed": changed})

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


def move_text(ch):
    rec = ch["rec"]
    after = rec["siblings"][rec["pos"] - 1] if rec["pos"] > 0 else ""
    pos = ("after: " + after) if after else "first"
    if rec["parent"].lower() != ch["old_parent"].lower():
        to = rec["parent"] if rec["parent"] else "(form)"
        return "moved to %s (%s)" % (to, pos)
    return "moved (%s)" % pos


def event_text(e):
    ct = ("[%s]" % e["call_type"]) if e["call_type"] else ""
    scope = (e["scope"] + ".") if e["scope"] else ""
    return "%s%s%s -> %s" % (scope, e["name"], ct, e["handler"])


# Transfer check of a form diff against the form of the main configuration
def prop_transfer(cpm, p, prefix):
    """One property change of the extension against the configuration: 'ok' (the extension's
    value), 'pending' (still the BaseForm value) or 'differs' (changed in the configuration some
    other way)."""
    cv = lower_or_none(cmp_key(cpm[p["key"]], prefix)) if p["key"] in cpm else None
    nv = lower_or_none(cmp_key(p["new"], prefix))
    ov = lower_or_none(cmp_key(p["old"], prefix))
    if cv == nv:
        return "ok"
    if cv == ov:
        return "pending"
    return "differs"


def form_transfer_items(diff, form, cfg_form_xml, cfg_module_path, ext_dir, prefix):
    items = []
    group = form["label"]
    cfg_doc = read_form_doc(cfg_form_xml)
    if cfg_doc is None:
        items.append(new_item("MISSING_IN_CONFIG", "form not found in config (%d changes)" % diff["total"], "", group))
        return items
    cr = cfg_doc.getroot()
    ci = form_element_index(cr)
    c_names = index_names(ci)

    def as_text(found, orig):
        if found and found.lower() != orig.lower():
            return " (found as %s)" % found
        return ""

    # Items the form module marks "not for transfer", with everything inside them
    ext_mod = read_bsl_lines(form["module"])
    tmarks = get_form_temp_marks(ext_mod)

    def marked(it, names):
        if not it or not tmarks:
            return it
        for n in names or []:
            if n and n.lower() in tmarks:
                return set_temp_mark(it, tmarks[n.lower()], it["text"])
        return it

    for ch in diff["elements"]:
        rec = ch["rec"]
        tag = get_element_tag(rec["node"])
        hit = find_name_in(c_names, rec["name"], prefix)
        own = [rec["name"]] + list(rec["ancestors"])
        if ch["kind"] == "added":
            inn = (" (in: %s)" % rec["parent"]) if rec["parent"] else ""
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            items.append(marked(new_item(st, "+ %s %s%s%s" % (tag, rec["name"], inn, as_text(hit, rec["name"])), "", group), own))
            continue
        if ch["props"]:
            keys = [p["key"] for p in ch["props"]]
            if not hit:
                items.append(marked(new_item("NOT_TRANSFERRED", "~ %s %s: %s (element not in config)" % (tag, rec["name"], ", ".join(keys)), "", group), own))
            else:
                cpm = get_prop_map(ci[hit.lower()]["node"])
                ok = 0
                differs = []
                for p in ch["props"]:
                    r = prop_transfer(cpm, p, prefix)
                    if r == "ok":
                        ok += 1
                    elif r == "differs":
                        differs.append(p["key"])
                n = len(ch["props"])
                if differs:
                    st = "DIVERGED"
                else:
                    st = "TRANSFERRED" if ok == n else ("NOT_TRANSFERRED" if ok == 0 else "PARTIAL")
                if st == "DIVERGED" and len(differs) == n:
                    cnt = " (config value differs)"
                elif st == "DIVERGED":
                    cnt = " (config value differs: %s)" % ", ".join(differs)
                else:
                    cnt = (" (%d/%d props)" % (ok, n)) if st == "PARTIAL" else ""
                items.append(marked(new_item(st, "~ %s %s: %s%s" % (tag, rec["name"], ", ".join(keys), cnt), "", group), own))
        if ch["moved"]:
            st = "NOT_TRANSFERRED"
            if hit:
                crec = ci[hit.lower()]
                same_parent = remove_ext_prefix(crec["parent"], prefix).lower() == remove_ext_prefix(rec["parent"], prefix).lower()
                want = get_prev_known(rec, c_names, prefix)
                have = get_prev_known(crec, index_names(diff["main_index"]), prefix)
                have_mapped = (find_name_in(c_names, have, prefix) or "") if have else ""
                if same_parent and want.lower() == have_mapped.lower():
                    st = "TRANSFERRED"
            items.append(marked(new_item(st, "> %s %s: %s" % (tag, rec["name"], move_text(ch)), "", group), own))

    # Interceptor of a handler: the extension's handler code looked up in the configuration's one
    cfg_mod = read_bsl_lines(cfg_module_path)
    mod_rel = rel_path(ext_dir, form["module"]) if form["module"] and os.path.isfile(form["module"]) else ""

    def check_handler(label, ext_handler, cfg_handler, missing):
        ext_m = get_method_safe(ext_mod, ext_handler)
        loc = ("%s:%d" % (mod_rel, ext_m["decl_idx"] + 1)) if ext_m and mod_rel else ""
        mark = get_method_temp_mark(ext_mod, ext_m) if ext_m else None
        if not cfg_handler:
            return set_temp_mark(new_item("NOT_TRANSFERRED", "%s (%s)" % (label, missing), loc, group), mark, label)
        cfg_m = get_method_safe(cfg_mod, cfg_handler)
        if not ext_m:
            return new_item("NOT_TRANSFERRED", label + " (handler not found in extension module)", loc, group)
        if not cfg_m:
            return set_temp_mark(new_item("NOT_TRANSFERRED", "%s (config handler %s not found in module)" % (label, cfg_handler), loc, group), mark, label)
        h = get_heuristic_transfer(ext_m, cfg_m, prefix)
        if not h:
            return None
        return set_temp_mark(new_item(heuristic_status(h), "%s (heuristic: %d/%d lines)" % (label, h["found"], h["total"]), loc, group), mark, label)

    for sec, item, word in (("Attributes", "Attribute", "attribute"), ("Commands", "Command", "command"), ("Parameters", "Parameter", "parameter")):
        if not diff[sec]:
            continue
        cm = section_map(cr, sec, item)
        cn = [v[0] for v in cm.values()]
        for x in diff[sec]:
            # A configuration command the extension intercepts (its action carries callType): kept in
            # BaseForm (changed) or not, so "absent from BaseForm" alone does not make it the extension's own
            ct_acts = [a for a in x["actions"] if a["call_type"]]
            if item == "Command" and ct_acts and (x["name"].lower() in cm or x.get("changed")):
                cfg_act = cm[x["name"].lower()][1].find("d:Action", NSMAP) if x["name"].lower() in cm else None
                cfg_handler = inner_text(cfg_act).strip() if cfg_act is not None else ""
                for a in ct_acts:
                    it = check_handler("command %s[%s] -> %s" % (x["name"], a["call_type"], a["handler"]), a["handler"], cfg_handler,
                                       "no action of %s in config" % x["name"])
                    if it:
                        items.append(marked(it, [x["name"]]))
                continue
            hit = find_name_in(cn, x["name"], prefix)
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            items.append(marked(new_item(st, "+ %s %s%s%s" % (word, x["name"], x["info"], as_text(hit, x["name"])), "", group), [x["name"]]))

    # Columns the extension adds to an attribute of the configuration
    if diff["columns"]:
        am = section_map(cr, "Attributes", "Attribute")
        an = [v[0] for v in am.values()]
        for c in diff["columns"]:
            label = "+ column %s.%s%s" % (c["attr"], c["name"], c["info"])
            ah = find_name_in(an, c["attr"], prefix)
            if not ah:
                items.append(marked(new_item("NOT_TRANSFERRED", label + " (attribute not in config)", "", group), [c["attr"], "%s.%s" % (c["attr"], c["name"])]))
                continue
            cols = [x.get("name") for x in am[ah.lower()][1].findall("d:Columns/d:Column", NSMAP)]
            hit = find_name_in(cols, c["name"], prefix)
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            items.append(marked(new_item(st, label + as_text(hit, c["name"]), "", group), [c["attr"], "%s.%s" % (c["attr"], c["name"])]))

    if diff["form_props"]:
        cpm = get_prop_map(cr, root=True)
        for p in diff["form_props"]:
            r = prop_transfer(cpm, p, prefix)
            st = {"ok": "TRANSFERRED", "pending": "NOT_TRANSFERRED"}.get(r, "DIVERGED")
            why = " (config value differs)" if r == "differs" else ""
            items.append(new_item(st, "~ form " + prop_change_text(p) + why, "", group))
    # Conditional appearance rules: an added one must be among the configuration's rules, a removed one not
    if diff["appearance"]:
        have = [cmp_key(x, prefix) for x in cr.findall("d:Attributes/d:ConditionalAppearance/dcsset:item", NSMAP)]
        for a in diff["appearance"]:
            inn = cmp_key(a["node"], prefix) in have
            done = inn if a["kind"] == "added" else not inn
            mk = "+" if a["kind"] == "added" else "-"
            items.append(new_item("TRANSFERRED" if done else "NOT_TRANSFERRED", "%s conditional appearance rule %s" % (mk, appearance_text(a["node"])), "", group))
    for b in diff["blocks"]:
        cnode = cr.find(b["xpath"], NSMAP)
        st = "TRANSFERRED" if lower_or_none(cmp_key(cnode, prefix)) == lower_or_none(cmp_key(b["node"], prefix)) else "NOT_TRANSFERRED"
        items.append(new_item(st, "~ " + b["name"], "", group))

    for e in diff["events"]:
        target = None
        if e["scope"]:
            hit = find_name_in(c_names, e["scope"], prefix)
            if hit:
                target = ci[hit.lower()]["node"]
        else:
            target = cr
        cfg_handler = ""
        if target is not None:
            for ce in event_list(target):
                if ce["name"].lower() == e["name"].lower():
                    cfg_handler = ce["handler"]
                    break
        it = check_handler("event " + event_text(e), e["handler"], cfg_handler, "no %s handler in config" % e["name"])
        if it:
            items.append(marked(it, [e["scope"]]))
    # An element of BaseForm the main part lacks: the extension cannot drop a borrowed element, so the
    # configuration's form has changed since the borrowing
    for nm in diff["removed"]:
        items.append(new_item("DIVERGED", "! %s (in BaseForm, not in the extension's form: the configuration's form changed since the borrowing)" % nm, "", group))
    return items


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
# Transfer check of one object
# ============================================================

def module_transfer_items(bsl, ext_dir, config_path, prefix, skip_handlers):
    items = []
    ext_lines = read_bsl_lines(bsl)
    if ext_lines is None:
        return items
    rel = rel_path(ext_dir, bsl)
    cfg_lines = read_bsl_lines(os.path.join(config_path, rel))
    mc = get_module_changes(ext_lines, skip_handlers)
    for x in mc["interceptors"]:
        ic = x["ic"]
        decl = x["decl"]
        label = '&%s("%s")' % (ic["raw"], ic["method"])
        loc = "%s:%d" % (rel, ic["line"] + 1)
        ext_m = get_method_safe(ext_lines, decl["name"]) if decl else None
        mark = get_method_temp_mark(ext_lines, ext_m, ic["type"] == "ИзменениеИКонтроль") if ext_m else None
        cfg_m = get_method_safe(cfg_lines, ic["method"])
        it = None
        plan = {"kind": "missing", "rel": rel, "ext_m": ext_m, "cfg_m": cfg_m, "label": label}
        if not cfg_m:
            why = "module not found in config" if cfg_lines is None else "method not found in config"
            it = new_item("MISSING_IN_CONFIG", "%s (%s)" % (label, why), loc)
            plan["why"] = why
        elif not ext_m:
            it = new_item("DIVERGED", label + " (cannot parse the interceptor)", loc)
            plan["why"] = "cannot parse the interceptor"
        elif ic["type"] == "ИзменениеИКонтроль":
            r = get_control_transfer(ext_m, cfg_m, prefix)
            if r:
                note = (" (%s)" % r["note"]) if r["note"] else ""
                it = new_item(r["status"], "%s — %s%s" % (label, r["count"], note), loc)
                if r.get("marked") and r["status"] == "TRANSFERRED":
                    it["marked"] = True
                plan["kind"] = "control"
                plan["ops"] = r["plan"]
        else:
            h = get_heuristic_transfer(ext_m, cfg_m, prefix)
            if h:
                it = new_item(heuristic_status(h), "%s (heuristic: %d/%d lines)" % (label, h["found"], h["total"]), loc)
            plan["kind"] = "intercept"
            plan["type"] = ic["type"]
        if it:
            it["plan"] = plan
        if it:
            items.append(set_temp_mark(it, mark, label))
    cfg_names = get_proc_names(cfg_lines) if cfg_lines is not None else []
    for od in mc["own"]:
        pn = od["name"]
        ext_m = get_method_safe(ext_lines, pn)
        if not ext_m:
            continue
        loc = "%s:%d" % (rel, ext_m["decl_idx"] + 1)
        mark = get_method_temp_mark(ext_lines, ext_m)
        # Every method of the module the name may stand for; the one with the same body wins (a name
        # given with the development prefix next to a vendor method of the plain name)
        hits = find_names_in(cfg_names, pn, prefix)
        hit = None
        cfg_m = None
        if not hits:
            it = new_item("NOT_TRANSFERRED", "method " + pn, loc)
        else:
            ext_sig = "\n".join(sig_lines(ext_m["body_lines"], prefix))
            same = False
            for h in hits:
                m = get_method_safe(cfg_lines, h)
                if m and "\n".join(sig_lines(m["body_lines"], prefix)).lower() == ext_sig.lower():
                    hit, cfg_m, same = h, m, True
                    break
            if not same:
                hit = hits[0]
                cfg_m = get_method_safe(cfg_lines, hit)
            as_ = (" (found as %s)" % hit) if hit.lower() != pn.lower() else ""
            if same:
                it = new_item("TRANSFERRED", "method %s%s" % (pn, as_), loc)
            else:
                it = new_item("DIVERGED", "method %s%s (body differs)" % (pn, as_), loc)
        it["plan"] = {"kind": "own", "rel": rel, "ext_m": ext_m, "ext_lines": ext_lines, "cfg_m": cfg_m, "name": pn, "hit": hit, "cfg_missing": cfg_lines is None}
        items.append(set_temp_mark(it, mark, "method " + pn))
    # Code outside methods (module variables, statements of the module body): its lines looked up among
    # the configuration module's code outside methods, prefixes left out; order is not compared. A line
    # counts once: a variable declared twice in the extension is declared once in the configuration.
    if mc["top_code"] >= 0:
        ext_top = list(dict.fromkeys(get_top_key(l, prefix) for l in get_top_code_lines(ext_lines)))
        have = {get_top_key(l, prefix) for l in get_top_code_lines(cfg_lines)} if cfg_lines is not None else set()
        found = sum(1 for k in ext_top if k in have)
        st = heuristic_status({"found": found, "total": len(ext_top)})
        it = new_item(st, "module code outside methods (heuristic: %d/%d lines)" % (found, len(ext_top)), "%s:%d" % (rel, mc["top_code"] + 1))
        it["plan"] = {"kind": "topcode", "rel": rel, "line": mc["top_code"], "ext_lines": ext_lines}
        items.append(it)
    return items


def get_module_layout(lines):
    """Layout of a module's code outside methods, in one walk: each Перем line with the directive and comment
    lines right above it (vars: start, idx, names, depth — of #Если nesting), the other code lines
    (statements: indexes), the last Перем before the methods at the methods' #Если depth, the first method
    with the directive and comment lines above it, the line after the last method."""
    decl_re = re.compile(r'^\s*(?:' + kw_alt("Async") + r'\s+)?(?:' + kw_alt("Proc") + '|' + kw_alt("Func")
                         + r')\s+[\w]+\s*\(', re.IGNORECASE)
    end_re = re.compile(r'^\s*(?:' + kw_alt("EndProc") + '|' + kw_alt("EndFunc") + r')\b', re.IGNORECASE)
    vars_, stmts = [], []
    first_method = -1
    method_depth = 0
    after_methods = 0
    in_proc = False
    depth = 0

    def lead(i):
        s = i
        while s > 0 and re.match(r'^(//|&)', lines[s - 1].strip()):
            s -= 1
        return s

    for i, line in enumerate(lines):
        t = line.strip()
        if in_proc:
            if end_re.match(t):
                in_proc = False
                after_methods = i + 1
            continue
        if decl_re.match(t):
            in_proc = True
            if first_method < 0:
                first_method = lead(i)
                method_depth = depth
            continue
        if re.match(r'^#(Если|If)(?!\w)', t, re.IGNORECASE):
            depth += 1
            continue
        if re.match(r'^#(КонецЕсли|EndIf)(?!\w)', t, re.IGNORECASE):
            depth = max(0, depth - 1)
            continue
        if t == "" or t.startswith("//") or t.startswith("&") or t.startswith("#"):
            continue
        if re.match(IC_VAR_RE, t, re.IGNORECASE):
            names = []
            m = re.match(IC_VAR_RE + r'\s+([^;]*)', t, re.IGNORECASE)
            if m:
                for v in m.group(1).split(","):
                    parts = v.strip().split()
                    if parts:
                        names.append(parts[0])
            vars_.append({"start": lead(i), "idx": i, "names": names, "depth": depth, "before_methods": first_method < 0})
        else:
            stmts.append(i)
    # New variables go after the last one declared where the methods are: one in a #Если block of its
    # own (#Если Клиент …) would carry them into that block
    last_var = -1
    for v in vars_:
        if v["before_methods"] and (first_method < 0 or v["depth"] == method_depth):
            last_var = v["idx"]
    return {"vars": vars_, "statements": stmts, "last_var": last_var, "first_method": first_method, "after_methods": after_methods}


def get_top_code_lines(lines):
    """Code lines of a module outside its methods (not blank, not comments, annotations or preprocessor
    lines), trimmed."""
    lay = get_module_layout(lines)
    idx = sorted([v["idx"] for v in lay["vars"]] + lay["statements"])
    return [lines[i].strip() for i in idx]


def get_top_key(line, prefix):
    """Comparable form of a line of code outside methods: no trailing comment, prefixes left out."""
    return code_key(get_code_only([line], True)[0], prefix)


# Own sub-objects of a borrowed object (attributes, tabular sections, commands, forms, templates, …)
def own_child_items(ctx, cfg_md, prefix):
    items = []
    if ctx["md"] is None or ctx["md"]["children"] is None:
        return items
    cfg_kids = elem_children(cfg_md["children"]) if cfg_md is not None and cfg_md["children"] is not None else []

    def check(node, label, cfg_pool, path):
        nm = md_child_name(node)
        cands = [c for c in cfg_pool if localname(c) == localname(node)]
        hit = find_name_in([md_child_name(c) for c in cands], nm, prefix)
        full = (path + "." + nm) if path else nm
        if not hit:
            return new_item("NOT_TRANSFERRED", "%s %s" % (label, full))
        as_ = (" (found as %s)" % hit) if hit.lower() != nm.lower() else ""
        if node.find("md:Properties/md:Type", MD_NSMAP) is not None:
            cnode = [c for c in cands if md_child_name(c).lower() == hit.lower()][0]
            a = md_type_key(node, prefix)
            b = md_type_key(cnode, prefix)
            if a.lower() != b.lower():
                return new_item("DIVERGED", "%s %s%s (type: %s vs %s in config)" % (label, full, as_, a, b))
        return new_item("TRANSFERRED", "%s %s%s" % (label, full, as_))

    for c in elem_children(ctx["md"]["children"]):
        if not has_element_child(c):
            # <Form>Имя</Form>, <Template>Имя</Template>: ownership is in the sub-object descriptor
            nm = inner_text(c).strip()
            desc = read_md_object(os.path.join(ctx["obj_dir"], localname(c) + "s", nm + ".xml"))
            if desc is not None and test_adopted_node(desc["props"]):
                continue
            hit = find_name_in([inner_text(x).strip() for x in cfg_kids if localname(x) == localname(c)], nm, prefix)
            as_ = (" (found as %s)" % hit) if hit and hit.lower() != nm.lower() else ""
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            items.append(new_item(st, "%s %s%s" % (kind_word(localname(c)), nm, as_)))
            continue
        if not test_adopted_node(c):
            items.append(check(c, kind_word(localname(c)), cfg_kids, ""))
            continue
        # Borrowed tabular section: its own attributes
        sub = c.find("md:ChildObjects", MD_NSMAP)
        if sub is None:
            continue
        ts_name = md_child_name(c)
        cfg_ts = [x for x in cfg_kids if localname(x) == localname(c) and md_child_name(x).lower() == ts_name.lower()]
        cfg_sub = []
        if cfg_ts:
            cs = cfg_ts[0].find("md:ChildObjects", MD_NSMAP)
            if cs is not None:
                cfg_sub = elem_children(cs)
        for sc in elem_children(sub):
            if test_adopted_node(sc):
                continue
            items.append(check(sc, kind_word(localname(sc)), cfg_sub, ts_name))
    return items


def transfer_object(ext, obj, cfg_info, config_path):
    ctx = get_obj_context(ext["dir"], obj["type"], obj["name"])
    rec = {"id": "%s.%s" % (obj["type"], obj["name"]), "items": []}
    if not ctx["known"] or not ctx["exists"]:
        return rec
    prefix = ext["prefix"]
    if not ctx["borrowed"]:
        pool = []
        if cfg_info["child_objects"] is not None:
            pool = [(c.text or "").strip() for c in elem_children(cfg_info["child_objects"]) if localname(c) == obj["type"]]
        hit = find_name_in(pool, obj["name"], prefix)
        as_ = (" (found as %s)" % hit) if hit and hit.lower() != obj["name"].lower() else ""
        rec["items"].append(new_item("TRANSFERRED" if hit else "NOT_TRANSFERRED", "own object" + as_))
        return rec
    cfg_md = read_md_object(os.path.join(config_path, ctx["dir"], obj["name"] + ".xml"))
    forms = get_obj_forms(ctx)
    diffs = {}
    form_items = []
    for f in forms:
        if f["own"]:
            continue
        d = get_form_diff(f["xml"])
        if d is None or not d["is_borrowed"]:
            continue
        diffs[path_key(f["module"])] = d
        if d["total"] == 0:
            continue
        rel = rel_path(ext["dir"], f["xml"])
        cfg_form = os.path.join(config_path, rel)
        cfg_module = os.path.join(config_path, rel_path(ext["dir"], f["module"]))
        # Dialog changes have no line of their own: their file is the form's Form.xml
        for fi in form_transfer_items(d, f, cfg_form, cfg_module, ext["dir"], prefix):
            if not fi["loc"]:
                fi["section"] = rel
            form_items.append(fi)
    for bsl in get_obj_modules(ctx, forms):
        k = path_key(bsl)
        skip = call_type_handlers(diffs[k]) if k in diffs else set()
        rec["items"] += module_transfer_items(bsl, ext["dir"], config_path, prefix, skip)
    rec["items"] += own_child_items(ctx, cfg_md, prefix)
    if obj["type"] == "Subsystem":
        rec["items"] += subsystem_content_items(ctx["md"], cfg_md, prefix)
    rec["items"] += form_items
    # Section = the file the change lives in (a module line, the form's Form.xml, the object's own
    # XML for its sub-objects); the item then keeps only its line number
    obj_rel = rel_path(ext["dir"], ctx["file"])
    for it in rec["items"]:
        m = re.match(r'^(.+):(\d+)$', it["loc"] or "")
        if m:
            it["section"] = m.group(1)
            it["loc"] = ":" + m.group(2)
        elif not it.get("section"):
            it["section"] = obj_rel
    if cfg_md is None and rec["items"]:
        # Temporary changes stay apart: they are not for transfer, missing object or not
        temp = [it for it in rec["items"] if it["status"] == "TEMPORARY"]
        rest = len(rec["items"]) - len(temp)
        rec["items"] = []
        if rest > 0:
            rec["items"].append(new_item("MISSING_IN_CONFIG", "object not found in config (%s)" % plural(rest, "change")))
        rec["items"] += temp
    return rec


# ============================================================
# Module declarations and subsystem content
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


def subsystem_content_items(md, cfg_md, prefix):
    """Transfer of a borrowed subsystem's content: each object the extension adds must be in the
    content of the configuration's subsystem (own names compared with and without the prefix)."""
    items = []
    cfg = get_subsystem_content(cfg_md)
    for ref in get_subsystem_content(md):
        typ, _, nm = ref.partition(".")
        pool = [c.partition(".")[2] for c in cfg if c.partition(".")[0] == typ]
        hit = find_name_in(pool, nm, prefix)
        as_ = (" (found as %s.%s)" % (typ, hit)) if hit and hit.lower() != nm.lower() else ""
        items.append(new_item("TRANSFERRED" if hit else "NOT_TRANSFERRED", "content " + ref + as_))
    return items


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


# ============================================================
# Transfer: writing into the configuration (-Mode transfer)
# ============================================================

# --- support-guard copies (verbatim from cf-edit, kept identical by check-inline-drift) ---
def _sg_root_uuid(xml_path):
    if not os.path.isfile(xml_path):
        return None
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str) and child.get("uuid"):
                return child.get("uuid")
    except Exception:
        return None
    return None


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


def _sg_get_edit_mode(cfg_dir):
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(os.path.abspath(cfg_dir))
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        # configSrc — от каталога .v8-project.json, а не от рабочего каталога: иначе из подкаталога
        # проекта база не сопоставляется и берётся правило проекта. Пути — настоящие (realpath):
        # на macOS /var — ссылка на /private/var, и getcwd с путём аргумента иначе не совпадут.
        proj_dir = os.path.dirname(pj)
        cfg_full = os.path.normcase(os.path.realpath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.realpath(os.path.join(proj_dir, src))).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"



# Run state of -Mode transfer (set in main)
SETTINGS = {"dev_prefix": []}
DEV_RE = None
NAME_MAP = {}
TRANSFER_PREFIX = ""
SUPPORT_INFO = {"g": 0, "k": 0, "map": {}, "mode": "deny"}
FILE_EDITS = {}
EDIT_SEQ = [0]

# Role of an own method -> region, by the module structure standard; a project overrides any of them
# in cfeTransfer.regions with a name or a list of names (the first one the module has wins)
REGION_DEFAULTS = [
    ("formEvents", ["ОбработчикиСобытийФормы"]),
    ("headerItemEvents", ["ОбработчикиСобытийЭлементовШапкиФормы"]),
    ("tableItemEvents", ["ОбработчикиСобытийЭлементовТаблицыФормы{table}"]),
    ("commands", ["ОбработчикиКомандФормы"]),
    ("notifications", ["ОбработчикиОповещений", "СлужебныеПроцедурыИФункции"]),
    ("objectEvents", ["ОбработчикиСобытий"]),
    ("api", ["ПрограммныйИнтерфейс"]),
    ("service", ["СлужебныеПроцедурыИФункции"]),
]
REGION_ORDER = [k for k, _ in REGION_DEFAULTS]

# Events of object, manager and record set modules (both spellings): their handlers go to objectEvents
OBJECT_EVENT_NAMES = {x.lower() for x in (
    "ПередЗаписью", "ПриЗаписи", "ОбработкаЗаполнения", "ОбработкаПроверкиЗаполнения", "ПриКопировании",
    "ПередУдалением", "ОбработкаПроведения", "ОбработкаУдаленияПроведения", "ПриУстановкеНовогоКода",
    "ПриУстановкеНовогоНомера", "ОбработкаПолученияДанныхВыбора", "ОбработкаПолученияФормы",
    "ОбработкаПолученияПредставления", "ОбработкаПолученияПолейПредставления", "ПриКомпоновкеРезультата",
    "BeforeWrite", "OnWrite", "Filling", "FillCheckProcessing", "OnCopy", "BeforeDelete", "Posting",
    "UndoPosting", "OnSetNewCode", "OnSetNewNumber", "ChoiceDataGetProcessing", "FormGetProcessing",
    "PresentationGetProcessing", "PresentationFieldsGetProcessing", "OnComposeResult")}


def _same_or_under(path, root):
    a = os.path.normcase(os.path.abspath(path)).rstrip("\\/")
    b = os.path.normcase(os.path.abspath(root)).rstrip("\\/")
    return a == b or a.startswith(b + os.sep)


class _CIDict(dict):
    """A JSON object read the way the .ps1 reads it: keys are case-insensitive."""
    def __init__(self, src):
        super().__init__()
        for k, v in src.items():
            super().__setitem__(str(k).lower(), _ci_json(v))

    def __getitem__(self, k):
        return super().__getitem__(str(k).lower())

    def __contains__(self, k):
        return super().__contains__(str(k).lower())

    def get(self, k, d=None):
        return super().get(str(k).lower(), d)


def _ci_json(v):
    if isinstance(v, dict):
        return _CIDict(v)
    if isinstance(v, list):
        return [_ci_json(x) for x in v]
    return v


def get_transfer_settings(cfg_dir):
    """Project settings: the database record whose configSrc holds the configuration, else the
    project level. devPrefix — the project's development prefixes; cfeTransfer — keys on its top level
    apply to both kinds of objects, its vendor/own sections refine them."""
    proj = None
    db = None
    pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(os.path.abspath(cfg_dir))
    if pj:
        try:
            proj = _ci_json(json.loads(open(pj, encoding="utf-8-sig").read()))
        except Exception as e:
            die("Cannot read %s: %s" % (pj, e))
        proj_dir = os.path.dirname(pj)
        for d in (proj.get("databases") or []) if isinstance(proj, dict) else []:
            if not isinstance(d, dict) or not d.get("configSrc"):
                continue
            if _same_or_under(cfg_dir, os.path.join(proj_dir, d["configSrc"])):
                db = d
                break

    def pick(key):
        if db is not None and key in db:
            return db[key]
        if isinstance(proj, dict) and key in proj:
            return proj[key]
        return None

    dp = pick("devPrefix")
    if dp is None:
        dp = []
    elif not isinstance(dp, list):
        dp = [dp]
    res = {"dev_prefix": [str(x) for x in dp if x]}
    ct = pick("cfeTransfer")
    if not isinstance(ct, dict):
        ct = {}
    for kind in ("vendor", "own"):
        e = {"insert_comment": None, "deletion": "comment", "create_regions": kind == "own",
             "regions": {k: list(v) for k, v in REGION_DEFAULTS}, "add_dev_objects": True, "add_dev_methods": False}
        for src in (ct, ct.get(kind)):
            if not isinstance(src, dict):
                continue
            if "insertComment" in src:
                e["insert_comment"] = src["insertComment"]
            if "deletion" in src:
                e["deletion"] = str(src["deletion"]).lower()
            if "createRegions" in src:
                e["create_regions"] = bool(src["createRegions"])
            if isinstance(src.get("regions"), dict):
                for k, v in src["regions"].items():
                    k = next((r for r in e["regions"] if r.lower() == k.lower()), k)
                    e["regions"][k] = [str(x) for x in (v if isinstance(v, list) else [v])]
            if isinstance(src.get("addDevPrefix"), dict):
                if "objects" in src["addDevPrefix"]:
                    e["add_dev_objects"] = bool(src["addDevPrefix"]["objects"])
                if "methods" in src["addDevPrefix"]:
                    e["add_dev_methods"] = bool(src["addDevPrefix"]["methods"])
        if e["deletion"] not in ("comment", "remove"):
            die("cfeTransfer.deletion: expected comment or remove, got '%s'" % e["deletion"])
        res[kind] = e
    return res


def get_template_vars(ext_dir, cp, tag):
    """Values for the comment template, from the extension's properties."""
    root = read_xml(os.path.join(ext_dir, "Configuration.xml")).getroot()
    props = root.find(".//md:Configuration/md:Properties", MD_NSMAP)

    def txt(n):
        x = props.find("md:" + n, MD_NSMAP) if props is not None else None
        return (x.text or "").strip() if x is not None else ""

    syn = ""
    if props is not None:
        for it in props.findall("md:Synonym/*", MD_NSMAP):
            if localname(it) != "item":
                continue
            lang = next((c for c in it if isinstance(c.tag, str) and localname(c) == "lang"), None)
            content = next((c for c in it if isinstance(c.tag, str) and localname(c) == "content"), None)
            if content is None:
                continue
            if not syn:
                syn = (content.text or "").strip()
            if lang is not None and (lang.text or "").strip() == "ru":
                syn = (content.text or "").strip()
                break
    prefix = cp["prefix"] or ""
    return {"name": cp["name"] or "", "synonym": syn, "version": txt("Version"), "vendor": txt("Vendor"),
            "prefix": prefix, "prefixBare": prefix.rstrip("_"), "tag": tag}


# .NET date format (as in the .ps1) -> strftime: the tokens a date template needs
_DATE_TOKENS = [("yyyy", "%Y"), ("yy", "%y"), ("MM", "%m"), ("dd", "%d"), ("HH", "%H"), ("mm", "%M"), ("ss", "%S"),
                ("M", "%-m"), ("d", "%-d"), ("H", "%-H")]


def format_date(fmt):
    import datetime
    now = datetime.datetime.now()
    out = []
    i = 0
    while i < len(fmt):
        for tok, _ in _DATE_TOKENS:
            if fmt.startswith(tok, i):
                if tok == "M":
                    out.append(str(now.month))
                elif tok == "d":
                    out.append(str(now.day))
                elif tok == "H":
                    out.append(str(now.hour))
                else:
                    out.append(now.strftime(dict(_DATE_TOKENS)[tok]))
                i += len(tok)
                break
        else:
            out.append(fmt[i])
            i += 1
    return "".join(out)


def expand_template(tpl, vars_):
    """A comment line from a template: {name} {synonym} {version} {vendor} {prefix} {prefixBare} {tag},
    {date} or {date:<.NET format>}; a template that is not a comment yet becomes one."""
    low = {k.lower(): v for k, v in vars_.items()}

    def ev(m):
        k = m.group(1).lower()
        if k == "date":
            return format_date(m.group(2) if m.group(2) is not None else "dd.MM.yyyy")
        if k in low:
            return str(low[k] if low[k] is not None else "")
        return m.group(0)
    out = re.sub(r'\{(\w+)(?::([^}]*))?\}', ev, tpl)
    if not out.lstrip().startswith("//"):
        out = "// " + out
    return out


def get_frame(set_, vars_):
    """Begin/end comment lines of a kind of object (None when the project frames nothing)."""
    ic = set_["insert_comment"]
    b = e = None
    if isinstance(ic, dict):
        if ic.get("begin"):
            b = expand_template(str(ic["begin"]), vars_)
        if ic.get("end"):
            e = expand_template(str(ic["end"]), vars_)
    return {"begin": b, "end": e}


def get_support_info(cfg_dir):
    """Support settings of the configuration, read once: capability (g), objects on support (k), the
    support state per object uuid (0 locked, 1 editable with support, 2 taken off support)."""
    info = {"g": 0, "k": 0, "map": {}, "mode": _sg_get_edit_mode(cfg_dir)}
    path = os.path.join(cfg_dir, "Ext", "ParentConfigurations.bin")
    if not os.path.exists(path):
        return info
    data = open(path, "rb").read()
    if len(data) <= 32:
        return info
    if data[:3] == b"\xef\xbb\xbf":
        data = data[3:]
    text = data.decode("utf-8", "replace")
    h = re.match(r"\{6,(\d+),(\d+),", text)
    if not h:
        return info
    info["g"] = int(h.group(1))
    info["k"] = int(h.group(2))
    for m in re.finditer(r"([0-2]),0,([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})", text):
        u = m.group(2).lower()
        f = int(m.group(1))
        if u not in info["map"] or f < info["map"][u]:
            info["map"][u] = f
    return info


def get_object_support(xml_path):
    """Support state of a configuration object: locked (the support settings forbid editing it), vendor
    (on support) or own (taken off support, created in the configuration, no support at all).
    editingAllowedCheck lifts the lock, as for the editing skills: warn — the object is 'warn' (on
    support, edited with a note in the report), off — plain 'vendor'."""
    si = SUPPORT_INFO
    if si["k"] == 0:
        return "own"
    lock = "vendor" if si["mode"] == "off" else ("warn" if si["mode"] == "warn" else "locked")
    if si["g"] == 1:
        return lock
    u = _sg_root_uuid(xml_path)
    f = si["map"].get(u.lower()) if u else None
    if f is None or f == 2:
        return "own"
    if f == 0:
        return lock
    return "vendor"


def has_dev_prefix(name):
    return any(name.lower().startswith(p.lower()) for p in SETTINGS["dev_prefix"])


def get_object_kind(obj_name, support):
    """Own or vendor: by the development prefix in the object's name when the project has one, else by support."""
    if SETTINGS["dev_prefix"]:
        return "own" if has_dev_prefix(remove_ext_prefix(obj_name, TRANSFER_PREFIX)) else "vendor"
    return "own" if support == "own" else "vendor"


def get_target_name(name, prefix, taken, add_dev):
    """Name in the configuration for an own name of the extension: without the extension prefix; taken ->
    with the development prefix; taken too -> as it is. add_dev puts the development prefix first.
    taken — lower-case names of the target (module or object) plus those given in this run."""
    bare = remove_ext_prefix(name, prefix) if prefix else name
    dp = SETTINGS["dev_prefix"]
    with_dev = (dp[0] + bare) if dp and not has_dev_prefix(bare) else None
    if add_dev and with_dev:
        cands = [with_dev]
    else:
        cands = [bare] + ([with_dev] if with_dev else [])
    for i, c in enumerate(cands):
        if c.lower() in taken:
            continue
        note = ""
        if i > 0:
            note = "as %s: %s exists" % (c, cands[0])
        elif c != name:
            note = "as " + c
        return {"name": c, "note": note}
    verb = "exist" if len(cands) > 1 else "exists"
    if name.lower() in taken:
        return {"name": name, "taken": True, "note": "%s %s" % (", ".join(cands), verb)}
    return {"name": name, "note": "kept prefix: %s %s" % (", ".join(cands), verb)}


CALL_RE = re.compile(r'(?<![\w.])(\w+)\s*\(')


def get_called_names(lines, skip):
    """Names called as functions (not methods of an object: no dot before them), lower case, without
    those in skip (the extension's own methods: calling them is not a global name)."""
    sk = {n.lower() for n in skip if n}
    res = set()
    for t in get_code_only(lines, True):
        for m in CALL_RE.finditer(t):
            k = m.group(1).lower()
            if k not in sk:
                res.add(k)
    return res


def convert_ext_code(lines, file_map):
    """Code of the extension as the configuration gets it: a name from the map (per file, then for the
    whole run) becomes its target, any other identifier with the extension prefix loses the prefix."""
    prefix = TRANSFER_PREFIX
    keys = set()
    for m in (file_map, NAME_MAP):
        for k in m:
            if not prefix or not k.startswith(prefix.lower()):
                keys.add(re.escape(k))
    alts = sorted(keys, key=lambda x: (-len(x), x))
    if prefix:
        alts.append(re.escape(prefix) + r'\w+')
    if not alts:
        return list(lines)
    rx = re.compile(r'(?<!\w)(?:' + "|".join(alts) + r')(?!\w)', re.IGNORECASE)

    def ev(m):
        k = m.group(0).lower()
        if k in file_map:
            return file_map[k]
        if k in NAME_MAP:
            return NAME_MAP[k]
        if prefix and k.startswith(prefix.lower()):
            return m.group(0)[len(prefix):]
        return m.group(0)
    return [rx.sub(ev, l) for l in lines]


def get_regions(lines):
    """Regions of a module, nested ones included: {name, start, end} (line indexes of the markers)."""
    re_region = re.compile(r'^\s*#' + kw_alt("Region") + r'\s+(\S+)', re.IGNORECASE)
    re_end = re.compile(r'^\s*#' + kw_alt("EndRegion") + r'(?!\w)', re.IGNORECASE)
    stack = []
    res = []
    for i, t in enumerate(lines):
        m = re_region.match(t)
        if m:
            stack.append({"name": m.group(1), "start": i, "end": -1})
        elif re_end.match(t) and stack:
            r = stack.pop()
            r["end"] = i
            res.append(r)
    return res


def get_module_kind(rel):
    r = rel.replace("\\", "/")
    if re.search(r'/Ext/Form/Module\.bsl$', r):
        return "form"
    if r.startswith("CommonModules/"):
        return "common"
    if re.search(r'/Ext/(?:ObjectModule|ManagerModule|RecordSetModule|ValueManagerModule)\.bsl$', r):
        return "object"
    return "other"


def _load_xml_root(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        return etree.parse(path).getroot()
    except Exception:
        return None


def _in_base_form(node, root):
    n = node
    while n is not None and n is not root:
        if isinstance(n.tag, str) and localname(n) == "BaseForm":
            return True
        n = n.getparent()
    return False


def get_form_bindings(form_xml):
    """Handlers a form binds (its own part, BaseForm left out): lower-case name -> {role, table}."""
    res = {}
    root = _load_xml_root(form_xml)
    if root is None:
        return res

    def put(h, role, table):
        if not h:
            return
        k = h.strip().lower()
        if k in res and REGION_ORDER.index(res[k]["role"]) <= REGION_ORDER.index(role):
            return
        res[k] = {"role": role, "table": table}

    for ev in root.iter():
        if not isinstance(ev.tag, str) or localname(ev) != "Event":
            continue
        owner = ev.getparent().getparent()
        in_base = False
        table = ""
        n = owner
        while n is not None and n is not root:
            if localname(n) == "BaseForm":
                in_base = True
                break
            if not table and localname(n) == "Table":
                table = n.get("name") or ""
            n = n.getparent()
        if in_base:
            continue
        role = "formEvents" if owner is root else ("tableItemEvents" if table else "headerItemEvents")
        put(ev.text or "", role, table)
    for a in root.iter():
        if not isinstance(a.tag, str) or localname(a) != "Action":
            continue
        p = a.getparent()
        if p is None or localname(p) != "Command" or _in_base_form(a, root):
            continue
        put(a.text or "", "commands", "")
    return res


NOTIFY_RE = re.compile(r'(?:Новый|New)\s+(?:ОписаниеОповещения|NotifyDescription)\s*\(\s*"(\w+)"', re.IGNORECASE)


def get_notify_names(lines):
    """Procedures a module names in Новый ОписаниеОповещения("Имя", ...)."""
    res = set()
    for l in lines:
        for m in NOTIFY_RE.finditer(l):
            res.add(m.group(1).lower())
    return res


def is_export(lines, m):
    t = lines[m["sig_end_idx"]]
    i = t.rfind(")")
    return i >= 0 and re.match(r'\s*(?:Экспорт|Export)(?!\w)', t[i + 1:], re.IGNORECASE) is not None


def get_method_role(name, kind, bind, notify, export):
    """Role of an own method: the first one by the order of the regions table."""
    k = name.lower()
    if kind == "form" and k in bind:
        return {"role": bind[k]["role"], "table": bind[k]["table"]}
    if kind == "form" and k in notify:
        return {"role": "notifications", "table": ""}
    if kind == "object" and k in OBJECT_EVENT_NAMES:
        return {"role": "objectEvents", "table": ""}
    if export and kind != "form":
        return {"role": "api", "table": ""}
    return {"role": "service", "table": ""}


def get_method_place(cfg_lines, regions, ext_m, role, set_, created):
    """Where an own method goes in the configuration's module. First the region it sits in, in the
    extension, if the module has it — unless that is the service region and the method has a role of
    its own (a service region often collects everything); then the region of the role; then a new one
    (createRegions), the service region, the end of the module."""
    # {table}: the table's name as the configuration gets it
    table = convert_ext_code([role["table"]], {})[0] if role["table"] else ""

    def names(r):
        return [str(x).replace("{table}", table) for x in set_["regions"].get(r, [])]

    def find(n):
        return next((r for r in regions if r["name"].lower() == n.lower()), None)

    service = names("service")
    chain = [c for c in ext_m["chain"] if c["kind"] == "region"]
    for c in reversed(chain):
        r = find(c["name"])
        if r is None:
            continue
        if role["role"] != "service" and r["name"].lower() in [x.lower() for x in service]:
            break
        return {"at": r["end"], "region": r["name"]}
    role_names = names(role["role"])
    for n in role_names:
        r = find(n)
        if r is not None:
            return {"at": r["end"], "region": r["name"]}
    for n in role_names:
        if n.lower() in created:
            return {"create": n}
    if set_["create_regions"] and role_names:
        return {"create": role_names[0]}
    for n in service:
        r = find(n)
        if r is not None:
            return {"at": r["end"], "region": r["name"]}
    return {"at": get_module_end(cfg_lines), "region": ""}


def get_module_end(lines):
    """Where methods appended to a module go: before the statements of the module body after the last method
    (a method after them would not compile), else the module's tail (get_module_tail)."""
    tail = get_module_tail(lines)
    lay = get_module_layout(lines)
    body = [i for i in lay["statements"] if lay["after_methods"] <= i < tail]
    if not body:
        return tail
    s = body[0]
    while s > 0 and re.match(r'^(//|&)', lines[s - 1].strip()):
        s -= 1
    return s


def get_module_tail(lines):
    """The tail of a module, where statements of the module body are added after the existing ones: its end,
    or — in a module wrapped whole in #Если Сервер ... Тогда ... [#Иначе ВызватьИсключение ...] #КонецЕсли —
    before the wrapper's #Иначе (#КонецЕсли when it has none): after the wrapper the code would not compile."""
    n = len(lines)

    def skip(t):
        t = t.strip()
        return t == "" or t.startswith("//")

    def pp(t, words):
        return re.match(r'^\s*#(' + words + r')(?!\w)', t, re.I) is not None

    i = n - 1
    while i >= 0 and skip(lines[i]):
        i -= 1
    if i < 0 or not pp(lines[i], "КонецЕсли|EndIf"):
        return n
    depth = 0
    els = -1
    for j in range(i, -1, -1):
        t = lines[j]
        if pp(t, "КонецЕсли|EndIf"):
            depth += 1
        elif pp(t, "Если|If"):
            depth -= 1
            if depth > 0:
                continue
            # A wrapper only when nothing but comments stands above it
            if any(not skip(lines[k]) for k in range(j)):
                return n
            return els if els >= 0 else i
        elif depth == 1 and pp(t, "Иначе|ИначеЕсли|Else|ElsIf"):
            els = j
    return n


def get_module_lang(lines):
    """Language of a module's keywords: the first region or method declaration decides (Russian without any)."""
    for l in lines:
        if re.match(r'^\s*(#Область|Процедура|Функция)(?!\w)', l, re.I):
            return "ru"
        if re.match(r'^\s*(#Region|Procedure|Function)(?!\w)', l, re.I):
            return "en"
    return "ru"


def read_bsl_file(path):
    """A .bsl file read for writing back as it was: BOM, line breaks, final line break."""
    data = open(path, "rb").read()
    bom = data[:3] == b"\xef\xbb\xbf"
    text = data[3:].decode("utf-8", "replace") if bom else data.decode("utf-8", "replace")
    eol = "\r\n" if "\r\n" in text else ("\n" if "\n" in text else "\r\n")
    final = text.endswith("\n") or text.endswith("\r")
    lines = re.split(r'\r\n|\n|\r', text) if text != "" else []
    if final and lines:
        lines = lines[:-1]
    return {"path": path, "lines": lines, "bom": bom, "eol": eol, "final": final}


def write_bsl_file(f, lines):
    text = f["eol"].join(lines)
    if f["final"]:
        text += f["eol"]
    with open(f["path"], "wb") as fh:
        fh.write((b"\xef\xbb\xbf" if f["bom"] else b"") + text.encode("utf-8"))


def get_indent(line):
    m = re.match(r'^(\s*)', line)
    return m.group(1) if m else ""


def get_control_body(cfg_m, plan, frame, deletion, file_map):
    """The pending edits of an &ИзменениеИКонтроль method laid onto the configuration's body: inserts
    after their anchor, deletions removed or commented out, each framed by the project's comments."""
    v2 = list(cfg_m["body_lines"])
    ins_after = {}
    del_at = {}
    for e in plan:
        if e["res"] != "pending":
            continue
        if e["op"]["kind"] == "insert":
            ins_after.setdefault(int(e["at"]), []).append(e["op"])
        else:
            del_at[int(e["at"])] = e["op"]["end"] - e["op"]["start"] + 1
    out = []

    def emit_ins(op):
        lines = convert_ext_code(op["lines"], file_map)
        first = next((l for l in lines if l.strip() != ""), None)
        ind = get_indent(first) if first is not None else get_indent(op.get("open") or "")
        if frame["begin"]:
            out.append(ind + frame["begin"])
        # A note on the opening marker (#Вставка // why) stays with the code
        if op.get("open"):
            ci = op["open"].find("//")
            if ci >= 0:
                out.append(ind + op["open"][ci:].strip())
        out.extend(lines)
        if frame["end"]:
            out.append(ind + frame["end"])

    for op in ins_after.get(-1, []):
        emit_ins(op)
    i = 0
    while i < len(v2):
        if i in del_at:
            n = del_at[i]
            if deletion == "comment":
                first = next((l for l in v2[i:i + n] if l.strip() != ""), None)
                ind = get_indent(first) if first is not None else ""
                if frame["begin"]:
                    out.append(ind + frame["begin"])
                for j in range(i, i + n):
                    out.append("//" + v2[j])
                if frame["end"]:
                    out.append(ind + frame["end"])
            for j in range(i, i + n):
                for op in ins_after.get(j, []):
                    emit_ins(op)
            i += n
            continue
        out.append(v2[i])
        for op in ins_after.get(i, []):
            emit_ins(op)
        i += 1
    return out


# ============================================================
# &Перед / &После / &Вместо: the handler's code put into the original's body
# ============================================================

def get_code_only(lines, keep_strings=False):
    """Each line's code without comments; string literals are kept (keep_strings) or left as "" — a
    literal that runs on over lines (the | continuation) is followed from line to line."""
    res = []
    in_str = False
    for s in lines:
        s = s or ""
        out = []
        i = 0
        while i < len(s):
            c = s[i]
            if in_str:
                if c == '"':
                    if i + 1 < len(s) and s[i + 1] == '"':
                        if keep_strings:
                            out.append('""')
                        i += 2
                        continue
                    in_str = False
                    out.append('"')
                elif keep_strings:
                    out.append(c)
                i += 1
                continue
            if c == '"':
                in_str = True
                out.append('"')
                i += 1
                continue
            if c == '/' and i + 1 < len(s) and s[i + 1] == '/':
                break
            out.append(c)
            i += 1
        res.append("".join(out))
    return res


def rename_code_words(lines, mapping):
    """Words renamed in code only (not in literals or comments, not after a dot): mapping lower-case -> new."""
    if not mapping:
        return list(lines)
    rx = re.compile(r'(?<![\w.])(?:' + "|".join(re.escape(k) for k in mapping) + r')(?!\w)', re.IGNORECASE)

    def sub(t):
        return rx.sub(lambda m: mapping[m.group(0).lower()], t)

    out = []
    in_str = False
    for s in lines:
        s = s or ""
        res = []
        code = []
        i = 0
        while i < len(s):
            c = s[i]
            if in_str:
                res.append(c)
                if c == '"':
                    if i + 1 < len(s) and s[i + 1] == '"':
                        res.append('"')
                        i += 2
                        continue
                    in_str = False
                i += 1
                continue
            if c == '"' or (c == '/' and i + 1 < len(s) and s[i + 1] == '/'):
                res.append(sub("".join(code)))
                code = []
                if c == '"':
                    in_str = True
                    res.append(c)
                    i += 1
                    continue
                res.append(s[i:])
                i = len(s)
                break
            code.append(c)
            i += 1
        res.append(sub("".join(code)))
        out.append("".join(res))
    return out


IC_OPEN_RE = re.compile(r'(?<![\w.])(?:Если|If|Для|For|Пока|While|Попытка|Try)(?!\w)', re.IGNORECASE)
IC_CLOSE_RE = re.compile(r'(?<![\w.])(?:КонецЕсли|EndIf|КонецЦикла|EndDo|КонецПопытки|EndTry)(?!\w)', re.IGNORECASE)
IC_RET_RE = re.compile(r'(?<![\w.])(?:Возврат|Return)(?!\w)', re.IGNORECASE)
IC_PROCEED_RE = re.compile(r'(?<![\w.])(?:ПродолжитьВызов|ProceedWithCall)\s*\(', re.IGNORECASE)
IC_VAR_RE = r'^\s*(?:Перем|Var)(?!\w)'
IC_BARE_RET_RE = re.compile(r'^(?:Возврат|Return)\s*;?$', re.IGNORECASE)
# Where one statement ends and the next may start within a line
IC_STMT_RE = re.compile(r';|(?<![\w.])(?:Тогда|Иначе|Цикл|Попытка|Исключение|Then|Else|Do|Try|Except)(?!\w)', re.IGNORECASE)


def test_bare_term(shape, code, i):
    """Is line i the terminal Возврат of a body, and a bare one (without a value)?"""
    return i == shape["term"] and IC_BARE_RET_RE.match(code[i].strip()) is not None


def get_body_shape(code):
    """Shape of a body from its code lines: block depth before each line, Возврат on it (inside a block
    when the line opens one too); the last line with code and whether it is a lone Возврат at the top
    level (the terminal one)."""
    n = len(code)
    depth = [0] * n
    ret = [False] * n
    in_block = [False] * n
    d = 0
    last = -1
    for i, t in enumerate(code):
        depth[i] = d
        o = len(IC_OPEN_RE.findall(t))
        c = len(IC_CLOSE_RE.findall(t))
        if IC_RET_RE.search(t):
            ret[i] = True
            in_block[i] = d > 0 or o > 0
        d = max(0, d + o - c)
        tt = t.strip()
        if tt != "" and not tt.startswith("#"):
            last = i
    term = -1
    if last >= 0 and ret[last] and not in_block[last] and re.match(r'^(?:Возврат|Return)(?!\w)[^;]*;?$', code[last].strip(), re.IGNORECASE):
        term = last
    return {"ret": ret, "in_block": in_block, "depth": depth, "last": last, "term": term}


def get_local_names(code, params):
    """Local variables of a body (assigned, loop variables, Перем), parameters left out: lower -> name.
    A line may hold several statements (Если … Тогда Х = 1; КонецЕсли;): each is looked at."""
    skip = {p.lower() for p in params}
    res = {}

    def add(n):
        if n and n.lower() not in skip and n.lower() not in res:
            res[n.lower()] = n

    for line in code:
        for t in IC_STMT_RE.split(line):
            m = re.match(r'^\s*([\w]+)\s*=', t)
            if m:
                add(m.group(1))
            m = re.match(r'^\s*(?:Для\s+Каждого|For\s+Each)\s+([\w]+)', t, re.IGNORECASE)
            if m:
                add(m.group(1))
            else:
                m = re.match(r'^\s*(?:Для|For)\s+([\w]+)\s*=', t, re.IGNORECASE)
                if m:
                    add(m.group(1))
        m = re.match(IC_VAR_RE + r'\s+([^;]*)', line, re.IGNORECASE)
        if m:
            for v in m.group(1).split(","):
                parts = v.strip().split()
                add(parts[0] if parts else "")
    return res


def get_assigned_names(code):
    """Names a body assigns to (any statement of a line), lower case."""
    res = set()
    for line in code:
        for t in IC_STMT_RE.split(line):
            m = re.match(r'^\s*([\w]+)\s*=', t)
            if m:
                res.add(m.group(1).lower())
            # A loop variable is assigned too
            m = (re.match(r'^\s*(?:Для\s+Каждого|For\s+Each)\s+([\w]+)', t, re.IGNORECASE)
                 or re.match(r'^\s*(?:Для|For)\s+([\w]+)\s*=', t, re.IGNORECASE))
            if m:
                res.add(m.group(1).lower())
    return res


def get_val_flags(params_text):
    """Знач of each parameter, by position."""
    if not params_text.strip():
        return []
    rx = re.compile(r'^\s*' + kw_alt("Val") + r'\s', re.IGNORECASE)
    return [bool(rx.match(seg)) for seg in split_top_level(params_text)]


def get_word_set(code):
    return {m.group(0).lower() for t in code for m in re.finditer(r'\w+', t)}


def get_framed(lines, frame):
    """Lines framed by the project's comments, at the indent of their first code line."""
    first = next((l for l in lines if l.strip() != ""), None)
    ind = get_indent(first) if first is not None else ""
    out = []
    if frame["begin"]:
        out.append(ind + frame["begin"])
    out.extend(lines)
    if frame["end"]:
        out.append(ind + frame["end"])
    return out


def get_removed(lines, frame, deletion):
    """Original lines that leave: commented out and framed, or gone (deletion = remove)."""
    if deletion != "comment":
        return []
    return get_framed(["//" + l for l in lines], frame)


def get_trimmed(lines):
    """Blank lines off both ends."""
    s = 0
    e = len(lines) - 1
    while s <= e and lines[s].strip() == "":
        s += 1
    while e >= s and lines[e].strip() == "":
        e -= 1
    return list(lines[s:e + 1]) if s <= e else []


def get_var_end(lines, code):
    """Index of the last Перем line in the leading run of Перем, blank and comment lines (-1: none)."""
    end = -1
    for i in range(len(lines)):
        t = code[i].strip()
        if t == "":
            continue
        if re.match(IC_VAR_RE, t, re.IGNORECASE):
            end = i
            continue
        break
    return end


def get_intercept_ops(ext_m, cfg_m, type_, frame, deletion, file_map):
    """Edits that put an interceptor's code into the original's body, as insertions after an index of
    the original's body (-1: at the top) and replacements of a range of it; or the reason it cannot be done."""
    if bool(ext_m.get("is_async")) != bool(cfg_m.get("is_async")):
        return {"why": "Асинх differs between the handler and the original"}
    ep = list(ext_m["param_names"])
    cp = list(cfg_m["param_names"])
    if len(ep) != len(cp):
        return {"why": "parameters differ from the original's"}
    # The platform does not apply an interceptor whose Знач differs from the original's: its code never ran
    cv = get_val_flags(cfg_m["params_text"])
    if get_val_flags(ext_m["params_text"]) != cv:
        return {"why": "the interceptor never applied: Знач differs from the original's",
                "next": "fix the signature in the extension or drop the interceptor, then re-run -Mode check"}
    val_names = [cp[i].lower() for i in range(len(cp)) if cv[i]]
    mapping = {ep[i].lower(): cp[i] for i in range(len(ep)) if ep[i] != cp[i]}
    h = convert_ext_code(rename_code_words(ext_m["body_lines"], mapping), file_map)
    o = list(cfg_m["body_lines"])
    hc = get_code_only(h)
    oc = get_code_only(o)
    hs = get_body_shape(hc)
    os_ = get_body_shape(oc)
    o_var = get_var_end(o, oc)

    def clash():
        # A local of the handler the original also names, or the other way round, becomes one variable
        hl = get_local_names(hc, cp)
        ol = get_local_names(oc, cp)
        hw = get_word_set(hc)
        ow = get_word_set(oc)
        names = []
        for n in [hl[k] for k in hl if k in ow] + [ol[k] for k in ol if k in hw]:
            if n not in names:
                names.append(n)
        return ("variable %s is in both the handler and the original" % ", ".join(names)) if names else None

    def o_early():
        # The original's Возврат lines other than a bare terminal one: code put after its body would be skipped
        return any(os_["ret"][i] and not test_bare_term(os_, oc, i) for i in range(len(o)))

    def o_tail():
        # Where code goes after the original's body: before its bare terminal Возврат, else after its last line
        end = os_["term"] if os_["term"] >= 0 and test_bare_term(os_, oc, os_["term"]) else len(o)
        for i in range(end - 1, -1, -1):
            if o[i].strip() != "":
                return i
        return o_var

    def split(frm, to, drop_term):
        # A handler part: its Перем lines go up to the original's, the rest stays in place
        vars_, rest = [], []
        for i in range(frm, to + 1):
            if drop_term and test_bare_term(hs, hc, i):
                continue
            if re.match(IC_VAR_RE, hc[i], re.IGNORECASE):
                vars_.append(h[i])
            else:
                rest.append(h[i])
        return {"vars": vars_, "code": get_trimmed(rest)}

    ops = []

    # Rank orders edits at one spot, whatever interceptor they come from: Перем, then code that runs
    # before the original, then code that runs after it
    def put(after, part, rank):
        if part["vars"]:
            ops.append({"kind": "insert", "after": o_var, "lines": get_framed(part["vars"], frame), "rank": 0})
        if part["code"]:
            ops.append({"kind": "insert", "after": after, "lines": get_framed(part["code"], frame), "rank": rank})

    # What the handler's code names: another interceptor of the method must not share its locals
    def done(where):
        return {"ops": ops, "where": where, "locals": get_local_names(hc, cp), "words": get_word_set(hc)}

    last = len(h) - 1

    def val_check(side, frm):
        # Знач parameters: the handler and the original each had a copy. What one of them changed the
        # other did not see; in one body it would.
        def shown(names):
            return ", ".join(next(p for p in cp if p.lower() == n) for n in names)
        if side == "handler":
            assigned = get_assigned_names(hc)
            names = [n for n in val_names if n in assigned]
            if names:
                return "the handler changes Знач parameter %s: the original did not see it" % shown(names)
        else:
            assigned = get_assigned_names(oc)
            words = get_word_set(hc[frm:last + 1])
            names = [n for n in val_names if n in assigned and n in words]
            if names:
                return "the original changes Знач parameter %s: the handler did not see it" % shown(names)
        return None

    if type_ in ("Перед", "После"):
        if cfg_m["is_function"]:
            return {"why": "a function cannot have &Перед/&После"}
        why = clash()
        if why:
            return {"why": why}
        if type_ == "Перед":
            for i in range(last + 1):
                if hs["ret"][i] and not test_bare_term(hs, hc, i):
                    return {"why": "Возврат in the handler would skip the original"}
            why = val_check("handler", 0)
            if why:
                return {"why": why}
            put(o_var, split(0, last, True), 1)
            return done("before the original")
        if o_early():
            return {"why": "the original returns early: the code after it would be skipped"}
        why = val_check("original", 0)
        if why:
            return {"why": why}
        put(o_tail(), split(0, last, True), 2)
        return done("after the original")
    # &Вместо
    calls = [i for i in range(last + 1) if IC_PROCEED_RE.search(hc[i])]
    if not calls:
        new = get_framed(get_trimmed(h), frame)
        if o:
            ops.append({"kind": "replace", "start": 0, "end": len(o) - 1, "lines": get_removed(o, frame, deletion) + new, "rank": 1})
        else:
            ops.append({"kind": "insert", "after": -1, "lines": new, "rank": 1})
        return done("in place of the original")
    if len(calls) > 1:
        return {"why": "ПродолжитьВызов is called more than once"}
    c = calls[0]
    if hs["depth"][c] > 0 or IC_OPEN_RE.search(hc[c]):
        return {"why": "ПродолжитьВызов sits inside a block"}
    ct = hc[c].strip()
    var = None
    m = re.match(r'^(?:ПродолжитьВызов|ProceedWithCall)\s*\((.*)\)\s*;?$', ct, re.IGNORECASE)
    if m:
        kind, arg_text = "call", m.group(1)
    else:
        m = re.match(r'^([\w]+)\s*=\s*(?:ПродолжитьВызов|ProceedWithCall)\s*\((.*)\)\s*;?$', ct, re.IGNORECASE)
        if m:
            kind, var, arg_text = "assign", m.group(1), m.group(2)
        else:
            m = re.match(r'^(?:Возврат|Return)\s+(?:ПродолжитьВызов|ProceedWithCall)\s*\((.*)\)\s*;?$', ct, re.IGNORECASE)
            if not m:
                return {"why": "ПродолжитьВызов is part of an expression"}
            kind, arg_text = "return", m.group(1)
    given = [a.strip().lower() for a in split_top_level(arg_text)] if arg_text.strip() else []
    if given != [p.lower() for p in cp]:
        return {"why": "ПродолжитьВызов gets other arguments than the parameters"}
    why = clash()
    if why:
        return {"why": why}
    why = val_check("original", c + 1)
    if why:
        return {"why": why}
    before = split(0, c - 1, False)
    after = split(c + 1, last, kind == "call")
    if kind == "call":
        if cfg_m["is_function"]:
            return {"why": "the result of ПродолжитьВызов is not used"}
        if after["code"] and o_early():
            return {"why": "the original returns early: the code after it would be skipped"}
        put(o_var, before, 1)
        put(o_tail(), after, 2)
        return done("around the original")
    if not cfg_m["is_function"]:
        return {"why": "ПродолжитьВызов of a procedure gives no value"}
    if kind == "return":
        if after["code"]:
            return {"why": "the code after Возврат ПродолжитьВызов is never reached"}
        put(o_var, before, 1)
        put(o_var, {"vars": after["vars"], "code": []}, 0)
        return done("around the original")
    # Р = ПродолжитьВызов(…): the original's one Возврат, at its end, gives Р its value
    rets = [i for i in range(len(o)) if os_["ret"][i]]
    r = os_["term"]
    raw = get_code_only([o[r]], True)[0].strip() if r >= 0 else ""
    m = re.match(r'^(?:Возврат|Return)\s+(.+?)\s*;?$', raw, re.IGNORECASE)
    if len(rets) != 1 or r < 0 or not m:
        return {"why": "the original returns other than by one Возврат at its end"}
    put(o_var, before, 1)
    put(o_var, {"vars": after["vars"], "code": []}, 0)
    set_lines = get_framed(["%s%s = %s;" % (get_indent(o[r]), var, m.group(1))] + after["code"], frame)
    ops.append({"kind": "replace", "start": r, "end": r, "lines": get_removed([o[r]], frame, deletion) + set_lines, "rank": 2})
    return done("around the original")


def get_intercept_body(body, ops):
    """The original's body with interceptor edits laid on it."""
    ins = {}
    rep = {}
    # At one spot: by rank, then in the order they came (a stable sort, the same in both ports)
    for op in sorted(ops, key=lambda x: x.get("rank", 0)):
        if op["kind"] == "insert":
            ins.setdefault(int(op["after"]), []).append(op)
        else:
            rep[int(op["start"])] = op
    out = []
    for op in ins.get(-1, []):
        out.extend(op["lines"])
    i = 0
    while i < len(body):
        if i in rep:
            op = rep[i]
            out.extend(op["lines"])
            for j in range(op["start"], op["end"] + 1):
                for x in ins.get(j, []):
                    out.extend(x["lines"])
            i = op["end"] + 1
            continue
        out.append(body[i])
        for x in ins.get(i, []):
            out.extend(x["lines"])
        i += 1
    return out


def get_missing_names(ext_names, cfg_names):
    """Names the extension declares and the configuration does not have yet, under any prefix (lower-case
    name -> name): code that uses them waits until those objects, sub-objects or form items are there."""
    have = {get_name_key(n, TRANSFER_PREFIX).lower() for n in cfg_names if n}
    res = {}
    for n in ext_names:
        if not n:
            continue
        if get_name_key(n, TRANSFER_PREFIX).lower() not in have:
            res[n.lower()] = n
    return res


def get_form_item_names(form_xml):
    """Named items of a form (elements, attributes, commands, parameters), its BaseForm left out."""
    root = _load_xml_root(form_xml)
    if root is None:
        return []
    return [n.get("name") for n in root.iter() if isinstance(n.tag, str) and n.get("name") is not None and not _in_base_form(n, root)]


def add_out_name(by_file, common, cfg_file, rel, name):
    """A method that is not coming, for the code that calls it: by its name in its own module; a common
    module's method also as Модуль.Метод for the other modules (a bare name there is someone else's).
    Returns True when it is new."""
    dst = by_file.setdefault(cfg_file.lower(), {})
    new = name.lower() not in dst
    dst[name.lower()] = name
    if get_module_kind(rel) == "common":
        mod = rel.replace("\\", "/").split("/")[1]
        common[(mod + "." + name).lower()] = mod + "." + name
    return new


def get_used_missing(lines, missing):
    """Missing names the code uses (comments left out): the sorted original names. The extension's code
    names its own things as the extension does, so a word matches by the very name: a plain Товары is
    not the extension's Расш_Товары."""
    if not missing:
        return []
    hit = set()
    for t in get_code_only(lines, True):
        for m in re.finditer(r'\w+', t):
            k = m.group(0).lower()
            if k in missing:
                hit.add(missing[k])
        # A common module's method called from another module: Модуль.Метод
        for m in re.finditer(r'(\w+)\s*\.\s*(\w+)', t):
            k = (m.group(1) + "." + m.group(2)).lower()
            if k in missing:
                hit.add(missing[k])
    # Ordinal, case-insensitive (as StringComparer.OrdinalIgnoreCase in the .ps1, which upper-cases)
    return sorted(hit, key=lambda x: x.upper())


def get_control_result_gap(plan, body):
    """The new body of an &ИзменениеИКонтроль method, compared again: every edit must come out absorbed,
    the way the check sees it after the write — the ones laid now and the ones already there (lines an
    edit moves within the method reappear in its insert, and a deletion then looks undone again).
    Returns the number of edits the check would still see as not transferred."""
    r2 = get_control_transfer(plan["ext_m"], {"body_lines": list(body)}, TRANSFER_PREFIX)
    before = plan["ops"]
    if not r2:
        return len(before)
    after = r2["plan"]
    if len(after) != len(before):
        return len(before)
    return sum(1 for b, a in zip(before, after) if b["res"] in ("pending", "absorbed") and a["res"] != "absorbed")


def test_own_result(plan, fe, file_map):
    """An own method after the transfer, seen by the check: found by its name, with the same body."""
    names = get_proc_names(fe["file"]["lines"]) + list(fe["given"])
    if not any(h.lower() == plan["target"]["name"].lower() for h in find_names_in(names, plan["name"], TRANSFER_PREFIX)):
        return False
    conv = convert_ext_code(plan["ext_m"]["body_lines"], file_map)
    return "\n".join(sig_lines(plan["ext_m"]["body_lines"], TRANSFER_PREFIX)).lower() == "\n".join(sig_lines(conv, TRANSFER_PREFIX)).lower()


def get_own_method_block(ext_lines, ext_m, frame, file_map):
    """An own method as the configuration gets it: the description comments above it, the directive, the
    declaration through Конец*; names converted; begin comment on top, end comment on the Конец* line."""
    start = ext_m["decl_idx"]
    if start >= 1 and is_context_directive(ext_lines[start - 1].strip()):
        start -= 1
    while start >= 1 and ext_lines[start - 1].strip().startswith("//"):
        start -= 1
    conv = convert_ext_code(ext_lines[start:ext_m["body_end_idx"] + 1], file_map)
    out = []
    if frame["begin"]:
        out.append(frame["begin"])
    out.extend(conv)
    if frame["end"]:
        out[-1] = out[-1] + " " + frame["end"]
    return out


def get_file_edits(path):
    """Edits of one configuration file, collected over the run and written once."""
    key = path.lower()
    if key not in FILE_EDITS:
        f = read_bsl_file(path)
        FILE_EDITS[key] = {"file": f, "repl": [], "create": {}, "create_order": [], "own_at": {}, "tail": [], "regions": get_regions(f["lines"]), "layout": get_module_layout(f["lines"]), "given": set()}
    return FILE_EDITS[key]


def write_file_edits():
    """All collected edits written: replacements from the bottom up (indexes stay valid; inserts at one
    spot keep the order they came in), own methods put at one spot as one block, then regions created
    at the end of the module."""
    changed = []
    for fe in FILE_EDITS.values():
        if not fe["repl"] and not fe["create"] and not fe["own_at"] and not fe["tail"]:
            continue
        lines = list(fe["file"]["lines"])
        repl = list(fe["repl"])
        for at, o in fe["own_at"].items():
            blk = []
            for b in o["blocks"]:
                if blk:
                    blk.append("")
                blk.extend(b)
            repl.append({"start": at, "end": at, "lines": get_spaced_block(fe["file"]["lines"], at, blk), "seq": o["seq"]})
        for r in sorted(repl, key=lambda x: (x["start"], x["seq"]), reverse=True):
            lines[r["start"]:r["end"]] = list(r["lines"])
        if fe["create_order"]:
            lang = get_module_lang(fe["file"]["lines"])
            end_at = get_module_end(lines)
            prev = lines[end_at - 1] if end_at > 0 else ""
            add = []
            for name in fe["create_order"]:
                if add or prev.strip() != "":
                    add.append("")
                add.append("#%s %s" % (BSL_KW[lang]["Region"], name))
                for blk in fe["create"][name]:
                    add.append("")
                    add.extend(blk)
                add.append("")
                add.append("#" + BSL_KW[lang]["EndRegion"])
            if end_at < len(lines) and lines[end_at].strip() != "":
                add.append("")
            lines[end_at:end_at] = add
        # Statements of the module body: after the configuration's own, at the tail
        for blk in fe["tail"]:
            at = get_module_tail(lines)
            lines[at:at] = get_spaced_block(lines, at, blk)
        write_bsl_file(fe["file"], lines)
        changed.append(fe["file"]["path"])
    return changed


def get_spaced_block(lines, at, block):
    """Lines around the spot: one blank line between the block and its neighbours."""
    res = []
    if at > 0 and lines[at - 1].strip() != "":
        res.append("")
    res.extend(block)
    if at < len(lines) and lines[at].strip() != "":
        res.append("")
    return res


def new_titem(status, text, loc, section):
    return {"status": status, "text": text, "loc": loc, "section": section, "group": "", "sub": []}


def get_where_lines(plan, next_):
    """from/to/next lines of a change the skill leaves to a person."""
    sub = []
    if plan and plan.get("ext_m"):
        sub.append("from: extension %s:%d-%d" % (plan["rel"], plan["ext_m"]["decl_idx"] + 1, plan["ext_m"]["body_end_idx"] + 1))
    if plan and plan.get("cfg_m"):
        cm = plan["cfg_m"]
        kw = BSL_KW[cm["lang"]]["Func"] if cm["is_function"] else BSL_KW[cm["lang"]]["Proc"]
        sub.append("to:   config %s:%d (%s %s)" % (plan["rel"], cm["decl_idx"] + 1, kw, cm["canonical"]))
    if next_:
        sub.append("next: " + next_)
    return sub

# ============================================================
# Run
# ============================================================

# -Expand: a section is opened by its object (Type.Name), a path from the section headers (prefix,
# so a form folder opens its Form.xml and Module.bsl) or * for all. A logical name as other skills
# take it (Type.Name.Form.F, Type.Name.ObjectModule) is turned into that path.
TYPE_DIR_LOWER = {k.lower(): v for k, v in CHILD_TYPE_DIR_MAP.items()}


def get_expand_prefix(token):
    t = token.strip()
    if re.search(r'[\\/]', t):
        return t.replace("\\", "/").rstrip("/").lower()
    parts = t.split(".")
    if len(parts) < 3 or parts[0].lower() not in TYPE_DIR_LOWER:
        return None
    base = "%s/%s" % (TYPE_DIR_LOWER[parts[0].lower()], parts[1])
    if parts[2].lower() == "form":
        return ("%s/Forms/%s" % (base, parts[3])).lower() if len(parts) >= 4 else base.lower()
    if parts[2].lower() == "command":
        return ("%s/Commands/%s" % (base, parts[3])).lower() if len(parts) >= 4 else base.lower()
    return ("%s/Ext/%s.bsl" % (base, parts[2])).lower()


def test_expanded(ext, obj_id, section, expand_list):
    for t in expand_list:
        if t == "*" or t.lower() == obj_id.lower():
            return True
        p = get_expand_prefix(t)
        if not p or not section:
            continue
        s = section.lower()
        full = os.path.join(ext["dir"], section).replace("\\", "/").lower()
        for c in (s, full):
            if c == p or c.startswith(p + "/"):
                return True
    return False


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


def get_transfer_details(ext, rec, expand_list, fold_word="transferred"):
    """Details of an object in transfer, grouped by the file each change lives in. A plain
    transferred change folds into "… N transferred" unless its section is expanded (one marked
    temporary stays in sight); a section with nothing else left is one line, and so is a form whose
    files all are."""
    lines = []
    folded = 0
    order = []
    by_sec = {}
    for it in rec["items"]:
        s = it.get("section") or ""
        if s not in by_sec:
            by_sec[s] = []
            order.append(s)
        by_sec[s].append(it)
    view = {}
    any_open = False
    for s in order:
        opened = test_expanded(ext, rec["id"], s, expand_list)
        if opened:
            any_open = True
        shown = [it for it in by_sec[s] if opened or it["status"] != "TRANSFERRED" or it.get("marked") or it.get("now")]
        view[s] = {"shown": shown, "hidden": len(by_sec[s]) - len(shown)}

    def emit(s):
        v = view[s]
        pad = "      " if s else "    "
        if s:
            if not v["shown"]:
                lines.append("    %s: %d %s" % (s, v["hidden"], fold_word))
                return
            lines.append("    %s:" % s)
        for it in v["shown"]:
            loc = ("  " + it["loc"]) if it["loc"] else ""
            lines.append("%s%s%s%s" % (pad, fmt_status(it["status"]), it["text"], loc))
            for sl in it.get("sub") or []:
                if sl:
                    lines.append("%s    %s" % (pad, sl))
        if v["hidden"] > 0:
            lines.append("%s… %d %s" % (pad, v["hidden"], fold_word))

    lay = section_layout(order)
    for s in lay["plain"]:
        emit(s)
        folded += view[s]["hidden"]
    for f in lay["forms"]:
        fd = f["dir"]
        secs = f["secs"]
        hidden = sum(view[s]["hidden"] for s in secs)
        shown = sum(len(view[s]["shown"]) for s in secs)
        folded += hidden
        if shown == 0:
            lines.append("    %s: %d %s" % (fd, hidden, fold_word))
            continue
        for s in secs:
            emit(s)
    return {"lines": lines, "folded": folded, "open": any_open}


STATUS_ORDER = ["TRANSFERRED", "NOT_TRANSFERRED", "PARTIAL", "DIVERGED", "MISSING_IN_CONFIG", "TEMPORARY"]


def fmt_status(st):
    return ("[%s]" % st).ljust(21)


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
    global SETTINGS, DEV_RE, NAME_MAP, TRANSFER_PREFIX, SUPPORT_INFO
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Transfer of 1C configuration extension (CFE) changes into the main configuration: check and transfer", allow_abbrev=False)
    parser.add_argument("-ExtensionPath", required=True, help="Extension dump root, comma-separated list, or folder of extensions")
    parser.add_argument("-ConfigPath", required=True, help="Main configuration dump root")
    parser.add_argument("-Mode", default="check", help="check | transfer")
    parser.add_argument("-Name", default="", help="Objects to detail: Type.Name[,Type.Name]")
    parser.add_argument("-Limit", type=int, default=150)
    parser.add_argument("-Offset", type=int, default=0)
    parser.add_argument("-Expand", default="", help="Open folded transferred changes: Type.Name, a section path, or *")
    parser.add_argument("-Tag", default="", help="Value of {tag} in the comment template")
    parser.add_argument("-OutFile", default="")
    args = ci_parse_args(parser)

    mode = args.Mode.strip().lower()
    if mode not in ("check", "transfer"):
        die("Invalid -Mode '%s'. Expected: check, transfer" % mode)

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
    # Two extensions may change one method: the order they go in is a person's decision
    if mode == "transfer" and len(ext_dirs) > 1:
        die("-Mode transfer takes one extension, got %d: %s" % (len(ext_dirs), ", ".join(ext_dirs)))

    config_path = resolve_input_path(args.ConfigPath)
    cfg_info = read_configuration_props(config_path)
    if cfg_info is None:
        die("Config Configuration.xml not found: " + os.path.join(config_path, "Configuration.xml"))
    if cfg_info["is_extension"]:
        die("-ConfigPath is an extension, expected the main configuration: " + config_path)

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

    # Project settings (.v8-project.json): development prefixes for both modes, the rest for transfer
    SETTINGS = get_transfer_settings(config_path)
    DEV_RE = None
    if SETTINGS["dev_prefix"]:
        alt = "|".join(re.escape(x) for x in sorted(SETTINGS["dev_prefix"], key=len, reverse=True))
        DEV_RE = re.compile(r'(?<!\w)(?:' + alt + r')(?=\w)', re.IGNORECASE)
    matched_ids = set()

    if mode == "transfer":
        ext_dir0 = ext_dirs[0]
        cp0 = read_configuration_props(ext_dir0)
        prefix = cp0["prefix"] or ""
        TRANSFER_PREFIX = prefix
        vars_ = get_template_vars(ext_dir0, cp0, args.Tag)
        for kind in ("vendor", "own"):
            ic = SETTINGS[kind]["insert_comment"]
            if isinstance(ic, dict) and not args.Tag:
                for k in ("begin", "end"):
                    if re.search(r'\{tag(?::[^}]*)?\}', str(ic.get(k) or ""), re.I):
                        die("The project's comment template (cfeTransfer.insertComment.%s in .v8-project.json) uses {tag}: "
                            "ask the user for the value (e.g. the task number) and pass -Tag <value>. Nothing was written." % k)
        SUPPORT_INFO = get_support_info(config_path)
        FILE_EDITS.clear()
        NAME_MAP = {}
        ext = {"dir": ext_dir0, "name": cp0["name"], "prefix": prefix, "purpose": cp0["purpose"]}
        roles = 0

        # --- Pass 1: what the check sees, object by object ---
        work = []
        cfg_pools = {}
        if cfg_info["child_objects"] is not None:
            for c in elem_children(cfg_info["child_objects"]):
                cfg_pools.setdefault(localname(c), []).append((c.text or "").strip())
        all_objs = []
        if cp0["child_objects"] is not None:
            for c in elem_children(cp0["child_objects"]):
                if localname(c) != "Language":
                    all_objs.append({"type": localname(c), "name": (c.text or "").strip()})
        for obj in all_objs:
            oid = "%s.%s" % (obj["type"], obj["name"])
            if not name_match(oid):
                continue
            matched_ids.add(oid.lower())
            if obj["type"] == "Role":
                roles += 1
                continue
            rec = transfer_object(ext, obj, cfg_info, config_path)
            if not rec["items"]:
                continue
            ctx = get_obj_context(ext_dir0, obj["type"], obj["name"])
            sup = "own"
            if ctx.get("known"):
                cfg_xml = os.path.join(config_path, ctx["dir"], obj["name"] + ".xml")
                if os.path.exists(cfg_xml):
                    sup = get_object_support(cfg_xml)
            work.append({"id": oid, "obj": obj, "rec": rec, "ctx": ctx, "support": sup, "kind": get_object_kind(obj["name"], sup)})

        # --- Pass 2: names the configuration gets ---
        # Own objects and own sub-objects of borrowed ones: the names code refers to. Only a name that
        # differs from the plain one (prefix dropped) goes to the map: found under another name, or with
        # the development prefix.
        missing_global = {}
        missing_by_obj = {}
        for obj in all_objs:
            if obj["type"] == "Role":
                continue
            ctx = get_obj_context(ext_dir0, obj["type"], obj["name"])
            if not ctx.get("known") or not ctx["exists"]:
                continue
            if not ctx["borrowed"]:
                pool = cfg_pools.get(obj["type"], [])
                hit = find_name_in(pool, obj["name"], prefix)
                if not hit:
                    missing_global[obj["name"].lower()] = obj["name"]
                t = hit if hit else get_target_name(obj["name"], prefix, {n.lower() for n in pool}, SETTINGS["vendor"]["add_dev_objects"])["name"]
                if t != remove_ext_prefix(obj["name"], prefix):
                    NAME_MAP[obj["name"].lower()] = t
                continue
            md = ctx["md"]
            if md is None or md["children"] is None:
                continue
            cfg_xml = os.path.join(config_path, ctx["dir"], obj["name"] + ".xml")
            cfg_md = read_md_object(cfg_xml)
            sup = get_object_support(cfg_xml) if os.path.exists(cfg_xml) else "own"
            add_dev = SETTINGS[get_object_kind(obj["name"], sup)]["add_dev_objects"]
            cfg_names = []
            if cfg_md is not None and cfg_md["children"] is not None:
                for c in elem_children(cfg_md["children"]):
                    cfg_names.append(md_child_name(c) if has_element_child(c) else inner_text(c).strip())
            taken = {n.lower() for n in cfg_names}
            for c in elem_children(md["children"]):
                own = []
                if not has_element_child(c):
                    nm = inner_text(c).strip()
                    desc = read_md_object(os.path.join(ctx["obj_dir"], localname(c) + "s", nm + ".xml"))
                    if not (desc is not None and test_adopted_node(desc["props"])):
                        own.append(nm)
                elif not test_adopted_node(c):
                    own.append(md_child_name(c))
                else:
                    sub = c.find("md:ChildObjects", MD_NSMAP)
                    if sub is not None:
                        for sc in elem_children(sub):
                            if not test_adopted_node(sc):
                                own.append(md_child_name(sc))
                for nm in own:
                    if not nm:
                        continue
                    hit = find_name_in(cfg_names, nm, prefix)
                    if not hit:
                        missing_by_obj.setdefault("%s.%s" % (obj["type"], obj["name"]), {})[nm.lower()] = nm
                    if nm.lower() in NAME_MAP:
                        continue
                    t = hit if hit else get_target_name(nm, prefix, taken, add_dev)["name"]
                    if t != remove_ext_prefix(nm, prefix):
                        NAME_MAP[nm.lower()] = t
        # Own methods: the target name in their module (taken: the module's methods and those given in
        # this run); a common module's method is called from other modules too, so it goes to the run map
        file_maps = {}
        for w in work:
            for it in w["rec"]["items"]:
                pl = it.get("plan")
                if not pl or pl["kind"] != "own":
                    continue
                cfg_file = os.path.join(config_path, pl["rel"])
                fk = cfg_file.lower()
                file_maps.setdefault(fk, {})
                if pl["hit"]:
                    if pl["hit"] != pl["name"]:
                        file_maps[fk][pl["name"].lower()] = pl["hit"]
                    continue
                if it["status"] != "NOT_TRANSFERRED" or pl["cfg_missing"] or w["support"] == "locked":
                    continue
                fe = get_file_edits(cfg_file)
                taken = {n.lower() for n in get_proc_names(fe["file"]["lines"])} | set(fe["given"])
                # A module method shadows a global function of the same name for every call in the module:
                # a name called as a function there (or in the extension's module) is taken too
                taken |= get_called_names(list(fe["file"]["lines"]) + list(pl["ext_lines"]), get_proc_names(pl["ext_lines"]))
                set_ = SETTINGS[w["kind"]]
                tn = get_target_name(pl["name"], prefix, taken, set_["add_dev_methods"] and w["kind"] == "vendor")
                pl["target"] = tn
                if tn.get("taken"):
                    continue
                fe["given"].add(tn["name"].lower())
                file_maps[fk][pl["name"].lower()] = tn["name"]
                if get_module_kind(pl["rel"]) == "common" and tn["name"] != remove_ext_prefix(pl["name"], prefix):
                    NAME_MAP[pl["name"].lower()] = tn["name"]

        # --- Pass 3: each change -> transferred now, waiting, left to a person (manual) or in conflict ---
        # An own method that stays out of the configuration in this run is one more missing name: code
        # calling it waits too. Nothing is written before pass 4, so the pass runs again until no new
        # method stays out. A method of a common module is called from other modules, the rest from
        # their own module only.
        form_missing = {}
        form_temp = {}
        out_by_file = {}
        out_common = {}
        # Own methods marked "not for transfer" and not in the configuration: never coming, so code that
        # calls them is left to a person (drop the call or the mark) rather than waiting
        temp_by_file = {}
        temp_common = {}
        for w in work:
            for it in w["rec"]["items"]:
                pl = it.get("plan")
                if it["status"] != "TEMPORARY" or not pl or pl["kind"] != "own" or pl["hit"]:
                    continue
                add_out_name(temp_by_file, temp_common, os.path.join(config_path, pl["rel"]), pl["rel"], pl["name"])
        while True:
            again = False
            for fe in FILE_EDITS.values():
                fe["repl"].clear()
                fe["create"].clear()
                fe["create_order"].clear()
                fe["own_at"].clear()
                fe["tail"].clear()
            EDIT_SEQ[0] = 0
            temp_count = 0
            recs = []
            own_items = []
            ic_pending = []
            top_items = []
            ctl_keys = set()
            for w in work:
                titems = []
                set_ = SETTINGS[w["kind"]]
                frame = get_frame(set_, vars_)
                for it in w["rec"]["items"]:
                    pl = it.get("plan")
                    t = new_titem(it["status"], it["text"], it.get("loc", ""), it.get("section", ""))
                    t["group"] = it.get("group", "")
                    t["marked"] = it.get("marked", False)
                    if pl and pl["kind"] == "own" and it["status"] == "NOT_TRANSFERRED":
                        own_items.append({"plan": pl, "t": t})
                    # A method with an &ИзменениеИКонтроль edit not in the configuration yet: an interceptor of it
                    # would move the lines the edit is anchored to
                    if pl and pl["kind"] == "control" and pl.get("cfg_m") and it["status"] not in ("TRANSFERRED", "TEMPORARY"):
                        ctl_keys.add("%s|%d" % (os.path.join(config_path, pl["rel"]).lower(), pl["cfg_m"]["decl_idx"]))
                    if it["status"] == "TEMPORARY":
                        temp_count += 1
                        continue
                    if it["status"] == "TRANSFERRED":
                        titems.append(t)
                        continue
                    t["status"] = "MANUAL"
                    if it.get("group"):
                        t["text"] = it["text"] + " — forms are not transferred yet"
                        titems.append(t)
                        continue
                    if not pl:
                        t["text"] = it["text"] + " — metadata is not transferred yet"
                        titems.append(t)
                        continue
                    if pl["kind"] == "missing":
                        nxt = ("the interceptor does not parse: fix it in the extension, then re-run -Mode transfer" if pl.get("cfg_m")
                               else "the target is not in the configuration: add it there first, then re-run -Mode transfer")
                        t["sub"] = get_where_lines(pl, nxt)
                        titems.append(t)
                        continue
                    cfg_file = os.path.join(config_path, pl["rel"])
                    file_map = file_maps.get(cfg_file.lower(), {})
                    label = ("method " + pl["name"] if pl["kind"] == "own"
                             else "module code outside methods" if pl["kind"] == "topcode" else pl["label"])
                    if w["support"] == "locked":
                        t["text"] = label + " — object is locked by vendor support"
                        t["sub"] = get_where_lines(pl, "allow editing with /support-edit, then re-run -Mode transfer")
                        titems.append(t)
                        continue
                    warn_note = " (object locked by vendor support, written: editingAllowedCheck = warn)" if w["support"] == "warn" else ""
                    # Code outside methods: module variables go after the configuration's (or before its first
                    # method), statements of the module body after the configuration's own, at the module's tail —
                    # the extension's body runs after the configuration's, so the order stays
                    if pl["kind"] == "topcode":
                        where_sub = ["from: extension %s:%d" % (pl["rel"], pl["line"] + 1)]
                        if not os.path.exists(cfg_file):
                            t["text"] = label + " — module not found in config"
                            t["sub"] = where_sub + ["next: add the module to the configuration first, then re-run -Mode transfer"]
                            titems.append(t)
                            continue
                        fe = get_file_edits(cfg_file)
                        if "layout" not in pl:
                            pl["layout"] = get_module_layout(pl["ext_lines"])
                        if "top_keys" not in fe:
                            fe["top_keys"] = {get_top_key(l, prefix) for l in get_top_code_lines(fe["file"]["lines"])}
                        el, cl, have = pl["layout"], fe["layout"], fe["top_keys"]
                        taken = {n.lower() for v in cl["vars"] for n in v["names"]} | {n.lower() for n in get_proc_names(fe["file"]["lines"])}
                        # Each line once: a variable declared twice in the extension is declared once in the configuration
                        seen = set()
                        stmts = []
                        stmts_have = 0
                        for i in el["statements"]:
                            key = get_top_key(pl["ext_lines"][i], prefix)
                            if key in have:
                                stmts_have += 1
                                continue
                            if key in seen:
                                continue
                            seen.add(key)
                            stmts.append(i)
                        todo, clash = [], []
                        for v in el["vars"]:
                            key = get_top_key(pl["ext_lines"][v["idx"]], prefix)
                            if key in have or key in seen:
                                continue
                            seen.add(key)
                            for n in v["names"]:
                                tn = convert_ext_code([n], file_map)[0]
                                if tn.lower() in taken:
                                    clash.append(tn)
                            todo.append(v)
                        # Variables that stay out make the code using them wait, like a method that stays out
                        t["out_names"] = [n for v in todo for n in v["names"]]
                        t["out_file"] = cfg_file
                        top_items.append(t)
                        # The platform drops a manager module with variables or statements, its methods included
                        if re.search(r'[\\/]Ext[\\/]ManagerModule\.bsl$', pl["rel"]):
                            t["text"] = label + " — a manager module with variables or statements is not applied by the platform: this code never ran"
                            t["sub"] = where_sub + ["next: remove the code outside methods from the extension's manager module (none of its methods run either), then re-run -Mode check"]
                            titems.append(t)
                            continue
                        if clash:
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — variable %s is declared in config already; not changed" % (label, ", ".join(clash))
                            t["sub"] = where_sub + ["next: rename or merge by hand, then re-run -Mode check"]
                            titems.append(t)
                            continue
                        body = None
                        if stmts:
                            s0 = stmts[0]
                            while s0 > 0 and re.match(r'^(//|&)', pl["ext_lines"][s0 - 1].strip()):
                                s0 -= 1
                            s1 = stmts[-1]
                            rng = pl["ext_lines"][s0:s1 + 1]
                            why = None
                            if stmts_have:
                                why = "statements of the module body are partly in config"
                            elif any(x.strip().startswith("#") for x in rng):
                                why = "statements of the module body stand under preprocessor instructions"
                            if why:
                                t["text"] = "%s — %s" % (label, why)
                                t["sub"] = ["from: extension %s:%d-%d" % (pl["rel"], s0 + 1, s1 + 1), "next: add them at the end of the configuration module by hand, then re-run -Mode check"]
                                titems.append(t)
                                continue
                            body = convert_ext_code(rng, file_map)
                        parts = []
                        if todo:
                            block = []
                            for v in todo:
                                block += convert_ext_code(pl["ext_lines"][v["start"]:v["idx"] + 1], file_map)
                            block = get_framed(block, frame)
                            if cl["last_var"] >= 0:
                                at = cl["last_var"] + 1
                                fe["repl"].append({"start": at, "end": at, "lines": block, "seq": EDIT_SEQ[0]})
                                where = "after the module variables"
                            else:
                                at = cl["first_method"] if cl["first_method"] >= 0 else get_module_end(fe["file"]["lines"])
                                fe["repl"].append({"start": at, "end": at, "lines": get_spaced_block(fe["file"]["lines"], at, block), "seq": EDIT_SEQ[0]})
                                where = "before the first method" if cl["first_method"] >= 0 else "end of module"
                            EDIT_SEQ[0] += 1
                            parts.append("%s -> %s" % (plural(len(todo), "variable declaration"), where))
                        if body is not None:
                            fe["tail"].append(get_framed(body, frame))
                            parts.append("statements of the module body -> end of module")
                        if not parts:
                            t["status"] = "TRANSFERRED"
                            titems.append(t)
                            continue
                        t["status"] = "TRANSFERRED"
                        t["now"] = True
                        t["text"] = "%s — %s%s" % (label, "; ".join(parts), warn_note)
                        titems.append(t)
                        continue
                    # Code that uses names the configuration does not have yet waits for them
                    missing = {}
                    for m in (missing_global, missing_by_obj.get(w["id"])):
                        if m:
                            missing.update(m)
                    if get_module_kind(pl["rel"]) == "form":
                        fk = pl["rel"].lower()
                        if fk not in form_missing:
                            def fx(root):
                                return re.sub(r'[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml', os.path.join(root, pl["rel"]))
                            form_missing[fk] = get_missing_names(get_form_item_names(fx(ext_dir0)), get_form_item_names(fx(config_path)))
                        missing.update(form_missing[fk])
                        # Form items the form module marks "not for transfer" are never coming
                        if fk not in form_temp:
                            form_temp[fk] = {}
                            for k, why in get_form_temp_marks(read_bsl_lines(os.path.join(ext_dir0, pl["rel"]))).items():
                                form_temp[fk][k] = form_missing[fk].get(k, k)
                        for k in form_temp[fk]:
                            missing.pop(k, None)
                    for m in (out_by_file.get(cfg_file.lower()), out_common):
                        if m:
                            missing.update(m)
                    # A method calling itself does not wait for itself
                    if pl["kind"] == "own":
                        missing.pop(pl["name"].lower(), None)
                    if pl["kind"] == "control":
                        code = [l for e in pl["ops"] if e["res"] == "pending" and e["op"]["kind"] == "insert" for l in e["op"]["lines"]]
                    else:
                        code = list(pl["ext_m"]["body_lines"])
                    deps = get_used_missing(code, missing)
                    # A conflict or a missing module shows first: waiting would hide it
                    blocked = ((pl["kind"] == "control" and any(e["res"] not in ("pending", "absorbed", "temp") for e in pl["ops"]))
                               or (pl["kind"] == "own" and (it["status"] == "DIVERGED" or pl["cfg_missing"]
                                                            or (pl.get("target") or {}).get("taken")))
                               or (pl["kind"] == "intercept" and it["status"] == "PARTIAL"))
                    temp_map = {}
                    for m in (temp_by_file.get(cfg_file.lower()), temp_common):
                        if m:
                            temp_map.update(m)
                    temp_deps = get_used_missing(code, temp_map)
                    if temp_deps and not blocked:
                        t["text"] = "%s — calls %s, marked as not for transfer" % (label, ", ".join(temp_deps))
                        t["sub"] = get_where_lines(pl, "drop the call before the transfer or remove the mark from the method, then re-run -Mode transfer")
                        titems.append(t)
                        continue
                    form_temp_deps = get_used_missing(code, form_temp.get(pl["rel"].lower(), {})) if get_module_kind(pl["rel"]) == "form" else []
                    if form_temp_deps and not blocked:
                        t["text"] = "%s — uses form items %s, marked as not for transfer" % (label, ", ".join(form_temp_deps))
                        t["sub"] = get_where_lines(pl, "drop the use before the transfer or remove the mark from the form module, then re-run -Mode transfer")
                        titems.append(t)
                        continue
                    if deps and not blocked:
                        more = (", …+%d" % (len(deps) - 5)) if len(deps) > 5 else ""
                        t["status"] = "WAITING"
                        t["text"] = "%s — waits for: %s%s" % (label, ", ".join(deps[:5]), more)
                        titems.append(t)
                        continue
                    if pl["kind"] == "intercept":
                        if it["status"] == "PARTIAL":
                            t["status"] = "CONFLICT"
                            t["text"] = it["text"] + " — partly in the configuration already; method not changed"
                            t["sub"] = get_where_lines(pl, "compare with the original and finish by hand, then re-run -Mode check")
                            titems.append(t)
                            continue
                        r = get_intercept_ops(pl["ext_m"], pl["cfg_m"], pl["type"], frame, set_["deletion"], file_map)
                        if r.get("why"):
                            t["text"] = "%s — %s" % (label, r["why"])
                            t["sub"] = get_where_lines(pl, r.get("next") or "apply by hand, then re-run -Mode check")
                            titems.append(t)
                            continue
                        # Laid once every interceptor of the module is known: two of one method go together
                        ic_pending.append({"t": t, "pl": pl, "fe": get_file_edits(cfg_file), "ops": r["ops"], "where": r["where"], "label": label, "warn": warn_note, "locals": r["locals"], "words": r["words"]})
                        titems.append(t)
                        continue
                    if pl["kind"] == "control":
                        fit = sum(1 for e in pl["ops"] if e["res"] in ("pending", "absorbed"))
                        pend = sum(1 for e in pl["ops"] if e["res"] == "pending")
                        div = [e for e in pl["ops"] if e["res"] not in ("pending", "absorbed", "temp")]
                        if div:
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %d of %d edits fit, %d diverged; method not changed" % (label, fit, fit + len(div), len(div))
                            t["sub"] = ["diverged: " + e["res"] for e in div] + get_where_lines(pl, "original changed in config -> /cfe-patch-method -Actualize, then re-run -Mode transfer; otherwise apply by hand")
                            titems.append(t)
                            continue
                        fe = get_file_edits(cfg_file)
                        body = get_control_body(pl["cfg_m"], pl["ops"], frame, set_["deletion"], file_map)
                        # The check must see the result as transferred, or a re-run would carry it over again:
                        # the new body goes through the same comparison before anything is written
                        gap = get_control_result_gap(pl, body)
                        if gap > 0:
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — after the transfer the check would still see %s as not transferred; method not changed" % (label, plural(gap, "edit"))
                            t["sub"] = get_where_lines(pl, "lines moved within the method or already partly carried over: transfer by hand, then re-run -Mode check")
                            titems.append(t)
                            continue
                        fe["repl"].append({"start": pl["cfg_m"]["sig_end_idx"] + 1, "end": pl["cfg_m"]["body_end_idx"], "lines": body, "seq": EDIT_SEQ[0]})
                        EDIT_SEQ[0] += 1
                        t["status"] = "TRANSFERRED"
                        t["now"] = True
                        already = fit - pend
                        t["text"] = "%s — %s%s%s" % (label, plural(pend, "edit"), (", %d already there" % already) if already else "", warn_note)
                        titems.append(t)
                        continue
                    # own method
                    if it["status"] == "DIVERGED":
                        t["status"] = "CONFLICT"
                        t["text"] = it["text"] + "; not changed"
                        t["sub"] = get_where_lines(pl, "compare the bodies and merge by hand")
                        titems.append(t)
                        continue
                    if pl["cfg_missing"]:
                        t["text"] = label + " — module not found in config"
                        t["sub"] = get_where_lines(pl, "add the module to the configuration first, then re-run -Mode transfer")
                        titems.append(t)
                        continue
                    if pl["target"].get("taken"):
                        t["status"] = "CONFLICT"
                        t["text"] = "%s — name taken in config (%s); not changed" % (label, pl["target"]["note"])
                        t["sub"] = get_where_lines(pl, "rename the method or merge by hand")
                        titems.append(t)
                        continue
                    fe = get_file_edits(cfg_file)
                    kind_mod = get_module_kind(pl["rel"])
                    bind = {}
                    if kind_mod == "form":
                        bind = get_form_bindings(re.sub(r'[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml', os.path.join(ext_dir0, pl["rel"])))
                    notify = get_notify_names(list(pl["ext_lines"]) + list(fe["file"]["lines"]))
                    role = get_method_role(pl["name"], kind_mod, bind, notify, is_export(pl["ext_lines"], pl["ext_m"]))
                    created = {k.lower() for k in fe["create_order"]}
                    place = get_method_place(fe["file"]["lines"], fe["regions"], pl["ext_m"], role, set_, created)
                    block = get_own_method_block(pl["ext_lines"], pl["ext_m"], frame, file_map)
                    if not test_own_result(pl, fe, file_map):
                        t["status"] = "CONFLICT"
                        t["text"] = "%s — after the transfer the check would not find it under %s; not changed" % (label, pl["target"]["name"])
                        t["sub"] = get_where_lines(pl, "transfer by hand")
                        titems.append(t)
                        continue
                    if place.get("create"):
                        key = next((k for k in fe["create_order"] if k.lower() == place["create"].lower()), None)
                        if key is None:
                            key = place["create"]
                            fe["create_order"].append(key)
                            fe["create"][key] = []
                        fe["create"][key].append(block)
                        where = "new region " + key
                    else:
                        at = int(place["at"])
                        if at not in fe["own_at"]:
                            fe["own_at"][at] = {"blocks": [], "seq": EDIT_SEQ[0]}
                            EDIT_SEQ[0] += 1
                        fe["own_at"][at]["blocks"].append(block)
                        where = ("region " + place["region"]) if place["region"] else "end of module"
                    t["status"] = "TRANSFERRED"
                    t["now"] = True
                    note = (" (%s)" % pl["target"]["note"]) if pl["target"]["note"] else ""
                    t["text"] = "%s%s -> %s%s" % (label, note, where, warn_note)
                    titems.append(t)
                if not titems:
                    continue
                recs.append({"id": w["id"], "items": titems})
            # Interceptors, by the method they intercept: &Перед and &После of one method go into one body;
            # &Вместо next to another interceptor, or any next to &ИзменениеИКонтроль, is left to a person
            ic_groups = {}
            for p in ic_pending:
                ic_groups.setdefault("%s|%d" % (p["fe"]["file"]["path"].lower(), p["pl"]["cfg_m"]["decl_idx"]), []).append(p)
            for key, g in ic_groups.items():
                fe = g[0]["fe"]
                cfg_m = g[0]["pl"]["cfg_m"]
                manual = None
                if key in ctl_keys:
                    manual = "the method has &ИзменениеИКонтроль too"
                elif len(g) > 1 and any(p["pl"]["type"] == "Вместо" for p in g):
                    manual = "the method has other interceptors too"
                elif len(g) > 1:
                    # Two handlers in one body: a local of one that the other names becomes one variable
                    shared = []
                    for a in range(len(g)):
                        for b in range(len(g)):
                            if a == b:
                                continue
                            for k in g[a]["locals"]:
                                if k in g[b]["words"] and g[a]["locals"][k] not in shared:
                                    shared.append(g[a]["locals"][k])
                    if shared:
                        manual = "variable %s is in more than one interceptor of the method" % ", ".join(shared)
                if manual:
                    for p in g:
                        p["t"]["text"] = "%s — %s" % (p["label"], manual)
                        p["t"]["sub"] = get_where_lines(p["pl"], "apply by hand, then re-run -Mode check")
                    continue
                ops = [op for p in g for op in p["ops"]]
                body = get_intercept_body(cfg_m["body_lines"], ops)
                # The check must find every handler's code in the new body, or a re-run would put it in again
                m2 = {"body_lines": body, "param_names": cfg_m["param_names"]}
                bad = False
                for p in g:
                    h2 = get_heuristic_transfer(p["pl"]["ext_m"], m2, prefix)
                    if h2 and h2["found"] != h2["total"]:
                        bad = True
                if bad:
                    for p in g:
                        p["t"]["status"] = "CONFLICT"
                        p["t"]["text"] = "%s — after the transfer the check would not find the handler's code; method not changed" % p["label"]
                        p["t"]["sub"] = get_where_lines(p["pl"], "apply by hand, then re-run -Mode check")
                    continue
                fe["repl"].append({"start": cfg_m["sig_end_idx"] + 1, "end": cfg_m["body_end_idx"], "lines": body, "seq": EDIT_SEQ[0]})
                EDIT_SEQ[0] += 1
                for p in g:
                    p["t"]["status"] = "TRANSFERRED"
                    p["t"]["now"] = True
                    p["t"]["text"] = "%s — %s%s" % (p["label"], p["where"], p["warn"])
            # Module variables that stay out, the same way
            for o in top_items:
                if o["status"] == "TRANSFERRED":
                    continue
                dst = out_by_file.setdefault(o["out_file"].lower(), {})
                for nm in o["out_names"]:
                    if nm.lower() not in dst:
                        dst[nm.lower()] = nm
                        again = True
            # Own methods that stay out: new ones make the pass run again
            for o in own_items:
                if o["t"]["status"] == "TRANSFERRED":
                    continue
                if add_out_name(out_by_file, out_common, os.path.join(config_path, o["plan"]["rel"]), o["plan"]["rel"], o["plan"]["name"]):
                    again = True
            if not again:
                break

        # --- Pass 4: write ---
        changed = write_file_edits()

        # --- Report ---
        c_now = c_already = c_wait = c_manual = c_conflict = 0
        body = []
        any_folded = False
        body.append("=== cfe-transfer transfer: %s (%s) -> %s ===" % (ext["name"], ext["purpose"], cfg_info["name"]))
        if ext["prefix"]:
            body.append("NamePrefix: " + ext["prefix"])
        body.append("")
        shown = 0
        for r in recs:
            now = sum(1 for x in r["items"] if x.get("now"))
            already = sum(1 for x in r["items"] if x["status"] == "TRANSFERRED" and not x.get("now"))
            wait = sum(1 for x in r["items"] if x["status"] == "WAITING")
            man = sum(1 for x in r["items"] if x["status"] == "MANUAL")
            con = sum(1 for x in r["items"] if x["status"] == "CONFLICT")
            c_now += now
            c_already += already
            c_wait += wait
            c_manual += man
            c_conflict += con
            if now + wait + man + con == 0:
                continue
            st = "CONFLICT" if con else ("MANUAL" if man else ("WAITING" if wait else "TRANSFERRED"))
            parts = []
            if now:
                parts.append("%d transferred now" % now)
            if wait:
                parts.append("%d waiting" % wait)
            if man:
                parts.append("%d manual" % man)
            if con:
                parts.append("%d conflict" % con)
            if already:
                parts.append("%d already transferred" % already)
            body.append("%s%s — %s" % (fmt_status(st), r["id"], ", ".join(parts)))
            dv = get_transfer_details(ext, r, expand_list, "already transferred")
            body += dv["lines"]
            if dv["folded"]:
                any_folded = True
            shown += 1
        if shown == 0:
            body.append("All changes already transferred." if recs else "No changes to transfer.")
        body.append("")

        footer = []
        parts = ["%d transferred now" % c_now]
        if c_wait:
            parts.append("%d waiting" % c_wait)
        if c_manual:
            parts.append("%d manual" % c_manual)
        if c_conflict:
            parts.append("%d conflict" % c_conflict)
        tail = []
        if c_already:
            tail.append("%d already transferred" % c_already)
        if temp_count:
            tail.append("%d temporary skipped" % temp_count)
        if roles:
            tail.append("%s, not transferred" % plural(roles, "role"))
        tail_text = (" · " + " · ".join(tail)) if tail else ""
        footer.append("=== Summary %s: %s%s ===" % (ext["name"], ", ".join(parts), tail_text))
        if changed:
            footer.append("Changed files:")
            for c in changed:
                footer.append("    " + rel_path(config_path, c))
            footer.append("Hint: validate the changed modules, then re-run -Mode check")
        if c_conflict:
            footer.append("Hint: resolve each conflict (see next:), then re-run -Mode transfer")
        if c_wait:
            footer.append("Hint: waiting changes go over by themselves on a re-run of -Mode transfer once what they wait for is in the configuration: "
                          "own methods of this run (see their lines), objects, sub-objects and form items (by hand for now)")
        failed = (c_wait + c_manual + c_conflict) > 0
        show_details = True
        full_count = 0
        unch_folded = False
    else:
        exts = []
        matched_ids = set()
        for d in ext_dirs:
            cp = read_configuration_props(d)
            ext = {"dir": d, "name": cp["name"], "prefix": cp["prefix"], "purpose": cp["purpose"], "objects": [],
                   "roles": 0, "matched": 0}
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
                    if obj["type"] == "Role":
                        ext["roles"] += 1
                        continue
                    rec = transfer_object(ext, obj, cfg_info, config_path)
                    if not rec["items"]:
                        continue
                    # Temporary changes are not for transfer: they neither leave the object incomplete nor set its status
                    sts = []
                    for it in rec["items"]:
                        if it["status"] != "TEMPORARY" and it["status"] not in sts:
                            sts.append(it["status"])
                    # A mix shows its most alarming status: a conflict must not hide behind PARTIAL
                    if not sts:
                        rec["status"] = "TEMPORARY"
                    elif len(sts) == 1:
                        rec["status"] = sts[0]
                    elif "DIVERGED" in sts:
                        rec["status"] = "DIVERGED"
                    elif "MISSING_IN_CONFIG" in sts:
                        rec["status"] = "MISSING_IN_CONFIG"
                    else:
                        rec["status"] = "PARTIAL"
                    done = len([it for it in rec["items"] if it["status"] == "TRANSFERRED"])
                    temp = len([it for it in rec["items"] if it["status"] == "TEMPORARY"])
                    rec["complete"] = done + temp == len(rec["items"])
                    n = len(rec["items"])
                    temp_note = (", %d temporary" % temp) if temp else ""
                    if rec["complete"]:
                        tail = plural(n, "change") + ((" (%d temporary)" % temp) if temp else "")
                    else:
                        tail = "%s: %d transferred, %d remaining%s" % (plural(n, "change"), done, n - done - temp, temp_note)
                    rec["summary"] = "%s%s — %s" % (fmt_status(rec["status"]), rec["id"], tail)
                    dv = get_transfer_details(ext, rec, expand_list)
                    rec["details"] = dv["lines"]
                    rec["folded"] = dv["folded"]
                    # Asked for by name or opened with -Expand (the object or one of its sections): details even when all is transferred
                    rec["asked"] = bool(name_filter) or dv["open"]
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
                full_count += 1
                if not o["complete"] or o.get("asked"):
                    full_count += len(o["details"])
        show_details = bool(name_filter) or bool(expand_list) or full_count <= DETAIL_BUDGET

        # --- Body ---
        body = []
        any_folded = False
        for ext in exts:
            body.append("=== cfe-transfer check: %s (%s) -> %s ===" % (ext["name"], ext["purpose"], cfg_info["name"]))
            if ext["prefix"]:
                body.append("NamePrefix: " + ext["prefix"])
            body.append("")
            shown = 0
            for o in ext["objects"]:
                if o["complete"] and not show_details:
                    continue
                body.append(o["summary"])
                shown += 1
                if show_details and (not o["complete"] or o.get("asked")):
                    body += o["details"]
                    if o.get("folded"):
                        any_folded = True
            if shown == 0:
                if ext["objects"]:
                    body.append("All changes transferred.")
                else:
                    body.append("No changes to transfer.")
            body.append("")

        # --- Footer: always printed, after the body (output is often read from its tail) ---
        footer = []
        failed = False
        ext_done = 0
        ext_left = 0
        left_total = 0
        for ext in exts:
            alls = [it for o in ext["objects"] for it in o["items"]]
            roles_note = (" · %s, not checked" % plural(ext["roles"], "role")) if ext["roles"] else ""
            if not alls:
                footer.append("=== Summary %s: no changes to transfer%s ===" % (ext["name"], roles_note))
                ext_done += 1
                continue
            cnt = {s: len([it for it in alls if it["status"] == s]) for s in STATUS_ORDER}
            # A workaround carried over although marked "not for transfer" is worth a look: counted apart
            marked = len([it for it in alls if it.get("marked")])
            marked_note = (" (%d marked temporary)" % marked) if marked else ""
            parts = ["%d transferred%s" % (cnt["TRANSFERRED"], marked_note)]
            for s in STATUS_ORDER[1:]:
                if cnt[s]:
                    parts.append("%d %s" % (cnt[s], s.lower().replace("_", " ")))
            footer.append("=== Summary %s: %s — %s%s ===" % (ext["name"], plural(len(alls), "change"), ", ".join(parts), roles_note))
            left = len(alls) - cnt["TRANSFERRED"] - cnt["TEMPORARY"]
            if left > 0:
                failed = True
                ext_left += 1
                left_total += left
                ids = [o["id"] for o in ext["objects"] if not o["complete"]]
                more = (", …+%d" % (len(ids) - 10)) if len(ids) > 10 else ""
                footer.append("Remaining: %s%s" % (", ".join(ids[:10]), more))
            else:
                ext_done += 1
        if len(exts) > 1:
            tail = (", %d with %d remaining" % (ext_left, left_total)) if ext_left else ""
            footer.append("=== Total: %d extensions — %d complete%s ===" % (len(exts), ext_done, tail))
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
    if any_folded:
        what = "already transferred" if mode == "transfer" else "transferred"
        footer.append("Hint: use -Expand <Type.Name> or a section path to list %s changes, -Expand * for all" % what)

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

    if failed:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
