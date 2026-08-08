# skd-validate v1.2 — Validate 1C DCS structure (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-TemplatePath", "-Path", required=True)
parser.add_argument("-Detailed", action="store_true")
parser.add_argument("-MaxErrors", type=int, default=20)
parser.add_argument("-OutFile", default="")
args = parser.parse_args()

template_path = args.TemplatePath
detailed = args.Detailed
max_errors = args.MaxErrors
out_file = args.OutFile

# ── resolve path ─────────────────────────────────────────────

# A: Directory → Ext/Template.xml
if os.path.isdir(template_path):
    template_path = os.path.join(template_path, 'Ext', 'Template.xml')
# B1: Missing Ext/ (e.g. Templates/СКД/Template.xml → Templates/СКД/Ext/Template.xml)
if not os.path.exists(template_path):
    fn = os.path.basename(template_path)
    if fn == 'Template.xml':
        c = os.path.join(os.path.dirname(template_path), 'Ext', fn)
        if os.path.exists(c):
            template_path = c
# B2: Descriptor (.xml → dir/Ext/Template.xml)
if not os.path.exists(template_path) and template_path.endswith('.xml'):
    stem = os.path.splitext(os.path.basename(template_path))[0]
    parent = os.path.dirname(template_path)
    c = os.path.join(parent, stem, 'Ext', 'Template.xml')
    if os.path.exists(c):
        template_path = c

if not os.path.exists(template_path):
    print(f"File not found: {template_path}", file=sys.stderr)
    sys.exit(1)

resolved_path = os.path.abspath(template_path)
file_name = os.path.basename(resolved_path)

# ── output infrastructure ────────────────────────────────────

errors = 0
warnings = 0
ok_count = 0
stopped = False
output_lines = []


def out_line(msg):
    output_lines.append(msg)


def report_ok(msg):
    global ok_count
    ok_count += 1
    if detailed:
        out_line(f"[OK]    {msg}")


def report_error(msg):
    global errors, stopped
    errors += 1
    out_line(f"[ERROR] {msg}")
    if errors >= max_errors:
        stopped = True


def report_warn(msg):
    global warnings
    warnings += 1
    out_line(f"[WARN]  {msg}")


def finalize():
    checks = ok_count + errors + warnings
    if errors == 0 and warnings == 0 and not detailed:
        result = f"=== Validation OK: {file_name} ({checks} checks) ==="
    else:
        out_line("")
        out_line(f"=== Result: {errors} errors, {warnings} warnings ({checks} checks) ===")
        result = "\n".join(output_lines)
    print(result)
    if out_file:
        with open(out_file, "w", encoding="utf-8-sig") as f:
            f.write(result)
        print(f"Written to: {out_file}")


out_line(f"=== Validation: {file_name} ===")
out_line("")

# ── 1. Parse XML ─────────────────────────────────────────────

NS = {
    "s": "http://v8.1c.ru/8.1/data-composition-system/schema",
    "dcscom": "http://v8.1c.ru/8.1/data-composition-system/common",
    "dcscor": "http://v8.1c.ru/8.1/data-composition-system/core",
    "dcsset": "http://v8.1c.ru/8.1/data-composition-system/settings",
    "v8": "http://v8.1c.ru/8.1/data/core",
    "v8ui": "http://v8.1c.ru/8.1/data/ui",
    "xs": "http://www.w3.org/2001/XMLSchema",
    "xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "dcsat": "http://v8.1c.ru/8.1/data-composition-system/area-template",
}

XSI_TYPE = f"{{{NS['xsi']}}}type"

tree = None
try:
    parser_xml = etree.XMLParser(remove_blank_text=False)
    tree = etree.parse(resolved_path, parser_xml)
    report_ok("XML parsed successfully")
except Exception as e:
    report_error(f"XML parse failed: {e}")
    result = "\n".join(output_lines)
    print(result)
    if out_file:
        with open(out_file, "w", encoding="utf-8-sig") as f:
            f.write(result)
    sys.exit(1)

