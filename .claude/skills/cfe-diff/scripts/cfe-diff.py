#!/usr/bin/env python3
# cfe-diff v2.0 — Analyze 1C configuration extension (CFE): overview and transfer check against the main configuration
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


# Control comparison key, as the platform compares a &ИзменениеИКонтроль copy with the original:
# each line trimmed, blank lines dropped, everything else byte-for-byte and case-sensitive
# (inner spaces, comments and letter case are significant). Measured on 8.3.24 and 8.3.27.
def control_key(lines):
    return "\n".join([k for k in (x.strip() for x in lines) if k != ""])


# Parameter count of a signature params text. The platform compares only the number of
# parameters of a &ИзменениеИКонтроль copy (names and default values it ignores).
def param_count(params_text):
    if not params_text or not params_text.strip():
        return 0
    return len([p for p in split_top_level(params_text) if p.strip()])


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
    s = remove_ext_prefix(name, prefix).lower()
    for c in names:
        if remove_ext_prefix(c, prefix).lower() == s:
            return c
    return None


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
    return normalize(remove_ext_prefix(line, prefix)).lower()


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
    m = re.match(r'(?i)(?:не\s*переносить|временно)(?![^\W])\s*[:\-–—]?\s*(.*)$', t)
    return m.group(1).strip() if m else None


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
    return new_item("TEMPORARY", label + fmt_temp_why(mark), item["loc"], item["group"])


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


def get_control_transfer(ext_method, cfg_method, prefix):
    parsed = parse_marked_body(ext_method["body_lines"])
    ops = parsed["ops"]
    v1norm = [code_key(x, prefix) for x in parsed["v1"]]
    v2norm = [code_key(x, prefix) for x in cfg_method["body_lines"]]
    v2sig, v2map = significant_projection(v2norm)
    absorbed = 0
    pending = 0
    disputed = []
    temp = 0
    temp_why = None
    marked_done = 0
    payloads = {i: [x for x in (code_key(y, prefix) for y in o["lines"]) if test_significant(x)]
                for i, o in enumerate(ops) if o["kind"] == "insert"}
    replaced = get_absorbed_in_place(ops, v1norm, v2norm, v2sig, payloads)
    deleted = set()
    for o in ops:
        if o["kind"] == "delete":
            deleted.update(range(o["start"], o["end"] + 1))
    for oi, op in enumerate(ops):
        # res: "absorbed", "pending" or the reason the edit is disputed
        if op["kind"] == "insert":
            payload_sig = payloads[oi]
            # A comment-only insert carries nothing to transfer
            if not payload_sig:
                continue
            if oi in replaced:
                res = "absorbed"
            else:
                after = op["after"]
                before_lines = v1norm[max(0, after - 2):after + 1] if after >= 0 else []
                after_lines = v1norm[after + 1:after + 4]
                k = resolve_insertion_point(v2norm, before_lines, after_lines)
                if k is None:
                    is_absorbed = find_unique_run(v2sig, payload_sig) >= 0
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
                if not is_absorbed and k is not None:
                    is_absorbed = test_run_at(v2sig, payload_sig, sig_start - len(payload_sig))
                if not is_absorbed:
                    is_absorbed = test_payload_beside(v2sig, payload_sig, b_ctx, a_ctx)
                if is_absorbed:
                    res = "absorbed"
                elif k is not None:
                    res = "pending"
                elif b_idx >= 0:
                    res = dispute_reason("insert", parsed["v1"][b_idx], b_ctx, "before", v2norm)
                elif a_idx >= 0:
                    res = dispute_reason("insert", parsed["v1"][a_idx], a_ctx, "after", v2norm)
                else:
                    res = dispute_reason("insert", "", "", "", v2norm)
        else:
            if oi in replaced:
                res = "absorbed"
            else:
                keys = v1norm[op["start"]:op["end"] + 1]
                p = find_unique_run(v2norm, keys)
                if p >= 0:
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
                    if test_delete_absorbed(v2sig, before_ctx, after_ctx):
                        res = "absorbed"
                    else:
                        first = next((x for x in op["lines"] if test_significant(normalize(x))), "")
                        res = dispute_reason("delete", first, "", "", v2norm)
        # A block marked "not for transfer" counts as temporary only while it is not in the configuration
        mark = get_block_temp_mark(op)
        if mark is not None and res != "absorbed":
            temp += 1
            if temp_why is None:
                temp_why = mark
            continue
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
            return {"status": "TEMPORARY", "count": plural(temp, "edit"), "note": temp_why}
        return None
    count = "%d/%d edits" % (absorbed, n)
    if temp > 0:
        count += ", %d temporary" % temp
    if disputed:
        more = " (+%d more)" % (len(disputed) - 1) if len(disputed) > 1 else ""
        return {"status": "DIVERGED", "count": count, "note": disputed[0] + more}
    if absorbed == n:
        st = "TRANSFERRED"
    elif absorbed == 0:
        st = "NOT_TRANSFERRED"
    else:
        st = "PARTIAL"
    note = ("%d marked temporary" % marked_done) if marked_done else ""
    return {"status": st, "count": count, "note": note, "marked": marked_done > 0}


