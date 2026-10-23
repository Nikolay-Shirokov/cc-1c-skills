# skd-validate v1.7 — Validate 1C DCS structure (Python port)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import os
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

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


# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-TemplatePath", "-Path", required=True)
parser.add_argument("-Detailed", action="store_true")
parser.add_argument("-MaxErrors", type=int, default=20)
parser.add_argument("-OutFile", default="")
args = ci_parse_args(parser)

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
# Проверка, которая не выполнялась, — в итоговую строку: без этого «Validation OK» читается как
# «проверено всё» (модель так и докладывала пользователю при нарушенном порядке)
xsd_note = None
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
        note = f"; {xsd_note}" if xsd_note else ""
        result = f"=== Validation OK: {file_name} ({checks} checks{note}) ==="
    else:
        out_line("")
        note = f"; {xsd_note}" if xsd_note else ""
        out_line(f"=== Result: {errors} errors, {warnings} warnings ({checks} checks{note}) ===")
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

# Строчную (dataCompositionSchema — имя из XSD, так пишет сериализатор XDTO) платформа загружает,
# но конфигуратор всегда пишет DataCompositionSchema — это предупреждение, не ошибка.
if local_name(root) == "DataCompositionSchema":
    report_ok("Root element: DataCompositionSchema")
elif local_name(root).lower() == "datacompositionschema":
    report_warn(f"Root element is '{local_name(root)}' — the platform loads it, but the Designer writes 'DataCompositionSchema'")
else:
    report_error(f"Root element is '{local_name(root)}', expected 'DataCompositionSchema'")

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
    elif xsi_type == 'xs:boolean' and text.strip() not in ('true', 'false', '1', '0'):
        # Платформа прощает True/False, чтение по схеме (XDTO) — нет
        report_error(f"<value xsi:type=\"xs:boolean\">{text}</value> — boolean must be true or false (lowercase)")
        v_ok = False

if v_checked > 0 and v_ok:
    report_ok(f"{v_checked} <value> element(s) with xsi:type: content OK")

if stopped:
    finalize()
    sys.exit(1)

# ── 18. XSD (schemas of the platform, /v8-xsd-fetch) ──────────
# Порядок элементов, типы и значения — по XSD платформы, если они есть в проекте. Нет схем —
# нет проверки. Схемы XDTO совпадают с выгрузкой конфигуратора только в СКД, и то кроме
# нескольких мест, которые платформа пишет иначе, — они отсекаются ниже (xsd_platform_noise).
import json
import re
import shutil
import tempfile
from pathlib import Path


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


# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Именно корневого: в Form.xml
# расширения ниже стоит <BaseForm version=…>. Читается только заголовок, без разбора файла.
def root_version(xml_path):
    if not os.path.isfile(xml_path):
        return None
    with open(xml_path, "rb") as f:
        head = f.read(4096).decode("utf-8", errors="ignore")
    m = re.search(r'<[A-Za-z_][\w.:-]*(\s[^>]*)?/?>', head)
    if not m:
        return None
    v = re.search(r'(?:^|\s)version="([^"]*)"', m.group(1) or "")
    if v:
        return v.group(1)
    return None


# Корень автономной внешней обработки/отчёта. Копия общего эталона (семья is_external_root,
# авторитет — cf-edit).
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


# Якорь выгрузки, в чьём дереве лежит файл: корень автономной EPF/ERF либо Configuration.xml,
# ближайший вверх. Корень обработки проверяется первым — иначе обработка, лежащая в дереве
# конфигурации, сверялась бы с конфигурацией. Нет якоря — сверять не с чем.
def find_dump_anchor(start_dir):
    d = start_dir
    for _ in range(15):
        if not d:
            break
        if _sg_is_external_root(d + ".xml"):
            return d + ".xml"
        cfg = os.path.join(d, "Configuration.xml")
        if os.path.exists(cfg):
            return cfg
        parent = os.path.dirname(d)
        if not parent or parent == d:
            break
        d = parent
    return None


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


