#!/usr/bin/env python3
# stub-db-create v1.0 — Create temp 1C infobase with metadata stubs for EPF/ERF build
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import random
import re
import subprocess
import sys
import tempfile
import uuid


def new_uuid():
    return str(uuid.uuid4())


def scan_ref_types(source_dir):
    """Scan XML files for reference/object/recordset types. Returns {metaType: {name: True}}."""
    type_map = {}

    ref_pattern = re.compile(
        r'(?:cfg:|d\dp1:)(CatalogRef|DocumentRef|EnumRef|ChartOfAccountsRef'
        r'|ChartOfCharacteristicTypesRef|ChartOfCalculationTypesRef'
        r'|ExchangePlanRef|BusinessProcessRef|TaskRef)'
        r'\.([A-Za-z\u0400-\u04FF\d_]+)'
    )
    obj_pattern = re.compile(
        r'(?:cfg:|d\dp1:)(CatalogObject|DocumentObject|ChartOfAccountsObject'
        r'|ChartOfCharacteristicTypesObject|ChartOfCalculationTypesObject'
        r'|ExchangePlanObject|BusinessProcessObject|TaskObject)'
        r'\.([A-Za-z\u0400-\u04FF\d_]+)'
    )
    rs_pattern = re.compile(
        r'(?:cfg:|d\dp1:)(InformationRegisterRecordSet|AccumulationRegisterRecordSet'
        r'|AccountingRegisterRecordSet|CalculationRegisterRecordSet)'
        r'\.([A-Za-z\u0400-\u04FF\d_]+)'
    )
    char_pattern = re.compile(r'cfg:Characteristic\.([A-Za-z\u0400-\u04FF\d_]+)')
    dt_pattern = re.compile(r'cfg:DefinedType\.([A-Za-z\u0400-\u04FF\d_]+)')

    ref_map = {
        'CatalogRef': 'Catalog', 'DocumentRef': 'Document', 'EnumRef': 'Enum',
        'ChartOfAccountsRef': 'ChartOfAccounts',
        'ChartOfCharacteristicTypesRef': 'ChartOfCharacteristicTypes',
        'ChartOfCalculationTypesRef': 'ChartOfCalculationTypes',
        'ExchangePlanRef': 'ExchangePlan', 'BusinessProcessRef': 'BusinessProcess', 'TaskRef': 'Task',
    }
    obj_map = {
        'CatalogObject': 'Catalog', 'DocumentObject': 'Document',
        'ChartOfAccountsObject': 'ChartOfAccounts',
        'ChartOfCharacteristicTypesObject': 'ChartOfCharacteristicTypes',
        'ChartOfCalculationTypesObject': 'ChartOfCalculationTypes',
        'ExchangePlanObject': 'ExchangePlan', 'BusinessProcessObject': 'BusinessProcess', 'TaskObject': 'Task',
    }
    rs_map = {
        'InformationRegisterRecordSet': 'InformationRegister',
        'AccumulationRegisterRecordSet': 'AccumulationRegister',
        'AccountingRegisterRecordSet': 'AccountingRegister',
        'CalculationRegisterRecordSet': 'CalculationRegister',
    }

    for dirpath, _, filenames in os.walk(source_dir):
        for fn in filenames:
            if not fn.endswith('.xml'):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, 'r', encoding='utf-8-sig') as f:
                    content = f.read()
            except Exception:
                continue

            for m in ref_pattern.finditer(content):
                mt = ref_map[m.group(1)]
                type_map.setdefault(mt, {})[m.group(2)] = True
            for m in obj_pattern.finditer(content):
                mt = obj_map[m.group(1)]
                type_map.setdefault(mt, {})[m.group(2)] = True
            for m in rs_pattern.finditer(content):
                mt = rs_map[m.group(1)]
                type_map.setdefault(mt, {})[m.group(2)] = True
            for m in char_pattern.finditer(content):
                type_map.setdefault('ChartOfCharacteristicTypes', {})[m.group(1)] = True
            for m in dt_pattern.finditer(content):
                type_map.setdefault('DefinedType', {})[m.group(1)] = True

    return type_map