root = tree.getroot()


def local_name(node):
    return etree.QName(node.tag).localname


def find(parent, xpath):
    """XPath find with namespaces, returns first match or None."""
    r = parent.xpath(xpath, namespaces=NS)
    return r[0] if r else None


def find_all(parent, xpath):
    """XPath findall with namespaces."""
    return parent.xpath(xpath, namespaces=NS)


def text_of(node):
    """Return stripped text or empty string."""
    if node is None:
        return ""
    return (node.text or "").strip()


def inner_text(node):
    """Return text (non-stripped) or empty string."""
    if node is None:
        return ""
    return node.text or ""

# ── 3. Root element checks ───────────────────────────────────

if local_name(root) != "DataCompositionSchema":
    report_error(f"Root element is '{local_name(root)}', expected 'DataCompositionSchema'")
else:
    report_ok("Root element: DataCompositionSchema")

expected_ns = "http://v8.1c.ru/8.1/data-composition-system/schema"
root_ns = etree.QName(root.tag).namespace or ""
if root_ns != expected_ns:
    report_error(f"Default namespace is '{root_ns}', expected '{expected_ns}'")
else:
    report_ok("Default namespace correct")

if stopped:
    finalize()
    sys.exit(1)

# ── 4. Collect inventories ───────────────────────────────────

# DataSources
data_source_nodes = find_all(root, "s:dataSource")
data_source_names = {}
for dsn in data_source_nodes:
    name = find(dsn, "s:name")
    if name is not None:
        data_source_names[inner_text(name)] = True

# DataSets (recursive for unions)
data_set_nodes = find_all(root, "s:dataSet")
data_set_names = {}
all_field_paths = {}  # dataPath -> dataSet name


def collect_data_set_fields(ds_node, ds_name):
    fields = find_all(ds_node, "s:field")
    local_paths = {}
    for f in fields:
        dp = find(f, "s:dataPath")
        if dp is not None:
            path = inner_text(dp)
            local_paths[path] = True
            all_field_paths[path] = ds_name
    # Union items
    items = find_all(ds_node, "s:item")
    for item in items:
        item_name = find(item, "s:name")
        if item_name is not None:
            collect_data_set_fields(item, inner_text(item_name))
    return local_paths


data_set_field_map = {}
for ds in data_set_nodes:
    name_node = find(ds, "s:name")
    if name_node is not None:
        ds_name = inner_text(name_node)
        data_set_names[ds_name] = True
        data_set_field_map[ds_name] = collect_data_set_fields(ds, ds_name)

# CalculatedFields
calc_field_nodes = find_all(root, "s:calculatedField")
calc_field_paths = {}
for cf in calc_field_nodes:
    dp = find(cf, "s:dataPath")
    if dp is not None:
        calc_field_paths[inner_text(dp)] = True

# TotalFields
total_field_nodes = find_all(root, "s:totalField")

# Parameters
param_nodes = find_all(root, "s:parameter")
param_names = {}
for p in param_nodes:
    name_node = find(p, "s:name")
    if name_node is not None:
        param_names[inner_text(name_node)] = True

# Templates
template_nodes = find_all(root, "s:template")
template_names = {}
for t in template_nodes:
    name_node = find(t, "s:name")
    if name_node is not None:
        template_names[inner_text(name_node)] = True

# GroupTemplates
group_template_nodes = find_all(root, "s:groupTemplate")

# SettingsVariants
variant_nodes = find_all(root, "s:settingsVariant")

# Known fields = dataset fields + calculated fields
known_fields = {}
for key in all_field_paths:
    known_fields[key] = True
for key in calc_field_paths:
    known_fields[key] = True

# ── 5. DataSource checks ─────────────────────────────────────

if len(data_source_nodes) == 0:
    report_warn("No dataSource elements found (settings-only DCS?)")