# &Перед/&После/&Вместо and form event interceptors: there is no marked original to compare with,
# so the interceptor's code lines are looked up, in order, in the body of the target method.
# Plumbing (ПродолжитьВызов and the return of its result) is not part of the fix and is skipped;
# the interceptor's parameters are renamed to the original's by position.
TRIVIAL_RE = re.compile(r'^(?:КонецЕсли|Иначе|КонецЦикла|КонецПопытки|Исключение|Возврат|Продолжить|Прервать|EndIf|Else|EndDo|EndTry|Except|Return|Continue|Break)\s*;?$', re.IGNORECASE)


def get_heuristic_transfer(ext_method, cfg_method, prefix):
    proceed_re = re.compile(kw_alt("Proceed") + r'\s*\(', re.IGNORECASE)
    result_vars = []
    lines = []
    for l in ext_method["body_lines"]:
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
    ep = ext_method["param_names"]
    cp = cfg_method["param_names"]
    # One pass for all names: renaming one by one would rename again a name already renamed
    # when the two lists overlap (Источник, Отказ -> Отказ, Режим)
    renames = {}
    for i in range(min(len(ep), len(cp))):
        if ep[i].lower() != cp[i].lower():
            renames[ep[i].lower()] = cp[i].lower()
    if renames:
        rx = re.compile(r'(?<!\w)(?:' + "|".join(re.escape(k) for k in renames) + r')(?!\w)', re.IGNORECASE)
        lines = [rx.sub(lambda m: renames[m.group(0).lower()], x) for x in lines]
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
    r = {"is_borrowed": base is not None, "root": root, "elements": [], "removed": [], "Attributes": [], "Commands": [],
         "Parameters": [], "events": [], "form_props": [], "blocks": [], "total": 0, "main_index": None}
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
        if key not in mi:
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

    # Whole blocks: conditional appearance, command interface
    for bname, xp in (("ConditionalAppearance", "d:Attributes/d:ConditionalAppearance"), ("CommandInterface", "d:CommandInterface")):
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

    r["total"] = (len(r["elements"]) + len(r["removed"]) + len(r["Attributes"]) + len(r["Commands"]) + len(r["Parameters"])
                  + len(r["events"]) + len(r["form_props"]) + len(r["blocks"]))
    return r


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
    added = len([c for c in diff["elements"] if c["kind"] == "added"])
    changed = len(diff["elements"]) - added
    parts = []
    if added:
        parts.append("+" + plural(added, "element"))
    if changed:
        parts.append("~" + plural(changed, "element"))
    if diff["Attributes"]:
        parts.append("+" + plural(len(diff["Attributes"]), "attribute"))
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
    if diff["removed"]:
        parts.append("!%d removed" % len(diff["removed"]))
    return "%s (borrowed): %s" % (label, ", ".join(parts))


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

    for ch in diff["elements"]:
        rec = ch["rec"]
        tag = get_element_tag(rec["node"])
        hit = find_name_in(c_names, rec["name"], prefix)
        if ch["kind"] == "added":
            inn = (" (in: %s)" % rec["parent"]) if rec["parent"] else ""
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            items.append(new_item(st, "+ %s %s%s%s" % (tag, rec["name"], inn, as_text(hit, rec["name"])), "", group))
            continue
        if ch["props"]:
            keys = [p["key"] for p in ch["props"]]
            if not hit:
                items.append(new_item("NOT_TRANSFERRED", "~ %s %s: %s (element not in config)" % (tag, rec["name"], ", ".join(keys)), "", group))
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
                items.append(new_item(st, "~ %s %s: %s%s" % (tag, rec["name"], ", ".join(keys), cnt), "", group))
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
            items.append(new_item(st, "> %s %s: %s" % (tag, rec["name"], move_text(ch)), "", group))

    # Interceptor of a handler: the extension's handler code looked up in the configuration's one
    ext_mod = read_bsl_lines(form["module"])
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
                        items.append(it)
                continue
            hit = find_name_in(cn, x["name"], prefix)
            st = "TRANSFERRED" if hit else "NOT_TRANSFERRED"
            items.append(new_item(st, "+ %s %s%s%s" % (word, x["name"], x["info"], as_text(hit, x["name"])), "", group))

    if diff["form_props"]:
        cpm = get_prop_map(cr, root=True)
        for p in diff["form_props"]:
            r = prop_transfer(cpm, p, prefix)
            st = {"ok": "TRANSFERRED", "pending": "NOT_TRANSFERRED"}.get(r, "DIVERGED")
            why = " (config value differs)" if r == "differs" else ""
            items.append(new_item(st, "~ form " + prop_change_text(p) + why, "", group))
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
            items.append(it)
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
    ic_procs = set()
    for ic in get_interceptors(ext_lines):
        decl = find_decl_after(ext_lines, ic["line"])
        if decl:
            ic_procs.add(decl["name"].lower())
        label = '&%s("%s")' % (ic["raw"], ic["method"])
        loc = "%s:%d" % (rel, ic["line"] + 1)
        ext_m = get_method_safe(ext_lines, decl["name"]) if decl else None
        mark = get_method_temp_mark(ext_lines, ext_m, ic["type"] == "ИзменениеИКонтроль") if ext_m else None
        cfg_m = get_method_safe(cfg_lines, ic["method"])
        it = None
        if not cfg_m:
            why = "module not found in config" if cfg_lines is None else "method not found in config"
            it = new_item("MISSING_IN_CONFIG", "%s (%s)" % (label, why), loc)
        elif not ext_m:
            it = new_item("DIVERGED", label + " (cannot parse the interceptor)", loc)
        elif ic["type"] == "ИзменениеИКонтроль":
            r = get_control_transfer(ext_m, cfg_m, prefix)
            if r:
                note = (" (%s)" % r["note"]) if r["note"] else ""
                it = new_item(r["status"], "%s — %s%s" % (label, r["count"], note), loc)
                if r.get("marked") and r["status"] == "TRANSFERRED":
                    it["marked"] = True
        else:
            h = get_heuristic_transfer(ext_m, cfg_m, prefix)
            if h:
                it = new_item(heuristic_status(h), "%s (heuristic: %d/%d lines)" % (label, h["found"], h["total"]), loc)
        if it:
            items.append(set_temp_mark(it, mark, label))
    cfg_names = get_proc_names(cfg_lines) if cfg_lines is not None else []
    for pn in get_proc_names(ext_lines):
        if pn.lower() in ic_procs or pn.lower() in skip_handlers:
            continue
        ext_m = get_method_safe(ext_lines, pn)
        if not ext_m:
            continue
        loc = "%s:%d" % (rel, ext_m["decl_idx"] + 1)
        mark = get_method_temp_mark(ext_lines, ext_m)
        hit = find_name_in(cfg_names, pn, prefix)
        if not hit:
            it = new_item("NOT_TRANSFERRED", "method " + pn, loc)
        else:
            as_ = (" (found as %s)" % hit) if hit.lower() != pn.lower() else ""
            cfg_m = get_method_safe(cfg_lines, hit)
            same = bool(cfg_m) and "\n".join(sig_lines(ext_m["body_lines"], prefix)) == "\n".join(sig_lines(cfg_m["body_lines"], prefix))
            if same:
                it = new_item("TRANSFERRED", "method %s%s" % (pn, as_), loc)
            else:
                it = new_item("DIVERGED", "method %s%s (body differs)" % (pn, as_), loc)
        items.append(set_temp_mark(it, mark, "method " + pn))
    return items


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
    rec["items"] += form_items
    if cfg_md is None and rec["items"]:
        # Temporary changes stay apart: they are not for transfer, missing object or not
        temp = [it for it in rec["items"] if it["status"] == "TEMPORARY"]
        rest = len(rec["items"]) - len(temp)
        rec["items"] = []
        if rest > 0:
            rec["items"].append(new_item("MISSING_IN_CONFIG", "object not found in config (%s)" % plural(rest, "change")))
        rec["items"] += temp
        return rec
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
    return rec