XSD_DCS_NS = "http://v8.1c.ru/8.1/data-composition-system/schema"
XS_NS = "http://www.w3.org/2001/XMLSchema"


def xsd_target_ns(path):
    """targetNamespace схемы — из заголовка файла, без разбора."""
    with open(path, "rb") as f:
        head = f.read(4096).decode("utf-8", errors="ignore")
    m = re.search(r'targetNamespace="([^"]*)"', head)
    return m.group(1) if m else None


def xsd_index(vdir):
    """namespace → файл схемы в каталоге версии."""
    idx = {}
    for name in sorted(os.listdir(vdir)):
        fp = os.path.join(vdir, name)
        if name.lower().endswith(".xsd") and os.path.isfile(fp):
            ns = xsd_target_ns(fp)
            if ns and ns not in idx:
                idx[ns] = fp
    return idx


def resolve_xsd_root(template_dir):
    """Каталог схем: .v8-project.json — сначала от шаблона (проект, которому он принадлежит),
    потом от текущего каталога; xsdPath из него, иначе .v8-xsd рядом с ним. Нет проекта — нет схем."""
    pj = _sg_find_v8project(template_dir) or _sg_find_v8project(os.getcwd())
    if not pj:
        return None
    pj_dir = os.path.dirname(pj)
    rel = ".v8-xsd"
    try:
        with open(pj, encoding="utf-8-sig") as f:
            cfg = json.load(f)
        if isinstance(cfg, dict) and cfg.get("xsdPath"):
            rel = str(cfg["xsdPath"])
    except Exception:
        pass
    d = rel if os.path.isabs(rel) else os.path.join(pj_dir, rel)
    return d if os.path.isdir(d) else None


def xsd_platform_noise(info):
    """Места, которые платформа пишет не так, как описывает XSD, — сверено на всех схемах
    компоновки выгрузок БП и УНФ. Правило — по месту (элемент, родитель, xsi:type), не по тексту:
    текст зависит от движка и языка."""
    e, p = info["elem"], info["parent"]
    if p in ("groupTemplate", "groupHeaderTemplate") and e in ("templateType", "groupName"):
        return True
    if p == "right" and e == "lastId":
        return True
    if p == "nestedSchema" and e == "schema":
        return True
    if info["xsiNs"] == "http://v8.1c.ru/8.2/data/chart":
        return True
    # Пустое выражение параметра макета платформа не пишет, схема требует
    if e == "parameter" and info["xsiLocal"] == "ExpressionAreaTemplateParameter":
        return True
    return False