else:
    ds_names_seen = {}
    ds_ok = True
    for dsn in data_source_nodes:
        name = find(dsn, "s:name")
        typ = find(dsn, "s:dataSourceType")
        if name is None or not inner_text(name):
            report_error("DataSource has empty name")
            ds_ok = False
        elif inner_text(name) in ds_names_seen:
            report_error(f"Duplicate dataSource name: {inner_text(name)}")
            ds_ok = False
        else:
            ds_names_seen[inner_text(name)] = True
        if typ is not None:
            tv = inner_text(typ)
            if tv not in ("Local", "External"):
                report_warn(f"DataSource '{inner_text(name)}' has unusual type: {tv}")
    if ds_ok:
        report_ok(f"{len(data_source_nodes)} dataSource(s) found, names unique")

if stopped:
    finalize()
    sys.exit(1)

# ── 6. DataSet checks ────────────────────────────────────────

valid_ds_types = ("DataSetQuery", "DataSetObject", "DataSetUnion")

if len(data_set_nodes) == 0:
    report_warn("No dataSet elements found (settings-only DCS?)")
else:
    ds_names_seen = {}
    ds_ok = True
    for ds in data_set_nodes:
        xsi_type = ds.get(XSI_TYPE, "")
        name_node = find(ds, "s:name")
        ds_name = inner_text(name_node) if name_node is not None else "(unnamed)"

        if name_node is None or not inner_text(name_node):
            report_error("DataSet has empty name")
            ds_ok = False
        elif ds_name in ds_names_seen:
            report_error(f"Duplicate dataSet name: {ds_name}")
            ds_ok = False
        else:
            ds_names_seen[ds_name] = True

        if not xsi_type:
            report_error(f"DataSet '{ds_name}' missing xsi:type")
            ds_ok = False
        elif xsi_type not in valid_ds_types:
            report_warn(f"DataSet '{ds_name}' has unusual xsi:type: {xsi_type}")

        # Check dataSource reference
        if xsi_type != "DataSetUnion":
            src_node = find(ds, "s:dataSource")
            if src_node is not None and inner_text(src_node):
                if inner_text(src_node) not in data_source_names:
                    report_error(f"DataSet '{ds_name}' references unknown dataSource: {inner_text(src_node)}")
                    ds_ok = False

        # Check query not empty for Query type
        if xsi_type == "DataSetQuery":
            query_node = find(ds, "s:query")
            if query_node is None or not text_of(query_node):
                report_warn(f"DataSet '{ds_name}' (Query) has empty query")

        # Check objectName for Object type
        if xsi_type == "DataSetObject":
            obj_node = find(ds, "s:objectName")
            if obj_node is None or not text_of(obj_node):
                report_error(f"DataSet '{ds_name}' (Object) has empty objectName")
                ds_ok = False

    if ds_ok:
        report_ok(f"{len(data_set_nodes)} dataSet(s) found, names unique")

if stopped:
    finalize()
    sys.exit(1)

# ── 7. Field checks ──────────────────────────────────────────


def check_data_set_fields(ds_node, ds_name):
    global stopped
    fields = find_all(ds_node, "s:field")
    if len(fields) == 0:
        return

    paths_seen = {}
    field_ok = True

    for f in fields:
        dp = find(f, "s:dataPath")
        fn = find(f, "s:field")

        if dp is None or not inner_text(dp):
            report_error(f"DataSet '{ds_name}': field has empty dataPath")
            field_ok = False
            continue

        path = inner_text(dp)
        if path in paths_seen:
            report_warn(f"DataSet '{ds_name}': duplicate dataPath '{path}'")
        else:
            paths_seen[path] = True

        if fn is None or not inner_text(fn):
            report_warn(f"DataSet '{ds_name}': field '{path}' has empty <field> element")

    if field_ok:
        report_ok(f'DataSet "{ds_name}": {len(fields)} fields, dataPath unique')

    # Check union items recursively
    items = find_all(ds_node, "s:item")
    for item in items:
        item_name = find(item, "s:name")
        i_name = inner_text(item_name) if item_name is not None else "(unnamed item)"
        check_data_set_fields(item, i_name)


