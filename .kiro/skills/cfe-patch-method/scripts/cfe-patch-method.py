#!/usr/bin/env python3
# cfe-patch-method v2.5 — Source-aware method interceptor for 1C extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

TYPE_DIR_MAP = {
    "Catalog": "Catalogs", "Document": "Documents", "Enum": "Enums",
    "CommonModule": "CommonModules", "Report": "Reports", "DataProcessor": "DataProcessors",
    "ExchangePlan": "ExchangePlans", "ChartOfAccounts": "ChartsOfAccounts",
    "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
    "ChartOfCalculationTypes": "ChartsOfCalculationTypes",
    "BusinessProcess": "BusinessProcesses", "Task": "Tasks",
    "InformationRegister": "InformationRegisters", "AccumulationRegister": "AccumulationRegisters",
    "AccountingRegister": "AccountingRegisters", "CalculationRegister": "CalculationRegisters",
}
# accept plural forms too
for _v in list(TYPE_DIR_MAP.values()):
    TYPE_DIR_MAP[_v] = _v

# InterceptorType -> Russian decorator keyword
DECORATOR_MAP = {
    "Before": "Перед", "After": "После", "Instead": "Вместо",
    "ModificationAndControl": "ИзменениеИКонтроль",
}

CONTEXT_RE = re.compile(
    r'^&(НаКлиенте|НаСервере|НаСервереБезКонтекста|НаКлиентеНаСервереБезКонтекста|НаКлиентеНаСервере)\s*$'
)


def get_module_rel_path(module_path):
    parts = module_path.split(".")
    if len(parts) < 2:
        raise ValueError(
            "Invalid ModulePath format: %s. Expected: Type.Name.Module, "
            "Type.Name.Form.FormName or CommonModule.Name" % module_path
        )
    obj_type = parts[0]
    obj_name = parts[1]
    if obj_type not in TYPE_DIR_MAP:
        raise ValueError("Unknown object type: %s" % obj_type)
    dir_name = TYPE_DIR_MAP[obj_type]

    if obj_type == "CommonModule":
        return [dir_name, obj_name, "Ext", "Module.bsl"]
    if len(parts) >= 4 and parts[2] == "Form":
        form_name = parts[3]
        return [dir_name, obj_name, "Forms", form_name, "Ext", "Form", "Module.bsl"]
    if len(parts) >= 3:
        module_name = parts[2]
        module_file_map = {
            "ObjectModule": "ObjectModule.bsl",
            "ManagerModule": "ManagerModule.bsl",
            "RecordSetModule": "RecordSetModule.bsl",
            "CommandModule": "CommandModule.bsl",
            "ValueManagerModule": "ValueManagerModule.bsl",
        }
        return [dir_name, obj_name, "Ext", module_file_map.get(module_name, module_name + ".bsl")]
    raise ValueError("Invalid ModulePath format: %s" % module_path)


def get_rel_parts_from_file_path(path):
    segs = [s for s in path.replace("\\", "/").split("/") if s]
    anchors = set(TYPE_DIR_MAP.values())
    for i in range(len(segs)):
        if segs[i] in anchors:
            return segs[i:]
    return None