# ============================================================
# Overview of one object
# ============================================================

def overview_object(ext, obj):
    oid = "%s.%s" % (obj["type"], obj["name"])
    ctx = get_obj_context(ext["dir"], obj["type"], obj["name"])
    if not ctx["known"]:
        return {"id": oid, "kind": "?", "summary": "[?]          %s — unknown type" % oid, "details": []}
    if not ctx["exists"]:
        return {"id": oid, "kind": "?", "summary": "[?]          %s — file not found" % oid, "details": []}
    ind = "    "
    details = []
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

    forms = get_obj_forms(ctx)
    diffs = {}
    form_modules = set()
    for f in forms:
        if f["own"]:
            continue
        d = get_form_diff(f["xml"])
        if d is not None and d["is_borrowed"]:
            diffs[f["label"]] = d
            if d["total"] > 0:
                form_modules.add(path_key(f["module"]))

    # Modules and interceptors
    ic_count = 0
    for bsl in get_obj_modules(ctx, forms):
        rel = rel_path(ext["dir"], bsl)
        lines = read_bsl_lines(bsl)
        ics = get_interceptors(lines)
        ic_count += len(ics)
        if not ics:
            # A changed borrowed form binds its handlers in Form.xml — they are listed with the form
            if path_key(bsl) not in form_modules:
                details.append("%s%s (no interceptors)" % (ind, rel))
            continue
        for ic in ics:
            details.append('%s&%s("%s") — line %d in %s' % (ind, ic["raw"], ic["method"], ic["line"] + 1, rel))

    # Own and borrowed sub-objects
    own = {}
    borrowed_items = 0
    if ctx["md"]["children"] is not None:
        for c in elem_children(ctx["md"]["children"]):
            if not has_element_child(c):
                desc = read_md_object(os.path.join(ctx["obj_dir"], localname(c) + "s", inner_text(c).strip() + ".xml"))
                is_own = not (desc is not None and test_adopted_node(desc["props"]))
            else:
                is_own = not test_adopted_node(c)
            if not is_own:
                borrowed_items += 1
                continue
            w = kind_word(localname(c))
            own[w] = own.get(w, 0) + 1
    own_parts = ["own " + plural(v, w) for w, v in own.items()]
    cp = list(own_parts)
    if borrowed_items:
        cp.append(plural(borrowed_items, "borrowed item"))
    if cp:
        details.append("%sChildObjects: %s" % (ind, ", ".join(cp)))

    # Forms
    changed_forms = 0
    unchanged_forms = 0
    for f in forms:
        if f["own"]:
            if ctx["type"] != "CommonForm":
                details.append("%s%s (own)" % (ind, f["label"]))
            continue
        if f["label"] not in diffs:
            details.append("%s%s (?)" % (ind, f["label"]))
            continue
        d = diffs[f["label"]]
        if d["total"] == 0:
            unchanged_forms += 1
        else:
            changed_forms += 1
        details += format_form_diff(d, f["label"], ind)

    sp = []
    if ic_count:
        sp.append(plural(ic_count, "interceptor"))
    sp += own_parts
    if changed_forms:
        sp.append(plural(changed_forms, "form") + " changed")
    if unchanged_forms:
        sp.append(plural(unchanged_forms, "form") + " unchanged")
    tail = (" — " + ", ".join(sp)) if sp else ""
    return {"id": oid, "kind": "borrowed", "summary": "[BORROWED]   " + oid + tail, "details": details}


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