for ds in data_set_nodes:
    name_node = find(ds, "s:name")
    ds_name = inner_text(name_node) if name_node is not None else "(unnamed)"
    check_data_set_fields(ds, ds_name)

if stopped:
    finalize()
    sys.exit(1)

# ── 8. DataSetLink checks ────────────────────────────────────

link_nodes = find_all(root, "s:dataSetLink")
if len(link_nodes) > 0:
    link_ok = True
    for link in link_nodes:
        src = find(link, "s:sourceDataSet")
        dst = find(link, "s:destinationDataSet")
        src_expr = find(link, "s:sourceExpression")
        dst_expr = find(link, "s:destinationExpression")

        if src is not None and inner_text(src) and inner_text(src) not in data_set_names:
            report_error(f"DataSetLink: sourceDataSet '{inner_text(src)}' not found")
            link_ok = False
        if dst is not None and inner_text(dst) and inner_text(dst) not in data_set_names:
            report_error(f"DataSetLink: destinationDataSet '{inner_text(dst)}' not found")
            link_ok = False
        if src_expr is None or not text_of(src_expr):
            report_error("DataSetLink: empty sourceExpression")
            link_ok = False
        if dst_expr is None or not text_of(dst_expr):
            report_error("DataSetLink: empty destinationExpression")
            link_ok = False
    if link_ok:
        report_ok(f"{len(link_nodes)} dataSetLink(s): references valid")

if stopped:
    finalize()
    sys.exit(1)

# ── 9. CalculatedField checks ────────────────────────────────

if len(calc_field_nodes) > 0:
    cf_ok = True
    cf_seen = {}
    # Collect totalField dataPaths — an empty calculatedField is legitimate if a
    # totalField with the same dataPath provides the expression (real-world
    # pattern in vendor ERP/БП reports for fields visible only in totals).
    tf_paths = set()
    for tf in total_field_nodes:
        tf_dp = find(tf, "s:dataPath")
        if tf_dp is not None and inner_text(tf_dp):
            tf_paths.add(inner_text(tf_dp))

    for cf in calc_field_nodes:
        dp = find(cf, "s:dataPath")
        expr = find(cf, "s:expression")

        if dp is None or not inner_text(dp):
            report_error("CalculatedField has empty dataPath")
            cf_ok = False
            continue

        path = inner_text(dp)
        if path in cf_seen:
            report_error(f"Duplicate calculatedField dataPath: {path}")
            cf_ok = False
        else:
            cf_seen[path] = True

        if expr is None or not text_of(expr):
            # Empty expression is legitimate in several vendor patterns:
            #   - totalField with same dataPath provides the calculation
            #   - groupTemplate uses the field as group name (declarative only)
            #   - field is referenced only by settingsVariants for grouping
            # Surface as warning, not error, to avoid false positives on real
            # ERP/БП reports while still flagging the unusual shape.
            if path not in tf_paths:
                report_warn(f"CalculatedField '{path}' has empty expression (declarative-only?)")

        # Warn if collides with a dataset field
        if path in all_field_paths:
            report_warn(f"CalculatedField '{path}' shadows dataSet field in '{all_field_paths[path]}'")

    if cf_ok:
        report_ok(f"{len(calc_field_nodes)} calculatedField(s): dataPath and expression valid")

if stopped:
    finalize()
    sys.exit(1)

# ── 10. TotalField checks ────────────────────────────────────

if len(total_field_nodes) > 0:
    tf_ok = True
    for tf in total_field_nodes:
        dp = find(tf, "s:dataPath")
        expr = find(tf, "s:expression")

        if dp is None or not inner_text(dp):
            report_error("TotalField has empty dataPath")
            tf_ok = False
            continue

        if expr is None or not text_of(expr):
            report_error(f"TotalField '{inner_text(dp)}' has empty expression")
            tf_ok = False

    if tf_ok:
        report_ok(f"{len(total_field_nodes)} totalField(s): dataPath and expression present")

