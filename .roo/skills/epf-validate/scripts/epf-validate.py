#!/usr/bin/env python3
# epf-validate v1.2 — Validate 1C external data processor / report structure
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
# Works for both EPF (ExternalDataProcessor) and ERF (ExternalReport) — auto-detects

import argparse
import os
import re
import sys
from io import StringIO
from lxml import etree

MD_NS = "http://v8.1c.ru/8.3/MDClasses"
V8_NS = "http://v8.1c.ru/8.1/data/core"
XR_NS = "http://v8.1c.ru/8.3/xcf/readable"
XSI_NS = "http://www.w3.org/2001/XMLSchema-instance"
XS_NS = "http://www.w3.org/2001/XMLSchema"
APP_NS = "http://v8.1c.ru/8.2/managed-application/core"

NSMAP = {"md": MD_NS, "v8": V8_NS, "xr": XR_NS, "xsi": XSI_NS, "xs": XS_NS, "app": APP_NS}

GUID_PATTERN = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
IDENT_PATTERN = re.compile(r'^[A-Za-z\u0410-\u042F\u0401\u0430-\u044F\u0451_][A-Za-z0-9\u0410-\u042F\u0401\u0430-\u044F\u0451_]*$')

CLASS_IDS = {
    "ExternalDataProcessor": "c3831ec8-d8d5-4f93-8a22-f9bfae07327f",
    "ExternalReport": "e41aff26-25cf-4bb6-b6c1-3f478a75f374",
}

ALLOWED_CHILD_TYPES = {"Attribute", "TabularSection", "Form", "Template", "Command"}

CHILD_TYPE_ORDER = {
    "Attribute": 0,
    "TabularSection": 1,
    "Form": 2,
    "Template": 3,
    "Command": 4,
}