def get_transfer_details(ext, rec, expand_list):
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
    form_of = {}
    for s in order:
        m = re.match(r'^(.*)/Ext/Form(?:\.xml|/Module\.bsl)$', s)
        form_of[s] = m.group(1) if m else ""
    view = {}
    for s in order:
        opened = test_expanded(ext, rec["id"], s, expand_list)
        shown = [it for it in by_sec[s] if opened or it["status"] != "TRANSFERRED" or it.get("marked")]
        view[s] = {"shown": shown, "hidden": len(by_sec[s]) - len(shown)}

    def emit(s):
        v = view[s]
        pad = "      " if s else "    "
        if s:
            if not v["shown"]:
                lines.append("    %s: %d transferred" % (s, v["hidden"]))
                return
            lines.append("    %s:" % s)
        for it in v["shown"]:
            loc = ("  " + it["loc"]) if it["loc"] else ""
            lines.append("%s%s%s%s" % (pad, fmt_status(it["status"]), it["text"], loc))
        if v["hidden"] > 0:
            lines.append("%s… %d transferred" % (pad, v["hidden"]))

    forms = []
    for s in order:
        if form_of[s] and form_of[s] not in forms:
            forms.append(form_of[s])
    for s in order:
        if not form_of[s]:
            emit(s)
            folded += view[s]["hidden"]
    for fd in forms:
        secs = sorted([s for s in order if form_of[s] == fd], key=lambda x: 0 if x.endswith(".xml") else 1)
        hidden = sum(view[s]["hidden"] for s in secs)
        shown = sum(len(view[s]["shown"]) for s in secs)
        folded += hidden
        if shown == 0:
            lines.append("    %s: %d transferred" % (fd, hidden))
            continue
        for s in secs:
            emit(s)
    return {"lines": lines, "folded": folded}


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
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Analyze 1C configuration extension (CFE): overview and transfer check", allow_abbrev=False)
    parser.add_argument("-ExtensionPath", required=True, help="Extension dump root, comma-separated list, or folder of extensions")
    parser.add_argument("-ConfigPath", default="", help="Main configuration dump root (required for -Mode transfer)")
    parser.add_argument("-Mode", default="overview", help="overview | transfer")
    parser.add_argument("-Name", default="", help="Objects to detail: Type.Name[,Type.Name]")
    parser.add_argument("-Limit", type=int, default=150)
    parser.add_argument("-Offset", type=int, default=0)
    parser.add_argument("-Expand", default="", help="Open folded transferred changes: Type.Name, a section path, or *")
    parser.add_argument("-OutFile", default="")
    args = ci_parse_args(parser)

    mode_map = {"overview": "overview", "transfer": "transfer", "a": "overview", "b": "transfer"}
    mode_key = args.Mode.strip().lower()
    if mode_key not in mode_map:
        die("Invalid -Mode '%s'. Expected: overview, transfer" % args.Mode)
    mode = mode_map[mode_key]

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

    cfg_info = None
    config_path = ""
    if args.ConfigPath:
        config_path = resolve_input_path(args.ConfigPath)
        cfg_info = read_configuration_props(config_path)
        if cfg_info is None:
            die("Config Configuration.xml not found: " + os.path.join(config_path, "Configuration.xml"))
    if mode == "transfer" and cfg_info is None:
        die("-Mode transfer needs -ConfigPath (the main configuration to check against)")

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
               "roles": 0, "borrowed": 0, "own": 0, "matched": 0}
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
                if mode == "transfer":
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
                    # Asked for by name or opened with -Expand: details even when all is transferred
                    rec["asked"] = bool(name_filter) or test_expanded(ext, rec["id"], "", expand_list)
                    ext["objects"].append(rec)
                else:
                    rec = overview_object(ext, obj)
                    if rec["kind"] == "borrowed":
                        ext["borrowed"] += 1
                    elif rec["kind"] == "own":
                        ext["own"] += 1
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
            if mode == "overview" or not o["complete"] or o.get("asked"):
                full_count += len(o["details"])
    show_details = bool(name_filter) or full_count <= DETAIL_BUDGET

    # --- Body ---
    body = []
    any_folded = False
    for ext in exts:
        target = (" -> " + cfg_info["name"]) if mode == "transfer" else ""
        body.append("=== cfe-diff %s: %s (%s)%s ===" % (mode, ext["name"], ext["purpose"], target))
        if ext["prefix"]:
            body.append("NamePrefix: " + ext["prefix"])
        body.append("")
        shown = 0
        for o in ext["objects"]:
            if mode == "transfer" and o["complete"] and not show_details:
                continue
            body.append(o["summary"])
            shown += 1
            if show_details and (mode == "overview" or not o["complete"] or o.get("asked")):
                body += o["details"]
                if o.get("folded"):
                    any_folded = True
        if shown == 0:
            if mode == "overview":
                body.append("No objects (besides Language) in extension.")
            elif ext["objects"]:
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
        if mode == "transfer":
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
        else:
            footer.append("=== Summary %s: %d borrowed, %d own objects ===" % (ext["name"], ext["borrowed"], ext["own"]))
    if mode == "transfer" and len(exts) > 1:
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
        footer.append("Hint: use -Expand <Type.Name> or a section path to list transferred changes, -Expand * for all")

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

    if mode == "transfer" and failed:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