if stopped:
    finalize()
    sys.exit(1)

# ── 11. Parameter checks ─────────────────────────────────────

if len(param_nodes) > 0:
    param_ok = True
    param_seen = {}
    for p in param_nodes:
        name_node = find(p, "s:name")
        if name_node is None or not inner_text(name_node):
            report_error("Parameter has empty name")
            param_ok = False
            continue
        p_name = inner_text(name_node)
        if p_name in param_seen:
            report_error(f"Duplicate parameter name: {p_name}")
            param_ok = False
        else:
            param_seen[p_name] = True
    if param_ok:
        report_ok(f"{len(param_nodes)} parameter(s): names unique")

if stopped:
    finalize()
    sys.exit(1)

# ── 12. Template checks ──────────────────────────────────────

if len(template_nodes) > 0:
    tpl_ok = True
    tpl_seen = {}
    for t in template_nodes:
        name_node = find(t, "s:name")
        if name_node is None or not inner_text(name_node):
            report_error("Template has empty name")
            tpl_ok = False
            continue
        t_name = inner_text(name_node)
        if t_name in tpl_seen:
            # Vendor configs (ERP/БП) ship templates with repeating names — the
            # platform identifies them by position/context, not by <name>. Demote
            # to warning so the check still surfaces the collision without failing.
            report_warn(f"Duplicate template name: {t_name} (allowed by platform but ambiguous)")
        else:
            tpl_seen[t_name] = True
    if tpl_ok:
        report_ok(f"{len(template_nodes)} template(s) found")

# ── 13. GroupTemplate checks ─────────────────────────────────

if len(group_template_nodes) > 0:
    gt_ok = True
    valid_tpl_types = ("Header", "Footer", "Overall", "OverallHeader", "OverallFooter")
    for gt in group_template_nodes:
        tpl_ref = find(gt, "s:template")
        tpl_type = find(gt, "s:templateType")

        if tpl_ref is not None and inner_text(tpl_ref) and inner_text(tpl_ref) not in template_names:
            report_error(f"GroupTemplate references unknown template: {inner_text(tpl_ref)}")
            gt_ok = False
        if tpl_type is not None and inner_text(tpl_type) not in valid_tpl_types:
            report_warn(f"GroupTemplate has unusual templateType: {inner_text(tpl_type)}")
    if gt_ok:
        report_ok(f"{len(group_template_nodes)} groupTemplate(s): references valid")

if stopped:
    finalize()
    sys.exit(1)

# ── 14. Settings helper functions ─────────────────────────────

valid_comparison_types = (
    "Equal", "NotEqual", "Greater", "GreaterOrEqual", "Less", "LessOrEqual",
    "InList", "NotInList", "InHierarchy", "NotInHierarchy",
    "InListByHierarchy", "NotInListByHierarchy",
    "Contains", "NotContains", "BeginsWith", "NotBeginsWith",
    "Filled", "NotFilled",
)

valid_structure_types = (
    "dcsset:StructureItemGroup",
    "dcsset:StructureItemTable",
    "dcsset:StructureItemChart",
    "dcsset:StructureItemNestedObject",
)


def check_filter_items(parent_node, variant_name):
    global stopped
    filter_items = find_all(parent_node, "dcsset:filter/dcsset:item")
    for fi in filter_items:
        if stopped:
            return
        xsi_type = fi.get(XSI_TYPE, "")
        if xsi_type == "dcsset:FilterItemComparison":
            comp_type = find(fi, "dcsset:comparisonType")
            if comp_type is not None and inner_text(comp_type) not in valid_comparison_types:
                report_error(f"Variant '{variant_name}' filter: invalid comparisonType '{inner_text(comp_type)}'")
        elif xsi_type == "dcsset:FilterItemGroup":
            group_type = find(fi, "dcsset:groupType")
            if group_type is not None:
                valid_group_types = ("AndGroup", "OrGroup", "NotGroup")
                if inner_text(group_type) not in valid_group_types:
                    report_warn(f"Variant '{variant_name}' filter group: unusual groupType '{inner_text(group_type)}'")
            # Recurse into nested items
            nested_items = find_all(fi, "dcsset:item")
            for ni in nested_items:
                ni_type = ni.get(XSI_TYPE, "")
                if ni_type == "dcsset:FilterItemComparison":
                    comp_type = find(ni, "dcsset:comparisonType")
                    if comp_type is not None and inner_text(comp_type) not in valid_comparison_types:
                        report_error(f"Variant '{variant_name}' filter: invalid comparisonType '{inner_text(comp_type)}'")