def scan_register_columns(source_dir):
    """Scan Form.xml for register record set columns referenced via DataPath.
    Returns {"RegisterType.RegisterName": {"col1": True, "col2": True}}."""
    import xml.etree.ElementTree as ET

    register_columns = {}
    std_cols = {'LineNumber', 'Period', 'Recorder', 'Active', 'RecordType'}
    rs_type_map = {
        'InformationRegisterRecordSet': 'InformationRegister',
        'AccumulationRegisterRecordSet': 'AccumulationRegister',
        'AccountingRegisterRecordSet': 'AccountingRegister',
        'CalculationRegisterRecordSet': 'CalculationRegister',
    }
    rs_pattern = re.compile(
        r'^(?:cfg:|d\dp1:)(InformationRegisterRecordSet|AccumulationRegisterRecordSet'
        r'|AccountingRegisterRecordSet|CalculationRegisterRecordSet)\.(.+)$'
    )
    dp_pattern = re.compile(r'<DataPath>([A-Za-z\u0400-\u04FF\d_]+)\.([A-Za-z\u0400-\u04FF\d_]+)</DataPath>')

    ns = {
        'v8': 'http://v8.1c.ru/8.1/data/core',
        'f': 'http://v8.1c.ru/8.3/xcf/logform',
    }

    for dirpath, _, filenames in os.walk(source_dir):
        for fn in filenames:
            if fn != 'Form.xml':
                continue
            fp = os.path.join(dirpath, fn)
            try:
                with open(fp, 'r', encoding='utf-8-sig') as fh:
                    content = fh.read()
            except Exception:
                continue
            if '<Attributes>' not in content:
                continue

            # Parse form attributes to find register recordset types
            reg_attr_map = {}  # formAttrName -> "RegisterType.RegisterName"
            try:
                root = ET.fromstring(content)
                for attr_node in root.iter('{http://v8.1c.ru/8.3/xcf/logform}Attribute'):
                    attr_name = attr_node.get('name', '')
                    for type_node in attr_node.iter('{http://v8.1c.ru/8.1/data/core}Type'):
                        m = rs_pattern.match(type_node.text or '')
                        if m:
                            reg_type = rs_type_map[m.group(1)]
                            reg_key = f"{reg_type}.{m.group(2)}"
                            reg_attr_map[attr_name] = reg_key
                            register_columns.setdefault(reg_key, {})
            except Exception:
                continue

            # Find DataPath references like "AttrName.ColumnName"
            for m in dp_pattern.finditer(content):
                attr_name, col_name = m.group(1), m.group(2)
                if attr_name in reg_attr_map and col_name not in std_cols:
                    register_columns[reg_attr_map[attr_name]][col_name] = True

    return register_columns


NS = (
    'xmlns="http://v8.1c.ru/8.3/MDClasses" xmlns:app="http://v8.1c.ru/8.2/managed-application/core" '
    'xmlns:cfg="http://v8.1c.ru/8.1/data/enterprise/current-config" '
    'xmlns:cmi="http://v8.1c.ru/8.2/managed-application/cmi" '
    'xmlns:ent="http://v8.1c.ru/8.1/data/enterprise" '
    'xmlns:lf="http://v8.1c.ru/8.2/managed-application/logform" '
    'xmlns:style="http://v8.1c.ru/8.1/data/ui/style" '
    'xmlns:sys="http://v8.1c.ru/8.1/data/ui/fonts/system" '
    'xmlns:v8="http://v8.1c.ru/8.1/data/core" '
    'xmlns:v8ui="http://v8.1c.ru/8.1/data/ui" '
    'xmlns:web="http://v8.1c.ru/8.1/data/ui/colors/web" '
    'xmlns:win="http://v8.1c.ru/8.1/data/ui/colors/windows" '
    'xmlns:xen="http://v8.1c.ru/8.3/xcf/enums" '
    'xmlns:xpr="http://v8.1c.ru/8.3/xcf/predef" '
    'xmlns:xr="http://v8.1c.ru/8.3/xcf/readable" '
    'xmlns:xs="http://www.w3.org/2001/XMLSchema" '
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="2.17"'
)

CLASS_IDS = [
    "9cd510cd-abfc-11d4-9434-004095e12fc7",
    "9fcd25a0-4822-11d4-9414-008048da11f9",
    "e3687481-0a87-462c-a166-9f34594f9bba",
    "9de14907-ec23-4a07-96f0-85521cb6b53b",
    "51f2d5d8-ea4d-4064-8892-82951750031e",
    "e68182ea-4237-4383-967f-90c1e3370bc7",
    "fb282519-d103-4dd3-bc12-cb271d631dfc",
]

GT_DEFS = {
    'Catalog': [('CatalogObject','Object'),('CatalogRef','Ref'),('CatalogSelection','Selection'),('CatalogList','List'),('CatalogManager','Manager')],
    'Document': [('DocumentObject','Object'),('DocumentRef','Ref'),('DocumentSelection','Selection'),('DocumentList','List'),('DocumentManager','Manager')],
    'Enum': [('EnumRef','Ref'),('EnumManager','Manager'),('EnumList','List')],
    'ChartOfAccounts': [('ChartOfAccountsObject','Object'),('ChartOfAccountsRef','Ref'),('ChartOfAccountsSelection','Selection'),('ChartOfAccountsList','List'),('ChartOfAccountsManager','Manager')],
    'ChartOfCharacteristicTypes': [('ChartOfCharacteristicTypesObject','Object'),('ChartOfCharacteristicTypesRef','Ref'),('ChartOfCharacteristicTypesSelection','Selection'),('ChartOfCharacteristicTypesList','List'),('Characteristic','Characteristic'),('ChartOfCharacteristicTypesManager','Manager')],
    'ChartOfCalculationTypes': [('ChartOfCalculationTypesObject','Object'),('ChartOfCalculationTypesRef','Ref'),('ChartOfCalculationTypesSelection','Selection'),('ChartOfCalculationTypesList','List'),('ChartOfCalculationTypesManager','Manager')],
    'ExchangePlan': [('ExchangePlanObject','Object'),('ExchangePlanRef','Ref'),('ExchangePlanSelection','Selection'),('ExchangePlanList','List'),('ExchangePlanManager','Manager')],
    'BusinessProcess': [('BusinessProcessObject','Object'),('BusinessProcessRef','Ref'),('BusinessProcessSelection','Selection'),('BusinessProcessList','List'),('BusinessProcessManager','Manager')],
    'Task': [('TaskObject','Object'),('TaskRef','Ref'),('TaskSelection','Selection'),('TaskList','List'),('TaskManager','Manager')],
    'InformationRegister': [('InformationRegisterRecord','Record'),('InformationRegisterManager','Manager'),('InformationRegisterSelection','Selection'),('InformationRegisterList','List'),('InformationRegisterRecordSet','RecordSet'),('InformationRegisterRecordKey','RecordKey'),('InformationRegisterRecordManager','RecordManager')],
    'AccumulationRegister': [('AccumulationRegisterRecord','Record'),('AccumulationRegisterManager','Manager'),('AccumulationRegisterSelection','Selection'),('AccumulationRegisterList','List'),('AccumulationRegisterRecordSet','RecordSet'),('AccumulationRegisterRecordKey','RecordKey')],
    'AccountingRegister': [('AccountingRegisterRecord','Record'),('AccountingRegisterManager','Manager'),('AccountingRegisterSelection','Selection'),('AccountingRegisterExtDimensions','ExtDimensions'),('AccountingRegisterList','List'),('AccountingRegisterRecordSet','RecordSet'),('AccountingRegisterRecordKey','RecordKey')],
    'CalculationRegister': [('CalculationRegisterRecord','Record'),('CalculationRegisterManager','Manager'),('CalculationRegisterSelection','Selection'),('CalculationRegisterList','List'),('CalculationRegisterRecordSet','RecordSet'),('CalculationRegisterRecordKey','RecordKey')],
    'DefinedType': [('DefinedType','DefinedType')],
}