def read_lines(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        text = f.read()
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def write_bsl(path, lines):
    text = "\r\n".join(lines) + "\r\n"
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        f.write(text)


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


def effective_condition(frame):
    conds = frame["conds"]
    n = len(conds)
    if frame["in_else"]:
        return " И ".join("НЕ (%s)" % c for c in conds)
    if n == 1:
        return conds[0]
    parts = ["НЕ (%s)" % conds[j] for j in range(n - 1)]
    parts.append(conds[n - 1])
    return " И ".join(parts)


def get_enclosing_chain(lines, target_idx):
    stack = []
    for i in range(target_idx):
        t = lines[i].strip()
        m = re.match(r'^#Область\s+(\S+)', t)
        if m:
            stack.append({"kind": "region", "name": m.group(1)})
            continue
        if re.match(r'^#КонецОбласти', t):
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "region":
                    del stack[k]
                    break
            continue
        m = re.match(r'^#Если\s+(.+?)\s+Тогда', t)
        if m:
            stack.append({"kind": "if", "conds": [m.group(1).strip()], "in_else": False})
            continue
        m = re.match(r'^#ИначеЕсли\s+(.+?)\s+Тогда', t)
        if m:
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "if":
                    stack[k]["conds"].append(m.group(1).strip())
                    stack[k]["in_else"] = False
                    break
            continue
        if re.match(r'^#Иначе(\s|$)', t):
            for k in range(len(stack) - 1, -1, -1):
                if stack[k]["kind"] == "if":
                    stack[k]["in_else"] = True
                    break
            continue
        if re.match(r'^#КонецЕсли', t):
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
            chain.append({"kind": "if", "cond": effective_condition(f)})
    return chain


def extract_method(lines, method_name):
    decl_re = re.compile(
        r'^\s*(Асинх\s+)?(Процедура|Функция)\s+(' + re.escape(method_name) + r')\s*\(',
        re.IGNORECASE,
    )
    for i in range(len(lines)):
        m = decl_re.match(lines[i])
        if not m:
            continue
        is_async = bool(m.group(1))
        keyword = m.group(2)
        canonical = m.group(3)
        is_function = keyword.lower() == "функция"

        sig = read_signature(lines, i)
        if not sig:
            raise ValueError("Не удалось разобрать сигнатуру метода '%s'" % method_name)
        params_text, sig_end = sig

        param_names = []
        if params_text.strip():
            for seg in split_top_level(params_text):
                s = re.sub(r'^Знач\s+', '', seg.strip())
                mm = re.match(r'^([\w]+)', s)
                if mm:
                    param_names.append(mm.group(1))

        end_re = re.compile(r'^\s*КонецФункции\b' if is_function else r'^\s*КонецПроцедуры\b',
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

        chain = get_enclosing_chain(lines, i)

        return {
            "canonical": canonical,
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


def get_interceptors(lines):
    result = []
    pat = re.compile(r'^&(Перед|После|ИзменениеИКонтроль|Вместо)\("([^"]+)"\)')
    for i in range(len(lines)):
        m = pat.match(lines[i].strip())
        if m:
            result.append({"type": m.group(1), "method": m.group(2), "line": i})
    return result


def get_proc_names(lines):
    names = []
    pat = re.compile(r'^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+([\w]+)\s*\(', re.IGNORECASE)
    for line in lines:
        m = pat.match(line)
        if m:
            names.append(m.group(1))
    return names


def build_interceptor_core(method, interceptor_type, interceptor_name):
    decorator_ru = DECORATOR_MAP[interceptor_type]
    async_prefix = "Асинх " if method["is_async"] else ""
    keyword = "Функция" if method["is_function"] else "Процедура"
    end_keyword = "КонецФункции" if method["is_function"] else "КонецПроцедуры"

    lines = []
    if method["context"]:
        lines.append(method["context"])
    lines.append('&%s("%s")' % (decorator_ru, method["canonical"]))
    lines.append("%s%s %s(%s)" % (async_prefix, keyword, interceptor_name, method["params_text"]))

    if interceptor_type == "Before":
        lines.append("\t// TODO: код перед вызовом оригинального метода")
    elif interceptor_type == "After":
        lines.append("\t// TODO: код после вызова оригинального метода")
    elif interceptor_type == "Instead":
        names_joined = ", ".join(method["param_names"])
        if method["is_function"]:
            lines.append("\tРезультат = ПродолжитьВызов(%s);" % names_joined)
            lines.append("\t// TODO: доработать поведение")
            lines.append("\tВозврат Результат;")
        else:
            lines.append("\tПродолжитьВызов(%s);" % names_joined)
            lines.append("\t// TODO: доработать поведение")
    elif interceptor_type == "ModificationAndControl":
        lines.extend(method["body_lines"])

    lines.append(end_keyword)
    return lines


def build_wrapped_block(chain_arr, core):
    """Wrap core with region/preprocessor lines, adding blank lines around each boundary."""
    b = []
    for w in chain_arr:
        b.append("#Область %s" % w["name"] if w["kind"] == "region" else "#Если %s Тогда" % w["cond"])
        b.append("")
    b.extend(core)
    for w in reversed(chain_arr):
        b.append("")
        b.append("#КонецОбласти" if w["kind"] == "region" else "#КонецЕсли")
    return b


def normalize(line):
    return re.sub(r'\s+', ' ', line).strip()


def parse_marked_body(body_lines):
    v1 = []
    ops = []
    i = 0
    n = len(body_lines)
    while i < n:
        t = body_lines[i].strip()
        if t == "#Вставка":
            ins = []
            i += 1
            while i < n and body_lines[i].strip() != "#КонецВставки":
                ins.append(body_lines[i])
                i += 1
            i += 1
            ops.append({"kind": "insert", "after": len(v1) - 1, "lines": ins})
        elif t == "#Удаление":
            start_idx = len(v1)
            i += 1
            dels = []
            while i < n and body_lines[i].strip() != "#КонецУдаления":
                dels.append(body_lines[i])
                v1.append(body_lines[i])
                i += 1
            i += 1
            ops.append({"kind": "delete", "start": start_idx, "end": len(v1) - 1, "lines": dels})
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


def test_delete_absorbed(v2norm, before_ctx, after_ctx):
    """True if a deletion is already applied in v2: before/after context are now adjacent
    (nothing between them), or the missing side sits at a body boundary (None = boundary)."""
    if before_ctx is not None and after_ctx is not None:
        for i in range(len(v2norm) - 1):
            if v2norm[i] == before_ctx and v2norm[i + 1] == after_ctx:
                return True
        return False
    if before_ctx is None and after_ctx is not None:
        return len(v2norm) > 0 and v2norm[0] == after_ctx
    if before_ctx is not None and after_ctx is None:
        return len(v2norm) > 0 and v2norm[-1] == before_ctx
    return False


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


def truncate(s, n=60):
    t = s.strip()
    return (t[:n] + "…") if len(t) > n else t


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Source-aware method interceptor for 1C extension (CFE)",
        allow_abbrev=False,
    )
    parser.add_argument("-ExtensionPath", required=True)
    parser.add_argument("-ConfigPath", required=False, default="")
    parser.add_argument("-ModulePath", required=False, default="")
    parser.add_argument("-MethodName", required=False, default="")
    parser.add_argument("-InterceptorType", required=False, default="",
                        choices=["", "Before", "After", "Instead", "ModificationAndControl"])
    parser.add_argument("-Check", action="store_true")
    parser.add_argument("-Actualize", action="store_true")
    args = parser.parse_args()

    extension_path = args.ExtensionPath
    config_path = args.ConfigPath
    module_path = args.ModulePath
    method_name = args.MethodName
    interceptor_type = args.InterceptorType
    check_mode = args.Check
    actualize_mode = args.Actualize

    # --- Resolve extension path ---
    if not os.path.isabs(extension_path):
        extension_path = os.path.join(os.getcwd(), extension_path)
    if os.path.isfile(extension_path):
        extension_path = os.path.dirname(extension_path)
    cfg_file = os.path.join(extension_path, "Configuration.xml")
    if not os.path.isfile(cfg_file):
        die("Configuration.xml не найден в расширении: %s" % extension_path)

    # --- Read NamePrefix ---
    ns = {"md": "http://v8.1c.ru/8.3/MDClasses"}
    name_prefix = "Расш_"
    try:
        root = ET.parse(cfg_file).getroot()
        props = root.find(".//md:Configuration/md:Properties", ns)
        if props is not None:
            pn = props.find("md:NamePrefix", ns)
            if pn is not None and pn.text:
                name_prefix = pn.text
            nn = props.find("md:Name", ns)
            if nn is not None and nn.text:
                ext_name = nn.text
    except ET.ParseError:
        pass
    if 'ext_name' not in dir():
        ext_name = "Расширение"

    # --- Batch modes: -Check / -Actualize over &ИзменениеИКонтроль ---
    if check_mode or actualize_mode:
        if check_mode and actualize_mode:
            die("Укажите либо -Check, либо -Actualize, не оба.")
        if not config_path:
            die("Для -Check/-Actualize нужен -ConfigPath (сверка с исходником).")
        cp = config_path
        if not os.path.isabs(cp):
            cp = os.path.join(os.getcwd(), cp)
        if os.path.isfile(cp):
            cp = os.path.dirname(cp)
        if not os.path.isfile(os.path.join(cp, "Configuration.xml")):
            die("Configuration.xml не найден в конфигурации-источнике: %s" % cp)
        report_only = check_mode
        verb = "КОНТРОЛЬ" if check_mode else "АКТУАЛИЗАЦИЯ"
        safe = re.sub(r'[\\/:*?"<>|]', "_", ext_name)
        run_root = os.path.join(tempfile.gettempdir(), "cfe-resync", safe)
        if actualize_mode and os.path.isdir(run_root):
            shutil.rmtree(run_root, ignore_errors=True)

        targets = []
        if module_path:
            rp = get_module_rel_path(module_path)
            mb = os.path.join(extension_path, *rp)
            if os.path.isfile(mb):
                targets.append(mb)
        else:
            for dirpath, _dirs, files in os.walk(extension_path):
                for fn in files:
                    if fn.endswith(".bsl"):
                        targets.append(os.path.join(dirpath, fn))

        results = []
        for tb in targets:
            scan = read_lines(tb)
            mnames = [ic["method"] for ic in get_interceptors(scan) if ic["type"] == "ИзменениеИКонтроль"]
            if method_name:
                mnames = [m for m in mnames if m.lower() == method_name.lower()]
            seen = set(); uniq = []
            for m in mnames:
                if m.lower() not in seen:
                    seen.add(m.lower()); uniq.append(m)
            if not uniq:
                continue
            rel = rel_parts_under(extension_path, tb)
            logical_module = module_path_from_rel(rel)
            src_bsl2 = os.path.join(cp, *rel)
            rel_no_bsl = os.path.join(*rel)
            if rel_no_bsl.endswith(".bsl"):
                rel_no_bsl = rel_no_bsl[:-4]
            for mname in uniq:
                mid = "%s.%s" % (logical_module, mname)
                if not os.path.isfile(src_bsl2):
                    results.append({"id": mid, "status": "ИСТОЧНИК-НЕ-НАЙДЕН", "ext_bsl": tb}); continue
                m = extract_method(read_lines(src_bsl2), mname)
                if not m:
                    results.append({"id": mid, "status": "МЕТОД-ИСЧЕЗ", "ext_bsl": tb}); continue
                tb_lines = read_lines(tb)
                ic = next((x for x in get_interceptors(tb_lines)
                           if x["type"] == "ИзменениеИКонтроль" and x["method"].lower() == mname.lower()), None)
                if not ic:
                    continue
                folder = os.path.join(run_root, rel_no_bsl, m["canonical"])
                results.append(resync_one(tb, tb_lines, ic, m, logical_module, folder, report_only))

        total = len(results)
        actual = sum(1 for r in results if r["status"] == "АКТУАЛЕН")
        print("[%s] %s -> %s   (на контроле: %d)" % (verb, ext_name, cp, total))
        listed = [r for r in results if r["status"] != "АКТУАЛЕН"]
        for pr in listed:
            line = "  %-22s %s" % (pr["status"], pr["id"])
            if pr.get("reason"):
                line += "   %s" % pr["reason"]
            print(line)
            for n in pr.get("absorbed_notes", []):
                print("     ⚠ комментарий не перенесён (код в основной конфигурации): %s" % n)
        transf = sum(1 for r in results if r["status"] == "ПЕРЕНЕСЕНО В ОСНОВНУЮ")
        if check_mode:
            drift = sum(1 for r in results if r["status"] == "ДРЕЙФ")
            confl = sum(1 for r in results if r["status"] == "КОНФЛИКТ")
            gone = sum(1 for r in results if r["status"] in ("МЕТОД-ИСЧЕЗ", "ИСТОЧНИК-НЕ-НАЙДЕН"))
            print("Итог: %d/%d актуальны · дрейф: %d · конфликтов: %d · перенесено в основную: %d · внимания: %d"
                  % (actual, total, drift, confl, transf, gone))
            if (drift + confl + gone) > 0:
                print("Починить: /cfe-patch-method -Actualize -ExtensionPath %s -ConfigPath %s" % (extension_path, cp))
                sys.exit(1)
            elif transf > 0:
                print("Перенесённые в основную конфигурацию правки подчистит: /cfe-patch-method -Actualize -ExtensionPath %s -ConfigPath %s" % (extension_path, cp))
                sys.exit(0)
            sys.exit(0)
        else:
            upd = sum(1 for r in results if r["status"] == "АКТУАЛИЗИРОВАН")
            part = sum(1 for r in results if r["status"] == "ЧАСТИЧНО")
            print("Итог: %d/%d актуальны · актуализировано: %d · частично: %d · перенесено в основную: %d" % (actual, total, upd, part, transf))
            idx = write_resync_index(run_root, results, ext_name, cp, verb)
            if idx:
                print("Merge-воркспейс конфликтов (см. index.md): %s" % idx)
            sys.exit(0)

    # --- Generation mode: require ModulePath + MethodName + InterceptorType ---
    if not (module_path and method_name and interceptor_type):
        die("Нужны -ModulePath, -MethodName, -InterceptorType (генерация перехватчика). "
            "Для проверки/актуализации контролируемых методов используйте -Check или -Actualize.")

    # --- Resolve module file paths (ModulePath = logical name OR path to a .bsl) ---
    has_config = bool(config_path)
    if has_config:
        if not os.path.isabs(config_path):
            config_path = os.path.join(os.getcwd(), config_path)
        if os.path.isfile(config_path):
            config_path = os.path.dirname(config_path)

    is_file_path = bool(re.search(r'[\\/]', module_path)) or module_path.endswith(".bsl")

    if is_file_path:
        mp_abs = module_path if os.path.isabs(module_path) else os.path.join(os.getcwd(), module_path)
        rel_parts = get_rel_parts_from_file_path(module_path)
        if not rel_parts:
            die("Не удалось определить объект по пути модуля: %s\n"
                "(нет распознаваемой типовой папки — Catalogs/Documents/CommonModules/…)" % module_path)
        ext_bsl = os.path.join(extension_path, *rel_parts)
        if has_config:
            src_bsl = os.path.join(config_path, *rel_parts)
        else:
            ext_root_abs = os.path.normcase(os.path.abspath(extension_path)).rstrip("\\/")
            mp_full = os.path.normcase(os.path.abspath(mp_abs))
            if mp_full.startswith(ext_root_abs):
                die("Путь модуля указывает внутрь расширения, а не на источник. "
                    "Укажите путь к модулю-источнику или -ConfigPath.")
            src_bsl = mp_abs
    else:
        if not has_config:
            die("Не указан -ConfigPath. Укажите путь к исходникам конфигурации "
                "или передайте путь к файлу модуля в -ModulePath.")
        if not os.path.isfile(os.path.join(config_path, "Configuration.xml")):
            die("Configuration.xml не найден в конфигурации-источнике: %s" % config_path)
        rel_parts = get_module_rel_path(module_path)
        ext_bsl = os.path.join(extension_path, *rel_parts)
        src_bsl = os.path.join(config_path, *rel_parts)

    if not os.path.isfile(src_bsl):
        die("Модуль-источник не найден: %s\n(проверьте ModulePath и ConfigPath)" % src_bsl)

    # --- Extract original method ---
    src_lines = read_lines(src_bsl)
    method = extract_method(src_lines, method_name)
    if not method:
        die("Метод '%s' не найден в модуле-источнике: %s" % (method_name, src_bsl))

    # --- Guard: functions cannot use Before/After ---
    if method["is_function"] and interceptor_type in ("Before", "After"):
        die("Метод '%s' — функция. Для функций доступны только Instead и ModificationAndControl "
            "(перехват &Перед/&После к функциям неприменим)." % method_name)

    decorator_ru = DECORATOR_MAP[interceptor_type]

    # --- Read existing extension module (if any) ---
    ext_exists = os.path.isfile(ext_bsl)
    ext_lines = read_lines(ext_bsl) if ext_exists else []

    existing_interceptors = get_interceptors(ext_lines) if ext_exists else []
    existing_proc_names = get_proc_names(ext_lines) if ext_exists else []

    dup = None
    for ic in existing_interceptors:
        if ic["type"] == decorator_ru and ic["method"].lower() == method_name.lower():
            dup = ic
            break

    if dup:
        if interceptor_type != "ModificationAndControl":
            print('[ПРОПУЩЕН] Перехватчик &%s("%s") уже есть в модуле — дубль не создаётся.'
                  % (decorator_ru, method_name))
            print("     Файл: %s" % ext_bsl)
            sys.exit(0)
        rel = rel_parts_under(extension_path, ext_bsl)
        logical_module = module_path_from_rel(rel)
        rel_no_bsl = os.path.join(*rel)
        if rel_no_bsl.endswith(".bsl"):
            rel_no_bsl = rel_no_bsl[:-4]
        safe = re.sub(r'[\\/:*?"<>|]', "_", ext_name)
        run_root = os.path.join(tempfile.gettempdir(), "cfe-resync", safe)
        folder = os.path.join(run_root, rel_no_bsl, method["canonical"])
        res = resync_one(ext_bsl, ext_lines, dup, method, logical_module, folder, False)
        st = res["status"]
        if st == "АКТУАЛЕН":
            print('[АКТУАЛЕН] &ИзменениеИКонтроль("%s") — оригинал не менялся, изменений нет.' % method_name)
        elif st == "АКТУАЛИЗИРОВАН":
            msg = '[АКТУАЛИЗИРОВАН] &ИзменениеИКонтроль("%s") — тело обновлено, правок сохранено: %d' % (method_name, res.get("transferred", 0))
            if res.get("absorbed", 0) > 0:
                msg += ", перенесено в основную конфигурацию: %d" % res["absorbed"]
            print(msg)
        elif st == "ПЕРЕНЕСЕНО В ОСНОВНУЮ":
            print('[ПЕРЕНЕСЕНО В ОСНОВНУЮ] &ИзменениеИКонтроль("%s") — все правки (%d) уже в основной конфигурации, перехватчик можно удалить.'
                  % (method_name, res.get("absorbed", 0)))
        elif st == "ЧАСТИЧНО":
            idx = write_resync_index(run_root, [res], ext_name, config_path, "АКТУАЛИЗАЦИЯ")
            msg = '[АКТУАЛИЗИРОВАН-ЧАСТИЧНО] &ИзменениеИКонтроль("%s") — сохранено: %d, конфликтов: %d' % (method_name, res.get("transferred", 0), res.get("disputed", 0))
            if res.get("absorbed", 0) > 0:
                msg += ", перенесено в основную: %d" % res["absorbed"]
            print(msg)
            print("     Конфликт помечен // [РЕСИНК-КОНФЛИКТ]. Папка метода: %s" % res.get("conflict_dir"))
            if idx:
                print("     Индекс: %s" % idx)
        else:
            print('[%s] &ИзменениеИКонтроль("%s") — %s' % (st, method_name, res.get("reason", "")))
        for n in res.get("absorbed_notes", []):
            print("     ⚠ комментарий не перенесён (код в основной конфигурации): %s" % n)
        print("     Файл: %s" % ext_bsl)
        sys.exit(0)

    # --- New interceptor ---
    candidate = name_prefix + method["canonical"]
    taken = [n.lower() for n in existing_proc_names]
    interceptor_name = candidate
    if candidate.lower() in taken:
        if interceptor_type == "ModificationAndControl":
            interceptor_name = candidate + "_ИзменениеИКонтроль"
        else:
            interceptor_name = candidate + "_" + decorator_ru

    core = build_interceptor_core(method, interceptor_type, interceptor_name)

    place_new(ext_bsl, ext_lines, ext_exists, method["chain"], core)

    # emit summary
    placement = place_new.placement
    print('[OK] Перехватчик &%s("%s") — %s' % (decorator_ru, method_name, placement))
    print("     Файл:       %s" % ext_bsl)
    print("     Процедура:  %s(%s)" % (interceptor_name, normalize(method["params_text"])))
    if method["context"]:
        print("     Контекст:   %s" % method["context"])
    if method["chain"]:
        desc = " > ".join(
            ("Область:%s" % w["name"]) if w["kind"] == "region" else ("Если:%s" % w["cond"])
            for w in method["chain"]
        )
        print("     Обрамление: %s" % desc)


def place_new(ext_bsl, ext_lines, ext_exists, chain, core):
    enc_bom = True  # noqa

    # find innermost region in chain that already exists in the extension module
    reuse_region_idx = -1
    reuse_line_idx = -1
    if ext_exists:
        for c in range(len(chain) - 1, -1, -1):
            if chain[c]["kind"] == "region":
                rname = chain[c]["name"]
                rre = re.compile(r'^#Область\s+' + re.escape(rname) + r'\s*$')
                for li in range(len(ext_lines)):
                    if rre.match(ext_lines[li].strip()):
                        reuse_region_idx = c
                        reuse_line_idx = li
                        break
            if reuse_region_idx >= 0:
                break

    if reuse_region_idx >= 0:
        inner_chain = chain[reuse_region_idx + 1:]
        block = build_wrapped_block(inner_chain, core)

        depth = 0
        close_idx = -1
        for li in range(reuse_line_idx, len(ext_lines)):
            t = ext_lines[li].strip()
            if re.match(r'^#Область\s', t):
                depth += 1
            elif re.match(r'^#КонецОбласти', t):
                depth -= 1
                if depth == 0:
                    close_idx = li
                    break
        if close_idx < 0:
            die("Не найден #КонецОбласти для региона (переиспользование)")

        # strip trailing blank lines of the region content, then insert with air
        last_content = close_idx - 1
        while last_content >= 0 and ext_lines[last_content].strip() == "":
            last_content -= 1
        out = list(ext_lines[:last_content + 1])
        out.append("")
        out.extend(block)
        out.append("")
        out.extend(ext_lines[close_idx:])
        write_bsl(ext_bsl, out)
        place_new.placement = "в существующий регион '%s'" % chain[reuse_region_idx]["name"]
        return

    # full wrapper chain, append (or create)
    block = build_wrapped_block(chain, core)
    block_text = "\r\n".join(block) + "\r\n"

    bsl_dir = os.path.dirname(ext_bsl)
    if not os.path.isdir(bsl_dir):
        os.makedirs(bsl_dir, exist_ok=True)

    if ext_exists:
        with open(ext_bsl, "r", encoding="utf-8-sig", newline="") as f:
            existing = f.read()
        if not existing.strip():
            with open(ext_bsl, "w", encoding="utf-8-sig", newline="") as f:
                f.write(block_text)
            place_new.placement = "заполнен модуль"
        else:
            sep = "\r\n" if existing.endswith("\n") else "\r\n\r\n"
            with open(ext_bsl, "w", encoding="utf-8-sig", newline="") as f:
                f.write(existing + sep + block_text)
            place_new.placement = "дописан в модуль"
    else:
        with open(ext_bsl, "w", encoding="utf-8-sig", newline="") as f:
            f.write(block_text)
        place_new.placement = "создан модуль"


DIR_TO_TYPE = {
    "Catalogs": "Catalog", "Documents": "Document", "Enums": "Enum", "CommonModules": "CommonModule",
    "Reports": "Report", "DataProcessors": "DataProcessor", "ExchangePlans": "ExchangePlan",
    "ChartsOfAccounts": "ChartOfAccounts", "ChartsOfCharacteristicTypes": "ChartOfCharacteristicTypes",
    "ChartsOfCalculationTypes": "ChartOfCalculationTypes", "BusinessProcesses": "BusinessProcess",
    "Tasks": "Task", "InformationRegisters": "InformationRegister",
    "AccumulationRegisters": "AccumulationRegister", "AccountingRegisters": "AccountingRegister",
    "CalculationRegisters": "CalculationRegister",
}


def module_path_from_rel(rel_parts):
    dir0, name = rel_parts[0], rel_parts[1]
    typ = DIR_TO_TYPE.get(dir0, dir0)
    if dir0 == "CommonModules":
        return "CommonModule.%s" % name
    if len(rel_parts) >= 7 and rel_parts[2] == "Forms":
        return "%s.%s.Form.%s" % (typ, name, rel_parts[3])
    mod = rel_parts[-1][:-4] if rel_parts[-1].endswith(".bsl") else rel_parts[-1]
    return "%s.%s.%s" % (typ, name, mod)


def rel_parts_under(root, full_path):
    rel = os.path.relpath(os.path.abspath(full_path), os.path.abspath(root))
    return [s for s in rel.replace("\\", "/").split("/") if s and s != "."]


def conflict_reason(disputed):
    kinds = set(d["kind"] for d in disputed)
    parts = []
    if "insert" in kinds:
        parts.append("якорь вставки изменён")
    if "delete" in kinds:
        parts.append("удаляемое исчезло")
    return "; ".join(parts)


def write_conflict_folder(folder, method_id, ext_bsl, existing_name, method, v1, marked_body, v2, v1norm, v2norm, disputed):
    os.makedirs(folder, exist_ok=True)
    write_bsl(os.path.join(folder, "base.bsl"), v1)
    write_bsl(os.path.join(folder, "local.bsl"), marked_body)
    write_bsl(os.path.join(folder, "remote.bsl"), v2)
    md = []
    md.append("# %s" % method_id)
    md.append("Править: %s" % ext_bsl)
    md.append('Метод:   %s (&ИзменениеИКонтроль("%s"))' % (existing_name, method["canonical"]))
    md.append("Причина: %s" % conflict_reason(disputed))
    md.append("")
    md.append("## Не размещено — перенести вручную")
    cn = 0
    for d in disputed:
        cn += 1
        md.append("")
        if d["kind"] == "insert":
            md.append("### Конфликт №%d — вставка" % cn)
            md.append("Как блок стоял в вашей версии (local):")
            if d.get("before"):
                for l in d["before"]:
                    md.append(l)
            md.append("#Вставка"); md.extend(d["lines"]); md.append("#КонецВставки")
            if d.get("after"):
                for l in d["after"]:
                    md.append(l)
            md.append("")
            md.append("Якорь (строки вокруг #Вставка) изменился/исчез в новом оригинале — блок не лёг автоматически (см. дифф base→remote ниже).")
            md.append("В модуле расширения блок припаркован в конце метода под меткой // [РЕСИНК-КОНФЛИКТ №%d] — найди по ней." % cn)
            md.append("Куда переносить: если якорного кода в новом методе больше нет — он, вероятно, вынесен/отрефакторен (ищите в диффе новый вызов/процедуру). Размести адаптацию по смыслу: например пост-обработкой после нового вызова, либо в заимствованной процедуре, куда переехал код. При правке файла сохрани кодировку (UTF-8 с BOM).")
        else:
            md.append("### Конфликт №%d — удаление" % cn)
            md.append("Строки для удаления не найдены в новом оригинале (изменились/исчезли):")
            for l in d["lines"]:
                md.append("  - " + l.strip())
            md.append("В модуле расширения помечено меткой // [РЕСИНК-КОНФЛИКТ №%d]." % cn)
    md.append("")
    md.append("## Дифф base→remote (что изменилось в оригинале)")
    for l in v1:
        if normalize(l) not in v2norm:
            md.append("- " + l)
    for l in v2:
        if normalize(l) not in v1norm:
            md.append("+ " + l)
    md.append("")
    md.append("Рядом: base.bsl / local.bsl / remote.bsl")
    write_bsl(os.path.join(folder, "conflict.md"), md)


def resync_one(ext_bsl, ext_lines, dup, method, logical_module, conflict_folder, report_only):
    method_id = "%s.%s" % (logical_module, method["canonical"])
    dec_line = dup["line"]
    sig_line_idx = dec_line + 1
    name_re = re.compile(r'^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+([\w]+)\s*\(', re.IGNORECASE)
    m0 = name_re.match(ext_lines[sig_line_idx]) if sig_line_idx < len(ext_lines) else None
    if not m0:
        return {"id": method_id, "status": "ОШИБКА", "ext_bsl": ext_bsl, "reason": "не разобрать сигнатуру перехватчика"}
    existing_name = m0.group(1)
    sig = read_signature(ext_lines, sig_line_idx)
    if not sig:
        return {"id": method_id, "status": "ОШИБКА", "ext_bsl": ext_bsl, "reason": "не разобрать сигнатуру"}
    _params, sig_end = sig
    is_func = bool(re.match(r'^\s*(?:Асинх\s+)?Функция\b', ext_lines[sig_line_idx], re.IGNORECASE))
    end_re = re.compile(r'^\s*КонецФункции\b' if is_func else r'^\s*КонецПроцедуры\b', re.IGNORECASE)
    block_end = -1
    for j in range(sig_end + 1, len(ext_lines)):
        if end_re.match(ext_lines[j]):
            block_end = j
            break
    if block_end < 0:
        return {"id": method_id, "status": "ОШИБКА", "ext_bsl": ext_bsl, "reason": "не найден конец перехватчика"}

    marked_body = ext_lines[sig_end + 1:block_end]
    parsed = parse_marked_body(marked_body)
    v1 = parsed["v1"]; ops = parsed["ops"]; v2 = method["body_lines"]
    v1norm = [normalize(x) for x in v1]
    v2norm = [normalize(x) for x in v2]

    if "\n".join(v1norm) == "\n".join(v2norm):
        return {"id": method_id, "status": "АКТУАЛЕН", "ext_bsl": ext_bsl}

    insert_top = []; insert_after = {}; del_start = set(); del_end = set(); disputed = []; transferred = 0; absorbed = 0; absorbed_notes = []
    v2sig, v2map = significant_projection(v2norm)
    for op in ops:
        if op["kind"] == "insert":
            after = op["after"]
            before_lines = v1norm[max(0, after - 2):after + 1] if after >= 0 else []
            after_lines = v1norm[after + 1:after + 4]
            k = resolve_insertion_point(v2norm, before_lines, after_lines)
            # Payload already in the new original -> change carried into the main config.
            # Match on significant lines only, so vendor-added blanks/comments don't hide it.
            payload_sig = [x for x in (normalize(y) for y in op["lines"]) if test_significant(x)]
            is_absorbed = False
            if payload_sig:
                if k is None:
                    is_absorbed = find_unique_run(v2sig, payload_sig) >= 0
                else:
                    sig_start = sum(1 for j in v2map if j <= k)
                    is_absorbed = test_run_at(v2sig, payload_sig, sig_start)
            if is_absorbed:
                absorbed += 1
                for pl in op["lines"]:
                    if normalize(pl).startswith("//"):
                        absorbed_notes.append(pl.strip())
            elif k is None:
                dbefore = v1[max(0, after - 2):after + 1] if after >= 0 else []
                dafter = v1[after + 1:after + 4]
                disputed.append({"kind": "insert", "lines": op["lines"], "before": dbefore, "after": dafter})
            elif k < 0:
                insert_top.append(op["lines"]); transferred += 1
            else:
                insert_after.setdefault(k, []).append(op["lines"]); transferred += 1
        else:
            keys = v1norm[op["start"]:op["end"] + 1]
            p = find_unique_run(v2norm, keys)
            if p >= 0:
                del_start.add(p); del_end.add(p + len(keys) - 1); transferred += 1
            else:
                # Nearest significant neighbours; adjacency in the significant projection means the
                # block is already cut (blanks/comments left behind don't matter).
                before_ctx = None
                for z in range(op["start"] - 1, -1, -1):
                    if test_significant(v1norm[z]):
                        before_ctx = v1norm[z]; break
                after_ctx = None
                for z in range(op["end"] + 1, len(v1norm)):
                    if test_significant(v1norm[z]):
                        after_ctx = v1norm[z]; break
                if test_delete_absorbed(v2sig, before_ctx, after_ctx):
                    absorbed += 1
                else:
                    disputed.append({"kind": "delete", "lines": op["lines"]})

    if report_only:
        if disputed:
            st = "КОНФЛИКТ"
        elif transferred == 0 and absorbed > 0:
            st = "ПЕРЕНЕСЕНО В ОСНОВНУЮ"
        else:
            st = "ДРЕЙФ"
        rsn = conflict_reason(disputed) if disputed else ("все правки уже в основной конфигурации" if st == "ПЕРЕНЕСЕНО В ОСНОВНУЮ" else "")
        return {"id": method_id, "status": st, "ext_bsl": ext_bsl, "transferred": transferred,
                "absorbed": absorbed, "disputed": len(disputed), "reason": rsn, "absorbed_notes": absorbed_notes}

    new_body = []
    for blk in insert_top:
        new_body.append("#Вставка"); new_body.extend(blk); new_body.append("#КонецВставки")
    for k in range(len(v2)):
        if k in del_start:
            new_body.append("#Удаление")
        new_body.append(v2[k])
        if k in del_end:
            new_body.append("#КонецУдаления")
        if k in insert_after:
            for blk in insert_after[k]:
                new_body.append("#Вставка"); new_body.extend(blk); new_body.append("#КонецВставки")
    if disputed:
        new_body.append("\t// [РЕСИНК-КОНФЛИКТ] блоки ниже не легли автоматически — перенесите вручную (по № см. conflict.md / index.md в merge-воркспейсе, путь в выводе).")
        cn = 0
        for d in disputed:
            cn += 1
            if d["kind"] == "insert":
                new_body.append("\t// [РЕСИНК-КОНФЛИКТ №%d] вставка — исходный якорь изменён в новом оригинале." % cn)
                new_body.append("#Вставка"); new_body.extend(d["lines"]); new_body.append("#КонецВставки")
            else:
                new_body.append("\t// [РЕСИНК-КОНФЛИКТ №%d] удаление — строки не найдены в новом оригинале:" % cn)
                for l in d["lines"]:
                    new_body.append("\t// " + l.strip())

    async_prefix = "Асинх " if method["is_async"] else ""
    keyword = "Функция" if method["is_function"] else "Процедура"
    end_keyword = "КонецФункции" if method["is_function"] else "КонецПроцедуры"
    new_block = []
    if method["context"]:
        new_block.append(method["context"])
    new_block.append('&ИзменениеИКонтроль("%s")' % method["canonical"])
    new_block.append("%s%s %s(%s)" % (async_prefix, keyword, existing_name, method["params_text"]))
    new_block.extend(new_body)
    new_block.append(end_keyword)

    block_start = dec_line
    if dec_line >= 1 and is_context_directive(ext_lines[dec_line - 1].strip()):
        block_start = dec_line - 1
    out = list(ext_lines[:block_start]) + new_block + list(ext_lines[block_end + 1:])
    write_bsl(ext_bsl, out)

    conflict_dir = None
    if disputed:
        conflict_dir = conflict_folder
        write_conflict_folder(conflict_folder, method_id, ext_bsl, existing_name, method, v1, marked_body, v2, v1norm, v2norm, disputed)
    if disputed:
        status = "ЧАСТИЧНО"
    elif transferred == 0 and absorbed > 0:
        status = "ПЕРЕНЕСЕНО В ОСНОВНУЮ"
    else:
        status = "АКТУАЛИЗИРОВАН"
    rsn = conflict_reason(disputed) if disputed else ("все правки уже в основной конфигурации — перехватчик можно удалить" if status == "ПЕРЕНЕСЕНО В ОСНОВНУЮ" else "")
    return {"id": method_id, "status": status, "ext_bsl": ext_bsl, "transferred": transferred,
            "absorbed": absorbed, "disputed": len(disputed), "conflict_dir": conflict_dir, "reason": rsn,
            "absorbed_notes": absorbed_notes}


def write_resync_index(run_root, results, ext_name, config_path, verb):
    conflicts = [r for r in results if r["status"] == "ЧАСТИЧНО"]
    if not conflicts:
        return None
    os.makedirs(run_root, exist_ok=True)
    total = len(results)
    actual = sum(1 for r in results if r["status"] == "АКТУАЛЕН")
    upd = sum(1 for r in results if r["status"] == "АКТУАЛИЗИРОВАН")
    lines = []
    lines.append("[%s] %s -> %s" % (verb, ext_name, config_path))
    lines.append("Итог: %d/%d актуальны · актуализировано: %d · конфликтов: %d" % (actual, total, upd, len(conflicts)))
    lines.append("")
    lines.append("Конфликты — править .bsl расширения:")
    for c in conflicts:
        lines.append("  ЧАСТИЧНО  %s" % c["id"])
        lines.append("            -> %s   (%s)" % (c["ext_bsl"], c.get("reason", "")))
    write_bsl(os.path.join(run_root, "index.md"), lines)
    return run_root


if __name__ == "__main__":
    main()
