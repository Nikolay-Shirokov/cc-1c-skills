#!/usr/bin/env python3
# cfe-patch-method v2.0 — Source-aware method interceptor for 1C extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
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
    parser.add_argument("-ModulePath", required=True)
    parser.add_argument("-MethodName", required=True)
    parser.add_argument("-InterceptorType", required=True,
                        choices=["Before", "After", "Instead", "ModificationAndControl"])
    args = parser.parse_args()

    extension_path = args.ExtensionPath
    config_path = args.ConfigPath
    module_path = args.ModulePath
    method_name = args.MethodName
    interceptor_type = args.InterceptorType

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
    except ET.ParseError:
        pass

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
        resync(ext_bsl, ext_lines, dup, method, method_name, module_path)
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


def resync(ext_bsl, ext_lines, dup, method, method_name, module_path):
    dec_line = dup["line"]
    sig_line_idx = dec_line + 1
    name_re = re.compile(r'^\s*(?:Асинх\s+)?(?:Процедура|Функция)\s+([\w]+)\s*\(', re.IGNORECASE)
    if sig_line_idx >= len(ext_lines) or not name_re.match(ext_lines[sig_line_idx]):
        die('Не удалось найти сигнатуру существующего перехватчика &ИзменениеИКонтроль("%s")' % method_name)
    existing_name = name_re.match(ext_lines[sig_line_idx]).group(1)
    sig = read_signature(ext_lines, sig_line_idx)
    if not sig:
        die("Не удалось разобрать сигнатуру существующего перехватчика")
    _params, sig_end = sig
    is_func = bool(re.match(r'^\s*(?:Асинх\s+)?Функция\b', ext_lines[sig_line_idx], re.IGNORECASE))
    end_re = re.compile(r'^\s*КонецФункции\b' if is_func else r'^\s*КонецПроцедуры\b', re.IGNORECASE)
    block_end = -1
    for j in range(sig_end + 1, len(ext_lines)):
        if end_re.match(ext_lines[j]):
            block_end = j
            break
    if block_end < 0:
        die("Не найден конец существующего перехватчика")

    marked_body = ext_lines[sig_end + 1:block_end]
    parsed = parse_marked_body(marked_body)
    v1 = parsed["v1"]
    ops = parsed["ops"]
    v2 = method["body_lines"]

    v1norm = [normalize(x) for x in v1]
    v2norm = [normalize(x) for x in v2]

    if "\n".join(v1norm) == "\n".join(v2norm):
        print('[АКТУАЛЕН] &ИзменениеИКонтроль("%s") — оригинал не менялся, изменений нет.' % method_name)
        print("     Файл: %s" % ext_bsl)
        return

    insert_top = []
    insert_after = {}
    del_start = set()
    del_end = set()
    disputed = []

    for op in ops:
        if op["kind"] == "insert":
            if op["after"] < 0:
                insert_top.append(op["lines"])
                continue
            k = find_unique_index(v2norm, v1norm[op["after"]])
            if k >= 0:
                insert_after.setdefault(k, []).append(op["lines"])
            else:
                disputed.append({"kind": "insert", "lines": op["lines"]})
        else:
            keys = v1norm[op["start"]:op["end"] + 1]
            p = find_unique_run(v2norm, keys)
            if p >= 0:
                del_start.add(p)
                del_end.add(p + len(keys) - 1)
            else:
                disputed.append({"kind": "delete", "lines": op["lines"]})

    new_body = []
    for blk in insert_top:
        new_body.append("#Вставка")
        new_body.extend(blk)
        new_body.append("#КонецВставки")
    for k in range(len(v2)):
        if k in del_start:
            new_body.append("#Удаление")
        new_body.append(v2[k])
        if k in del_end:
            new_body.append("#КонецУдаления")
        if k in insert_after:
            for blk in insert_after[k]:
                new_body.append("#Вставка")
                new_body.extend(blk)
                new_body.append("#КонецВставки")

    if disputed:
        new_body.append("\t// [РЕСИНК-КОНФЛИКТ] перенесите блоки ниже вручную — исходный якорь изменился в новой версии оригинала.")
        new_body.append("\t// Материалы для анализа см. в выводе команды (файлы v1/v2/current/diff).")
        for d in disputed:
            if d["kind"] == "insert":
                new_body.append("#Вставка")
                new_body.extend(d["lines"])
                new_body.append("#КонецВставки")
            else:
                new_body.append("\t// [РЕСИНК-КОНФЛИКТ] не удалось найти для удаления:")
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

    out = list(ext_lines[:block_start])
    out.extend(new_block)
    out.extend(ext_lines[block_end + 1:])
    write_bsl(ext_bsl, out)

    if disputed:
        safe = re.sub(r'[\\/:*?"<>|]', '_', module_path)
        tmp_root = os.path.join(tempfile.gettempdir(), "cfe-resync", safe + "." + method_name)
        os.makedirs(tmp_root, exist_ok=True)
        write_bsl(os.path.join(tmp_root, "v1.bsl"), v1)
        write_bsl(os.path.join(tmp_root, "v2.bsl"), v2)
        write_bsl(os.path.join(tmp_root, "current.bsl"), marked_body)
        diff = ["--- v1 (что было скопировано) vs v2 (новый оригинал) ---"]
        for l in v1:
            if normalize(l) not in v2norm:
                diff.append("- " + l)
        for l in v2:
            if normalize(l) not in v1norm:
                diff.append("+ " + l)
        write_bsl(os.path.join(tmp_root, "diff.txt"), diff)

        print('[АКТУАЛИЗИРОВАН-ЧАСТИЧНО] &ИзменениеИКонтроль("%s")' % method_name)
        print("     Перенесено автоматически, конфликтов: %d (помечены // [РЕСИНК-КОНФЛИКТ])" % len(disputed))
        print("     Файлы-версии для анализа:")
        print("       %s" % tmp_root)
        print("     Проверьте конфликтные блоки и разместите их вручную.")
    else:
        print('[АКТУАЛИЗИРОВАН] &ИзменениеИКонтроль("%s") — тело обновлено по новому оригиналу, правки перенесены.' % method_name)
    print("     Файл: %s" % ext_bsl)


if __name__ == "__main__":
    main()
