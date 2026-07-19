#!/usr/bin/env python3
# add-template v1.9 — Add template to 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import json
import os
import re
import sys
import uuid

from lxml import etree

NSMAP = {"md": "http://v8.1c.ru/8.3/MDClasses"}


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

TYPE_MAP = {
    "HTML": {"TemplateType": "HTMLDocument", "Ext": ".html"},
    "Text": {"TemplateType": "TextDocument", "Ext": ".txt"},
    "SpreadsheetDocument": {"TemplateType": "SpreadsheetDocument", "Ext": ".xml"},
    "BinaryData": {"TemplateType": "BinaryData", "Ext": ".bin"},
    "DataCompositionSchema": {"TemplateType": "DataCompositionSchema", "Ext": ".xml"},
}


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


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Add template to 1C object", allow_abbrev=False)
    parser.add_argument("-ObjectName", "-ProcessorName", required=True)
    parser.add_argument("-TemplateName", required=True)
    parser.add_argument("-TemplateType", required=True,
                        choices=["HTML", "Text", "SpreadsheetDocument", "BinaryData", "DataCompositionSchema"])
    parser.add_argument("-Synonym", default=None)
    parser.add_argument("-SrcDir", default="src")
    parser.add_argument("-SetMainSKD", action="store_true")
    args = parser.parse_args()

    object_name = args.ObjectName
    template_name = args.TemplateName
    template_type = args.TemplateType
    synonym = args.Synonym if args.Synonym is not None else template_name
    src_dir = args.SrcDir
    set_main_skd = args.SetMainSKD

    tmpl = TYPE_MAP[template_type]

    format_version = detect_format_version(os.path.abspath(src_dir))

    # --- Checks ---

    object_type_folders = [
        "Reports", "DataProcessors", "Documents", "Catalogs",
        "InformationRegisters", "AccumulationRegisters",
        "ChartsOfCharacteristicTypes", "ChartsOfAccounts", "ChartsOfCalculationTypes",
        "BusinessProcesses", "Tasks", "ExchangePlans",
    ]

    root_xml_path = os.path.join(src_dir, f"{object_name}.xml")
    if not os.path.exists(root_xml_path):
        candidates = []
        for folder in object_type_folders:
            probe = os.path.join(src_dir, folder, f"{object_name}.xml")
            if os.path.exists(probe):
                candidates.append(os.path.join(src_dir, folder))
        if len(candidates) == 1:
            src_dir = candidates[0]
            root_xml_path = os.path.join(src_dir, f"{object_name}.xml")
            print(f"[INFO] SrcDir расширен до: {src_dir}")
        elif len(candidates) > 1:
            print(f"Объект '{object_name}' найден в нескольких подпапках: {', '.join(candidates)}", file=sys.stderr)
            print(f"Укажи SrcDir явно", file=sys.stderr)
            sys.exit(1)
        else:
            print(f"Корневой файл объекта не найден: {root_xml_path}", file=sys.stderr)
            print(f"Ожидается: <SrcDir>/<ObjectName>.xml", file=sys.stderr)
            print(f"Подсказка: SrcDir должен указывать на папку типа объектов (например Reports), а не на корень конфигурации", file=sys.stderr)
            sys.exit(1)

    processor_dir = os.path.join(src_dir, object_name)
    templates_dir = os.path.join(processor_dir, "Templates")
    template_meta_path = os.path.join(templates_dir, f"{template_name}.xml")

    if os.path.exists(template_meta_path):
        print(f"Макет уже существует: {template_meta_path}", file=sys.stderr)
        sys.exit(1)

    assert_edit_allowed(root_xml_path, "editable")

    # --- Create directories ---

    template_ext_dir = os.path.join(templates_dir, template_name, "Ext")
    os.makedirs(template_ext_dir, exist_ok=True)

    # --- 1. Template metadata (Templates/<TemplateName>.xml) ---

    template_uuid = str(uuid.uuid4())

    template_meta_xml = (
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
        f'\t<Template uuid="{template_uuid}">\n'
        '\t\t<Properties>\n'
        f'\t\t\t<Name>{template_name}</Name>\n'
        '\t\t\t<Synonym>\n'
        '\t\t\t\t<v8:item>\n'
        '\t\t\t\t\t<v8:lang>ru</v8:lang>\n'
        f'\t\t\t\t\t<v8:content>{synonym}</v8:content>\n'
        '\t\t\t\t</v8:item>\n'
        '\t\t\t</Synonym>\n'
        '\t\t\t<Comment/>\n'
        f'\t\t\t<TemplateType>{tmpl["TemplateType"]}</TemplateType>\n'
        '\t\t</Properties>\n'
        '\t</Template>\n'
        '</MetaDataObject>'
    )

    write_text_with_bom(template_meta_path, template_meta_xml)

    # --- 2. Template content (Templates/<TemplateName>/Ext/Template.<ext>) ---

    template_file_path = os.path.join(template_ext_dir, f"Template{tmpl['Ext']}")

    if template_type == "HTML":
        content = (
            '<!DOCTYPE html>\n'
            '<html>\n'
            '<head>\n'
            '\t<meta charset="UTF-8">\n'
            '\t<title></title>\n'
            '</head>\n'
            '<body>\n'
            '</body>\n'
            '</html>'
        )
        write_text_with_bom(template_file_path, content)

    elif template_type == "Text":
        write_text_with_bom(template_file_path, "")

    elif template_type == "SpreadsheetDocument":
        content = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<SpreadsheetDocument xmlns="http://v8.1c.ru/spreadsheet/document"'
            ' xmlns:ss="http://v8.1c.ru/spreadsheet/document"'
            ' xmlns:v8="http://v8.1c.ru/8.1/data/core"'
            ' xmlns:xs="http://www.w3.org/2001/XMLSchema">\n'
            '</SpreadsheetDocument>'
        )
        write_text_with_bom(template_file_path, content)

    elif template_type == "BinaryData":
        with open(template_file_path, "wb") as f:
            pass  # empty file

    elif template_type == "DataCompositionSchema":
        content = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"\n'
            '\t\txmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"\n'
            '\t\txmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"\n'
            '\t\txmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"\n'
            '\t\txmlns:v8="http://v8.1c.ru/8.1/data/core"\n'
            '\t\txmlns:v8ui="http://v8.1c.ru/8.1/data/ui"\n'
            '\t\txmlns:xs="http://www.w3.org/2001/XMLSchema"\n'
            '\t\txmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n'
            '\t<dataSource>\n'
            '\t\t<name>ИсточникДанных1</name>\n'
            '\t\t<dataSourceType>Local</dataSourceType>\n'
            '\t</dataSource>\n'
            '</DataCompositionSchema>'
        )
        write_text_with_bom(template_file_path, content)

    # --- 3. Modify root XML ---

    root_xml_full = os.path.abspath(root_xml_path)
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(root_xml_full, parser_xml)
    root = tree.getroot()

    ns = "http://v8.1c.ru/8.3/MDClasses"
    child_objects = root.find(".//md:ChildObjects", NSMAP)
    if child_objects is None:
        print(f"Не найден элемент ChildObjects в {root_xml_path}", file=sys.stderr)
        sys.exit(1)

    # Add <Template> to end of ChildObjects
    template_elem = etree.SubElement(child_objects, f"{{{ns}}}Template")
    template_elem.text = template_name
    # Remove auto-appended element to reinsert with proper whitespace
    child_objects.remove(template_elem)

    children = list(child_objects)
    if len(children) == 0 and (child_objects.text is None or child_objects.text.strip() == ""):
        # Empty ChildObjects (self-closing)
        child_objects.text = "\n\t\t\t"
        child_objects.append(template_elem)
        template_elem.tail = "\n\t\t"
    else:
        if len(children) > 0:
            last_child = children[-1]
            # last_child.tail is the trailing whitespace before </ChildObjects>
            old_tail = last_child.tail
            last_child.tail = "\n\t\t\t"
            child_objects.append(template_elem)
            template_elem.tail = old_tail if old_tail else "\n\t\t"
        else:
            # Has text content but no element children
            child_objects.text = (child_objects.text or "") + "\n\t\t\t"
            child_objects.append(template_elem)
            template_elem.tail = "\n\t\t"

    # --- 4. MainDataCompositionSchema (for ExternalReport / Report) ---

    main_dcs_updated = False
    if template_type == "DataCompositionSchema":
        report_like_types = ["ExternalReport", "Report"]
        object_type_node = None
        object_type_name = None
        for rt in report_like_types:
            node = root.find(f".//md:{rt}", NSMAP)
            if node is not None:
                object_type_node = node
                object_type_name = rt
                break

        if object_type_node is not None:
            main_dcs = root.find(f".//md:{object_type_name}/md:Properties/md:MainDataCompositionSchema", NSMAP)
            if main_dcs is not None:
                is_empty = main_dcs.text is None or main_dcs.text.strip() == ""
                if is_empty or set_main_skd:
                    obj_name_node = root.find(f".//md:{object_type_name}/md:Properties/md:Name", NSMAP)
                    obj_name = obj_name_node.text if obj_name_node is not None else ""
                    main_dcs.text = f"{object_type_name}.{obj_name}.Template.{template_name}"
                    main_dcs_updated = True

    # Save with BOM
    save_xml_with_bom(tree, root_xml_full)

    print(f"[OK] Создан макет: {template_name} ({template_type})")
    print(f"     Метаданные: {template_meta_path}")
    print(f"     Содержимое: {template_file_path}")
    if main_dcs_updated:
        print(f"     MainDataCompositionSchema: {main_dcs.text}")


if __name__ == "__main__":
    main()
