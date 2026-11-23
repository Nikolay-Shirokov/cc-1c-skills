#!/usr/bin/env python3
# cfe-transfer v1.47 — Transfer of 1C configuration extension (CFE) changes into the main configuration: check and transfer
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import tempfile
import uuid
from collections import Counter
from decimal import Decimal, InvalidOperation
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
    last = conds[n - 1]
    parts.append("(%s)" % last if re.search(r'\b(?:Или|Or)\b', last, re.I) else last)
    return (" %s " % kw_and).join(parts)


def get_enclosing_chain(lines, target_idx, lang):
    re_region = re.compile(r'^#' + kw_alt("Region") + r'\s+(\S+)', re.IGNORECASE)
    re_end_region = re.compile(r'^#' + kw_alt("EndRegion"), re.IGNORECASE)
    re_if = re.compile(r'^#\s*' + kw_alt("If") + r'(?!\w)\s*(.+?)\s*(?<!\w)' + kw_alt("Then") + r'(?=\s|//|$)', re.IGNORECASE)
    re_elsif = re.compile(r'^#\s*' + kw_alt("ElsIf") + r'(?!\w)\s*(.+?)\s*(?<!\w)' + kw_alt("Then") + r'(?=\s|//|$)', re.IGNORECASE)
    re_else = re.compile(r'^#\s*' + kw_alt("Else") + r'(?=\s|//|$)', re.IGNORECASE)
    re_endif = re.compile(r'^#\s*' + kw_alt("EndIf") + r'(?=\s|//|$)', re.IGNORECASE)
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


def form_item_rank(it):
    """Order of a form's changes in the transfer: what the others rely on goes first (a column needs its
    attribute, an element may name a command or carry a property and an event), a form change left to a
    person or applied in place goes last; anything not of a form keeps its place."""
    if not it.get("group"):
        return 100
    k = it["plan"]["kind"] if it.get("plan") else ""
    return {"attribute": 0, "command": 1, "command-bind": 1, "column": 2, "element": 3,
            "prop": 4, "move": 4, "event-bind": 5, "appearance": 6, "formprop": 6,
            "intercept": 9}.get(k, 8)


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


# Fold identifiers while protecting literal values from case and whitespace normalization.
def code_keys(lines, prefix, significant=False, params=()):
    lines = protect_bsl_parameter_members(lines, params)
    source = '\n'.join(lines)
    parts, pos, line_no, comments = [], 0, 0, {}
    def code_part(value):
        value = remove_ext_prefix(value, prefix)
        return DEV_RE.sub('', value) if DEV_RE is not None else value
    for match in re.finditer(r'//[^\r\n]*|' + BSL_LITERAL_PATTERN, source):
        segment = source[pos:match.start()]
        line_no += segment.count('\n')
        parts.append(code_part(segment))
        if match[0].startswith('//'):
            line_start = source.rfind('\n', 0, match.start()) + 1
            if not source[line_start:match.start()].strip():
                comments[line_no] = match[0][2:]
            parts.append(code_part(match[0]))
        else:
            segments = match[0].split('\n')
            encoded = []
            for i, part in enumerate(segments):
                if i and part.lstrip().startswith('//'):
                    archive = part.lstrip()[2:].lstrip()
                    if archive.startswith('|'):
                        encoded.append('//' + code_keys(['"', archive, '|"'], prefix)[1])
                    else:
                        encoded.append(part.strip())
                    continue
                if i and not part.strip():
                    encoded.append(''); continue
                if i:
                    part = re.sub(r'^[\t ]+(?=\|)', '', part)
                encoded.append('~' + part.encode('utf-16-le', errors='surrogatepass').hex())
            parts.append('"' + '\n'.join(encoded) + '"')
        pos = match.end()
        line_no += match[0].count('\n')
    parts.append(code_part(source[pos:]))
    keys = ''.join(parts).split('\n')
    i = 0
    while i < len(keys):
        if i not in comments:
            i += 1; continue
        start, archive = i, []
        while i < len(keys) and i in comments:
            archive.append(comments[i]); i += 1
        for j, key in enumerate(code_keys(archive, prefix, params=params)):
            keys[start + j] = '//' + key
    result = [normalize(line).lower() for line in keys]
    return [line for line in result if test_significant(line)] if significant else result


def code_key(line, prefix):
    return code_keys([line], prefix)[0]


def sig_lines(lines, prefix):
    return code_keys(lines, prefix, True)


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


def test_sequence_without_run(longer, shorter, keys):
    """Can one occurrence be removed to reproduce the shorter sequence exactly?"""
    size = len(keys)
    if not size or len(longer) != len(shorter) + size:
        return False
    first = len(shorter)
    while first > 0 and longer[first + size - 1] == shorter[first - 1]:
        first -= 1
    for i in range(len(shorter) + 1):
        if i >= first and test_run_at(longer, keys, i):
            return True
        if i < len(shorter) and longer[i] != shorter[i]:
            break
    return False


def expected_without_edit(projection, index, restored_keys=()):
    """Expected live code with the operation at its projected position undone."""
    start, end = projection['ranges'][index]
    keys = projection['keys']
    return [key for key in keys[:start] if test_significant(key)] + list(restored_keys) + [
        key for key in keys[end:] if test_significant(key)
    ]


def get_control_transfer(ext_method, cfg_method, prefix):
    parsed = parse_marked_body(ext_method["body_lines"])
    projection = get_control_projection(ext_method['body_lines'], {}, prefix, ext_method['param_names'])
    ops = parsed["ops"]
    for i, op in enumerate(ops):
        op["source_index"] = i
    params = ext_method["param_names"]
    v1norm = code_keys(convert_bsl_code(parsed['v1'], {}, params), prefix, params=params)
    v2norm = code_keys(cfg_method["body_lines"], prefix, params=cfg_method["param_names"])
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
    payloads = {i: [k for k in projection['payload_keys'][i] if test_significant(k)]
                for i, o in enumerate(ops) if o["kind"] == "insert"}
    desired_sig = [key for key in projection['keys'] if test_significant(key)]
    has_temp_edits = any(get_block_temp_mark(op) is not None for op in ops)
    # Whole-body agreement identifies repeated lines by their position in the sequence.
    has_body_change = v1sig != desired_sig
    at_original = has_body_change and v1norm == v2norm
    at_desired = has_body_change and desired_sig == v2sig
    replaced = set() if at_original or at_desired else get_absorbed_in_place(ops, v1norm, v2norm, v2sig, payloads)
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
            if at_desired:
                res = "absorbed"
            elif at_original:
                k = op["after"]
                res = "pending"
            else:
                base_runs = run_count(v1sig, payload_sig)
                current_runs = run_count(v2sig, payload_sig)
                desired_runs = run_count(desired_sig, payload_sig) if base_runs > 0 else 0
                # An optional insertion must not raise the required count of a permanent insertion.
                if has_temp_edits:
                    desired_runs = min(desired_runs, base_runs + 1)
                missing_repeat = base_runs > 0 and desired_runs > base_runs and current_runs < desired_runs
                after = op["after"]
                before_lines = v1norm[max(0, after - 2):after + 1] if after >= 0 else []
                after_lines = v1norm[after + 1:after + 4]
                k = resolve_insertion_point(v2norm, before_lines, after_lines)
                # The looser checks below accept the payload only as new code: the configuration has it
                # more times than the original method (an insert repeating a line next to it otherwise
                # finds that very line)
                is_new = current_runs > base_runs
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
                wrong_position = False
                if has_body_change and base_runs > 0 and len(v2sig) == len(desired_sig):
                    if len(ops) == 1:
                        wrong_position = test_sequence_without_run(v2sig, v1sig, payload_sig)
                    elif desired_runs > base_runs:
                        without_edit = expected_without_edit(projection, oi)
                        wrong_position = test_sequence_without_run(v2sig, without_edit, payload_sig)
                if wrong_position:
                    res = "repeated insertion is at a different position in config"
                elif is_absorbed or oi in replaced:
                    res = "repeated insertion is ambiguous in config" if missing_repeat else "absorbed"
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
            p = c_at = -1
            keys = v1norm[op["start"]:op["end"] + 1]
            sig_keys = [x for x in keys if test_significant(x)]
            if at_desired:
                res = "absorbed"
                if not sig_keys and keys:
                    # The live lines agree. Look for the explicitly deleted comments only
                    # between the live lines that surround their projected position.
                    start = projection['ranges'][oi][0]
                    live_before = sum(test_significant(key) for key in projection['keys'][:start])
                    first_gap = v2map[live_before - 1] + 1 if live_before else 0
                    end_gap = v2map[live_before] if live_before < len(v2map) else len(v2norm)
                    gap_keys = v2norm[first_gap:end_gap]
                    offset = find_unique_run(gap_keys, keys)
                    if offset >= 0:
                        p = first_gap + offset
                        res = "pending"
                    elif run_count(gap_keys, keys) > 1:
                        res = "comment-only deletion has multiple matches in config"
            elif at_original:
                p = op["start"]
                res = "pending"
            else:
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
                current_runs = run_count(v2sig, sig_keys)
                desired_runs = run_count(desired_sig, sig_keys) if v1_runs > 1 else v1_runs
                if has_temp_edits:
                    desired_runs = max(desired_runs, v1_runs - 1)
                missing_deletion = v1_runs > 1 and desired_runs < v1_runs and current_runs > desired_runs
                live_left = bool(sig_keys) and current_runs == v1_runs - 1 + ins_runs
                stays = live_left and (ins_runs > 0 or v1_runs > 1)
                # Commented out at its own place, and the code left as often as after the edit: carried over.
                # Looked at first — a line the edit moves into its own insert is there as code too, and
                # deleting it would break the carried-over insert. An old comment elsewhere does not count.
                c_at = find_commented_run(v2norm, sig_keys, before_ctx, after_ctx) if live_left else -1
                wrong_position = False
                if has_body_change and v1_runs > 1 and len(v2sig) == len(desired_sig):
                    if len(ops) == 1:
                        wrong_position = test_sequence_without_run(v1sig, v2sig, sig_keys)
                    elif desired_runs < v1_runs:
                        without_edit = expected_without_edit(projection, oi, sig_keys)
                        wrong_position = test_sequence_without_run(without_edit, v2sig, sig_keys)
                if wrong_position:
                    res = "repeated deletion is at a different position in config"
                elif oi in replaced and not missing_deletion:
                    res = "absorbed"
                    c_at = -1
                elif c_at >= 0 and not missing_deletion:
                    res = "absorbed"
                elif not missing_deletion and stays and test_delete_absorbed(v2sig, before_ctx, after_ctx):
                    res = "absorbed"
                elif find_unique_run(v2norm, keys) >= 0:
                    p = find_unique_run(v2norm, keys)
                    res = "pending"
                elif v1_runs > 1 and find_run_in_context(v2norm, v2sig, v2map, keys, sig_keys, before_ctx, after_ctx) >= 0:
                    p = find_run_in_context(v2norm, v2sig, v2map, keys, sig_keys, before_ctx, after_ctx)
                    res = "pending"
                else:
                    if not missing_deletion and test_delete_absorbed(v2sig, before_ctx, after_ctx):
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
    for n in code_keys(protect_bsl_parameter_members(rename_code_words(convert_bsl_code(ext_method["body_lines"], {}, ep), renames), cp), prefix):
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
    hay = sig_lines(protect_bsl_parameter_members(cfg_method["body_lines"], cp), prefix)
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


# --- Property overrides of adopted elements (xr:PropertyState) ---

def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


# --- Copies from cfe-borrow (kept identical by check-cfe-prop-lists): how a declared property of an
# adopted element is treated. The extension's mode decides; these lists tell the exceptions ---
controlled_props = ['Type', 'Owners', 'Global', 'ClientManagedApplication', 'Server', 'ExternalConnection',
                    'ClientOrdinaryApplication', 'ServerCall', 'Hierarchical', 'CodeLength', 'DescriptionLength', 'CodeType',
                    'CodeAllowedLength', 'NumberType', 'NumberLength', 'NumberAllowedLength', 'InformationRegisterPeriodicity',
                    'WriteMode', 'LanguageCode', 'RegisteredDocuments', 'ExtDimensionTypes', 'MaxExtDimensionCount']
additive_props = ['RegisterRecords', 'Content']
no_override_props = ['Hierarchical', 'InformationRegisterPeriodicity', 'WriteMode', 'Global',
                     'ClientManagedApplication', 'Server', 'ExternalConnection', 'ClientOrdinaryApplication', 'ServerCall', 'CodeAllowedLength', 'LanguageCode']

# Properties the other stages bring: modules and forms are transfered as code, not as a property value
md_module_props = ('Module', 'ObjectModule', 'ManagerModule', 'RecordSetModule', 'ValueManagerModule', 'CommandModule', 'Form')
md_service_props = ('ObjectBelonging', 'Name', 'Comment', 'ExtendedConfigurationObject')

XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
md_qual_kind_by_type = {"string": "StringQualifiers", "decimal": "NumberQualifiers", "dateTime": "DateQualifiers", "base64Binary": "BinaryDataQualifiers"}
md_qual_order = ["NumberQualifiers", "StringQualifiers", "DateQualifiers", "BinaryDataQualifiers"]


def get_md_type_ref_base(kind, event_source=False):
    extra = re.fullmatch(r"(FilterCriterion|IntegrationService|WSReference|SettingsStorage|Bot|Sequence|DocumentJournal)(?:Manager|List|RecordSet)", kind)
    if extra:
        return extra[1]
    if re.fullmatch(r"ExternalDataSource(?:Table(?:Ref|Object|Manager|List|RecordSet|RecordManager|RecordKey|Record)?|CubesManager|Cube(?:Manager|RecordSet|Record|Selection)?|TablesManager|Manager)", kind):
        return "ExternalDataSource"
    """Type kinds that name a metadata object of the configuration; a *Ref kind looks up its base kind."""
    if kind == "Characteristic":
        return "ChartOfCharacteristicTypes"
    if re.fullmatch(r"ChartOfCharacteristicTypes(?:Object|Manager|Selection|List|TabularSectionRow|TabularSection)", kind):
        return "ChartOfCharacteristicTypes"
    if kind in ("ConstantManager", "ConstantValueManager", "ConstantValueKey"):
        return "Constant"
    if re.fullmatch(r"(BaseCalculationTypes|DisplacingCalculationTypes|LeadingCalculationTypes)(Row)?", kind):
        return "ChartOfCalculationTypes"
    if kind == "RecalculationsManager":
        return "CalculationRegister"
    if kind == "BusinessProcessRoutePointRef":
        return "BusinessProcess"
    if kind.endswith("Ref") and len(kind) > 3:
        return kind[:-3]
    match = re.fullmatch(r"(Report|DataProcessor)(?:Object|Manager|TabularSectionRow|TabularSection)", kind)
    if match:
        return match[1]
    match = re.fullmatch(r"(Document|InformationRegister|AccumulationRegister|AccountingRegister|CalculationRegister|ExchangePlan|"
                         r"BusinessProcess|Task|ChartOfAccounts|ChartOfCalculationTypes)"
                         r"(?:Object|Manager|RecordSet|RecordManager|RecordKey|Record|Selection|List|TabularSectionRow|"
                         r"TabularSection|ExtDimensions|ExtDimensionTypesRow|ExtDimensionTypes)", kind)
    if match:
        return match[1]
    if event_source:
        match = re.fullmatch(r"(.+?)(?:Object|RecordSet|Manager)", kind)
        if match and match[1] in CHILD_TYPE_DIR_MAP:
            return match[1]
    return kind


def resolve_md_reference(value, prefix, type_reference=False, event_source=False):
    match = re.fullmatch(r"((?:\w+:)?)(\w+)\.(\w+)((?:\.\w+)*)", value)
    if not match:
        return {"value": value}
    namespace, kind, name, tail = match.groups()
    base = get_md_type_ref_base(kind, event_source) if type_reference else kind
    if base not in CHILD_TYPE_DIR_MAP:
        return {"value": value}
    root_id = (base + "." + name).lower()
    provisional = ROOT_PROVISIONAL.get(root_id)
    if root_id in ROOT_OWN and root_id not in ROOT_BINDINGS and not provisional:
        return {"status": "WAITING", "reason": "waiting for %s.%s" % (base, name), "dependency": root_id}
    if MD_REFERENCE_POOLS is None:
        return {"status": "MANUAL", "reason": "configuration has no ChildObjects to resolve " + value}
    hits = find_names_in(MD_REFERENCE_POOLS.get(base, ()), name, prefix)
    if root_id in ROOT_BINDINGS:
        hits = [ROOT_BINDINGS[root_id]]
    if provisional:
        hits = [provisional["target"]]
    if not hits:
        return {"status": "WAITING", "reason": "%s.%s: the object is not in the configuration" % (base, name)}
    if len(hits) > 1 and hits[0].lower() != name.lower():
        return {"status": "MANUAL", "reason": "%s.%s: ambiguous target (%s)" % (base, name, ", ".join(hits))}
    target = hits[0]
    relative = os.path.join(CHILD_TYPE_DIR_MAP[base], target + ".xml")
    path = os.path.join(MD_REFERENCE_ROOT, relative)
    if not provisional and not os.path.isfile(path):
        return {"status": "MANUAL", "reason": "%s.%s: missing descriptor %s" % (base, target, relative.replace(os.sep, "/"))}
    if tail and tail != ".EmptyRef":
        item = re.fullmatch(r"\.(\w+)", tail)
        if base in PREDEFINED_KINDS and item:
            binding = BORROWED_PREDEFINED_BINDINGS.get(f"{root_id}.{item[1].lower()}")
            if binding:
                if binding.get("status"):
                    return binding
                return {"value": f"{namespace}{kind}.{target}.{binding['name']}"}
            file = os.path.join(MD_REFERENCE_ROOT, CHILD_TYPE_DIR_MAP[base], target, "Ext", "Predefined.xml")
            if provisional:
                file = provisional["predefined_path"]
            if os.path.isfile(file):
                names = read_form_write(file)["root"].findall(f".//{PREDEFINED_NS}Item/{PREDEFINED_NS}Name")
                if sum(inner_text(n).lower() == item[1].lower() for n in names) == 1:
                    return {"value": f"{namespace}{kind}.{target}{tail}"}
            return {"status": "WAITING", "reason": f"predefined item {base}.{target}.{item[1]} is not in the configuration",
                    "dependency": root_id}
        child_path = re.fullmatch(r"\.(Form|Template|Command)\.(\w+)", tail, re.I)
        if child_path:
            binding = get_catalog_child_binding(f"{root_id}.{child_path[1]}.{child_path[2]}")
            if binding.get("status"):
                return binding
            if binding:
                return {"value": f"{namespace}{kind}.{target}.{binding['kind']}.{binding['target']}"}
        owner = (provisional["md"] if provisional else read_md_object(path))["children"]
        parts = tail[1:].split(".")
        if type_reference and kind.startswith("ExternalDataSourceTable") and len(parts) == 1:
            parts.insert(0, "Table")
        if len(parts) % 2:
            return {"status": "MANUAL", "reason": "unsupported metadata path: " + value}
        tail = ""
        for tag, member in zip(parts[::2], parts[1::2]):
            nodes = {md_child_name(x).lower(): x for x in elem_children(owner) if localname(x) == tag} if owner is not None else {}
            members = find_names_in([md_child_name(x) for x in nodes.values()], member, prefix)
            if base == "Enum" and tag == "EnumValue" and root_id in ROOT_OWN:
                expected = ROOT_OWN[root_id]["value_ids"].get(member.lower())
                matches_by_id = [md_child_name(x) for x in nodes.values() if expected and x.get("uuid") == expected]
                if len(matches_by_id) == 1:
                    members = matches_by_id
            if not members:
                return {"status": "WAITING", "reason": "%s: %s.%s is not in the configuration" % (value, tag, member)}
            if len(members) > 1 and members[0].lower() != member.lower():
                return {"status": "MANUAL", "reason": "%s has ambiguous members (%s)" % (value, ", ".join(members))}
            tail += "." + tag + "." + members[0]
            owner = nodes[members[0].lower()].find("md:ChildObjects", MD_NSMAP)
    if type_reference and kind.startswith("ExternalDataSourceTable"):
        tail = re.sub(r"^\.Table\.", ".", tail)
    return {"value": namespace + kind + "." + target + tail}


def get_md_node_references(node, prefix, project):
    values = []
    for leaf in node.xpath(".//v8:Type|.//v8:TypeSet|.//md:FillValue[@xsi:type='xr:DesignTimeRef']",
                           namespaces={**MD_NSMAP, "xsi": XSI_NS}):
        value = inner_text(leaf).strip()
        if project:
            ref = resolve_md_reference(value, prefix, localname(leaf) != "FillValue")
            if ref.get("status"):
                return ref
            value = ref["value"]
            leaf.text = value
        values.append(value)
    return {"values": values}


def new_md_reference_item(label, reference):
    item = new_item(reference["status"], label + " — " + reference["reason"])
    item["plan"] = {"kind": "md-reference"}
    return item


def find_stale_md_reference(existing, target, prefix, type_reference=False):
    key = get_name_key(target, prefix).lower()
    for value in existing:
        if value.lower() == target.lower() or get_name_key(value, prefix).lower() != key:
            continue
        actual = resolve_md_reference(value, prefix, type_reference)
        if actual.get("status") or actual["value"].lower() != value.lower():
            return value
    return None


def get_md_property_states(el):
    """Modes of one element: property -> Notify / MultiState / Extended, from InternalInfo/PropertyState."""
    states = {}
    if el is None:
        return states
    ii = None
    for c in elem_children(el):
        if localname(c) == "InternalInfo":
            ii = c
            break
    if ii is None:
        return states
    for ps in elem_children(ii):
        if localname(ps) != "PropertyState":
            continue
        p = s = ""
        for x in elem_children(ps):
            if localname(x) == "Property":
                p = inner_text(x).strip()
            elif localname(x) == "State":
                s = inner_text(x).strip()
        if p and s and p not in states:
            states[p] = s
    return states


def get_md_type_entry_key(local, value, prefix):
    """Comparable key of one type entry: kind|value, without the namespace prefix, an object name
    without the extension prefix — the configuration has the name the transfer gives it."""
    v = re.sub(r'^[\w]+:', '', (value or "").strip())
    i = v.find(".")
    if i >= 0 and prefix:
        v = v[:i + 1] + get_name_key(v[i + 1:], prefix)
    return (local + "|" + v).lower()


def get_md_type_model(type_el, prefix):
    """Composition of a <Type>: type entries with their keys and the qualifier elements by kind."""
    types = []
    quals = {}
    if type_el is not None:
        for c in elem_children(type_el):
            if localname(c) in ("Type", "TypeSet", "TypeId"):
                val = inner_text(c).strip()
                types.append({"local": localname(c), "value": val, "key": get_md_type_entry_key(localname(c), val, prefix)})
            elif localname(c).endswith("Qualifiers"):
                quals[localname(c)] = c
    return {"types": types, "quals": quals}


def get_md_type_qual_kind(t):
    """Qualifier element a type entry of the model needs, '' when the type has none."""
    v = re.sub(r'^[\w]+:', '', t["value"])
    if "." in v:
        return ""
    return md_qual_kind_by_type.get(v, "")


def get_md_qual_value(q, local):
    if q is None:
        return ""
    for c in elem_children(q):
        if localname(c) == local:
            return inner_text(c).strip()
    return ""


def format_md_type_model(model):
    """Short type composition for the report: String(20), Number(10,2), CatalogRef.X."""
    parts = []
    for t in model["types"]:
        v = re.sub(r'^[\w]+:', '', t["value"])
        k = get_md_type_qual_kind(t)
        q = model["quals"].get(k) if t["local"] == "Type" else None
        if v == "string":
            v = ("String(%s)" % get_md_qual_value(q, "Length")) if q is not None else "String"
        elif v == "decimal":
            v = ("Number(%s,%s)" % (get_md_qual_value(q, "Digits"), get_md_qual_value(q, "FractionDigits"))) if q is not None else "Number"
        elif v == "boolean":
            v = "Boolean"
        elif v == "dateTime":
            v = "Date"
        parts.append(v)
    return ", ".join(parts)


def test_md_type_model_equal(a, b):
    """Same composition of a type: the same entries (their order is not a value) and qualifiers."""
    if len(a["types"]) != len(b["types"]):
        return False
    for t in a["types"]:
        if not any(x["key"] == t["key"] for x in b["types"]):
            return False
    for k in set(a["quals"]) | set(b["quals"]):
        if k not in a["quals"] or k not in b["quals"]:
            return False
        if node_canon(a["quals"][k]) != node_canon(b["quals"][k]):
            return False
    return True


def test_md_type_model_includes(cfg, ext):
    """Every type of the part is in the configuration with the qualifiers the part declares for it."""
    for t in ext["types"]:
        ct = next((x for x in cfg["types"] if x["key"] == t["key"]), None)
        if ct is None:
            return False
        k = get_md_type_qual_kind(t)
        if not k or k not in ext["quals"]:
            continue
        if k not in cfg["quals"]:
            return False
        if node_canon(ext["quals"][k]) != node_canon(cfg["quals"][k]):
            return False
    return True


def get_md_missing_type_text(cfg, ext):
    """Types of the part the configuration does not have yet, as a short text."""
    parts = []
    for t in ext["types"]:
        if any(x["key"] == t["key"] for x in cfg["types"]):
            continue
        parts.append(format_md_type_model({"types": [t], "quals": ext["quals"]}))
    return ", ".join(parts)


def get_md_type_merge_conflict(cfg, ext):
    """Why the part cannot be merged into the configuration, '' when it can."""
    for t in ext["types"]:
        if t["local"] == "TypeId":
            return "a generated type identifier cannot be transferred"
        k = get_md_type_qual_kind(t)
        if not k:
            continue
        has = k in ext["quals"]
        cfg_has = k in cfg["quals"]
        ct = next((x for x in cfg["types"] if x["key"] == t["key"]), None)
        ext_one = format_md_type_model({"types": [t], "quals": ext["quals"]})
        if ct is not None:
            if has != cfg_has:
                return "the qualifiers differ (%s)" % ext_one
            if has and node_canon(ext["quals"][k]) != node_canon(cfg["quals"][k]):
                return "the configuration already has %s, the extension declares %s" % (
                    format_md_type_model({"types": [ct], "quals": cfg["quals"]}), ext_one)
        elif cfg_has:
            # The kind belongs to another type already: adding this one would change that type too
            if not has or node_canon(ext["quals"][k]) != node_canon(cfg["quals"][k]):
                return "the configuration already has %s for another type, the extension declares %s" % (k, ext_one)
    return ""


def test_md_scalar_prop(p):
    """A property value the transfer can write: no element children, only xsi:type / xsi:nil attributes."""
    for c in p:
        if isinstance(c.tag, str):
            return False
    for a in p.attrib:
        if not a.startswith("{%s}" % XSI_NS):
            return False
        if a.rsplit("}", 1)[-1] not in ("type", "nil"):
            return False
    return True


def format_md_prop_value(p):
    if p is None:
        return "—"
    if has_element_child(p):
        return "{…}"
    t = inner_text(p).strip()
    if not t:
        if p.get("{%s}nil" % XSI_NS) is not None:
            return "nil"
        return "—"
    return get_short(t, 30)


def get_md_props_element(el):
    if el is None:
        return None
    for c in elem_children(el):
        if localname(c) == "Properties":
            return c
    return None


def get_md_prop_node(props, prop):
    if props is None:
        return None
    for c in elem_children(props):
        if localname(c) == prop:
            return c
    return None


def add_md_prop_items(items, ext_el, cfg_el, prefix, rank, rel, obj_type, tag, name, parent, subject, is_object):
    """Items of the property overrides one adopted element declares: Extended scalars are transfered
    (the config's own element gets the value, its uuid and name stay), a type extension is merged into
    the config's <Type>; Notify and a difference without a mode are shown but never written."""
    if ext_el is None:
        return
    ext_props = get_md_props_element(ext_el)
    if ext_props is None:
        return
    states = get_md_property_states(ext_el) if rank >= 219 else {}
    cfg_props = get_md_props_element(cfg_el)
    elem_missing = cfg_el is None

    def new_plan(mode, why, next_="", prop=""):
        pl = {"kind": "md-prop", "rel": rel, "obj_type": obj_type, "tag": tag, "name": name,
              "parent": parent, "prop": prop, "mode": mode}
        if why:
            pl["conflict"] = why
        if next_:
            pl["next"] = next_
        return pl

    for p in elem_children(ext_props):
        prop = localname(p)
        if prop in md_service_props or prop in md_module_props or prop in additive_props:
            continue
        if (is_object and re.fullmatch(r"(Default|Auxiliary).*Form", prop)
                and inner_text(p).strip().lower() in CATALOG_CHILDREN):
            continue
        state = states.get(prop, "")
        at = ("%s property %s" % (subject, prop)) if is_object else ("%s.%s" % (subject, prop))

        # Type extension: the extension declares parts; the configuration gets the missing types
        if rank >= 219 and prop == "Type":
            is_xp = any(a.rsplit("}", 1)[-1] == "type" and "ExtendedProperty" in (p.attrib[a] or "") for a in p.attrib)
            if state == "MultiState" or is_xp:
                parts = [c for c in elem_children(p) if localname(c) == "ExtendValue"]
                if not parts:
                    continue
                ex = {"types": [], "quals": {}}
                for pt in parts:
                    projected = copy.deepcopy(pt)
                    ref = get_md_node_references(projected, prefix, True)
                    if ref.get("status"):
                        break
                    m = get_md_type_model(projected, "")
                    ex["types"] += m["types"]
                    for k, v in m["quals"].items():
                        ex["quals"].setdefault(k, v)
                if ref.get("status"):
                    items.append(new_md_reference_item(at, ref))
                    continue
                cfg_type = get_md_prop_node(cfg_props, "Type")
                why = ""
                if elem_missing:
                    why = "the element is not in the configuration"
                elif cfg_type is None:
                    why = "the element has no type in the configuration"
                else:
                    cfg_model = get_md_type_model(cfg_type, "")
                    stale = next((hit for t in ex["types"]
                                  if (hit := find_stale_md_reference(
                                      (c["value"] for c in cfg_model["types"] if c["local"] == t["local"]),
                                      t["value"], prefix, True))), None)
                    if stale:
                        items.append(new_md_reference_item(at, {"status": "CONFLICT", "reason":
                                     "existing reference %s does not resolve to its registered target" % stale}))
                        continue
                    why = get_md_type_merge_conflict(cfg_model, ex)
                if why:
                    ni = new_item("DIVERGED", "%s — %s" % (at, why))
                    ni["plan"] = new_plan("TypeExtend", why,
                                          "next: compare the types and merge by hand, then re-run -Mode check", "Type")
                    items.append(ni)
                    continue
                if test_md_type_model_includes(get_md_type_model(cfg_type, ""), ex):
                    items.append(new_item("TRANSFERRED", at))
                    continue
                ni = new_item("NOT_TRANSFERRED", "%s: + %s" % (at, get_md_missing_type_text(get_md_type_model(cfg_type, ""), ex)))
                pl = new_plan("TypeExtend", "")
                pl.update({"prop": "Type", "node": p, "parts": parts, "ext_model": ex})
                ni["plan"] = pl
                items.append(ni)
                continue
            if state == "Extended":
                ni = new_item("MANUAL", "%s (mode: Extended) — the platform does not apply a single override of the type; compare by hand" % at)
                ni["manual"] = True
                items.append(ni)
                continue

        cfg_p = get_md_prop_node(cfg_props, prop)
        # An empty element in the shell declares no value: nothing to compare and nothing to report
        declared = inner_text(p).strip() != "" or has_element_child(p) or bool(p.attrib)
        if not declared and state != "Extended":
            continue
        differs = True
        if cfg_p is not None:
            if prop == "Type":
                # The order of the type entries is not a value: the same set is the same type
                differs = not test_md_type_model_equal(get_md_type_model(p, prefix), get_md_type_model(cfg_p, ""))
            else:
                differs = cmp_key(p, prefix) != cmp_key(cfg_p, "")

        if state == "Extended":
            if prop in no_override_props:
                ni = new_item("MANUAL", "%s (mode: Extended) — override mode is not supported for this property" % at)
                ni["manual"] = True
                items.append(ni)
                continue
            if not test_md_scalar_prop(p):
                ni = new_item("MANUAL", "%s (mode: Extended) — not a scalar; not transferred by this stage" % at)
                ni["manual"] = True
                items.append(ni)
                continue
            if cfg_p is None:
                why = "the element is not in the configuration" if elem_missing else "the property is not in the configuration"
                ni = new_item("DIVERGED", "%s — %s" % (at, why))
                ni["plan"] = new_plan("Scalar", why,
                                      "next: add it by hand if it belongs in the configuration, then re-run -Mode check", prop)
                items.append(ni)
                continue
            if not differs:
                items.append(new_item("TRANSFERRED", at))
                continue
            ni = new_item("NOT_TRANSFERRED", "%s: %s vs %s in config" % (at, format_md_prop_value(p), format_md_prop_value(cfg_p)))
            pl = new_plan("Scalar", "", "", prop)
            pl["node"] = p
            pl["value"] = inner_text(p)
            pl["xml_type"] = p.get("{%s}type" % XSI_NS)
            pl["nil"] = p.get("{%s}nil" % XSI_NS) == "true"
            ni["plan"] = pl
            items.append(ni)
            continue

        if state == "Notify":
            if cfg_p is None:
                why = "the element is not in the configuration" if elem_missing else "the property is not in the configuration"
                ni = new_item("MANUAL", "%s (mode: Notify) — %s" % (at, why))
                ni["manual"] = True
                items.append(ni)
                continue
            if not differs:
                continue
            ni = new_item("MANUAL", "%s (mode: Notify): %s vs %s in config — the platform only warns, the extension is not applied; the configuration keeps its value"
                          % (at, format_md_prop_value(p), format_md_prop_value(cfg_p)))
            ni["manual"] = True
            items.append(ni)
            continue

        # No mode: with no override declared this is a stale snapshot, not a change to move
        if cfg_p is None:
            why = "the element is not in the configuration" if elem_missing else "the property is not in the configuration"
            ni = new_item("MANUAL", "%s — %s" % (at, why))
            ni["manual"] = True
            items.append(ni)
            continue
        if not differs:
            continue
        if rank >= 219:
            msg = "%s — no override mode: the platform will not apply it — align the extension or change the configuration by hand"
        else:
            msg = "%s — the value differs (this format has no override modes); compare by hand"
        ni = new_item("MANUAL", msg % at)
        ni["manual"] = True
        items.append(ni)


# --- ChildObjects canon (verbatim from meta-edit, kept identical by check-inline-drift) ---
def object_child_order():
    """Порядок групп в <ChildObjects> объекта по виду. Это xs:sequence <Вид>ChildObjects из MDClasses XSD,
    сверенный выгрузкой платформы: выгрузка сама ставит группы в этот порядок, так что вставка не на место
    даёт дифф при следующей выгрузке. Единого порядка нет — у документа Form стоит до TabularSection."""
    return {
        "Catalog":                    ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "Document":                   ["Attribute", "Form", "TabularSection", "Template", "Command"],
        "ExchangePlan":               ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "ChartOfCharacteristicTypes": ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "ChartOfAccounts":            ["Attribute", "TabularSection", "AccountingFlag", "ExtDimensionAccountingFlag", "Form", "Template", "Command"],
        "ChartOfCalculationTypes":    ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "BusinessProcess":            ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "Task":                       ["Attribute", "TabularSection", "Form", "Template", "AddressingAttribute", "Command"],
        "DataProcessor":              ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "Report":                     ["Attribute", "TabularSection", "Form", "Template", "Command"],
        "ExternalDataProcessor":      ["Attribute", "TabularSection", "Form", "Template"],
        "ExternalReport":             ["Attribute", "TabularSection", "Form", "Template"],
        "Enum":                       ["EnumValue", "Form", "Template", "Command"],
        "InformationRegister":        ["Resource", "Attribute", "Dimension", "Form", "Template", "Command"],
        "AccumulationRegister":       ["Resource", "Attribute", "Dimension", "Form", "Template", "Command"],
        "AccountingRegister":         ["Dimension", "Resource", "Attribute", "Form", "Template", "Command"],
        "CalculationRegister":        ["Resource", "Attribute", "Dimension", "Recalculation", "Form", "Template", "Command"],
        "DocumentJournal":            ["Column", "Form", "Template", "Command"],
        "Table":                      ["Field", "Form", "Command", "Template"],
        "ExternalDataSource":         ["Table", "Cube", "Function"],
        "Cube":                       ["DimensionTable", "Dimension", "Resource", "Form", "Command", "Template"],
        "DimensionTable":             ["Field", "Form", "Command", "Template"],
        "FilterCriterion":            ["Form", "Command"],
        "SettingsStorage":            ["Form", "Template"],
        "TabularSection":             ["Attribute"],
    }


def find_child_anchor(container, tag, obj_type):
    """Элемент <ChildObjects>, ПЕРЕД которым встаёт новый <tag>; None — дописать в конец.
    Сразу за последним элементом своего тега, иначе перед первым элементом группы, идущей
    по канону вида позже. Вид или тег вне канона — None, как раньше."""
    children = [c for c in container if isinstance(c.tag, str)]
    last_idx = -1
    for i, c in enumerate(children):
        if c.tag.rsplit('}', 1)[-1] == tag:
            last_idx = i
    if last_idx >= 0:
        return children[last_idx + 1] if last_idx + 1 < len(children) else None
    order = object_child_order().get(obj_type)
    if not order or tag not in order:
        return None
    later = order[order.index(tag) + 1:]
    for c in children:
        if c.tag.rsplit('}', 1)[-1] in later:
            return c
    return None


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
def form_localized_text(node):
    if node is None:
        return ()
    return tuple(inner_text(n).replace("\r\n", "\n").replace("\r", "\n")
                 for n in node.iter("{%s}content" % NSMAP["v8"]))


def prop_transfer(cpm, p, prefix, scope, name_map):
    """One property change of the extension against the configuration: 'ok' (the extension's
    value), 'pending' (still the BaseForm value) or 'differs' (changed in the configuration some
    other way)."""
    current = cpm.get(p["key"])
    bad = []
    cv = lower_or_none(get_form_property_key(current, prefix))
    nv = lower_or_none(get_form_property_key(p["new"], prefix, scope, name_map, bad))
    ov = lower_or_none(get_form_property_key(p["old"], prefix, scope, name_map, bad))
    if bad:
        return "differs"
    if cv == nv and form_localized_text(current) == form_localized_text(p["new"]):
        return "ok"
    # A property the configuration never had: the extension's own, still to be added
    if p["old"] is None and not cv:
        return "pending"
    if cv == ov and form_localized_text(current) == form_localized_text(p["old"]):
        return "pending"
    return "differs"


def get_form_transfer_marks(index, lines):
    marks = get_form_temp_marks(lines)
    if not marks:
        return marks
    for rec in index.values():
        for ancestor in rec["ancestors"]:
            if ancestor.lower() in marks:
                marks.setdefault(rec["name"].lower(), marks[ancestor.lower()])
                break
    for rec in index.values():
        key = rec["name"].lower()
        if key in marks or localname(rec["node"]) not in ("SearchStringAddition", "SearchControlAddition", "ViewStatusAddition"):
            continue
        source = rec["node"].find("d:AdditionSource/d:Item", NSMAP)
        source_name = inner_text(source).strip() if source is not None else ""
        if source_name.lower() in marks:
            marks[key] = "depends on excluded source " + source_name
    return marks


def form_transfer_items(diff, form, cfg_form_xml, cfg_module_path, ext_dir, prefix, form_interceptors=None):
    items = []
    group = form["label"]
    cfg_doc = read_form_doc(cfg_form_xml)
    if cfg_doc is None:
        items.append(new_item("MISSING_IN_CONFIG", "form not found in config (%d changes)" % diff["total"], "", group))
        return items
    cr = cfg_doc.getroot()
    ci = form_element_index(cr)
    c_names = index_names(ci)
    cfg_mod = read_bsl_lines(cfg_module_path)
    reference_scope = get_form_reference_scope(diff["root"], cr, prefix, cfg_mod)
    reference_names = get_form_name_map(diff["root"], cr, prefix)

    def as_text(found, orig):
        if found and found.lower() != orig.lower():
            return " (found as %s)" % found
        return ""

    # Items the form module marks "not for transfer", with everything inside them
    ext_mod = read_bsl_lines(form["module"])
    tmarks = get_form_transfer_marks(diff["main_index"], ext_mod)

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
            if hit and localname(ci[hit.lower()]["node"]) != localname(rec["node"]):
                compatible = next((name for name in find_names_in(c_names, rec["name"], prefix)
                                   if localname(ci[name.lower()]["node"]) == localname(rec["node"])), None)
                if compatible is None:
                    actual = localname(ci[hit.lower()]["node"])
                    items.append(marked(new_item("DIVERGED", "+ %s %s%s (name %s is occupied by %s)" %
                                                 (tag, rec["name"], inn, hit, actual), "", group), own))
                    continue
                hit = compatible
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            ni = marked(new_item(st, "+ %s %s%s%s" % (tag, rec["name"], inn, as_text(hit, rec["name"])), "", group), own)
            if not hit:
                ni["plan"] = {"kind": "element", "rec": rec}
                ni["plan_key"] = "+ %s %s" % (tag, rec["name"])
            items.append(ni)
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
                    r = prop_transfer(cpm, p, prefix, reference_scope, reference_names)
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
                ni = marked(new_item(st, "~ %s %s: %s%s" % (tag, rec["name"], ", ".join(keys), cnt), "", group), own)
                # Only the properties still at their BaseForm value: a value changed in the configuration some
                # other way stays as it is and is left to a person
                pend = [p for p in ch["props"] if prop_transfer(cpm, p, prefix, reference_scope, reference_names) == "pending"]
                if pend:
                    ni["plan"] = {"kind": "prop", "rec": rec, "props": pend}
                    ni["plan_key"] = "~ %s %s: %s" % (tag, rec["name"], ", ".join(keys))
                items.append(ni)
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
            ni = marked(new_item(st, "> %s %s: %s" % (tag, rec["name"], move_text(ch)), "", group), own)
            if st != "TRANSFERRED":
                ni["plan"] = {"kind": "move", "rec": rec}
                ni["plan_key"] = "> %s %s" % (tag, rec["name"])
            items.append(ni)

    # Interceptor of a handler: the extension's handler code looked up in the configuration's one
    mod_rel = rel_path(ext_dir, form["module"]) if form["module"] and os.path.isfile(form["module"]) else ""
    ext_method_names = Counter(name.lower() for name in get_proc_names(ext_mod or []))
    cfg_method_names = Counter(name.lower() for name in get_proc_names(cfg_mod or []))

    def check_handler(label, ext_handler, cfg_handler, missing):
        ext_m = get_method_safe(ext_mod, ext_handler)
        cfg_m = get_method_safe(cfg_mod, cfg_handler)
        loc = ("%s:%d" % (mod_rel, ext_m["decl_idx"] + 1)) if ext_m and mod_rel else ""
        mark = get_method_temp_mark(ext_mod, ext_m) if ext_m else None
        reason = None
        if ext_method_names[(ext_handler or "").lower()] > 1 or cfg_method_names[(cfg_handler or "").lower()] > 1:
            reason = "multiple declarations of the same handler"
        elif method_crosses_branch(ext_mod, ext_m) or method_crosses_branch(cfg_mod, cfg_m):
            reason = "handler crosses a preprocessor branch boundary"
        elif (ext_m and cfg_m
              and method_condition_key(method_conditions(ext_m["chain"])) != method_condition_key(method_conditions(cfg_m["chain"]))):
            reason = "preprocessor condition differs"
        if reason:
            manual = new_item("MANUAL", "%s (%s)" % (label, reason), loc, group)
            manual["plan"] = {"kind": "form-handler", "rel": mod_rel, "ext_m": ext_m, "cfg_m": cfg_m,
                              "manual_reason": reason, "blocked_handlers": [ext_handler]}
            return set_temp_mark(manual, mark, label)
        if not cfg_handler:
            return set_temp_mark(new_item("NOT_TRANSFERRED", "%s (%s)" % (label, missing), loc, group), mark, label)
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
                    label = "command %s[%s] -> %s" % (x["name"], a["call_type"], a["handler"])
                    it = check_handler(label, a["handler"], cfg_handler, "no action of %s in config" % x["name"])
                    kind = get_call_type_kind(a["call_type"])
                    ext_m = get_method_safe(ext_mod, a["handler"]) if a["handler"] else None
                    cfg_m = get_method_safe(cfg_mod, cfg_handler) if cfg_handler else None
                    if it and not it.get("plan", {}).get("manual_reason") and kind and ext_m and cfg_m and it["status"] != "TRANSFERRED":
                        it["plan"] = {"kind": "intercept", "type": kind, "ext_m": ext_m, "cfg_m": cfg_m, "rel": mod_rel, "label": label}
                        it["plan_key"] = label
                    if it:
                        it = marked(it, [x["name"]])
                        items.append(it)
                    if form_interceptors is not None and kind and cfg_m:
                        form_interceptors.append((mod_rel, cfg_m["decl_idx"], it))
                continue
            if word == "attribute":
                matches = find_scoped_form_names(cn, x["name"], prefix, reference_scope["attributes"])
                if len(matches) > 1 and matches[0].lower() != x["name"].lower():
                    label = "+ attribute %s%s (matches %s; choose the intended target)" % (x["name"], x["info"], ", ".join(matches))
                    items.append(marked(new_item("MANUAL", label, "", group), [x["name"]]))
                    continue
                hit = matches[0] if matches else None
            else:
                hit = find_name_in(cn, x["name"], prefix)
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            ni = marked(new_item(st, "+ %s %s%s%s" % (word, x["name"], x["info"], as_text(hit, x["name"])), "", group), [x["name"]])
            # A command whose action intercepts a method is a transfer of its own kind. A command the
            # configuration lacks is the extension's own even when its action carries callType — there is no
            # handler to intercept: it goes as a command, with its handler as an own method and the callType
            # dropped on the write
            ct_actions = [a for a in x["actions"] if a["call_type"]]
            if not hit:
                cmd_own = []
                if word == "command" and ni["status"] != "TEMPORARY":
                    for a in x["actions"]:
                        handler = check_handler(ni["text"], a["handler"], "", "")
                        if not handler.get("plan", {}).get("manual_reason"):
                            continue
                        ni = handler
                        ni["plan"]["blocked_handlers"] = [action["handler"] for action in x["actions"]]
                        break
                if ni.get("plan", {}).get("manual_reason"):
                    items.append(ni)
                    continue
                if word == "command" and ct_actions:
                    for a in ct_actions:
                        m = get_method_safe(ext_mod, a["handler"]) if a["handler"] else None
                        if m is not None:
                            cmd_own.append({"handler": a["handler"], "ext_m": m})
                if cmd_own:
                    ni["plan"] = {"kind": "command-bind", "node": x["node"], "name": x["name"],
                                  "handlers": cmd_own, "ext_lines": ext_mod, "rel": mod_rel}
                    ni["plan_key"] = "+ %s %s" % (word, x["name"])
                elif not ct_actions:
                    ni["plan"] = {"kind": word if word != "parameter" else "parameter", "node": x["node"], "name": x["name"]}
                    if word == "command":
                        ni["plan"]["rel"] = mod_rel
                        ni["plan"]["handlers"] = [
                            {"handler": action["handler"], "ext_m": method}
                            for action in x["actions"]
                            if (method := get_method_safe(ext_mod, action["handler"]))
                        ]
                    ni["plan_key"] = "+ %s %s" % (word, x["name"])
            items.append(ni)

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
            ni = marked(new_item(st, label + as_text(hit, c["name"]), "", group), [c["attr"], "%s.%s" % (c["attr"], c["name"])])
            if not hit:
                ni["plan"] = {"kind": "column", "node": c["node"], "attr": c["attr"]}
                ni["plan_key"] = label
            items.append(ni)

    if diff["form_props"]:
        cpm = get_prop_map(cr, root=True)
        for p in diff["form_props"]:
            r = prop_transfer(cpm, p, prefix, reference_scope, reference_names)
            st = {"ok": "TRANSFERRED", "pending": "NOT_TRANSFERRED"}.get(r, "DIVERGED")
            why = " (config value differs)" if r == "differs" else ""
            ni = new_item(st, "~ form " + prop_change_text(p) + why, "", group)
            if r == "pending":
                ni["plan"] = {"kind": "formprop", "props": [p], "ext_root": diff["root"]}
                ni["plan_key"] = "~ form " + p["key"]
            items.append(ni)
    # Conditional appearance rules: an added one must be among the configuration's rules, a removed one not
    if diff["appearance"]:
        rules = cr.findall("d:Attributes/d:ConditionalAppearance/dcsset:item", NSMAP)
        have = [get_form_property_key(x, prefix) for x in rules]
        old_keys = [cmp_key(x, prefix) for x in rules]
        for a in diff["appearance"]:
            bad = []
            inn = get_form_property_key(a["node"], prefix, reference_scope, reference_names, bad) in have
            mk = "+" if a["kind"] == "added" else "-"
            label = "%s conditional appearance rule %s" % (mk, appearance_text(a["node"]))
            if bad or (not inn and cmp_key(a["node"], prefix) in old_keys):
                reason = bad[0] if bad else "form references differ"
                items.append(new_item("DIVERGED", "%s (%s)" % (label, reason), "", group))
                continue
            done = inn if a["kind"] == "added" else not inn
            ni = new_item("TRANSFERRED" if done else "NOT_TRANSFERRED", label, "", group)
            if not done:
                ni["plan"] = {"kind": "appearance", "rule": a["node"], "add": a["kind"] == "added"}
                ni["plan_key"] = "%s conditional appearance rule %s" % (mk, appearance_text(a["node"]))
            items.append(ni)
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
        kind = get_call_type_kind(e["call_type"])
        ext_m = get_method_safe(ext_mod, e["handler"]) if e["handler"] else None
        cfg_m = get_method_safe(cfg_mod, cfg_handler) if cfg_handler else None
        if it and not it.get("plan", {}).get("manual_reason") and kind and ext_m and cfg_m and it["status"] != "TRANSFERRED":
            it["plan"] = {"kind": "intercept", "type": kind, "ext_m": ext_m, "cfg_m": cfg_m, "rel": mod_rel,
                          "label": "event " + event_text(e)}
            it["plan_key"] = "event " + event_text(e)
        # An event the configuration has no handler for — whatever its callType: there is nothing to intercept,
        # the event is the extension's own. It goes into the configuration's form and its handler as own method
        if it and not it.get("plan", {}).get("manual_reason") and ext_m and not cfg_handler and it["status"] != "TRANSFERRED":
            it["plan"] = {"kind": "event-bind", "ext_m": ext_m, "ext_lines": ext_mod, "rel": mod_rel,
                          "scope": e["scope"], "name": e["name"], "handler": e["handler"]}
            it["plan_key"] = "event " + (e["scope"] + "." if e["scope"] else "") + e["name"]
        if it:
            it = marked(it, [e["scope"]])
            items.append(it)
        if form_interceptors is not None and kind and cfg_m:
            form_interceptors.append((mod_rel, cfg_m["decl_idx"], it))
    # An element of BaseForm the main part lacks: the extension cannot drop a borrowed element, so the
    # configuration's form has changed since the borrowing
    for nm in diff["removed"]:
        items.append(new_item("DIVERGED", "! %s (in BaseForm, not in the extension's form: the configuration's form changed since the borrowing)" % nm, "", group))
    return items


def get_call_type_kind(call_type):
    """A form event or command action with callType intercepts the configuration's handler: same kinds as the
    module annotations."""
    ct = (call_type or "").strip().lower()
    return {"before": "Перед", "after": "После", "override": "Вместо"}.get(ct)


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

def own_method_parameters(text):
    clean = "\n".join(get_code_only(text.splitlines(), True)).strip()
    if not clean:
        return []
    pattern = re.compile(r'^\s*(?:(' + kw_alt("Val") + r')\s+)?\w+\s*(?:=\s*(.+))?$', re.I | re.S)
    keywords = {'истина': 'true', 'ложь': 'false', 'неопределено': 'undefined'}
    parameters = []
    for part in split_top_level(clean):
        match = pattern.match(part)
        if not match:
            return None
        modifier, default = match.groups()
        if default is not None:
            default = default.strip()
            if not default.startswith('"'):
                normalized = re.sub(r'\s+', '', default).lower()
                default = keywords.get(normalized, normalized)
        parameters.append((modifier is not None, default))
    return parameters


def own_method_context(method):
    context = method["context"].lstrip("&").lower()
    for ru, en in zip(BSL_KW["ru"]["Directives"], BSL_KW["en"]["Directives"]):
        if context in (ru.lower(), en.lower()):
            return en.lower()
    return context


def method_conditions(chain):
    return [frame["cond"] for frame in chain if frame["kind"] == "if"]


def method_crosses_branch(lines, method):
    if not method:
        return False
    depth = 0
    for line in lines[method["decl_idx"]:method["body_end_idx"] + 1]:
        if re.match(r'^\s*#\s*(?:Если|If)\b', line, re.I):
            depth += 1
        elif re.match(r'^\s*#\s*(?:КонецЕсли|EndIf)\b', line, re.I):
            if depth == 0:
                return True
            depth -= 1
        elif depth == 0 and re.match(r'^\s*#\s*(?:ИначеЕсли|Иначе|ElsIf|Else)\b', line, re.I):
            return True
    return depth != 0


# Compare the existing condition expressions without attempting logical simplification.
PREPROCESSOR_WORDS = {
    'не': 'not', 'и': 'and', 'или': 'or', 'клиент': 'client', 'сервер': 'server',
    'наклиенте': 'atclient', 'насервере': 'atserver', 'внешнеесоединение': 'externalconnection',
    'тонкийклиент': 'thinclient', 'вебклиент': 'webclient', 'мобильныйклиент': 'mobileclient',
    'толстыйклиентобычноеприложение': 'thickclientordinaryapplication',
    'толстыйклиентуправляемоеприложение': 'thickclientmanagedapplication',
    'мобильноеприложениеклиент': 'mobileappclient', 'мобильноеприложениесервер': 'mobileappserver',
    'мобильныйавтономныйсервер': 'mobilestandaloneserver',
}


def method_condition_key(conditions):
    return "\n".join(
        " ".join(PREPROCESSOR_WORDS.get(word, word) for word in re.findall(r'\w+|[^\s]', condition.lower()))
        for condition in conditions)


def own_declaration_difference(ext_lines, ext_method, cfg_lines, cfg_method):
    if ext_method["is_function"] != cfg_method["is_function"]:
        return "procedure/function differs"
    if ext_method["is_async"] != cfg_method["is_async"]:
        return "Async modifier differs"
    if is_export(ext_lines, ext_method) != is_export(cfg_lines, cfg_method):
        return "Export modifier differs"
    if own_method_context(ext_method) != own_method_context(cfg_method):
        return "execution context differs"
    if method_condition_key(method_conditions(ext_method["chain"])) != method_condition_key(method_conditions(cfg_method["chain"])):
        return "preprocessor condition differs"
    left = own_method_parameters(ext_method["params_text"])
    right = own_method_parameters(cfg_method["params_text"])
    if left is None or right is None:
        return "cannot compare parameter declarations"
    if len(left) != len(right):
        return "parameter count differs"
    for i, ((left_val, left_default), (right_val, right_default)) in enumerate(zip(left, right), 1):
        if left_val != right_val:
            return "parameter %d has a different Val modifier" % i
        if left_default != right_default:
            return "parameter %d has a different default value" % i
    return None


def module_transfer_items(bsl, ext_dir, config_path, prefix, skip_handlers, form_interceptors):
    items = []
    ext_lines = read_bsl_lines(bsl)
    if ext_lines is None:
        return items
    rel = rel_path(ext_dir, bsl)
    set_bsl_context(rel)
    cfg_lines = read_bsl_lines(os.path.join(config_path, rel))
    mc = get_module_changes(ext_lines, skip_handlers)
    form_interceptors = [(idx, it) for module, idx, it in form_interceptors if module.lower() == rel.lower()]
    mixed_empty_around = set()
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
        elif ic["type"] == "Вместо" and is_empty_interceptor_body(ext_m["body_lines"]):
            plan.update(kind="intercept", type=ic["type"], empty_around=True)
            status = "NOT_TRANSFERRED"
            if (sum(x["ic"]["method"].lower() == ic["method"].lower() for x in mc["interceptors"]) > 1
                    or any(idx == cfg_m["decl_idx"] for idx, _ in form_interceptors)):
                if mark is None:
                    mixed_empty_around.add(cfg_m["decl_idx"])
            elif ext_m["is_function"] or cfg_m["is_function"]:
                plan["manual_reason"] = "empty replacement of a function requires manual review"
            elif any(frame["kind"] == "if" for frame in ext_m["chain"] + cfg_m["chain"]):
                plan["manual_reason"] = "empty replacement under a preprocessor condition requires manual review"
            elif has_inline_method_body(ext_lines, ext_m) or has_inline_method_body(cfg_lines, cfg_m):
                plan["manual_reason"] = "statement on the signature line requires manual review"
            elif is_empty_interceptor_body(cfg_m["body_lines"]):
                status = "TRANSFERRED"
            if plan.get("manual_reason"):
                status = "MANUAL"
            note = plan.get("manual_reason", "empty replacement body")
            it = new_item(status, "%s (%s)" % (label, note), loc)
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
    interceptor_items = items + [it for _, it in form_interceptors if it]
    for it in interceptor_items:
        plan = it.get("plan")
        if plan and plan.get("cfg_m") and plan["cfg_m"]["decl_idx"] in mixed_empty_around and it["status"] not in ("TRANSFERRED", "TEMPORARY"):
            plan["manual_reason"] = "the method has an empty replacement and other interceptors"
            it["status"] = "MANUAL"
            it["text"] = "%s (%s)" % (plan["label"], plan["manual_reason"])
    cfg_names = get_proc_names(cfg_lines) if cfg_lines is not None else []
    cfg_counts = Counter(name.lower() for name in cfg_names)
    ext_counts = Counter(name.lower() for name in get_proc_names(ext_lines))
    seen_own = set()
    for od in mc["own"]:
        pn = od["name"]
        if pn.lower() in seen_own:
            continue
        seen_own.add(pn.lower())
        ext_m = get_method_safe(ext_lines, pn)
        if not ext_m:
            continue
        loc = "%s:%d" % (rel, ext_m["decl_idx"] + 1)
        mark = get_method_temp_mark(ext_lines, ext_m)
        # Every method of the module the name may stand for; matching declaration and body win (a name
        # given with the development prefix next to a vendor method of the plain name)
        hits = find_names_in(cfg_names, pn, prefix)
        hit = None
        cfg_m = None
        declaration_mismatch = None
        manual_reason = None
        if ext_counts[pn.lower()] > 1 or any(cfg_counts[h.lower()] > 1 for h in hits):
            manual_reason = "multiple declarations of the same method"
            it = new_item("MANUAL", "method %s (%s)" % (pn, manual_reason), loc)
        elif method_crosses_branch(ext_lines, ext_m):
            manual_reason = "method crosses a preprocessor branch boundary"
            it = new_item("MANUAL", "method %s (%s)" % (pn, manual_reason), loc)
        elif not hits:
            it = new_item("NOT_TRANSFERRED", "method " + pn, loc)
        else:
            ext_sig = "\n".join(sig_lines(protect_bsl_parameter_members(convert_bsl_code(ext_m["body_lines"], {}, ext_m["param_names"]), ext_m["param_names"]), prefix))
            same = False
            for h in hits:
                m = get_method_safe(cfg_lines, h)
                if not m:
                    continue
                if method_crosses_branch(cfg_lines, m):
                    manual_reason = "method crosses a preprocessor branch boundary"
                    continue
                if "\n".join(sig_lines(protect_bsl_parameter_members(m["body_lines"], m["param_names"]), prefix)).lower() == ext_sig.lower():
                    reason = own_declaration_difference(ext_lines, ext_m, cfg_lines, m)
                    if not reason:
                        hit, cfg_m, same = h, m, True
                        declaration_mismatch = None
                        break
                    if not declaration_mismatch:
                        hit, cfg_m, declaration_mismatch = h, m, reason
            if not hit:
                hit = hits[0]
                cfg_m = get_method_safe(cfg_lines, hit)
            if (not same and not declaration_mismatch and cfg_m
                    and method_condition_key(method_conditions(ext_m["chain"])) != method_condition_key(method_conditions(cfg_m["chain"]))):
                declaration_mismatch = "preprocessor condition differs"
            as_ = (" (found as %s)" % hit) if hit.lower() != pn.lower() else ""
            if same:
                manual_reason = None
                it = new_item("TRANSFERRED", "method %s%s" % (pn, as_), loc)
            elif manual_reason:
                it = new_item("MANUAL", "method %s%s (%s)" % (pn, as_, manual_reason), loc)
            else:
                reason = "declaration differs: " + declaration_mismatch if declaration_mismatch else "body differs"
                it = new_item("DIVERGED", "method %s%s (%s)" % (pn, as_, reason), loc)
        it["plan"] = {"kind": "own", "rel": rel, "ext_m": ext_m, "ext_lines": ext_lines, "cfg_m": cfg_m, "name": pn, "hit": hit, "cfg_missing": cfg_lines is None, "manual_reason": manual_reason}
        items.append(set_temp_mark(it, mark, "method " + pn))
    # Variables are declarations. Statements must retain their order and multiplicity.
    if mc["top_code"] >= 0:
        el, cl = get_module_layout(ext_lines), get_module_layout(cfg_lines or [])
        ext_keys, cfg_keys = get_top_code_keys(ext_lines, prefix, True), get_top_code_keys(cfg_lines or [], prefix)
        ext_vars = {ext_keys[v["idx"]].lower() for v in el["vars"]}
        cfg_vars = {cfg_keys[v["idx"]].lower() for v in cl["vars"]}
        found, count, any_stmt = get_module_statement_match(ext_lines, el, ext_keys, cfg_lines or [], cl, cfg_keys)
        found += len(ext_vars & cfg_vars)
        total = len(ext_vars) + count
        st = heuristic_status({"found": found, "total": total})
        if st == "NOT_TRANSFERRED" and any_stmt:
            st = "PARTIAL"
        it = new_item(st, "module code outside methods (heuristic: %d/%d items)" % (found, total), "%s:%d" % (rel, mc["top_code"] + 1))
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


def get_top_code_keys(lines, prefix, extension=False):
    src = convert_bsl_code(lines, {}) if extension else lines
    keys = code_keys(get_code_only(src, True), prefix)
    lay = get_module_layout(lines)
    return {i: keys[i] for i in sorted([v['idx'] for v in lay['vars']] + lay['statements'])}


def get_module_statements(lines, layout, keys):
    parts, scopes = [], []
    depth, paren = 0, 0
    for i in layout["statements"]:
        scope = method_condition_key(method_conditions(get_enclosing_chain(lines, i, "en")))
        for token in re.findall(r'\w+|[^\s]', keys[i].lower()):
            if token in ("(", "["):
                paren += 1
            elif token in (")", "]"):
                paren -= 1
            if paren == 0:
                if token in ("if", "если", "try", "попытка", "for", "для", "while", "пока"):
                    depth += 1
                elif token in ("endif", "конецесли", "endtry", "конецпопытки", "enddo", "конеццикла"):
                    depth -= 1
            if token == ";" and paren == 0 and depth == 0:
                if parts:
                    yield " ".join(parts), tuple(scopes)
                parts.clear()
                scopes.clear()
            else:
                if not scopes or scopes[-1][1] != scope:
                    scopes.append((len(parts), scope))
                parts.append(token)
    if parts:
        yield " ".join(parts), tuple(scopes)


def get_module_statement_match(ext_lines, ext_layout, ext_keys, cfg_lines, cfg_layout, cfg_keys):
    wanted = list(get_module_statements(ext_lines, ext_layout, ext_keys))
    keys = {value for value, _ in wanted}
    # A shared fragment in a changed compound statement is a partial match, not a new statement to append.
    separator = re.compile(r' (?:;|then|тогда|do|цикл|else|иначе|except|исключение) ')
    keys.update({part for value in keys for part in separator.split(value) if " " in part})
    found, any_match = 0, False
    for item in get_module_statements(cfg_lines, cfg_layout, cfg_keys):
        any_match |= item[0] in keys
        if not any_match:
            any_match = any(part in keys for part in separator.split(item[0]) if " " in part)
        if found < len(wanted) and wanted[found] == item:
            found += 1
    return found, len(wanted), any_match


# Own sub-objects of a borrowed object (attributes, tabular sections, commands, forms, templates, …)
def own_child_items(ctx, cfg_md, prefix, rel, rank):
    items = []
    if ctx["md"] is None or ctx["md"]["children"] is None:
        return items
    cfg_kids = elem_children(cfg_md["children"]) if cfg_md is not None and cfg_md["children"] is not None else []
    # File-backed children registered with the package planner have their own report items.
    file_kinds = ("Form", "Template", "Command")

    def check(node, label, cfg_pool, path):
        nm = md_child_name(node)
        cands = [c for c in cfg_pool if localname(c) == localname(node)]
        hit = find_name_in([md_child_name(c) for c in cands], nm, prefix)
        full = (path + "." + nm) if path else nm
        plan = {"kind": "md", "rel": rel, "obj_type": ctx["type"], "tag": localname(node), "name": nm,
                "parent": path, "node": node, "type_key": ""}
        projected = copy.deepcopy(node)
        refs = get_md_node_references(projected, prefix, True)
        if refs.get("status"):
            return new_md_reference_item("%s %s" % (label, full), refs)
        if localname(node) == "TabularSection":
            plan["child_names"] = []
            sk = node.find("md:ChildObjects", MD_NSMAP)
            if sk is not None:
                plan["child_names"] = [md_child_name(x) for x in elem_children(sk)]
        if not hit:
            ni = new_item("NOT_TRANSFERRED", "%s %s" % (label, full))
            ni["plan"] = ({"kind": "md-skip", "rel": rel,
                           "reason": "own %s is kept in files and is not transferred by this stage; copy it by hand"
                                     % localname(node).lower()}
                          if localname(node) in file_kinds else plan)
            return ni
        as_ = (" (found as %s)" % hit) if hit.lower() != nm.lower() else ""
        if node.find("md:Properties/md:Type", MD_NSMAP) is not None:
            cnode = [c for c in cands if md_child_name(c).lower() == hit.lower()][0]
            a = md_type_key(projected, "")
            b = md_type_key(cnode, "")
            expected_type = get_md_type_model(projected.find("md:Properties/md:Type", MD_NSMAP), "")
            actual_type = get_md_type_model(cnode.find("md:Properties/md:Type", MD_NSMAP), "")
            if not test_md_type_model_equal(expected_type, actual_type):
                ni = new_item("DIVERGED", "%s %s%s (type: %s vs %s in config)" % (label, full, as_, a, b))
                if a.lower() == b.lower():
                    ni["text"] = f"{label} {full}{as_} (type qualifiers differ)"
                plan["type_key"] = a
                plan["conflict"] = "the type differs"
                ni["plan"] = plan
                return ni
            current = get_md_node_references(cnode, "", False)
            if sorted(s.lower() for s in refs["values"]) != sorted(s.lower() for s in current["values"]):
                return new_md_reference_item("%s %s%s" % (label, full, as_),
                                             {"status": "CONFLICT", "reason": "metadata references differ"})
        return new_item("TRANSFERRED", "%s %s%s" % (label, full, as_))

    for c in elem_children(ctx["md"]["children"]):
        if (localname(c) in file_kinds
                and f"{ctx['id']}.{localname(c)}.{md_child_name(c)}".lower() in CATALOG_CHILDREN):
            continue
        if not has_element_child(c):
            # <Form>Имя</Form>, <Template>Имя</Template>: ownership is in the sub-object descriptor
            nm = inner_text(c).strip()
            desc = read_md_object(os.path.join(ctx["obj_dir"], localname(c) + "s", nm + ".xml"))
            if desc is not None and test_adopted_node(desc["props"]):
                continue
            hit = find_name_in([inner_text(x).strip() for x in cfg_kids if localname(x) == localname(c)], nm, prefix)
            as_ = (" (found as %s)" % hit) if hit and hit.lower() != nm.lower() else ""
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            ni = new_item(st, "%s %s%s" % (kind_word(localname(c)), nm, as_))
            if not hit:
                ni["plan"] = {"kind": "md-skip", "rel": rel,
                              "reason": "own %s is kept in files and is not transferred by this stage; copy it by hand"
                                        % localname(c).lower()}
            items.append(ni)
            continue
        if not test_adopted_node(c):
            items.append(check(c, kind_word(localname(c)), cfg_kids, ""))
            if localname(c) == "TabularSection" and items[-1]["status"] == "TRANSFERRED":
                tables = [x for x in cfg_kids if localname(x) == "TabularSection"]
                name = find_name_in([md_child_name(x) for x in tables], md_child_name(c), prefix)
                table = next(x for x in tables if md_child_name(x).lower() == name.lower())
                columns = table.find("md:ChildObjects", MD_NSMAP)
                for column in c.findall("md:ChildObjects/md:Attribute", MD_NSMAP):
                    items.append(check(column, kind_word("Attribute"), elem_children(columns) if columns is not None else [], name))
            continue
        # Adopted element: overrides of its own properties; a borrowed tabular section is also walked
        # for its own children — adopted ones carry overrides, the rest are the extension's new columns
        nm = md_child_name(c)
        hit = find_name_in([md_child_name(x) for x in cfg_kids if localname(x) == localname(c)], nm, prefix)
        cnode = ([x for x in cfg_kids if localname(x) == localname(c) and md_child_name(x).lower() == hit.lower()][0]
                 if hit else None)
        cname = hit if hit else nm
        add_md_prop_items(items, c, cnode, prefix, rank, rel, ctx["type"],
                          localname(c), cname, "", "%s %s" % (kind_word(localname(c)), nm), False)
        sub = c.find("md:ChildObjects", MD_NSMAP)
        if sub is None:
            continue
        ts_name = nm
        cfg_children = [x for x in cfg_kids if localname(x) == localname(c)]
        cfg_ts = ([x for x in cfg_children if md_child_name(x).lower() == hit.lower()][0] if hit else None)
        cfg_sub = []
        if cfg_ts is not None:
            cs = cfg_ts.find("md:ChildObjects", MD_NSMAP)
            if cs is not None:
                cfg_sub = elem_children(cs)
        for sc in elem_children(sub):
            sc_name = md_child_name(sc)
            if not test_adopted_node(sc):
                items.append(check(sc, kind_word(localname(sc)), cfg_sub, ts_name))
                continue
            s_hit = find_name_in([md_child_name(x) for x in cfg_sub], sc_name, prefix)
            sc_node = ([x for x in cfg_sub if md_child_name(x).lower() == s_hit.lower()][0] if s_hit else None)
            sc_target = s_hit if s_hit else sc_name
            ts_target = md_child_name(cfg_ts) if cfg_ts is not None else ts_name
            add_md_prop_items(items, sc, sc_node, prefix, rank, rel, ctx["type"],
                              localname(sc), sc_target, ts_target,
                              "%s %s.%s" % (kind_word(localname(sc)), ts_name, sc_name), False)
    return items


ROOT_SOURCE_IDS = set()
ROOT_OWN = {}
ROOT_BINDINGS = {}
ROOT_RESULTS = {}
ROOT_DATA_WARNINGS = []
CATALOG_CHILDREN = {}
BORROWED_PREDEFINED_BINDINGS = {}
BORROWED_PREDEFINED_ITEMS = {}
ROOT_METHOD_BLOCKS = {}
ROOT_GLOBAL_METHODS = {}


def root_object_paths(kind, name):
    directory = "%s/%s" % (CHILD_TYPE_DIR_MAP[kind], name)
    filename = "Module.bsl" if kind == "CommonModule" else "CommandModule.bsl"
    return {"xml": directory + ".xml", "bsl": directory + "/Ext/" + filename, "dir": directory}


def get_root_object_xml(fw, kind, name, prefix):
    obj = get_md_object_element(fw["root"])
    props = get_md_props_element(obj)
    props.find("md:Name", MD_NSMAP).text = name
    for owned in props.xpath("md:ObjectBelonging|md:ExtendedConfigurationObject", namespaces=MD_NSMAP):
        props.remove(owned)
    if kind == "CommonCommand":
        for leaf in props.xpath("md:Group|md:Picture/xr:Ref|md:CommandParameterType/v8:Type|md:CommandParameterType/v8:TypeSet",
                                namespaces=MD_NSMAP):
            ref = resolve_md_reference(inner_text(leaf).strip(), prefix, localname(leaf) in ("Type", "TypeSet"))
            if ref.get("status"):
                return ref
            leaf.text = ref["value"]
    return {"props": props}


DIRECT_MD_COLLECTIONS = {
    "журналыдокументов": "DocumentJournal", "documentjournals": "DocumentJournal",
    "последовательности": "Sequence", "sequences": "Sequence",
    "внешниеисточникиданных": "ExternalDataSource", "externaldatasources": "ExternalDataSource",
    "планысчетов": "ChartOfAccounts", "chartsofaccounts": "ChartOfAccounts",
    "планывидоврасчета": "ChartOfCalculationTypes", "chartsofcalculationtypes": "ChartOfCalculationTypes",
    "регистрыбухгалтерии": "AccountingRegister", "accountingregisters": "AccountingRegister",
    "регистрырасчета": "CalculationRegister", "calculationregisters": "CalculationRegister",
    "планыобмена": "ExchangePlan", "exchangeplans": "ExchangePlan",
    "бизнеспроцессы": "BusinessProcess", "businessprocesses": "BusinessProcess",
    "задачи": "Task", "tasks": "Task",
    "планывидоврасчёта": "ChartOfCalculationTypes", "регистрырасчёта": "CalculationRegister",
    "константы": "Constant", "constants": "Constant", "параметрысеанса": "SessionParameter", "sessionparameters": "SessionParameter",
    "библиотекакартинок": "CommonPicture", "picturelib": "CommonPicture", "документы": "Document", "documents": "Document",
    "регистрысведений": "InformationRegister", "informationregisters": "InformationRegister",
    "регистрынакопления": "AccumulationRegister", "accumulationregisters": "AccumulationRegister",
    "планывидовхарактеристик": "ChartOfCharacteristicTypes", "chartsofcharacteristictypes": "ChartOfCharacteristicTypes",
}
ROOT_BSL_COLLECTIONS = {
    **DIRECT_MD_COLLECTIONS,
    "справочники": "Catalog", "catalogs": "Catalog",
    "перечисления": "Enum", "enums": "Enum", "общиекоманды": "CommonCommand", "commoncommands": "CommonCommand",
    "обработки": "DataProcessor", "dataprocessors": "DataProcessor", "отчеты": "Report", "reports": "Report",
}

EXTRA_PACKAGE_KINDS = ("Subsystem", "CommonForm", "CommonTemplate", "CommonAttribute", "SettingsStorage",
                       "FilterCriterion", "Style", "StyleItem", "PaletteColor", "DocumentJournal", "Sequence",
                       "HTTPService", "WebService", "WSReference", "XDTOPackage", "ExternalDataSource",
                       "IntegrationService", "Bot")
FLAT_TRANSFER_KINDS = ("Constant", "DefinedType", "SessionParameter", "FunctionalOption", "FunctionalOptionsParameter",
                       "EventSubscription", "ScheduledJob", "CommonPicture", "CommandGroup", "DocumentNumerator", "Role")
FLAT_TRANSFER_KINDS += EXTRA_PACKAGE_KINDS
REGISTER_TRANSFER_KINDS = ("InformationRegister", "AccumulationRegister", "AccountingRegister", "CalculationRegister")
LINKED_TRANSFER_KINDS = ("Document",) + REGISTER_TRANSFER_KINDS
PREDEFINED_KINDS = ("Catalog", "ChartOfCharacteristicTypes", "ChartOfAccounts", "ChartOfCalculationTypes")
PREDEFINED_NS = "{http://v8.1c.ru/8.3/xcf/predef}"
EXTENDED_TRANSFER_KINDS = (
    "ChartOfAccounts",
    "ChartOfCalculationTypes",
    "AccountingRegister",
    "CalculationRegister",
    "ExchangePlan",
    "BusinessProcess",
    "Task",
)
STRUCTURED_TRANSFER_KINDS = PREDEFINED_KINDS + ("Report", "DataProcessor", "ExchangePlan", "BusinessProcess", "Task") + LINKED_TRANSFER_KINDS
ROOT_PROVISIONAL = {}
ROOT_REGISTRARS = {}
ROOT_TARGET_REGISTRARS = None
ROOT_SLOT_PATH = ("md:Properties/*[((starts-with(local-name(),'Default') or starts-with(local-name(),'Auxiliary')) "
                  "and contains(local-name(),'Form')) or local-name()='MainDataCompositionSchema']")


def get_functional_option_bsl(tokens, declared, prefix):
    edits, issues = {}, []
    if not ROOT_OWN:
        return edits, issues
    declared = {name.lower() for name in declared}
    for i in range(len(tokens) - 3):
        token, opening, literal, separator = tokens[i:i+4]
        api = token["value"].lower()
        if (api not in ("получитьфункциональнуюопцию", "getfunctionaloption") or api in declared
                or (i and tokens[i-1]["value"] == ".") or api in ROOT_GLOBAL_METHODS
                or opening["value"] != "(" or literal["kind"] != "string" or separator["value"] not in (",", ")")):
            continue
        match = re.fullmatch(r'"(\w+)"', literal["value"])
        if not match:
            continue
        oid = f"FunctionalOption.{match[1]}"
        if oid.lower() not in ROOT_OWN:
            continue
        ref = resolve_md_reference(oid, prefix)
        if ref.get("status"):
            issues.append(dict(ref, token=literal, rename=oid, why=ref["reason"]))
        else:
            edits[literal["start"]] = '"' + ref["value"].split(".")[1] + '"'
    return edits, issues


def get_root_bsl_projection(lines, prefix, self_id, self_name, rel="", child=None, enum_aliases=None):
    all_tokens = list(bsl_tokens(lines))
    tokens = [t for t in all_tokens if t["kind"] not in ("comment", "string", "fragment") and t["value"].strip()]
    source = "\n".join(lines)
    proc_names = get_proc_names(lines)
    proc_keys = {n.lower() for n in proc_names}
    methods = [m for n in proc_names if (m := get_method_safe(lines, n))]
    locals_ = {n.lower() for v in get_module_layout(lines)["vars"] for n in v["names"]}
    method_locals = {}
    significant = [t for t in all_tokens if t["kind"] != "comment" and t["value"].strip()]
    edits, issues = get_catalog_child_bsl(significant, rel, child, proc_names, prefix, self_id, self_name)
    if issues:
        return issues[0]
    option_edits, option_issues = get_functional_option_bsl(significant, proc_names, prefix)
    if option_issues:
        return option_issues[0]
    edits.update(option_edits)
    for i in range(len(tokens) - 1):
        token, dot = tokens[i:i + 2]
        if token["kind"] != "word" or (i and tokens[i - 1]["value"] == "."):
            continue
        word = token["value"].lower()
        if dot["value"] == "(" and word not in proc_keys and word in ROOT_GLOBAL_METHODS:
            providers = ROOT_GLOBAL_METHODS[word]
            if len(providers) > 1:
                return {"status": "MANUAL", "reason": "ambiguous global method %s: %s" %
                        (token["value"], ", ".join(ROOT_OWN[key]["id"] for key in providers))}
            key = providers[0]
            if key not in ROOT_BINDINGS or word in ROOT_METHOD_BLOCKS.get(key, ()):
                return {"status": "WAITING", "reason": "waiting for %s.%s" % (ROOT_OWN[key]["id"], token["value"]), "dependency": key}
            continue
        if i + 2 >= len(tokens) or dot["value"] != "." or tokens[i + 2]["kind"] != "word":
            continue
        member = tokens[i + 2]
        collection = ROOT_BSL_COLLECTIONS.get(word)
        if (self_id.lower().startswith("document.") and rel == "Ext/ObjectModule.bsl"
                and word in ("движения", "registerrecords")):
            kinds = [kind for kind in REGISTER_TRANSFER_KINDS
                     if self_id.lower() in ROOT_REGISTRARS.get(f"{kind}.{member['value']}".lower(), ())]
            if len(kinds) > 1:
                return {"status": "MANUAL", "reason": f"ambiguous register movement {member['value']}"}
            if kinds:
                collection = kinds[0]
        kind = collection or "CommonModule"
        ref_token = member if collection else token
        ref = kind + "." + ref_token["value"]
        key = ref.lower()
        data_alias = child and word in child.get("data_aliases", ())
        if (not data_alias and key not in ROOT_SOURCE_IDS) or word in locals_:
            continue
        line = source.count("\n", 0, token["start"])
        owner = next((m for m in methods if m["decl_idx"] <= line <= m["body_end_idx"]), None)
        if owner:
            idx = owner["decl_idx"]
            if idx not in method_locals:
                params = owner.get("param_names", ())
                method_locals[idx] = {p.lower() for p in params} | set(get_local_names(get_code_only(owner["body_lines"]), params))
            if word in method_locals[idx]:
                continue
        if data_alias:
            reference = resolve_form_owner_data_path(child["ctx"], token["value"], member["value"], None, prefix)
            if reference.get("status"):
                return reference
            if reference.get("value"):
                edits[member["start"]] = reference["value"].split(".")[1]
            continue
        if key == self_id.lower():
            target = self_name
        elif key in ROOT_PROVISIONAL:
            target = ROOT_PROVISIONAL[key]["target"]
        elif key in ROOT_BINDINGS:
            target = ROOT_BINDINGS[key]
            if not collection and i + 3 < len(tokens) and tokens[i + 3]["value"] == "(":
                path = os.path.join(MD_REFERENCE_ROOT, root_object_paths(kind, target)["bsl"])
                if member["value"].lower() in ROOT_METHOD_BLOCKS.get(key, ()) or not get_method_safe(read_bsl_lines(path), member["value"]):
                    return {"status": "WAITING", "reason": "waiting for " + ref + "." + member["value"]}
        else:
            if key in ROOT_OWN:
                return {"status": "WAITING", "reason": "waiting for " + ref, "dependency": key}
            resolved = resolve_md_reference(ref, prefix)
            if resolved.get("status"):
                return resolved
            target = resolved["value"].split(".", 1)[1]
            if not collection and i + 3 < len(tokens) and tokens[i + 3]["value"] == "(":
                path = os.path.join(MD_REFERENCE_ROOT, root_object_paths(kind, target)["bsl"])
                hits = find_names_in(get_proc_names(read_bsl_lines(path) or []), member["value"], prefix)
                method_id = ref + "." + member["value"]
                if not hits:
                    return {"status": "WAITING", "reason": "waiting for " + method_id}
                if len(hits) > 1 and hits[0].lower() != member["value"].lower():
                    return {"status": "MANUAL", "reason": "ambiguous method %s: %s" % (method_id, ", ".join(hits))}
                edits[member["start"]] = hits[0]
        predefined_path = borrowed_predefined_access(tokens, i)
        if predefined_path:
            binding = BORROWED_PREDEFINED_BINDINGS[predefined_path.lower()]
            if binding.get("status"):
                return binding
            edits[tokens[i + 4]["start"]] = binding["name"]
        if (kind == "Enum" and i + 4 < len(tokens) and tokens[i+3]["value"] == "."
                and tokens[i+4]["kind"] == "word" and (i + 5 >= len(tokens) or tokens[i+5]["value"] != "(")
                and key in ROOT_OWN):
            value = tokens[i+4]
            if key == self_id.lower():
                if enum_aliases and value["value"].lower() in enum_aliases:
                    edits[value["start"]] = enum_aliases[value["value"].lower()]
            else:
                reference = resolve_md_reference(ref + ".EnumValue." + value["value"], prefix)
                if reference.get("status"):
                    return reference
                edits[value["start"]] = reference["value"].split(".")[3]
        edits[ref_token["start"]] = target
    # A direct platform form call names the owning catalog in its first argument.
    if self_id.lower().startswith("catalog.") and self_name != self_id.split(".", 1)[1]:
        form_path = re.compile(r'^("(?:Catalog|Справочник)\.)' + re.escape(self_id.split(".", 1)[1])
                               + r'(\.(?:Form|Форма)\.\w+")$', re.I)
        call = [t for t in all_tokens if t["kind"] != "comment" and t["value"].strip()]
        for i in range(len(call) - 3):
            token, opening, literal, separator = call[i:i + 4]
            api = token["value"].lower()
            if (api not in ("openform", "getform", "открытьформу", "получитьформу") or api in proc_keys
                    or api in ROOT_GLOBAL_METHODS or (i and call[i - 1]["value"] == ".")):
                continue
            if opening["value"] == "(" and literal["kind"] == "string" and separator["value"] in (",", ")"):
                match = form_path.fullmatch(literal["value"])
                if match:
                    edits[literal["start"]] = match[1] + self_name + match[2]
    return {"lines": "".join(edits.get(t["start"], t["value"]) for t in all_tokens).split("\n") if edits else lines}


def root_object_code_key(lines):
    return "\0".join(t["value"].lower() if t["kind"] == "word" else t["value"] for t in bsl_tokens(lines)
                     if t["kind"] != "comment" and t["value"].strip())


def root_top_code_key(lines):
    layout = get_module_layout(lines)
    indexes = sorted([v["idx"] for v in layout["vars"]] + layout["statements"])
    guards = tuple(method_condition_key(method_conditions(get_enclosing_chain(lines, i, "en"))) for i in indexes)
    return root_object_code_key([lines[i] for i in indexes]), guards


def compare_root_module(source, target):
    names, current = get_proc_names(source), get_proc_names(target)
    source_counts, target_counts = Counter(n.lower() for n in names), Counter(n.lower() for n in current)
    matched, missing, different, temporary = 0, [], [], []
    for name in names:
        key = name.lower()
        a, b = get_method_safe(source, name), get_method_safe(target, name)
        if not a or source_counts[key] != 1:
            different.append(name)
            continue
        same = (b and target_counts[key] == 1 and not own_declaration_difference(source, a, target, b)
                and root_object_code_key(a["body_lines"]) == root_object_code_key(b["body_lines"]))
        mark = get_method_temp_mark(source, a)
        if mark is not None:
            status = "TRANSFERRED" if same else "NOT_TRANSFERRED"
            label = "method " + name
            temporary.append(set_temp_mark(new_item(status, label), mark, label))
        elif not target_counts[key]:
            missing.append((name, a))
        elif not same:
            different.append(name)
        elif root_object_code_key(a["body_lines"]):
            matched += 1
    top = root_top_code_key(source) == root_top_code_key(target)
    return {"matched": matched, "total": len(names) - len(temporary), "missing": missing,
            "different": different, "temporary": temporary, "top": top}


def metadata_transfer_uuid(cfg, kind, source):
    config_uuid = cfg["child_objects"].getparent().get("uuid")
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"cc-1c-skills:cfe-transfer:v1|{config_uuid.lower()}|{kind}|{source.lower()}"))


def template_payload(template_type, folder, skd):
    suffix = {"SpreadsheetDocument": "xml", "DataCompositionSchema": "xml",
              "TextDocument": "txt", "BinaryData": "bin"}.get(template_type)
    if not suffix:
        return None
    path = f"{folder}Ext/Template.{suffix}"
    if template_type == "DataCompositionSchema":
        skd.add(path)
    return path


def catalog_files(root, directory, child=None, extra_package=False):
    required = set()
    skd = set()
    optional = {"Ext/ObjectModule.bsl", "Ext/ManagerModule.bsl"}
    obj = get_md_object_element(root)
    obj_kind = localname(obj)
    if child is None and obj_kind in PREDEFINED_KINDS:
        optional.add("Ext/Predefined.xml")
    if obj_kind in REGISTER_TRANSFER_KINDS:
        optional.add("Ext/RecordSetModule.bsl")
    if extra_package:
        optional = set()
        if obj_kind == "Subsystem":
            optional.add("Ext/CommandInterface.xml")
        elif obj_kind == "CommonForm":
            if obj.findtext("md:Properties/md:FormType", namespaces=MD_NSMAP) == "Ordinary":
                raise ValueError("ordinary forms are not supported")
            required.add("Ext/Form.xml")
            optional.add("Ext/Form/Module.bsl")
        elif obj_kind == "CommonTemplate":
            template_type = obj.findtext("md:Properties/md:TemplateType", "", MD_NSMAP)
            payload = template_payload(template_type, "", skd)
            if not payload:
                raise ValueError(f"unsupported template type {template_type}")
            required.add(payload)
        elif obj_kind in ("DocumentJournal", "FilterCriterion", "SettingsStorage"):
            optional.add("Ext/ManagerModule.bsl")
        elif obj_kind == "Style":
            required.add("Ext/Style.xml")
        elif obj_kind == "Sequence":
            optional.add("Ext/RecordSetModule.bsl")
        elif obj_kind in ("HTTPService", "WebService", "IntegrationService", "Bot"):
            optional.add("Ext/Module.bsl")
        elif obj_kind == "WSReference":
            required.add("Ext/WSDefinition.xml")
        elif obj_kind == "XDTOPackage":
            required.add("Ext/Package.bin")
        elif obj_kind in ("ExternalDataSource", "Table", "Cube", "DimensionTable"):
            optional.update(f"Ext/{module}.bsl" for module in
                            ("ManagerModule", "ObjectModule", "RecordSetModule", "RecordManagerModule"))
    if child is None and (obj_kind in EXTENDED_TRANSFER_KINDS or (extra_package and obj_kind in
            ("Subsystem", "CommonForm", "DocumentJournal", "Table", "Cube", "DimensionTable"))):
        optional.add("Ext/Help.xml")
        if obj_kind == "ExchangePlan":
            required.add("Ext/Content.xml")
        if obj_kind == "BusinessProcess":
            required.add("Ext/Flowchart.xml")
        help_path = os.path.join(directory, "Ext/Help.xml")
        if os.path.isfile(help_path):
            help_root = read_form_doc(help_path).getroot()
            if help_root.tag != "{http://v8.1c.ru/8.3/xcf/extrnprops}Help":
                raise ValueError("unsupported help descriptor")
            for page in elem_children(help_root):
                if localname(page) != "Page" or not re.fullmatch(r"[\w-]+", inner_text(page)):
                    raise ValueError("unsupported help page")
                required.add(f"Ext/Help/{inner_text(page)}.html")
    children = obj.find("md:ChildObjects", MD_NSMAP)
    nodes = [child] if child is not None else elem_children(children) if children is not None else []
    for node in nodes:
        kind, name = localname(node), md_child_name(node)
        if not re.fullmatch(r"\w+", name):
            raise ValueError(f"invalid {obj_kind} child name: {name}")
        if extra_package:
            order = {"Subsystem": ("Subsystem",), "Sequence": ("Dimension",), "HTTPService": ("URLTemplate",),
                     "WebService": ("Operation",), "IntegrationService": ("IntegrationServiceChannel",)}
            if kind not in order.get(obj_kind, object_child_order().get(obj_kind, ())):
                raise ValueError(f"unsupported {obj_kind} child {kind}")
            if kind in ("Subsystem", "Table", "Cube", "DimensionTable"):
                folder = f"{kind}s/{name}"
                md = read_md_object(os.path.join(directory, folder + ".xml"))
                if (not md or localname(md["el"]) != kind or md_child_name(md["el"]) != name
                        or md["el"].getroottree().getroot().get("version") != root.get("version")):
                    raise ValueError(f"missing or invalid child descriptor {folder}.xml")
                try:
                    nested, nested_skd = catalog_files(md["el"].getroottree().getroot(), os.path.join(directory, folder),
                                                       extra_package=True)
                except ValueError as exc:
                    raise ValueError(f"{folder} — {exc}") from exc
                required.add(folder + ".xml")
                required.update(f"{folder}/{rel}" for rel in nested)
                skd.update(f"{folder}/{rel}" for rel in nested_skd)
                continue
            if kind not in ("Form", "Template", "Command"):
                continue
        if kind == "Form":
            required.update((f"Forms/{name}.xml", f"Forms/{name}/Ext/Form.xml"))
            optional.add(f"Forms/{name}/Ext/Form/Module.bsl")
        elif kind == "Template":
            filename = f"Templates/{name}.xml"
            template = read_md_object(os.path.join(directory, filename))
            if not template:
                raise ValueError(f"missing template {name}")
            template_type = template["props"].findtext("md:TemplateType", namespaces=MD_NSMAP)
            if obj_kind == "Catalog" and template_type != "SpreadsheetDocument":
                raise ValueError(f"unsupported or missing template {name}")
            payload = template_payload(template_type, f"Templates/{name}/", skd)
            if not payload:
                raise ValueError(f"unsupported template type {template_type} for {name}")
            required.update((filename, payload))
        elif kind == "Command":
            required.add(f"Commands/{name}/Ext/CommandModule.bsl")
            if not elem_children(node):
                required.add(f"Commands/{name}.xml")
        elif kind in ("Dimension", "Resource") and obj_kind in REGISTER_TRANSFER_KINDS:
            continue
        elif kind in ("AccountingFlag", "ExtDimensionAccountingFlag") and obj_kind == "ChartOfAccounts":
            continue
        elif kind == "AddressingAttribute" and obj_kind == "Task":
            continue
        elif kind == "Recalculation" and obj_kind == "CalculationRegister":
            continue
        elif kind not in ("Attribute", "TabularSection"):
            raise ValueError(f"unsupported {obj_kind} child {kind}")
    schema = obj.findtext("md:Properties/md:MainDataCompositionSchema", "", MD_NSMAP)
    own_schema = re.fullmatch(r"Report\." + re.escape(md_child_name(obj)) + r"\.Template\.(\w+)", schema, re.I)
    if own_schema and f"Templates/{own_schema[1]}/Ext/Template.xml" not in skd:
        raise ValueError(f"missing data composition schema {schema}")
    files = {}
    scan = directory if child is None else os.path.join(directory, localname(child) + "s", md_child_name(child))
    for folder, _, filenames in os.walk(scan):
        for filename in filenames:
            path = os.path.join(folder, filename)
            rel = os.path.relpath(path, directory).replace(os.sep, "/")
            if rel not in required and rel not in optional and not (
                    extra_package and obj_kind == "WSReference" and re.fullmatch(r"Ext/[1-9][0-9]*\.xsd", rel)):
                raise ValueError(f"unsupported object file {rel}")
            files[rel] = path
    if child is not None and os.path.isfile(scan + ".xml"):
        rel = os.path.relpath(scan + ".xml", directory).replace(os.sep, "/")
        if rel not in required:
            raise ValueError(f"unsupported object file {rel}")
        files[rel] = scan + ".xml"
    missing = sorted(required - files.keys())
    if missing:
        raise ValueError(f"missing object file {missing[0]}")
    if extra_package and obj_kind == "WSReference":
        schemas = set()
        for rel, path in files.items():
            document = read_form_doc(path).getroot()
            expected = ("{http://schemas.xmlsoap.org/wsdl/}definitions" if rel == "Ext/WSDefinition.xml"
                        else "{http://www.w3.org/2001/XMLSchema}schema")
            if document.tag != expected:
                raise ValueError(f"invalid {rel}")
            for location in document.xpath(".//*[namespace-uri()='http://www.w3.org/2001/XMLSchema']/@schemaLocation|"
                                           ".//*[local-name()='import' and namespace-uri()='http://schemas.xmlsoap.org/wsdl/']/@location"):
                schema = re.fullmatch(r"file://([1-9][0-9]*\.xsd)", location)
                if not schema or f"Ext/{schema[1]}" not in files:
                    raise ValueError(f"unresolved WS schema in {rel}")
                schemas.add(schema[1])
        if len(files) != len(schemas) + 1:
            raise ValueError("unexpected WS schema file")
    return files, skd


def convert_catalog_xml(fw, cfg, source, target, prefix, descriptor, child=None, owner_kind="Catalog"):
    root = fw["root"]
    obj_kind = localname(get_md_object_element(root)) if descriptor else owner_kind
    kind = {
        "Enum": r"Enum(?:Ref|Manager|List)?",
        "Constant": r"Constant(?:Manager|ValueManager|ValueKey)?",
        "Catalog": r"Catalog(?:Ref|Object|Manager|Selection|List|TabularSectionRow|TabularSection)?",
        "ChartOfCharacteristicTypes": r"(?:Characteristic|ChartOfCharacteristicTypes(?:Ref|Object|Manager|Selection|List|TabularSectionRow|TabularSection)?)",
        "Report": r"Report(?:Object|Manager|TabularSectionRow|TabularSection)?",
        "DataProcessor": r"DataProcessor(?:Object|Manager|TabularSectionRow|TabularSection)?",
        "Document": r"Document(?:Ref|Object|Manager|Selection|List|TabularSectionRow|TabularSection)?",
        "ChartOfAccounts": r"ChartOfAccounts(?:Ref|Object|Manager|Selection|List|TabularSectionRow|TabularSection|ExtDimensionTypesRow|ExtDimensionTypes)?",
        "ChartOfCalculationTypes": r"(?:ChartOfCalculationTypes(?:Ref|Object|Manager|Selection|List|TabularSectionRow|TabularSection)?|(?:Base|Displacing|Leading)CalculationTypes(?:Row)?)",
        "AccountingRegister": r"AccountingRegister(?:Manager|RecordSet|RecordManager|RecordKey|Record|Selection|List|ExtDimensions)?",
        "CalculationRegister": r"(?:CalculationRegister(?:Manager|RecordSet|RecordManager|RecordKey|Record|Selection|List)?|RecalculationsManager)",
        **{k: rf"{k}(?:Ref|Object|Manager|Selection|List|TabularSectionRow|TabularSection|RoutePointRef)?"
           for k in ("ExchangePlan", "BusinessProcess", "Task")},
        "ExternalDataSource": r"ExternalDataSource(?:Table(?:Ref|Object|Manager|List|RecordSet|RecordManager|RecordKey|Record)?|CubesManager|Cube(?:Manager|RecordSet|Record|Selection)?|TablesManager|Manager)?",
        "FilterCriterion": r"FilterCriterion(?:Manager|List)?",
        "IntegrationService": r"IntegrationService(?:Channel)?(?:Manager)?",
        **{k: rf"{k}(?:Manager)?" for k in ("WSReference", "SettingsStorage", "Bot")},
        **{k: rf"{k}(?:Manager|RecordSet|RecordManager|RecordKey|Record|Selection|List)?" for k in ("Sequence", "DocumentJournal")},
        "InformationRegister": r"InformationRegister(?:Manager|RecordSet|RecordManager|RecordKey|Record|Selection|List)?",
        "AccumulationRegister": r"AccumulationRegister(?:Manager|RecordSet|RecordManager|RecordKey|Record|Selection|List)?",
    }.get(obj_kind, re.escape(obj_kind))
    if descriptor:
        get_md_object_element(root).find("md:Properties/md:Name", MD_NSMAP).text = target
    for node in root.xpath("//md:ObjectBelonging|//md:ExtendedConfigurationObject", namespaces=MD_NSMAP):
        node.getparent().remove(node)
    for node in root.xpath("//*[@uuid]"):
        node.set("uuid", metadata_transfer_uuid(cfg, localname(node), node.get("uuid")))
    pattern = re.compile(r"^((?:\w+:)?" + kind + r"\.)"
                         + re.escape(source) + r"(?=\.|$)", re.I)
    for node in root.xpath("//xr:GeneratedType", namespaces=MD_NSMAP):
        node.set("name", pattern.sub(lambda m: m[1] + target, node.get("name")))
        for id_node in node.xpath("xr:TypeId|xr:ValueId", namespaces=MD_NSMAP):
            id_node.text = metadata_transfer_uuid(cfg, localname(id_node), inner_text(id_node).strip())
    for node in root.xpath("//*[not(*)]"):
        value, name = inner_text(node).strip(), localname(node)
        if child and FORM_PATH_TAGS.search(name):
            path = re.fullmatch(r"(\w+)\.(\w+)(?:\.(\w+))?", value)
            if path and path[1].lower() in child.get("data_aliases", ()):
                ref = resolve_form_owner_data_path(child["ctx"], path[1], path[2], path[3], prefix)
                if ref.get("status"):
                    return ref
                if ref.get("value"):
                    node.text = ref["value"]
                    continue
        xsi_type = node.get(f"{{{XSI_NS}}}type", "").split(":", 1)
        design_ref = (len(xsi_type) == 2 and xsi_type[1] in ("DesignTimeRef", "MDObjectRef")
                      and node.nsmap.get(xsi_type[0]) == MD_NSMAP["xr"])
        is_type = node.tag in ("{%s}Type" % MD_NSMAP["v8"], "{%s}TypeSet" % MD_NSMAP["v8"])
        parent = localname(node.getparent()) if node.getparent() is not None else ""
        strict_ref = (
            (obj_kind == "FunctionalOption" and (name == "Location" or (name == "Object" and parent == "Content")))
            or (obj_kind == "FunctionalOptionsParameter" and name == "Item" and parent == "Use")
            or (obj_kind == "Constant" and (
                (name in ("DefaultForm", "ChoiceForm") and parent == "Properties")
                or (name == "DataPath" and node.xpath("ancestor::md:ChoiceParameterLinks|ancestor::md:LinkByType",
                                                      namespaces=MD_NSMAP))))
            or (obj_kind == "Document" and ((name == "Item" and parent in ("RegisterRecords", "BasedOn"))
                                           or (name == "Numerator" and parent == "Properties")))
            or (obj_kind == "ChartOfCharacteristicTypes" and name == "CharacteristicExtValues" and parent == "Properties")
            or (obj_kind == "ChartOfAccounts" and name == "ExtDimensionTypes" and parent == "Properties")
            or (obj_kind == "ChartOfCalculationTypes" and name == "Item"
                and parent in ("BaseCalculationTypes", "DisplacingCalculationTypes", "LeadingCalculationTypes"))
            or (obj_kind == "AccountingRegister" and name in ("ChartOfAccounts", "AccountingFlag", "ExtDimensionAccountingFlag"))
            or (obj_kind == "CalculationRegister" and name in ("ChartOfCalculationTypes", "Schedule", "ScheduleDate",
                                                               "ScheduleValue", "ScheduleLink", "LeadingDimension", "Dimension"))
            or (obj_kind == "BusinessProcess" and name in ("Task", "AddressingAttribute"))
            or (obj_kind == "Task" and name in ("Addressing", "AddressingDimension", "MainAddressingAttribute", "CurrentPerformer"))
            or (obj_kind == "ExchangePlan" and node.tag == "{http://v8.1c.ru/8.3/xcf/extrnprops}Metadata")
            or (obj_kind == "CommonAttribute" and name == "Metadata" and node.getparent().getparent() is not None
                and localname(node.getparent().getparent()) == "Content")
            or (obj_kind == "WebService" and name == "Value" and node.getparent().getparent() is not None
                and localname(node.getparent().getparent()) == "XDTOPackages" and value.lower().startswith("xdtopackage."))
            or (obj_kind == "Subsystem" and ((name == "Item" and parent == "Content")
                or (name == "CommandGroup" and value.lower().startswith("commandgroup.")))))
        color = re.fullmatch(r"(style|palette):(\w+)", value, re.I)
        if color and (re.search(r"(Color|Font|Border)$", name, re.I) or name == "Value"):
            tag = "StyleItem" if color[1].lower() == "style" else "PaletteColor"
            if f"{tag}.{color[2]}".lower() not in ROOT_SOURCE_IDS:
                continue
            ref = resolve_md_reference(f"{tag}.{color[2]}", prefix)
            if ref.get("status"):
                return ref
            node.text = f"{color[1]}:{ref['value'].split('.', 1)[1]}"
            continue
        if strict_ref and value:
            path = re.fullmatch(r"(\w+)\.\w+(?:\.\w+\.\w+)*", value)
            if not path or path[1] not in CHILD_TYPE_DIR_MAP:
                return {"status": "MANUAL", "reason": f"unsupported metadata reference in {name}: {value}"}
        if (obj_kind == "Document" and value
                and ((name == "Numerator" and not re.fullmatch(r"DocumentNumerator\.\w+", value))
                     or (parent == "RegisterRecords" and
                         not re.fullmatch(r"(Information|Accumulation|Accounting|Calculation)Register\.\w+", value)))):
            return {"status": "MANUAL", "reason": f"invalid document reference: {value}"}
        is_ref = (re.match(r"^(Default|Auxiliary).*Form$", name)
                  or strict_ref
                  or name in ("ChoiceForm", "Owners", "Group", "Ref", "DataPath", "MainDataCompositionSchema",
                              "VariantsStorage", "SettingsStorage")
                  or node.tag == "{%s}Field" % MD_NSMAP["xr"]
                  or design_ref)
        if not value or not (is_type or is_ref):
            continue
        if child and re.fullmatch(r"\w+\.\w+\.(Form|Template|Command|Attribute|TabularSection)\.\w+(?:\.Attribute\.\w+)?", value, re.I):
            if value.lower() == child["id"].lower():
                node.text = f"{obj_kind}.{target}.{child['kind']}.{child['target']}"
            else:
                ref = resolve_md_reference(value, prefix)
                if ref.get("status"):
                    return ref
                node.text = ref["value"]
        elif pattern.match(value):
            item = re.fullmatch(r"((?:\w+:)?\w+)\.\w+\.(\w+)", value)
            binding = BORROWED_PREDEFINED_BINDINGS.get(f"{obj_kind}.{source}.{item[2]}".lower()) if item else None
            if binding:
                if binding.get("status"):
                    return binding
                value = f"{item[1]}.{source}.{binding['name']}"
            node.text = pattern.sub(lambda m: m[1] + target, value)
        elif name != "DataPath" or is_type or strict_ref:
            ref = resolve_md_reference(value, prefix, is_type, obj_kind == "EventSubscription" and parent == "Source")
            if ref.get("status"):
                return ref
            node.text = ref["value"]
    if obj_kind == "Subsystem" and localname(root) == "CommandInterface":
        for attr in root.xpath("//*[local-name()='Command' or local-name()='Subsystem']/@name"):
            if not re.match(r"^\w+\.\w+", attr):
                continue
            parts = re.split(r"\.StandardCommand\.", attr, maxsplit=1, flags=re.I)
            if pattern.match(parts[0]):
                parts[0] = pattern.sub(lambda m: m[1] + target, parts[0])
            else:
                ref = resolve_md_reference(parts[0], prefix)
                if ref.get("status"):
                    return ref
                parts[0] = ref["value"]
            attr.getparent().set("name", ".StandardCommand.".join(parts))
    for node in root.xpath("//*[@ref]|//*[local-name()='ExtDimensionType' and @name]"):
        if obj_kind == "ChartOfAccounts" and node.tag == PREDEFINED_NS + "Flag":
            attribute, expected = "ref", r"ChartOfAccounts\.\w+\.(AccountingFlag|ExtDimensionAccountingFlag)\.\w+"
        elif obj_kind == "ChartOfAccounts" and node.tag == PREDEFINED_NS + "ExtDimensionType":
            attribute, expected = "name", r"ChartOfCharacteristicTypes\.\w+\.\w+"
        elif obj_kind == "BusinessProcess" and node.tag == "{http://v8.1c.ru/8.3/xcf/scheme}AddressingAttribute":
            attribute, expected = "ref", r"Task\.\w+\.AddressingAttribute\.\w+"
        else:
            continue
        value = node.get(attribute, "")
        if not re.fullmatch(expected, value, re.I):
            return {"status": "MANUAL", "reason": f"unsupported {localname(node)} reference: {value}"}
        if pattern.match(value):
            value = pattern.sub(lambda m: m[1] + target, value)
        else:
            ref = resolve_md_reference(value, prefix)
            if ref.get("status"):
                return ref
            value = ref["value"]
        node.set(attribute, value)
    return {}


def resolve_form_owner_data_path(ctx, alias, field, column, prefix):
    member = next((node for node in elem_children(ctx["md"]["children"])
                   if localname(node) in ("Attribute", "TabularSection") and md_child_name(node).lower() == field.lower()), None)
    if member is None:
        return {}
    path = f"{ctx['id']}.{localname(member)}.{field}"
    own = not test_adopted_node(member)
    if column:
        if localname(member) != "TabularSection":
            return {}
        col = next((node for node in member.findall("md:ChildObjects/md:Attribute", MD_NSMAP)
                    if md_child_name(node).lower() == column.lower()), None)
        if col is None:
            return {}
        own = own or not test_adopted_node(col)
        path += ".Attribute." + column
    if not own:
        return {}
    ref = resolve_md_reference(path, prefix)
    if ref.get("status"):
        return ref
    parts = ref["value"].split(".")
    source_node = col if column else member
    type_node = source_node.find("md:Properties/md:Type", MD_NSMAP)
    if type_node is not None:
        projected = copy.deepcopy(type_node)
        refs = get_md_node_references(projected, prefix, True)
        if refs.get("status"):
            return refs
        md = read_md_object(os.path.join(MD_REFERENCE_ROOT, ctx["dir"], parts[1] + ".xml"))
        lookup = {"tag": "Attribute", "name": parts[5] if column else parts[3], "parent": parts[3] if column else ""}
        actual = get_md_target_element(md["el"], lookup)
        if actual is None or not test_md_type_model_equal(
                get_md_type_model(projected, ""), get_md_type_model(actual.find("md:Properties/md:Type", MD_NSMAP), "")):
            return {"status": "WAITING", "reason": "waiting for compatible type of " + path}
    return {"value": f"{alias}.{parts[3]}" + (f".{parts[5]}" if column else "")}


def get_catalog_child_binding(oid):
    entry = CATALOG_CHILDREN.get(oid.lower())
    if not entry:
        return {}
    if entry.get("ready"):
        return {"kind": entry["kind"], "target": entry["ready"]}
    return {"status": "WAITING", "reason": "waiting for " + oid, "dependency": oid.lower()}


def borrowed_predefined_access(tokens, i):
    collection = tokens[i]["value"].lower()
    kind = "Catalog" if collection in ("справочники", "catalogs") else DIRECT_MD_COLLECTIONS.get(collection)
    if (not BORROWED_PREDEFINED_BINDINGS or i + 4 >= len(tokens)
            or kind not in PREDEFINED_KINDS
            or (i and tokens[i - 1]["value"] == ".")
            or tokens[i+1]["value"] != "." or tokens[i+3]["value"] != "."
            or tokens[i+2]["kind"] != "word" or tokens[i+4]["kind"] != "word"
            or (i + 5 < len(tokens) and tokens[i+5]["value"] == "(")):
        return None
    path = f"{kind}.{tokens[i+2]['value']}.{tokens[i+4]['value']}"
    return path if path.lower() in BORROWED_PREDEFINED_BINDINGS else None


def get_catalog_child_bsl(tokens, rel, child, declared, prefix, self_id="", self_name=""):
    edits, issues = {}, []
    if not (CATALOG_CHILDREN or ROOT_OWN or BORROWED_PREDEFINED_BINDINGS):
        return edits, issues
    module = re.fullmatch(r"(\w+)/(\w+)/Ext/(ObjectModule|ManagerModule)\.bsl", rel, re.I)
    owner_id = next((f"{kind}.{module[2]}" for kind, directory in CHILD_TYPE_DIR_MAP.items()
                     if directory.lower() == module[1].lower()), "") if module else ""
    declared = {name.lower() for name in declared}
    for i in range(len(tokens) - 3):
        token, opening, literal, separator = tokens[i:i + 4]
        api = token["value"].lower()
        if (api in declared or api in ROOT_GLOBAL_METHODS or opening["value"] != "("
                or literal["kind"] != "string" or separator["value"] not in (",", ")")
                or (i and tokens[i - 1]["value"] == ".")):
            continue
        form = (re.fullmatch(r'("(?:CommonForm|ОбщаяФорма)\.)(\w+)"', literal["value"], re.I)
                if api in ("openform", "getform", "открытьформу", "получитьформу") else None)
        template = (re.fullmatch(r'(")(\w+)"', literal["value"])
                    if api in ("getcommontemplate", "получитьобщиймакет") else None)
        if form or template:
            match = form or template
            kind = "CommonForm" if form else "CommonTemplate"
            oid = f"{kind}.{match[2]}"
            if oid.lower() in ROOT_OWN:
                ref = ({"value": f"{kind}.{self_name}"} if oid.lower() == self_id.lower()
                       else resolve_md_reference(oid, prefix))
                if ref.get("status"):
                    issues.append(dict(token=literal, rename=oid, why=ref["reason"], **ref))
                else:
                    edits[literal["start"]] = match[1] + ref["value"].split(".")[1] + '"'
            continue
        if api in ("предопределенноезначение", "предопределённоезначение", "predefinedvalue"):
            item = re.fullmatch(r'("(Catalog|Справочник|ChartOfCharacteristicTypes|ПланВидовХарактеристик|ChartOfAccounts|ПланСчетов|ChartOfCalculationTypes|ПланВидовРасч[её]та)\.)(\w+)\.(\w+)"',
                                literal["value"], re.I)
            if not item:
                continue
            kind = {"catalog": "Catalog", "справочник": "Catalog",
                    "chartofaccounts": "ChartOfAccounts", "плансчетов": "ChartOfAccounts",
                    "chartofcalculationtypes": "ChartOfCalculationTypes",
                    "планвидоврасчета": "ChartOfCalculationTypes", "планвидоврасчёта": "ChartOfCalculationTypes"
                    }.get(item[2].lower(), "ChartOfCharacteristicTypes")
            oid = f"{kind}.{item[3]}"
            path = f"{oid}.{item[4]}"
            if oid.lower() not in ROOT_OWN and path.lower() not in BORROWED_PREDEFINED_BINDINGS:
                continue
            if oid.lower() == self_id.lower() and path.lower() not in BORROWED_PREDEFINED_BINDINGS:
                edits[literal["start"]] = f'{item[1]}{self_name}.{item[4]}"'
                continue
            ref = resolve_md_reference(path, prefix)
            if ref.get("status"):
                issues.append({"token": literal, "rename": path, "why": ref["reason"], "reason": ref["reason"],
                               "status": ref["status"], "dependency": ref.get("dependency")})
            else:
                edits[literal["start"]] = item[1] + ref["value"].split(".", 1)[1] + '"'
            continue
        if api in ("открытьформу", "openform", "получитьформу", "getform"):
            match = re.fullmatch(r'("(Report|Отч[её]т|DataProcessor|Обработка|Document|Документ|ChartOfCharacteristicTypes|ПланВидовХарактеристик|'
                                 r'ChartOfAccounts|ПланСчетов|ChartOfCalculationTypes|ПланВидовРасч[её]та|AccountingRegister|РегистрБухгалтерии|CalculationRegister|РегистрРасч[её]та|ExchangePlan|ПланОбмена|BusinessProcess|БизнесПроцесс|Task|Задача)\.)'
                                 r'(\w+)(\.(?:Form|Форма)\.)(\w+)"',
                                 literal["value"], re.I)
            if match:
                owner_kind = match[2].lower()
                kind = {"report": "Report", "отчет": "Report", "отчёт": "Report",
                        "document": "Document", "документ": "Document",
                        "chartofcharacteristictypes": "ChartOfCharacteristicTypes",
                        "chartofaccounts": "ChartOfAccounts", "плансчетов": "ChartOfAccounts",
                        "accountingregister": "AccountingRegister", "регистрбухгалтерии": "AccountingRegister",
                        "exchangeplan": "ExchangePlan", "планобмена": "ExchangePlan",
                        "businessprocess": "BusinessProcess", "бизнеспроцесс": "BusinessProcess",
                        "task": "Task", "задача": "Task",
                        "chartofcalculationtypes": "ChartOfCalculationTypes", "планвидоврасчета": "ChartOfCalculationTypes", "планвидоврасчёта": "ChartOfCalculationTypes",
                        "calculationregister": "CalculationRegister", "регистррасчета": "CalculationRegister", "регистррасчёта": "CalculationRegister",
                        "планвидовхарактеристик": "ChartOfCharacteristicTypes"}.get(owner_kind, "DataProcessor")
                root_id = f"{kind}.{match[3]}"
                oid = f"{root_id}.Form.{match[5]}"
                if root_id.lower() not in ROOT_OWN and oid.lower() not in CATALOG_CHILDREN:
                    continue
                if child and child["id"].lower() == oid.lower():
                    edits[literal["start"]] = f'{match[1]}{self_name}{match[4]}{child["target"]}"'
                    continue
                if root_id.lower() == self_id.lower() and root_id.lower() in ROOT_OWN:
                    edits[literal["start"]] = f'{match[1]}{self_name}{match[4]}{match[5]}"'
                    continue
                ref = resolve_md_reference(oid, prefix)
                if ref.get("status"):
                    issues.append({"token": literal, "rename": oid, "why": ref["reason"], "reason": ref["reason"],
                                   "status": ref["status"], "dependency": ref.get("dependency")})
                else:
                    _, resolved_owner, _, resolved_form = ref["value"].split(".")
                    edits[literal["start"]] = f'{match[1]}{resolved_owner}{match[4]}{resolved_form}"'
                continue
            match = re.fullmatch(r'("(?:Catalog|Справочник)\.)(\w+)(\.(?:Form|Форма)\.)(\w+)"', literal["value"], re.I)
            if not match:
                continue
            oid = f"Catalog.{match[2]}.Form.{match[4]}"
            head = match[1] + match[2] + match[3]
        elif owner_id and api in ("получитьмакет", "gettemplate"):
            match = re.fullmatch(r'"(\w+)"', literal["value"])
            if not match:
                continue
            oid, head = f"{owner_id}.Template.{match[1]}", '"'
        else:
            continue
        binding = child if child and oid.lower() == child["id"].lower() else get_catalog_child_binding(oid)
        if binding.get("status"):
            issues.append({"token": literal, "rename": oid, "why": binding["reason"],
                           "reason": binding["reason"], "status": binding["status"], "dependency": binding["dependency"]})
        elif binding:
            edits[literal["start"]] = head + binding["target"] + '"'
    return edits, issues


def get_catalog_child_descriptor(registry, root):
    if has_element_child(registry):
        return registry
    name = md_child_name(registry)
    if re.fullmatch(r"\w+", name):
        md = read_md_object(os.path.join(root, localname(registry) + "s", name + ".xml"))
        if md:
            return md["el"]
    return None


def get_catalog_child_projection(entry, cfg, target, prefix, files, skd):
    result = {"files": {}}
    kind, owner = entry["kind"], entry["ctx"]["name"]
    child = {"id": entry["id"], "kind": kind, "target": target, "ctx": entry["ctx"]}
    owner_kind = entry["ctx"]["type"]
    directory = entry["ctx"]["dir"]
    old, new = f"{kind}s/{entry['name']}", f"{directory}/{owner}/{kind}s/{target}"
    if kind == "Form":
        form = read_form_write(files[old + "/Ext/Form.xml"])["root"]
        attrs = form.xpath("/*[local-name()='Form']/*[local-name()='Attributes']/*[local-name()='Attribute']")
        child["data_aliases"] = {attr.get("name", "").lower() for attr in attrs
                                 if (value := attr.findtext("{*}Type/v8:Type", namespaces=MD_NSMAP))
                                 and value.lower() == f"cfg:{owner_kind}Object.{owner}".lower()}
    if has_element_child(entry["node"]):
        root = etree.Element(f"{{{MD_NS}}}MetaDataObject")
        node = copy.deepcopy(entry["node"])
        root.append(node)
        ref = convert_catalog_xml({"root": root}, cfg, owner, owner, prefix, False, child, owner_kind)
        if ref:
            return ref
        node.find("md:Properties/md:Name", MD_NSMAP).text = target
        result["node"] = node
    for rel, src in sorted(files.items()):
        dest = new + rel[len(old):]
        if rel.endswith(".bsl"):
            bsl = read_bsl_file(src)
            base = get_root_bsl_projection(bsl["lines"], prefix, entry["ctx"]["id"], owner, f"{directory}/{owner}/{rel}", child)
            if base.get("status"):
                return base
            result["files"][dest] = {"bsl": bsl, "lines": base["lines"]}
        elif rel.startswith("Templates/") and re.search(r"/Ext/Template\.(xml|txt|bin)$", rel):
            if rel in skd:
                issue = skd_transfer_issue(read_form_write(src)["root"], entry["ctx"]["id"], owner, prefix, rel)
                if issue:
                    return issue
            result["files"][dest] = {"copy": src, "skd": rel in skd}
        else:
            xml = read_form_write(src)
            if kind == "Form" and rel.endswith("/Ext/Form.xml") and xml["root"].xpath("//*[local-name()='BaseForm']"):
                return {"status": "MANUAL", "reason": "form body contains a borrowed BaseForm"}
            ref = convert_catalog_xml(xml, cfg, owner, owner, prefix, False, child, owner_kind)
            if ref:
                return ref
            if rel == old + ".xml":
                descriptor = get_md_object_element(xml["root"])
                if localname(descriptor) != kind:
                    raise ValueError("unexpected descriptor type " + localname(descriptor))
                descriptor.find("md:Properties/md:Name", MD_NSMAP).text = target
            result["files"][dest] = {"xml": xml}
    return result


def get_catalog_child_plan(entry, prefix, cfg):
    ctx, kind, name = (entry[k] for k in ("ctx", "kind", "name"))
    owner_kind = ctx["type"]
    owner_id = ctx["id"]
    relative = f"{ctx['dir']}/{ctx['name']}.xml"
    owner_path = os.path.join(MD_REFERENCE_ROOT, relative)
    owners = [n for n in (MD_REFERENCE_POOLS or {}).get(owner_kind, ()) if n.lower() == ctx["name"].lower()]
    if not owners or not os.path.isfile(owner_path):
        return {"status": "WAITING", "reason": "missing owner " + owner_id}
    if len(owners) > 1:
        return {"status": "CONFLICT", "reason": "duplicate registration of " + owner_id}
    with open(owner_path, "rb") as original:
        before = original.read()
    fw = read_form_write(owner_path)
    source_doc = ctx["md"]["el"].getroottree().getroot()
    if fw["root"].get("version") != source_doc.get("version"):
        return {"status": "MANUAL", "reason": "metadata dump formats differ"}
    desc = entry["descriptor"]
    if entry.get("error"):
        return {"status": "MANUAL", "reason": entry["error"]}
    if desc is None:
        return {"status": "MANUAL", "reason": "missing source descriptor"}
    if not desc.get("uuid"):
        return {"status": "MANUAL", "reason": "source descriptor has no UUID"}
    if kind == "Form" and desc.findtext("md:Properties/md:FormType", namespaces=MD_NSMAP) == "Ordinary":
        return {"status": "MANUAL", "reason": "ordinary forms are not supported"}
    owner = get_md_object_element(fw["root"])
    adopted_id = ctx["md"]["props"].findtext("md:ExtendedConfigurationObject", "", MD_NSMAP)
    if localname(owner) != owner_kind or owner.get("uuid", "").lower() != adopted_id.lower():
        return {"status": "CONFLICT", "reason": f"borrowed owner identity does not match {owner_id}"}
    children = owner.find("md:ChildObjects", MD_NSMAP)
    if children is None:
        children = etree.Element(f"{{{MD_NS}}}ChildObjects")
        insert_form_node_at(owner, children, None, fw["eol"])
    nodes = children.findall("md:" + kind, MD_NSMAP)
    pool = [md_child_name(node) for node in nodes]
    dest_root = os.path.splitext(owner_path)[0]
    files, skd = catalog_files(source_doc, ctx["obj_dir"], entry["node"])
    identity = metadata_transfer_uuid(cfg, kind, desc.get("uuid"))
    identified = [node for node in nodes if (d := get_catalog_child_descriptor(node, dest_root)) is not None
                  and d.get("uuid") == identity]
    if len(identified) > 1:
        return {"status": "CONFLICT", "reason": f"duplicate {kind} UUID {identity}"}
    candidates = [md_child_name(identified[0])] if identified else find_names_in(pool, name, prefix)
    matches, incomplete = [], []
    for candidate in candidates:
        projection = get_catalog_child_projection(entry, cfg, candidate, prefix, files, skd)
        if projection.get("status"):
            return projection
        current = next(node for node in nodes if md_child_name(node).lower() == candidate.lower())
        different, missing = [], {}
        for rel, file in projection["files"].items():
            path = os.path.join(MD_REFERENCE_ROOT, rel)
            if not os.path.lexists(path):
                missing[rel] = file
            elif not os.path.isfile(path) or not catalog_file_equal(file, path):
                different.append(rel)
        node = projection.get("node")
        registry_differs = (node is not None or has_element_child(current)) and catalog_node_key(node) != catalog_node_key(current)
        if different or registry_differs:
            if identified:
                return {"status": "CONFLICT", "target": candidate, "reason": f"existing {kind} differs: " + ", ".join(different)}
            continue
        if identified or not missing:
            matches.append({"status": "NOT_TRANSFERRED" if missing else "TRANSFERRED",
                            "name": candidate, "files": missing, "register": False})
        else:
            incomplete.append(candidate)
    if len(matches) > 1:
        return {"status": "MANUAL", "reason": "multiple matching children in configuration"}
    if not matches and incomplete:
        return {"status": "MANUAL", "reason": "incomplete matching child without a confirmed UUID: " + ", ".join(incomplete)}
    if matches:
        plan = matches[0]
    else:
        taken = {n.lower() for n in pool}
        folder = os.path.join(dest_root, kind + "s")
        if os.path.isdir(folder):
            for file in os.scandir(folder):
                taken.add((file.name if file.is_dir() else os.path.splitext(file.name)[0]).lower())
                if not file.is_dir() and _sg_root_uuid(file.path) == identity:
                    return {"status": "CONFLICT", "reason": f"unregistered {kind} UUID {identity}"}
        policy = get_object_support(owner_path)
        choice = get_target_name(name, prefix, taken, SETTINGS[get_object_kind(ctx["name"], policy)]["add_dev_objects"])
        if choice.get("taken"):
            return {"status": "CONFLICT", "reason": f"name taken in configuration ({choice['note']})"}
        target = choice["name"]
        projection = get_catalog_child_projection(entry, cfg, target, prefix, files, skd)
        if projection.get("status"):
            return projection
        node = projection.get("node")
        if node is None:
            node = etree.Element(f"{{{MD_NS}}}{kind}")
            node.text = target
        insert_form_node_at(children, node, find_child_anchor(children, kind, owner_kind), fw["eol"])
        plan = {"status": "NOT_TRANSFERRED", "name": target, "files": projection["files"], "register": True}
    plan.update(relative=relative, target=ctx["name"])
    plan["files"][relative] = {"xml": fw, "before": before, "write_owner": plan["register"]}
    return plan


def initialize_catalog_children(ext, objects):
    CATALOG_CHILDREN.clear()
    for obj in objects:
        order = object_child_order().get(obj["type"], ())
        if not set(order).intersection(("Form", "Template", "Command")):
            continue
        ctx = get_obj_context(ext["dir"], obj["type"], obj["name"])
        if not ctx["borrowed"] or ctx["md"]["children"] is None:
            continue
        for node in elem_children(ctx["md"]["children"]):
            kind, name = localname(node), md_child_name(node)
            if kind not in ("Form", "Template", "Command") or kind not in order:
                continue
            desc, error = None, None
            try:
                desc = get_catalog_child_descriptor(node, ctx["obj_dir"])
            except Exception as exc:
                error = str(exc)
            if desc is not None and test_adopted_node(desc):
                continue
            oid = f"{ctx['id']}.{kind}.{name}"
            CATALOG_CHILDREN[oid.lower()] = dict(id=oid, ctx=ctx, kind=kind, name=name, node=node, descriptor=desc, error=error)


def complete_catalog_children(prefix, cfg, selected, apply):
    changed = []
    pending = [entry for entry in CATALOG_CHILDREN.values() if entry.get("item", {}).get("status", "WAITING") == "WAITING"]
    while pending:
        again = []
        for entry in pending:
            try:
                plan = get_catalog_child_plan(entry, prefix, cfg)
            except Exception as exc:
                plan = {"status": "MANUAL", "reason": str(exc)}
            item = new_item(plan["status"], f"{kind_word(entry['kind'])} {entry['name']}")
            if plan.get("name") and plan["name"].lower() != entry["name"].lower():
                item["text"] += f" (as {plan['name']})"
            if plan.get("reason"):
                item["text"] += " — " + plan["reason"]
            item["plan"] = {"kind": "md-reference"}
            entry["item"] = item
            if plan["status"] == "WAITING":
                entry["dependency"] = plan.get("dependency")
                again.append(entry)
                continue
            if plan["status"] == "TRANSFERRED":
                entry["ready"] = plan["name"]
            if plan["status"] != "NOT_TRANSFERRED" or not apply or not selected(entry["ctx"]["id"]):
                continue
            support = get_object_support(os.path.join(MD_REFERENCE_ROOT, plan["relative"]))
            if support == "locked":
                item.update(status="MANUAL", text=item["text"] + " — object is locked by vendor support",
                            sub=["next: allow editing with /support-edit, then re-run -Mode transfer"])
                continue
            try:
                changed.extend(write_metadata_package({"type": entry["ctx"]["type"]}, plan))
                entry["ready"] = plan["name"]
                item.update(status="TRANSFERRED", now=True)
                if support == "warn":
                    item["text"] += " (object locked by vendor support, written: editingAllowedCheck = warn)"
            except Exception as exc:
                item.update(status="CONFLICT", text=item["text"] + " — " + str(exc))
        if len(again) == len(pending):
            break
        pending = again
    return changed


def catalog_node_key(node, ignore_slots=False, shallow=False, ignore_characteristic_type=False):
    if node is None:
        return None
    node = copy.deepcopy(node)
    for descendant in node.xpath("descendant-or-self::*[@uuid]"):
        del descendant.attrib["uuid"]
    for child in node.xpath(".//xr:TypeId|.//xr:ValueId", namespaces=MD_NSMAP):
        child.getparent().remove(child)
    if ignore_characteristic_type:
        for child in node.xpath("self::md:Properties/md:Type|self::md:ChartOfCharacteristicTypes/md:Properties/md:Type", namespaces=MD_NSMAP):
            child.getparent().remove(child)
    for child in elem_children(node):
        tag = localname(child)
        if (ignore_slots and (tag == "MainDataCompositionSchema" or
                             (tag.startswith(("Default", "Auxiliary")) and "Form" in tag))) or (shallow and tag == "ChildObjects"):
            node.remove(child)
    # Designer orders recorder links by metadata identity.
    for records in node.xpath("descendant-or-self::md:Properties/md:RegisterRecords", namespaces=MD_NSMAP):
        for record in sorted(elem_children(records), key=lambda child: inner_text(child).lower()):
            records.append(record)
    # The metadata compiler emits an empty string for the boolean flags' unset FillValue.
    flags = node.xpath("descendant-or-self::md:AccountingFlag/md:Properties/md:FillValue|"
                          "descendant-or-self::md:ExtDimensionAccountingFlag/md:Properties/md:FillValue", namespaces=MD_NSMAP)
    for fill in flags:
        type_name = fill.get(f"{{{XSI_NS}}}type", "").split(":", 1)
        if (not inner_text(fill) and len(type_name) == 2 and type_name[1] == "string"
                and (type_name[0] == "xs" or fill.nsmap.get(type_name[0]) == "http://www.w3.org/2001/XMLSchema")):
            fill.attrib.pop(f"{{{XSI_NS}}}type")
            fill.set(f"{{{XSI_NS}}}nil", "true")
    return node_canon(node)


def resolve_transfer_handler(value, prefix):
    match = re.fullmatch(r"(CommonModule\.)?(\w+)\.(\w+)", value, re.I)
    if not match:
        return {"status": "MANUAL", "reason": f"unsupported handler reference: '{value}'"}
    qualifier, module, method = match.groups()
    identity = f"CommonModule.{module}"
    ref = resolve_md_reference(identity, prefix)
    if ref.get("status"):
        return ref
    target = ref["value"].split(".")[1]
    base = f"CommonModules/{target}"
    relative = f"{base}/Ext/Module.bsl"
    path = os.path.join(MD_REFERENCE_ROOT, relative)
    if os.path.isfile(os.path.join(MD_REFERENCE_ROOT, base, "Ext", "Module.bin")):
        return {"status": "MANUAL", "reason": f"{value}: handler module is binary"}
    waiting = {"status": "WAITING", "reason": f"waiting for handler {value}", "dependency": identity}
    if method.lower() in ROOT_METHOD_BLOCKS.get(identity.lower(), ()) or not os.path.isfile(path):
        return waiting
    lines = read_bsl_lines(path)
    hits = find_names_in([decl["name"] for decl in get_proc_decls(lines)], method, prefix)
    hits = [name for name in hits if name.lower() == method.lower()] or hits
    if not hits:
        return waiting
    if len(hits) != 1:
        return {"status": "MANUAL", "reason": f"{value}: ambiguous handler ({', '.join(hits)})"}
    decl = get_method_safe(lines, hits[0])
    if not decl or not is_export(lines, decl):
        return {"status": "MANUAL", "reason": f"{value}: handler {target}.{hits[0]} is not a readable export"}
    return {"value": f"{qualifier or ''}{target}.{hits[0]}", "validation_files": (base + ".xml", relative)}


def get_predefined_tree(fw, kind, version, borrowed=False):
    root = fw["root"]
    expected_type = {"Catalog": "CatalogPredefinedItems", "ChartOfCharacteristicTypes": "PlanOfCharacteristicKindPredefinedItems",
                     "ChartOfAccounts": "ChartOfAccountsPredefinedItems", "ChartOfCalculationTypes": "CalculationTypePredefinedItems"}[kind]
    if (root.tag != f"{PREDEFINED_NS}PredefinedData" or root.get("version") != version
            or root.get(f"{{{XSI_NS}}}type") != expected_type):
        raise ValueError("unsupported Predefined.xml format")
    entries, by_id, by_name = [], {}, {}
    required = {"Name", "Code", "Description"}
    if kind in ("Catalog", "ChartOfCharacteristicTypes"):
        required.add("IsFolder")
    extra = {"ChartOfAccounts": ("AccountType", "OffBalance", "Order", "AccountingFlags", "ExtDimensionTypes"),
             "ChartOfCalculationTypes": ("ActionPeriodIsBase",)}.get(kind, ())
    allowed = required | set(extra)
    if borrowed:
        allowed.add('ExtensionState')
    if kind != "ChartOfCalculationTypes":
        allowed.add("ChildItems")
    if kind == "ChartOfCharacteristicTypes":
        allowed.add("Type")
    for node in root.iter(f"{PREDEFINED_NS}Item"):
        parent = node.getparent()
        parent_id = ""
        if parent is not root:
            if parent.tag != f"{PREDEFINED_NS}ChildItems":
                raise ValueError("invalid predefined hierarchy")
            parent_id = parent.getparent().get("id", "").lower()
            if parent_id not in by_id or not by_id[parent_id]["folder"]:
                raise ValueError(f"invalid predefined parent {parent_id}")
        fields = {}
        for leaf in elem_children(node):
            name = localname(leaf)
            if leaf.tag != PREDEFINED_NS + name or name not in allowed or name in fields:
                raise ValueError(f"unsupported predefined field {name}")
            fields[name] = leaf
        for field in sorted(required):
            if field not in fields or has_element_child(fields[field]):
                raise ValueError(f"invalid predefined field {field}")
        if "Type" in fields:
            for leaf in elem_children(fields["Type"]):
                name = localname(leaf)
                if (leaf.tag != f"{{{MD_NSMAP['v8']}}}{name}"
                        or not re.fullmatch(r"(Type|TypeSet|TypeId|\w+Qualifiers)", name)):
                    raise ValueError(f"unsupported predefined type field {name}")
        identity = node.get("id", "").lower()
        name, folder = inner_text(fields["Name"]), inner_text(fields["IsFolder"]) if "IsFolder" in fields else ""
        if (not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", identity)
                or not re.fullmatch(r"\w+", name) or identity in by_id or name.lower() in by_name
                or ("IsFolder" in fields and folder not in ("true", "false"))):
            raise ValueError(f"invalid or duplicate predefined item {name} ({identity})")
        state = inner_text(fields["ExtensionState"]) if "ExtensionState" in fields else "AdoptedCheck"
        if borrowed and (state not in ("Native", "AdoptedCheck", "AdoptedNotify")
                         or ("ExtensionState" in fields and has_element_child(fields["ExtensionState"]))):
            raise ValueError(f"unsupported predefined extension state '{state}' for {name}")
        item = {"id": identity, "name": name, "state": state, "code": inner_text(fields["Code"]),
                "description": inner_text(fields["Description"]), "folder": kind == "ChartOfAccounts" or folder == "true",
                "parent": parent_id, "node": node, "type": fields.get("Type"),
                "extra": tuple(node_canon(fields[key]) if key in fields else "" for key in extra)}
        entries.append(item)
        by_id[identity] = item
        by_name[name.lower()] = item
    for container in (root, *root.iter(f"{PREDEFINED_NS}ChildItems")):
        if any(child.tag != f"{PREDEFINED_NS}Item" for child in elem_children(container)):
            raise ValueError("unsupported predefined list element")
    return entries, by_id, by_name


def predefined_code_value(item, owner_props):
    code = item["code"]
    if code and owner_props.findtext("md:CodeType", namespaces=MD_NSMAP) == "Number":
        try:
            decimal = Decimal(code)
            if decimal.is_finite():
                return decimal
        except InvalidOperation:
            pass
        raise ValueError(f"invalid predefined numeric code {code}")
    return code


def predefined_code_key(item, owner_props):
    code = predefined_code_value(item, owner_props)
    if isinstance(code, str):
        code = code.rstrip().lower()
    if code == "" or owner_props.findtext("md:CheckUnique", namespaces=MD_NSMAP) != "true":
        return None
    series = owner_props.findtext("md:CodeSeries", namespaces=MD_NSMAP)
    parent = item["parent"] if series in ("WithinSubordination", "WithinOwnerSubordination") else ""
    return parent, code


def merge_predefined_tree(source, destination, owner_props, kind, version, wanted=None):
    if wanted is None:
        wanted, _, _ = get_predefined_tree(source, kind, version)
    existing, by_id, by_name = get_predefined_tree(destination, kind, version) if destination else ([], {}, {})
    added, matched = [], 0
    codes = {key: item for item in existing if (key := predefined_code_key(item, owner_props)) is not None}
    for item in wanted:
        same = by_id.get(item["id"])
        if same:
            if (any(same[field] != item[field] for field in ("parent", "name", "description", "folder", "extra"))
                    or predefined_code_value(same, owner_props) != predefined_code_value(item, owner_props)
                    or not test_md_type_model_equal(get_md_type_model(same["type"], ""), get_md_type_model(item["type"], ""))):
                return {"reason": f"predefined item {item['name']} ({item['id']}) differs in properties or parent"}
            matched += 1
            continue
        collision = by_name.get(item["name"].lower())
        if collision:
            return {"reason": f"predefined name {item['name']} is used by {collision['id']}, expected {item['id']}"}
        key = predefined_code_key(item, owner_props)
        if key is not None:
            if key in codes:
                return {"reason": f"predefined code {item['code']} is already used by {codes[key]['name']}"}
            codes[key] = item
        added.append(item["name"])
        if destination:
            container = destination["root"]
            if item["parent"]:
                parent = by_id[item["parent"]]["node"]
                container = parent.find(f"{PREDEFINED_NS}ChildItems")
                if container is None:
                    container = etree.Element(f"{PREDEFINED_NS}ChildItems")
                    insert_form_node_at(parent, container, None, destination["eol"])
            source_node = item["node"]
            new = etree.Element(source_node.tag, attrib=dict(source_node.attrib), nsmap=source_node.nsmap)
            new.text = source_node.text
            for child in source_node:
                if child.tag != f"{PREDEFINED_NS}ChildItems":
                    new.append(copy.deepcopy(child))
            if item["state"] == "Native":
                new.remove(new.find(PREDEFINED_NS + "ExtensionState"))
                new.find(PREDEFINED_NS + "Name").text = item["name"]
            insert_form_node_at(container, new, None, destination["eol"])
            by_id[item["id"]] = {"node": new}
    return {"added": added, "matched": matched}


def get_borrowed_predefined_plan(entries, destination, owner, kind, name, prefix, version, policy):
    _, by_id, by_name = get_predefined_tree(destination, kind, version)
    taken = set(by_name)
    parents = {"": ""}
    wanted, kept, bindings = [], [], {}
    add_dev = SETTINGS[get_object_kind(name, policy)]["add_dev_objects"]
    for item in entries:
        parent = parents.get(item["parent"])
        if item["state"] != "Native":
            # Adopted GUIDs can differ. Match a controlled group along the actual parent chain.
            match = by_id.get(item["id"]) or by_name.get(item["name"].lower())
            if (item["state"] == "AdoptedCheck" and parent is not None and match and match["folder"]
                    and match["name"].lower() == item["name"].lower() and match["parent"] == parent):
                parents[item["id"]] = match["id"]
            continue
        if parent is None:
            return {"status": "CONFLICT", "reason": f"cannot match the adopted parent of {item['name']}"}
        original_name = item["name"]
        same = by_id.get(item["id"])
        if same:
            target = same["name"]
        else:
            choice = get_target_name(original_name, prefix, taken, add_dev)
            if choice.get("taken"):
                return {"status": "CONFLICT", "reason": f"predefined name {original_name} is occupied ({choice['note']})"}
            target = choice["name"]
        taken.add(target.lower())
        parents[item["id"]] = item["id"]
        bindings[f"{kind}.{name}.{original_name}".lower()] = target
        if original_name.lower() == target.lower():
            kept.append(target)
        wanted.append(dict(item, name=target, parent=parent))
    result = merge_predefined_tree(None, destination, owner["props"], kind, version, wanted)
    if result.get("reason"):
        return dict(result, status="CONFLICT")
    return dict(result, bindings=bindings, kept=kept)


def initialize_borrowed_predefined(ext, objects, cfg, selected, apply, retry=False):
    global SUPPORT_INFO
    support_loaded = apply
    if not retry:
        BORROWED_PREDEFINED_BINDINGS.clear()
        BORROWED_PREDEFINED_ITEMS.clear()
    changed = []
    for obj in objects:
        kind = obj["type"]
        if kind not in PREDEFINED_KINDS:
            continue
        name = obj["name"]
        oid = f"{kind}.{name}"
        if retry and BORROWED_PREDEFINED_ITEMS.get(oid.lower(), {}).get("status") != "WAITING":
            continue
        directory = CHILD_TYPE_DIR_MAP[kind]
        rel = f"{directory}/{name}/Ext/Predefined.xml"
        source_path = os.path.join(ext["dir"], rel)
        if not os.path.isfile(source_path):
            continue
        ctx = get_obj_context(ext["dir"], kind, name)
        if not ctx["borrowed"]:
            continue
        keys = {}
        try:
            src = read_form_write(source_path)
            version = ctx["md"]["el"].getroottree().getroot().get("version")
            keys = {f"{oid}.{inner_text(node)}".lower(): f"{oid}.{inner_text(node)}"
                    for node in src["root"].xpath(".//pre:Item[pre:ExtensionState='Native']/pre:Name",
                                                 namespaces={"pre": PREDEFINED_NS[1:-1]})}
            entries, _, _ = get_predefined_tree(src, kind, version, borrowed=True)
            if not keys:
                continue
            owner_rel = f"{directory}/{name}.xml"
            owner_path = os.path.join(MD_REFERENCE_ROOT, owner_rel)
            with open(owner_path, "rb") as owner_file:
                owner_before = owner_file.read()
            owner = read_md_object(owner_path)
            adopted_id = ctx["md"]["props"].findtext("md:ExtendedConfigurationObject", "", MD_NSMAP)
            if (cfg["child_objects"] is None or not any(node.text == name for node in cfg["child_objects"].findall(f"md:{kind}", MD_NSMAP))
                    or not owner or localname(owner["el"]) != kind or (owner["el"].get("uuid") or "").lower() != adopted_id.lower()):
                raise ValueError("borrowed owner identity does not match")
            if owner["el"].getroottree().getroot().get("version") != version:
                raise ValueError("metadata dump formats differ")
            if (kind == "Catalog" and owner["props"].findtext("md:Hierarchical", namespaces=MD_NSMAP) != "true"
                    and any(entry["state"] == "Native" and (entry["parent"] or entry["folder"]) for entry in entries)):
                raise ValueError("the target catalog does not support hierarchy")
            path = os.path.join(MD_REFERENCE_ROOT, rel)
            before = None
            if os.path.isfile(path):
                with open(path, "rb") as original:
                    before = original.read()
            destination = read_form_write(path if before is not None else source_path)
            if before is None:
                for node in list(destination["root"]):
                    destination["root"].remove(node)
            if not support_loaded:
                SUPPORT_INFO = get_support_info(MD_REFERENCE_ROOT)
                support_loaded = True
            policy = get_object_support(owner_path)
            refs = {}
            for entry in entries:
                if entry["state"] != "Native":
                    continue
                original = entry["node"]
                node = etree.Element(original.tag, nsmap=original.nsmap, attrib=original.attrib)
                node.extend(copy.deepcopy(child) for child in original if child.tag != PREDEFINED_NS + "ChildItems")
                refs = convert_catalog_xml({"root": node}, cfg, name, name, ext["prefix"], False, owner_kind=kind)
                if refs:
                    break
                entry["node"] = node
                entry["type"] = node.find(PREDEFINED_NS + "Type")
                if kind == "ChartOfAccounts":
                    entry["extra"] = tuple(node_canon(field) if field is not None else "" for field in
                                           (node.find(PREDEFINED_NS + name) for name in
                                            ("AccountType", "OffBalance", "Order", "AccountingFlags", "ExtDimensionTypes")))
            plan = refs or get_borrowed_predefined_plan(entries, destination, owner, kind, name, ext["prefix"], version, policy)
            if plan.get("status"):
                item = new_md_reference_item("predefined items", plan)
            else:
                label = f"predefined items ({', '.join(plan['bindings'].values())})"
                if plan["kept"]:
                    label += " — deactivate the old extension before updating the database: predefined names overlap"
                item = new_item("NOT_TRANSFERRED" if plan["added"] else "TRANSFERRED", label)
                item["plan"] = {"kind": "md-reference"}
                if plan["added"] and apply and selected(oid):
                    if policy == "locked":
                        item = new_md_reference_item(label, {"status": "MANUAL", "reason": f"{owner_rel} is locked by vendor support"})
                    else:
                        files = {owner_rel: {"xml": read_form_write(owner_path), "before": owner_before, "write_owner": False},
                                 rel: {"xml": destination, "before": before, "write_owner": True}}
                        try:
                            changed.extend(write_metadata_package({"type": kind},
                                                                  {"relative": owner_rel, "target": name, "files": files}))
                            item.update(status="TRANSFERRED", now=True)
                            ROOT_DATA_WARNINGS.append(f"Predefined items in {oid} — verify linked predefined data before removing the extension")
                            if policy == "warn":
                                item["text"] += " (locked by vendor support, written: editingAllowedCheck = warn)"
                        except Exception as exc:
                            item = new_md_reference_item(label, {"status": "CONFLICT", "reason": str(exc)})
        except Exception as exc:
            item = new_md_reference_item("predefined items", {"status": "MANUAL", "reason": str(exc)})
            plan = {}
        item["section"] = rel
        BORROWED_PREDEFINED_ITEMS[oid.lower()] = item
        for key, path in keys.items():
            BORROWED_PREDEFINED_BINDINGS[key] = ({"name": plan["bindings"][key]} if item["status"] == "TRANSFERRED"
                                                else {"status": "WAITING", "reason": f"waiting for predefined item {path}",
                                                      "dependency": path})
    return changed


def xdto_package_context(path, ext_dir, target, cfg):
    ns = "{http://v8.1c.ru/8.1/xdto}"
    document = read_form_doc(path)
    package = document.getroot() if document is not None else None
    uri = package.get("targetNamespace") if package is not None else None
    if package is None or package.tag != ns + "package" or not uri:
        return {"status": "MANUAL", "reason": "unsupported XDTO package format"}
    imports = {node.get("namespace") for node in package.findall(ns + "import")}
    known = set()
    context = []
    for node in cfg["child_objects"].findall("md:XDTOPackage", MD_NSMAP):
        name = inner_text(node).strip()
        if name.lower() == target.lower():
            continue
        rel = f"XDTOPackages/{name}/Ext/Package.bin"
        other = read_form_doc(os.path.join(MD_REFERENCE_ROOT, rel))
        if other is None:
            continue
        other_uri = other.getroot().get("targetNamespace")
        if other_uri == uri:
            return {"status": "CONFLICT", "reason": f"XDTO namespace is already registered by {name}"}
        known.add(other_uri)
        context.append(rel)
    if imports:
        for key, entry in sorted(ROOT_OWN.items()):
            if entry["type"] != "XDTOPackage" or key in ROOT_PROVISIONAL:
                continue
            other_path = os.path.join(ext_dir, f"XDTOPackages/{entry['name']}/Ext/Package.bin")
            if os.path.normcase(os.path.normpath(other_path)) == os.path.normcase(os.path.normpath(path)):
                continue
            other = read_form_doc(other_path)
            other_uri = other.getroot().get("targetNamespace") if other is not None else None
            if other_uri and other_uri in imports - known:
                oid = entry["id"]
                return {"status": "WAITING", "reason": f"waiting for {oid} imported by XDTO package", "dependency": oid}
    return {"validation_files": context}


def skd_transfer_issue(schema, self_id, target, prefix, rel):
    if schema.tag != "{http://v8.1c.ru/8.1/data-composition-system/schema}DataCompositionSchema":
        return {"status": "MANUAL", "reason": f"unsupported data composition schema {rel}"}
    # Query and expression text can contain references that the metadata resolver cannot rewrite.
    leaves = schema.xpath("//*[not(*)][local-name()='query' or local-name()='expression' "
                          "or local-name()='Type' or local-name()='TypeSet']")
    words = {word.lower() for leaf in leaves for word in re.findall(r"\w+", inner_text(leaf))}
    for oid, dependency in sorted(ROOT_OWN.items()):
        name = dependency["name"]
        if name.lower() not in words:
            continue
        identity = dependency["id"]
        alias = target if oid == self_id.lower() else ROOT_PROVISIONAL.get(oid, {}).get("target", ROOT_BINDINGS.get(oid))
        if not alias:
            return {"status": "WAITING", "reason": f"waiting for {identity} referenced in {rel}",
                    "dependency": identity}
        if alias.lower() != name.lower():
            return {"status": "MANUAL", "reason": f"inspect reference to {identity} in {rel} (as {alias})"}
    if prefix:
        for oid in sorted(ROOT_SOURCE_IDS):
            name = oid.split(".", 1)[1]
            if oid not in ROOT_OWN and name.startswith(prefix.lower()) and name in words:
                ref = resolve_md_reference(oid, prefix)
                if ref.get("status") or ref["value"].lower() != oid:
                    return {"status": "MANUAL", "reason": f"inspect unresolved reference to {oid} in {rel}"}
    return {}


def root_metadata_projection(entry, cfg, source, files, target, prefix, enum_aliases=None, skd=()):
    base = f"{CHILD_TYPE_DIR_MAP[entry['type']]}/{target}"
    fw = read_form_write(source["path"])
    result = convert_catalog_xml(fw, cfg, entry["name"], target, prefix, True)
    if result:
        return result
    plan = {"target": target, "relative": base + ".xml", "files": {base + ".xml": {"xml": fw}}}
    if entry["type"] == "XDTOPackage":
        context = xdto_package_context(files["Ext/Package.bin"], os.path.dirname(os.path.dirname(source["path"])), target, cfg)
        if context.get("status"):
            return context
        plan.update(context)
    if entry["type"] in ("EventSubscription", "ScheduledJob"):
        prop = "Handler" if entry["type"] == "EventSubscription" else "MethodName"
        handler = get_md_object_element(fw["root"]).find(f"md:Properties/md:{prop}", MD_NSMAP)
        ref = resolve_transfer_handler(inner_text(handler) if handler is not None else "", prefix)
        if ref.get("status"):
            return ref
        handler.text = ref["value"]
        plan["validation_files"] = ref["validation_files"]
    if enum_aliases:
        for node in fw["root"].xpath("//md:EnumValue/md:Properties/md:Name", namespaces=MD_NSMAP):
            node.text = enum_aliases.get(node.text.lower(), node.text)
    if entry["type"] == "CommonPicture" and files:
        rel = "Ext/Picture.xml"
        if rel not in files:
            return {"status": "MANUAL", "reason": f"missing common picture {rel}"}
        xml = read_form_write(files[rel])["root"]
        ns = "{http://v8.1c.ru/8.3/xcf/extrnprops}"
        abs_nodes = xml.findall(ns + "Picture/{http://v8.1c.ru/8.3/xcf/readable}Abs")
        if xml.tag != ns + "ExtPicture" or len(abs_nodes) != 1 or xml.get("version") != fw["root"].get("version"):
            return {"status": "MANUAL", "reason": f"unsupported common picture {rel}"}
        payload = "Ext/Picture/" + inner_text(abs_nodes[0])
        if payload not in files or len(files) != 2:
            return {"status": "MANUAL", "reason": f"incomplete or ambiguous common picture payload: {payload}"}
        plan["files"][f"{base}/{rel}"] = {"copy": files[rel], "external_xml": xml}
        plan["files"][f"{base}/{payload}"] = {"copy": files[payload]}
        return plan
    for rel, path in sorted(files.items()):
        if rel.endswith(".bsl"):
            bsl = read_bsl_file(path)
            projection = get_root_bsl_projection(bsl["lines"], prefix, entry["id"], target, rel, enum_aliases=enum_aliases)
            if projection.get("status"):
                return projection
            data = {"bsl": bsl, "lines": projection["lines"]}
        elif rel == "Ext/Predefined.xml":
            fw = read_form_write(path)
            issue = convert_catalog_xml(fw, cfg, entry["name"], target, prefix, False, owner_kind=entry["type"])
            if issue:
                return issue
            descriptor = plan["files"][plan["relative"]]["xml"]["root"]
            props = get_md_object_element(descriptor).find("md:Properties", MD_NSMAP)
            merged = merge_predefined_tree(fw, None, props, entry["type"], descriptor.get("version"))
            if merged.get("reason"):
                return {"status": "MANUAL", "reason": merged["reason"]}
            plan["has_predefined"] = True
            data = {"xml": fw}
        elif rel in ("Ext/Content.xml", "Ext/Flowchart.xml") and entry["type"] in ("ExchangePlan", "BusinessProcess"):
            fw = read_form_write(path)
            root = fw["root"]
            is_flowchart = entry["type"] == "BusinessProcess"
            tag = ("{http://v8.1c.ru/8.3/xcf/scheme}GraphicalSchema" if is_flowchart
                   else "{http://v8.1c.ru/8.3/xcf/extrnprops}ExchangePlanContent")
            empty_flow = is_flowchart and root.tag == f"{{{MD_NSMAP['md']}}}Flowchart" and not elem_children(root)
            descriptor = plan["files"][plan["relative"]]["xml"]["root"]
            if (root.tag != tag and not empty_flow) or root.get("version") != descriptor.get("version"):
                return {"status": "MANUAL", "reason": f"unsupported external metadata {rel}"}
            issue = convert_catalog_xml(fw, cfg, entry["name"], target, prefix, False, owner_kind=entry["type"])
            if issue:
                return issue
            if not is_flowchart:
                ns = "{http://v8.1c.ru/8.3/xcf/extrnprops}"
                members = set()
                for member in elem_children(root):
                    parts = elem_children(member)
                    if (member.tag != ns + "Item" or [part.tag for part in parts] != [ns + "Metadata", ns + "AutoRecord"]
                            or not re.fullmatch(r"\w+\.\w+", inner_text(parts[0]))
                            or inner_text(parts[1]) not in ("Allow", "Deny") or inner_text(parts[0]).lower() in members):
                        return {"status": "MANUAL", "reason": f"invalid or duplicate exchange plan member in {rel}"}
                    members.add(inner_text(parts[0]).lower())
            data = {"xml": fw, "flowchart": is_flowchart, "exchange_content": not is_flowchart}
        elif re.fullmatch(r"Ext/Help/[^/]+\.html", rel):
            data = {"copy": path}
        elif rel in skd:
            issue = skd_transfer_issue(read_form_write(path)["root"], entry["id"], target, prefix, rel)
            if issue:
                return issue
            data = {"copy": path, "skd": True}
        elif (re.search(r"(?:^|/)Ext/Template\.(xml|txt|bin)$", rel)
              or re.search(r"(?:^|/)Ext/Help/[^/]+\.html$", rel)
              or (entry["type"] == "XDTOPackage" and rel == "Ext/Package.bin")
              or (entry["type"] == "WSReference" and re.fullmatch(r"Ext/(WSDefinition\.xml|[1-9][0-9]*\.xsd)", rel))):
            data = {"copy": path}
        elif entry["type"] == "Role" and rel == "Ext/Rights.xml":
            fw = read_form_write(path)
            descriptor = plan["files"][plan["relative"]]["xml"]["root"]
            issue = convert_role_rights(fw["root"], cfg, prefix, descriptor.get("version"))
            if issue:
                return issue
            data = {"xml": fw, "role_rights": True}
        elif entry["type"] == "ScheduledJob" and rel == "Ext/Schedule.xml":
            schedule = read_form_write(path)["root"]
            ns = "{http://v8.1c.ru/8.3/xcf/extrnprops}"
            if (schedule.tag != ns + "JobSchedule" or schedule.get("version") != fw["root"].get("version")
                    or len(schedule.findall(ns + "Schedule")) != 1):
                return {"status": "MANUAL", "reason": f"unsupported scheduled job schedule {rel}"}
            data = {"copy": path, "external_xml": schedule}
        else:
            xml = read_form_write(path)
            if entry["type"] in EXTRA_PACKAGE_KINDS:
                for filename, tag, ns in (("Form", "Form", "logform"), ("Style", "Style", "extrnprops"),
                                          ("CommandInterface", "CommandInterface", "extrnprops")):
                    if not (rel == f"Ext/{filename}.xml" or rel.endswith(f"/Ext/{filename}.xml")):
                        continue
                    root = xml["root"]
                    if (root.tag != f"{{http://v8.1c.ru/8.3/xcf/{ns}}}{tag}"
                            or root.get("version") != source["root"].get("version")):
                        return {"status": "MANUAL", "reason": f"unsupported {rel}"}
                    if tag == "Form" and root.find("{*}BaseForm") is not None:
                        return {"status": "MANUAL", "reason": f"form body contains a borrowed BaseForm: {rel}"}
            result = convert_catalog_xml(xml, cfg, entry["name"], target, prefix, False, owner_kind=entry["type"])
            if result:
                return result
            data = {"xml": xml}
            if entry["type"] == "CommonForm" and rel == "Ext/Form.xml":
                data["common_form_body"] = True
        plan["files"][f"{base}/{rel}"] = data
    return plan


def flowchart_key(node):
    if node is None:
        return None
    layout = {"BackColor", "GridEnabled", "DrawGridMode", "GridHorizontalStep", "GridVerticalStep", "PrintParameters", "Items"}
    if (node.tag in (f"{{{MD_NSMAP['md']}}}Flowchart", "{http://v8.1c.ru/8.3/xcf/scheme}GraphicalSchema")
            and all(localname(child) in layout and (localname(child) != "Items" or not elem_children(child))
                    for child in elem_children(node))):
        return "empty route " + node.get("version", "")
    projected = copy.deepcopy(node)
    for entry in projected.xpath("descendant-or-self::*[@id]"):
        entry.set("route-point-id", entry.get("id"))
    # The Designer writes empty placeholder events for the available handlers.
    for event in projected.xpath("//*[local-name()='Events']/*[local-name()='Event' and @name and count(@*)=1 and not(*)]"):
        if not inner_text(event).strip():
            event.getparent().remove(event)
    return node_canon(projected)


def convert_role_rights(root, cfg, prefix, version):
    ns = "{http://v8.1c.ru/8.2/roles}"
    if root.tag != ns + "Rights" or root.get("version") != version:
        return {"status": "MANUAL", "reason": "unsupported role rights format"}
    renamed = set()
    for obj in root.findall(ns + "object"):
        node = obj.find(ns + "name")
        value = inner_text(node).strip() if node is not None else ""
        if re.fullmatch(r"Configuration\.\w+", value, re.I):
            node.text = f"Configuration.{cfg['name']}"
            continue
        match = re.fullmatch(r"(\w+)\.\w+(?:\.\w+\.\w+)*", value)
        if not match or match[1] not in CHILD_TYPE_DIR_MAP:
            return {"status": "MANUAL", "reason": f"unsupported role object: {value}"}
        ref = resolve_md_reference(value, prefix)
        if ref.get("status"):
            return ref
        target = ref["value"]
        if target.lower() in renamed:
            return {"status": "MANUAL", "reason": f"duplicate role object: {target}"}
        renamed.add(target.lower())
        node.text = target
    # Query text can contain metadata paths and prefixed members. Leave such roles for review.
    for condition in root.iter(ns + "condition"):
        for token in re.findall(r"\w+", inner_text(condition)):
            if prefix and token.lower().startswith(prefix.lower()):
                return {"status": "MANUAL", "reason": f"review extension identifier {token} in RLS condition"}
    return {}


def unordered_metadata_xml_key(node):
    children = sorted((node_canon(item), tuple(inner_text(condition) for condition in
                                              item.xpath(".//*[local-name()='condition']")))
                      for item in elem_children(node))
    return node.tag, node.get("version"), children


def common_form_body_key(node):
    root = copy.deepcopy(node)
    for default in root.xpath("*[(local-name()='ChildItems' or local-name()='Attributes') and not(*) and not(@*) and not(normalize-space())]|"
                              "*[local-name()='AutoCommandBar']/*[local-name()='Autofill' and text()='true' and not(*) and not(@*)]"):
        default.getparent().remove(default)
    return catalog_node_key(root)


def catalog_file_equal(entry, path):
    if entry.get("role_rights") or entry.get("exchange_content"):
        other = read_form_doc(path)
        return other is not None and unordered_metadata_xml_key(entry["xml"]["root"]) == unordered_metadata_xml_key(other.getroot())
    if entry.get("flowchart"):
        other = read_form_doc(path)
        return other is not None and flowchart_key(entry["xml"]["root"]) == flowchart_key(other.getroot())
    if "bsl" in entry:
        return root_object_code_key(entry["lines"]) == root_object_code_key(read_bsl_lines(path))
    if entry.get("common_form_body"):
        other = read_form_doc(path)
        return other is not None and common_form_body_key(entry["xml"]["root"]) == common_form_body_key(other.getroot())
    if "xml" in entry:
        return catalog_node_key(entry["xml"]["root"]) == catalog_node_key(read_form_write(path)["root"])
    if "external_xml" in entry:
        return node_canon(entry["external_xml"]) == node_canon(read_form_write(path)["root"])
    with open(entry["copy"], "rb") as source, open(path, "rb") as target:
        return source.read() == target.read()


def compare_catalog_children(source, target, relative, merge=False, blocked=(), stored=True):
    score, items, file_conflicts = 0, [], set()
    for node in elem_children(source) if source is not None else ():
        kind, name = localname(node), md_child_name(node)
        label = f"{kind} {name}"
        existing = [x for x in elem_children(target) if localname(x) == kind and md_child_name(x).lower() == name.lower()] if target is not None else []
        if f"{kind}.{name}" in blocked:
            items.append(new_item("CONFLICT", label + " — related child files differ"))
        elif not existing:
            item = new_item("NOT_TRANSFERRED", label)
            if stored and kind in ("Attribute", "TabularSection", "Dimension", "Resource"):
                item["stored"] = f"{relative}: {label}"
            items.append(item)
            if merge:
                anchor = find_child_anchor(target, kind, localname(target.getparent()))
                insert_form_node_at(target, copy.deepcopy(node), anchor, "\n")
        elif len(existing) == 1 and catalog_node_key(node) == catalog_node_key(existing[0]):
            if kind in ("Attribute", "TabularSection", "Dimension", "Resource"):
                score += 1
            items.append(new_item("TRANSFERRED", label))
        elif (kind == "TabularSection" and len(existing) == 1
              and catalog_node_key(node, shallow=True) == catalog_node_key(existing[0], shallow=True)):
            columns = node.find("md:ChildObjects", MD_NSMAP)
            dest_columns = existing[0].find("md:ChildObjects", MD_NSMAP)
            if dest_columns is None and columns is not None and merge:
                dest_columns = etree.SubElement(existing[0], f"{{{MD_NS}}}ChildObjects")
            count, detail, _ = compare_catalog_children(columns, dest_columns, relative + "/" + name, merge, stored=stored)
            score += count
            items.extend(detail)
        else:
            items.append(new_item("CONFLICT", label + " — existing child differs"))
            if kind in ("Form", "Command", "Template"):
                file_conflicts.add(f"{kind}.{name}")
    return score, items, file_conflicts


def get_structured_target_set(entry, node, prefix, cfg):
    kind = entry["type"]
    identity = metadata_transfer_uuid(cfg, kind, node.get("uuid"))
    registry = [(localname(n), inner_text(n)) for n in elem_children(cfg["child_objects"])]
    ids = [(kind, name) for kind, name in registry if kind in CHILD_TYPE_DIR_MAP
           and _sg_root_uuid(os.path.join(MD_REFERENCE_ROOT, CHILD_TYPE_DIR_MAP[kind], name + ".xml")) == identity]
    if len(ids) > 1 or (ids and ids[0][0] != kind):
        return {"status": "CONFLICT", "reason": f"{kind} UUID {identity} collides in configuration"}
    pool = [name for tag, name in registry if tag == kind]
    candidates = [ids[0][1]] if ids else find_names_in(pool, entry["name"], prefix)
    return {"uuid": identity, "known": bool(ids), "pool": pool, "candidates": candidates}


def get_new_structured_target(entry, targets, prefix):
    kind = entry["type"]
    directory = os.path.join(MD_REFERENCE_ROOT, CHILD_TYPE_DIR_MAP[kind])
    taken = {name.lower() for name in targets["pool"]}
    taken.update(value["target"].lower() for key, value in ROOT_PROVISIONAL.items()
                 if key != entry["key"] and ROOT_OWN[key]["type"] == kind)
    if os.path.isdir(directory):
        for file in os.scandir(directory):
            if file.is_dir():
                taken.add(file.name.lower())
            elif file.name.lower().endswith(".xml"):
                taken.add(file.name[:-4].lower())
                if _sg_root_uuid(file.path) == targets["uuid"]:
                    return {"status": "CONFLICT", "reason": f"{kind} UUID {targets['uuid']} exists in an unregistered descriptor"}
    settings = SETTINGS[get_object_kind(entry["name"], "own")]
    choice = get_target_name(entry["name"], prefix, taken, settings["add_dev_objects"])
    if choice.get("taken"):
        return {"status": "CONFLICT", "reason": f"name taken in configuration ({choice['note']})"}
    return {"target": choice["name"]}


def get_structured_transfer_plan(entry, ext_dir, prefix, cfg):
    children = cfg["child_objects"]
    if children is None:
        return {"status": "MANUAL", "reason": "configuration has no ChildObjects"}
    kind = entry["type"]
    directory = CHILD_TYPE_DIR_MAP[kind]
    label = "catalog" if kind == "Catalog" else kind
    stored = kind in PREDEFINED_KINDS + LINKED_TRANSFER_KINDS + ('ExchangePlan', 'BusinessProcess', 'Task')
    path = os.path.join(ext_dir, directory, entry["name"])
    source = read_form_write(path + ".xml")
    if source["root"].get("version") != children.getroottree().getroot().get("version"):
        return {"status": "MANUAL", "reason": "metadata dump formats differ"}
    node = get_md_object_element(source["root"])
    if localname(node) != kind or not node.get("uuid"):
        return {"status": "MANUAL", "reason": f"unsupported {kind} descriptor"}
    files, skd = catalog_files(source["root"], path)
    targets = get_structured_target_set(entry, node, prefix, cfg)
    if targets.get("status"):
        return targets
    matches, uncertain = [], []
    for name in targets["candidates"]:
        plan = root_metadata_projection(entry, cfg, source, files, name, prefix, skd=skd)
        if plan.get("status"):
            return plan
        path = os.path.join(MD_REFERENCE_ROOT, plan["relative"])
        if not os.path.isfile(path):
            return {"status": "CONFLICT", "reason": "missing descriptor " + plan["relative"]}
        with open(path, "rb") as original:
            before = original.read()
        dest = read_form_write(path)
        a = get_md_object_element(plan["files"][plan["relative"]]["xml"]["root"])
        b = get_md_object_element(dest["root"])
        chart = kind == "ChartOfCharacteristicTypes"
        props_a = a.find("md:Properties", MD_NSMAP)
        props_b = b.find("md:Properties", MD_NSMAP)
        props = catalog_node_key(props_a, ignore_slots=True, ignore_characteristic_type=chart) == catalog_node_key(
            props_b, ignore_slots=True, ignore_characteristic_type=chart)
        if props and chart:
            props = test_md_type_model_equal(get_md_type_model(props_a.find("md:Type", MD_NSMAP), ""),
                                             get_md_type_model(props_b.find("md:Type", MD_NSMAP), ""))
        x, y = (obj.find("md:ChildObjects", MD_NSMAP) for obj in (a, b))
        if y is None:
            y = etree.SubElement(b, f"{{{MD_NS}}}ChildObjects")
        score, _, blocked = compare_catalog_children(x, y, plan["relative"])
        predefined_rel = f"{directory}/{name}/Ext/Predefined.xml"
        predefined_path = os.path.join(MD_REFERENCE_ROOT, predefined_rel)
        predefined, predefined_write = {}, None
        if plan.get("has_predefined") and os.path.isfile(predefined_path):
            try:
                with open(predefined_path, "rb") as original:
                    predefined_before = original.read()
                merged = read_form_write(predefined_path)
                predefined = merge_predefined_tree(plan["files"][predefined_rel]["xml"], merged,
                                                   b.find("md:Properties", MD_NSMAP), kind, dest["root"].get("version"))
                if predefined.get("added"):
                    predefined_write = {"xml": merged, "before": predefined_before, "write_owner": True}
            except (OSError, ValueError, etree.XMLSyntaxError) as exc:
                predefined = {"reason": str(exc)}
            if predefined.get("reason") and (targets["known"] or props):
                return {"status": "CONFLICT", "reason": f"{predefined_rel} — {predefined['reason']}"}
        items, available = [], {}
        for rel, file in sorted(plan["files"].items()):
            if rel == plan["relative"]:
                continue
            if rel == predefined_rel and predefined and not predefined.get("reason"):
                continue
            sub = rel[len(f"{directory}/{name}/"):]
            parts = sub.split("/")
            group = "" if parts[0] == "Ext" else parts[0][:-1] + "." + os.path.splitext(parts[1])[0]
            dest_file = os.path.join(MD_REFERENCE_ROOT, rel)
            if not os.path.isfile(dest_file):
                available[rel] = group
            elif not catalog_file_equal(file, dest_file):
                items.append(new_item("CONFLICT", sub + " — existing file differs"))
                if group:
                    blocked.add(group)
        full = (props and not predefined_write and not items and not available
                and catalog_node_key(a, ignore_characteristic_type=chart) == catalog_node_key(b, ignore_characteristic_type=chart))
        if not targets["known"] and not full and not (kind not in LINKED_TRANSFER_KINDS and props and (score or predefined.get("matched"))):
            if props or score:
                uncertain.append(name)
            continue
        if not props and plan.get("has_predefined") and (predefined_write or not os.path.isfile(predefined_path)):
            return {"status": "CONFLICT", "reason": f"{label} properties differ; cannot merge predefined items"}
        if not props:
            items.append(new_item("CONFLICT", f"{label} properties differ"))
        _, detail, _ = compare_catalog_children(x, y, plan["relative"], True, blocked, stored)
        items.extend(detail)
        write_owner = any(item["status"] == "NOT_TRANSFERRED" for item in detail)
        writes = {}
        if predefined_write:
            writes[predefined_rel] = predefined_write
            item = new_item("NOT_TRANSFERRED", "predefined items: " + ", ".join(predefined["added"]))
            item["stored"] = f"{kind}.{name} — predefined data"
            items.append(item)
        elif predefined and not predefined.get("reason"):
            items.append(new_item("TRANSFERRED", "predefined items"))
        for rel, group in available.items():
            if group in blocked:
                items.append(new_item("CONFLICT", rel + " — related child files differ"))
            else:
                writes[rel] = plan["files"][rel]
                item = new_item("NOT_TRANSFERRED", rel)
                if rel == predefined_rel:
                    item["stored"] = f"{kind}.{name} — predefined data"
                items.append(item)
        for slot in a.xpath(ROOT_SLOT_PATH, namespaces=MD_NSMAP):
            tag = localname(slot)
            dest_slot = b.find("md:Properties/md:" + tag, MD_NSMAP)
            if not slot.text or (dest_slot is not None and dest_slot.text == slot.text):
                continue
            if dest_slot is None:
                items.append(new_item("CONFLICT", tag + " — missing assignment property"))
                continue
            slot_kind = "Template" if tag == "MainDataCompositionSchema" else "Form"
            if not dest_slot.text and f"{slot_kind}.{slot.text.split('.')[-1]}" not in blocked:
                dest_slot.text = slot.text
                write_owner = True
                items.append(new_item("NOT_TRANSFERRED", tag))
            else:
                items.append(new_item("CONFLICT", tag + " — existing assignment or form differs"))
        writes[plan["relative"]] = {"xml": dest, "before": before, "write_owner": write_owner}
        plan.update(status="PACKAGE_PARTIAL", items=items or [new_item("TRANSFERRED", f"own {label}")],
                    files=writes, predefined_pending=predefined_rel in writes)
        matches.append(plan)
    if len(matches) == 1 and not uncertain:
        return matches[0]
    if matches or uncertain:
        return {"status": "MANUAL", "reason": "check matching objects: " + ", ".join([p["target"] for p in matches] + uncertain)}
    choice = get_new_structured_target(entry, targets, prefix)
    if choice.get("status"):
        return choice
    target = choice["target"]
    plan = root_metadata_projection(entry, cfg, source, files, target, prefix, skd=skd)
    if not plan.get("status"):
        item = new_item("NOT_TRANSFERRED", f"own {label} {entry['name']} (as {target})")
        if stored:
            data = {"Catalog": "catalog and tabular-section records", "ChartOfCharacteristicTypes": "characteristic kinds and data",
                    "ChartOfAccounts": "accounts, subaccounts and balances",
                    "ChartOfCalculationTypes": "calculation types and their data",
                    "ExchangePlan": "exchange nodes and exchange state", "BusinessProcess": "business process instances",
                    "Task": "tasks and task execution state",
                    "Document": "documents, tabular sections and register movements"}.get(kind, "register records")
            item["stored"] = f"{entry['id']} -> {kind}.{target} — {data}"
            if plan.get("has_predefined"):
                item["stored"] += " (includes predefined data)"
        plan.update(status="NOT_TRANSFERRED", items=[item], new=True)
    return plan


def get_enum_transfer_plan(entry, ext_dir, prefix, cfg):
    children = cfg["child_objects"]
    if children is None:
        return {"status": "MANUAL", "reason": "configuration has no ChildObjects"}
    base = os.path.join(ext_dir, "Enums", entry["name"])
    source = read_form_write(base + ".xml")
    if source["root"].get("version") != children.getroottree().getroot().get("version"):
        return {"status": "MANUAL", "reason": "metadata dump formats differ"}
    node = get_md_object_element(source["root"])
    if not node.get("uuid") or node.xpath("md:ChildObjects/*[not(self::md:EnumValue)]", namespaces=MD_NSMAP):
        return {"status": "MANUAL", "reason": "unsupported enumeration descriptor or children"}
    files = {}
    for folder, _, filenames in os.walk(base):
        for filename in filenames:
            path = os.path.join(folder, filename)
            rel = os.path.relpath(path, base).replace(os.sep, "/")
            if rel != "Ext/ManagerModule.bsl":
                return {"status": "MANUAL", "reason": f"unsupported enumeration file {rel}"}
            files[rel] = path
    identity = metadata_transfer_uuid(cfg, "Enum", node.get("uuid"))
    registry = [(localname(n), inner_text(n)) for n in elem_children(children)]
    ids = [(kind, name) for kind, name in registry if kind in CHILD_TYPE_DIR_MAP
           and _sg_root_uuid(os.path.join(MD_REFERENCE_ROOT, CHILD_TYPE_DIR_MAP[kind], name + ".xml")) == identity]
    if len(ids) > 1 or (ids and ids[0][0] != "Enum"):
        return {"status": "CONFLICT", "reason": f"enumeration UUID {identity} collides in configuration"}
    pool = [name for kind, name in registry if kind == "Enum"]
    candidates = [ids[0][1]] if ids else find_names_in(pool, entry["name"], prefix)
    matches, uncertain = [], []
    for name in candidates:
        relative = f"Enums/{name}.xml"
        path = os.path.join(MD_REFERENCE_ROOT, relative)
        if not os.path.isfile(path):
            return {"status": "CONFLICT", "reason": "missing descriptor " + relative}
        with open(path, "rb") as original:
            before = original.read()
        dest = read_form_write(path)
        b = get_md_object_element(dest["root"])
        container = b.find("md:ChildObjects", MD_NSMAP)
        if container is None:
            container = etree.Element(f"{{{MD_NS}}}ChildObjects")
            insert_form_node_at(b, container, None, dest["eol"])
        dest_values = container.findall("md:EnumValue", MD_NSMAP)
        aliases = {}
        if ids:
            for value_name, value_id in entry["value_ids"].items():
                by_id = [v for v in dest_values if v.get("uuid") == value_id]
                if len(by_id) > 1:
                    return {"status": "CONFLICT", "reason": f"duplicate UUID of enumeration value {value_name}"}
                if by_id:
                    aliases[value_name] = md_child_name(by_id[0])
        plan = root_metadata_projection(entry, cfg, source, files, name, prefix, aliases)
        if plan.get("status"):
            return plan
        a = get_md_object_element(plan["files"][plan["relative"]]["xml"]["root"])
        props = catalog_node_key(a, shallow=True) == catalog_node_key(b, shallow=True)
        src = a.findall("md:ChildObjects/md:EnumValue", MD_NSMAP)
        src_names = [md_child_name(v).lower() for v in src]
        dst = {md_child_name(v).lower(): v for v in dest_values}
        if len(src_names) != len(set(src_names)) or len(dst) != len(dest_values):
            return {"status": "CONFLICT", "reason": "duplicate enumeration value names"}
        common = [n for n in src_names if n in dst]
        ordered = common == [n for n in dst if n in src_names]
        module = f"Enums/{name}/Ext/ManagerModule.bsl"
        module_path = os.path.join(MD_REFERENCE_ROOT, module)
        module_exists = os.path.lexists(module_path)
        same_module = (module_exists and catalog_file_equal(plan["files"][module], module_path)
                       if module in plan["files"] else not module_exists)
        full = same_module and catalog_node_key(a) == catalog_node_key(b)
        if not ids and not full:
            if props or common:
                uncertain.append(name)
            continue
        items = []
        if not props:
            items.append(new_item("CONFLICT", "enumeration properties differ"))
        if not ordered:
            items.append(new_item("CONFLICT", "enumeration value order differs"))
        write = False
        for i, value in enumerate(src):
            value_name = md_child_name(value)
            key = src_names[i]
            if key in dst:
                status = "TRANSFERRED" if catalog_node_key(value) == catalog_node_key(dst[key]) else "CONFLICT"
                items.append(new_item(status, f"enumeration value {value_name}"))
            elif ordered:
                anchor = next((dst[n] for n in src_names[i+1:] if n in dst), None)
                if anchor is None:
                    anchor = find_child_anchor(container, "EnumValue", "Enum")
                insert_form_node_at(container, copy.deepcopy(value), anchor, dest["eol"])
                item = new_item("NOT_TRANSFERRED", f"enumeration value {value_name}")
                item["stored"] = f"Enum.{entry['name']}.EnumValue.{value_name} -> Enum.{name}.EnumValue.{value_name} — stored references"
                items.append(item)
                write = True
        writes = {plan["relative"]: {"xml": dest, "before": before, "write_owner": write}}
        if module in plan["files"] and not same_module:
            if module_exists:
                items.append(new_item("CONFLICT", "existing manager module differs"))
            elif not ordered:
                items.append(new_item("WAITING", "manager module — waiting for enumeration value order to be resolved"))
            else:
                writes[module] = plan["files"][module]
                items.append(new_item("NOT_TRANSFERRED", "manager module"))
        plan.update(status="PACKAGE_PARTIAL", items=items or [new_item("TRANSFERRED", "own enumeration")], files=writes)
        matches.append(plan)
    if len(matches) == 1 and not uncertain:
        return matches[0]
    if matches or uncertain:
        return {"status": "MANUAL", "reason": "check matching enumerations: " + ", ".join([p["target"] for p in matches] + uncertain)}
    taken = {name.lower() for name in pool}
    directory = os.path.join(MD_REFERENCE_ROOT, "Enums")
    if os.path.isdir(directory):
        for file in os.scandir(directory):
            if file.is_dir():
                taken.add(file.name.lower())
            elif file.name.lower().endswith(".xml"):
                taken.add(file.name[:-4].lower())
                if _sg_root_uuid(file.path) == identity:
                    return {"status": "CONFLICT", "reason": f"enumeration UUID {identity} exists in an unregistered descriptor"}
    settings = SETTINGS[get_object_kind(entry["name"], "own")]
    choice = get_target_name(entry["name"], prefix, taken, settings["add_dev_objects"])
    if choice.get("taken"):
        return {"status": "CONFLICT", "reason": f"name taken in configuration ({choice['note']})"}
    target = choice["name"]
    plan = root_metadata_projection(entry, cfg, source, files, target, prefix)
    if not plan.get("status"):
        item = new_item("NOT_TRANSFERRED", f"own enumeration {entry['name']} (as {target})")
        item["stored"] = f"Enum.{entry['name']} -> Enum.{target} — stored references to enumeration values"
        plan.update(status="NOT_TRANSFERRED", items=[item], new=True)
    return plan


def flat_metadata_equal(source, target):
    a, b = copy.deepcopy(source), copy.deepcopy(target)
    if localname(source) == "Bot":
        for obj in (a, b):
            for picture in obj.xpath("md:Properties/md:Picture[not(*) and not(@*) and not(normalize-space())]", namespaces=MD_NSMAP):
                picture.getparent().remove(picture)
    path = "md:Properties/md:Source" if localname(source) == "EventSubscription" else "md:Properties/md:Type"
    x, y = a.find(path, MD_NSMAP), b.find(path, MD_NSMAP)
    if (x is None) != (y is None):
        return False
    if x is not None:
        if not test_md_type_model_equal(get_md_type_model(x, ""), get_md_type_model(y, "")):
            return False
        x.getparent().remove(x)
        y.getparent().remove(y)
    return catalog_node_key(a) == catalog_node_key(b)


def get_flat_transfer_plan(entry, ext_dir, prefix, cfg):
    children = cfg["child_objects"]
    if children is None:
        return {"status": "MANUAL", "reason": "configuration has no ChildObjects"}
    kind, source_name = entry["type"], entry["name"]
    directory = CHILD_TYPE_DIR_MAP[kind]
    base = os.path.join(ext_dir, directory, source_name)
    source = read_form_write(base + ".xml")
    if source["root"].get("version") != children.getroottree().getroot().get("version"):
        return {"status": "MANUAL", "reason": "metadata dump formats differ"}
    node = get_md_object_element(source["root"])
    extra_package = kind in EXTRA_PACKAGE_KINDS
    if kind == "PaletteColor" and format_rank(source["root"].get("version")) < 221:
        return {"status": "MANUAL", "reason": "palette colors require dump format 2.21 or newer"}
    if (localname(node) != kind or not node.get("uuid")
            or (not extra_package and node.find("md:ChildObjects/*", MD_NSMAP) is not None)):
        return {"status": "MANUAL", "reason": f"unsupported {kind} descriptor or children"}
    skd = set()
    if extra_package:
        files, skd = catalog_files(source["root"], base, extra_package=True)
    else:
        allowed = {
            "Constant": {"Ext/ManagerModule.bsl", "Ext/ValueManagerModule.bsl"},
            "Role": {"Ext/Rights.xml"},
            "ScheduledJob": {"Ext/Schedule.xml"},
        }.get(kind, ())
        files = {}
        for folder, _, names in os.walk(base):
            for name in names:
                path = os.path.join(folder, name)
                rel = os.path.relpath(path, base).replace(os.sep, "/")
                if rel not in allowed and not (kind == "CommonPicture" and re.fullmatch(r"Ext/Picture(?:\.xml|/Picture\.[A-Za-z0-9]+)", rel)):
                    return {"status": "MANUAL", "reason": f"unsupported {kind} file {rel}"}
                files[rel] = path
        if kind == "Role" and "Ext/Rights.xml" not in files:
            return {"status": "MANUAL", "reason": "missing Ext/Rights.xml"}
    identity = metadata_transfer_uuid(cfg, kind, node.get("uuid"))
    registry = [(localname(n), inner_text(n)) for n in elem_children(children)]
    ids = [(tag, name) for tag, name in registry if tag in CHILD_TYPE_DIR_MAP
           and _sg_root_uuid(os.path.join(MD_REFERENCE_ROOT, CHILD_TYPE_DIR_MAP[tag], name + ".xml")) == identity]
    if len(ids) > 1 or (ids and ids[0][0] != kind):
        return {"status": "CONFLICT", "reason": f"{kind} UUID {identity} collides in configuration"}
    pool = [name for tag, name in registry if tag == kind]
    candidates = [ids[0][1]] if ids else find_names_in(pool, source_name, prefix)
    matches, uncertain = [], []
    for name in candidates:
        relative = f"{directory}/{name}.xml"
        path = os.path.join(MD_REFERENCE_ROOT, relative)
        if not os.path.isfile(path):
            return {"status": "CONFLICT", "reason": "missing descriptor " + relative}
        with open(path, "rb") as original:
            before = original.read()
        dest = read_form_write(path)
        plan = root_metadata_projection(entry, cfg, source, files, name, prefix, skd=skd)
        if plan.get("status"):
            return plan
        same = flat_metadata_equal(get_md_object_element(plan["files"][relative]["xml"]["root"]),
                                   get_md_object_element(dest["root"]))
        writes, different = {}, []
        folder = os.path.splitext(path)[0]
        for parent, _, names in os.walk(folder):
            for filename in names:
                existing = os.path.join(parent, filename)
                rel = os.path.relpath(existing, MD_REFERENCE_ROOT).replace(os.sep, "/")
                if rel not in plan["files"] or not catalog_file_equal(plan["files"][rel], existing):
                    different.append(rel)
        for rel, info in sorted(plan["files"].items()):
            if rel == relative:
                continue
            path = os.path.join(MD_REFERENCE_ROOT, rel)
            if not os.path.lexists(path):
                if kind == "CommonForm" and rel.endswith("/Ext/Form/Module.bsl") and not "".join(info["lines"]).strip():
                    continue
                writes[rel] = info
            elif not os.path.isfile(path):
                different.append(rel)
        if ids and (not same or different):
            reason = f"{kind} descriptor differs" if not same else "existing files differ: " + ", ".join(different)
            return {"status": "CONFLICT", "target": name, "reason": reason}
        if not same:
            continue
        if not ids and (different or writes):
            uncertain.append(name)
            continue
        if writes:
            items = [new_item("NOT_TRANSFERRED", rel) for rel in writes]
            writes[relative] = {"xml": dest, "before": before, "write_owner": False}
            plan.update(status="PACKAGE_PARTIAL", files=writes, items=items)
        else:
            plan["status"] = "TRANSFERRED"
        matches.append(plan)
    if len(matches) == 1 and not uncertain:
        return matches[0]
    if matches or uncertain:
        return {"status": "MANUAL", "reason": "check matching objects: " + ", ".join([p["target"] for p in matches] + uncertain)}
    taken = {name.lower() for name in pool}
    dest_dir = os.path.join(MD_REFERENCE_ROOT, directory)
    if os.path.isdir(dest_dir):
        for file in os.scandir(dest_dir):
            if file.is_dir():
                taken.add(file.name.lower())
            elif file.name.lower().endswith(".xml"):
                taken.add(file.name[:-4].lower())
                if _sg_root_uuid(file.path) == identity:
                    return {"status": "CONFLICT", "reason": f"{kind} UUID {identity} exists in an unregistered descriptor"}
    settings = SETTINGS[get_object_kind(source_name, "own")]
    choice = get_target_name(source_name, prefix, taken, settings["add_dev_objects"])
    if choice.get("taken"):
        return {"status": "CONFLICT", "reason": f"name taken in configuration ({choice['note']})"}
    target = choice["name"]
    plan = root_metadata_projection(entry, cfg, source, files, target, prefix, skd=skd)
    if not plan.get("status"):
        item = new_item("NOT_TRANSFERRED", f"own {kind} {source_name} (as {target})")
        if kind == "Constant":
            item["stored"] = f"Constant.{source_name} -> Constant.{target} — stored constant value"
        if kind == "DocumentNumerator":
            item["stored"] = f"{entry['id']} -> {kind}.{target} — numbering continuity"
        if kind in ("CommonAttribute", "SettingsStorage", "Sequence"):
            item["stored"] = f"{entry['id']} -> {kind}.{target} — migrate stored data before removing the extension"
        plan.update(status="NOT_TRANSFERRED", items=[item], new=True)
    return plan


def add_register_registrar_check(entry, plan, cfg):
    global ROOT_TARGET_REGISTRARS
    if plan["status"] not in ("NOT_TRANSFERRED", "PACKAGE_PARTIAL"):
        return plan
    owner = get_md_object_element(plan["files"][plan["relative"]]["xml"]["root"])
    if (entry["type"] == "InformationRegister"
            and owner.findtext("md:Properties/md:WriteMode", namespaces=MD_NSMAP) != "RecorderSubordinate"):
        return plan
    target = f"{entry['type']}.{plan['target']}"
    if ROOT_TARGET_REGISTRARS is None:
        ROOT_TARGET_REGISTRARS = {}
        for doc in cfg["child_objects"].findall("md:Document", MD_NSMAP):
            rel = f"Documents/{inner_text(doc)}.xml"
            md = read_md_object(os.path.join(MD_REFERENCE_ROOT, rel))
            if md:
                for ref in md["props"].findall("md:RegisterRecords/*", MD_NSMAP):
                    ROOT_TARGET_REGISTRARS.setdefault(inner_text(ref).strip().lower(), []).append(rel)
    if target.lower() in ROOT_TARGET_REGISTRARS:
        plan["validation_files"] = ROOT_TARGET_REGISTRARS[target.lower()][:1]
        return plan
    registrars = ROOT_REGISTRARS.get(entry["key"], {})
    if any(key in ROOT_PROVISIONAL for key in registrars):
        return plan
    pending = sorted(key for key in registrars if key in ROOT_OWN and key not in ROOT_BINDINGS)
    if pending:
        dependency = next((key for key in pending if ROOT_OWN[key]["selected"]), pending[0])
        return {"status": "WAITING", "reason": f"waiting for {registrars[dependency]} to register movements in {entry['id']}",
                "dependency": dependency}
    if registrars:
        return {"status": "WAITING", "reason": f"{target} needs a registrar: add it to RegisterRecords of "
                                                + ", ".join(registrars[key] for key in sorted(registrars))}
    return {"status": "MANUAL", "reason": f"{target} has no registrar document; configure RegisterRecords"}


def get_root_object_plan(entry, ext_dir, prefix, cfg):
    if entry["type"] in STRUCTURED_TRANSFER_KINDS:
        plan = get_structured_transfer_plan(entry, ext_dir, prefix, cfg)
        return add_register_registrar_check(entry, plan, cfg) if entry["type"] in REGISTER_TRANSFER_KINDS else plan
    if entry["type"] == "Enum":
        return get_enum_transfer_plan(entry, ext_dir, prefix, cfg)
    if entry["type"] in FLAT_TRANSFER_KINDS:
        return get_flat_transfer_plan(entry, ext_dir, prefix, cfg)
    oid, kind, name = entry["id"], entry["type"], entry["name"]
    src = root_object_paths(kind, name)
    src_bsl = os.path.normpath(os.path.join(ext_dir, src["bsl"]))
    if cfg["child_objects"] is None:
        return {"status": "MANUAL", "reason": "configuration has no ChildObjects"}
    src_xml = os.path.join(ext_dir, src["xml"])
    fw = read_form_write(src_xml)
    if fw["root"].get("version") != cfg["child_objects"].getroottree().getroot().get("version"):
        return {"status": "MANUAL", "reason": "metadata dump formats differ"}
    for folder, _, files in os.walk(os.path.join(ext_dir, src["dir"])):
        for filename in files:
            if os.path.normpath(os.path.join(folder, filename)).lower() != src_bsl.lower():
                return {"status": "MANUAL", "reason": "unsupported object file " + filename}
    if not os.path.isfile(src_bsl):
        return {"status": "MANUAL", "reason": "missing module " + src["bsl"]}
    bsl = read_bsl_file(src_bsl)
    source_uuid = get_md_object_element(fw["root"]).get("uuid")
    pool = MD_REFERENCE_POOLS.get(kind, ())
    matches, uncertain = [], []
    for candidate in find_names_in(pool, name, prefix):
        paths = root_object_paths(kind, candidate)
        dst = read_md_object(os.path.join(MD_REFERENCE_ROOT, paths["xml"]))
        dst_path = os.path.join(MD_REFERENCE_ROOT, paths["bsl"])
        if not dst or not os.path.isfile(dst_path):
            uncertain.append(candidate)
            continue
        xml = get_root_object_xml(read_form_write(src_xml), kind, candidate, prefix)
        if xml.get("status"):
            return xml
        projection = get_root_bsl_projection(bsl["lines"], prefix, oid, candidate)
        if projection.get("status"):
            return projection
        dst_bsl = read_bsl_file(dst_path, track_content=True)
        same_xml = node_canon(xml["props"]) == node_canon(dst["props"])
        same_bsl = root_object_code_key(projection["lines"]) == root_object_code_key(dst_bsl["lines"])
        plan = {"target": candidate, "paths": paths, "bsl": dst_bsl, "lines": projection["lines"], "status": "TRANSFERRED"}
        if same_xml and same_bsl:
            matches.append(plan)
            continue
        if kind == "CommonModule":
            comparison = compare_root_module(projection["lines"], dst_bsl["lines"])
            count = comparison["matched"]
            if same_xml and count >= 2 and count * 2 > comparison["total"]:
                plan["comparison"] = comparison
                if comparison["missing"] or comparison["different"] or comparison["temporary"] or not comparison["top"]:
                    plan["status"] = "PARTIAL"
                matches.append(plan)
                continue
            if count >= 2 or (same_xml and count):
                uncertain.append(candidate)
                continue
        if (source_uuid and source_uuid == dst["el"].get("uuid")) or (same_bsl and any(
                root_object_code_key(m["body_lines"]) for n in get_proc_names(projection["lines"])
                if (m := get_method_safe(projection["lines"], n)))):
            uncertain.append(candidate)
    if len(matches) == 1 and not uncertain:
        return matches[0]
    if matches or uncertain:
        return {"status": "MANUAL", "reason": "check matching objects: " + ", ".join([p["target"] for p in matches] + uncertain)}
    taken = {n.lower() for n in pool}
    directory = os.path.join(MD_REFERENCE_ROOT, CHILD_TYPE_DIR_MAP[kind])
    if os.path.isdir(directory):
        for p in os.scandir(directory):
            if p.is_dir():
                taken.add(p.name.lower())
            elif p.name.lower().endswith(".xml"):
                taken.add(p.name[:-4].lower())
    choice = get_target_name(name, prefix, taken, SETTINGS[get_object_kind(name, "own")]["add_dev_objects"])
    if choice.get("taken"):
        return {"status": "CONFLICT", "reason": "name taken in configuration (%s)" % choice["note"]}
    target = choice["name"]
    xml = get_root_object_xml(fw, kind, target, prefix)
    if xml.get("status"):
        return xml
    projection = get_root_bsl_projection(bsl["lines"], prefix, oid, target)
    if projection.get("status"):
        return projection
    return {"status": "NOT_TRANSFERRED", "target": target, "paths": root_object_paths(kind, target),
            "fw": fw, "bsl": bsl, "lines": projection["lines"]}


CONFIG_CHILD_ORDER = (
    "Language Subsystem StyleItem Style CommonPicture SessionParameter Role CommonTemplate FilterCriterion CommonModule "
    "CommonAttribute ExchangePlan XDTOPackage WebService HTTPService WSReference EventSubscription ScheduledJob "
    "SettingsStorage FunctionalOption FunctionalOptionsParameter DefinedType Bot PaletteColor CommonCommand CommandGroup "
    "Constant CommonForm Catalog Document DocumentNumerator Sequence DocumentJournal Enum Report DataProcessor "
    "InformationRegister AccumulationRegister ChartOfCharacteristicTypes ChartOfAccounts AccountingRegister "
    "ChartOfCalculationTypes CalculationRegister BusinessProcess Task ExternalDataSource IntegrationService"
).split()


def get_new_object_position(cfg_dir):
    """Куда навык ставит новую запись в <ChildObjects> — настройка newObjectPosition.

    databases[].newObjectPosition базы, чей configSrc охватывает каталог родительского XML,
    иначе корневое поле, иначе end. Значения: end — после последнего объекта того же вида
    (так дописывает Конфигуратор); byName — по имени среди объектов того же вида.
    Файл ищем от рабочего каталога вверх, каталог конфигурации — запасной путь: так же
    его ищут support-guard и группа db-*, а скрипт навыка зовут по абсолютному пути, и cwd
    остаётся рабочим каталогом проекта.
    configSrc считается от каталога .v8-project.json, как задокументировано в
    docs/v8-project-guide.md. Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    try:
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(os.path.abspath(cfg_dir or "."))
        if not pj:
            return "end"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        proj_dir = os.path.dirname(pj)
        # Пути — настоящие (realpath): на macOS /var — ссылка на /private/var
        cfg_full = os.path.normcase(os.path.realpath(cfg_dir or ".")).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src and db.get("newObjectPosition"):
                src_full = os.path.normcase(os.path.realpath(os.path.join(proj_dir, src))).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    return "byName" if str(db["newObjectPosition"]).lower() == "byname" else "end"
        if str(proj.get("newObjectPosition") or "").lower() == "byname":
            return "byName"
        return "end"
    except Exception:
        return "end"

def is_order_sensitive_type(type_name):
    """Виды, у которых порядок в дереве несёт смысл: автоматически их не упорядочиваем.

    CommonAttribute — исключение самого стандарта (#std467): у общих реквизитов-разделителей
    порядок в дереве задаёт порядок установки параметров сеанса. Subsystem и CommandGroup:
    пока они не перечислены в <SubsystemsOrder> / <GroupsOrder> файла Ext/CommandInterface.xml,
    порядок дерева задаёт порядок в интерфейсе, а платформа эти списки сама не заводит
    (в выгрузке ACC вне GroupsOrder 15 живых групп из 39). Language исключён из осторожности,
    без замера: языков обычно один-два, и в типовых их порядок не алфавитный.
    Явно названный вид сортируется в любом случае.
    Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    return type_name in ("CommonAttribute", "Subsystem", "CommandGroup", "Language")

def compare_metadata_names(a, b):
    """Порядок имён объектов метаданных, как в дереве Конфигуратора.

    Ключ — пары «ранг+символ»: регистр не учитывается, подчёркивание раньше цифр, цифры раньше
    букв, буквы по кодам (латиница раньше кириллицы), ё на месте е. Культурные таблицы не
    используются — они разные на разных ОС и в разных рантаймах, а так оба порта сравнивают
    одинаково везде. Равные ключи разводит ordinal-сравнение исходных строк.
    Возвращает -1 | 0 | 1. Реестр семьи: tests/skills/check-inline-drift.mjs.
    """
    keys = []
    for name in (a, b):
        parts = []
        for ch in name.lower():
            if ch == "ё":
                ch = "е"
            if ch.isdigit():
                parts.append("1" + ch)
            elif ch.isalpha():
                parts.append("2" + ch)
            else:
                parts.append("0" + ch)
        keys.append("".join(parts))
    if keys[0] != keys[1]:
        return -1 if keys[0] < keys[1] else 1
    if a != b:
        return -1 if a < b else 1
    return 0

def add_root_object_registration(fw, kind, name):
    children = fw["root"].find("md:Configuration/md:ChildObjects", MD_NSMAP)
    if children is None or any(inner_text(x).lower() == name.lower() for x in children.findall("md:" + kind, MD_NSMAP)):
        raise ValueError("configuration registration changed since planning")
    later = set(CONFIG_CHILD_ORDER[CONFIG_CHILD_ORDER.index(kind) + 1:])
    before = next((x for x in elem_children(children) if localname(x) in later), None)
    if not is_order_sensitive_type(kind) and get_new_object_position(MD_REFERENCE_ROOT) == "byName":
        before = next((x for x in children.findall("md:" + kind, MD_NSMAP)
                       if compare_metadata_names(inner_text(x), name) > 0), before)
    node = etree.Element("{%s}%s" % (MD_NS, kind))
    node.text = name
    insert_form_node_at(children, node, before, fw["eol"])


def replace_metadata_file(source, target, backup=None, expected=None):
    retry_delay = (0.025, 0.05, 0.1, 0.2, 0.4)
    for attempt in range(len(retry_delay) + 1):
        try:
            if expected is not None:
                with open(target, "rb") as original:
                    if original.read() != expected:
                        raise ValueError(f"{target} changed during transfer")
            replace_form_file(source, target, backup)
            return
        except OSError as exc:
            # Windows leaves both filenames intact on these sharing and removal errors.
            if attempt == len(retry_delay) or getattr(exc, "winerror", None) not in (32, 33, 1175):
                raise
            time.sleep(retry_delay[attempt])


def write_metadata_package(entry=None, plan=None, *, packages=None, expected_registry=None):
    packages = packages or [(entry, plan)]
    root = os.path.abspath(MD_REFERENCE_ROOT)
    stage = os.path.join(root, ".cfe-catalog-" + uuid.uuid4().hex)
    lock_path = os.path.join(root, ".cfe-transfer-registration.lock")
    cfg_path = os.path.join(root, "Configuration.xml")
    staged_cfg = os.path.join(stage, "Configuration.xml")
    installed, made_dirs, replaced = [], [], []
    lock = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    published = stage_created = False
    try:
        os.mkdir(stage)
        stage_created = True
        with open(cfg_path, "rb") as original:
            cfg_before = original.read()
        if expected_registry is not None and cfg_before != expected_registry:
            raise ValueError("Configuration.xml changed during planning")
        cfg = read_form_write(cfg_path)
        files, claimed, register = {}, set(), False
        for entry, plan in packages:
            if plan.get("new"):
                add_root_object_registration(cfg, entry["type"], plan["target"])
                register = True
            for rel, file in plan["files"].items():
                if rel.lower() in claimed:
                    raise ValueError(f"multiple objects claim {rel}")
                claimed.add(rel.lower())
                files[rel] = file
        save_form_write(cfg, staged_cfg)
        for rel, file in sorted(files.items()):
            path = os.path.join(stage, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if "xml" in file:
                save_form_write(file["xml"], path)
            elif "bsl" in file:
                write_bsl_file(file["bsl"], file["lines"], path)
            else:
                shutil.copyfile(file["copy"], path)
        for rel in dict.fromkeys(rel for _, plan in packages for rel in plan.get("validation_files", ())):
            path = os.path.join(stage, rel)
            if os.path.isfile(path):
                continue
            os.makedirs(os.path.dirname(path), exist_ok=True)
            shutil.copyfile(os.path.join(root, rel), path)
        for entry, plan in packages:
            validate_staged_metadata_owner(root, stage, entry, plan)
        for rel in sorted(files):
            if re.search(r"/Ext/(?:Form\.xml|Form/Module\.bsl)$", rel):
                form_rel = re.sub(r"/Form/Module\.bsl$", "/Form.xml", rel)
                form = os.path.join(stage, form_rel)
                module_rel = re.sub(r"/Form\.xml$", "/Form/Module.bsl", form_rel)
                module = os.path.join(stage, module_rel)
                if not os.path.isfile(module):
                    module = os.path.join(root, module_rel)
                    if not os.path.isfile(module):
                        module = None
                if not os.path.isfile(form):
                    form = os.path.join(root, form_rel)
                errors = get_form_validate_errors(form, module_path=module)
                if globals().get("FORM_VALIDATE_MISSING"):
                    raise ValueError("form validator is not installed")
                if errors:
                    raise ValueError("validator: " + errors[0])
            elif re.fullmatch(r"XDTOPackages/\w+/Ext/Package\.bin", rel):
                validator = os.path.join(os.path.dirname(__file__), "../../xdto-validate/scripts/xdto-validate.py")
                result = subprocess.run([sys.executable, validator, "-PackagePath", os.path.join(stage, rel), "-ConfigDir", stage],
                                        capture_output=True, text=True, encoding="utf-8", errors="replace")
                if result.returncode:
                    raise ValueError("xdto-validate failed: " + " ".join((result.stdout + result.stderr).splitlines()))
            elif rel.endswith("/Ext/Template.xml"):
                skill = "skd-validate" if files[rel].get("skd") else "mxl-validate"
                validator = os.path.join(os.path.dirname(__file__), f"../../{skill}/scripts/{skill}.py")
                result = subprocess.run([sys.executable, validator, "-TemplatePath", os.path.join(stage, rel)],
                                        capture_output=True, text=True, encoding="utf-8", errors="replace")
                if result.returncode:
                    raise ValueError(f"{skill} failed: " + " ".join((result.stdout + result.stderr).splitlines()))
        with open(cfg_path, "rb") as original:
            if original.read() != cfg_before:
                raise ValueError("Configuration.xml changed during transfer")
        for rel, file in sorted(files.items()):
            if file.get("before") is not None:
                with open(os.path.join(root, rel), "rb") as original:
                    if original.read() != file["before"]:
                        raise ValueError(f"{rel} changed during transfer")
        for rel, file in sorted(files.items()):
            if file.get("before") is not None:
                continue
            dest = os.path.join(root, rel)
            missing = []
            folder = os.path.dirname(dest)
            while not os.path.isdir(folder):
                missing.append(folder)
                folder = os.path.dirname(folder)
            for folder in reversed(missing):
                os.mkdir(folder)
                made_dirs.append(folder)
            os.link(os.path.join(stage, rel), dest)
            installed.append(dest)
        for rel, file in sorted(files.items()):
            if file.get("before") is None or not file.get("write_owner"):
                continue
            owner = os.path.join(root, rel)
            with open(owner, "rb") as original:
                if original.read() != file["before"]:
                    raise ValueError(f"{rel} changed during transfer")
            backup = os.path.join(stage, f"owner-before-{len(replaced)}.xml")
            replace_metadata_file(os.path.join(stage, rel), owner, backup, file["before"])
            replaced.append((owner, backup))
        with open(cfg_path, "rb") as original:
            if original.read() != cfg_before:
                raise ValueError("Configuration.xml changed during transfer")
        if register:
            replace_metadata_file(staged_cfg, cfg_path, expected=cfg_before)
        published = True
    finally:
        try:
            if not published:
                for owner, backup in reversed(replaced):
                    replace_metadata_file(backup, owner)
                for path in installed:
                    os.unlink(path)
                for folder in reversed(made_dirs):
                    if not os.listdir(folder):
                        os.rmdir(folder)
            if stage_created and os.path.dirname(stage) == root and not os.path.islink(stage):
                shutil.rmtree(stage)
        finally:
            os.close(lock)
            os.unlink(lock_path)
    return installed + [owner for owner, _ in replaced] + ([cfg_path] if register else [])


def validate_staged_metadata_owner(root, stage, entry, plan):
    owner = os.path.join(root, plan["relative"])
    staged_owner = os.path.join(stage, plan["relative"])
    check = read_md_object(staged_owner)
    if not check or localname(check["el"]) != entry["type"] or md_child_name(check["el"]) != plan["target"]:
        raise ValueError("staged metadata object did not pass read-back validation")
    if entry["type"] in REGISTER_TRANSFER_KINDS and (entry["type"] != "InformationRegister"
            or check["props"].findtext("md:WriteMode", namespaces=MD_NSMAP) == "RecorderSubordinate"):
        target = f"{entry['type']}.{plan['target']}"
        documents = os.path.join(stage, "Documents")
        registrar_found = False
        if os.path.isdir(documents):
            for file in os.scandir(documents):
                if not file.is_file() or not file.name.lower().endswith(".xml"):
                    continue
                md = read_md_object(file.path)
                if md and any(inner_text(ref).strip().lower() == target.lower()
                              for ref in md["props"].findall("md:RegisterRecords/*", MD_NSMAP)):
                    registrar_found = True
                    break
        if not registrar_found:
            raise ValueError(f"validator: no staged registrar links to {target}")
    if not plan.get("new") and entry["type"] in STRUCTURED_TRANSFER_KINDS + EXTRA_PACKAGE_KINDS + ("Enum",):
        # Preserve the validation context for slots pointing at existing local forms.
        for slot in elem_children(check["props"]):
            if not re.fullmatch(r"(Default|Auxiliary).*Form", localname(slot)):
                continue
            match = re.fullmatch(r"(\w+)\.(\w+)\.Form\.(\w+)", inner_text(slot), re.I)
            if not match or match[1].lower() != entry["type"].lower() or match[2].lower() != plan["target"].lower():
                continue
            base = f"{CHILD_TYPE_DIR_MAP[entry['type']]}/{plan['target']}/Forms/{match[3]}"
            for rel in (base + ".xml", base + "/Form.xml", base + "/Ext/Form.xml"):
                original, candidate = os.path.join(root, rel), os.path.join(stage, rel)
                if os.path.isfile(original) and not os.path.exists(candidate):
                    os.makedirs(os.path.dirname(candidate), exist_ok=True)
                    shutil.copyfile(original, candidate)
    errors = get_md_validate_errors(staged_owner, entry["type"], require_result=True)
    if not plan.get("new"):
        baseline = get_md_validate_errors(owner, entry["type"], require_result=True)
        errors = [error for error in errors if error.startswith("metadata validator") or error not in baseline]
    if errors:
        raise ValueError("validator: " + errors[0])


def write_root_object(entry, plan):
    cfg_path = os.path.join(MD_REFERENCE_ROOT, "Configuration.xml")
    xml_path, bsl_path = (os.path.join(MD_REFERENCE_ROOT, plan["paths"][key]) for key in ("xml", "bsl"))
    suffix = ".cfe-root-" + uuid.uuid4().hex
    cfg_temp, xml_temp, bsl_temp = (os.path.join(MD_REFERENCE_ROOT, suffix + extension)
                                     for extension in ("-config.xml", "-object.xml", "-module.bsl"))
    installed, made_dirs = [], []
    lock_path = os.path.join(MD_REFERENCE_ROOT, ".cfe-transfer-registration.lock")
    lock = None
    try:
        lock = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        if not os.stat(cfg_path).st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise PermissionError("Configuration.xml is read-only")
        if os.path.lexists(os.path.join(MD_REFERENCE_ROOT, plan["paths"]["dir"])):
            raise FileExistsError("object directory already exists: " + plan["paths"]["dir"])
        with open(cfg_path, "rb") as original:
            before = original.read()
        cfg = read_form_write(cfg_path)
        add_root_object_registration(cfg, entry["type"], plan["target"])
        get_md_object_element(plan["fw"]["root"]).set("uuid", str(uuid.uuid4()))
        save_form_write(cfg, cfg_temp)
        save_form_write(plan["fw"], xml_temp)
        write_bsl_file(plan["bsl"], plan["lines"], bsl_temp)
        check = read_md_object(xml_temp)
        registered = read_xml(cfg_temp).findall("md:Configuration/md:ChildObjects/md:" + entry["type"], MD_NSMAP)
        if (not check or localname(check["el"]) != entry["type"] or md_child_name(check["el"]) != plan["target"]
                or sum(inner_text(x) == plan["target"] for x in registered) != 1
                or root_object_code_key(read_bsl_lines(bsl_temp)) != root_object_code_key(plan["lines"])):
            raise ValueError("staged object did not pass read-back validation")
        errors = get_md_validate_errors(xml_temp, entry["type"], require_result=True)
        if errors:
            raise ValueError("validator: " + errors[0])
        folder = os.path.dirname(bsl_path)
        missing = []
        while not os.path.isdir(folder):
            missing.append(folder)
            folder = os.path.dirname(folder)
        for folder in reversed(missing):
            os.mkdir(folder)
            made_dirs.append(folder)
        # Link creates the destination without overwriting a file that appeared since planning.
        for source, target in ((xml_temp, xml_path), (bsl_temp, bsl_path)):
            os.link(source, target)
            installed.append(target)
        with open(cfg_path, "rb") as current:
            if current.read() != before:
                raise ValueError("Configuration.xml changed during transfer")
        replace_metadata_file(cfg_temp, cfg_path, expected=before)
    except Exception:
        for path in installed:
            os.unlink(path)
        for folder in reversed(made_dirs):
            if not os.listdir(folder):
                os.rmdir(folder)
        raise
    finally:
        for path in (cfg_temp, xml_temp, bsl_temp):
            if os.path.exists(path):
                os.unlink(path)
        if lock is not None:
            os.close(lock)
            os.unlink(lock_path)
    return [xml_path, bsl_path, cfg_path]


def get_root_local_calls(method, target):
    tokens = [t for t in bsl_tokens(method["body_lines"]) if t["kind"] != "comment" and t["value"].strip()]
    params = method.get("param_names", ())
    key = target.lower()
    shadowed = key in {p.lower() for p in params} or key in get_local_names(get_code_only(method["body_lines"]), params)
    for i, token in enumerate(tokens[:-1]):
        if token["kind"] != "word" or tokens[i + 1]["value"] != "(":
            continue
        if i and tokens[i - 1]["value"].lower() in ("новый", "new"):
            continue
        if i and tokens[i - 1]["value"] == "." and (shadowed or i < 2 or tokens[i - 2]["value"].lower() != key
                                                   or (i > 2 and tokens[i - 3]["value"] == ".")):
            continue
        yield token["value"]


def complete_root_module(plan, frame, apply):
    comparison = plan["comparison"]
    items, changed, inserted = [], [], []
    if comparison["matched"]:
        items.append(new_item("TRANSFERRED", "%d/%d methods already present" % (comparison["matched"], comparison["total"])))
    for name in comparison["different"]:
        items.append(new_item("CONFLICT", "method %s — declaration or body differs" % name))
    if not comparison["top"]:
        items.append(new_item("CONFLICT", "module code outside methods differs"))
    lines = list(plan["bsl"]["lines"])
    blocked = {name.lower() for name in comparison["different"]}
    items.extend(comparison["temporary"])
    blocked.update(item["text"].split()[1].lower() for item in comparison["temporary"] if item["status"] == "TEMPORARY")
    pending = []
    for name, method in comparison["missing"]:
        if not comparison["top"]:
            items.append(new_item("WAITING", "method %s — waiting for module code outside methods" % name))
            blocked.add(name.lower())
            continue
        place = resolve_method_conditions(lines, {"at": get_module_end(lines)}, method)
        if not place or method_crosses_branch(plan["lines"], method):
            items.append(new_item("MANUAL", "method %s — preprocessor condition differs" % name))
            blocked.add(name.lower())
            continue
        pending.append((name, method, list(dict.fromkeys(get_root_local_calls(method, plan["target"])))))
    while True:
        before = len(blocked)
        for name, _, calls in pending:
            if name.lower() in blocked:
                continue
            dependencies = [call for call in calls if call.lower() in blocked]
            if dependencies:
                items.append(new_item("WAITING", "method %s — waiting for %s" % (name, ", ".join(dependencies))))
                blocked.add(name.lower())
        if len(blocked) == before:
            break
    for name, method, _ in pending:
        if name.lower() in blocked:
            continue
        item = new_item("NOT_TRANSFERRED", "method " + name)
        items.append(item)
        if not apply:
            continue
        place = resolve_method_conditions(lines, {"at": get_module_end(lines)}, method)
        start = method["decl_idx"]
        if start and is_context_directive(plan["lines"][start - 1].strip()):
            start -= 1
        while start and plan["lines"][start - 1].strip().startswith("//"):
            start -= 1
        block = plan["lines"][start:method["body_end_idx"] + 1]
        if frame["begin"]:
            block.insert(0, frame["begin"])
        if frame["end"]:
            block[-1] += " " + frame["end"]
        block = join_own_method_blocks([{"lines": block, "guards": place["guards"], "guard_key": place["guard_key"], "lang": method["lang"]}])
        at = place["at"]
        lines[at:at] = get_spaced_block(lines, at, block)
        inserted.append(item)
    if inserted:
        path = plan["bsl"]["path"]
        temp = path + ".cfe-root-" + uuid.uuid4().hex + ".tmp"
        try:
            if not os.stat(path).st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                raise PermissionError("module is read-only")
            write_bsl_file(plan["bsl"], lines, temp)
            readback = compare_root_module(plan["lines"], read_bsl_lines(temp))
            invalid = {name for name, _ in readback["missing"]} | set(readback["different"])
            if any(item["text"] in {"method " + name for name in invalid} for item in inserted):
                raise ValueError("inserted methods did not pass read-back validation")
            with open(path, "rb") as current:
                if hashlib.sha256(current.read()).digest() != plan["bsl"]["digest"]:
                    raise ValueError("module changed during transfer")
            replace_form_file(temp, path)
            changed.append(path)
            for item in inserted:
                item.update(status="TRANSFERRED", now=True)
        except Exception as exc:
            for item in inserted:
                item.update(status="CONFLICT", text=item["text"] + " — " + str(exc))
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    return items, changed


def linked_reachable(start, edges):
    seen, stack = set(), [start]
    while stack:
        key = stack.pop()
        if key not in seen:
            seen.add(key)
            stack.extend(edges.get(key, ()))
    return seen


def linked_groups(edges):
    reverse, visited = {}, set()
    for key, dependencies in edges.items():
        for dependency in dependencies:
            reverse.setdefault(dependency, set()).add(key)
    for key in sorted(edges):
        if key not in visited:
            group = linked_reachable(key, edges) & linked_reachable(key, reverse)
            visited.update(group)
            if len(group) > 1:
                yield tuple(sorted(group))


def get_linked_package_plans(keys, ext, cfg):
    sources, unassigned = {}, []
    prefix = ext["prefix"]
    try:
        for key in keys:
            entry = ROOT_OWN[key]
            path = os.path.join(ext["dir"], CHILD_TYPE_DIR_MAP[entry["type"]], entry["name"] + ".xml")
            md = read_md_object(path)
            if not md or localname(md["el"]) != entry["type"] or not md["el"].get("uuid"):
                return {"id": key, "status": "MANUAL", "reason": "invalid source descriptor"}
            targets = get_structured_target_set(entry, md["el"], prefix, cfg)
            if targets.get("status"):
                return dict(targets, id=key)
            predefined_path = os.path.join(os.path.splitext(path)[0], "Ext", "Predefined.xml")
            sources[key] = md, targets, predefined_path
            if targets["candidates"]:
                ROOT_PROVISIONAL[key] = {"target": targets["candidates"][0], "md": md, "predefined_path": predefined_path}
            else:
                unassigned.append(key)
        for key in unassigned:
            md, targets, predefined_path = sources[key]
            choice = get_new_structured_target(ROOT_OWN[key], targets, prefix)
            if choice.get("status"):
                return dict(choice, id=key)
            ROOT_PROVISIONAL[key] = {"target": choice["target"], "md": md, "predefined_path": predefined_path}
        seen = set()
        while True:
            signature = tuple(ROOT_PROVISIONAL[key]["target"].lower() for key in keys)
            if signature in seen:
                return {"id": keys[0], "status": "MANUAL", "reason": "ambiguous targets for linked objects"}
            seen.add(signature)
            members, changes, blocked = [], {}, []
            for key in keys:
                entry = ROOT_OWN[key]
                plan = get_root_object_plan(entry, ext["dir"], prefix, cfg)
                if plan["status"] not in ("NOT_TRANSFERRED", "PACKAGE_PARTIAL", "TRANSFERRED"):
                    blocked.append(dict(plan, id=key))
                    continue
                if plan["status"] == "TRANSFERRED" and not plan.get("items"):
                    plan["items"] = [new_item("TRANSFERRED", f"own object (found as {plan['target']})")]
                if plan["target"].lower() != ROOT_PROVISIONAL[key]["target"].lower():
                    changes[key] = plan["target"]
                members.append((entry, plan))
            if changes:
                for key, target in changes.items():
                    ROOT_PROVISIONAL[key]["target"] = target
                continue
            if blocked:
                return blocked[0]
            claimed = set()
            for entry, plan in members:
                conflict = next((item for item in plan["items"] if item["status"] == "CONFLICT"), None)
                if conflict:
                    return {"id": entry["key"], "status": "CONFLICT", "reason": conflict["text"]}
                relative = plan["relative"].lower()
                if relative in claimed:
                    return {"id": entry["key"], "status": "MANUAL", "reason": f"multiple objects claim {plan['relative']}"}
                claimed.add(relative)
            return {"members": members}
    except Exception as exc:
        return {"id": key, "status": "MANUAL", "reason": str(exc)}
    finally:
        ROOT_PROVISIONAL.clear()


def complete_linked_root_groups(waiting, ext, cfg, apply):
    global ROOT_TARGET_REGISTRARS
    edges = {key: set() for key in waiting if ROOT_OWN[key]["type"] in
             LINKED_TRANSFER_KINDS + PREDEFINED_KINDS + EXTENDED_TRANSFER_KINDS + EXTRA_PACKAGE_KINDS}
    for key, dependencies in edges.items():
        dependency = waiting[key].get("dependency")
        if dependency in edges:
            dependencies.add(dependency)
    tried, changed = set(), []
    while True:
        keys = ()
        for group in linked_groups(edges):
            if group in tried:
                continue
            kinds = {ROOT_OWN[key]["type"] for key in group}
            if (kinds.issubset(LINKED_TRANSFER_KINDS)
                    or ("ChartOfCharacteristicTypes" in kinds and kinds.issubset(PREDEFINED_KINDS))
                    or kinds.intersection(EXTENDED_TRANSFER_KINDS + EXTRA_PACKAGE_KINDS)):
                keys = group
                break
        if not keys:
            return set(), changed
        tried.add(keys)
        with open(os.path.join(MD_REFERENCE_ROOT, "Configuration.xml"), "rb") as registry:
            expected_registry = registry.read()
        batch = get_linked_package_plans(keys, ext, cfg)
        dependency = batch.get("dependency")
        if batch.get("status") == "WAITING" and dependency in edges and dependency not in edges[batch["id"]]:
            edges[batch["id"]].add(dependency)
            tried.remove(keys)
            continue
        members, supports = batch.get("members", ()), {}
        writes = [(entry, plan) for entry, plan in members
                  if any(item["status"] == "NOT_TRANSFERRED" for item in plan["items"])]
        if apply:
            for entry, plan in writes:
                key = entry["key"]
                if not entry["selected"]:
                    batch = {"id": key, "status": "WAITING", "reason": f"{entry['id']} is excluded by -Name"}
                    break
                policy_file = "Configuration.xml" if plan.get("new") else plan["relative"]
                supports[key] = get_object_support(os.path.join(MD_REFERENCE_ROOT, policy_file))
                if supports[key] == "locked":
                    batch = {"id": key, "status": "MANUAL", "reason": f"{policy_file} is locked by vendor support"}
                    break
        if not batch.get("status") and apply and writes:
            try:
                changed = write_metadata_package(packages=members, expected_registry=expected_registry)
                for entry, plan in members:
                    if plan.get("new"):
                        MD_REFERENCE_POOLS.setdefault(entry["type"], []).append(plan["target"])
                ROOT_TARGET_REGISTRARS = None
                cfg.update(read_configuration_props(MD_REFERENCE_ROOT))
            except Exception as exc:
                batch = {"id": keys[0], "status": "CONFLICT", "reason": str(exc)}
        if batch.get("status"):
            for key in keys:
                status = batch["status"] if key == batch["id"] else "WAITING"
                waiting[key] = {"status": status, "reason": f"{ROOT_OWN[batch['id']]['id']}: {batch['reason']}",
                                "dependency": batch.get("dependency"), "linked": True}
            continue
        for entry, plan in members:
            key = entry["key"]
            if apply or not writes:
                ROOT_BINDINGS[key] = plan["target"]
            for item in plan["items"]:
                item["plan"] = {"kind": "md-reference"}
                if apply and item["status"] == "NOT_TRANSFERRED":
                    item.update(status="TRANSFERRED", now=True)
                    if item.get("stored"):
                        ROOT_DATA_WARNINGS.append(item["stored"])
                    if supports.get(key) == "warn":
                        item["text"] += " (locked by vendor support, written: editingAllowedCheck = warn)"
            ROOT_RESULTS[key] = {"id": entry["id"], "items": plan["items"]}
            waiting.pop(key)
        return set(keys), changed


def initialize_root_transfer(ext, objects, cfg, vars_, selected, apply=False, include_default_roles=False):
    global ROOT_TARGET_REGISTRARS
    ROOT_SOURCE_IDS.clear()
    ROOT_OWN.clear()
    ROOT_BINDINGS.clear()
    ROOT_RESULTS.clear()
    ROOT_METHOD_BLOCKS.clear()
    ROOT_GLOBAL_METHODS.clear()
    ROOT_PROVISIONAL.clear()
    ROOT_REGISTRARS.clear()
    ROOT_TARGET_REGISTRARS = None
    initialize_catalog_children(ext, objects)
    ROOT_DATA_WARNINGS.clear()
    pending = []
    default_roles = set()
    if not include_default_roles and any(obj["type"] == "Role" for obj in objects):
        source_config = read_xml(os.path.join(ext["dir"], "Configuration.xml")).getroot()
        default_roles = {inner_text(node).strip().lower() for node in
                         source_config.findall(".//md:Configuration/md:Properties/md:DefaultRoles/*", MD_NSMAP)}
    for obj in objects:
        oid = "%s.%s" % (obj["type"], obj["name"])
        key = oid.lower()
        ROOT_SOURCE_IDS.add(key)
        if obj["type"] not in ("CommonModule", "CommonCommand", "Enum") + STRUCTURED_TRANSFER_KINDS + FLAT_TRANSFER_KINDS:
            continue
        if obj["type"] == "Role" and not include_default_roles and key in default_roles:
            continue
        ctx = get_obj_context(ext["dir"], obj["type"], obj["name"])
        if obj["type"] == "Document" and ctx.get("md") and ctx["md"]["props"] is not None:
            for ref in ctx["md"]["props"].findall("md:RegisterRecords/*", MD_NSMAP):
                ROOT_REGISTRARS.setdefault(inner_text(ref).strip().lower(), {})[key] = oid
        if not ctx["exists"] or ctx["borrowed"]:
            continue
        entry = dict(obj, id=oid, key=key, selected=selected(oid))
        if obj["type"] == "Enum":
            values = ctx["md"]["el"].findall("md:ChildObjects/md:EnumValue", MD_NSMAP)
            entry["value_ids"] = {md_child_name(v).lower(): metadata_transfer_uuid(cfg, "EnumValue", v.get("uuid"))
                                  for v in values if v.get("uuid") and cfg["child_objects"] is not None}
        ROOT_OWN[key] = entry
        pending.append(entry)
        props = ctx["md"]["props"]
        if obj["type"] == "CommonModule" and props is not None and props.findtext("md:Global", namespaces=MD_NSMAP) == "true":
            lines = read_bsl_lines(os.path.join(ext["dir"], root_object_paths(obj["type"], obj["name"])["bsl"])) or []
            for name in get_proc_names(lines):
                method = get_method_safe(lines, name)
                if method and is_export(lines, method):
                    ROOT_GLOBAL_METHODS.setdefault(name.lower(), []).append(key)
    changed = initialize_borrowed_predefined(ext, objects, cfg, selected, apply)
    waiting = {}
    while pending:
        changed.extend(complete_catalog_children(ext["prefix"], cfg, selected, apply))
        again, waiting = [], {}
        for entry in pending:
            oid, key = entry["id"], entry["key"]
            try:
                plan = get_root_object_plan(entry, ext["dir"], ext["prefix"], cfg)
            except Exception as exc:
                plan = {"status": "MANUAL", "reason": str(exc)}
            status = plan["status"]
            if status == "WAITING":
                waiting[key] = plan
                again.append(entry)
                continue
            if status in ("TRANSFERRED", "PARTIAL"):
                ROOT_BINDINGS[key] = plan["target"]
            if entry["type"] in ("Enum",) + STRUCTURED_TRANSFER_KINDS + FLAT_TRANSFER_KINDS and status in ("NOT_TRANSFERRED", "PACKAGE_PARTIAL"):
                new = status == "NOT_TRANSFERRED"
                items = plan["items"]
                if entry["type"] in LINKED_TRANSFER_KINDS and any(item["status"] == "CONFLICT" for item in items):
                    items = [item for item in items if item["status"] != "NOT_TRANSFERRED"]
                writes = [item for item in items if item["status"] == "NOT_TRANSFERRED"]
                if not new and entry["type"] not in FLAT_TRANSFER_KINDS:
                    ROOT_BINDINGS[key] = plan["target"]
                if plan.get("predefined_pending") or (entry["type"] in LINKED_TRANSFER_KINDS
                        and any(item["status"] != "TRANSFERRED" for item in items)):
                    ROOT_BINDINGS.pop(key, None)
                if apply and entry["selected"] and writes:
                    support = None
                    try:
                        policy_file = "Configuration.xml" if new else plan["relative"]
                        support = get_object_support(os.path.join(MD_REFERENCE_ROOT, policy_file))
                        if support == "locked":
                            raise ValueError(policy_file + " is locked by vendor support")
                        changed.extend(write_metadata_package(entry, plan))
                        if new:
                            MD_REFERENCE_POOLS.setdefault(entry["type"], []).append(plan["target"])
                            cfg.update(read_configuration_props(MD_REFERENCE_ROOT))
                        ROOT_BINDINGS[key] = plan["target"]
                        if entry["type"] == "Document":
                            ROOT_TARGET_REGISTRARS = None
                        for item in writes:
                            item.update(status="TRANSFERRED", now=True)
                            if item.get("stored"):
                                ROOT_DATA_WARNINGS.append(item["stored"])
                            if support == "warn":
                                item["text"] += " (locked by vendor support, written: editingAllowedCheck = warn)"
                    except Exception as exc:
                        for item in writes:
                            item.update(status="MANUAL" if support == "locked" else "CONFLICT",
                                        text=item["text"] + " — " + str(exc))
                            if support == "locked":
                                item["sub"] = ["next: allow editing with /support-edit, then re-run -Mode transfer"]
            elif status == "PARTIAL":
                locked = apply and get_object_support(os.path.join(MD_REFERENCE_ROOT, plan["paths"]["xml"])) == "locked"
                settings = SETTINGS[get_object_kind(entry["name"], "own")]
                items, paths = complete_root_module(plan, get_frame(settings, vars_), apply and entry["selected"] and not locked)
                changed.extend(paths)
                ROOT_METHOD_BLOCKS[key] = {
                    item["text"].split()[1].lower() for item in items
                    if item["status"] != "TRANSFERRED" and item["text"].startswith("method ")
                }
                if apply and entry["selected"] and locked:
                    for item in items:
                        if item["status"] == "NOT_TRANSFERRED":
                            item.update(status="MANUAL", text=item["text"] + " — object is locked by vendor support")
            else:
                target = plan.get("target")
                label = "own object"
                if target and target.lower() != entry["name"].lower():
                    label += " (found as %s)" % target
                if plan.get("reason"):
                    label += " — " + plan["reason"]
                item = new_item(status, label)
                if status == "NOT_TRANSFERRED" and apply and entry["selected"]:
                    support = None
                    try:
                        support = get_object_support(os.path.join(MD_REFERENCE_ROOT, "Configuration.xml"))
                        if support == "locked":
                            raise ValueError("Configuration.xml is locked by vendor support")
                        changed.extend(write_root_object(entry, plan))
                        ROOT_BINDINGS[key] = target
                        MD_REFERENCE_POOLS.setdefault(entry["type"], []).append(target)
                        cfg.update(read_configuration_props(MD_REFERENCE_ROOT))
                        item.update(status="TRANSFERRED", now=True, text="own object (as %s)" % target)
                        if support == "warn":
                            item["text"] += " (configuration root locked by vendor support, written: editingAllowedCheck = warn)"
                    except Exception as exc:
                        item.update(status="MANUAL" if support == "locked" else "CONFLICT",
                                    text=label + " — " + str(exc))
                        if support == "locked":
                            item["sub"] = ["next: allow editing with /support-edit, then re-run -Mode transfer"]
                items = [item]
            for item in items:
                item["plan"] = {"kind": "md-reference"}
            ROOT_RESULTS[key] = {"id": oid, "items": items}
        if len(again) == len(pending):
            predefined_changes = initialize_borrowed_predefined(ext, objects, cfg, selected, apply, retry=True)
            if predefined_changes:
                changed.extend(predefined_changes)
                pending = again
                continue
            done, batch_changes = complete_linked_root_groups(waiting, ext, cfg, apply)
            changed.extend(batch_changes)
            if not done:
                break
            again = [entry for entry in again if entry["key"] not in done]
        pending = again
    changed.extend(initialize_borrowed_predefined(ext, objects, cfg, selected, apply, retry=True))
    changed.extend(complete_catalog_children(ext["prefix"], cfg, selected, apply))
    deps = {key: plan.get("dependency") for key, plan in waiting.items() if not plan.get("linked")}
    deps.update({key: entry["dependency"] for key, entry in CATALOG_CHILDREN.items() if entry["item"]["status"] == "WAITING"})
    for key, dep in deps.items():
        path = [key]
        while dep in deps:
            if dep in path:
                if dep == key:
                    cycle = " -> ".join((ROOT_OWN.get(k) or CATALOG_CHILDREN[k])["id"] for k in path + [dep])
                    reason = "dependency cycle: " + cycle
                    if key in waiting:
                        waiting[key].update(status="MANUAL", reason=reason)
                    else:
                        item = CATALOG_CHILDREN[key]["item"]
                        item.update(status="MANUAL", text=item["text"] + " — " + reason)
                break
            path.append(dep)
            dep = deps[dep]
    for key, plan in waiting.items():
        ROOT_RESULTS[key] = {"id": ROOT_OWN[key]["id"], "items": [new_md_reference_item("own object", plan)]}
    return list(dict.fromkeys(changed))


def transfer_object(ext, obj, cfg_info, config_path, cfg_pools=None):
    ctx = get_obj_context(ext["dir"], obj["type"], obj["name"])
    rec = {"id": "%s.%s" % (obj["type"], obj["name"]), "items": []}
    if not ctx["known"] or not ctx["exists"]:
        return rec
    prefix = ext["prefix"]
    if not ctx["borrowed"]:
        if rec["id"].lower() in ROOT_RESULTS:
            return ROOT_RESULTS[rec["id"].lower()]
        pool = []
        if cfg_info["child_objects"] is not None:
            pool = [(c.text or "").strip() for c in elem_children(cfg_info["child_objects"]) if localname(c) == obj["type"]]
        hit = find_name_in(pool, obj["name"], prefix)
        if hit and not os.path.isfile(os.path.join(config_path, ctx["dir"], hit + ".xml")):
            rec["items"].append(new_md_reference_item("own object", {"status": "MANUAL",
                                "reason": "missing descriptor %s/%s.xml" % (ctx["dir"], hit)}))
            return rec
        as_ = (" (found as %s)" % hit) if hit and hit.lower() != obj["name"].lower() else ""
        rec["items"].append(new_item("TRANSFERRED" if hit else "NOT_TRANSFERRED", "own object" + as_))
        return rec
    cfg_md = read_md_object(os.path.join(config_path, ctx["dir"], obj["name"] + ".xml"))
    forms = get_obj_forms(ctx)
    diffs = {}
    form_items = []
    form_interceptors = []
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
        set_bsl_context(rel_path(ext["dir"], f["module"]))
        # Dialog changes have no line of their own: their file is the form's Form.xml
        for fi in form_transfer_items(d, f, cfg_form, cfg_module, ext["dir"], prefix, form_interceptors):
            if not fi["loc"]:
                fi["section"] = rel
            form_items.append(fi)
    for bsl in get_obj_modules(ctx, forms):
        k = path_key(bsl)
        skip = call_type_handlers(diffs[k]) if k in diffs else set()
        rec["items"] += module_transfer_items(bsl, ext["dir"], config_path, prefix, skip, form_interceptors)
    # Section = the file the change lives in (a module line, the form's Form.xml, the object's own
    # XML for its sub-objects); the item then keeps only its line number
    obj_rel = rel_path(ext["dir"], ctx["file"])
    # Overrides of the borrowed object's own properties; a missing config object is MISSING_IN_CONFIG anyway
    rank = format_rank(ctx["md"]["el"].getroottree().getroot().get("version")) if ctx["md"]["el"] is not None else 0
    if cfg_md is not None:
        add_md_prop_items(rec["items"], ctx["md"]["el"], cfg_md["el"], prefix, rank, obj_rel,
                          ctx["type"], "", "", "", "object", True)
    rec["items"] += own_child_items(ctx, cfg_md, prefix, obj_rel, rank)
    rec["items"] += [entry["item"] for entry in sorted(CATALOG_CHILDREN.values(), key=lambda e: (e["kind"], e["name"]))
                     if rec["id"].lower() == entry["ctx"]["id"].lower() and entry.get("item")]
    predefined = BORROWED_PREDEFINED_ITEMS.get(rec["id"].lower())
    if predefined:
        rec["items"].append(predefined)
    if obj["type"] == "Subsystem":
        rec["items"] += subsystem_content_items(ctx["md"], cfg_md, prefix, obj_rel, cfg_pools)
    rec["items"] += form_items
    for it in rec["items"]:
        pl2 = it.get('plan')
        if pl2 and pl2.get('rel') and it['status'] not in ('TRANSFERRED', 'TEMPORARY'):
            set_bsl_context(pl2['rel'])
            problem = get_bsl_plan_issue(pl2)
            if problem:
                it['status'] = problem['issue'].get('status', 'MANUAL')
                it['text'] += ' — ' + problem['issue']['why']
                it['sub'] = get_bsl_manual_details(pl2, problem)
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


def subsystem_content_items(md, cfg_md, prefix, rel, cfg_pools=None):
    """Transfer of a borrowed subsystem's content: each object the extension adds must be in the
    content of the configuration's subsystem (own names compared with and without the prefix)."""
    items = []
    entries = get_subsystem_content(cfg_md)
    cfg = {value.lower() for value in entries}
    for ref in get_subsystem_content(md):
        resolved = resolve_md_reference(ref, prefix)
        if resolved.get("status"):
            if ref.lower() in cfg and resolved["status"] == "WAITING":
                resolved["status"] = "CONFLICT"
            items.append(new_md_reference_item("content " + ref, resolved))
            continue
        target = resolved["value"]
        renamed = target.lower() != ref.lower()
        stale = ref if renamed and ref.lower() in cfg else find_stale_md_reference(entries, target, prefix)
        if stale:
            items.append(new_md_reference_item("content " + ref, {"status": "CONFLICT",
                                              "reason": "existing reference %s differs from %s" % (stale, target)}))
            continue
        hit = target.lower() in cfg
        as_ = (" (found as %s)" % target) if renamed else ""
        ni = new_item("TRANSFERRED" if hit else "NOT_TRANSFERRED", "content " + ref + as_)
        if not hit:
            ni["plan"] = {"kind": "md-content", "rel": rel, "ref": target}
        items.append(ni)
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
# Form writing: nodes of the extension's Form.xml copied into the configuration's one
# ============================================================

def read_form_write(path):
    """A form document for writing: whitespace is kept, BOM and line breaks are remembered."""
    data = open(path, "rb").read()
    bom = data[:3] == b"\xef\xbb\xbf"
    parser = etree.XMLParser(remove_blank_text=False)
    root = etree.fromstring(data, parser)
    # The parser normalizes line breaks of the tree to "\n": the nodes are written with it, and the file's
    # own line breaks are restored on save (a raw "\r" in a text node would come out as "&#13;")
    return {"path": path, "root": root, "bom": bom, "eol": "\n",
            "file_eol": "\r\n" if b"\r\n" in data else "\n"}


def save_form_write(fw, path=None):
    """The document written the way the platform dumps it: UTF-8, <a/> without a space, the file's line breaks."""
    body = etree.tostring(fw["root"], encoding="unicode")
    text = '<?xml version="1.0" encoding="UTF-8"?>\n' + body
    text = re.sub(r'(?<=\S) />', '/>', text)
    if fw.get("file_eol", fw["eol"]) == "\r\n":
        text = text.replace("\r\n", "\n").replace("\n", "\r\n")
    with open(path or fw["path"], "wb") as fh:
        fh.write((b"\xef\xbb\xbf" if fw["bom"] else b"") + text.encode("utf-8"))


def get_form_id_pools(root):
    """Free ids of the configuration's form: elements (with companions), attributes, commands, columns per attribute."""
    res = {"elem": 0, "attr": 0, "cmd": 0, "col": {}}
    for n in root.iter():
        if not isinstance(n.tag, str) or n.get("id") is None:
            continue
        try:
            v = int(n.get("id"))
        except ValueError:
            continue
        tag = localname(n)
        if tag == "Attribute":
            res["attr"] = max(res["attr"], v)
        elif tag == "Command":
            res["cmd"] = max(res["cmd"], v)
        elif tag == "Column":
            at = n.getparent()
            while at is not None and localname(at) != "Attribute":
                at = at.getparent()
            k = (at.get("name") or "").lower() if at is not None else ""
            res["col"][k] = max(res["col"].get(k, 0), v)
        else:
            res["elem"] = max(res["elem"], v)
    return res


def get_form_depth(node):
    d = 0
    cur = node
    while cur is not None and cur.getparent() is not None:
        d += 1
        cur = cur.getparent()
    return d


def get_form_child_indent(container, eol):
    """Indent of the container's children, from the whitespace it already has."""
    for s in [container.text] + [c.tail for c in container]:
        m = re.match(r'^\r?\n(\t+)', s or "")
        if m:
            return m.group(1)
    return "\t" * (get_form_depth(container) + 1)


def set_form_subtree_indent(node, eol, depth):
    """Whitespace of a subtree rewritten for a new depth: the gaps between children are the children's tails."""
    kids = list(node)
    if not kids:
        return
    node.text = eol + "\t" * (depth + 1)
    for i, c in enumerate(kids):
        set_form_subtree_indent(c, eol, depth + 1)
        c.tail = eol + ("\t" * (depth + 1) if i < len(kids) - 1 else "\t" * depth)


def insert_form_node_at(container, node, ref, eol):
    """A node put among the container's children: before the reference, else after the last child."""
    ind = get_form_child_indent(container, eol)
    depth = get_form_depth(container)
    if ref is not None:
        node.tail = eol + ind
        container.insert(container.index(ref), node)
        return
    kids = list(container)
    if kids:
        kids[-1].tail = eol + ind
    else:
        container.text = eol + ind
    container.append(node)
    node.tail = eol + "\t" * depth


def remove_form_node(node):
    parent = node.getparent()
    prev = node.getprevious()
    tail = node.tail
    parent.remove(node)
    if prev is not None:
        prev.tail = tail
    else:
        parent.text = tail


def get_form_child_items(container):
    ci = container.find("d:ChildItems", NSMAP)
    if ci is not None:
        return ci
    ci = etree.SubElement(container, "{%s}ChildItems" % NSMAP["d"])
    return ci


def get_form_prop_keys(node):
    """Name of the property node as get_prop_map keys it: the tag, a repeat gets #2, #3…"""
    res = {}
    seen = {}
    for c in node:
        if not isinstance(c.tag, str):
            continue
        k = localname(c)
        if k in seen:
            seen[k] += 1
            k = "%s#%d" % (k, seen[k])
        else:
            seen[k] = 1
        res[k] = c
    return res


def insert_form_prop(target, ext_node, key, new_node, eol):
    """A property node put where the extension's layout has it: after the previous one both sides have, else
    before the next, else first."""
    keys = []
    seen = {}
    for c in ext_node:
        if not isinstance(c.tag, str):
            continue
        k = localname(c)
        if k in seen:
            seen[k] += 1
            k = "%s#%d" % (k, seen[k])
        else:
            seen[k] = 1
        keys.append(k)
    pos = keys.index(key) if key in keys else -1
    tgt = get_form_prop_keys(target)
    ref = None
    if pos > 0:
        for i in range(pos - 1, -1, -1):
            if keys[i] in tgt:
                ref = tgt[keys[i]].getnext()
                break
    if ref is None and pos >= 0:
        for i in range(pos + 1, len(keys)):
            if keys[i] in tgt:
                ref = tgt[keys[i]]
                break
    if ref is None and len(target):
        ref = target[0]
    insert_form_node_at(target, new_node, ref, eol)


def get_form_name_set(root):
    return {(n.get("name") or "").lower() for n in root.iter() if isinstance(n.tag, str) and n.get("name")}


def find_scoped_form_names(targets, name, prefix, owners):
    owners = {source.lower() for source in owners}
    return [hit for hit in find_names_in(targets, name, prefix) if hit.lower() == name.lower() or hit.lower() not in owners]


def get_form_attribute_targets(ext_root, cfg_root, prefix, cfg_lines):
    taken = get_form_name_set(cfg_root)
    ext_attrs = section_map(ext_root, "Attributes", "Attribute")
    cfg_attrs = section_map(cfg_root, "Attributes", "Attribute")
    cfg_names = [name for name, _ in cfg_attrs.values()]
    taken.update(name.lower() for decl in get_module_layout(cfg_lines or [])["vars"] for name in decl["names"])
    result = {}
    for name, _ in ext_attrs.values():
        if not prefix or not name.lower().startswith(prefix.lower()):
            continue
        hits = find_scoped_form_names(cfg_names, name, prefix, ext_attrs)
        if hits:
            result[name.lower()] = hits[0]
            continue
        target = get_target_name(name, prefix, taken, False)
        result[name.lower()] = target["name"]
        if not target.get("taken"):
            taken.add(target["name"].lower())
    return result


def get_form_name_map(ext_root, cfg_root, prefix):
    """Names of the extension's main part -> names in the configuration: the extension prefix goes, a taken
    name gets the project's development prefix."""
    taken = get_form_name_set(cfg_root)
    res = {}
    for n in ext_root.iter():
        if not isinstance(n.tag, str) or not n.get("name"):
            continue
        nm = n.get("name")
        k = nm.lower()
        if k in res:
            continue
        if prefix and nm.lower().startswith(prefix.lower()):
            tn = get_target_name(nm, prefix, taken, False)
            if not tn.get("taken"):
                taken.add(tn["name"].lower())
            res[k] = tn["name"]
    return res


def get_config_ref_map(cfg_dir):
    """Objects of the configuration by uuid: the style items and common pictures name themselves in their own
    source files — StyleItems/<Name>.xml, CommonPictures/<Name>.xml."""
    res = {}
    for folder, prefix in (("StyleItems", "style:"), ("CommonPictures", "CommonPicture.")):
        d = os.path.join(cfg_dir, folder)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            if not f.lower().endswith(".xml"):
                continue
            root = _load_xml_root(os.path.join(d, f))
            if root is None:
                continue
            obj = next((c for c in root if isinstance(c.tag, str)), None)
            if obj is None or not obj.get("uuid"):
                continue
            props = next((c for c in obj if isinstance(c.tag, str) and localname(c) == "Properties"), None)
            nm = next((c for c in props if isinstance(c.tag, str) and localname(c) == "Name"), None) if props is not None else None
            if nm is not None and (nm.text or "").strip():
                res[obj.get("uuid").lower()] = prefix + nm.text.strip()
    return res


def get_ref_cmp_key(node, prefix):
    """A compared value that is a reference to a style item or a picture: the extension has "0:<uuid>", the
    configuration's dump has "style:<Name>"/"CommonPicture.<Name>", so the extension's side is read the same."""
    k = cmp_key(node, prefix)
    if not k or "0:" not in k or not CONFIG_REF_MAP:
        return k
    # The value of a leaf inside the canonical form: <tag>0:<uuid></>
    return re.sub(r'(?<=>)0:([0-9a-fA-F-]{36})(?=<)',
                  lambda m: CONFIG_REF_MAP.get(m.group(1).lower(), m.group(0)), k)


FORM_PATH_TAGS = re.compile(r'(DataPath|TitleDataPath|FooterDataPath|HeaderDataPath|MultipleValue\w*DataPath)$')


def get_form_reference_scope(ext_root, cfg_root, prefix, cfg_lines):
    attrs = {
        (attr.get("name") or "").lower(): {(column.get("name") or "").lower()
                                          for column in attr.findall("d:Columns/d:Column", NSMAP)}
        for attr in ext_root.findall("d:Attributes/d:Attribute", NSMAP)
    }
    return {"attributes": attrs, "attribute_targets": get_form_attribute_targets(ext_root, cfg_root, prefix, cfg_lines),
            "elements": form_element_index(ext_root), "config": cfg_root, "prefix": prefix}


def resolve_form_reference_name(name, targets, name_map, scope, bad, owners):
    hits = find_scoped_form_names(targets, name, scope["prefix"], owners)
    if len(hits) == 1 or (hits and hits[0].lower() == name.lower()):
        return hits[0]
    if hits:
        bad.append("ambiguous form reference %s (matches %s); choose the intended target" % (name, ", ".join(hits)))
        return name
    return name_map.get(name.lower(), name)


def resolve_form_element_reference(name, name_map, scope, bad):
    source = scope["elements"].get(name.lower())
    if source is None:
        return name
    kind = localname(source["node"])
    targets = [rec["name"] for rec in form_element_index(scope["config"]).values() if localname(rec["node"]) == kind]
    return resolve_form_reference_name(name, targets, name_map, scope, bad, scope["elements"])


def convert_form_path(value, name_map, scope, bad):
    m = re.fullmatch(r'\s*~?(?P<head>\w+)(?:\[\d+\])?(?:\.(?P<member>\w+))?(?:\[\d+\])?(?:\.\w+(?:\[\d+\])?)*\s*', value)
    if not m:
        return value
    head, member = m.group("head", "member")
    if head.lower() in ("items", "элементы") and member:
        target = resolve_form_element_reference(member, name_map, scope, bad)
        return value[:m.start("member")] + target + value[m.end("member"):]
    columns = scope["attributes"].get(head.lower())
    if columns is None:
        return value
    attrs = section_map(scope["config"], "Attributes", "Attribute")
    target = resolve_form_reference_name(head, [name for name, _ in attrs.values()], scope["attribute_targets"], scope, bad,
                                        scope["attributes"])
    if member and member.lower() in columns:
        owner = attrs.get(target.lower())
        existing = [(n.get("name") or "") for n in owner[1].findall("d:Columns/d:Column", NSMAP)] if owner else []
        replacement = resolve_form_reference_name(member, existing, name_map, scope, bad, columns)
        value = value[:m.start("member")] + replacement + value[m.end("member"):]
    return value[:m.start("head")] + target + value[m.end("head"):]


def get_form_reference_kind(node):
    dcsset = "{%s}" % NSMAP["dcsset"]
    form_tag = "{%s}" % NSMAP["d"]
    parent = node.getparent()
    owner = parent.getparent() if parent is not None else None
    if ((node.tag == dcsset + "field" and owner is not None and owner.tag == dcsset + "selection")
            or (node.tag == form_tag + "Item" and parent is not None and parent.tag == form_tag + "AdditionSource")):
        return "element"
    if FORM_PATH_TAGS.search(localname(node)) or (node.tag in (dcsset + "left", dcsset + "right") and
            (node.get("{%s}type" % NSMAP["xsi"]) or "").endswith(":Field")):
        return "path"
    return None


def convert_scoped_form_leaf(node, role, name_map, scope, bad):
    value = node.text or ""
    if role == "element":
        node.text = resolve_form_element_reference(value.strip(), name_map, scope, bad)
    elif role == "path":
        node.text = convert_form_path(value, name_map, scope, bad)


def get_form_property_key(node, prefix, scope=None, name_map=None, bad=None):
    if node is None:
        return get_ref_cmp_key(node, prefix)
    if scope is not None:
        if localname(node) == "Item" and get_form_reference_kind(node) == "element":
            node = copy.deepcopy(node.getparent()).find("d:Item", NSMAP)
        else:
            node = copy.deepcopy(node)
    refs = []
    for leaf in node.iter():
        if not isinstance(leaf.tag, str) or len(leaf):
            continue
        role = get_form_reference_kind(leaf)
        if role:
            if scope is not None:
                convert_scoped_form_leaf(leaf, role, name_map, scope, bad)
            refs.append((leaf.text or "").strip())
    key = get_ref_cmp_key(node, prefix)
    return key + "|" + "|".join(refs) if refs else key


def convert_form_leaf(node, name_map, ref_map, handler_map, bad, scope):
    """Text of a leaf rewritten: names renamed, "0:<uuid>" references resolved, handler names renamed."""
    tag = localname(node)
    if node.tag == "{%s}content" % NSMAP["v8"]:
        return
    v = node.text or ""
    if tag in ("Action", "Event"):
        t = v.strip()
        if handler_map and t.lower() in handler_map:
            node.text = handler_map[t.lower()]
        return
    if tag == "CommandName" and v.strip().startswith("Form.Command."):
        cn = v.strip()[len("Form.Command."):]
        if cn.lower() in name_map:
            node.text = "Form.Command." + name_map[cn.lower()]
        return
    m = re.match(r'^\s*0:([0-9a-fA-F-]{36})\s*$', v)
    if m:
        u = m.group(1).lower()
        if u in ref_map:
            node.text = ref_map[u]
        else:
            bad.append("reference %s 0:%s is not in the configuration" % (tag, u))
        return
    convert_scoped_form_leaf(node, get_form_reference_kind(node), name_map, scope, bad)


def copy_form_node(node, pools, name_map, ref_map, handler_map, bad, scope, col_owner="", omit_names=None):
    """A copy of the extension's node for the configuration: ids from its pools, names and references converted."""
    c = copy.deepcopy(node)
    if omit_names:
        for child in list(c.iterdescendants()):
            if is_form_element(child) and child.get("name").lower() in omit_names:
                child.getparent().remove(child)
    for n in c.iter():
        if not isinstance(n.tag, str):
            continue
        if n.get("id") is not None:
            tag = localname(n)
            if tag == "Attribute":
                pools["attr"] += 1
                n.set("id", str(pools["attr"]))
            elif tag == "Command":
                pools["cmd"] += 1
                n.set("id", str(pools["cmd"]))
            elif tag == "Column":
                owner = (col_owner or "").lower()
                pools["col"][owner] = pools["col"].get(owner, 0) + 1
                n.set("id", str(pools["col"][owner]))
            else:
                pools["elem"] += 1
                n.set("id", str(pools["elem"]))
        nm = n.get("name")
        if nm and nm.lower() in name_map:
            n.set("name", name_map[nm.lower()])
        if len(n) == 0:
            convert_form_leaf(n, name_map, ref_map, handler_map, bad, scope)
    return c


def get_form_section(root, name):
    s = root.find("d:" + name, NSMAP)
    if s is not None:
        return s
    s = etree.SubElement(root, "{%s}%s" % (NSMAP["d"], name))
    return s


def insert_form_element(rec, root, name_map):
    """An element put among its parent's children: after the nearest previous sibling the configuration has."""
    parent_name = rec["parent"]
    container = root
    if parent_name:
        target = find_form_target(root, name_map, parent_name)
        if target is None:
            return None
        container = target
    ci = get_form_child_items(container)
    ref = None
    found_any = False
    for sib in reversed(rec["siblings"][:rec["pos"]]):
        mn = name_map.get(sib.lower(), sib)
        found = next((c for c in ci if isinstance(c.tag, str) and c.get("name") == mn), None)
        if found is not None:
            found_any = True
            ref = found.getnext()
            break
    # None of the previous siblings is there: the element stands first, as the check reads it back
    if not found_any:
        ref = next((c for c in ci if isinstance(c.tag, str)), None)
    return {"ci": ci, "ref": ref}


def find_form_target(root, name_map, name):
    """The element of the configuration by its name in the extension: the name map applied. Attributes and
    commands may share a name with an element — only the form's own elements are looked up here."""
    mn = name_map.get(name.lower(), name)
    rec = form_element_index(root).get(mn.lower())
    return rec["node"] if rec else None


def find_form_attr(root, name):
    """The attribute of the configuration by its name: a form element may share it, the element stands first."""
    return next((a for a in root.findall("d:Attributes/d:Attribute", NSMAP) if (a.get("name") or "").lower() == name.lower()), None)


def apply_form_op(fe, op, ctx):
    root = fe["fw"]["root"]
    eol = fe["fw"]["eol"]
    pools = fe["pools"]

    def copy_node(node, col_owner="", omit_names=None):
        return copy_form_node(node, pools, ctx["name_map"], ctx["ref_map"], ctx["handler_map"], ctx["bad"],
                              ctx["reference_scope"], col_owner, omit_names)

    kind = op["kind"]
    if kind == "attribute":
        attrs = get_form_section(root, "Attributes")
        node = copy_node(op["node"], op.get("name", ""))
        target = ctx["reference_scope"]["attribute_targets"].get(op["name"].lower())
        if target:
            node.set("name", target)
        set_form_subtree_indent(node, eol, get_form_depth(attrs) + 1)
        ca = attrs.find("d:ConditionalAppearance", NSMAP)
        insert_form_node_at(attrs, node, ca, eol)
    elif kind == "column":
        at = find_form_attr(root, ctx["reference_scope"]["attribute_targets"].get(op["attr"].lower(), op["attr"]))
        if at is None:
            raise ValueError("SKIP: attribute %s is not in the configuration" % op["attr"])
        cols = at.find("d:Columns", NSMAP)
        if cols is None:
            cols = etree.SubElement(at, "{%s}Columns" % NSMAP["d"])
        node = copy_node(op["node"], at.get("name") or "")
        set_form_subtree_indent(node, eol, get_form_depth(cols) + 1)
        insert_form_node_at(cols, node, None, eol)
    elif kind == "command":
        cmds = get_form_section(root, "Commands")
        node = copy_node(op["node"])
        # A command of the extension's own: callType has no handler of the configuration to intercept
        if op.get("strip_call_type"):
            for a in node.findall("d:Action", NSMAP):
                a.attrib.pop("callType", None)
        set_form_subtree_indent(node, eol, get_form_depth(cmds) + 1)
        insert_form_node_at(cmds, node, None, eol)
    elif kind == "element":
        # Only the form's own elements count: an attribute may share a name with an element
        el_names = form_element_index(root)
        # What a copied ancestor brought into this run is not added a second time
        mn = ctx["name_map"].get(op["rec"]["name"].lower(), op["rec"]["name"])
        if mn.lower() in el_names:
            return
        where = insert_form_element(op["rec"], root, ctx["name_map"])
        if where is None:
            raise ValueError("SKIP: parent %s is not in the configuration" % op["rec"]["parent"])
        node = copy_node(op["rec"]["node"], omit_names=ctx["temp_marks"])
        # Descendants the configuration already has come with their own items: a property, a move — the copy
        # of the new element must not bring a second one
        for d in list(node.iter()):
            if d is node or not isinstance(d.tag, str):
                continue
            dn = d.get("name")
            if dn and dn.lower() in el_names:
                d.getparent().remove(d)
        # A button carries its command with it: a command the configuration does not have leaves the
        # form broken
        cmds0 = section_map(root, "Commands", "Command")
        for cn in node.findall(".//d:CommandName", NSMAP):
            v = (cn.text or "").strip()
            if not v.startswith("Form.Command."):
                continue
            v = v[len("Form.Command."):]
            if v.lower() not in cmds0:
                raise ValueError("SKIP: command %s is not in the configuration" % v)
        set_form_subtree_indent(node, eol, get_form_depth(where["ci"]) + 1)
        insert_form_node_at(where["ci"], node, where["ref"], eol)
    elif kind == "event":
        target = find_form_target(root, ctx["name_map"], op["scope"]) if op["scope"] else root
        if target is None:
            raise ValueError("SKIP: element %s is not in the configuration" % op["scope"])
        evs = target.find("d:Events", NSMAP)
        if evs is None:
            evs = etree.Element("{%s}Events" % NSMAP["d"])
            insert_form_node_at(target, evs, None, eol)
        node = etree.Element("{%s}Event" % NSMAP["d"])
        node.set("name", op["name"])
        node.text = op["handler"]
        insert_form_node_at(evs, node, None, eol)
    elif kind == "prop":
        target = find_form_target(root, ctx["name_map"], op["rec"]["name"])
        if target is None:
            raise ValueError("SKIP: element %s is not in the configuration" % op["rec"]["name"])
        for p in op["props"]:
            keys = get_form_prop_keys(target)
            if p["new"] is None:
                if p["key"] in keys:
                    remove_form_node(keys[p["key"]])
                continue
            node = copy_node(p["new"])
            if p["key"] in keys:
                old = keys[p["key"]]
                old.addprevious(node)
                node.tail = old.tail
                target.remove(old)
            else:
                insert_form_prop(target, op["rec"]["node"], p["key"], node, eol)
    elif kind == "formprop":
        for p in op["props"]:
            keys = get_form_prop_keys(root)
            if p["new"] is None:
                if p["key"] in keys:
                    remove_form_node(keys[p["key"]])
                continue
            node = copy_node(p["new"])
            if p["key"] in keys:
                old = keys[p["key"]]
                old.addprevious(node)
                node.tail = old.tail
                root.remove(old)
            else:
                insert_form_prop(root, op["ext_root"], p["key"], node, eol)
    elif kind == "move":
        target = find_form_target(root, ctx["name_map"], op["rec"]["name"])
        if target is None:
            raise ValueError("SKIP: element %s is not in the configuration" % op["rec"]["name"])
        if op["rec"]["parent"]:
            parent = find_form_target(root, ctx["name_map"], op["rec"]["parent"])
            if parent is None:
                raise ValueError("SKIP: parent %s is not in the configuration" % op["rec"]["parent"])
            if parent is target or any(ancestor is target for ancestor in parent.iterancestors()):
                raise ValueError("SKIP: destination %s is inside the element being moved" % op["rec"]["parent"])
        node = copy.deepcopy(target)
        remove_form_node(target)
        where = insert_form_element(op["rec"], root, ctx["name_map"])
        if where is None:
            raise ValueError("parent %s disappeared during the move" % op["rec"]["parent"])
        insert_form_node_at(where["ci"], node, where["ref"], eol)
    elif kind == "appearance":
        attrs = get_form_section(root, "Attributes")
        ca = attrs.find("d:ConditionalAppearance", NSMAP)
        if op["add"]:
            if ca is None:
                ca = etree.SubElement(attrs, "{%s}ConditionalAppearance" % NSMAP["d"])
            node = copy_node(op["rule"])
            set_form_subtree_indent(node, eol, get_form_depth(ca) + 1)
            insert_form_node_at(ca, node, None, eol)
        elif ca is not None:
            key = get_form_property_key(op["rule"], TRANSFER_PREFIX, ctx["reference_scope"], ctx["name_map"], ctx["bad"])
            for it in ca.findall("dcsset:item", NSMAP):
                if get_form_property_key(it, TRANSFER_PREFIX) == key:
                    remove_form_node(it)
                    break
    else:
        raise ValueError("unknown form operation %s" % kind)


def new_form_edit(path, ext_form, ext_module, cfg_module, ext_dir, prefix, label):
    # The full path as the key: two spellings of one file must not make two documents
    k = os.path.abspath(path).lower()
    if k not in FORM_EDITS:
        fw = read_form_write(path)
        FORM_EDITS[k] = {
            "path": path, "fw": fw, "pools": get_form_id_pools(fw["root"]),
            "ext_form": ext_form, "ext_module": ext_module, "cfg_module": cfg_module,
            "ext_dir": ext_dir, "prefix": prefix, "label": label,
            "form_info": {"xml": ext_form, "module": ext_module, "label": label},
            "ops": [], "failed": 0,
        }
    return FORM_EDITS[k]


def get_form_validate_errors(path, context_path=None, module_path=None):
    """Errors of the form validator (form-validate) for a form file: what the write must not add."""
    here = os.path.dirname(os.path.abspath(__file__))
    script = os.path.join(here, "..", "..", "form-validate", "scripts", "form-validate.py")
    if not os.path.exists(script):
        # The skill may be installed on its own: say so rather than skip the check silently
        globals()["FORM_VALIDATE_MISSING"] = True
        return []
    command = [sys.executable, script, "-FormPath", path, "-MaxErrors", "2147483647"]
    if context_path:
        command.extend(["-ContextFormPath", context_path])
    if module_path:
        command.extend(["-ModulePath", module_path])
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
    errs = []
    complete = False
    for line in result.stdout.splitlines():
        if re.match(r'^Stopped after \d+ errors', line):
            raise ValueError("form-validate stopped before checking the entire form")
        if "[ERROR]" in line:
            errs.append(re.sub(r'\s+', ' ', line.split("[ERROR]", 1)[1]).strip())
        if re.match(r'^(=== (Validation OK|Result):|Errors: \d+, Warnings: \d+)', line):
            complete = True
    if not complete or result.returncode not in (0, 1) or (result.returncode == 1 and not errs):
        raise ValueError("form-validate did not complete (exit %d)" % result.returncode)
    return errs


def test_form_write(fe, module_only=False):
    """The form written and read back the same way the check reads it: every planned item must come out in place —
    a property by its value, the rest by the line the check would print for it."""
    tmp = None
    tmp_module = None
    try:
        module = FILE_EDITS.get(fe["cfg_module"].lower())
        if module:
            lines = get_file_edit_lines(module)
            if lines is not None:
                fd, tmp_module = tempfile.mkstemp(suffix=".bsl")
                os.close(fd)
                write_bsl_file(module["file"], lines, tmp_module)
        if module_only and not tmp_module:
            return []
        if not module_only:
            fd, tmp = tempfile.mkstemp(suffix=".xml")
            os.close(fd)
            save_form_write(fe["fw"], tmp)
        # The validator must not see errors the configuration's form did not have before the write
        before = {re.sub(r'Module\.bsl:\d+', 'Module.bsl', error)
                  for error in get_form_validate_errors(fe["path"])}
        after = get_form_validate_errors(fe["path"] if module_only else tmp, fe["path"], tmp_module)
        added = [error for error in after if re.sub(r'Module\.bsl:\d+', 'Module.bsl', error) not in before]
        if added:
            return ["form-validate: " + added[0]]
        if module_only:
            return []
        diff = get_form_diff(fe["ext_form"])
        set_bsl_context(rel_path(fe["ext_dir"], fe["ext_module"]))
        items = form_transfer_items(diff, fe["form_info"], tmp, tmp_module or fe["cfg_module"], fe["ext_dir"], fe["prefix"])
        ok = [it["text"] for it in items if it["status"] == "TRANSFERRED"]
        doc = read_form_doc(tmp)
        names = list(form_element_index(doc.getroot()).keys()) if doc is not None else []
        miss = []

        def bad_props(target, props):
            if target is None:
                return ["target not found"]
            cpm = get_prop_map(target)
            return [p["key"] for p in props
                    if prop_transfer(cpm, p, fe["prefix"], fe["ctx"]["reference_scope"], fe["ctx"]["name_map"]) != "ok"]

        for op in fe["ops"]:
            if op["kind"] == "prop":
                hit = find_name_in(names, op["rec"]["name"], fe["prefix"])
                target = form_element_index(doc.getroot())[hit.lower()]["node"] if (hit and doc is not None) else None
                miss += ["%s.%s" % (op["rec"]["name"], x) for x in bad_props(target, op["props"])]
                continue
            if op["kind"] == "formprop":
                miss += ["form." + x for x in bad_props(doc.getroot() if doc is not None else None, op["props"])]
                continue
            hit = any(t.startswith(op["key"]) for t in ok)
            # A command of the extension's own is read back by the check as an interception of itself: its
            # item goes by the command and the callType of the extension's action
            if not hit and op["key"].startswith("+ command "):
                cre = re.compile(r'^command ' + re.escape(op["key"][len("+ command "):]) + r'\[')
                hit = any(cre.match(t) for t in ok)
            if not hit:
                miss.append(op["key"])
        return miss
    except Exception as exc:
        return [str(exc)]
    finally:
        for path in (tmp, tmp_module):
            if path:
                try:
                    os.remove(path)
                except OSError:
                    pass


# ============================================================
# Metadata writing: nodes of the extension's object XML copied into the configuration's one
# ============================================================

XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
V8_NS = "http://v8.1c.ru/8.1/data/core"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"


def get_md_edits(path, obj_type):
    """Edits of one configuration's object XML, collected over the run and written once."""
    k = os.path.abspath(path).lower()
    if k not in MD_EDITS:
        with open(path, "rb") as original:
            before = hashlib.sha256(original.read()).digest()
        MD_EDITS[k] = {"path": path, "obj_type": obj_type, "before": before,
                       "fw": read_form_write(path), "ops": [], "failed": 0}
    return MD_EDITS[k]


def get_md_object_element(root):
    """The object element of a configuration's object XML."""
    for c in root:
        if isinstance(c.tag, str):
            return c
    return None


def get_md_container(me, parent, tag):
    """The <ChildObjects> of the object or of its tabular section `parent`, created where it belongs."""
    root = me["fw"]["root"]
    eol = me["fw"]["eol"]
    obj_el = get_md_object_element(root)
    if obj_el is None:
        return None
    owner = obj_el
    if parent:
        owner = None
        kids = obj_el.find("md:ChildObjects", MD_NSMAP)
        if kids is not None:
            for c in elem_children(kids):
                if localname(c) == "TabularSection" and md_child_name(c).lower() == parent.lower():
                    owner = c
                    break
        if owner is None:
            return None
    co = owner.find("md:ChildObjects", MD_NSMAP)
    if co is None:
        co = etree.SubElement(owner, "{%s}ChildObjects" % MD_NS)
        insert_form_node_at(owner, co, None, eol)
    return co


def apply_md_op(me, plan):
    root = me["fw"]["root"]
    eol = me["fw"]["eol"]
    obj_el = get_md_object_element(root)
    if obj_el is None:
        raise ValueError("SKIP: the object is not in the configuration")
    if plan["kind"] == "md-prop":
        apply_md_prop_op(me, plan)
        return
    if plan["kind"] == "md-content":
        props = obj_el.find("md:Properties", MD_NSMAP)
        if props is None:
            raise ValueError("SKIP: the subsystem has no Properties")
        content = props.find("md:Content", MD_NSMAP)
        if content is None:
            content = etree.SubElement(props, "{%s}Content" % MD_NS)
            insert_form_node_at(props, content, None, eol)
        item = etree.SubElement(content, "{%s}Item" % XR_NS)
        item.set("{%s}type" % XSI_NS, "xr:MDObjectRef")
        item.text = plan["ref"]
        insert_form_node_at(content, item, None, eol)
        return
    container = get_md_container(me, plan["parent"], plan["tag"])
    if container is None:
        why = ("tabular section %s is not in the configuration" % plan["parent"]) if plan["parent"] \
            else "ChildObjects is not in the configuration"
        raise ValueError("SKIP: " + why)
    node = copy.deepcopy(plan["node"])
    # Identifiers are new: a configuration's object must not share them with the extension's own one
    for n in node.iter():
        if isinstance(n.tag, str) and n.get("uuid"):
            n.set("uuid", str(uuid.uuid4()))
    # A new tabular section: its generated types are new and named after it
    for g in node.iter("{%s}GeneratedType" % XR_NS):
        for x in g:
            if isinstance(x.tag, str) and localname(x) in ("TypeId", "ValueId"):
                x.text = str(uuid.uuid4())
        gn = g.get("name")
        if gn:
            g.set("name", re.sub(r'[^.]+$', plan["target"]["name"], gn))
    nm_node = node.find("md:Properties/md:Name", MD_NSMAP)
    if nm_node is not None:
        nm_node.text = plan["target"]["name"]
    # Inner names of a copied subtree: a tabular section's own attributes lose the prefix too
    for x in node.iter("{%s}Name" % MD_NS):
        if x is nm_node or localname(x.getparent()) != "Properties":
            continue
        x.text = convert_ext_code([x.text or ""], {})[0]
    # The node is the configuration's own: the extension's belongings have no place here
    for x in (node.findall("md:Properties/md:ObjectBelonging", MD_NSMAP)
              + node.findall("md:Properties/md:ExtendedConfigurationObject", MD_NSMAP)):
        x.getparent().remove(x)
    refs = get_md_node_references(node, TRANSFER_PREFIX, True)
    if refs.get("status"):
        raise ValueError("SKIP: " + refs["reason"])
    plan["expected_references"] = refs["values"]
    ref = find_child_anchor(container, plan["tag"], plan["obj_type"])
    insert_form_node_at(container, node, ref, eol)


def get_md_target_element(obj_el, plan):
    """The config's element a property override belongs to: the object itself or a named child (inside
    the named tabular section when parent is given), None when the configuration has no such element."""
    if not plan["tag"]:
        return obj_el
    kids = obj_el.find("md:ChildObjects", MD_NSMAP)
    if kids is None:
        return None
    if plan["parent"]:
        ts = None
        for c in elem_children(kids):
            if localname(c) == "TabularSection" and md_child_name(c).lower() == plan["parent"].lower():
                ts = c
                break
        if ts is None:
            return None
        kids = ts.find("md:ChildObjects", MD_NSMAP)
        if kids is None:
            return None
    for c in elem_children(kids):
        if localname(c) == plan["tag"] and md_child_name(c).lower() == plan["name"].lower():
            return c
    return None


def set_md_scalar_prop(p, plan):
    """One scalar property of the configuration's existing element takes the extension's value."""
    for a in list(p.attrib):
        if a.startswith("{%s}" % XSI_NS) and a.rsplit("}", 1)[-1] in ("type", "nil"):
            del p.attrib[a]
    if plan.get("nil"):
        p.set("{%s}nil" % XSI_NS, "true")
    elif plan.get("xml_type"):
        p.set("{%s}type" % XSI_NS, plan["xml_type"])
    for c in list(p):
        p.remove(c)
    p.text = convert_ext_code([plan.get("value") or ""], {})[0]
    plan["expected_key"] = cmp_key(p, "")


def add_md_type_extends(props, plan, eol):
    """Missing types of the extension's ExtendValue parts merged into the configuration's <Type>: the
    type entries keep their order, the qualifiers follow by kind; the element stays a plain <Type>."""
    type_el = get_md_prop_node(props, "Type")
    if type_el is None:
        raise ValueError("SKIP: the element has no Type in the configuration")
    src_type = plan.get("node")
    if src_type is None:
        raise ValueError("SKIP: the type is not found in the extension")
    # Declared parts converted to the configuration's names
    ex = {"types": [], "quals": {}}
    for part in elem_children(src_type):
        if localname(part) != "ExtendValue":
            continue
        for c in elem_children(part):
            if localname(c) in ("Type", "TypeSet"):
                ref = resolve_md_reference(inner_text(c).strip(), TRANSFER_PREFIX, True)
                if ref.get("status"):
                    raise ValueError("SKIP: " + ref["reason"])
                val = ref["value"]
                ex["types"].append({"local": localname(c), "value": val,
                                    "key": get_md_type_entry_key(localname(c), val, ""), "node": c})
            elif localname(c).endswith("Qualifiers"):
                ex["quals"].setdefault(localname(c), c)
    if not ex["types"]:
        return
    cfg_model = get_md_type_model(type_el, "")
    why = get_md_type_merge_conflict(cfg_model, ex)
    if why:
        raise ValueError("SKIP: " + why)
    new = etree.Element("{%s}Type" % MD_NS)
    new.tail = type_el.tail
    type_el.getparent().replace(type_el, new)
    existing = []
    existing_quals = {}
    for c in list(type_el):
        if not isinstance(c.tag, str):
            continue
        if localname(c) in ("Type", "TypeSet", "TypeId"):
            existing.append(c)
        elif localname(c).endswith("Qualifiers"):
            existing_quals[localname(c)] = c
    have = {}
    for c in existing:
        insert_form_node_at(new, c, None, eol)
        have[get_md_type_entry_key(localname(c), inner_text(c), "")] = True
    need = []
    for t in ex["types"]:
        if t["key"] in have:
            continue
        n = copy.deepcopy(t["node"])
        for ch in list(n):
            n.remove(ch)
        n.text = t["value"]
        insert_form_node_at(new, n, None, eol)
        have[t["key"]] = True
        k = get_md_type_qual_kind(t)
        if k and k not in need:
            need.append(k)
    for k in md_qual_order:
        if k in existing_quals:
            insert_form_node_at(new, existing_quals[k], None, eol)
            continue
        if k in need and k in ex["quals"]:
            q = copy.deepcopy(ex["quals"][k])
            insert_form_node_at(new, q, None, eol)
            # The source qualifier sat deeper (inside ExtendValue): its children are re-indented for <Type>
            set_form_subtree_indent(q, eol, get_form_depth(q))
    for k in existing_quals:
        if k not in md_qual_order:
            insert_form_node_at(new, existing_quals[k], None, eol)
    plan["expected_model"] = ex


def apply_md_prop_op(me, plan):
    """An override of one property of the configuration's existing element: the element keeps its uuid
    and name, only the declared value (or the missing type entries) is written."""
    root = me["fw"]["root"]
    obj_el = get_md_object_element(root)
    if obj_el is None:
        raise ValueError("SKIP: the object is not in the configuration")
    target = get_md_target_element(obj_el, plan)
    if target is None:
        why = ("the element %s %s is not in the configuration" % (plan["tag"], plan["name"])) if plan["tag"] \
            else "the object is not in the configuration"
        raise ValueError("SKIP: " + why)
    props = get_md_props_element(target)
    if props is None:
        raise ValueError("SKIP: the element has no Properties in the configuration")
    if plan["mode"] == "TypeExtend":
        add_md_type_extends(props, plan, me["fw"]["eol"])
        return
    p = get_md_prop_node(props, plan["prop"])
    if p is None:
        raise ValueError("SKIP: property %s is not in the configuration" % plan["prop"])
    set_md_scalar_prop(p, plan)


def get_md_validate_errors(path, obj_type, require_result=False):
    """Errors of the metadata validator (meta-validate for an object, subsystem-validate for a subsystem)."""
    here = os.path.dirname(os.path.abspath(__file__))
    rel = {"Subsystem": "../../subsystem-validate/scripts/subsystem-validate.py",
           "Role": "../../role-validate/scripts/role-validate.py"}.get(obj_type, "../../meta-validate/scripts/meta-validate.py")
    script = os.path.normpath(os.path.join(here, rel))
    if not os.path.exists(script):
        globals()["MD_VALIDATE_MISSING"] = True
        return ["metadata validator is not installed"] if require_result else []
    validator_args = {"Subsystem": ["-SubsystemPath", path],
                      "Role": ["-RightsPath", os.path.splitext(path)[0], "-MaxErrors", str(2**31 - 1)]
                      }.get(obj_type, ["-ObjectPath", path])
    try:
        result = subprocess.run([sys.executable, script, *validator_args], capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
    except Exception as exc:
        return ["metadata validator did not complete: " + str(exc)] if require_result else []
    errs = []
    lines = result.stdout.splitlines()
    for line in lines:
        if "[ERROR]" in line:
            errs.append(re.sub(r'\s+', ' ', line.split("[ERROR]", 1)[1]).strip())
    complete = any(line.startswith(("=== Validation OK:", "=== Result:")) for line in lines)
    if require_result and (not complete or result.returncode not in (0, 1) or (result.returncode == 1 and not errs)):
        return ["metadata validator did not complete (exit %d)" % result.returncode]
    return errs


def test_md_write(me, tmp):
    """The written file read back the same way the check reads it: every planned node is in place with the
    type the extension has, and the validator sees no error the configuration's file did not have."""
    try:
        save_form_write(me["fw"], tmp)
        before = get_md_validate_errors(me["path"], me["obj_type"], require_result=True)
        after = get_md_validate_errors(tmp, me["obj_type"], require_result=True)
        added = [x for x in before + after if x.startswith("metadata validator")]
        added.extend(x for x in after if x not in before)
        if added:
            return ["validator: " + added[0]]
        doc = read_form_write(tmp)
        root = doc["root"]
        obj_el = get_md_object_element(root)
        miss = []
        for op in me["ops"]:
            pl = op["plan"]
            if pl["kind"] == "md-content":
                content = obj_el.find("md:Properties/md:Content", MD_NSMAP) if obj_el is not None else None
                found = False
                if content is not None:
                    for i in elem_children(content):
                        if localname(i) == "Item" and inner_text(i).strip().lower() == pl["ref"].lower():
                            found = True
                            break
                if not found:
                    miss.append(op["item"]["text"])
                continue
            if pl["kind"] == "md-prop":
                target = get_md_target_element(obj_el, pl) if obj_el is not None else None
                props = get_md_props_element(target)
                bad = target is None
                if not bad:
                    if pl["mode"] == "TypeExtend":
                        type_el = get_md_prop_node(props, "Type")
                        bad = type_el is None or not test_md_type_model_includes(get_md_type_model(type_el, ""), pl["expected_model"])
                    else:
                        p = get_md_prop_node(props, pl["prop"])
                        bad = p is None or cmp_key(p, "") != pl["expected_key"]
                if bad:
                    miss.append(op["item"]["text"])
                continue
            container = None
            node = None
            if obj_el is not None:
                if pl["parent"]:
                    kids = obj_el.find("md:ChildObjects", MD_NSMAP)
                    if kids is not None:
                        for c in elem_children(kids):
                            if localname(c) == "TabularSection" and md_child_name(c).lower() == pl["parent"].lower():
                                container = c.find("md:ChildObjects", MD_NSMAP)
                                break
                else:
                    container = obj_el.find("md:ChildObjects", MD_NSMAP)
            if container is not None:
                for c in elem_children(container):
                    if localname(c) == pl["tag"] and md_child_name(c).lower() == pl["target"]["name"].lower():
                        node = c
                        break
            bad = node is None
            if not bad and pl["type_key"]:
                bad = md_type_key(node, "").lower() != pl["type_key"].lower()
            if not bad:
                bad = get_md_node_references(node, "", False)["values"] != pl["expected_references"]
            if not bad and pl["tag"] == "TabularSection" and pl.get("child_names"):
                sub = node.find("md:ChildObjects", MD_NSMAP)
                have = [md_child_name(x) for x in elem_children(sub)] if sub is not None else []
                for n in pl["child_names"]:
                    if not find_name_in(have, n, TRANSFER_PREFIX):
                        bad = True
                        break
            if bad:
                miss.append(op["item"]["text"])
        return miss
    except Exception as exc:
        return [str(exc)]


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
FORM_EDITS = {}
MD_EDITS = {}
MD_GIVEN = {}
MD_WARN = []
MD_REFERENCE_POOLS = None
MD_REFERENCE_ROOT = ""
EDIT_SEQ = [0]
CONFIG_REF_MAP = {}

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
    for t in get_code_only(lines):
        for m in CALL_RE.finditer(t):
            k = m.group(1).lower()
            if k not in sk:
                res.add(k)
    return res


BSL_CATALOG = {}
BSL_COMMON = {}
BSL_GLOBALS = {}
BSL_GLOBAL_OWNERS = []
BSL_GLOBAL_NAMES = set()
BSL_CFG_COMMON_NAMES = {}
BSL_CONFIG_PATH = ""
BSL_CONTEXT = None
BSL_LITERAL_PATTERN = r'"(?:""|[^"\r\n])*(?:\r?\n[\t ]*(?:\|(?:""|[^"\r\n])*|//[^\r\n]*|(?=\r?\n|$)))*(?:"|(?=\r?\n|$))'
BSL_TOKEN_RE = re.compile(r'//[^\r\n]*|' + BSL_LITERAL_PATTERN + r'|\w+|\s+|[^\w\s]')


def bsl_tokens(lines):
    for m in BSL_TOKEN_RE.finditer("\n".join(lines)):
        v = m.group()
        kind = "comment" if v.startswith("//") else "string" if v.startswith('"') and len(v) >= 2 and v.endswith('"') else "fragment" if v.startswith('"') else "word" if re.fullmatch(r'\w+', v) else "punct"
        yield {"kind": kind, "value": v, "start": m.start(), "length": len(v)}


def initialize_bsl_catalog(ext_dir, config_path, prefix):
    global BSL_CONFIG_PATH
    BSL_CONFIG_PATH = config_path
    BSL_GLOBAL_NAMES.clear()
    BSL_CFG_COMMON_NAMES.clear()
    global BSL_CONTEXT
    BSL_CATALOG.clear(); BSL_COMMON.clear(); BSL_GLOBALS.clear(); BSL_GLOBAL_OWNERS.clear(); BSL_CONTEXT = None
    for directory, dirs, files in os.walk(ext_dir):
        dirs.sort()
        for filename in sorted(files):
            if not filename.lower().endswith('.bsl'):
                continue
            path = os.path.join(directory, filename)
            rel = rel_path(ext_dir, path)
            cfg = os.path.join(config_path, rel)
            match_root = re.match(r"^CommonModules[/\\]([^/\\]+)[/\\]Ext[/\\]Module\.bsl$", rel, re.I)
            root_id = ("CommonModule." + match_root[1]).lower() if match_root else ""
            own_root = root_id in ROOT_OWN
            if own_root and root_id in ROOT_BINDINGS:
                cfg = os.path.join(config_path, root_object_paths("CommonModule", ROOT_BINDINGS[root_id])["bsl"])
            el, cl = read_bsl_lines(path), read_bsl_lines(cfg)
            kind = get_module_kind(rel)
            ctx = {"rel": rel, "ext": el, "cfg": cl, "kind": kind, "methods": {}, "attrs": {}, "data_attrs": {}, "form_names": {}, "names": {}}
            BSL_CATALOG[rel.lower()] = ctx
            cn, en = get_proc_names(cl or []), get_proc_names(el)
            taken = {n.lower() for n in cn} | get_called_names((cl or []) + el, en)
            intercept_names = set()
            for ic in get_interceptors(el):
                declaration = find_decl_after(el, ic['line'])
                if declaration:
                    intercept_names.add(declaration['name'].lower())
            for d in get_proc_decls(el):
                n = d['name']
                if n.lower() in intercept_names:
                    continue
                if own_root:
                    ctx["methods"][n.lower()] = n
                    ctx["names"][n.lower()] = n
                    continue
                hits = find_names_in(cn, n, prefix)
                hit = None
                em = get_method_safe(el, n)
                for h in hits:
                    cm = get_method_safe(cl, h)
                    if cm and not own_declaration_difference(el, em, cl, cm) and sig_lines(cm['body_lines'], prefix) == sig_lines(em['body_lines'], prefix):
                        hit = h; break
                hit = hit or (hits[0] if hits else None)
                target = hit or get_target_name(n, prefix, taken, False)['name']
                ctx['methods'][n.lower()] = target; ctx['names'][n.lower()] = n
                taken.add(target.lower())
            match = re.match(r'^CommonModules[/\\]([^/\\]+)', rel, re.I)
            if kind == 'common' and match:
                BSL_COMMON[match[1].lower()] = ctx
            for v in get_module_layout(el)['vars']:
                for n in v['names']:
                    ctx['attrs'][n.lower()] = remove_ext_prefix(n, prefix); ctx['names'][n.lower()] = n
            if kind == 'form':
                ef = re.sub(r'[/\\]Form[/\\]Module\.bsl$', '/Form.xml', path, flags=re.I)
                cf = re.sub(r'[/\\]Form[/\\]Module\.bsl$', '/Form.xml', cfg, flags=re.I)
                ed, cd = read_form_doc(ef), read_form_doc(cf)
                if ed is not None and cd is not None:
                    fm = get_form_name_map(ed, cd, prefix)
                    attribute_targets = get_form_attribute_targets(ed, cd, prefix, cl)
                    cfg_names2 = [x.get('name') for x in cd.iter() if x.get('name')]
                    ext_attrs = section_map(ed, "Attributes", "Attribute")
                    cfg_attrs = section_map(cd, "Attributes", "Attribute")
                    cfg_attr_names = [name for name, _ in cfg_attrs.values()]
                    ambiguous_attrs = {}
                    for name, _ in ext_attrs.values():
                        matches = find_scoped_form_names(cfg_attr_names, name, prefix, ext_attrs)
                        if len(matches) > 1 and matches[0].lower() != name.lower():
                            ambiguous_attrs[name.lower()] = ", ".join(matches)
                    ctx["ambiguous_form_attrs"] = ambiguous_attrs
                    for k2 in list(fm):
                        hit2 = find_name_in(cfg_names2, k2, prefix)
                        if hit2:
                            fm[k2] = hit2
                    ctx['form_names'] = fm
                    for x in ed.findall('{*}Attributes/{*}Attribute'):
                        if localname(x) != 'Attribute':
                            continue
                        n = x.get('name', '')
                        if n:
                            ctx['attrs'][n.lower()] = attribute_targets.get(n.lower(), remove_ext_prefix(n, prefix)); ctx['names'][n.lower()] = n
            match = re.match(r'^([^/\\]+)[/\\]([^/\\]+)[/\\]', rel)
            if match:
                md_rel = '%s/%s.xml' % (match[1], match[2])
                ed, cd = read_md_object(os.path.join(ext_dir, md_rel)), read_md_object(os.path.join(config_path, md_rel))
                if ed and ed['children'] is not None:
                    cfg_names = [md_child_name(x) for x in elem_children(cd['children'])] if cd and cd['children'] is not None else []
                    for x in elem_children(ed['children']):
                        if localname(x) not in ('Attribute', 'TabularSection'):
                            continue
                        n = md_child_name(x)
                        if not n:
                            continue
                        target = find_name_in(cfg_names, n, prefix) or remove_ext_prefix(n, prefix)
                        ctx['data_attrs'][n.lower()] = target; ctx['names'][n.lower()] = n
                        if kind != 'form':
                            ctx['attrs'][n.lower()] = target
    cp = read_configuration_props(ext_dir)
    cfg_props = read_configuration_props(config_path)
    if cp['child_objects'] is not None:
        for x in elem_children(cp['child_objects']):
            n = (x.text or '').strip()
            pool = [(c.text or '').strip() for c in elem_children(cfg_props['child_objects']) if localname(c) == localname(x)] if cfg_props['child_objects'] is not None else []
            BSL_GLOBALS[n.lower()] = ROOT_BINDINGS.get((localname(x) + "." + n).lower()) or find_name_in(pool, n, prefix) or remove_ext_prefix(n, prefix)

    global_paths = {}
    for root2 in (config_path, ext_dir):
        directory = os.path.join(root2, 'CommonModules')
        if not os.path.isdir(directory):
            continue
        for filename in sorted(os.listdir(directory)):
            if not filename.lower().endswith('.xml'):
                continue
            if root2 == config_path:
                BSL_CFG_COMMON_NAMES[filename[:-4].lower()] = filename[:-4]
            md = read_md_object(os.path.join(directory, filename))
            if not md or md['props'] is None:
                continue
            glob = md['props'].find('{*}Global')
            if glob is not None and (glob.text or '').lower() == 'true':
                rel2 = 'CommonModules/%s/Ext/Module.bsl' % filename[:-4]
                global_paths[rel2.lower()] = rel2
    for rel2 in global_paths.values():
        gc = BSL_CATALOG.get(rel2.lower())
        if gc is None:
            gc = {'rel': rel2, 'kind': 'common', 'methods': {}, 'ext': [], 'cfg': read_bsl_lines(os.path.join(config_path, rel2))}
        BSL_GLOBAL_OWNERS.append(gc)
    for rel2 in ('Ext/ManagedApplicationModule.bsl', 'Ext/OrdinaryApplicationModule.bsl'):
        ac = BSL_CATALOG.get(rel2.lower())
        acl = read_bsl_lines(os.path.join(config_path, rel2))
        if ac is not None or acl is not None:
            BSL_GLOBAL_OWNERS.append({'rel': rel2, 'kind': 'application',
                                      'methods': ac['methods'] if ac else {},
                                      'ext': ac['ext'] if ac else [], 'cfg': acl})
    for owner in BSL_GLOBAL_OWNERS:
        BSL_GLOBAL_NAMES.update(name.lower() for lines in (owner["ext"], owner["cfg"])
                                for name in get_proc_names(lines or []))
    api_re = re.compile(r'(ОписаниеОповещения|CallbackDescription|NotifyDescription|ОбработчикОжидания|IdleHandler|УстановитьДействие|SetAction|РеквизитФормыВЗначение|FormAttributeToValue)\s*\(', re.I)
    for _ in range(len(BSL_CATALOG) + 1):
        changed = False
        for ctx2 in BSL_CATALOG.values():
            BSL_CONTEXT = ctx2
            for k2 in list(ctx2['methods']):
                n2 = ctx2['names'][k2]
                em2 = get_method_safe(ctx2['ext'], n2)
                if not em2 or not api_re.search('\n'.join(em2['body_lines'])):
                    continue
                old, found = ctx2['methods'][k2], None
                for hit in find_names_in(get_proc_names(ctx2['cfg'] or []), n2, prefix):
                    ctx2['methods'][k2] = hit
                    cm2 = get_method_safe(ctx2['cfg'], hit)
                    if cm2 and not own_declaration_difference(ctx2['ext'], em2, ctx2['cfg'], cm2) and sig_lines(protect_bsl_parameter_members(convert_bsl_code(em2['body_lines'], {}, em2['param_names']), em2['param_names']), prefix) == sig_lines(protect_bsl_parameter_members(cm2['body_lines'], cm2['param_names']), prefix):
                        found = hit; break
                ctx2['methods'][k2] = found or old
                changed |= found is not None and found != old
        if not changed:
            break
    BSL_CONTEXT = None


def get_bsl_global_references(name):
    result, k = [], name.lower()
    for gc in BSL_GLOBAL_OWNERS:
        em = get_method_safe(gc['ext'], name)
        if em and is_export(gc['ext'], em) and k in gc['methods']:
            target = gc['methods'][k]
            if gc['kind'] == 'application' and not get_method_safe(gc['cfg'], target):
                target = name
            result.append({'target': target, 'context': gc})
        cm = get_method_safe(gc['cfg'], name)
        if cm and is_export(gc['cfg'], cm):
            result.append({'target': name, 'context': gc})
    return result


def set_bsl_context(rel):
    global BSL_CONTEXT
    BSL_CONTEXT = BSL_CATALOG.get(rel.lower())


def get_bsl_owner(owner, ctx):
    k = owner.strip().lower()
    if len(k) >= 2 and k.startswith('"') and k.endswith('"'):
        k = k[1:-1]
    else:
        k = re.sub(r'\s+', '', k)
    if not k:
        return ctx
    if k in ('этаформа', 'thisform') and ctx and ctx['kind'] == 'form':
        return ctx
    if k in ('этотобъект', 'thisobject') and ctx and ctx['kind'] in ('form', 'object'):
        return ctx
    return BSL_COMMON.get(k)


def get_bsl_arguments(tokens, opening):
    args, part, depth = [], [], 0
    for j in range(opening + 1, len(tokens)):
        v = tokens[j]['value']
        if tokens[j]['kind'] == 'punct':
            if v in ('(', '['):
                depth += 1
            elif v in (')', ']'):
                if depth == 0:
                    args.append(part); break
                depth -= 1
            elif v == ',' and depth == 0:
                args.append(part); part = []; continue
        part.append(j)
    return args


def get_bsl_conversion(lines, file_map, ctx, params=(), comparison=False):
    params = {name.lower() for name in params}
    all_tokens = list(bsl_tokens(lines))
    ts = [t for t in all_tokens if t['kind'] != 'comment' and not t['value'].isspace()]
    edits, handled, issues, warnings, references = {}, set(), [], [], []
    methods = dict(ctx['methods']) if ctx else {}
    methods.update(file_map)
    attrs = ctx['attrs'] if ctx else {}
    if not comparison and (CATALOG_CHILDREN or ROOT_OWN or BORROWED_PREDEFINED_BINDINGS):
        if ctx and "declared_methods" not in ctx:
            ctx["declared_methods"] = get_proc_names(ctx["ext"])
        child_edits, child_issues = get_catalog_child_bsl(ts, ctx['rel'] if ctx else '', None,
                                                        ctx["declared_methods"] if ctx else (), TRANSFER_PREFIX)
        edits.update(child_edits)
        handled.update(child_edits)
        issues.extend(child_issues)
        option_edits, option_issues = get_functional_option_bsl(ts, ctx["declared_methods"] if ctx else (), TRANSFER_PREFIX)
        edits.update(option_edits)
        handled.update(option_edits)
        issues.extend(option_issues)
    locals_ = None
    for i, t in enumerate(ts):
        if t['kind'] != 'word':
            continue
        k, owner = t['value'].lower(), ''
        qualified = i > 0 and ts[i - 1]['value'] == '.'
        if (not comparison and not qualified
                and k in DIRECT_MD_COLLECTIONS
                and i + 2 < len(ts) and ts[i+1]["value"] == "." and ts[i+2]["kind"] == "word" and k not in params):
            kind = ROOT_BSL_COLLECTIONS[k]
            oid = kind + "." + ts[i+2]["value"]
            if oid.lower() in ROOT_OWN:
                if locals_ is None:
                    locals_ = get_local_names(get_code_only(lines), params)
                if k not in locals_:
                    ref = resolve_md_reference(oid, TRANSFER_PREFIX)
                    if ref.get("status"):
                        issues.append({"token": t, "rename": oid, "why": ref["reason"], "status": ref["status"]})
                    else:
                        edits[ts[i+2]["start"]] = ref["value"].split(".")[1]
        predefined_path = borrowed_predefined_access(ts, i) if not comparison and k not in params else None
        if predefined_path:
            if locals_ is None:
                locals_ = get_local_names(get_code_only(lines), params)
            if k not in locals_:
                binding = BORROWED_PREDEFINED_BINDINGS[predefined_path.lower()]
                member = ts[i+4]
                if binding.get("status"):
                    issues.append(dict(binding, token=member, rename=predefined_path, why=binding["reason"]))
                else:
                    edits[member["start"]] = binding["name"]
                handled.add(member["start"])
        if (not comparison and not qualified and k in ("перечисления", "enums") and i + 4 < len(ts)
                and ts[i+1]["value"] == "." and ts[i+3]["value"] == "." and ts[i+2]["kind"] == ts[i+4]["kind"] == "word"
                and (i + 5 >= len(ts) or ts[i+5]["value"] != "(") and k not in params
                and ("enum." + ts[i+2]["value"].lower()) in ROOT_OWN):
            if locals_ is None:
                locals_ = get_local_names(get_code_only(lines), params)
            if k not in locals_:
                path = "Enum." + ts[i+2]["value"] + ".EnumValue." + ts[i+4]["value"]
                ref = resolve_md_reference(path, TRANSFER_PREFIX)
                if ref.get("status"):
                    issues.append({"token": t, "rename": path, "why": ref["reason"], "status": ref["status"]})
                else:
                    parts = ref["value"].split(".")
                    edits[ts[i+2]["start"]] = parts[1]
                    edits[ts[i+4]["start"]] = parts[3]
        if qualified:
            a = i - 2
            while a > 1 and ts[a - 1]['value'] == '.' and ts[a - 2]['kind'] == 'word':
                a -= 2
            owner = ''.join(x['value'] for x in ts[a:i - 1])
        receiver = owner.split('.', 1)[0].lower()
        if qualified and receiver in params:
            if comparison and receiver in BSL_COMMON:
                edits[t['start']] = '~' + k.encode('utf-16-le').hex() + '~'
            continue
        oc = get_bsl_owner(owner, ctx) if not comparison else None
        if qualified and oc and oc is not ctx:
            if locals_ is None:
                locals_ = get_local_names(get_code_only(lines), params)
            if owner.lower() in locals_:
                oc = None
        om = methods if oc is ctx and oc else oc['methods'] if oc else {}
        is_call = i + 1 < len(ts) and ts[i + 1]['value'] == '('
        is_ctor = i > 0 and ts[i - 1]['value'].lower() in ('новый', 'new')
        if comparison or (not qualified and not is_call and k in params):
            continue
        ambiguous = ctx.get("ambiguous_form_attrs", {}) if ctx and (not qualified or oc is ctx) else {}
        if not is_call and k in ambiguous:
            issues.append({"token": t, "rename": "%s -> %s" % (t["value"], ambiguous[k]),
                           "why": "form attribute matches multiple target names"})
            continue
        if not is_ctor:
            if k in om and (is_call or not qualified):
                edits[t['start']] = om[k]
            elif not qualified and k in attrs:
                edits[t['start']] = attrs[k]
            elif qualified and not is_call and oc and k in oc.get('attrs', {}):
                edits[t['start']] = oc['attrs'][k]
            elif not qualified and i + 1 < len(ts) and ts[i + 1]['value'] == '.' and k in BSL_GLOBALS:
                edits[t['start']] = BSL_GLOBALS[k]
            elif qualified and ctx and owner.lower() in ('элементы', 'items', 'команды', 'commands') and k in ctx['form_names']:
                edits[t['start']] = ctx['form_names'][k]
            elif qualified and ctx and owner.lower() in ('объект', 'object') and ctx['kind'] == 'form' and k in ctx['data_attrs']:
                edits[t['start']] = ctx['data_attrs'][k]
            elif qualified and not is_call and k in BSL_GLOBALS:
                edits[t['start']] = BSL_GLOBALS[k]
        if not is_call and ctx and ctx["kind"] == "form":
            form_item = (re.fullmatch(r'(?:(?:ЭтотОбъект|ЭтаФорма|ThisObject|ThisForm)\.)?(?:Элементы|Items|Команды|Commands)', owner, re.I)
                         if qualified else k in attrs)
            if form_item:
                references.append({"name": t["value"], "context": ctx, "kind": "form_item", "token": t})
        if not is_call:
            continue
        if not is_ctor:
            if qualified and oc:
                references.append({'name': t['value'], 'context': oc, 'kind': 'method', 'token': t})
            elif not qualified:
                refs = []
                if k not in om and k in BSL_GLOBAL_NAMES and not get_method_safe(ctx.get('cfg') if ctx else None, t['value']):
                    refs = get_bsl_global_references(t['value'])
                for ref in refs:
                    references.append({'name': t['value'], 'context': ref['context'], 'kind': 'method', 'token': t})
                if len(refs) == 1 and refs[0]['target'] != t['value']:
                    edits[t['start']] = refs[0]['target']
                if not refs:
                    references.append({'name': t['value'], 'context': ctx, 'kind': 'method', 'token': t})
        if not is_ctor and (k in om or (qualified and oc and oc['kind'] == 'common')):
            continue
        specs = []
        if k in ('описаниеоповещения', 'notifydescription', 'callbackdescription'):
            if i == 0 or ts[i - 1]['value'].lower() not in ('новый', 'new'):
                continue
            specs = [(0, 1, 'method'), (3, 4, 'method')]
        elif k in ('подключитьобработчикожидания', 'attachidlehandler', 'отключитьобработчикожидания', 'detachidlehandler'):
            specs = [(0, -1, 'method')]
        elif k in ('установитьдействие', 'setaction'):
            specs = [(1, -1, 'method')]
        elif k in ('реквизитформывзначение', 'formattributetovalue'):
            specs = [(0, -1, 'attribute')]
        if not specs:
            continue
        args = get_bsl_arguments(ts, i + 1)
        if k in ('setaction', 'установитьдействие') and args and len(args[0]) == 1:
            handled.add(ts[args[0][0]]['start'])
        for arg, owner_arg, ref_kind in specs:
            if len(args) <= arg or len(args[arg]) != 1:
                continue
            st = ts[args[arg][0]]
            if st['kind'] != 'string':
                continue
            value = st['value'][1:-1].replace('""', '"'); sk = value.lower()
            ref_owner = owner
            if owner_arg >= 0:
                ref_owner = ''.join(ts[j]['value'] for j in args[owner_arg]) if len(args) > owner_arg else '?'
            rc = get_bsl_owner(ref_owner, ctx) if ref_owner.lower() not in params else None
            if owner_arg >= 0 and rc and len(args) > owner_arg and len(args[owner_arg]) == 1:
                mt = ts[args[owner_arg][0]]
                if mt['kind'] == 'string':
                    mk = mt['value'][1:-1].lower()
                    handled.add(mt['start'])
                    if mk in BSL_GLOBALS:
                        edits[mt['start']] = '"' + BSL_GLOBALS[mk] + '"'
            if k in ('setaction', 'установитьдействие') and ctx and ctx['kind'] == 'form' and re.match(r'^(Элементы|Items)\.', ref_owner, re.I):
                rc = ctx
            if k in ('attachidlehandler', 'detachidlehandler', 'подключитьобработчикожидания', 'отключитьобработчикожидания') and not qualified and ctx and ctx['kind'] != 'form':
                gs = get_bsl_global_references(value)
                targets = {g['target'].lower(): g['target'] for g in gs}
                handled.add(st['start'])
                if len(targets) == 1:
                    edits[st['start']] = '"' + next(iter(targets.values())) + '"'
                    references += [{'name': value, 'context': gr['context'], 'kind': 'method', 'token': st} for gr in gs]
                elif len(targets) > 1:
                    issues.append({'token': st, 'rename': value + ' -> ' + ', '.join(sorted(targets.values())), 'why': 'global handler resolves to different target names'})
                continue
            handled.add(st['start'])
            ambiguous = rc.get("ambiguous_form_attrs", {}) if rc and ref_kind == "attribute" else {}
            if sk in ambiguous:
                issues.append({"token": st, "rename": "%s -> %s" % (value, ambiguous[sk]),
                               "why": "form attribute matches multiple target names"})
                continue
            rm = (rc['attrs'] if rc and rc['kind'] == 'form' else {}) if ref_kind == 'attribute' else methods if rc is ctx and rc else rc['methods'] if rc else {}
            if sk in rm:
                edits[st['start']] = '"' + rm[sk].replace('"', '""') + '"'
                references.append({'name': value, 'context': rc, 'kind': ref_kind, 'token': st})
            elif rc is None:
                matches = set()
                for c in BSL_CATALOG.values():
                    mm = c['attrs'] if ref_kind == 'attribute' else c['methods']
                    if sk in mm and mm[sk].lower() != sk:
                        matches.add('%s -> %s' % (value, mm[sk]))
                if matches:
                    issues.append({'token': st, 'rename': ', '.join(sorted(matches)), 'why': 'handler owner is unknown; the current module map cannot be used'})
    for t in ts:
        if t['kind'] != 'string' or t['start'] in handled:
            continue
        value = t['value'][1:-1].replace('""', '"'); k = value.lower()
        for mapping, kind in ((methods, 'method'), (attrs, 'attribute')):
            maps = [mapping] + [c['methods'] if kind == 'method' else c['attrs'] for c in BSL_CATALOG.values()]
            renames = {m[k].lower(): '%s -> %s' % (value, m[k]) for m in maps if k in m and m[k].lower() != k}
            if renames:
                warnings.append({'token': t, 'kind': kind, 'rename': ', '.join(sorted(renames.values()))})
    text = ''.join(edits.get(t['start'], t['value']) for t in all_tokens)
    return {'lines': text.split('\n'), 'issues': issues, 'warnings': warnings, 'references': references}


def convert_bsl_code(lines, file_map, params=()):
    return get_bsl_conversion(lines, file_map, BSL_CONTEXT, params)['lines']


def protect_bsl_parameter_members(lines, params):
    # Protect member names of shadowing parameters only in comparison keys.
    if any(name.lower() in BSL_COMMON for name in params):
        return get_bsl_conversion(lines, {}, None, params, comparison=True)['lines']
    return lines


def get_control_projection(body, file_map, prefix, params=()):
    desired, source, ranges, op_index, i = [], [], {}, -1, 0
    while i < len(body):
        kind = bsl_marker_kind(body[i])
        if kind in ('Insert', 'Delete'):
            op_index += 1; i += 1; start = len(desired)
            end_kind = 'EndInsert' if kind == 'Insert' else 'EndDelete'
            while i < len(body) and bsl_marker_kind(body[i]) != end_kind:
                if kind == 'Insert':
                    desired.append(body[i]); source.append(i)
                i += 1
            ranges[op_index] = (start, len(desired)); i += 1
        else:
            desired.append(body[i]); source.append(i); i += 1
    converted = convert_bsl_code(desired, file_map, params)
    keys = code_keys(converted, prefix, params=params)
    return {'desired': desired, 'source': source, 'ranges': ranges,
            'payloads': {k: converted[a:b] for k, (a, b) in ranges.items()},
            'payload_keys': {k: keys[a:b] for k, (a, b) in ranges.items()}, 'keys': keys}


def get_bsl_plan_issue(plan):
    if not plan:
        return None
    methods = [plan['ext_m']] if plan.get('ext_m') else []
    methods += [h['ext_m'] for h in plan.get('handlers', []) if h.get('ext_m')]
    allowed = None
    if plan['kind'] == 'topcode':
        methods.append({'body_lines': plan['ext_lines'], 'sig_end_idx': -1})
        allowed = get_top_code_keys(plan['ext_lines'], TRANSFER_PREFIX)
    for m in methods:
        lines, source_map = m['body_lines'], None
        if plan['kind'] == 'control':
            projection = get_control_projection(lines, {}, TRANSFER_PREFIX, m.get('param_names', ()))
            lines, source_map = projection['desired'], projection['source']
        bc = get_bsl_conversion(lines, {}, BSL_CONTEXT, m.get('param_names', ()))
        for issue in bc['issues']:
            offset = '\n'.join(lines)[:issue['token']['start']].count('\n')
            if allowed is not None and offset not in allowed:
                continue
            if source_map is not None:
                offset = source_map[offset]
            return {'method': m, 'issue': issue, 'offset': offset}
    return None


def get_bsl_manual_details(plan, problem):
    m, issue = problem['method'], problem['issue']
    offset = problem['offset']
    if issue.get("status") == "WAITING":
        return ['from: extension %s:%d' % (plan['rel'], m['sig_end_idx'] + 2 + offset),
                'next: transfer the dependency, then re-run -Mode transfer']
    return ['from: extension %s:%d' % (plan['rel'], m['sig_end_idx'] + 2 + offset),
            'code: ' + m['body_lines'][offset].strip(), 'rename: ' + issue['rename'],
            'next: resolve the handler context in the extension, or copy the complete method and verify its handler by hand; then re-run -Mode transfer']


def get_bsl_blocked_dependencies(plan, by_file, common, config_path, form_items=None):
    missing = dict(common)
    missing.update(by_file.get(os.path.abspath(os.path.join(config_path, plan['rel'])).lower(), {}))
    methods = [plan.get('ext_m')] + [h.get('ext_m') for h in plan.get('handlers', [])]
    deps = {dep for m in methods if m
            for dep in get_used_missing(m['body_lines'], missing, params=m['param_names'], form_items=form_items)}
    return sorted(deps, key=str.upper)


def add_blocked_form_handlers(plan, by_file, common, file_maps, config_path):
    module = os.path.abspath(os.path.join(config_path, plan["rel"]))
    file_map = file_maps.get(module.lower(), {})
    names = [plan["handler"]] if plan["kind"] == "event-bind" else [h["handler"] for h in plan["handlers"]]
    added = False
    for name in names:
        file_map.pop(name.lower(), None)
        if add_out_name(by_file, common, module, plan["rel"], name):
            added = True
    return added


def get_bsl_warning_report(records, config_path):
    result, seen = [], set()
    for rec in records:
        units = list(rec['items'])
        for it2 in rec['items']:
            for h2 in (it2.get('plan') or {}).get('handlers', []):
                if h2.get('ext_m'):
                    units.append({'status': it2['status'], 'plan': {'kind': 'own', 'rel': it2['plan']['rel'], 'ext_m': h2['ext_m'], 'name': h2['handler']}})
        for it in units:
            pl = it.get('plan')
            if not pl or (not pl.get('ext_m') and pl['kind'] != 'topcode') or not pl.get('rel'):
                continue
            ctx = BSL_CATALOG.get(pl['rel'].lower())
            if not ctx:
                continue
            key = (pl['rel'], pl['ext_m']['decl_idx'] if pl.get('ext_m') else None)
            if key in seen:
                continue
            seen.add(key)
            side, m, allowed = 'extension', pl.get('ext_m'), None
            if pl['kind'] == 'topcode':
                src2 = pl['ext_lines']
                if it['status'] == 'TRANSFERRED':
                    src2 = read_bsl_lines(os.path.join(config_path, pl['rel'])); side = 'config'
                m = {'body_lines': src2, 'sig_end_idx': -1}
                allowed = get_top_code_keys(src2, TRANSFER_PREFIX)
            if it['status'] == 'TRANSFERRED' and pl['kind'] != 'topcode':
                cl = read_bsl_lines(os.path.join(config_path, pl['rel']))
                if pl['kind'] == 'own':
                    name = ctx['methods'].get(pl['name'].lower(), '')
                elif pl.get('cfg_m'):
                    name = pl['cfg_m']['canonical']
                elif pl.get('handler'):
                    name = ctx['methods'].get(pl['handler'].lower(), '')
                else:
                    name = ''
                cm = get_method_safe(cl, name)
                if cm:
                    m, side = cm, 'config'
            bc = get_bsl_conversion(m['body_lines'], {}, ctx, m.get('param_names', ()))
            text = '\n'.join(m['body_lines'])
            for w in bc['warnings']:
                offset = text[:w['token']['start']].count('\n')
                line = m['sig_end_idx'] + 2 + offset
                if allowed is not None and line - 1 not in allowed:
                    continue
                result += ['[WARNING] string matches a renamed %s; left unchanged' % w['kind'],
                           '  to:   %s %s:%d' % (side, pl['rel'], line),
                           '  code: ' + m['body_lines'][offset].strip(),
                           '  rename: ' + w['rename'],
                           '  next: check whether the string refers to this ' + w['kind']]
    return ['Warnings: %d' % (len(result) // 5)] + result if result else []


def convert_ext_code(lines, file_map):
    """Legacy XML value conversion; BSL uses convert_bsl_code and its scoped symbol catalog."""
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


NOTIFY_RE = re.compile(r'(?:Новый|New)\s+(?:ОписаниеОповещения|NotifyDescription|CallbackDescription)\s*\(\s*"(\w+)"', re.IGNORECASE)


def get_notify_names(lines):
    """Procedures a module names in Новый ОписаниеОповещения("Имя", ...)."""
    res = set()
    for l in lines:
        for m in NOTIFY_RE.finditer(l):
            res.add(m.group(1).lower())
    return res


def is_export(lines, m):
    t = get_code_only([lines[m["sig_end_idx"]]], True)[0]
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


def resolve_method_conditions(lines, place, method):
    conditions = method_conditions(method["chain"])
    at = get_module_end(lines) if place.get("create") else place["at"]
    target = method_conditions(get_enclosing_chain(lines, at, method["lang"]))
    key = method_condition_key(conditions)
    target_key = method_condition_key(target)
    if target and target_key != key:
        at = get_module_end(lines)
        target = method_conditions(get_enclosing_chain(lines, at, method["lang"]))
        target_key = method_condition_key(target)
        if target and target_key != key:
            # Look before the guard of the first statement, without crossing an existing method.
            after_methods = get_module_layout(lines)["after_methods"]
            whole_module_guard = get_module_tail(lines) < len(lines)
            for i in range(at - 1, after_methods - 1, -1):
                if not re.match(r'^\s*#\s*(?:Если|If|ИначеЕсли|ElsIf|Иначе|Else)\b', lines[i], re.I):
                    continue
                scope = method_conditions(get_enclosing_chain(lines, i, method["lang"]))
                scope_key = method_condition_key(scope)
                if (scope and scope_key == key) or (not scope and not whole_module_guard):
                    at, target_key = i, scope_key
                    break
            else:
                return None
        place = {"at": at, "region": ""}
    if target_key == key:
        place.update(guards=[], guard_key="")
    else:
        place.update(guards=conditions, guard_key=key)
    return place


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
        return re.match(r'^\s*#\s*(' + words + r')(?!\w)', t, re.I) is not None

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


def read_bsl_file(path, track_content=False):
    """A .bsl file read for writing back as it was: BOM, line breaks, final line break."""
    data = open(path, "rb").read()
    bom = data[:3] == b"\xef\xbb\xbf"
    text = data[3:].decode("utf-8", "replace") if bom else data.decode("utf-8", "replace")
    eol = "\r\n" if "\r\n" in text else ("\n" if "\n" in text else "\r\n")
    final = text.endswith("\n") or text.endswith("\r")
    lines = re.split(r'\r\n|\n|\r', text) if text != "" else []
    if final and lines:
        lines = lines[:-1]
    result = {"path": path, "lines": lines, "bom": bom, "eol": eol, "final": final}
    if track_content:
        result["digest"] = hashlib.sha256(data).digest()
    return result


def write_bsl_file(f, lines, path=None):
    text = f["eol"].join(lines)
    if f["final"]:
        text += f["eol"]
    with open(path or f["path"], "wb") as fh:
        fh.write((b"\xef\xbb\xbf" if f["bom"] else b"") + text.encode("utf-8"))


def get_indent(line):
    m = re.match(r'^(\s*)', line)
    return m.group(1) if m else ""


def get_control_body(cfg_m, plan, frame, deletion, file_map, ext_m):
    projection = get_control_projection(ext_m['body_lines'], file_map, TRANSFER_PREFIX, ext_m['param_names'])
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
        lines = projection['payloads'][op['source_index']]
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
    if not lines:
        return []
    source, parts, pos = '\n'.join(lines), [], 0
    for match in re.finditer(r'//[^\r\n]*|' + BSL_LITERAL_PATTERN, source):
        parts.append(source[pos:match.start()])
        value = match[0]
        if not value.startswith('//'):
            if keep_strings:
                parts.append(value)
            else:
                parts.append('"' + '\n' * value.count('\n') + ('"' if len(value) >= 2 and value.endswith('"') else ''))
        pos = match.end()
    parts.append(source[pos:])
    return ''.join(parts).split('\n')


def is_empty_interceptor_body(lines):
    return not "\n".join(get_code_only(lines)).strip()


def has_inline_method_body(lines, method):
    line = lines[method["sig_end_idx"]]
    # params_text retains the text up to the closing parenthesis, including indentation.
    end = len(method["params_text"].rsplit("\n", 1)[-1])
    if method["decl_idx"] == method["sig_end_idx"]:
        end += line.index("(") + 1
    suffix = re.sub(r'^\s*(?:Экспорт|Export)\b', '', line[end + 1:], flags=re.I)
    return not is_empty_interceptor_body([suffix])


def rename_code_words(lines, mapping):
    if not mapping or not lines:
        return list(lines)
    parts, previous = [], ''
    for token in bsl_tokens(lines):
        key = token['value'].lower()
        if token['kind'] == 'word' and previous.lower() not in ('.', '\u043d\u043e\u0432\u044b\u0439', 'new') and key in mapping:
            parts.append(mapping[key])
        else:
            parts.append(token['value'])
        if token['kind'] != 'comment' and not token['value'].isspace():
            previous = token['value']
    return ''.join(parts).split('\n')


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


def get_call_written_names(code, names, params):
    written = set()
    if not names:
        return written
    tokens = [t for t in bsl_tokens(code) if t["kind"] != "comment" and not t["value"].isspace()]
    non_calls = {"если", "if", "иначеесли", "elsif", "пока", "while", "возврат", "return",
                 "и", "and", "или", "or", "не", "not", "по", "to", "из", "in",
                 "вызватьисключение", "raise", "ждать", "await"}
    params = {param.lower() for param in params}
    locals_ = get_local_names(code, params)
    for i, token in enumerate(tokens[:-1]):
        name = token["value"].lower()
        if token["kind"] != "word" or tokens[i + 1]["value"] != "(" or name in non_calls:
            continue
        arguments = {}
        for j, part in enumerate(get_bsl_arguments(tokens, i + 1)):
            while len(part) > 2 and tokens[part[0]]["value"] == "(" and tokens[part[-1]]["value"] == ")":
                part = part[1:-1]
            if len(part) != 1:
                continue
            arg = tokens[part[0]]["value"].lower()
            if arg in names:
                arguments[j] = arg
        if not arguments:
            continue
        qualified = i > 0 and tokens[i - 1]["value"] == "."
        owner = BSL_CONTEXT
        if qualified:
            owner = None
            if i >= 2 and tokens[i - 2]["kind"] == "word" and (i < 3 or tokens[i - 3]["value"] != "."):
                receiver = tokens[i - 2]["value"]
                if receiver.lower() not in params and receiver.lower() not in locals_:
                    owner = get_bsl_owner(receiver, BSL_CONTEXT)
                    cfg_name = BSL_CFG_COMMON_NAMES.get(receiver.lower())
                    if not owner and cfg_name:
                        module_path = os.path.join(BSL_CONFIG_PATH, "CommonModules", cfg_name, "Ext", "Module.bsl")
                        owner = {"cfg": read_bsl_lines(module_path), "ext": [], "methods": {}}
        signatures, ambiguous = [], False
        if owner:
            cfg_names = [n for n in get_proc_names(owner["cfg"] or []) if n.lower() == name]
            ext_names = [n for n in get_proc_names(owner["ext"] or [])
                         if n.lower() == name or owner["methods"].get(n.lower(), "").lower() == name]
            ambiguous = len(cfg_names) > 1 or len(ext_names) > 1
            for lines, candidates in ((owner["cfg"], cfg_names), (owner["ext"], ext_names)):
                for candidate in candidates:
                    method = get_method_safe(lines, candidate)
                    if method:
                        signatures.append((method["is_async"], get_val_flags(method["params_text"])))
                    else:
                        ambiguous = True
        if not qualified and not ambiguous and not signatures and name in BSL_GLOBAL_NAMES:
            owners = {ref['context']['rel']: ref['context'] for ref in get_bsl_global_references(name)}
            ambiguous = len(owners) > 1
            for gc in owners.values():
                cfg_names = [n for n in get_proc_names(gc["cfg"] or []) if n.lower() == name]
                ext_names = [n for n in get_proc_names(gc["ext"] or [])
                             if n.lower() == name or gc["methods"].get(n.lower(), "").lower() == name]
                ambiguous |= len(cfg_names) > 1 or len(ext_names) > 1
                for lines, candidates in ((gc["cfg"], cfg_names), (gc["ext"], ext_names)):
                    for candidate in candidates:
                        method = get_method_safe(lines, candidate)
                        if method:
                            signatures.append((method["is_async"], get_val_flags(method["params_text"])))
                        else:
                            ambiguous = True
        if not qualified and not ambiguous and not signatures and name in ("сообщить", "message"):
            continue
        for j, arg in arguments.items():
            if ambiguous or not signatures or any(not async_ and (j >= len(flags) or not flags[j])
                                                  for async_, flags in signatures):
                written.add(arg)
    return written


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
    h = convert_bsl_code(rename_code_words(ext_m["body_lines"], mapping), file_map, cp)
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
            written = get_call_written_names(hc, val_names, cp)
            if written:
                return "the handler may change Знач parameter %s through a call" % shown([n for n in val_names if n in written])
        else:
            assigned = get_assigned_names(oc)
            words = get_word_set(hc[frm:last + 1])
            names = [n for n in val_names if n in assigned and n in words]
            if names:
                return "the original changes Знач parameter %s: the handler did not see it" % shown(names)
            written = get_call_written_names(oc, [n for n in val_names if n in words], cp)
            if written:
                return "the original may change Знач parameter %s through a call" % shown([n for n in val_names if n in written])
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


def get_form_code_dependencies(rel, ext_dir, config_path, cache):
    key = rel.lower()
    if key not in cache:
        form_rel = re.sub(r'[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml', rel)
        ext_form = os.path.join(ext_dir, form_rel)
        missing = get_missing_names(
            get_form_item_names(ext_form),
            get_form_item_names(os.path.join(config_path, form_rel)),
        )
        ext_doc = read_form_doc(ext_form)
        cfg_doc = read_form_doc(os.path.join(config_path, form_rel))
        if ext_doc is not None and cfg_doc is not None:
            ext_attrs = section_map(ext_doc, "Attributes", "Attribute")
            cfg_attrs = section_map(cfg_doc, "Attributes", "Attribute")
            for name, _ in ext_attrs.values():
                if not find_scoped_form_names(cfg_attrs, name, TRANSFER_PREFIX, ext_attrs):
                    missing[name.lower()] = name
        index = form_element_index(ext_doc.getroot()) if ext_doc is not None else {}
        marks = get_form_transfer_marks(index, read_bsl_lines(os.path.join(ext_dir, rel)))
        temporary = {name: missing.pop(name, name) for name in marks}
        cache[key] = (missing, temporary)
    return cache[key]


def add_out_name(by_file, common, cfg_file, rel, name):
    """A method that is not coming, for the code that calls it: by its name in its own module; a common
    module's method also as Модуль.Метод for the other modules (a bare name there is someone else's).
    Returns True when it is new."""
    dst = by_file.setdefault(cfg_file.lower(), {})
    key = "method:" + name.lower()
    new = key not in dst
    dst[key] = name
    if get_module_kind(rel) == "common":
        mod = rel.replace("\\", "/").split("/")[1]
        common[("method:" + mod + "." + name).lower()] = mod + "." + name
    return new


def get_used_missing(lines, missing, selected=None, params=(), form_items=None):
    """Missing names the code uses (comments left out): the sorted original names. The extension's code
    names its own things as the extension does, so a word matches by the very name: a plain Товары is
    not the extension's Расш_Товары."""
    if not missing and not form_items:
        return []
    shadowed = {name.lower() for name in params}
    hit = set()
    for line_idx, t in enumerate(get_code_only(lines)):
        if selected is not None and line_idx not in selected:
            continue
        for m in re.finditer(r'\w+', t):
            k = m.group(0).lower()
            if k in shadowed:
                continue
            if k in missing:
                hit.add(missing[k])
    bc = get_bsl_conversion(lines, {}, BSL_CONTEXT, params)
    for ref in bc['references']:
        ref_line = '\n'.join(lines)[:ref['token']['start']].count('\n')
        if selected is not None and ref_line not in selected:
            continue
        k = ref['name'].lower()
        if (ref["kind"] in ("form_item", "attribute") and ref["context"] and ref["context"]["kind"] == "form"
                and form_items and k in form_items):
            hit.add(form_items[k])
        if ref['context'] and ref['context'] is not BSL_CONTEXT and ref['context']['kind'] == 'common':
            mod = ref['context']['rel'].replace('\\', '/').split('/')[1]
            k = (mod + '.' + ref['name']).lower()
        if ref['context'] and ref['context'] is not BSL_CONTEXT and ref['context']['kind'] == 'application':
            continue
        if ref['kind'] == 'method':
            k = "method:" + k
        if k in missing:
            hit.add(missing[k])
    # Ordinal, case-insensitive (as StringComparer.OrdinalIgnoreCase in the .ps1, which upper-cases)
    return sorted(hit, key=lambda x: x.upper())


def get_control_result_gap(plan, body):
    """The new body of an &ИзменениеИКонтроль method, compared again: every edit must come out absorbed,
    the way the check sees it after the write — the ones laid now and the ones already there (lines an
    edit moves within the method reappear in its insert, and a deletion then looks undone again).
    Returns the number of edits the check would still see as not transferred."""
    r2 = get_control_transfer(plan["ext_m"], dict(plan["cfg_m"], body_lines=list(body)), TRANSFER_PREFIX)
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
    conv = convert_bsl_code(plan["ext_m"]["body_lines"], file_map, plan["ext_m"]["param_names"])
    return "\n".join(sig_lines(convert_bsl_code(plan["ext_m"]["body_lines"], file_map, plan["ext_m"]["param_names"]), TRANSFER_PREFIX)).lower() == "\n".join(sig_lines(conv, TRANSFER_PREFIX)).lower()


def get_own_method_block(ext_lines, ext_m, frame, file_map, place):
    """An own method as the configuration gets it: the description comments above it, the directive, the
    declaration through Конец*; names converted; begin comment on top, end comment on the Конец* line."""
    start = ext_m["decl_idx"]
    if start >= 1 and is_context_directive(ext_lines[start - 1].strip()):
        start -= 1
    while start >= 1 and ext_lines[start - 1].strip().startswith("//"):
        start -= 1
    conv = convert_bsl_code(ext_lines[start:ext_m["body_end_idx"] + 1], file_map, ext_m["param_names"])
    out = []
    if frame["begin"]:
        out.append(frame["begin"])
    out.extend(conv)
    if frame["end"]:
        out[-1] = out[-1] + " " + frame["end"]
    return {"lines": out, "guards": place["guards"], "guard_key": place["guard_key"], "lang": ext_m["lang"]}


def join_own_method_blocks(blocks):
    out = []
    previous = None
    for block in blocks:
        same_guard = previous is not None and previous["guard_key"] == block["guard_key"]
        if previous is not None and not same_guard:
            out.extend(["#" + BSL_KW[previous["lang"]]["EndIf"]] * len(previous["guards"]))
        if out:
            out.append("")
        if not same_guard:
            keywords = BSL_KW[block["lang"]]
            out.extend("#%s %s %s" % (keywords["If"], guard, keywords["Then"]) for guard in block["guards"])
            previous = block
        out.extend(block["lines"])
    if previous is not None:
        out.extend(["#" + BSL_KW[previous["lang"]]["EndIf"]] * len(previous["guards"]))
    return out


def get_file_edits(path):
    """Edits of one configuration file, collected over the run and written once."""
    # One pool per file, however the path was spelled
    path = os.path.abspath(path)
    key = path.lower()
    if key not in FILE_EDITS:
        f = read_bsl_file(path)
        FILE_EDITS[key] = {"file": f, "repl": [], "create": {}, "create_order": [], "own_at": {}, "tail": [], "regions": get_regions(f["lines"]), "layout": get_module_layout(f["lines"]), "given": set()}
    return FILE_EDITS[key]


def get_file_edit_lines(fe):
    """Render the staged edits for validation or writing. Indexes refer to the original file."""
    if not fe["repl"] and not fe["create"] and not fe["own_at"] and not fe["tail"]:
        return None
    lines = list(fe["file"]["lines"])
    repl = list(fe["repl"])
    for at, o in fe["own_at"].items():
        blk = join_own_method_blocks(o["blocks"])
        repl.append({"start": at, "end": at, "lines": get_spaced_block(fe["file"]["lines"], at, blk), "seq": o["seq"]})
    region_at = get_module_end(fe["file"]["lines"]) if fe["create_order"] else -1
    end_at = region_at
    tail_at = get_module_tail(fe["file"]["lines"]) if fe["tail"] else -1
    body_at = tail_at
    for r in sorted(repl, key=lambda x: (x["start"], x["seq"]), reverse=True):
        # Keep the original insertion scope even when edits add a new conditional block at this spot.
        delta = len(r["lines"]) - (r["end"] - r["start"])
        if r["end"] <= region_at:
            end_at += delta
        if r["end"] <= tail_at:
            body_at += delta
        lines[r["start"]:r["end"]] = list(r["lines"])
    if fe["create_order"]:
        lang = get_module_lang(fe["file"]["lines"])
        prev = lines[end_at - 1] if end_at > 0 else ""
        add = []
        for name in fe["create_order"]:
            if add or prev.strip() != "":
                add.append("")
            add.append("#%s %s" % (BSL_KW[lang]["Region"], name))
            add.append("")
            add.extend(join_own_method_blocks(fe["create"][name]))
            add.append("")
            add.append("#" + BSL_KW[lang]["EndRegion"])
        if end_at < len(lines) and lines[end_at].strip() != "":
            add.append("")
        lines[end_at:end_at] = add
        if region_at <= tail_at:
            body_at += len(add)
    # Statements of the module body: after the configuration's own, at the tail
    for blk in fe["tail"]:
        spaced = get_spaced_block(lines, body_at, blk)
        lines[body_at:body_at] = spaced
        body_at += len(spaced)
    return lines


def write_file_edits(excluded):
    changed = []
    for key, fe in FILE_EDITS.items():
        if key in excluded:
            continue
        lines = get_file_edit_lines(fe)
        if lines is None:
            continue
        write_bsl_file(fe["file"], lines)
        changed.append(fe["file"]["path"])
    return changed


def replace_form_file(source, target, backup=None):
    if os.name != "nt":
        if backup:
            shutil.copy2(target, backup)
        os.replace(source, target)
        return

    # ReplaceFileW keeps the destination ACL, as File.Replace does in PowerShell.
    import ctypes
    from ctypes import wintypes
    replace = ctypes.WinDLL("kernel32", use_last_error=True).ReplaceFileW
    replace.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR,
                        wintypes.DWORD, wintypes.LPVOID, wintypes.LPVOID]
    replace.restype = wintypes.BOOL
    if not replace(target, source, backup, 0, None, None):
        raise ctypes.WinError(ctypes.get_last_error())


def write_form_pair(fe):
    paths = []
    backup = None
    module_written = False

    def staging_path(target):
        if not os.stat(target).st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
            raise PermissionError("read-only file: %s" % target)
        fd, path = tempfile.mkstemp(prefix=".cfe-transfer-", suffix=".tmp", dir=os.path.dirname(target))
        paths.append(path)
        os.close(fd)
        return path

    try:
        form_path = os.path.realpath(fe["path"])
        module_path = os.path.realpath(fe["cfg_module"])
        candidate = staging_path(form_path)
        save_form_write(fe["fw"], candidate)
        shutil.copymode(form_path, candidate)
        module = FILE_EDITS.get(fe["cfg_module"].lower())
        lines = get_file_edit_lines(module) if module else None
        if lines is not None:
            candidate_module = staging_path(module_path)
            write_bsl_file(module["file"], lines, candidate_module)
            shutil.copymode(module_path, candidate_module)
            backup = staging_path(module_path)
            os.remove(backup)
            replace_form_file(candidate_module, module_path, backup)
            module_written = True
        replace_form_file(candidate, form_path)
        return [fe["cfg_module"], fe["path"]] if module_written else [fe["path"]]
    except Exception:
        if module_written:
            try:
                replace_form_file(backup, module_path)
            except OSError as exc:
                paths.remove(backup)
                raise OSError("Could not restore the form module. Restore %s from %s. %s" %
                              (module_path, backup, exc)) from exc
        raise
    finally:
        for path in paths:
            try:
                if os.path.exists(path):
                    os.chmod(path, 0o600)
                    os.remove(path)
            except OSError:
                pass


def set_form_write_conflict(fe, recs, config_path, reason):
    items = [op["item"] for op in fe.get("ops", [])]
    for rec in recs:
        for item in rec["items"]:
            plan = item.get("plan") or {}
            rel = plan.get("rel")
            if (item.get("now") and rel and plan["kind"] not in ("event-bind", "command-bind")
                    and os.path.abspath(os.path.join(config_path, rel)).lower() == fe["cfg_module"].lower()):
                items.append(item)
    for item in items:
        item["status"] = "CONFLICT"
        item["now"] = False
        item["text"] = "%s — %s" % (item["text"], reason)
        item["sub"] = [get_form_conflict_hint(reason)]


def get_form_conflict_hint(reason):
    if "form-validate: 24. Module variable" in reason:
        return "next: give the form attribute or module variable a distinct name and update its references, then re-run -Mode transfer"
    return "next: resolve the reported form or module issue, then re-run -Mode transfer"


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


STATUS_ORDER = ["TRANSFERRED", "NOT_TRANSFERRED", "PARTIAL", "DIVERGED", "MISSING_IN_CONFIG", "TEMPORARY", "MANUAL"]


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
    global SETTINGS, DEV_RE, NAME_MAP, TRANSFER_PREFIX, SUPPORT_INFO, MD_REFERENCE_POOLS, MD_REFERENCE_ROOT
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
    parser.add_argument("-IncludeDefaultRoles", action="store_true")
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
    MD_REFERENCE_ROOT = config_path
    if cfg_info["child_objects"] is not None:
        MD_REFERENCE_POOLS = {}
        for child in elem_children(cfg_info["child_objects"]):
            MD_REFERENCE_POOLS.setdefault(localname(child), []).append(inner_text(child).strip())

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
    CONFIG_REF_MAP.clear()
    CONFIG_REF_MAP.update(get_config_ref_map(config_path))
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
        filtered_own = []
        all_objs = []
        if cp0["child_objects"] is not None:
            for c in elem_children(cp0["child_objects"]):
                if localname(c) != "Language":
                    all_objs.append({"type": localname(c), "name": (c.text or "").strip()})
        root_changed = initialize_root_transfer(ext, all_objs, cfg_info, vars_, name_match, apply=True, include_default_roles=args.IncludeDefaultRoles)
        initialize_bsl_catalog(ext_dir0, config_path, prefix)
        cfg_pools = MD_REFERENCE_POOLS or {}
        for obj in all_objs:
            oid = "%s.%s" % (obj["type"], obj["name"])
            if not name_match(oid):
                if obj["type"] == "CommonModule":
                    rec = transfer_object(ext, obj, cfg_info, config_path, cfg_pools)
                    filtered_own.extend(it for it in rec["items"]
                                        if it.get("plan", {}).get("kind") == "own" and it["status"] != "TRANSFERRED")
                continue
            matched_ids.add(oid.lower())
            if obj["type"] == "Role" and oid.lower() not in ROOT_OWN:
                roles += 1
                continue
            rec = transfer_object(ext, obj, cfg_info, config_path, cfg_pools)
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
                own_id = ("%s.%s" % (obj["type"], obj["name"])).lower()
                if own_id in ROOT_OWN:
                    hit = ROOT_BINDINGS.get(own_id)
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
            cfg_children = []
            if cfg_md is not None and cfg_md["children"] is not None:
                cfg_children = elem_children(cfg_md["children"])
            taken = {md_child_name(c).lower() for c in cfg_children}
            for c in elem_children(md["children"]):
                own = []
                peers = [child for child in cfg_children if localname(child) == localname(c)]
                cfg_known = [md_child_name(child) for child in peers]
                taken_here = taken
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
                        parent = find_name_in(cfg_known, md_child_name(c), prefix)
                        cfg_known = [md_child_name(col) for child in peers
                                     if parent and md_child_name(child).lower() == parent.lower()
                                     for col in child.findall("md:ChildObjects/md:Attribute", MD_NSMAP)]
                        taken_here = {name.lower() for name in cfg_known}
                        for sc in elem_children(sub):
                            if not test_adopted_node(sc):
                                own.append(md_child_name(sc))
                for nm in own:
                    if not nm:
                        continue
                    hit = find_name_in(cfg_known, nm, prefix)
                    if not hit:
                        missing_by_obj.setdefault("%s.%s" % (obj["type"], obj["name"]), {})[nm.lower()] = nm
                    if nm.lower() in NAME_MAP:
                        continue
                    t = hit if hit else get_target_name(nm, prefix, taken_here, add_dev)["name"]
                    if t != remove_ext_prefix(nm, prefix):
                        NAME_MAP[nm.lower()] = t
        # Own methods: the target name in their module (taken: the module's methods and those given in
        # this run); a common module's method is called from other modules too, so it goes to the run map
        file_maps = {}
        for w in work:
            for it in w["rec"]["items"]:
                pl = it.get("plan")
                if not pl or pl["kind"] != "own" or pl.get("manual_reason"):
                    continue
                cfg_file = os.path.abspath(os.path.join(config_path, pl["rel"]))
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
                # XML keeps its legacy map; BSL resolves methods through owner-scoped catalogs.
                if get_module_kind(pl["rel"]) == "common" and tn["name"] != remove_ext_prefix(pl["name"], prefix):
                    NAME_MAP[pl["name"].lower()] = tn["name"]


        for ctx2 in BSL_CATALOG.values():
            fk2 = os.path.abspath(os.path.join(config_path, ctx2['rel'])).lower()
            ctx2['methods'].update(file_maps.get(fk2, {}))

        # --- Pass 3: each change -> transferred now, waiting, left to a person (manual) or in conflict ---
        # An own method that stays out of the configuration in this run is one more missing name: code
        # calling it waits too. Nothing is written before pass 4, so the pass runs again until no new
        # method stays out. A method of a common module is called from other modules, the rest from
        # their own module only.
        form_dependencies = {}
        form_rejections = {}
        form_handler_rejections = {}
        form_topcode_rejections = {}
        out_by_file = {}
        out_common = {}
        for oid, methods in ROOT_METHOD_BLOCKS.items():
            rel = root_object_paths("CommonModule", ROOT_OWN[oid]["name"])["bsl"]
            for method in methods:
                add_out_name(out_by_file, out_common, os.path.join(config_path, rel), rel, method)
        for oid, entry in ROOT_OWN.items():
            if entry["type"] != "CommonModule" or oid in ROOT_BINDINGS:
                continue
            rel = root_object_paths("CommonModule", entry["name"])["bsl"]
            for method in get_proc_names(read_bsl_lines(os.path.join(ext_dir0, rel)) or []):
                add_out_name(out_by_file, out_common, os.path.join(config_path, rel), rel, method)
        # Own methods marked "not for transfer" and not in the configuration: never coming, so code that
        # calls them is left to a person (drop the call or the mark) rather than waiting
        temp_by_file = {}
        temp_common = {}
        for it in filtered_own:
            pl = it["plan"]
            by_file, common = (temp_by_file, temp_common) if it["status"] == "TEMPORARY" else (out_by_file, out_common)
            add_out_name(by_file, common, os.path.abspath(os.path.join(config_path, pl["rel"])), pl["rel"], pl["name"])
        for w in work:
            for it in w["rec"]["items"]:
                pl = it.get("plan")
                if it["status"] != "TEMPORARY" or not pl or pl["kind"] != "own":
                    continue
                add_out_name(temp_by_file, temp_common, os.path.abspath(os.path.join(config_path, pl["rel"])), pl["rel"], pl["name"])
        while True:
            again = False
            for fe in FILE_EDITS.values():
                fe["repl"].clear()
                fe["create"].clear()
                fe["create_order"].clear()
                fe["own_at"].clear()
                fe["tail"].clear()
            FORM_EDITS.clear()
            MD_EDITS.clear()
            MD_GIVEN.clear()
            MD_WARN[:] = ROOT_DATA_WARNINGS
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
                # Changes of one form go in the order they depend on each other — a column needs its attribute,
                # an element may name a command added in this run — the report keeps the items' own order
                order = sorted(((form_item_rank(it), i, it) for i, it in enumerate(w["rec"]["items"])),
                               key=lambda x: (x[0], x[1]))
                for _, oi, it in order:
                    pl = it.get("plan")
                    if pl and pl.get("rel"):
                        set_bsl_context(pl["rel"])
                    t = new_titem(it["status"], it["text"], it.get("loc", ""), it.get("section", ""))
                    if it.get("now"):
                        t["now"] = True
                    t["plan"] = pl
                    t["group"] = it.get("group", "")
                    t["marked"] = it.get("marked", False)
                    t["seq"] = oi
                    if pl and pl["kind"] == "own" and it["status"] != "TRANSFERRED":
                        handler_key = (os.path.abspath(os.path.join(config_path, pl["rel"])).lower(), pl["name"].lower())
                        if handler_key in form_handler_rejections:
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %s; handler not added" % (it["text"], form_handler_rejections[handler_key])
                            t["sub"] = get_where_lines(pl, "resolve the form conflict, then re-run -Mode transfer")
                            titems.append(t)
                            continue
                    if pl and pl["kind"] == "own" and it["status"] in ("NOT_TRANSFERRED", "MANUAL", "DIVERGED"):
                        own_items.append({"plan": pl, "t": t})
                    # A method with an &ИзменениеИКонтроль edit not in the configuration yet: an interceptor of it
                    # would move the lines the edit is anchored to
                    if pl and pl["kind"] == "control" and pl.get("cfg_m") and it["status"] not in ("TRANSFERRED", "TEMPORARY"):
                        ctl_keys.add("%s|%d" % (os.path.abspath(os.path.join(config_path, pl["rel"])).lower(), pl["cfg_m"]["decl_idx"]))
                    if it["status"] == "TEMPORARY":
                        temp_count += 1
                        continue
                    if it["status"] == "TRANSFERRED" or (pl and pl["kind"] == "md-reference"):
                        titems.append(t)
                        continue
                    if pl and pl.get("manual_reason"):
                        t["sub"] = get_where_lines(pl, "apply by hand, then re-run -Mode check")
                        for handler in pl.get("blocked_handlers", []):
                            if handler and add_out_name(out_by_file, out_common, os.path.abspath(os.path.join(config_path, pl["rel"])), pl["rel"], handler):
                                again = True
                        titems.append(t)
                        continue
                    problem = get_bsl_plan_issue(pl)
                    if problem:
                        t['status'] = problem['issue'].get('status', 'MANUAL')
                        if it['status'] != t['status']:
                            t['text'] += ' — ' + problem['issue']['why']
                        t['sub'] = get_bsl_manual_details(pl, problem)
                        if pl["kind"] in ("event-bind", "command-bind") and add_blocked_form_handlers(
                                pl, out_by_file, out_common, file_maps, config_path):
                            again = True
                        titems.append(t); continue
                    if it.get("group") and w["support"] == "locked":
                        t["status"] = "MANUAL"
                        t["text"] = it["text"] + " — object is locked by vendor support"
                        t["sub"] = ["next: allow editing with /support-edit, then re-run -Mode transfer"]
                        titems.append(t)
                        continue
                    if it.get("group") and it.get("plan") and it["plan"]["kind"] == "intercept":
                        cfg_file = os.path.abspath(os.path.join(config_path, it["plan"]["rel"]))
                        fm = file_maps.get(cfg_file.lower(), {})
                        r = get_intercept_ops(it["plan"]["ext_m"], it["plan"]["cfg_m"], it["plan"]["type"], frame, set_["deletion"], fm)
                        if r.get("why"):
                            t["text"] = "%s — %s" % (it["plan"]["label"], r["why"])
                            t["sub"] = ["next: apply by hand, then re-run -Mode check"]
                            titems.append(t)
                            continue
                        blocked2 = get_bsl_blocked_dependencies(pl, out_by_file, out_common, config_path)
                        if blocked2:
                            t['status'] = 'WAITING'; t['text'] = it['text'] + ' - waits for: ' + ', '.join(blocked2)
                            titems.append(t); continue
                        ic_pending.append({"t": t, "pl": it["plan"], "fe": get_file_edits(cfg_file), "ops": r["ops"],
                                           "where": r["where"], "label": it["plan"]["label"], "warn": "",
                                           "locals": r["locals"], "words": r["words"]})
                        titems.append(t)
                        continue
                    if it.get("group") and it.get("plan"):
                        pl = it["plan"]
                        rel_form = it.get("section") or ""
                        # A new event or a new command's handler lives in the form's module, the change itself
                        # in Form.xml
                        is_binding = pl["kind"] in ("event-bind", "command-bind")
                        if is_binding:
                            rel_form = re.sub(r'[\\/]Ext[\\/]Form[\\/]Module\.bsl$', '/Ext/Form.xml', pl["rel"])
                        cfg_form = os.path.abspath(os.path.join(config_path, rel_form))
                        form_key = cfg_form.lower()
                        if form_key in form_rejections:
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %s; form not changed" % (it["text"], form_rejections[form_key]["reason"])
                            t["sub"] = [get_form_conflict_hint(form_rejections[form_key]["reason"])]
                            if is_binding and add_blocked_form_handlers(pl, out_by_file, out_common, file_maps, config_path):
                                again = True
                            titems.append(t)
                            continue
                        if is_binding or (pl["kind"] == "command" and pl.get("handlers")):
                            missing, temporary = get_form_code_dependencies(pl["rel"], ext_dir0, config_path, form_dependencies)
                            temp_deps = get_bsl_blocked_dependencies(pl, {}, {}, config_path, temporary)
                            blocked2 = get_bsl_blocked_dependencies(pl, out_by_file, out_common, config_path, missing)
                            if temp_deps or blocked2:
                                if temp_deps:
                                    t["status"] = "MANUAL"
                                    t["text"] = "%s — uses form items %s, marked as not for transfer" % (it["text"], ", ".join(temp_deps))
                                    t["sub"] = get_where_lines(pl, "drop the use before the transfer or remove the mark from the form module, then re-run -Mode transfer")
                                else:
                                    t["status"] = "WAITING"
                                    t["text"] = it["text"] + " - waits for: " + ", ".join(blocked2)
                                if is_binding and add_blocked_form_handlers(pl, out_by_file, out_common, file_maps, config_path):
                                    again = True
                                titems.append(t)
                                continue
                        ext_form = os.path.abspath(os.path.join(ext_dir0, rel_form))
                        cfg_form_mod = os.path.abspath(re.sub(r'[\\/]Ext[\\/]Form\.xml$', '/Ext/Form/Module.bsl', cfg_form))
                        ext_form_mod = os.path.abspath(re.sub(r'[\\/]Ext[\\/]Form\.xml$', '/Ext/Form/Module.bsl', ext_form))
                        fe = new_form_edit(cfg_form, ext_form, ext_form_mod, cfg_form_mod, ext_dir0, prefix, it["group"])
                        if "ctx" not in fe:
                            # The same map the handlers of this module are registered in: a node copied later
                            # (a command's Action, an element's Event) finds the names given in this run
                            hm = file_maps.setdefault(cfg_form_mod.lower(), {})
                            ext_root = read_form_doc(ext_form).getroot()
                            scope = get_form_reference_scope(ext_root, fe["fw"]["root"], prefix, read_bsl_lines(cfg_form_mod))
                            fe["ctx"] = {"name_map": get_form_name_map(ext_root, fe["fw"]["root"], prefix),
                                         "ref_map": CONFIG_REF_MAP, "handler_map": hm, "bad": [],
                                         "temp_marks": get_form_transfer_marks(scope["elements"], read_bsl_lines(ext_form_mod)),
                                         "reference_scope": scope}
                        # A binding of the extension's own (an event, a new command's actions): its handlers go
                        # into the module by the role the form gives them, the item into Form.xml; nothing is
                        # committed until the item itself has been applied
                        op = pl
                        mod_adds = []
                        map_ref = None
                        map_added = []
                        if is_binding:
                            cfg_mod_file = os.path.abspath(os.path.join(config_path, pl["rel"]))
                            fw = get_file_edits(cfg_mod_file)
                            fk = cfg_mod_file.lower()
                            # The names go into the shared map before the item is copied: a command's Action
                            # text is renamed by the copy; on a refusal they are taken back
                            map_ref = file_maps.setdefault(fk, {})
                            hs = ([{"handler": pl["handler"], "ext_m": pl["ext_m"]}] if pl["kind"] == "event-bind"
                                  else list(pl["handlers"]))
                            bind = get_form_bindings(ext_form)
                            notify = get_notify_names(list(pl["ext_lines"]) + list(fw["file"]["lines"]))
                            conflict = None
                            for h in hs:
                                hk = h["handler"].lower()
                                tn = {"name": map_ref[hk], "note": ""} if hk in map_ref else None
                                if tn is None:
                                    taken = {n.lower() for n in get_proc_names(fw["file"]["lines"])} | set(fw["given"])
                                    taken |= {n.lower() for n in get_called_names(list(fw["file"]["lines"]) + list(pl["ext_lines"]), get_proc_names(pl["ext_lines"]))}
                                    tn = get_target_name(h["handler"], prefix, taken, set_["add_dev_methods"] and w["kind"] == "vendor")
                                if tn.get("taken"):
                                    conflict = "name taken in config (%s)" % tn["note"]
                                    break
                                map_ref[hk] = tn["name"]
                                map_added.append(hk)
                                conv = convert_bsl_code(h["ext_m"]["body_lines"], map_ref, h["ext_m"]["param_names"])
                                if "\n".join(sig_lines(convert_bsl_code(h["ext_m"]["body_lines"], map_ref, h["ext_m"]["param_names"]), prefix)).lower() != "\n".join(sig_lines(conv, prefix)).lower():
                                    conflict = "after the transfer the check would not find the handler's code"
                                    break
                                role = get_method_role(h["handler"], "form", bind, notify, is_export(pl["ext_lines"], h["ext_m"]))
                                created = {k.lower() for k in fw["create_order"]}
                                place = get_method_place(fw["file"]["lines"], fw["regions"], h["ext_m"], role, set_, created)
                                place = resolve_method_conditions(fw["file"]["lines"], place, h["ext_m"])
                                if not place:
                                    conflict = "no compatible preprocessor scope for the handler"
                                    break
                                mod_adds.append({"name": tn["name"], "note": tn["note"], "fw": fw, "place": place,
                                                 "block": get_own_method_block(pl["ext_lines"], h["ext_m"], frame, map_ref, place),
                                                 "where": ""})
                            if conflict:
                                for k in map_added:
                                    map_ref.pop(k, None)
                                t["status"] = "CONFLICT"
                                t["text"] = "%s — %s; form not changed" % (it["text"], conflict)
                                t["sub"] = ["next: rename the handler in the extension or merge by hand, then re-run -Mode transfer"]
                                titems.append(t)
                                continue
                            if pl["kind"] == "event-bind":
                                op = {"kind": "event", "scope": pl["scope"], "name": pl["name"], "handler": mod_adds[0]["name"]}
                            else:
                                op = {"kind": "command", "node": pl["node"], "name": pl["name"], "strip_call_type": True}
                        try:
                            apply_form_op(fe, op, fe["ctx"])
                            if fe["ctx"]["bad"]:
                                raise ValueError(fe["ctx"]["bad"][0])
                            for ma in mod_adds:
                                mf, mp = ma["fw"], ma["place"]
                                if mp.get("create"):
                                    key = next((k for k in mf["create_order"] if k.lower() == mp["create"].lower()), None)
                                    if key is None:
                                        key = mp["create"]
                                        mf["create_order"].append(key)
                                        mf["create"][key] = []
                                    mf["create"][key].append(ma["block"])
                                    ma["where"] = "new region " + key
                                else:
                                    at = int(mp["at"])
                                    if at not in mf["own_at"]:
                                        mf["own_at"][at] = {"blocks": [], "seq": EDIT_SEQ[0]}
                                        EDIT_SEQ[0] += 1
                                    mf["own_at"][at]["blocks"].append(ma["block"])
                                    ma["where"] = ("region " + mp["region"]) if mp["region"] else "end of module"
                            pk = pl["kind"]
                            if pk == "prop":
                                fe["ops"].append({"kind": "prop", "rec": pl["rec"], "props": pl["props"], "item": t})
                            elif pk == "formprop":
                                fe["ops"].append({"kind": "formprop", "props": pl["props"], "item": t})
                            else:
                                fe["ops"].append({"kind": "text", "key": it["plan_key"], "item": t})
                            # A property changed in the configuration some other way stays as it is: the item
                            # keeps its divergence, what was pending has gone over
                            if it["status"] == "DIVERGED":
                                t["status"] = "DIVERGED"
                                t["now"] = False
                                t["text"] = it["text"] + " — the rest transferred"
                            else:
                                t["status"] = "TRANSFERRED"
                                t["now"] = True
                                if mod_adds:
                                    names = ", ".join("%s%s" % (m["name"], (" (%s)" % m["note"]) if m["note"] else "") for m in mod_adds)
                                    where = ", ".join(sorted({m["where"] for m in mod_adds}))
                                    if pl["kind"] == "event-bind":
                                        t["text"] = "event %s%s -> %s — method in %s" % (
                                            (pl["scope"] + ".") if pl["scope"] else "", pl["name"], names, where)
                                    else:
                                        t["text"] = "%s — method %s -> %s" % (it["text"], names, where)
                                else:
                                    t["text"] = re.sub(r' \(\d+/\d+ props\)$', '', it["text"])
                            titems.append(t)
                        except Exception as e:
                            # A change that was refused before touching the document leaves the rest of
                            # the form transferable
                            if map_ref is not None:
                                for k in map_added:
                                    map_ref.pop(k, None)
                            msg = str(e)
                            # A refused change leaves the rest of the form transferable; a failure of the write
                            # itself keeps the whole form as it is
                            skip = msg.startswith("SKIP: ")
                            if skip:
                                msg = msg[6:]
                            else:
                                fe["failed"] += 1
                                fe.setdefault("failure_reason", msg)
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %s; %s" % (it["text"], msg, "change not applied" if skip else "form not changed")
                            t["sub"] = ["next: apply by hand, then re-run -Mode check"]
                            titems.append(t)
                        continue
                    t["status"] = "MANUAL"
                    if it.get("group"):
                        t["text"] = it["text"] + " — the configuration's form changed since the borrowing; not applied"
                        titems.append(t)
                        continue
                    # A metadata property left to a person: the check side already said why, nothing to add
                    if it.get("manual") and not pl:
                        t["text"] = it["text"]
                        titems.append(t)
                        continue
                    if not pl:
                        t["text"] = it["text"] + " — metadata is not transferred yet"
                        titems.append(t)
                        continue
                    if pl["kind"] == "md" or pl["kind"].startswith("md-"):
                        if pl["kind"] == "md-skip":
                            t["text"] = it["text"] + " — " + pl["reason"]
                            titems.append(t)
                            continue
                        if w["support"] == "locked":
                            t["text"] = it["text"] + " — object is locked by vendor support"
                            t["sub"] = ["next: allow editing with /support-edit, then re-run -Mode transfer"]
                            titems.append(t)
                            continue
                        if pl["kind"] == "md-prop":
                            if pl.get("conflict"):
                                t["status"] = "CONFLICT"
                                # The check's line already names the reason (the type qualifiers, the missing property)
                                t["text"] = it["text"] + "; property not changed"
                                nxt = pl.get("next") or "next: compare and merge by hand, then re-run -Mode check"
                                t["sub"] = ["from: extension " + pl["rel"], "to:   config " + pl["rel"], nxt]
                                titems.append(t)
                                continue
                            me = get_md_edits(os.path.abspath(os.path.join(config_path, pl["rel"])), pl["obj_type"])
                            try:
                                apply_md_op(me, pl)
                                me["ops"].append({"plan": pl, "item": t})
                                t["status"] = "TRANSFERRED"
                                t["now"] = True
                                t["text"] = it["text"] + " — applied"
                                titems.append(t)
                            except Exception as e:
                                msg = str(e)
                                skip = msg.startswith("SKIP: ")
                                if skip:
                                    msg = msg[6:]
                                else:
                                    me["failed"] += 1
                                t["status"] = "CONFLICT"
                                t["text"] = "%s — %s; %s" % (it["text"], msg, "property not changed" if skip else "object not changed")
                                t["sub"] = ["next: apply by hand, then re-run -Mode check"]
                                titems.append(t)
                            continue
                        if pl["kind"] == "md-content":
                            if pl.get("missing"):
                                t["text"] = it["text"] + " — the object is not in the configuration"
                                t["sub"] = ["next: add the object to the configuration first, then re-run -Mode transfer"]
                                titems.append(t)
                                continue
                            me = get_md_edits(os.path.abspath(os.path.join(config_path, pl["rel"])), "Subsystem")
                            try:
                                apply_md_op(me, pl)
                                me["ops"].append({"plan": pl, "item": t})
                                t["status"] = "TRANSFERRED"
                                t["now"] = True
                                titems.append(t)
                            except Exception as e:
                                msg = str(e)
                                skip = msg.startswith("SKIP: ")
                                if skip:
                                    msg = msg[6:]
                                else:
                                    me["failed"] += 1
                                t["status"] = "CONFLICT"
                                t["text"] = "%s — %s; %s" % (it["text"], msg, "change not applied" if skip else "object not changed")
                                t["sub"] = ["next: apply by hand, then re-run -Mode check"]
                                titems.append(t)
                            continue
                        if pl.get("conflict"):
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %s; object not changed" % (it["text"], pl["conflict"])
                            t["sub"] = ["from: extension " + pl["rel"], "to:   config " + pl["rel"],
                                        pl.get("next") or "next: compare the types and merge by hand, then re-run -Mode check"]
                            titems.append(t)
                            continue
                        me = get_md_edits(os.path.abspath(os.path.join(config_path, pl["rel"])), pl["obj_type"])
                        # The name is the one pass 2 gave the code, else the container's pool decides
                        tn = ({"name": NAME_MAP[pl["name"].lower()], "note": ""}
                              if pl["name"].lower() in NAME_MAP else None)
                        if tn is None:
                            co = get_md_container(me, pl["parent"], pl["tag"])
                            taken = {md_child_name(x).lower() for x in elem_children(co)} if co is not None else set()
                            gk = (pl["rel"].lower(), pl["parent"].lower(), pl["tag"])
                            taken |= MD_GIVEN.get(gk, set())
                            tn = get_target_name(pl["name"], prefix, taken, set_["add_dev_objects"])
                        if tn.get("taken"):
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — name taken in config (%s); object not changed" % (it["text"], tn["note"])
                            t["sub"] = ["next: rename it in the extension or merge by hand, then re-run -Mode transfer"]
                            titems.append(t)
                            continue
                        pl["target"] = tn
                        gk = (pl["rel"].lower(), pl["parent"].lower(), pl["tag"])
                        MD_GIVEN.setdefault(gk, set()).add(tn["name"].lower())
                        try:
                            apply_md_op(me, pl)
                            me["ops"].append({"plan": pl, "item": t})
                            note = (" (as %s)" % tn["name"]) if tn["name"].lower() != pl["name"].lower() else ""
                            t["status"] = "TRANSFERRED"
                            t["now"] = True
                            t["text"] = "%s%s — structure only, stored values are not migrated" % (it["text"], note)
                            t["stored"] = "%s: %s%s" % (pl["rel"], it["text"], note)
                            titems.append(t)
                        except Exception as e:
                            msg = str(e)
                            skip = msg.startswith("SKIP: ")
                            if skip:
                                msg = msg[6:]
                            else:
                                me["failed"] += 1
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %s; %s" % (it["text"], msg, "change not applied" if skip else "object not changed")
                            t["sub"] = ["next: apply by hand, then re-run -Mode check"]
                            titems.append(t)
                        continue
                    if pl["kind"] == "missing":
                        nxt = ("the interceptor does not parse: fix it in the extension, then re-run -Mode transfer" if pl.get("cfg_m")
                               else "the target is not in the configuration: add it there first, then re-run -Mode transfer")
                        t["sub"] = get_where_lines(pl, nxt)
                        titems.append(t)
                        continue
                    cfg_file = os.path.abspath(os.path.join(config_path, pl["rel"]))
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
                            fe["top_keys"] = get_top_code_keys(fe["file"]["lines"], prefix)
                        el, cl = pl["layout"], fe["layout"]
                        ext_keys = get_top_code_keys(pl["ext_lines"], prefix, True)
                        have = {fe["top_keys"][v["idx"]].lower() for v in cl["vars"]}
                        taken = {n.lower() for v in cl["vars"] for n in v["names"]} | {n.lower() for n in get_proc_names(fe["file"]["lines"])}
                        # Each line once: a variable declared twice in the extension is declared once in the configuration
                        seen = set()
                        matched, count, any_stmt = get_module_statement_match(pl["ext_lines"], el, ext_keys, fe["file"]["lines"], cl, fe["top_keys"])
                        stmts = el["statements"] if matched < count else []
                        todo, clash = [], []
                        for v in el["vars"]:
                            key = ext_keys[v["idx"]].lower()
                            if key in have or key in seen:
                                continue
                            seen.add(key)
                            for n in v["names"]:
                                tn = convert_bsl_code([n], file_map)[0]
                                if tn.lower() in taken:
                                    clash.append(tn)
                            todo.append(v)
                        # Variables that stay out make the code using them wait, like a method that stays out
                        t["out_names"] = [n for v in todo for n in v["names"]]
                        t["out_file"] = cfg_file
                        top_items.append(t)
                        if cfg_file.lower() in form_topcode_rejections:
                            reason = form_topcode_rejections[cfg_file.lower()]
                            t["status"] = "CONFLICT"
                            t["text"] = "%s — %s; declarations not transferred" % (label, reason)
                            t["sub"] = where_sub + [get_form_conflict_hint(reason)]
                            titems.append(t)
                            continue
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
                            if any_stmt:
                                why = "statements of the module body are partly in config"
                            elif s0 < el["after_methods"] or any(s0 <= v["idx"] <= s1 for v in el["vars"]):
                                why = "statements of the module body are interleaved with declarations"
                            elif (method_conditions(get_enclosing_chain(pl["ext_lines"], s0, get_module_lang(pl["ext_lines"])))
                                  or any(x.strip().startswith("#") for x in rng)):
                                why = "statements of the module body stand under preprocessor instructions"
                            elif method_conditions(get_enclosing_chain(fe["file"]["lines"], get_module_tail(fe["file"]["lines"]), "en")):
                                why = "module body has no unconditional insertion position"
                            if why:
                                t["text"] = "%s — %s" % (label, why)
                                t["sub"] = ["from: extension %s:%d-%d" % (pl["rel"], s0 + 1, s1 + 1), "next: add them at the end of the configuration module by hand, then re-run -Mode check"]
                                titems.append(t)
                                continue
                            temp_methods = dict(temp_by_file.get(cfg_file.lower(), {}))
                            temp_methods.update(temp_common)
                            temp_deps = get_used_missing(rng, temp_methods)
                            if temp_deps:
                                t["text"] = "%s — calls %s, marked as not for transfer" % (label, ", ".join(temp_deps))
                                t["sub"] = where_sub + ["next: drop the call or remove the mark, then re-run -Mode transfer"]
                                titems.append(t)
                                continue
                            blocked_methods = dict(missing_global)
                            blocked_methods.update(missing_by_obj.get(w["id"], {}))
                            blocked_methods.update(out_by_file.get(cfg_file.lower(), {}))
                            blocked_methods.update(out_common)
                            deps = get_used_missing(rng, blocked_methods)
                            if deps:
                                t["status"] = "WAITING"
                                t["text"] = "%s — waits for: %s" % (label, ", ".join(deps))
                                t["sub"] = ["from: extension %s:%d-%d" % (pl["rel"], s0 + 1, s1 + 1),
                                            "next: transfer the required methods, then re-run -Mode transfer"]
                                titems.append(t)
                                continue
                            body = convert_bsl_code(rng, file_map)
                        parts = []
                        if todo:
                            block = []
                            for v in todo:
                                block += convert_bsl_code(pl["ext_lines"][v["start"]:v["idx"] + 1], file_map)
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
                    form_missing_items = {}
                    form_temp_items = {}
                    for m in (missing_global, missing_by_obj.get(w["id"])):
                        if m:
                            missing.update(m)
                    if get_module_kind(pl["rel"]) == "form":
                        form_missing_items, form_temp_items = get_form_code_dependencies(pl["rel"], ext_dir0, config_path, form_dependencies)
                        for k in form_temp_items:
                            missing.pop(k, None)
                    for m in (out_by_file.get(cfg_file.lower()), out_common):
                        if m:
                            missing.update(m)
                    # A method calling itself does not wait for itself
                    if pl["kind"] == "own":
                        missing.pop("method:" + pl["name"].lower(), None)
                    selected2 = None
                    if pl["kind"] == "control":
                        cp2 = get_control_projection(pl['ext_m']['body_lines'], file_map, prefix, pl['ext_m']['param_names'])
                        code, selected2 = cp2['desired'], set()
                        for op2 in pl['ops']:
                            if op2['res'] == 'pending' and op2['op']['kind'] == 'insert':
                                a2, b2 = cp2['ranges'][op2['op']['source_index']]
                                selected2.update(range(a2, b2))
                    else:
                        code = list(pl["ext_m"]["body_lines"])
                    deps = get_used_missing(code, missing, selected2, pl["ext_m"]["param_names"], form_missing_items)
                    # A conflict or a missing module shows first: waiting would hide it
                    blocked = ((pl["kind"] == "control" and any(e["res"] not in ("pending", "absorbed", "temp") for e in pl["ops"]))
                               or (pl["kind"] == "own" and (it["status"] == "DIVERGED" or pl["cfg_missing"]
                                                            or (pl.get("target") or {}).get("taken")))
                               or (pl["kind"] == "intercept" and it["status"] == "PARTIAL"))
                    temp_map = {}
                    for m in (temp_by_file.get(cfg_file.lower()), temp_common):
                        if m:
                            temp_map.update(m)
                    temp_deps = get_used_missing(code, temp_map, selected2, pl["ext_m"]["param_names"])
                    if temp_deps and not blocked:
                        t["text"] = "%s — calls %s, marked as not for transfer" % (label, ", ".join(temp_deps))
                        t["sub"] = get_where_lines(pl, "drop the call before the transfer or remove the mark from the method, then re-run -Mode transfer")
                        titems.append(t)
                        continue
                    form_temp_deps = get_used_missing(code, {}, selected2, pl["ext_m"]["param_names"], form_temp_items)
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
                        body = get_control_body(pl["cfg_m"], pl["ops"], frame, set_["deletion"], file_map, pl["ext_m"])
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
                    place = resolve_method_conditions(fe["file"]["lines"], place, pl["ext_m"])
                    if not place:
                        t["text"] = "%s — no compatible preprocessor scope" % label
                        t["sub"] = get_where_lines(pl, "choose a placement with matching conditions, then re-run -Mode check")
                        titems.append(t)
                        continue
                    block = get_own_method_block(pl["ext_lines"], pl["ext_m"], frame, file_map, place)
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
                titems.sort(key=lambda x: x["seq"])
                recs.append({"id": w["id"], "items": titems})
            # Interceptors, by the method they intercept: &Перед and &После of one method go into one body;
            # &Вместо next to another interceptor, or any next to &ИзменениеИКонтроль, is left to a person
            ic_groups = {}
            for p in ic_pending:
                ic_groups.setdefault("%s|%d" % (p["fe"]["file"]["path"].lower(), p["pl"]["cfg_m"]["decl_idx"]), []).append(p)
            for key, g in ic_groups.items():
                fe = g[0]["fe"]
                cfg_m = g[0]["pl"]["cfg_m"]
                set_bsl_context(g[0]["pl"]["rel"])
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
                # Reuse the check's criteria so a re-run cannot apply the same handler again.
                m2 = {"body_lines": body, "param_names": cfg_m["param_names"]}
                bad = False
                for p in g:
                    if p["pl"].get("empty_around"):
                        bad |= not is_empty_interceptor_body(body)
                        continue
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
                if add_out_name(out_by_file, out_common, os.path.abspath(os.path.join(config_path, o["plan"]["rel"])), o["plan"]["rel"], o["plan"]["name"]):
                    again = True
            if not again:
                for item in top_items:
                    if not item.get("now") or not item["out_names"]:
                        continue
                    module_key = item["out_file"].lower()
                    form_key = os.path.abspath(re.sub(r'[\\/]ext[\\/]form[\\/]module\.bsl$', '/ext/form.xml', module_key))
                    rejected = form_rejections.get(form_key)
                    if not rejected:
                        continue
                    miss = test_form_write(rejected, module_only=True)
                    if miss and miss[0].startswith("form-validate: 24. Module variable"):
                        form_topcode_rejections[module_key] = miss[0]
                        again = True
            if not again:
                for form_key, fe in FORM_EDITS.items():
                    if not fe["ops"] and not fe["failed"]:
                        continue
                    why = fe.get("failure_reason")
                    if not why:
                        miss = test_form_write(fe)
                        if miss:
                            why = "after the transfer the check would not find it: %s" % miss[0]
                    if not why:
                        continue
                    # Replan before publishing either file. A handler staged as an own method belongs
                    # to the rejected form unless the original form already binds it.
                    form_rejections[form_key] = {"path": fe["path"], "cfg_module": fe["cfg_module"], "reason": why}
                    again = True
                    ext_bindings = get_form_bindings(fe["ext_form"])
                    cfg_bindings = get_form_bindings(fe["path"])
                    for o in own_items:
                        pl = o["plan"]
                        cfg_module = fe["cfg_module"]
                        if not o["t"].get("now") or os.path.abspath(os.path.join(config_path, pl["rel"])).lower() != cfg_module.lower():
                            continue
                        name = pl["name"].lower()
                        if name not in ext_bindings or pl["target"]["name"].lower() in cfg_bindings:
                            continue
                        form_handler_rejections[(cfg_module.lower(), name)] = why
                        add_out_name(out_by_file, out_common, cfg_module, pl["rel"], pl["name"])
            if not again:
                break

        # --- Pass 4: write ---
        handled_modules = set()
        for fe in form_rejections.values():
            miss = test_form_write(fe, module_only=True)
            if not miss:
                continue
            handled_modules.add(fe["cfg_module"].lower())
            set_form_write_conflict(fe, recs, config_path, "%s; module not changed" % miss[0])
        changed = list(root_changed)
        for fe in list(FORM_EDITS.values()):
            if not fe["ops"]:
                continue
            handled_modules.add(fe["cfg_module"].lower())
            try:
                changed.extend(write_form_pair(fe))
            except Exception as exc:
                set_form_write_conflict(fe, recs, config_path, "could not write the form and its module: %s" % exc)
        changed.extend(write_file_edits(handled_modules))
        # Metadata: written only after the same comparison and the validator see it in place
        for me in list(MD_EDITS.values()):
            if not me["ops"]:
                continue
            why = "another change of the same file could not be applied" if me["failed"] else None
            if not why:
                # Keep the staged file next to the original so the validator sees Configuration.xml.
                tmp = os.path.join(os.path.dirname(me["path"]), f".cfe-md-{uuid.uuid4().hex}.xml")
                try:
                    miss = test_md_write(me, tmp)
                    if miss:
                        raise ValueError("after the transfer the check would not find it: " + miss[0])
                    with open(me["path"], "rb") as original:
                        if hashlib.sha256(original.read()).digest() != me["before"]:
                            raise ValueError("metadata changed during transfer")
                    replace_form_file(tmp, me["path"])
                except Exception as exc:
                    why = str(exc)
                finally:
                    if os.path.isfile(tmp):
                        os.unlink(tmp)
            if why:
                for op in me["ops"]:
                    op["item"]["status"] = "CONFLICT"
                    op["item"]["now"] = False
                    op["item"]["text"] = "%s — %s; object not changed" % (op["item"]["text"], why)
                    op["item"]["sub"] = ["next: apply by hand, then re-run -Mode check"]
                continue
            MD_WARN.extend(op["item"]["stored"] for op in me["ops"] if op["item"].get("stored"))
            changed.append(me["path"])

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
        # The values the extension wrote into its own attributes do not come along: loud and never cut by
        # the detail budget, so it goes into the footer with the summary
        if MD_WARN:
            footer.append("!!! Stored data is NOT migrated:")
            for l in dict.fromkeys(MD_WARN):
                footer.append("    " + l)
            if any(not note.startswith(("Enum.", "Constant.")) for note in MD_WARN):
                footer.append("    The transfer copies metadata structure. Values the extension")
                footer.append("    wrote into its own attributes stay in the extension's columns and are LOST when it is")
                footer.append("    disabled or removed. Copy them into the configuration's attributes BEFORE that.")
            if any(note.startswith("Catalog.") for note in ROOT_DATA_WARNINGS):
                footer.append("    Copy the catalog records and their tabular sections into the configuration BEFORE disabling or removing the extension.")
            if any(note.startswith("ChartOfCharacteristicTypes.") for note in ROOT_DATA_WARNINGS):
                footer.append("    Migrate characteristic kinds and their data BEFORE disabling or removing the extension.")
            if any("predefined data" in note for note in ROOT_DATA_WARNINGS):
                footer.append("    Verify the predefined elements and migrate their linked data BEFORE disabling or removing the extension.")
            if any(note.startswith("Enum.") for note in ROOT_DATA_WARNINGS):
                footer.append("    Replace stored references to the extension's enumeration values BEFORE disabling or removing the extension.")
            if any(note.startswith("Constant.") for note in ROOT_DATA_WARNINGS):
                footer.append("    Copy the stored constant value into the configuration BEFORE disabling or removing the extension.")
            if any(re.match(r"^(Document|InformationRegister|AccumulationRegister|AccountingRegister|CalculationRegister)[./]", note) for note in ROOT_DATA_WARNINGS):
                footer.append("    Migrate documents, register records and posting movements BEFORE disabling or removing the extension.")
            if any(re.match(r"^(ChartOfAccounts|ChartOfCalculationTypes|ExchangePlan|BusinessProcess|Task)\.", note) for note in ROOT_DATA_WARNINGS):
                footer.append("    Migrate accounts, calculation types, exchange state and process or task records listed above BEFORE disabling or removing the extension.")
            if any(note.startswith("DocumentNumerator.") for note in ROOT_DATA_WARNINGS):
                footer.append("    Verify numbering continuity for documents using the transferred numerators.")
        if changed:
            footer.append("Changed files:")
            for c in changed:
                footer.append("    " + rel_path(config_path, c))
            footer.append("Hint: validate the changed modules, then re-run -Mode check")
        if c_conflict:
            footer.append("Hint: resolve each conflict (see next:), then re-run -Mode transfer")
        if globals().get("FORM_VALIDATE_MISSING"):
            footer.append("Hint: /form-validate is not installed — the written forms were not checked; run /form-validate by hand")
        if globals().get("MD_VALIDATE_MISSING"):
            footer.append("Hint: /meta-validate (or /subsystem-validate) is not installed — the written metadata was not checked; run it by hand")
        if c_wait:
            footer.append("Hint: waiting changes go over by themselves on a re-run of -Mode transfer once their dependencies are in the configuration")
        for ctx2 in BSL_CATALOG.values():
            fk2 = os.path.abspath(os.path.join(config_path, ctx2['rel'])).lower()
            ctx2['methods'].update(file_maps.get(fk2, {}))
        footer += get_bsl_warning_report(recs, config_path)
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
            objects = [{"type": localname(c), "name": inner_text(c).strip()} for c in elem_children(cp["child_objects"])] if cp["child_objects"] is not None else []
            TRANSFER_PREFIX = ext["prefix"] or ""
            initialize_root_transfer(ext, objects, cfg_info, {}, name_match, include_default_roles=args.IncludeDefaultRoles)
            initialize_bsl_catalog(d, config_path, TRANSFER_PREFIX)
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
                    if obj["type"] == "Role" and oid.lower() not in ROOT_OWN:
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
            ext["string_warnings"] = get_bsl_warning_report(ext["objects"], config_path)
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
            footer += ext.get("string_warnings", [])
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