def check_structure_item(item_node, variant_name):
    global stopped
    if stopped:
        return

    xsi_type = item_node.get(XSI_TYPE, "")
    if not xsi_type:
        report_error(f"Variant '{variant_name}': structure item missing xsi:type")
        return
    if xsi_type not in valid_structure_types:
        report_warn(f"Variant '{variant_name}': unusual structure item type '{xsi_type}'")

    # Recurse into nested items (groups can contain groups)
    nested_items = find_all(item_node, "dcsset:item")
    for ni in nested_items:
        check_structure_item(ni, variant_name)

    # Check column/row in tables
    if xsi_type == "dcsset:StructureItemTable":
        columns = find_all(item_node, "dcsset:column")
        rows = find_all(item_node, "dcsset:row")
        if len(columns) == 0:
            report_warn(f"Variant '{variant_name}': table has no columns")
        if len(rows) == 0:
            report_warn(f"Variant '{variant_name}': table has no rows")


def check_settings(settings_node, variant_name):
    global stopped
    if stopped:
        return

    # Selection
    sel_items = find_all(settings_node, "dcsset:selection/dcsset:item")
    for si in sel_items:
        xsi_type = si.get(XSI_TYPE, "")
        if xsi_type == "dcsset:SelectedItemField":
            field = find(si, "dcsset:field")
            if field is not None and inner_text(field) and inner_text(field) != "SystemFields.Number":
                base_path = inner_text(field).split(".")[0]
                if inner_text(field) not in known_fields and base_path not in known_fields:
                    pass  # Soft check — autoFillFields may add fields not listed explicitly

    # Filter
    check_filter_items(settings_node, variant_name)

    # Order
    order_items = find_all(settings_node, "dcsset:order/dcsset:item")
    for oi in order_items:
        xsi_type = oi.get(XSI_TYPE, "")
        if xsi_type == "dcsset:OrderItemField":
            order_type = find(oi, "dcsset:orderType")
            if order_type is not None and inner_text(order_type) not in ("Asc", "Desc"):
                report_warn(f"Variant '{variant_name}' order: invalid orderType '{inner_text(order_type)}'")

    # Structure items
    struct_items = find_all(settings_node, "dcsset:item")
    for si in struct_items:
        check_structure_item(si, variant_name)


# ── 15. SettingsVariant checks ────────────────────────────────

if len(variant_nodes) == 0:
    report_warn("No settingsVariant elements found")
else:
    v_ok = True
    v_idx = 0
    for v in variant_nodes:
        v_idx += 1
        v_name = find(v, "dcsset:name")
        if v_name is None or not inner_text(v_name):
            report_error(f"SettingsVariant #{v_idx} has empty name")
            v_ok = False

        settings = find(v, "dcsset:settings")
        if settings is None:
            report_error(f"SettingsVariant '{inner_text(v_name) if v_name is not None else ''}' has no settings element")
            v_ok = False
            continue

        # Check settings internals
        check_settings(settings, inner_text(v_name) if v_name is not None else "")

    if v_ok:
        report_ok(f"{len(variant_nodes)} settingsVariant(s) found")

# ── 16. valueType structural checks ───────────────────────────
# Catches broken XDTO that XML/structural checks miss (decimal without xs:,
# missing qualifiers, mismatched qualifier blocks, unknown sign/length tokens).

