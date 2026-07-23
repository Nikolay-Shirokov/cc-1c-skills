#!/usr/bin/env python3
# form-add v1.11 — Add managed form to 1C config object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import sys
import uuid

from lxml import etree


# ============================================================
# Support guard (Ext/ParentConfigurations.bin) — see docs/1c-support-state-spec.md
# Blocks edits of vendor objects "на замке" / read-only configs. Trigger = bin
# present; reaction from .v8-project.json editingAllowedCheck (deny|warn|off,
# default deny). Never throws (except sys.exit on deny) — errors degrade to allow.
# ============================================================

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


def _sg_is_external_root(xml_path):
    if not os.path.isfile(xml_path):
        return False
    try:
        mx = etree.parse(xml_path).getroot()
        for child in mx:
            if isinstance(child.tag, str):
                return child.tag.split("}")[-1] in ("ExternalDataProcessor", "ExternalReport")
    except Exception:
        return False
    return False

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
        pj = _sg_find_v8project(os.getcwd()) or _sg_find_v8project(cfg_dir)
        if not pj:
            return "deny"
        proj = json.loads(open(pj, encoding="utf-8-sig").read())
        cfg_full = os.path.normcase(os.path.abspath(cfg_dir)).rstrip("\\/")
        for db in proj.get("databases", []):
            src = db.get("configSrc")
            if src:
                src_full = os.path.normcase(os.path.abspath(src)).rstrip("\\/")
                if cfg_full == src_full or cfg_full.startswith(src_full + os.sep):
                    if db.get("editingAllowedCheck"):
                        return db["editingAllowedCheck"]
        if proj.get("editingAllowedCheck"):
            return proj["editingAllowedCheck"]
        return "deny"
    except Exception:
        return "deny"


def assert_edit_allowed(target_path, require):
    try:
        rp = os.path.abspath(target_path)
        # Autonomous external object (EPF/ERF): never part of a config on support (issue #39).
        if _sg_is_external_root(rp):
            return
        elem_uuid = _sg_root_uuid(rp)
        cfg_dir = None
        bin_path = None
        d = rp if os.path.isdir(rp) else os.path.dirname(rp)
        for _ in range(12):
            if not d:
                break
            if _sg_is_external_root(d + ".xml"):
                return
            if not elem_uuid:
                elem_uuid = _sg_root_uuid(d + ".xml")
            if not cfg_dir:
                cand = os.path.join(d, "Ext", "ParentConfigurations.bin")
                if os.path.exists(cand) or os.path.exists(os.path.join(d, "Configuration.xml")):
                    cfg_dir = d
                    bin_path = cand
            if elem_uuid and cfg_dir:
                break
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
        if not elem_uuid and cfg_dir:
            elem_uuid = _sg_root_uuid(os.path.join(cfg_dir, "Configuration.xml"))
        if not bin_path or not os.path.exists(bin_path):
            return
        data = open(bin_path, "rb").read()
        if len(data) <= 32:
            return
        if data[:3] == b"\xef\xbb\xbf":
            data = data[3:]
        text = data.decode("utf-8", "replace")
        h = re.match(r"\{6,(\d+),(\d+),", text)
        if not h:
            return
        g = int(h.group(1))
        k = int(h.group(2))
        if k == 0:
            return
        best = None
        if elem_uuid:
            for m in re.finditer(r"([0-2]),0," + re.escape(elem_uuid.lower()), text):
                f1 = int(m.group(1))
                if best is None or f1 < best:
                    best = f1
        blocked = False
        code = ""
        reason = ""
        if g == 1:
            blocked = True
            code = "capability-off"
            reason = "возможность изменения конфигурации выключена (вся конфигурация read-only)"
        elif require == "removed":
            if best is not None and best != 2:
                blocked = True
                code = "not-removed"
                reason = "объект не снят с поддержки — удаление сломает обновления"
        else:
            if best is not None and best == 0:
                blocked = True
                code = "locked"
                reason = "объект на замке — редактирование сломает обновления"
        if not blocked:
            return
        mode = _sg_get_edit_mode(cfg_dir)
        if mode == "off":
            return
        if mode == "warn":
            sys.stderr.write(f"[support-guard] ПРЕДУПРЕЖДЕНИЕ: {reason}. Цель: {rp}\n")
            return
        head = "[support-guard] Редактирование отклонено: это объект типовой конфигурации на поддержке поставщика, прямое редактирование молча сломает будущие обновления."
        cfe = "Рекомендуемый путь: внести доработку в расширение (навыки cfe-borrow / cfe-patch-method) — состояние поддержки менять не нужно, обновления вендора сохраняются."
        off_note = "Снять проверку для этой базы: editingAllowedCheck = warn|off в .v8-project.json."
        if code == "capability-off":
            state = f"Состояние: у всей конфигурации выключена возможность изменения (режим read-only «из коробки») — поэтому объект «{rp}» редактировать нельзя."
            fix = (
                "Либо снять защиту явно (навык support-edit, два шага):\n"
                f'  1. support-edit -Path "{cfg_dir}" -Capability on — включить возможность изменения (объекты пока остаются на замке);\n'
                f'  2. support-edit -Path "{rp}" -Set editable — открыть этот объект для редактирования.\n'
                "  Изменение применяется в базу полной загрузкой выгрузки и обходит механизм обновлений вендора."
            )
        elif code == "not-removed":
            state = f"Состояние: объект «{rp}» на поддержке (не снят с поддержки) — его удаление разорвёт обновления вендора."
            fix = (
                "Либо сначала снять объект с поддержки, затем удалять:\n"
                f'  support-edit -Path "{rp}" -Set off-support — объект уходит из-под обновлений, после этого удаление безопасно.'
            )
        else:
            state = f"Состояние: объект «{rp}» на замке (возможность изменения конфигурации включена, но сам объект не редактируется)."
            fix = (
                "Либо разрешить редактирование этого объекта (навык support-edit, выбрать одно):\n"
                f'  support-edit -Path "{rp}" -Set editable — редактировать и дальше получать обновления вендора (возможны конфликты слияния);\n'
                f'  support-edit -Path "{rp}" -Set off-support — снять с поддержки: обновления по объекту больше не приходят.'
            )
        sys.stderr.write(head + "\n" + state + "\n" + cfe + "\n" + fix + "\n" + off_note + "\n")
        sys.exit(1)
    except SystemExit:
        raise
    except Exception:
        return