META_INFO = {
    'Catalog': ('Catalog', 'Catalogs'),
    'Document': ('Document', 'Documents'),
    'Enum': ('Enum', 'Enums'),
    'ChartOfAccounts': ('ChartOfAccounts', 'ChartsOfAccounts'),
    'ChartOfCharacteristicTypes': ('ChartOfCharacteristicTypes', 'ChartsOfCharacteristicTypes'),
    'ChartOfCalculationTypes': ('ChartOfCalculationTypes', 'ChartsOfCalculationTypes'),
    'ExchangePlan': ('ExchangePlan', 'ExchangePlans'),
    'BusinessProcess': ('BusinessProcess', 'BusinessProcesses'),
    'Task': ('Task', 'Tasks'),
    'InformationRegister': ('InformationRegister', 'InformationRegisters'),
    'AccumulationRegister': ('AccumulationRegister', 'AccumulationRegisters'),
    'AccountingRegister': ('AccountingRegister', 'AccountingRegisters'),
    'CalculationRegister': ('CalculationRegister', 'CalculationRegisters'),
    'DefinedType': ('DefinedType', 'DefinedTypes'),
}

STD_ATTRS_BY_TYPE = {
    'Catalog': ['PredefinedDataName','Predefined','Ref','DeletionMark','IsFolder','Owner','Parent','Description','Code'],
    'Document': ['Posted','Ref','DeletionMark','Date','Number'],
    'Enum': ['Order','Ref'],
    'ChartOfAccounts': ['PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','Parent','Order','Type','OffBalance'],
    'ChartOfCharacteristicTypes': ['PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','Parent','ValueType'],
    'ChartOfCalculationTypes': ['PredefinedDataName','Predefined','Ref','DeletionMark','Description','Code','ActionPeriodIsBasic'],
    'ExchangePlan': ['Ref','DeletionMark','Code','Description','ThisNode','SentNo','ReceivedNo'],
    'BusinessProcess': ['Ref','DeletionMark','Date','Number','Started','Completed','HeadTask'],
    'Task': ['Ref','DeletionMark','Date','Number','Executed','Description','RoutePoint','BusinessProcess'],
    'InformationRegister': ['Active','LineNumber','Recorder','Period'],
    'AccumulationRegister': ['Active','LineNumber','Recorder','Period'],
    'AccountingRegister': ['Active','Period','Recorder','LineNumber','Account'],
    'CalculationRegister': ['Active','Recorder','LineNumber','RegistrationPeriod','CalculationType','ReversingEntry'],
}

STD_ATTR_BODY = """\t\t\t\t<xr:LinkByType/>
\t\t\t\t<xr:FillChecking>DontCheck</xr:FillChecking>
\t\t\t\t<xr:MultiLine>false</xr:MultiLine>
\t\t\t\t<xr:FillFromFillingValue>false</xr:FillFromFillingValue>
\t\t\t\t<xr:CreateOnInput>Auto</xr:CreateOnInput>
\t\t\t\t<xr:MaxValue xsi:nil="true"/>
\t\t\t\t<xr:ToolTip/>
\t\t\t\t<xr:ExtendedEdit>false</xr:ExtendedEdit>
\t\t\t\t<xr:Format/>
\t\t\t\t<xr:ChoiceForm/>
\t\t\t\t<xr:QuickChoice>Auto</xr:QuickChoice>
\t\t\t\t<xr:ChoiceHistoryOnInput>Auto</xr:ChoiceHistoryOnInput>
\t\t\t\t<xr:EditFormat/>
\t\t\t\t<xr:PasswordMode>false</xr:PasswordMode>
\t\t\t\t<xr:DataHistory>Use</xr:DataHistory>
\t\t\t\t<xr:MarkNegatives>false</xr:MarkNegatives>
\t\t\t\t<xr:MinValue xsi:nil="true"/>
\t\t\t\t<xr:Synonym/>
\t\t\t\t<xr:Comment/>
\t\t\t\t<xr:FullTextSearch>Use</xr:FullTextSearch>
\t\t\t\t<xr:ChoiceParameterLinks/>
\t\t\t\t<xr:FillValue xsi:nil="true"/>
\t\t\t\t<xr:Mask/>
\t\t\t\t<xr:ChoiceParameters/>"""