import re as _re_vt

_VALID_TYPE_QUALIFIER = {
    'xs:decimal':        'v8:NumberQualifiers',
    'xs:string':         'v8:StringQualifiers',
    'xs:dateTime':       'v8:DateQualifiers',
    'xs:boolean':        '',
    'v8:StandardPeriod': '',
    'v8:UUID':           '',
    'v8:Null':           '',
    'v8:Type':           '',
    'v8:ValueStorage':   '',
}
_VALID_SIGN      = ('Any', 'Nonnegative', 'Negative')
_VALID_LENGTH    = ('Variable', 'Fixed')
_VALID_FRACTIONS = ('Date', 'DateTime', 'Time')
_V8_NS_URI       = 'http://v8.1c.ru/8.1/data/core'
_CONFIG_NS_URI   = 'http://v8.1c.ru/8.1/data/enterprise/current-config'

# DCS supports composite types: multiple <v8:Type> blocks may share a single
# trailing qualifier block (e.g. xs:string + CatalogRef.X + StringQualifiers).
# So we collect all types and qualifiers per valueType, then check consistency.
_QUALIFIER_PRODUCERS = {
    'v8:NumberQualifiers': 'xs:decimal',
    'v8:StringQualifiers': 'xs:string',
    'v8:DateQualifiers':   'xs:dateTime',
}

vt_nodes = find_all(root, "//s:valueType")
vt_checked = 0
vt_ok = True
for vt in vt_nodes:
    vt_checked += 1
    types = []        # short type strings; '' marks a ref type
    qualifiers = []   # list of (qName, node)

    for child in vt:
        if not isinstance(child.tag, str):
            continue
        qn = etree.QName(child.tag)
        if qn.namespace != _V8_NS_URI:
            continue
        local = qn.localname

        if local == 'Type':
            t = (child.text or '').strip()
            if not t:
                report_error("valueType: <v8:Type> is empty")
                vt_ok = False
                continue
            m = _re_vt.match(r'^([A-Za-z][A-Za-z0-9]*):(.+)$', t)
            if not m:
                report_error(f"valueType: type '{t}' has no namespace prefix (expected xs:/v8:/d5p1: — e.g. xs:decimal not decimal)")
                vt_ok = False
                continue
            prefix, local_t = m.group(1), m.group(2)
            if prefix in ('xs', 'v8'):
                if t not in _VALID_TYPE_QUALIFIER:
                    report_error(f"valueType: unknown type '{t}' (allowed: xs:decimal/xs:string/xs:dateTime/xs:boolean/v8:StandardPeriod or <prefix>:*Ref.X)")
                    vt_ok = False
                else:
                    types.append(t)
            else:
                prefix_ns = child.nsmap.get(prefix)
                if prefix_ns == _CONFIG_NS_URI:
                    if not _re_vt.match(r'^[A-Za-z]+(Ref)?\.', local_t):
                        report_error(f"valueType: ref type '{t}' must look like '<prefix>:<Kind>.<Name>' (e.g. d5p1:CatalogRef.X)")
                        vt_ok = False
                    else:
                        types.append('')   # ref — no qualifier needed
                elif prefix_ns == 'http://v8.1c.ru/8.1/data/enterprise':
                    # System types: AccumulationRecordType etc. — no qualifiers
                    if not _re_vt.match(r'^[A-Za-z][A-Za-z0-9]*$', local_t):
                        report_error(f"valueType: system type '{t}' has unexpected local-name shape")
                        vt_ok = False
                    else:
                        types.append('')
                else:
                    report_error(f"valueType: type '{t}' uses prefix '{prefix}' bound to unexpected namespace '{prefix_ns}'")
                    vt_ok = False

        elif local.endswith('Qualifiers'):
            q_name = f"v8:{local}"
            qualifiers.append((q_name, child))
            if q_name == 'v8:NumberQualifiers':
                digits = find(child, "v8:Digits")
                frac   = find(child, "v8:FractionDigits")
                sign   = find(child, "v8:AllowedSign")
                if digits is None or not _re_vt.match(r'^\d+$', text_of(digits)):
                    report_error("v8:NumberQualifiers: <v8:Digits> missing or not a non-negative integer")
                    vt_ok = False
                if frac is None or not _re_vt.match(r'^\d+$', text_of(frac)):
                    report_error("v8:NumberQualifiers: <v8:FractionDigits> missing or not a non-negative integer")
                    vt_ok = False
                if sign is not None and text_of(sign) and text_of(sign) not in _VALID_SIGN:
                    report_error(f"v8:NumberQualifiers: <v8:AllowedSign>{text_of(sign)}</v8:AllowedSign> — must be one of: {', '.join(_VALID_SIGN)}")
                    vt_ok = False
            elif q_name == 'v8:StringQualifiers':
                length = find(child, "v8:Length")
                al     = find(child, "v8:AllowedLength")
                if length is None or not _re_vt.match(r'^\d+$', text_of(length)):
                    report_error("v8:StringQualifiers: <v8:Length> missing or not a non-negative integer")
                    vt_ok = False
                if al is not None and text_of(al) and text_of(al) not in _VALID_LENGTH:
                    report_error(f"v8:StringQualifiers: <v8:AllowedLength>{text_of(al)}</v8:AllowedLength> — must be one of: {', '.join(_VALID_LENGTH)}")
                    vt_ok = False
            elif q_name == 'v8:DateQualifiers':
                df = find(child, "v8:DateFractions")
                if df is not None and text_of(df) and text_of(df) not in _VALID_FRACTIONS:
                    report_error(f"v8:DateQualifiers: <v8:DateFractions>{text_of(df)}</v8:DateFractions> — must be one of: {', '.join(_VALID_FRACTIONS)}")
                    vt_ok = False

    # Cross-check: every qualifier must have a matching scalar type in this valueType
    for q_name, _ in qualifiers:
        producer = _QUALIFIER_PRODUCERS.get(q_name)
        if not producer:
            continue
        if producer not in types:
            report_error(f"valueType: <{q_name}> has no matching <v8:Type>{producer}</v8:Type> in this valueType")
            vt_ok = False