def _xsd_build_schema(vdir, tmp):
    """Схема для lxml. У import в схемах платформы нет schemaLocation, а libxml2 сам по namespace
    не ищет, — корневая схема импортирует замыкание зависимостей СКД с путями, листья первыми.
    Корень DataCompositionSchema в схеме объявлен как dataCompositionSchema (строчная) — схему
    СКД подключаем через обёртку: xs:include настоящего файла плюс элемент с нужным именем."""
    idx = xsd_index(vdir)
    order, seen = [], set()

    def visit(ns):
        if ns in seen or ns not in idx:
            return
        seen.add(ns)
        doc = etree.parse(idx[ns])
        for imp in doc.getroot().iter("{%s}import" % XS_NS):
            visit(imp.get("namespace"))
        order.append(ns)

    # Сначала замыкание СКД, затем остальные схемы каталога: значения в выгрузке ссылаются через
    # xsi:type на типы, которые схема СКД не импортирует (data/enterprise: LinkedValueChangeMode,
    # FoldersAndItemsUse …) — как и в PS-мастере, где в набор кладутся все схемы.
    visit(XSD_DCS_NS)
    for ns in idx:
        visit(ns)
    dcs_doc = etree.parse(idx[XSD_DCS_NS])
    has_root = any(el.get("name") == "DataCompositionSchema"
                   for el in dcs_doc.getroot().findall("{%s}element" % XS_NS))
    locations = {ns: Path(idx[ns]).as_uri() for ns in order}
    if not has_root:
        wrapper = os.path.join(tmp, "dcs-root.xsd")
        with open(wrapper, "w", encoding="utf-8") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                    '<xs:schema xmlns:xs="%s" xmlns:tns="%s" targetNamespace="%s" elementFormDefault="qualified">\n'
                    '  <xs:include schemaLocation="%s"/>\n'
                    '  <xs:element name="DataCompositionSchema" type="tns:DataCompositionSchema"/>\n'
                    '</xs:schema>\n' % (XS_NS, XSD_DCS_NS, XSD_DCS_NS, locations[XSD_DCS_NS]))
        locations[XSD_DCS_NS] = Path(wrapper).as_uri()
    root = os.path.join(tmp, "root.xsd")
    with open(root, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<xs:schema xmlns:xs="%s" targetNamespace="urn:v8-xsd-root">\n' % XS_NS)
        for ns in order:
            f.write('  <xs:import namespace="%s" schemaLocation="%s"/>\n' % (ns, locations[ns]))
        f.write('</xs:schema>\n')
    return etree.XMLSchema(etree.parse(root))


def _xsd_elem_info(el):
    if el is None or not isinstance(el.tag, str):
        return {"elem": "", "parent": "", "xsiNs": "", "xsiLocal": ""}
    par = el.getparent()
    info = {"elem": etree.QName(el).localname,
            "parent": etree.QName(par).localname if par is not None and isinstance(par.tag, str) else "",
            "xsiNs": "", "xsiLocal": ""}
    xt = el.get(XSI_TYPE)
    if xt:
        pp = xt.split(":")
        info["xsiLocal"] = pp[-1]
        if len(pp) > 1:
            info["xsiNs"] = el.nsmap.get(pp[0]) or ""
    return info


def _xsd_error_element(err):
    """Элемент нарушения по error.path. Путь несёт префиксы документа (dcsset:settings) — xpath
    получает их из корня; префикс, объявленный глубже, не разрешится — тогда ищем по строке и
    имени последнего шага."""
    if not err.path:
        return None
    ns = {k: v for k, v in tree.getroot().nsmap.items() if k}
    try:
        hits = tree.xpath(err.path, namespaces=ns)
        if hits and isinstance(hits[0], etree._Element):
            return hits[0]
    except Exception:
        pass
    last = re.sub(r'\[\d+\]$', '', err.path.rsplit('/', 1)[-1]).split(':')[-1]
    for el in tree.iter():
        if isinstance(el.tag, str) and el.sourceline == err.line and etree.QName(el).localname == last:
            return el
    return None


# ── Подсказка по схеме: что именно исправить ──
# Текст валидатора про порядок («недопустимый дочерний X, ожидается A, B») читается как «добавь A»,
# а означает «X стоит слишком поздно». Поэтому для нарушений порядка строим свою подсказку: тип
# родителя и порядок его детей берём из XSD, сравниваем с соседями нарушителя в документе. Обход
# схемы — свой, по XSD-документам, как в PS-мастере: так подсказки портов совпадают.

def xsd_model(vdir):
    m = {"types": {}, "elems": {}, "orders": {}}
    for name in sorted(os.listdir(vdir)):
        fp = os.path.join(vdir, name)
        if not (name.lower().endswith(".xsd") and os.path.isfile(fp)):
            continue
        root_el = etree.parse(fp).getroot()
        tns = root_el.get("targetNamespace") or ""
        for n in root_el:
            if not isinstance(n.tag, str) or etree.QName(n).namespace != XS_NS or not n.get("name"):
                continue
            key = f"{tns}|{n.get('name')}"
            ln = etree.QName(n).localname
            if ln == "complexType":
                m["types"].setdefault(key, n)
            elif ln == "element":
                m["elems"].setdefault(key, n)
    return m


def xsd_resolve_qname(node, qn):
    """QName из атрибута схемы → "ns|имя" по пространствам имён узла XSD."""
    if not qn:
        return None
    pp = qn.split(":")
    prefix = pp[0] if len(pp) > 1 else None
    return f"{node.nsmap.get(prefix) or ''}|{pp[-1]}"


def xsd_child_order(model, type_key):
    """Дети типа по порядку: {name, type, maxOne}. База расширения — первой. Порядок не определён
    (choice, all, any, group) или тип неизвестен — None."""
    if not type_key:
        return None
    if type_key in model["orders"]:
        return model["orders"][type_key]
    model["orders"][type_key] = None   # защита от циклов
    ct = model["types"].get(type_key)
    if ct is None:
        return None
    lst = []
    holder = ct
    for c in ct:
        if not isinstance(c.tag, str):
            continue
        ln = etree.QName(c).localname
        if ln == "simpleContent":
            model["orders"][type_key] = lst
            return lst
        if ln == "complexContent":
            ext = None
            for x in c:
                if isinstance(x.tag, str) and etree.QName(x).localname == "extension":
                    ext = x
            if ext is None:
                return None
            base_key = xsd_resolve_qname(ext, ext.get("base"))
            base = xsd_child_order(model, base_key)
            # База известна, но порядок у неё не определён — не определён и здесь
            if base is None and base_key in model["types"]:
                return None
            if base:
                lst.extend(base)
            holder = ext
    for c in holder:
        if not isinstance(c.tag, str):
            continue
        ln = etree.QName(c).localname
        if ln == "sequence":
            if not _xsd_add_sequence(model, c, lst):
                return None
        elif ln in ("choice", "all", "group", "any"):
            return None
    model["orders"][type_key] = lst
    return lst


def _xsd_add_sequence(model, seq, lst):
    for c in seq:
        if not isinstance(c.tag, str):
            continue
        ln = etree.QName(c).localname
        if ln == "element":
            ref = c.get("ref")
            if ref:
                rk = xsd_resolve_qname(c, ref)
                ge = model["elems"].get(rk)
                name = rk.split("|")[-1]
                typ = xsd_resolve_qname(ge, ge.get("type")) if ge is not None and ge.get("type") else None
            else:
                name = c.get("name")
                typ = xsd_resolve_qname(c, c.get("type")) if c.get("type") else None
            mx = c.get("maxOccurs")
            lst.append({"name": name, "type": typ, "maxOne": (not mx or mx == "1")})
        elif ln == "sequence":
            if not _xsd_add_sequence(model, c, lst):
                return False
        elif ln == "annotation":
            continue
        else:
            return False
    return True


def _xsd_ancestor(el):
    """Предок для спуска по схеме: {name, ns, xsiKey}."""
    q = etree.QName(el)
    e = {"name": q.localname, "ns": q.namespace or "", "xsiKey": None}
    xt = el.get(XSI_TYPE)
    if xt:
        pp = xt.split(":")
        prefix = pp[0] if len(pp) > 1 else None
        e["xsiKey"] = f"{el.nsmap.get(prefix) or ''}|{pp[-1]}"
    return e


def xsd_parent_type(model, ancestors):
    """Тип родителя нарушителя: спуск от корня по цепочке предков."""
    if not ancestors:
        return None
    root = ancestors[0]
    rk = f"{root['ns']}|{root['name']}"
    if root["xsiKey"]:
        typ = root["xsiKey"]
    elif rk in model["elems"] and model["elems"][rk].get("type"):
        typ = xsd_resolve_qname(model["elems"][rk], model["elems"][rk].get("type"))
    elif rk in model["types"]:
        typ = rk
    else:
        return None
    for a in ancestors[1:]:
        if a["xsiKey"]:
            typ = a["xsiKey"]
            continue
        order = xsd_child_order(model, typ)
        if order is None:
            return None
        hit = next((o for o in order if o["name"] == a["name"]), None)
        if hit is None or not hit["type"]:
            return None
        typ = hit["type"]
    return typ


def xsd_order_hint(model, ancestors, name, preceding):
    order = xsd_child_order(model, xsd_parent_type(model, ancestors))
    if order is None:
        return None
    names = [o["name"] for o in order]
    if name not in names:
        return f"not allowed in <{ancestors[-1]['name']}>"
    idx = names.index(name)
    if order[idx]["maxOne"] and name in preceding:
        return f"duplicate — only one <{name}> allowed"
    for sib in preceding:
        if sib in names and names.index(sib) > idx:
            return f"must come before <{sib}>"
    return None


def compress_xsd_message(m):
    """Текст валидатора без пространств имён: остаются имена и значения."""
    m = re.sub(r'[\r\n]+', ' ', m)
    m = re.sub(r'\s(в пространстве имен|in namespace)\s"[^"]*"', '', m)
    m = re.sub(r"\s(в пространстве имен|in namespace)\s'[^']*'", '', m)
    m = re.sub(r'\{[^}]*\}', '', m)
    m = re.sub(r'(["\'])https?://[^"\']*:', r'\1', m)
    return ' '.join(m.split())


def xsd_check():
    xsd_root = resolve_xsd_root(os.path.dirname(resolved_path))
    global xsd_note
    if not xsd_root:
        xsd_note = "XSD not checked: no schemas (/v8-xsd-fetch)"
        return
    anchor = find_dump_anchor(os.path.dirname(resolved_path))
    ver = root_version(anchor) if anchor else None
    if not ver or format_rank(ver) == 0:
        xsd_note = "XSD not checked: template outside a dump"
        return

    # Точная версия — ошибки; ближайшая более новая — предупреждения; только старше — пропуск
    cands = sorted((d for d in os.listdir(xsd_root)
                    if re.match(r'^\d+\.\d+$', d) and os.path.isdir(os.path.join(xsd_root, d))
                    and format_rank(d) >= format_rank(ver)), key=format_rank)
    cands = [d for d in cands if XSD_DCS_NS in xsd_index(os.path.join(xsd_root, d))]
    if not cands:
        report_warn(f"XSD: no schemas for format {ver} in '{xsd_root}' — not checked")
        return
    use_ver = cands[0]
    exact = use_ver == ver

    tmp = tempfile.mkdtemp(prefix="skd-xsd-")
    try:
        try:
            schema = _xsd_build_schema(os.path.join(xsd_root, use_ver), tmp)
            # Модель — после компиляции, как в PS-мастере: битый .xsd даёт предупреждение, а не трейсбэк
            model = xsd_model(os.path.join(xsd_root, use_ver))
        except Exception as ex:
            report_warn(f"XSD: schemas in '{os.path.join(xsd_root, use_ver)}' do not compile — not checked: {ex}")
            return
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    tag = f"XSD {use_ver}" if exact else f"XSD {use_ver} (no schemas for {ver})"
    schema.validate(tree)
    found = 0
    for err in schema.error_log:
        if stopped:
            break
        el = _xsd_error_element(err)
        info = _xsd_elem_info(el)
        if xsd_platform_noise(info):
            continue
        # Недопустимое булево значение уже сообщила собственная проверка значений (раздел 17)
        if info["elem"] == "value" and info["xsiNs"] == XS_NS and info["xsiLocal"] == "boolean":
            continue
        found += 1
        hint = None
        # «Лишний/не на месте» у libxml2 — «This element is not expected» (текст не локализуется)
        if el is not None and "This element is not expected" in err.message:
            ancestors = [_xsd_ancestor(a) for a in reversed(list(el.iterancestors()))]
            preceding = [etree.QName(x).localname for x in reversed(list(el.itersiblings(preceding=True)))
                         if isinstance(x.tag, str)]
            hint = xsd_order_hint(model, ancestors, etree.QName(el).localname, preceding)
        text = hint or compress_xsd_message(err.message)
        msg = f"{tag}, line {err.line}: {info['parent']}/{info['elem']}: {text}"
        if exact:
            report_error(msg)
        else:
            report_warn(msg)
    if found == 0:
        report_ok(f"{tag}: order, types and values OK")


xsd_check()

if stopped:
    finalize()
    sys.exit(1)

# ── Final output ──────────────────────────────────────────────

finalize()

if errors > 0:
    sys.exit(1)
sys.exit(0)