def build_std_attrs(meta_type):
    attrs = STD_ATTRS_BY_TYPE.get(meta_type)
    if not attrs:
        return ''
    lines = ['\t\t\t<StandardAttributes>']
    for a in attrs:
        lines.append(f'\t\t\t\t<xr:StandardAttribute name="{a}">')
        lines.append(STD_ATTR_BODY)
        lines.append(f'\t\t\t\t</xr:StandardAttribute>')
    lines.append('\t\t\t</StandardAttributes>')
    return '\n'.join(lines) + '\n'


def build_internal_info(meta_type, obj_name):
    gts = GT_DEFS.get(meta_type)
    if not gts:
        return ''
    lines = ['\t\t<InternalInfo>']
    if meta_type == 'ExchangePlan':
        lines.append(f'\t\t\t<xr:ThisNode>{new_uuid()}</xr:ThisNode>')
    for prefix, cat in gts:
        full = f'{prefix}.{obj_name}'
        lines.append(f'\t\t\t<xr:GeneratedType name="{full}" category="{cat}">')
        lines.append(f'\t\t\t\t<xr:TypeId>{new_uuid()}</xr:TypeId>')
        lines.append(f'\t\t\t\t<xr:ValueId>{new_uuid()}</xr:ValueId>')
        lines.append(f'\t\t\t</xr:GeneratedType>')
    lines.append('\t\t</InternalInfo>')
    return '\n'.join(lines)


# Properties templates per type — returns the Properties content (without <Properties> tags)
PROPS = {}