if vt_checked > 0 and vt_ok:
    report_ok(f"{vt_checked} valueType block(s): structure and qualifiers OK")

if stopped:
    finalize()
    sys.exit(1)

# ── 17. value content checks ──────────────────────────────────
# Catches literal placeholders ('_') and empty strings in DesignTimeValue refs
# that XDTO would reject at db-load-xml.

value_nodes = find_all(root, "//s:value[@xsi:type]") + find_all(root, "//dcscor:value[@xsi:type]")
v_checked = 0
v_ok = True
for vn in value_nodes:
    if vn is None:
        continue
    v_checked += 1
    xsi_type = vn.get(XSI_TYPE) or ''
    text = vn.text or ''
    if xsi_type == 'dcscor:DesignTimeValue':
        stripped = text.strip()
        if not stripped or stripped == '_':
            report_error(f"<value xsi:type=\"dcscor:DesignTimeValue\">{text}</value> — DesignTimeValue must be a reference path (e.g. Перечисление.X.Y), not '{text}'")
            v_ok = False
        elif not _re_vt.match(r'^[A-Za-zА-Яа-яЁё]+\.[A-Za-zА-Яа-яЁё0-9_]+', stripped):
            report_warn(f"<value xsi:type=\"dcscor:DesignTimeValue\">{text}</value> — doesn't look like a typical ref path")

if v_checked > 0 and v_ok:
    report_ok(f"{v_checked} <value> element(s) with xsi:type: content OK")

if stopped:
    finalize()
    sys.exit(1)

# ── Final output ──────────────────────────────────────────────

finalize()

if errors > 0:
    sys.exit(1)
sys.exit(0)