def localname(el):
    return etree.QName(el.tag).localname


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Validate 1C external data processor/report structure", allow_abbrev=False)
    parser.add_argument("-ObjectPath", "-Path", required=True)
    parser.add_argument("-Detailed", action="store_true")
    parser.add_argument("-MaxErrors", type=int, default=30)
    parser.add_argument("-OutFile", default=None)
    args = parser.parse_args()

    max_errors = args.MaxErrors

    # --- Resolve path ---
    object_path = args.ObjectPath
    if not os.path.isabs(object_path):
        object_path = os.path.join(os.getcwd(), object_path)

    if os.path.isdir(object_path):
        dir_name = os.path.basename(object_path)
        candidate = os.path.join(object_path, f"{dir_name}.xml")
        sibling = os.path.join(os.path.dirname(object_path), f"{dir_name}.xml")
        if os.path.isfile(candidate):
            object_path = candidate
        elif os.path.isfile(sibling):
            object_path = sibling
        else:
            xml_files = [f for f in os.listdir(object_path) if f.lower().endswith(".xml")]
            if xml_files:
                object_path = os.path.join(object_path, xml_files[0])
            else:
                print(f"[ERROR] No XML file found in directory: {object_path}")
                sys.exit(1)

    if not os.path.isfile(object_path):
        file_name = os.path.splitext(os.path.basename(object_path))[0]
        parent_dir = os.path.dirname(object_path)
        parent_dir_name = os.path.basename(parent_dir)
        if file_name == parent_dir_name:
            candidate = os.path.join(os.path.dirname(parent_dir), f"{file_name}.xml")
            if os.path.isfile(candidate):
                object_path = candidate

    if not os.path.isfile(object_path):
        print(f"[ERROR] File not found: {object_path}")
        sys.exit(1)

    resolved_path = os.path.abspath(object_path)
    src_dir = os.path.dirname(resolved_path)

    # --- Output infrastructure ---
    detailed = args.Detailed
    errors = 0
    warnings = 0
    ok_count = 0
    stopped = False
    output_lines = []

    def out_line(msg):
        output_lines.append(msg)

    def report_ok(msg):
        nonlocal ok_count
        ok_count += 1
        if detailed:
            out_line(f"[OK]    {msg}")

    def report_error(msg):
        nonlocal errors, stopped
        errors += 1
        out_line(f"[ERROR] {msg}")
        if errors >= max_errors:
            stopped = True

    def report_warn(msg):
        nonlocal warnings
        warnings += 1
        out_line(f"[WARN]  {msg}")

    def finalize():
        checks = ok_count + errors + warnings
        if errors == 0 and warnings == 0 and not detailed:
            result = f"=== Validation OK: {short_type}.{obj_name} ({checks} checks) ==="
        else:
            out_line("")
            out_line(f"=== Result: {errors} errors, {warnings} warnings ({checks} checks) ===")
            result = "\n".join(output_lines)
        print(result)
        if args.OutFile:
            with open(args.OutFile, "w", encoding="utf-8-sig") as fh:
                fh.write(result)
            print(f"Written to: {args.OutFile}")

    # --- 1. Parse XML ---
    out_line("")

    try:
        xml_parser = etree.XMLParser(remove_blank_text=True)
        tree = etree.parse(resolved_path, xml_parser)
    except Exception as e:
        out_line("=== Validation: (parse failed) ===")
        out_line("")
        report_error(f"1. XML parse failed: {e}")
        finalize()
        sys.exit(1)

    root = tree.getroot()

    # --- Check 1: Root structure ---
    check1_ok = True

    if localname(root) != "MetaDataObject":
        report_error(f"1. Root element is '{localname(root)}', expected 'MetaDataObject'")
        finalize()
        sys.exit(1)

    expected_ns = MD_NS
    if root.tag.split("}")[0].lstrip("{") != expected_ns:
        report_error(f"1. Root namespace is '{root.tag.split('}')[0].lstrip('{')}', expected '{expected_ns}'")
        check1_ok = False

    version = root.get("version", "")
    if not version:
        report_warn("1. Missing version attribute on MetaDataObject")
    elif version not in ("2.17", "2.20", "2.21"):
        report_warn(f"1. Unusual version '{version}' (expected 2.17, 2.20 or 2.21)")

    # Detect type
    child_elements = []
    for child in root:
        if isinstance(child.tag, str) and child.tag.startswith(f"{{{expected_ns}}}"):
            child_elements.append(child)

    if not child_elements:
        report_error("1. No metadata type element found inside MetaDataObject")
        finalize()
        sys.exit(1)
    elif len(child_elements) > 1:
        report_error(f"1. Multiple type elements found: {[localname(c) for c in child_elements]}")
        check1_ok = False

    type_node = child_elements[0]
    md_type = localname(type_node)

    if md_type not in ("ExternalDataProcessor", "ExternalReport"):
        report_error(f"1. Unexpected type '{md_type}' (expected ExternalDataProcessor or ExternalReport)")
        finalize()
        sys.exit(1)

    type_uuid = type_node.get("uuid", "")
    if not type_uuid:
        report_error(f"1. Missing uuid on <{md_type}>")
        check1_ok = False
    elif not GUID_PATTERN.match(type_uuid):
        report_error(f"1. Invalid uuid '{type_uuid}' on <{md_type}>")
        check1_ok = False

    props_node = type_node.find(f"{{{MD_NS}}}Properties")
    name_node = props_node.find(f"{{{MD_NS}}}Name") if props_node is not None else None
    obj_name = name_node.text if name_node is not None and name_node.text else "(unknown)"

    short_type = "EPF" if md_type == "ExternalDataProcessor" else "ERF"
    output_lines.insert(0, f"=== Validation: {short_type}.{obj_name} ===")

    if check1_ok:
        report_ok(f"1. Root structure: MetaDataObject/{md_type}, version {version}")

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 2: InternalInfo ---
    internal_info = type_node.find(f"{{{MD_NS}}}InternalInfo")
    if internal_info is None:
        report_error("2. InternalInfo block missing")
    else:
        check2_ok = True

        contained_obj = internal_info.find(f"{{{XR_NS}}}ContainedObject")
        if contained_obj is None:
            report_error("2. InternalInfo: missing xr:ContainedObject")
            check2_ok = False
        else:
            class_id_node = contained_obj.find(f"{{{XR_NS}}}ClassId")
            object_id_node = contained_obj.find(f"{{{XR_NS}}}ObjectId")

            expected_class_id = CLASS_IDS[md_type]
            if class_id_node is None or not class_id_node.text:
                report_error("2. Missing ClassId in ContainedObject")
                check2_ok = False
            elif class_id_node.text != expected_class_id:
                report_error(f"2. ClassId is '{class_id_node.text}', expected '{expected_class_id}' for {md_type}")
                check2_ok = False

            if object_id_node is not None and object_id_node.text and not GUID_PATTERN.match(object_id_node.text):
                report_error("2. Invalid ObjectId UUID")
                check2_ok = False

        gen_types = internal_info.findall(f"{{{XR_NS}}}GeneratedType")
        if not gen_types:
            report_error("2. No GeneratedType entries found")
            check2_ok = False
        else:
            for gt in gen_types:
                gt_name = gt.get("name", "")
                gt_category = gt.get("category", "")

                if gt_category != "Object":
                    report_warn(f"2. Unexpected GeneratedType category '{gt_category}' (expected 'Object')")

                expected_prefix = f"{md_type}Object."
                if gt_name and obj_name != "(unknown)" and not gt_name.startswith(expected_prefix):
                    report_warn(f"2. GeneratedType name '{gt_name}' does not start with '{expected_prefix}'")

                type_id = gt.find(f"{{{XR_NS}}}TypeId")
                value_id = gt.find(f"{{{XR_NS}}}ValueId")
                if type_id is not None and type_id.text and not GUID_PATTERN.match(type_id.text):
                    report_error("2. Invalid TypeId UUID in GeneratedType")
                    check2_ok = False
                if value_id is not None and value_id.text and not GUID_PATTERN.match(value_id.text):
                    report_error("2. Invalid ValueId UUID in GeneratedType")
                    check2_ok = False

        if check2_ok:
            report_ok(f"2. InternalInfo: ClassId correct, {len(gen_types)} GeneratedType")

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 3: Properties ---
    if props_node is None:
        report_error("3. Properties block missing")
    else:
        check3_ok = True

        if name_node is None or not name_node.text:
            report_error("3. Properties: Name is missing or empty")
            check3_ok = False
        else:
            name_val = name_node.text
            if not IDENT_PATTERN.match(name_val):
                report_error(f"3. Properties: Name '{name_val}' is not a valid 1C identifier")
                check3_ok = False
            if len(name_val) > 80:
                report_warn(f"3. Properties: Name '{name_val}' exceeds 80 characters ({len(name_val)})")

        syn_node = props_node.find(f"{{{MD_NS}}}Synonym")
        syn_present = False
        if syn_node is not None:
            syn_item = syn_node.find(f"{{{V8_NS}}}item")
            if syn_item is not None:
                syn_content = syn_item.find(f"{{{V8_NS}}}content")
                if syn_content is not None and syn_content.text:
                    syn_present = True

        default_form_node = props_node.find(f"{{{MD_NS}}}DefaultForm")
        default_form_val = (default_form_node.text or "").strip() if default_form_node is not None else ""

        aux_form_node = props_node.find(f"{{{MD_NS}}}AuxiliaryForm")
        aux_form_val = (aux_form_node.text or "").strip() if aux_form_node is not None else ""

        main_dcs_val = ""
        if md_type == "ExternalReport":
            main_dcs_node = props_node.find(f"{{{MD_NS}}}MainDataCompositionSchema")
            main_dcs_val = (main_dcs_node.text or "").strip() if main_dcs_node is not None else ""

        if check3_ok:
            syn_info = "Synonym present" if syn_present else "no Synonym"
            extras = ""
            if default_form_val:
                extras += ", DefaultForm set"
            if main_dcs_val:
                extras += ", MainDCS set"
            report_ok(f'3. Properties: Name="{obj_name}", {syn_info}{extras}')

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 4: ChildObjects ---
    child_obj_node = type_node.find(f"{{{MD_NS}}}ChildObjects")
    form_names = []
    template_names = []

    if child_obj_node is not None:
        check4_ok = True
        child_counts = {}
        last_order = -1
        order_ok = True

        for child in child_obj_node:
            if not isinstance(child.tag, str):
                continue
            child_tag = localname(child)

            if child_tag not in ALLOWED_CHILD_TYPES:
                report_error(f"4. ChildObjects: disallowed element '{child_tag}'")
                check4_ok = False
                continue

            child_counts[child_tag] = child_counts.get(child_tag, 0) + 1

            this_order = CHILD_TYPE_ORDER.get(child_tag, -1)
            if this_order < last_order and order_ok:
                report_warn(f"4. ChildObjects: '{child_tag}' appears after higher-order elements (expected: Attribute, TabularSection, Form, Template, Command)")
                order_ok = False
            last_order = this_order

            if child_tag == "Form":
                form_names.append((child.text or "").strip())
            elif child_tag == "Template":
                template_names.append((child.text or "").strip())

        if check4_ok:
            summary = ", ".join(f"{k}({v})" for k, v in sorted(child_counts.items(), key=lambda x: CHILD_TYPE_ORDER.get(x[0], 99)))
            if summary:
                report_ok(f"4. ChildObjects: {summary}")
            else:
                report_ok("4. ChildObjects: empty")
    else:
        pass  # no ChildObjects — nothing to check

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 5: DefaultForm / MainDCS cross-references ---
    check5_ok = True

    if default_form_val:
        expected_prefix = f"{md_type}.{obj_name}.Form."
        if default_form_val.startswith(expected_prefix):
            ref_form_name = default_form_val[len(expected_prefix):]
            if ref_form_name not in form_names:
                report_error(f"5. DefaultForm references '{ref_form_name}', but no such Form in ChildObjects")
                check5_ok = False
        else:
            report_warn(f"5. DefaultForm value '{default_form_val}' has unexpected prefix (expected '{expected_prefix}...')")

    if aux_form_val:
        expected_prefix = f"{md_type}.{obj_name}.Form."
        if aux_form_val.startswith(expected_prefix):
            ref_form_name = aux_form_val[len(expected_prefix):]
            if ref_form_name not in form_names:
                report_error(f"5. AuxiliaryForm references '{ref_form_name}', but no such Form in ChildObjects")
                check5_ok = False

    if main_dcs_val and md_type == "ExternalReport":
        expected_prefix = f"ExternalReport.{obj_name}.Template."
        if main_dcs_val.startswith(expected_prefix):
            ref_tpl_name = main_dcs_val[len(expected_prefix):]
            if ref_tpl_name not in template_names:
                report_error(f"5. MainDataCompositionSchema references '{ref_tpl_name}', but no such Template in ChildObjects")
                check5_ok = False
        else:
            report_warn(f"5. MainDataCompositionSchema value '{main_dcs_val}' has unexpected prefix")

    if check5_ok:
        refs = []
        if default_form_val:
            refs.append("DefaultForm")
        if aux_form_val:
            refs.append("AuxiliaryForm")
        if main_dcs_val:
            refs.append("MainDCS")
        if refs:
            report_ok(f"5. Cross-references: {', '.join(refs)} valid")
        else:
            pass  # no cross-references to check

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 6: Attributes ---
    def check_attribute(node, context):
        uuid = node.get("uuid", "")
        if not uuid:
            report_error(f"6. {context}Attribute missing uuid")
            return False
        if not GUID_PATTERN.match(uuid):
            report_error(f"6. {context}Attribute has invalid uuid '{uuid}'")
            return False

        el_props = node.find(f"{{{MD_NS}}}Properties")
        if el_props is None:
            report_error(f"6. {context}Attribute (uuid={uuid}) missing Properties")
            return False

        el_name = el_props.find(f"{{{MD_NS}}}Name")
        if el_name is None or not el_name.text:
            report_error(f"6. {context}Attribute (uuid={uuid}) missing or empty Name")
            return False

        name_val = el_name.text
        if not IDENT_PATTERN.match(name_val):
            report_error(f"6. {context}Attribute '{name_val}' has invalid identifier")
            return False

        type_el = el_props.find(f"{{{MD_NS}}}Type")
        if type_el is None:
            report_error(f"6. {context}Attribute '{name_val}' missing Type block")
            return False

        v8_types = type_el.findall(f"{{{V8_NS}}}Type")
        v8_type_sets = type_el.findall(f"{{{V8_NS}}}TypeSet")
        if not v8_types and not v8_type_sets:
            report_error(f"6. {context}Attribute '{name_val}' Type block has no v8:Type or v8:TypeSet")
            return False

        return True

    if child_obj_node is not None:
        attrs = child_obj_node.findall(f"{{{MD_NS}}}Attribute")
        check6_ok = True
        attr_count = 0

        for attr in attrs:
            if stopped:
                break
            ok = check_attribute(attr, "")
            if not ok:
                check6_ok = False
            attr_count += 1

        if attr_count > 0:
            if check6_ok:
                report_ok(f"6. Attributes: {attr_count} checked (UUID, Name, Type)")
        else:
            pass  # no attributes
    else:
        pass  # no ChildObjects

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 7: TabularSections ---
    if child_obj_node is not None:
        ts_sections = child_obj_node.findall(f"{{{MD_NS}}}TabularSection")
        if ts_sections:
            check7_ok = True
            ts_count = 0
            ts_attr_total = 0

            for ts in ts_sections:
                if stopped:
                    break
                ts_count += 1

                ts_uuid = ts.get("uuid", "")
                if not ts_uuid or not GUID_PATTERN.match(ts_uuid):
                    report_error(f"7. TabularSection #{ts_count}: invalid or missing uuid")
                    check7_ok = False

                ts_props = ts.find(f"{{{MD_NS}}}Properties")
                ts_name_node = ts_props.find(f"{{{MD_NS}}}Name") if ts_props is not None else None
                ts_name = ts_name_node.text if ts_name_node is not None and ts_name_node.text else "(unnamed)"

                if ts_name_node is None or not ts_name_node.text:
                    report_error(f"7. TabularSection #{ts_count}: missing or empty Name")
                    check7_ok = False
                elif not IDENT_PATTERN.match(ts_name):
                    report_error(f"7. TabularSection '{ts_name}': invalid identifier")
                    check7_ok = False

                ts_int_info = ts.find(f"{{{MD_NS}}}InternalInfo")
                if ts_int_info is not None:
                    ts_gens = ts_int_info.findall(f"{{{XR_NS}}}GeneratedType")
                    if len(ts_gens) < 2:
                        report_warn(f"7. TabularSection '{ts_name}': expected 2 GeneratedType, found {len(ts_gens)}")

                ts_child_obj = ts.find(f"{{{MD_NS}}}ChildObjects")
                if ts_child_obj is not None:
                    ts_attrs = ts_child_obj.findall(f"{{{MD_NS}}}Attribute")
                    ts_attr_names = {}
                    for ta in ts_attrs:
                        ta_ok = check_attribute(ta, f"TabularSection '{ts_name}'.")
                        if not ta_ok:
                            check7_ok = False
                        ts_attr_total += 1

                        ta_props = ta.find(f"{{{MD_NS}}}Properties")
                        if ta_props is not None:
                            ta_name_node = ta_props.find(f"{{{MD_NS}}}Name")
                            if ta_name_node is not None and ta_name_node.text:
                                if ta_name_node.text in ts_attr_names:
                                    report_error(f"7. Duplicate attribute '{ta_name_node.text}' in TabularSection '{ts_name}'")
                                    check7_ok = False
                                else:
                                    ts_attr_names[ta_name_node.text] = True

            if check7_ok:
                report_ok(f"7. TabularSections: {ts_count} sections, {ts_attr_total} inner attributes")
        else:
            pass  # no tabular sections
    else:
        pass  # no ChildObjects

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 8: Name uniqueness ---
    check8_ok = True
    all_names = {}

    if child_obj_node is not None:
        name_kinds = [
            ("Attribute", f"{{{MD_NS}}}Attribute"),
            ("TabularSection", f"{{{MD_NS}}}TabularSection"),
            ("Command", f"{{{MD_NS}}}Command"),
        ]

        for kind, xpath in name_kinds:
            nodes = child_obj_node.findall(xpath)
            for node in nodes:
                np = node.find(f"{{{MD_NS}}}Properties")
                if np is not None:
                    nn = np.find(f"{{{MD_NS}}}Name")
                    if nn is not None and nn.text:
                        nv = nn.text
                        if nv in all_names:
                            report_error(f"8. Duplicate name '{nv}' ({kind} conflicts with {all_names[nv]})")
                            check8_ok = False
                        else:
                            all_names[nv] = kind

        for fn in form_names:
            if fn in all_names:
                report_error(f"8. Duplicate name '{fn}' (Form conflicts with {all_names[fn]})")
                check8_ok = False
            else:
                all_names[fn] = "Form"
        for tn in template_names:
            if tn in all_names:
                report_error(f"8. Duplicate name '{tn}' (Template conflicts with {all_names[tn]})")
                check8_ok = False
            else:
                all_names[tn] = "Template"

    if check8_ok:
        report_ok(f"8. Name uniqueness: {len(all_names)} names, all unique")

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 9: File existence ---
    check9_ok = True
    files_checked = 0
    obj_dir = os.path.join(src_dir, obj_name)

    for fn in form_names:
        form_meta_xml = os.path.join(obj_dir, "Forms", f"{fn}.xml")
        if not os.path.isfile(form_meta_xml):
            report_error(f"9. Missing form descriptor: Forms/{fn}.xml")
            check9_ok = False
        else:
            files_checked += 1

        form_xml = os.path.join(obj_dir, "Forms", fn, "Ext", "Form.xml")
        if not os.path.isfile(form_xml):
            report_error(f"9. Missing form layout: Forms/{fn}/Ext/Form.xml")
            check9_ok = False
        else:
            files_checked += 1

    for tn in template_names:
        tpl_meta_xml = os.path.join(obj_dir, "Templates", f"{tn}.xml")
        if not os.path.isfile(tpl_meta_xml):
            report_error(f"9. Missing template descriptor: Templates/{tn}.xml")
            check9_ok = False
        else:
            files_checked += 1

        tpl_ext_dir = os.path.join(obj_dir, "Templates", tn, "Ext")
        if os.path.isdir(tpl_ext_dir):
            tpl_files = [f for f in os.listdir(tpl_ext_dir) if f.startswith("Template.")]
            if not tpl_files:
                report_error(f"9. Missing template content: Templates/{tn}/Ext/Template.*")
                check9_ok = False
            else:
                files_checked += 1
        else:
            report_error(f"9. Missing template Ext directory: Templates/{tn}/Ext/")
            check9_ok = False

    obj_module = os.path.join(obj_dir, "Ext", "ObjectModule.bsl")
    if os.path.isfile(obj_module):
        files_checked += 1

    if check9_ok:
        if files_checked > 0:
            report_ok(f"9. File existence: {files_checked} files verified")
        else:
            pass  # no forms/templates to check

    if stopped:
        finalize()
        sys.exit(1)

    # --- Check 10: Form descriptors structure ---
    check10_ok = True
    forms_checked = 0

    for fn in form_names:
        form_meta_xml = os.path.join(obj_dir, "Forms", f"{fn}.xml")
        if not os.path.isfile(form_meta_xml):
            continue

        try:
            f_parser = etree.XMLParser(remove_blank_text=True)
            f_tree = etree.parse(form_meta_xml, f_parser)
            f_root = f_tree.getroot()

            if localname(f_root) != "MetaDataObject":
                report_error(f"10. Form '{fn}': root element is '{localname(f_root)}', expected 'MetaDataObject'")
                check10_ok = False
                continue

            f_type_node = f_root.find(f"{{{MD_NS}}}Form")
            if f_type_node is None:
                report_error(f"10. Form '{fn}': missing <Form> element")
                check10_ok = False
                continue

            f_uuid = f_type_node.get("uuid", "")
            if not f_uuid or not GUID_PATTERN.match(f_uuid):
                report_error(f"10. Form '{fn}': invalid or missing uuid")
                check10_ok = False

            f_props = f_type_node.find(f"{{{MD_NS}}}Properties")
            if f_props is not None:
                f_name = f_props.find(f"{{{MD_NS}}}Name")
                if f_name is not None and f_name.text != fn:
                    report_error(f"10. Form '{fn}': Name in descriptor is '{f_name.text}', expected '{fn}'")
                    check10_ok = False

                f_type = f_props.find(f"{{{MD_NS}}}FormType")
                if f_type is not None and f_type.text != "Managed":
                    report_warn(f"10. Form '{fn}': FormType is '{f_type.text}' (expected 'Managed')")

            forms_checked += 1
        except Exception as e:
            report_error(f"10. Form '{fn}': XML parse error: {e}")
            check10_ok = False

    if check10_ok:
        if forms_checked > 0:
            report_ok(f"10. Form descriptors: {forms_checked} checked")
        else:
            pass  # no form descriptors to check

    # --- Final output ---
    finalize()

    if errors > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