PROPS['Catalog'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<Hierarchical>false</Hierarchical>
\t\t\t<HierarchyType>HierarchyFoldersAndItems</HierarchyType>
\t\t\t<LimitLevelCount>false</LimitLevelCount>
\t\t\t<LevelCount>2</LevelCount>
\t\t\t<FoldersOnTop>true</FoldersOnTop>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Owners/>
\t\t\t<SubordinationUse>ToItems</SubordinationUse>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CodeType>String</CodeType>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
\t\t\t<CodeSeries>WholeCatalog</CodeSeries>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultFolderForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<DefaultFolderChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryFolderForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<AuxiliaryFolderChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['Enum'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
{sa}\t\t\t<Characteristics/>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>"""

PROPS['InformationRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<DefaultRecordForm/>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryRecordForm/>
\t\t\t<AuxiliaryListForm/>
{sa}\t\t\t<InformationRegisterPeriodicity>Nonperiodical</InformationRegisterPeriodicity>
\t\t\t<WriteMode>Independent</WriteMode>
\t\t\t<MainFilterOnPeriod>false</MainFilterOnPeriod>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<EnableTotalsSliceFirst>false</EnableTotalsSliceFirst>
\t\t\t<EnableTotalsSliceLast>false</EnableTotalsSliceLast>
\t\t\t<RecordPresentation/>
\t\t\t<ExtendedRecordPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['AccumulationRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<RegisterType>Balance</RegisterType>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
{sa}\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<EnableTotalsSplitting>true</EnableTotalsSplitting>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>"""

PROPS['AccountingRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<ChartOfAccounts/>
\t\t\t<Correspondence>false</Correspondence>
{sa}\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<EnableTotalsSplitting>true</EnableTotalsSplitting>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>"""

PROPS['CalculationRegister'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<DefaultListForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<ChartOfCalculationTypes/>
{sa}\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>"""

PROPS['ChartOfAccounts'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeMask/>
\t\t\t<CodeLength>20</CodeLength>
\t\t\t<DescriptionLength>100</DescriptionLength>
\t\t\t<CodeSeries>WholeCatalog</CodeSeries>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<DefaultFolderForm/>
\t\t\t<DefaultFolderChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<AuxiliaryFolderForm/>
\t\t\t<AuxiliaryFolderChoiceForm/>
\t\t\t<AutoOrderByCode>true</AutoOrderByCode>
\t\t\t<OrderLength>5</OrderLength>
\t\t\t<MaxExtDimensionCount>0</MaxExtDimensionCount>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['ChartOfCharacteristicTypes'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
\t\t\t<CharacteristicExtValues/>
\t\t\t<Type>
\t\t\t\t<v8:Type>xs:boolean</v8:Type>
\t\t\t\t<v8:Type>xs:string</v8:Type>
\t\t\t\t<v8:StringQualifiers>
\t\t\t\t\t<v8:Length>0</v8:Length>
\t\t\t\t\t<v8:AllowedLength>Variable</v8:AllowedLength>
\t\t\t\t</v8:StringQualifiers>
\t\t\t\t<v8:Type>xs:decimal</v8:Type>
\t\t\t\t<v8:NumberQualifiers>
\t\t\t\t\t<v8:Digits>15</v8:Digits>
\t\t\t\t\t<v8:FractionDigits>2</v8:FractionDigits>
\t\t\t\t\t<v8:AllowedSign>Any</v8:AllowedSign>
\t\t\t\t</v8:NumberQualifiers>
\t\t\t\t<v8:Type>xs:dateTime</v8:Type>
\t\t\t\t<v8:DateQualifiers>
\t\t\t\t\t<v8:DateFractions>DateTime</v8:DateFractions>
\t\t\t\t</v8:DateQualifiers>
\t\t\t</Type>
\t\t\t<Hierarchical>false</Hierarchical>
\t\t\t<FoldersOnTop>true</FoldersOnTop>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultFolderForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<DefaultFolderChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryFolderForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<AuxiliaryFolderChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['ChartOfCalculationTypes'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CodeType>String</CodeType>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
\t\t\t<CodeSeries>WholeCatalog</CodeSeries>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
{sa}\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DependenceOnCalculationTypes>NotDepend</DependenceOnCalculationTypes>
\t\t\t<BaseCalculationTypes/>
\t\t\t<ActionPeriodUse>false</ActionPeriodUse>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['ExchangePlan'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<CodeLength>9</CodeLength>
\t\t\t<DescriptionLength>25</DescriptionLength>
\t\t\t<CodeAllowedLength>Variable</CodeAllowedLength>
{sa}\t\t\t<DefaultPresentation>AsDescription</DefaultPresentation>
\t\t\t<Characteristics/>
\t\t\t<PredefinedDataUpdate>Auto</PredefinedDataUpdate>
\t\t\t<EditType>InDialog</EditType>
\t\t\t<QuickChoice>true</QuickChoice>
\t\t\t<ChoiceMode>BothWays</ChoiceMode>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DistributedInfoBase>false</DistributedInfoBase>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['BusinessProcess'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Numerator/>
\t\t\t<NumberType>String</NumberType>
\t\t\t<NumberLength>11</NumberLength>
\t\t\t<NumberAllowedLength>Variable</NumberAllowedLength>
\t\t\t<NumberPeriodicity>Year</NumberPeriodicity>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
{sa}\t\t\t<Characteristics/>
\t\t\t<Task/>
\t\t\t<CreateTaskInPrivilegedMode>false</CreateTaskInPrivilegedMode>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['Task'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Numerator/>
\t\t\t<NumberType>String</NumberType>
\t\t\t<NumberLength>11</NumberLength>
\t\t\t<NumberAllowedLength>Variable</NumberAllowedLength>
\t\t\t<NumberPeriodicity>Year</NumberPeriodicity>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
\t\t\t<DescriptionLength>25</DescriptionLength>
{sa}\t\t\t<Characteristics/>
\t\t\t<InputByString/>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<BasedOn/>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<Addressing/>
\t\t\t<MainAddressingAttribute/>
\t\t\t<CurrentUserAlias/>
\t\t\t<CurrentUserValue/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""

PROPS['DefinedType'] = lambda n, sa: f"""\t\t\t<Name>{n}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<Type>
\t\t\t\t<v8:Type>xs:string</v8:Type>
\t\t\t\t<v8:StringQualifiers>
\t\t\t\t\t<v8:Length>0</v8:Length>
\t\t\t\t\t<v8:AllowedLength>Variable</v8:AllowedLength>
\t\t\t\t</v8:StringQualifiers>
\t\t\t</Type>"""


def build_doc_props(obj_name, std_attrs, reg_records_xml):
    return f"""\t\t\t<Name>{obj_name}</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<UseStandardCommands>false</UseStandardCommands>
\t\t\t<Numerator/>
\t\t\t<NumberType>String</NumberType>
\t\t\t<NumberLength>11</NumberLength>
\t\t\t<NumberAllowedLength>Variable</NumberAllowedLength>
\t\t\t<NumberPeriodicity>Year</NumberPeriodicity>
\t\t\t<CheckUnique>false</CheckUnique>
\t\t\t<Autonumbering>true</Autonumbering>
{std_attrs}\t\t\t<Characteristics/>
\t\t\t<BasedOn/>
\t\t\t<InputByString/>
\t\t\t<CreateOnInput>DontUse</CreateOnInput>
\t\t\t<SearchStringModeOnInputByString>Begin</SearchStringModeOnInputByString>
\t\t\t<FullTextSearchOnInputByString>DontUse</FullTextSearchOnInputByString>
\t\t\t<ChoiceDataGetModeOnInputByString>Directly</ChoiceDataGetModeOnInputByString>
\t\t\t<DefaultObjectForm/>
\t\t\t<DefaultListForm/>
\t\t\t<DefaultChoiceForm/>
\t\t\t<AuxiliaryObjectForm/>
\t\t\t<AuxiliaryListForm/>
\t\t\t<AuxiliaryChoiceForm/>
\t\t\t<Posting>Allow</Posting>
\t\t\t<RealTimePosting>Deny</RealTimePosting>
\t\t\t<RegisterRecordsDeletion>AutoDelete</RegisterRecordsDeletion>
\t\t\t<RegisterRecordsWritingOnPost>WriteModified</RegisterRecordsWritingOnPost>
\t\t\t<SequenceFilling>AutoFill</SequenceFilling>
\t\t\t{reg_records_xml}
\t\t\t<PostInPrivilegedMode>true</PostInPrivilegedMode>
\t\t\t<UnpostInPrivilegedMode>true</UnpostInPrivilegedMode>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<DataLockFields/>
\t\t\t<DataLockControlMode>Automatic</DataLockControlMode>
\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t<ObjectPresentation/>
\t\t\t<ExtendedObjectPresentation/>
\t\t\t<ListPresentation/>
\t\t\t<ExtendedListPresentation/>
\t\t\t<Explanation/>
\t\t\t<ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t<DataHistory>DontUse</DataHistory>
\t\t\t<UpdateDataHistoryImmediatelyAfterWrite>false</UpdateDataHistoryImmediatelyAfterWrite>
\t\t\t<ExecuteAfterWriteDataHistoryVersionProcessing>false</ExecuteAfterWriteDataHistoryVersionProcessing>"""


def write_bom(path, content):
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')

    parser = argparse.ArgumentParser(description='Create temp 1C infobase with metadata stubs')
    parser.add_argument('-SourceDir', required=True)
    parser.add_argument('-V8Path', required=True)
    parser.add_argument('-TempBasePath', default='')
    args = parser.parse_args()

    type_map = scan_ref_types(args.SourceDir)
    register_columns = scan_register_columns(args.SourceDir)
    has_ref_types = len(type_map) > 0

    temp_base = args.TempBasePath or os.path.join(tempfile.gettempdir(), f'epf_stub_db_{random.randint(0,999999)}')

    # Add registrator stub document if needed
    registrator_types = ['AccumulationRegister', 'AccountingRegister', 'CalculationRegister']
    needs_registrator = any(rt in type_map and len(type_map[rt]) > 0 for rt in registrator_types)
    if needs_registrator:
        type_map.setdefault('Document', {})['\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430'] = True  # ЗаглушкаРегистратора

    if has_ref_types:
        cfg_dir = os.path.join(temp_base, 'cfg')
        os.makedirs(cfg_dir, exist_ok=True)

        # Configuration.xml
        uuid_cfg = new_uuid()
        uuid_lang = new_uuid()
        co_ids = [new_uuid() for _ in range(7)]

        co_xml = ''
        for i in range(7):
            co_xml += f'\n\t\t\t<xr:ContainedObject>\n\t\t\t\t<xr:ClassId>{CLASS_IDS[i]}</xr:ClassId>\n\t\t\t\t<xr:ObjectId>{co_ids[i]}</xr:ObjectId>\n\t\t\t</xr:ContainedObject>'

        child_xml = '\n\t\t\t<Language>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</Language>'  # Русский
        for meta_type, names in type_map.items():
            if meta_type not in META_INFO:
                continue
            tag = META_INFO[meta_type][0]
            for name in names:
                child_xml += f'\n\t\t\t<{tag}>{name}</{tag}>'

        cfg_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {NS}>
\t<Configuration uuid="{uuid_cfg}">
\t\t<InternalInfo>{co_xml}
\t\t</InternalInfo>
\t\t<Properties>
\t\t\t<Name>StubConfig</Name>
\t\t\t<Synonym/>
\t\t\t<Comment/>
\t\t\t<NamePrefix/>
\t\t\t<ConfigurationExtensionCompatibilityMode>Version8_3_24</ConfigurationExtensionCompatibilityMode>
\t\t\t<DefaultRunMode>ManagedApplication</DefaultRunMode>
\t\t\t<UsePurposes>
\t\t\t\t<v8:Value xsi:type="app:ApplicationUsePurpose">PlatformApplication</v8:Value>
\t\t\t</UsePurposes>
\t\t\t<ScriptVariant>Russian</ScriptVariant>
\t\t\t<DefaultRoles/>
\t\t\t<Vendor/>
\t\t\t<Version/>
\t\t\t<UpdateCatalogAddress/>
\t\t\t<IncludeHelpInContents>false</IncludeHelpInContents>
\t\t\t<UseManagedFormInOrdinaryApplication>false</UseManagedFormInOrdinaryApplication>
\t\t\t<UseOrdinaryFormInManagedApplication>false</UseOrdinaryFormInManagedApplication>
\t\t\t<AdditionalFullTextSearchDictionaries/>
\t\t\t<CommonSettingsStorage/>
\t\t\t<ReportsUserSettingsStorage/>
\t\t\t<ReportsVariantsStorage/>
\t\t\t<FormDataSettingsStorage/>
\t\t\t<DynamicListsUserSettingsStorage/>
\t\t\t<URLExternalDataStorage/>
\t\t\t<Content/>
\t\t\t<DefaultReportForm/>
\t\t\t<DefaultReportVariantForm/>
\t\t\t<DefaultReportSettingsForm/>
\t\t\t<DefaultReportAppearanceTemplate/>
\t\t\t<DefaultDynamicListSettingsForm/>
\t\t\t<DefaultSearchForm/>
\t\t\t<DefaultDataHistoryChangeHistoryForm/>
\t\t\t<DefaultDataHistoryVersionDataForm/>
\t\t\t<DefaultDataHistoryVersionDifferencesForm/>
\t\t\t<DefaultCollaborationSystemUsersChoiceForm/>
\t\t\t<RequiredMobileApplicationPermissions/>
\t\t\t<UsedMobileApplicationFunctionalities/>
\t\t\t<StandaloneConfigurationRestrictionRoles/>
\t\t\t<MobileApplicationURLs/>
\t\t\t<AllowedIncomingShareRequestTypes/>
\t\t\t<MainClientApplicationWindowMode>Normal</MainClientApplicationWindowMode>
\t\t\t<DefaultInterface/>
\t\t\t<DefaultStyle/>
\t\t\t<DefaultLanguage>Language.\u0420\u0443\u0441\u0441\u043a\u0438\u0439</DefaultLanguage>
\t\t\t<BriefInformation/>
\t\t\t<DetailedInformation/>
\t\t\t<Copyright/>
\t\t\t<VendorInformationAddress/>
\t\t\t<ConfigurationInformationAddress/>
\t\t\t<DataLockControlMode>Managed</DataLockControlMode>
\t\t\t<ObjectAutonumerationMode>NotAutoFree</ObjectAutonumerationMode>
\t\t\t<ModalityUseMode>DontUse</ModalityUseMode>
\t\t\t<SynchronousPlatformExtensionAndAddInCallUseMode>DontUse</SynchronousPlatformExtensionAndAddInCallUseMode>
\t\t\t<InterfaceCompatibilityMode>Taxi</InterfaceCompatibilityMode>
\t\t\t<DatabaseTablespacesUseMode>DontUse</DatabaseTablespacesUseMode>
\t\t\t<CompatibilityMode>Version8_3_24</CompatibilityMode>
\t\t\t<DefaultConstantsForm/>
\t\t</Properties>
\t\t<ChildObjects>{child_xml}
\t\t</ChildObjects>
\t</Configuration>
</MetaDataObject>
"""
        write_bom(os.path.join(cfg_dir, 'Configuration.xml'), cfg_xml)

        # Language
        lang_dir = os.path.join(cfg_dir, 'Languages')
        os.makedirs(lang_dir, exist_ok=True)
        lang_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {NS}>
\t<Language uuid="{uuid_lang}">
\t\t<Properties>
\t\t\t<Name>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>\u0420\u0443\u0441\u0441\u043a\u0438\u0439</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<LanguageCode>ru</LanguageCode>
\t\t</Properties>
\t</Language>
</MetaDataObject>
"""
        write_bom(os.path.join(lang_dir, '\u0420\u0443\u0441\u0441\u043a\u0438\u0439.xml'), lang_xml)

        # Metadata stubs
        for meta_type, names in type_map.items():
            if meta_type not in META_INFO:
                continue
            tag, dirname = META_INFO[meta_type]
            obj_dir = os.path.join(cfg_dir, dirname)
            os.makedirs(obj_dir, exist_ok=True)

            for obj_name in names:
                obj_uuid = new_uuid()
                internal_xml = build_internal_info(meta_type, obj_name)
                if internal_xml:
                    internal_xml = '\n' + internal_xml

                sa = build_std_attrs(meta_type)

                if meta_type == 'Document':
                    rr_xml = '<RegisterRecords/>'
                    if obj_name == '\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430\u0420\u0435\u0433\u0438\u0441\u0442\u0440\u0430\u0442\u043e\u0440\u0430':  # ЗаглушкаРегистратора
                        rr_lines = []
                        for rt in registrator_types:
                            if rt in type_map:
                                for rn in type_map[rt]:
                                    rr_lines.append(f'\t\t\t\t<xr:Item xsi:type="xr:MDObjectRef">{rt}.{rn}</xr:Item>')
                        if rr_lines:
                            rr_xml = '<RegisterRecords>\n' + '\n'.join(rr_lines) + '\n\t\t\t</RegisterRecords>'
                    props_xml = build_doc_props(obj_name, sa, rr_xml)
                elif meta_type in PROPS:
                    props_xml = PROPS[meta_type](obj_name, sa)
                else:
                    props_xml = f'\t\t\t<Name>{obj_name}</Name>\n\t\t\t<Synonym/>\n\t\t\t<Comment/>'

                # ChildObjects — varies by type
                if meta_type == 'DefinedType':
                    child_obj_xml = ''
                elif meta_type == 'InformationRegister':
                    reg_key = f'InformationRegister.{obj_name}'
                    cols = list(register_columns.get(reg_key, {}).keys()) or ['\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430']
                    parts = []
                    for i, col in enumerate(cols):
                        u = new_uuid()
                        if i == 0:
                            parts.append(f"""\t\t\t<Dimension uuid="{u}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>{col}</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:string</v8:Type><v8:StringQualifiers><v8:Length>10</v8:Length><v8:AllowedLength>Variable</v8:AllowedLength></v8:StringQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/>
\t\t\t\t\t<FillFromFillingValue>false</FillFromFillingValue><FillValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<Master>false</Master><MainFilter>true</MainFilter><DenyIncompleteValues>false</DenyIncompleteValues>
\t\t\t\t\t<Indexing>DontIndex</Indexing><FullTextSearch>Use</FullTextSearch><DataHistory>Use</DataHistory>
\t\t\t\t</Properties>
\t\t\t</Dimension>""")
                        else:
                            parts.append(f"""\t\t\t<Attribute uuid="{u}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>{col}</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:string</v8:Type><v8:StringQualifiers><v8:Length>10</v8:Length><v8:AllowedLength>Variable</v8:AllowedLength></v8:StringQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/>
\t\t\t\t\t<FillFromFillingValue>false</FillFromFillingValue><FillValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<Indexing>DontIndex</Indexing><FullTextSearch>Use</FullTextSearch><DataHistory>Use</DataHistory>
\t\t\t\t</Properties>
\t\t\t</Attribute>""")
                    child_obj_xml = '\n\t\t<ChildObjects>\n' + '\n'.join(parts) + '\n\t\t</ChildObjects>'
                elif meta_type in ('AccumulationRegister', 'AccountingRegister', 'CalculationRegister'):
                    reg_key = f'{meta_type}.{obj_name}'
                    cols = list(register_columns.get(reg_key, {}).keys())
                    parts = []
                    # Required stub Resource
                    parts.append(f"""\t\t\t<Resource uuid="{new_uuid()}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>\u0417\u0430\u0433\u043b\u0443\u0448\u043a\u0430</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:decimal</v8:Type><v8:NumberQualifiers><v8:Digits>15</v8:Digits><v8:FractionDigits>2</v8:FractionDigits><v8:AllowedSign>Any</v8:AllowedSign></v8:NumberQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t\t</Properties>
\t\t\t</Resource>""")
                    # Form-referenced columns as Dimensions
                    for col in cols:
                        parts.append(f"""\t\t\t<Dimension uuid="{new_uuid()}">
\t\t\t\t<Properties>
\t\t\t\t\t<Name>{col}</Name>
\t\t\t\t\t<Synonym/><Comment/>
\t\t\t\t\t<Type><v8:Type>xs:string</v8:Type><v8:StringQualifiers><v8:Length>10</v8:Length><v8:AllowedLength>Variable</v8:AllowedLength></v8:StringQualifiers></Type>
\t\t\t\t\t<PasswordMode>false</PasswordMode><Format/><EditFormat/><ToolTip/><MarkNegatives>false</MarkNegatives><Mask/>
\t\t\t\t\t<MultiLine>false</MultiLine><ExtendedEdit>false</ExtendedEdit>
\t\t\t\t\t<MinValue xsi:nil="true"/><MaxValue xsi:nil="true"/><FillChecking>DontCheck</FillChecking>
\t\t\t\t\t<ChoiceFoldersAndItems>Items</ChoiceFoldersAndItems><ChoiceParameterLinks/><ChoiceParameters/>
\t\t\t\t\t<QuickChoice>Auto</QuickChoice><CreateOnInput>Auto</CreateOnInput><ChoiceForm/><LinkByType/><ChoiceHistoryOnInput>Auto</ChoiceHistoryOnInput>
\t\t\t\t\t<FullTextSearch>Use</FullTextSearch>
\t\t\t\t</Properties>
\t\t\t</Dimension>""")
                    child_obj_xml = '\n\t\t<ChildObjects>\n' + '\n'.join(parts) + '\n\t\t</ChildObjects>'
                else:
                    child_obj_xml = '\n\t\t<ChildObjects/>'

                obj_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {NS}>
\t<{tag} uuid="{obj_uuid}">{internal_xml}
\t\t<Properties>
{props_xml}
\t\t</Properties>{child_obj_xml}
\t</{tag}>
</MetaDataObject>
"""
                write_bom(os.path.join(obj_dir, f'{obj_name}.xml'), obj_xml)

        print(f'Generated stub configuration with {len(type_map)} metadata types')
        if register_columns:
            print('WARNING: Register column categories (Dimension/Resource/Attribute) are guessed. Form field bindings may not survive round-trip through a real database.')

    # Create infobase
    print(f'Creating infobase: {temp_base}')
    result = subprocess.run(
        [args.V8Path, 'CREATEINFOBASE', f'File={temp_base}', '/DisableStartupDialogs'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f'Failed to create infobase (code: {result.returncode})', file=sys.stderr)
        sys.exit(1)

    if has_ref_types:
        cfg_dir = os.path.join(temp_base, 'cfg')
        # LoadConfigFromFiles
        print('Loading configuration from files...')
        result = subprocess.run(
            [args.V8Path, 'DESIGNER', f'/F{temp_base}', '/LoadConfigFromFiles', cfg_dir, '/DisableStartupDialogs'],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f'Failed to load config (code: {result.returncode})', file=sys.stderr)
            sys.exit(1)

        # UpdateDBCfg
        print('Updating database configuration...')
        update_log = os.path.join(tempfile.gettempdir(), 'stub_update_log.txt')
        result = subprocess.run(
            [args.V8Path, 'DESIGNER', f'/F{temp_base}', '/UpdateDBCfg', '/Out', update_log, '/DisableStartupDialogs'],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            if os.path.isfile(update_log):
                try:
                    with open(update_log, 'r', encoding='utf-8-sig') as f:
                        print(f.read())
                except Exception:
                    pass
            print(f'Failed to update DB config (code: {result.returncode})', file=sys.stderr)
            sys.exit(1)

        # Cleanup cfg dir
        import shutil
        shutil.rmtree(cfg_dir, ignore_errors=True)

    print(f'[OK] Stub database created: {temp_base}')
    print(temp_base)


if __name__ == '__main__':
    main()
