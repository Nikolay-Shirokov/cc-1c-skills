#!/usr/bin/env python3
# form-remove v1.10 — Remove form from 1C object
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import shutil
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


NSMAP = {"md": "http://v8.1c.ru/8.3/MDClasses"}


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
    """Привести байты к стилю оригинала; для НОВОГО файла (style is None) — к канону
    выгрузки Конфигуратора: encoding="UTF-8", CRLF в разделителях, без перевода в конце."""
    enc_decl = style["enc"] if style else "UTF-8"
    xml_bytes = xml_bytes.replace(
        b"<?xml version='1.0' encoding='UTF-8'?>",
        b'<?xml version="1.0" encoding="' + enc_decl.encode("ascii") + b'"?>')
    # Канонизировать переносы к LF (убирает &#13; от \r в tail'ах)
    xml_bytes = (xml_bytes.replace(b"&#13;\n", b"\n").replace(b"&#13;", b"")
                 .replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
    # Финальный перенос — как в оригинале (новый файл → нет, канон #57)
    want_final_nl = style["final_nl"] if style else False
    xml_bytes = xml_bytes.rstrip(b"\n")
    if want_final_nl:
        xml_bytes += b"\n"
    # EOL — как в оригинале (новый файл → CRLF, канон #57)
    if (style["crlf"] if style else True):
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


def long_path(path):
    """Полный путь в длинной форме. Зеркало Get-LongPath в PS: там Resolve-Path оставляет
    короткое имя 8.3 (NSHIRO~1), а перечисление отдаёт длинное — сравнение молча не совпадало."""
    if not os.path.exists(path):
        return ""
    return os.path.realpath(path)


def remove_node_with_indent(node):
    """Удалить элемент вместе с предшествующим whitespace; опустевший контейнер сделать
    самозакрывающимся. Зеркало Remove-NodeWithIndent в PS."""
    parent = node.getparent()
    if parent is None:
        return
    # В DOM (PS) whitespace — отдельные узлы: удаляются предшествующий и сам элемент, а
    # whitespace ПОСЛЕ элемента остаётся. В lxml он лежит в node.tail и ушёл бы вместе с
    # узлом, поэтому его надо передать предшественнику — иначе `</Attributes></Form>`.
    prev = node.getprevious()
    if prev is not None:
        prev.tail = node.tail
    else:
        parent.text = node.tail
    parent.remove(node)
    # Опустевший контейнер: text="" сериализуется парой <ChildObjects></ChildObjects>,
    # а нужен <ChildObjects/> — PS-порт через DOM даёт именно его.
    if len(parent) == 0 and not (parent.text or "").strip():
        parent.text = None


def clear_form_refs(tree, ref):
    """Очистить ссылки на форму. Каноничное «не задано» зависит от файла: в корневом XML
    объекта и в Configuration.xml пустой слот штатен (164 508 пустых на корпус), а внутри
    Ext/Form.xml пустых <ChoiceForm/> и <SettingsStorage/> нет ни одного — там свойство
    просто отсутствует. Зеркало Clear-FormRefs в PS."""
    root = tree.getroot()
    is_form_file = etree.QName(root).localname == "Form"
    touched = []
    ref_lc = ref.lower()
    for el in list(root.iter()):
        if not isinstance(el.tag, str):
            continue
        if len(el) > 0:                                    # только листья
            continue
        # Сравнение регистронезависимое — как у платформы (в PS -eq регистр не различает).
        if (el.text or "").strip().lower() != ref_lc:
            continue

        ln = etree.QName(el).localname
        parent = el.getparent()
        if ln == "Form" and parent is not None and etree.QName(parent).localname == "Item":
            touched.append(f"{etree.QName(parent).localname}/{ln}")
            remove_node_with_indent(parent)
        elif is_form_file:
            touched.append(ln)
            remove_node_with_indent(el)
        else:
            # text=None, а не "": пустая строка сериализуется парой <Tag></Tag>, а
            # Конфигуратор пустых пар не пишет (0 на 476 942 XML корпуса) — нужен <Tag/>.
            touched.append(ln)
            el.text = None
    return touched


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Remove form from 1C object", allow_abbrev=False)
    parser.add_argument("-ObjectName", "-ProcessorName", required=True)
    parser.add_argument("-FormName", required=True)
    parser.add_argument("-SrcDir", default="src")
    parser.add_argument("-Force", action="store_true")
    args = ci_parse_args(parser)

    object_name = args.ObjectName
    form_name = args.FormName
    src_dir = args.SrcDir
    force = args.Force

    # --- Checks ---

    root_xml_path = os.path.join(src_dir, f"{object_name}.xml")
    if not os.path.exists(root_xml_path):
        print(f"Корневой файл обработки не найден: {root_xml_path}", file=sys.stderr)
        sys.exit(1)

    processor_dir = os.path.join(src_dir, object_name)
    forms_dir = os.path.join(processor_dir, "Forms")
    form_meta_path = os.path.join(forms_dir, f"{form_name}.xml")
    form_dir = os.path.join(forms_dir, form_name)

    if not os.path.exists(form_meta_path):
        print(f"Метаданные формы не найдены: {form_meta_path}", file=sys.stderr)
        sys.exit(1)

    # --- Load root XML: kind and object name ---

    root_xml_full = long_path(root_xml_path) or os.path.abspath(root_xml_path)
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(root_xml_full, parser_xml)
    root = tree.getroot()

    type_node = None
    for c in root:
        if isinstance(c.tag, str):
            type_node = c
            break
    if type_node is None:
        print(f"Не удалось определить вид объекта в {root_xml_path}", file=sys.stderr)
        sys.exit(1)
    md_type = etree.QName(type_node).localname
    name_node = type_node.find("md:Properties/md:Name", NSMAP)
    obj_meta_name = (name_node.text or "").strip() if name_node is not None else ""
    if not obj_meta_name:
        obj_meta_name = os.path.splitext(os.path.basename(root_xml_path))[0]

    # Полная ссылка на форму. Матч по ней целиком, а не по хвосту "Form.<Имя>": иначе при
    # удалении своей ФормаСписка обнулялась бы и ссылка на DocumentJournal.Ж.Form.ФормаСписка.
    form_ref = f"{md_type}.{obj_meta_name}.Form.{form_name}"

    # --- Find references across the configuration ---

    config_dir = None
    probe = long_path(src_dir) or os.path.abspath(src_dir)
    for _ in range(4):
        if not probe:
            break
        if os.path.exists(os.path.join(probe, "Configuration.xml")):
            config_dir = probe
            break
        parent_probe = os.path.dirname(probe)
        if parent_probe == probe:
            break
        probe = parent_probe

    form_meta_full = long_path(form_meta_path)
    form_dir_full = long_path(form_dir)

    references = []
    if config_dir:
        ref_pattern = re.compile(r"<([A-Za-z0-9_.]+)>" + re.escape(form_ref) + r"</")
        for dirpath, _dirnames, filenames in os.walk(config_dir):
            for fn in filenames:
                if not fn.lower().endswith(".xml"):
                    continue
                fp = os.path.join(dirpath, fn)
                if fp == root_xml_full or fp == form_meta_full:
                    continue                                  # свой файл и файлы удаляемой формы
                if form_dir_full and fp.startswith(form_dir_full):
                    continue
                try:
                    with open(fp, "r", encoding="utf-8-sig") as f:
                        content = f.read()
                except OSError:
                    continue
                if form_ref not in content:
                    continue
                for m in ref_pattern.finditer(content):
                    references.append({"path": fp, "rel": os.path.relpath(fp, config_dir),
                                       "tag": m.group(1)})

    if references:
        print(f"[WARN]  На форму {form_ref} ссылаются {len(references)} раз(а):")
        grouped = {}
        for r in references:
            grouped[(r["rel"], r["tag"])] = grouped.get((r["rel"], r["tag"]), 0) + 1
        for (rel, tag) in sorted(grouped):
            suffix = f" x{grouped[(rel, tag)]}" if grouped[(rel, tag)] > 1 else ""
            print(f"        {rel} — <{tag}>{suffix}")
        print()
        if not force:
            print("[ERROR] Удаление остановлено: форма используется.")
            print("        Решает пользователь: убрать ссылки, отказаться от удаления или")
            print("        повторить с -Force — тогда ссылки будут очищены.")
            sys.exit(1)
        print("[WARN]  -Force: ссылки будут очищены")
        print()
    elif not config_dir:
        print("[WARN]  Корень конфигурации не найден — ссылки в других объектах не проверены")

    # --- Delete files ---

    if os.path.isdir(form_dir):
        shutil.rmtree(form_dir)
        print(f"[OK] Удалён каталог: {form_dir}")

    os.remove(form_meta_path)
    print(f"[OK] Удалён файл: {form_meta_path}")

    # --- Modify root XML ---

    # Remove <Form>FormName</Form> from ChildObjects
    for node in root.findall(".//md:ChildObjects/md:Form", NSMAP):
        if node.text and node.text.strip() == form_name:
            remove_node_with_indent(node)
            break

    # Очистить слоты своего объекта: Default*/Auxiliary*Form и ChoiceForm у реквизитов.
    clear_form_refs(tree, form_ref)

    # Save with BOM
    save_xml_with_bom(tree, root_xml_full)

    print(f"[OK] Форма {form_name} удалена из {root_xml_path}")

    # --- Clean references in other files (only with -Force) ---

    for fp in sorted({r["path"] for r in references}):
        other_tree = etree.parse(fp, parser_xml)
        touched = clear_form_refs(other_tree, form_ref)
        if not touched:
            continue
        save_xml_with_bom(other_tree, fp)
        rel = os.path.relpath(fp, config_dir)
        print(f"[OK] Очищена ссылка в {rel} — {', '.join(sorted(set(touched)))}")


if __name__ == "__main__":
    main()