NSMAP = {
    "md": "http://v8.1c.ru/8.3/MDClasses",
    "v8": "http://v8.1c.ru/8.1/data/core",
}


def detect_format_version(d):
    while d:
        cfg_path = os.path.join(d, "Configuration.xml")
        if os.path.isfile(cfg_path):
            with open(cfg_path, "r", encoding="utf-8-sig") as f:
                head = f.read(2000)
            m = re.search(r'<MetaDataObject[^>]+version="(\d+\.\d+)"', head)
            if m:
                return m.group(1)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return "2.17"


def _detect_xml_style(path):
    """Стиль существующего файла для round-trip-сохранения: BOM / EOL / регистр encoding /
    финальный перенос. None → файл новый (сохранить текущее поведение)."""
    try:
        raw = open(path, "rb").read()
    except OSError:
        return None
    bom = raw.startswith(b"\xef\xbb\xbf")
    body = raw[3:] if bom else raw
    crlf = b"\r\n" in body
    m = re.search(rb'encoding="([^"]+)"', body[:200])
    enc = m.group(1).decode("ascii") if m else "utf-8"
    final_nl = body.endswith(b"\n")
    return {"bom": bom, "crlf": crlf, "enc": enc, "final_nl": final_nl}


def _finalize_xml_bytes(xml_bytes, style):
    """Привести сериализованные байты к стилю оригинала (или к дефолту, если style is None)."""
    enc_decl = style["enc"] if style else "utf-8"
    xml_bytes = xml_bytes.replace(
        b"<?xml version='1.0' encoding='UTF-8'?>",
        b'<?xml version="1.0" encoding="' + enc_decl.encode("ascii") + b'"?>')
    # Канонизировать переносы к LF (убирает &#13; от \r в tail'ах)
    xml_bytes = (xml_bytes.replace(b"&#13;\n", b"\n").replace(b"&#13;", b"")
                 .replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
    # Финальный перенос — как в оригинале (новый файл → есть)
    want_final_nl = style["final_nl"] if style else True
    xml_bytes = xml_bytes.rstrip(b"\n")
    if want_final_nl:
        xml_bytes += b"\n"
    # EOL — как в оригинале (новый файл → LF, текущее поведение)
    if style and style["crlf"]:
        xml_bytes = xml_bytes.replace(b"\n", b"\r\n")
    return xml_bytes


def save_xml_with_bom(tree, path):
    """Save XML tree preserving the existing file's BOM/EOL/encoding-case/final-newline."""
    style = _detect_xml_style(path)
    xml_bytes = etree.tostring(tree, xml_declaration=True, encoding="UTF-8")
    xml_bytes = _finalize_xml_bytes(xml_bytes, style)
    with open(path, "wb") as f:
        if style is None or style["bom"]:
            f.write(b"\xef\xbb\xbf")
        f.write(xml_bytes)


def write_text_with_bom(path, text):
    """Write text to file with UTF-8 BOM."""
    with open(path, "w", encoding="utf-8-sig") as f:
        f.write(text)


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Add managed form to 1C config object", allow_abbrev=False)
    parser.add_argument("-ObjectPath", required=True)
    parser.add_argument("-FormName", required=True)
    parser.add_argument("-Synonym", default=None)
    parser.add_argument("-Purpose", default="Object")
    parser.add_argument("-SetDefault", action="store_true")
    args = parser.parse_args()

    object_path = args.ObjectPath
    form_name = args.FormName
    synonym = args.Synonym if args.Synonym is not None else form_name
    purpose = args.Purpose
    set_default = args.SetDefault

    # --- Phase 1: Determine object type ---

    # Resolve ObjectPath (directory → .xml)
    if not os.path.isabs(object_path):
        object_path = os.path.join(os.getcwd(), object_path)
    if os.path.isdir(object_path):
        dir_name = os.path.basename(object_path.rstrip("/\\"))
        candidate = os.path.join(object_path, dir_name + ".xml")
        sibling = os.path.join(os.path.dirname(object_path.rstrip("/\\")), dir_name + ".xml")
        if os.path.isfile(candidate):
            object_path = candidate
        elif os.path.isfile(sibling):
            object_path = sibling
    if not os.path.isfile(object_path):
        print(f"Файл объекта не найден: {object_path}", file=sys.stderr)
        sys.exit(1)

    object_xml_full = os.path.abspath(object_path)
    assert_edit_allowed(object_xml_full, "editable")
    format_version = detect_format_version(os.path.dirname(object_xml_full))

    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(object_xml_full, parser_xml)
    root = tree.getroot()

    supported_types = [
        "Document", "Catalog", "DataProcessor", "Report",
        "ExternalDataProcessor", "ExternalReport",
        "InformationRegister", "AccumulationRegister", "ChartOfAccounts", "ChartOfCharacteristicTypes",
        "ExchangePlan", "BusinessProcess", "Task", "DocumentJournal",
    ]

    object_type = None
    object_node = None
    for t in supported_types:
        node = root.find(f".//md:{t}", NSMAP)
        if node is not None:
            object_type = t
            object_node = node
            break

    if object_type is None:
        print(f"Не удалось определить тип объекта. Поддерживаемые типы: {', '.join(supported_types)}", file=sys.stderr)
        sys.exit(1)

    # Object name from Properties/Name
    name_node = root.find(f".//md:{object_type}/md:Properties/md:Name", NSMAP)
    if name_node is None or not name_node.text:
        print("Не удалось определить имя объекта из Properties/Name", file=sys.stderr)
        sys.exit(1)
    object_name = name_node.text

    print()
    print("=== form-add ===")
    print()
    print(f"Object: {object_type}.{object_name}")

    # --- Phase 2: Validate Purpose ---

    # Normalize: capitalize first letter, lowercase rest
    purpose = purpose[0].upper() + purpose[1:].lower()

    valid_purposes = ["Object", "List", "Choice", "Record"]
    if purpose not in valid_purposes:
        print(f"Недопустимое назначение: {purpose}. Допустимые: Object, List, Choice, Record", file=sys.stderr)
        sys.exit(1)

    object_like_types = ["Document", "Catalog", "ChartOfAccounts", "ChartOfCharacteristicTypes",
                         "ExchangePlan", "BusinessProcess", "Task"]
    processor_like_types = ["DataProcessor", "Report", "ExternalDataProcessor", "ExternalReport"]

    if purpose == "List":
        if object_type == "DataProcessor":
            print("Purpose=List недопустим для DataProcessor", file=sys.stderr)
            sys.exit(1)

    elif purpose == "Choice":
        if object_type in processor_like_types or object_type == "InformationRegister":
            print(f"Purpose=Choice недопустим для {object_type}", file=sys.stderr)
            sys.exit(1)

    elif purpose == "Record":
        if object_type != "InformationRegister":
            print("Purpose=Record допустим только для InformationRegister", file=sys.stderr)
            sys.exit(1)

    # --- Phase 3: Create files ---

    object_dir = os.path.splitext(object_xml_full)[0]
    forms_dir = os.path.join(object_dir, "Forms")
    form_meta_path = os.path.join(forms_dir, f"{form_name}.xml")

    if os.path.exists(form_meta_path):
        print(f"Форма уже существует: {form_meta_path}", file=sys.stderr)
        sys.exit(1)

    form_dir = os.path.join(forms_dir, form_name)
    form_ext_dir = os.path.join(form_dir, "Ext")
    form_module_dir = os.path.join(form_ext_dir, "Form")

    os.makedirs(form_module_dir, exist_ok=True)

    # --- 3a. Form metadata ---

    form_uuid = str(uuid.uuid4())

    form_meta_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses"'
        ' xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
        ' xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
        ' xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi"'
        ' xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
        ' xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"'
        ' xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
        ' xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
        ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
        ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
        ' xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"'
        ' xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"'
        ' xmlns:xen="http://v8.1c.ru/8.3/xcf/enums"'
        ' xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef"'
        ' xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
        ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
        f' version="{format_version}">\n'
        f'\t<Form uuid="{form_uuid}">\n'
        '\t\t<Properties>\n'
        f'\t\t\t<Name>{form_name}</Name>\n'
        '\t\t\t<Synonym>\n'
        '\t\t\t\t<v8:item>\n'
        '\t\t\t\t\t<v8:lang>ru</v8:lang>\n'
        f'\t\t\t\t\t<v8:content>{synonym}</v8:content>\n'
        '\t\t\t\t</v8:item>\n'
        '\t\t\t</Synonym>\n'
        '\t\t\t<Comment/>\n'
        '\t\t\t<FormType>Managed</FormType>\n'
        '\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>\n'
        '\t\t\t<UsePurposes>\n'
        '\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>\n'
        '\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">MobilePlatformApplication</v8:Value>\n'
        '\t\t\t</UsePurposes>\n'
        + ('\t\t\t<ExtendedPresentation/>\n' if object_type in processor_like_types else '')
        + '\t\t</Properties>\n'
        '\t</Form>\n'
        '</MetaDataObject>'
    )

    write_text_with_bom(form_meta_path, form_meta_xml)

    # --- 3b. Form.xml ---

    form_xml_path = os.path.join(form_ext_dir, "Form.xml")

    form_ns_decl = (
        'xmlns="http://v8.1c.ru/8.3/xcf/logform"'
        ' xmlns:app="http://v8.1c.ru/8.2/managed-application/core"'
        ' xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config"'
        ' xmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"'
        ' xmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"'
        ' xmlns:ent="http://v8.1c.ru/8.1/data/enterprise"'
        ' xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform"'
        ' xmlns:style="http://v8.1c.ru/8.1/data/ui/style"'
        ' xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system"'
        ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
        ' xmlns:v8ui="http://v8.1c.ru/8.1/data/ui"'
        ' xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web"'
        ' xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows"'
        ' xmlns:xr="http://v8.1c.ru/8.3/xcf/readable"'
        ' xmlns:xs="http://www.w3.org/2001/XMLSchema"'
        ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    )

    if purpose in ("List", "Choice"):
        # Dynamic list
        main_table = f"{object_type}.{object_name}"

        form_xml = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Form {form_ns_decl} version="{format_version}">\n'
            '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
            '\t\t<Autofill>true</Autofill>\n'
            '\t</AutoCommandBar>\n'
            '\t<ChildItems/>\n'
            '\t<Attributes>\n'
            '\t\t<Attribute name="\u0421\u043f\u0438\u0441\u043e\u043a" id="1">\n'
            '\t\t\t<Type>\n'
            '\t\t\t\t<v8:Type>cfg:DynamicList</v8:Type>\n'
            '\t\t\t</Type>\n'
            '\t\t\t<MainAttribute>true</MainAttribute>\n'
            '\t\t\t<Settings xsi:type="DynamicList">\n'
            f'\t\t\t\t<MainTable>{main_table}</MainTable>\n'
            '\t\t\t</Settings>\n'
            '\t\t</Attribute>\n'
            '\t</Attributes>\n'
            '</Form>'
        )

    elif purpose == "Record":
        # Information register record
        main_attr_name = "\u0417\u0430\u043f\u0438\u0441\u044c"
        main_attr_type = f"InformationRegisterRecordManager.{object_name}"

        form_xml = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Form {form_ns_decl} version="{format_version}">\n'
            '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
            '\t\t<Autofill>true</Autofill>\n'
            '\t</AutoCommandBar>\n'
            '\t<ChildItems/>\n'
            '\t<Attributes>\n'
            f'\t\t<Attribute name="{main_attr_name}" id="1">\n'
            '\t\t\t<Type>\n'
            f'\t\t\t\t<v8:Type>cfg:{main_attr_type}</v8:Type>\n'
            '\t\t\t</Type>\n'
            '\t\t\t<MainAttribute>true</MainAttribute>\n'
            '\t\t\t<SavedData>true</SavedData>\n'
            '\t\t</Attribute>\n'
            '\t</Attributes>\n'
            '</Form>'
        )

    else:
        # Object — object form
        main_attr_name = "\u041e\u0431\u044a\u0435\u043a\u0442"

        attr_type_map = {
            "Document": "DocumentObject",
            "Catalog": "CatalogObject",
            "DataProcessor": "DataProcessorObject",
            "Report": "ReportObject",
            "ExternalDataProcessor": "ExternalDataProcessorObject",
            "ExternalReport": "ExternalReportObject",
            "ChartOfAccounts": "ChartOfAccountsObject",
            "ChartOfCharacteristicTypes": "ChartOfCharacteristicTypesObject",
            "ExchangePlan": "ExchangePlanObject",
            "BusinessProcess": "BusinessProcessObject",
            "Task": "TaskObject",
            "InformationRegister": "InformationRegisterRecordManager",
            "AccumulationRegister": "AccumulationRegisterRecordSet",
        }

        main_attr_type = f"{attr_type_map[object_type]}.{object_name}"

        # SavedData: standard for Catalog/Document/etc, but not for processor-like (DataProcessor/Report/External*)
        saved_data_line = ''
        if object_type not in processor_like_types:
            saved_data_line = '\t\t\t<SavedData>true</SavedData>\n'

        form_xml = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<Form {form_ns_decl} version="{format_version}">\n'
            '\t<AutoCommandBar name="\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c" id="-1">\n'
            '\t\t<Autofill>true</Autofill>\n'
            '\t</AutoCommandBar>\n'
            '\t<ChildItems/>\n'
            '\t<Attributes>\n'
            f'\t\t<Attribute name="{main_attr_name}" id="1">\n'
            '\t\t\t<Type>\n'
            f'\t\t\t\t<v8:Type>cfg:{main_attr_type}</v8:Type>\n'
            '\t\t\t</Type>\n'
            '\t\t\t<MainAttribute>true</MainAttribute>\n'
            f'{saved_data_line}'
            '\t\t</Attribute>\n'
            '\t</Attributes>\n'
            '</Form>'
        )

    if os.path.exists(form_xml_path):
        print(f"[SKIP] Form.xml already exists: {form_xml_path} — not overwriting")
    else:
        write_text_with_bom(form_xml_path, form_xml)

    # --- 3c. Module.bsl ---

    module_path = os.path.join(form_module_dir, "Module.bsl")

    module_bsl = (
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u0421\u043e\u0431\u044b\u0442\u0438\u0439\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u0421\u043e\u0431\u044b\u0442\u0438\u0439\u042d\u043b\u0435\u043c\u0435\u043d\u0442\u043e\u0432\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u041a\u043e\u043c\u0430\u043d\u0434\u0424\u043e\u0440\u043c\u044b\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u041e\u0431\u0440\u0430\u0431\u043e\u0442\u0447\u0438\u043a\u0438\u041e\u043f\u043e\u0432\u0435\u0449\u0435\u043d\u0438\u0439\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438\n'
        '\n'
        '#\u041e\u0431\u043b\u0430\u0441\u0442\u044c \u0421\u043b\u0443\u0436\u0435\u0431\u043d\u044b\u0435\u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u044b\u0418\u0424\u0443\u043d\u043a\u0446\u0438\u0438\n'
        '\n'
        '#\u041a\u043e\u043d\u0435\u0446\u041e\u0431\u043b\u0430\u0441\u0442\u0438'
    )

    if os.path.exists(module_path):
        print(f"[SKIP] Module.bsl already exists: {module_path} — not overwriting")
    else:
        write_text_with_bom(module_path, module_bsl)

    # --- Phase 4: Register in parent object ---

    ns = "http://v8.1c.ru/8.3/MDClasses"
    child_objects = root.find(f".//md:{object_type}/md:ChildObjects", NSMAP)
    if child_objects is None:
        print(f"Не найден элемент ChildObjects в {object_path}", file=sys.stderr)
        sys.exit(1)

    # Add <Form>$FormName</Form> — idempotent (do not duplicate already-registered form)
    already_registered = child_objects.find(f"md:Form[.='{form_name}']", NSMAP) is not None

    if not already_registered:
        form_elem = etree.Element(f"{{{ns}}}Form")
        form_elem.text = form_name

        # Find first <Template> to insert before it
        first_template = child_objects.find("md:Template", NSMAP)
        # Find first <TabularSection> to insert before it (if no Template)
        first_tabular = child_objects.find("md:TabularSection", NSMAP)

        # Determine insertion point: before Template, before TabularSection, or at end
        insert_before = None
        if first_template is not None:
            insert_before = first_template
        elif first_tabular is not None:
            insert_before = first_tabular

        if insert_before is not None:
            # Insert before the found element
            idx = list(child_objects).index(insert_before)
            child_objects.insert(idx, form_elem)
            # Whitespace: form_elem gets "\n\t\t\t" as tail (indent before insert_before)
            form_elem.tail = "\n\t\t\t"
        else:
            # Add to end of ChildObjects
            children = list(child_objects)
            if len(children) == 0 and (child_objects.text is None or child_objects.text.strip() == ""):
                # Empty ChildObjects (self-closing)
                child_objects.text = "\n\t\t\t"
                child_objects.append(form_elem)
                form_elem.tail = "\n\t\t"
            else:
                if len(children) > 0:
                    last_child = children[-1]
                    old_tail = last_child.tail
                    last_child.tail = "\n\t\t\t"
                    child_objects.append(form_elem)
                    form_elem.tail = old_tail if old_tail else "\n\t\t"
                else:
                    child_objects.text = (child_objects.text or "") + "\n\t\t\t"
                    child_objects.append(form_elem)
                    form_elem.tail = "\n\t\t"

    # --- SetDefault ---

    is_first_form_for_purpose = False
    default_prop_name = None
    default_value = f"{object_type}.{object_name}.Form.{form_name}"

    # Determine property name for DefaultForm
    if purpose == "Object":
        if object_type in processor_like_types:
            default_prop_name = "DefaultForm"
        else:
            default_prop_name = "DefaultObjectForm"
    elif purpose == "List":
        default_prop_name = "DefaultListForm"
    elif purpose == "Choice":
        default_prop_name = "DefaultChoiceForm"
    elif purpose == "Record":
        default_prop_name = "DefaultRecordForm"

    # Check if value is already set
    default_node = root.find(f".//md:{object_type}/md:Properties/md:{default_prop_name}", NSMAP)
    if default_node is not None:
        is_first_form_for_purpose = default_node.text is None or default_node.text.strip() == ""

    default_updated = False
    if set_default or is_first_form_for_purpose:
        if default_node is not None:
            default_node.text = default_value
            default_updated = True

    # Save with BOM
    save_xml_with_bom(tree, object_xml_full)

    # --- Phase 5: Output ---

    obj_dir_name = os.path.dirname(object_path)
    obj_base_name = os.path.splitext(os.path.basename(object_path))[0]

    print("Created:")
    print(f"  Metadata: {obj_dir_name}\\{obj_base_name}\\Forms\\{form_name}.xml")
    print(f"  Form:     {obj_dir_name}\\{obj_base_name}\\Forms\\{form_name}\\Ext\\Form.xml")
    print(f"  Module:   {obj_dir_name}\\{obj_base_name}\\Forms\\{form_name}\\Ext\\Form\\Module.bsl")
    print()
    if already_registered:
        print(f"Already registered: <Form>{form_name}</Form> in ChildObjects (skipped duplicate)")
    else:
        print(f"Registered: <Form>{form_name}</Form> in ChildObjects")
    if default_updated:
        print(f"{default_prop_name}: {default_value}")
    print()


if __name__ == "__main__":
    main()
