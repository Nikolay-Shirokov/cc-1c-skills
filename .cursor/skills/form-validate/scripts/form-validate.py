#!/usr/bin/env python3
# form-validate v1.29 — Validate 1C managed form
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


F_NS = "http://v8.1c.ru/8.3/xcf/logform"
V8_NS = "http://v8.1c.ru/8.1/data/core"

NSMAP = {"f": F_NS, "v8": V8_NS}

KNOWN_INVALID_TYPES = {
    'FormDataStructure', 'FormDataCollection', 'FormDataTree',
    'FormDataTreeItem', 'FormDataCollectionItem',
    'FormGroup', 'FormField', 'FormButton', 'FormDecoration', 'FormTable',
}

VALID_CLOSED_TYPES = {
    'xs:boolean', 'xs:string', 'xs:decimal', 'xs:dateTime', 'xs:binary',
    'v8:FillChecking', 'v8:Null', 'v8:StandardPeriod', 'v8:StandardBeginningDate', 'v8:Type',
    'v8:TypeDescription', 'v8:UUID', 'v8:ValueListType', 'v8:ValueTable', 'v8:ValueTree',
    'v8:Universal', 'v8:FixedArray', 'v8:FixedStructure',
    'v8ui:Color', 'v8ui:Font', 'v8ui:FormattedString', 'v8ui:HorizontalAlign',
    'v8ui:Picture', 'v8ui:SizeChangeMode', 'v8ui:VerticalAlign',
    'dcsset:DataCompositionComparisonType', 'dcsset:DataCompositionFieldPlacement',
    'dcsset:Filter', 'dcsset:SettingsComposer', 'dcsset:DataCompositionSettings',
    'dcssch:DataCompositionSchema',
    'dcscor:DataCompositionComparisonType', 'dcscor:DataCompositionGroupType',
    'dcscor:DataCompositionPeriodAdditionType', 'dcscor:DataCompositionSortDirection', 'dcscor:Field',
    'ent:AccountType', 'ent:AccumulationRecordType', 'ent:AccountingRecordType',
}

VALID_CFG_PREFIXES = {
    'AccountingRegisterRecordSet', 'AccumulationRegisterRecordSet',
    'BusinessProcessObject', 'BusinessProcessRef',
    'CatalogObject', 'CatalogRef',
    'ChartOfAccountsObject', 'ChartOfAccountsRef',
    'ChartOfCalculationTypesObject', 'ChartOfCalculationTypesRef',
    'ChartOfCharacteristicTypesObject', 'ChartOfCharacteristicTypesRef',
    'ConstantsSet', 'DataProcessorObject', 'DocumentObject', 'DocumentRef',
    'DynamicList', 'EnumRef', 'ExchangePlanObject', 'ExchangePlanRef',
    'ExternalDataProcessorObject', 'ExternalReportObject',
    'ExternalDataSourceTableObject', 'ExternalDataSourceTableRecordManager',
    'ExternalDataSourceTableRef',
    'InformationRegisterRecordManager', 'InformationRegisterRecordSet',
    'ReportObject', 'TaskObject', 'TaskRef',
}


# Корень автономной внешней обработки/отчёта. Копия общего эталона (семья
# support-guard: is_external_root, авторитет — cf-edit).
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


# Штамп версии формата — атрибут version КОРНЕВОГО элемента файла. Копия общего эталона (семья
# root_version, авторитет — meta-validate).
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


# Якорь выгрузки: корень автономной EPF/ERF либо Configuration.xml, ближайший вверх. Копия общего
# эталона (семья find_dump_anchor, авторитет — meta-validate).
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


# Владелец тела X/Ext/<файл>.xml — дескриптор X.xml рядом с каталогом X. У тел конфигурации (и
# расширения) соседа-дескриптора нет, владелец — Configuration.xml внутри X. Иначе — не определён.
def ext_body_owner(body_path):
    ext_dir = os.path.dirname(body_path)
    if os.path.basename(ext_dir) != "Ext":
        return None
    obj_dir = os.path.dirname(ext_dir)
    if os.path.isfile(obj_dir + ".xml"):
        return obj_dir + ".xml"
    cfg = os.path.join(obj_dir, "Configuration.xml")
    if os.path.isfile(cfg):
        return cfg
    return None


# ── Format version ───────────────────────────────────────────
# Проверенный диапазон версий формата выгрузки: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница —
# docs/1c-configuration-spec.md, «Лестница версий». Версию задаёт платформа ВЫГРУЗКИ, а не режим
# совместимости конфигурации. Версии ниже 2.17 (платформы 8.3.23 и старше) существуют, но навыки
# на них не проверялись — это предупреждение о непокрытии, а не о некорректности файла.
FORMAT_VERIFIED_MIN = "2.17"
FORMAT_VERIFIED_MAX = "2.21"


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


def localname(el):
    return etree.QName(el.tag).localname


# --- Перечисления свойств формы (генерируется) ---
# Значения свойств-перечислений элементов формы и корня (ключ «Тип.Свойство» или общий «Свойство»).
# Источник — XSD xcf-logform 2.10–2.21, сверено с корпусом БП/ERP 8.3.24 (17036 форм, расхождений нет)
# и загрузкой в 8.3.24. Перегенерировать: python debug/form-dsl-revision/gen_enum_table.py
valid_enum_values = {
    "ActionPurpose": ["Usual", "Create", "Finish"],
    "AppearanceInCard": ["Auto", "Extended"],
    "AppearanceMode": ["Auto", "CommandBar", "UsualGroup"],
    "AutoAddIncomplete": ["true", "false", "auto"],
    "AutoCapitalizationOnTextInput": ["Auto", "None", "Words", "Sentences", "AllCharacters"],
    "AutoChoiceIncomplete": ["true", "false", "auto"],
    "AutoCorrectionOnTextInput": ["Auto", "Use", "DontUse"],
    "AutoMarkIncomplete": ["true", "false", "auto"],
    "AutoSaveDataInSettings": ["DontUse", "Use"],
    "AutoShowClearButtonMode": ["Auto", "Always", "FilledOnly"],
    "AutoShowOpenButtonMode": ["Auto", "Always", "FilledOnly"],
    "AutoShowState": ["Auto", "DontShow", "Show", "ShowOnComposition"],
    "AutoTime": ["DontUse", "Last", "First", "CurrentOrLast", "CurrentOrFirst"],
    "AutoWidthInTable": ["Auto", "ByData", "None", "ByDataAndTitle"],
    "AutofillHint": ["DontUse", "FullName", "GivenName", "FamilyName", "MiddleName", "NamePrefix", "NameSuffix", "Street", "City", "Region", "Country", "PostalCode", "UserName", "Password", "NewPassword", "OneTimeCode", "Email", "PhoneNumber", "CreditCardNumber"],
    "BackPictureEffect": ["Auto", "None", "Semitransparency", "SemitransparencyAndBlur"],
    "BackgroundShowMode": ["Auto", "DontShow", "ShowAndIncreaseSize", "ShowAndDontIncreaseSize"],
    "Behavior": ["Usual", "Collapsible", "PopUp", "Auto"],
    "BehaviorOnHorizontalCompression": ["Auto", "HideItemsByImportance", "MoveItemsByImportance"],
    "ButtonImportance": ["Main", "Normal", "Supplementary"],
    "CardBehaviorOnVerticalCompression": ["Auto", "MoveItemsToSwipeablePages", "HideItems"],
    "CardPictureAndTitleAlign": ["Auto", "LeftHorizontallySidesVertically", "CenterHorizontallySidesVertically", "CenterHorizontallyCenterVertically"],
    "CardRepresentationType": ["Usual", "Group"],
    "CellActionsButtonViewMode": ["Auto", "DontShow", "ShowOnHover"],
    "CellHyperlinkDisplayVariant": ["Auto", "Always", "OnRowHover"],
    "CellHyperlinkRepresentation": ["Auto", "Show", "DontShow"],
    "CellHyperlinksRepresentation": ["Auto", "AutoForSingle", "ForAll", "DontShow"],
    "CellMark": ["None", "ShapeUnderTextOval", "IconCircle"],
    "CheckBoxType": ["Auto", "CheckBox", "Tumbler", "Switcher"],
    "ChildItemsTitleLocation": ["Auto", "Left", "LeftIfPossible", "Top"],
    "ChildItemsWidth": ["Auto", "Equal", "LeftWide", "LeftWidest", "LeftNarrow", "LeftNarrowest"],
    "ChildrenAlign": ["Auto", "None", "ItemsLeftTitlesLeft", "ItemsRightTitlesLeft", "ItemsLeftTitlesRight", "ItemsRightTitlesRight", "TitlesLeftDataLeft", "TitlesLeftDataRight", "TitlesRightDataLeft", "TitlesRightDataRight", "TitlesLeftDataAuto"],
    "ChoiceButton": ["true", "false", "auto"],
    "ChoiceButtonRepresentation": ["Auto", "ShowInDropList", "ShowInDropListAndInInputField", "ShowInInputField"],
    "InputField.ChoiceFoldersAndItems": ["Items", "Folders", "FoldersAndItems", "Auto"],
    "Table.ChoiceFoldersAndItems": ["Items", "Folders", "FoldersAndItems"],
    "ChoiceHistoryOnInput": ["Auto", "DontUse"],
    "ChoiceListButton": ["true", "false", "auto"],
    "ClearButton": ["true", "false", "auto"],
    "CollapseItemsByImportanceVariant": ["Auto", "Use", "DontUse"],
    "CommandBarLocation": ["None", "Auto", "Top", "Bottom"],
    "ComplexSettingsViewMode": ["Show", "DontShow"],
    "ControlRepresentation": ["TitleHyperlink", "Picture", "Button", "ButtonInParentElement"],
    "ConversationsRepresentation": ["Auto", "Show", "DontShow"],
    "CreateButton": ["true", "false", "auto"],
    "Command.CurrentRowUse": ["Use", "DontUse", "Auto"],
    "Pages.CurrentRowUse": ["Use", "DontUse", "Auto"],
    "Table.CurrentRowUse": ["Auto", "Choice", "SelectionPresentation", "SelectionPresentationAndChoice"],
    "UsualGroup.CurrentRowUse": ["Use", "DontUse", "Auto"],
    "DisplayImportance": ["Auto", "VeryHigh", "High", "Usual", "Low", "VeryLow"],
    "DrawingSelectionShowMode": ["Show", "DontShow", "Auto"],
    "DropListButton": ["true", "false", "auto"],
    "EditMode": ["Directly", "Enter", "EnterOnInput", "Auto"],
    "EditTextUpdate": ["Auto", "DontUse", "OnValueChange", "Always"],
    "EnterKeyBehavior": ["ControlNavigation", "DefaultButton"],
    "EqualColumnsWidth": ["true", "false", "auto"],
    "EqualItemsWidth": ["true", "false", "auto"],
    "ExtendedEdit": ["true", "false", "auto"],
    "FileDragMode": ["AsFile", "AsFileRef"],
    "FillCheck": ["DontCheck", "ShowError"],
    "FixInCard": ["true", "false", "auto"],
    "FixingInTable": ["None", "Left", "Right"],
    "FooterHorizontalAlign": ["Left", "Center", "Right", "Auto"],
    "ColumnGroup.Group": ["Horizontal", "Vertical", "InCell"],
    "Form.Group": ["Horizontal", "Vertical", "HorizontalIfPossible", "AlwaysHorizontal", "Auto", "AutoScreenTypeSensitive"],
    "Page.Group": ["Horizontal", "Vertical", "HorizontalIfPossible", "AlwaysHorizontal", "Auto", "AutoScreenTypeSensitive"],
    "UsualGroup.Group": ["Horizontal", "Vertical", "HorizontalIfPossible", "AlwaysHorizontal", "Auto", "AutoScreenTypeSensitive"],
    "GroupHorizontalAlign": ["Left", "Center", "Right", "Auto"],
    "GroupVerticalAlign": ["Top", "Center", "Bottom", "Auto"],
    "HeaderHorizontalAlign": ["Left", "Center", "Right", "Auto"],
    "InputField.HeightControlVariant": ["Auto", "UseHeightInFormRows", "UseContentHeight"],
    "Table.HeightControlVariant": ["Auto", "UseHeightInFormRows", "UseHeightInTableRows", "UseContentHeight"],
    "HierarchyPanelLocation": ["Auto", "None"],
    "HorizontalAlign": ["Left", "Center", "Right", "Auto"],
    "HorizontalLinesBWA": ["true", "false", "auto"],
    "HorizontalLocation": ["Left", "Center", "Right", "Auto"],
    "Table.HorizontalScrollBar": ["DontUse", "UseAlways", "AutoUse"],
    "HorizontalSpacing": ["Auto", "None", "Half", "Single", "OneAndHalf", "Double"],
    "AutoCommandBar.HorizontalStretch": ["true", "false", "auto"],
    "ButtonGroup.HorizontalStretch": ["true", "false", "auto"],
    "CheckBoxField.HorizontalStretch": ["true", "false", "auto"],
    "ColumnGroup.HorizontalStretch": ["true", "false", "auto"],
    "CommandBar.HorizontalStretch": ["true", "false", "auto"],
    "ContextMenu.HorizontalStretch": ["true", "false", "auto"],
    "ExtendedTooltip.HorizontalStretch": ["true", "false", "auto"],
    "InputField.HorizontalStretch": ["true", "false", "auto"],
    "LabelDecoration.HorizontalStretch": ["true", "false", "auto"],
    "LabelField.HorizontalStretch": ["true", "false", "auto"],
    "Page.HorizontalStretch": ["true", "false", "auto"],
    "Pages.HorizontalStretch": ["true", "false", "auto"],
    "PictureDecoration.HorizontalStretch": ["true", "false", "auto"],
    "Popup.HorizontalStretch": ["true", "false", "auto"],
    "RadioButtonField.HorizontalStretch": ["true", "false", "auto"],
    "SearchControlAddition.HorizontalStretch": ["true", "false", "auto"],
    "SearchStringAddition.HorizontalStretch": ["true", "false", "auto"],
    "UsualGroup.HorizontalStretch": ["true", "false", "auto"],
    "ViewStatusAddition.HorizontalStretch": ["true", "false", "auto"],
    "Importance": ["Main", "Normal", "Supplementary"],
    "IncompleteChoiceMode": ["OnEnterPressed", "OnActivate"],
    "InitialListView": ["Beginning", "End", "Auto"],
    "InitialRowActivation": ["Auto", "Activate", "NoActivate"],
    "InitialTreeView": ["NoExpand", "ExpandTopLevel", "ExpandAllLevels"],
    "IntervalsSelectionMode": ["Auto", "Multiple", "Single", "None"],
    "KeyType": ["Auto", "FieldValue", "RowKey", "RowNumber"],
    "LocationInCommandBar": ["Auto", "InAdditionalSubmenu", "InCommandBar", "InCommandBarAndInAdditionalSubmenu"],
    "MarkNegatives": ["true", "false", "auto"],
    "MarkRequiredComplete": ["true", "false", "auto"],
    "MarkingAppearance": ["DontShow", "TopLeft", "BottomRight", "BothSides"],
    "MobileDeviceTableType": ["Auto", "List", "Cards"],
    "MultiLine": ["true", "false", "auto"],
    "MultipleValuePictureShape": ["Auto", "Rect", "Circle", "Square"],
    "MultipleValuePictureSize": ["Auto", "Small", "Medium", "Large"],
    "MultipleValuesHyperlink": ["true", "false", "auto"],
    "OnMainServerUnavalableBehavior": ["Auto", "MakeDisable", "DontChangeBehavior"],
    "OnScreenKeyboardReturnKeyText": ["Auto", "Return", "Go", "Join", "Next", "Search", "Send", "Done", "Continue"],
    "OnlyInAllActions": ["true", "false", "auto"],
    "OpenButton": ["true", "false", "auto"],
    "Orientation": ["Horizontal", "Vertical", "HorizontalIfPossible"],
    "Output": ["Auto", "Enable", "Disable"],
    "PagesRepresentation": ["None", "TabsOnTop", "TabsOnBottom", "TabsOnLeftHorizontal", "TabsOnRightHorizontal", "Swipe", "Auto"],
    "PasswordMode": ["true", "false", "auto"],
    "PictureLocation": ["Auto", "Left", "Right", "Top", "Bottom"],
    "PictureSize": ["RealSize", "Stretch", "Proportionally", "Tile", "AutoSize", "RealSizeIgnoreScale", "AutoSizeIgnoreScale", "ByFontSize"],
    "PlacementArea": ["mainCmdsLeft", "autoCmds", "userCmds", "mainCmdsRight"],
    "PointerType": ["Special", "Regular"],
    "QuickChoice": ["true", "false", "auto"],
    "RadioButtonType": ["Auto", "RadioButtons", "Tumbler"],
    "RefreshRequest": ["None", "PullFromTop", "PullFromBottom", "PullFromTopOrBottom"],
    "ReportFormType": ["Main", "Settings", "Variant"],
    "ReportResultViewMode": ["Auto", "Default", "Compact"],
    "Button.Representation": ["Text", "Picture", "PictureAndText", "Auto"],
    "ButtonGroup.Representation": ["Auto", "Usual", "Compact"],
    "Command.Representation": ["Text", "Picture", "TextPicture", "Auto"],
    "Popup.Representation": ["Text", "Picture", "PictureAndText", "Auto"],
    "ProgressBarField.Representation": ["Smooth", "Broken", "BrokenTilt"],
    "Table.Representation": ["List", "HierarchicalList", "Tree"],
    "UsualGroup.Representation": ["Auto", "None", "StrongSeparation", "WeakSeparation", "NormalSeparation", "GroupBox", "Line", "Margin"],
    "RepresentationInContextMenu": ["None", "AdditionalInContextMenu", "OnlyInContextMenu", "Auto"],
    "RowActionsShowType": ["Auto", "DontShow", "ShowOnHover", "ShowAlways"],
    "RowInputMode": ["EndOfList", "EndOfWindow", "AfterCurrentRow", "BeforeCurrentRow"],
    "RowSelectionMode": ["Auto", "Cell", "Row"],
    "SaveColors": ["Auto", "ForUser", "ByKeyForUser", "DontUse"],
    "SaveDataInSettings": ["DontUse", "UseList"],
    "ScaleVariant": ["Auto", "Normal", "Compact", "NormalIfPossible"],
    "ScalingMode": ["Auto", "Normal", "Compact"],
    "Page.ScrollOnCompress": ["true", "false", "auto"],
    "UsualGroup.ScrollOnCompress": ["true", "false", "auto"],
    "SearchControlLocation": ["Auto", "None", "CommandBar"],
    "SearchOnInput": ["Use", "DontUse", "Auto"],
    "SearchStringLocation": ["Auto", "None", "CommandBar", "Top", "Bottom", "FormCaption", "PullFromTop"],
    "SelectedRowsUse": ["Use", "DontUse", "Auto"],
    "CalendarField.SelectionMode": ["Single", "Multiple", "Interval"],
    "Table.SelectionMode": ["SingleRow", "MultiRow"],
    "SelectionShowMode": ["WhenActive", "Always", "DontShow", "WhenMultipleCellsSelected", "WhenMultipleCellsSelectedWhenActive"],
    "Shape": ["Auto", "Usual", "Oval"],
    "ShapeRepresentation": ["Auto", "Always", "WhenActive", "None"],
    "ShowCheckBoxesInDropList": ["true", "false", "auto"],
    "ShowCommandBar": ["true", "false", "auto"],
    "ShowHorizontalLinesFlag": ["true", "false", "auto"],
    "ColumnGroup.ShowTitle": ["true", "false", "auto"],
    "Form.ShowTitle": ["true", "false", "auto"],
    "Page.ShowTitle": ["true", "false", "auto"],
    "UsualGroup.ShowTitle": ["true", "false", "auto"],
    "ShowTitleInCard": ["true", "false", "auto"],
    "ShowVerticalLinesFlag": ["true", "false", "auto"],
    "SkipOnInput": ["true", "false", "auto"],
    "SpecialTextInputMode": ["Auto", "None", "DigitsAndPunctuation", "URL", "Email", "PhoneNumber", "Digits"],
    "SpellCheckingOnTextInput": ["Auto", "Use", "DontUse"],
    "SpinButton": ["true", "false", "auto"],
    "SpreadsheetDocumentMultipleSelectionPanelViewMode": ["Auto", "DontShow", "ShowOnMultipleSelection", "ShowAlways"],
    "TableLocation": ["Auto", "Left", "Right", "None"],
    "TextSize": ["Enlarged", "Normal", "Reduced"],
    "ThroughAlign": ["Use", "DontUse", "Auto"],
    "TimeChoiceMode": ["Auto", "DontChoose", "CustomTime", "Interval1Minute", "Interval5Minutes", "Interval10Minutes", "Interval15Minutes", "Interval15And20Minutes", "Interval20Minutes", "Interval30Minutes", "Interval60Minutes"],
    "TitleLocation": ["None", "Auto", "Left", "Top", "Right", "Bottom"],
    "ToolTipRepresentation": ["Auto", "None", "Balloon", "Button", "ShowAuto", "ShowTop", "ShowLeft", "ShowBottom", "ShowRight"],
    "TumblerRepresentation": ["Text", "Picture", "Auto"],
    "Button.Type": ["CommandBarButton", "UsualButton", "Hyperlink", "CommandBarHyperlink"],
    "UpdateOnDataChange": ["Auto", "DontUpdate"],
    "UseAlternationRowColorBWA": ["true", "false", "auto"],
    "UseCopy": ["true", "false", "auto"],
    "UseForFoldersAndItems": ["Items", "Folders", "FoldersAndItems"],
    "UsePostingMode": ["Regular", "RealTime", "Ask", "Auto"],
    "ValuesSelectionMode": ["Auto", "Multiple", "Single", "None"],
    "VerticalAlign": ["Top", "Center", "Bottom", "Auto"],
    "VerticalLinesBWA": ["true", "false", "auto"],
    "VerticalScroll": ["auto", "use", "useIfNecessary", "useWithoutStretch"],
    "Table.VerticalScrollBar": ["DontUse", "UseAlways", "AutoUse"],
    "VerticalSpacing": ["Auto", "None", "Half", "Single", "OneAndHalf", "Double"],
    "AutoCommandBar.VerticalStretch": ["true", "false", "auto"],
    "ButtonGroup.VerticalStretch": ["true", "false", "auto"],
    "ColumnGroup.VerticalStretch": ["true", "false", "auto"],
    "CommandBar.VerticalStretch": ["true", "false", "auto"],
    "ContextMenu.VerticalStretch": ["true", "false", "auto"],
    "ExtendedTooltip.VerticalStretch": ["true", "false", "auto"],
    "InputField.VerticalStretch": ["true", "false", "auto"],
    "LabelDecoration.VerticalStretch": ["true", "false", "auto"],
    "LabelField.VerticalStretch": ["true", "false", "auto"],
    "Page.VerticalStretch": ["true", "false", "auto"],
    "Pages.VerticalStretch": ["true", "false", "auto"],
    "PictureDecoration.VerticalStretch": ["true", "false", "auto"],
    "Popup.VerticalStretch": ["true", "false", "auto"],
    "UsualGroup.VerticalStretch": ["true", "false", "auto"],
    "ViewMode": ["All", "QuickAccess"],
    "ViewModeApplicationOnSetReportResult": ["Auto", "Apply", "DontApply"],
    "ViewScalingMode": ["Auto", "Normal", "Large"],
    "ViewStatusLocation": ["Auto", "None", "Top", "Bottom"],
    "WarningOnEditRepresentation": ["Show", "DontShow", "Auto"],
    "WidthInCard": ["Auto", "Full", "Half"],
    "WindowOpeningMode": ["Auto", "DontBlock", "LockOwner", "LockWholeInterface", "Independent", "LockOwnerWindow"],
}
# Старые имена значений, которые платформа принимает и переводит в современные (замер выгрузки 8.3.24)
enum_value_aliases = {
    "TitlesLeftDataLeft": "ItemsLeftTitlesLeft",
    "TitlesLeftDataRight": "ItemsRightTitlesLeft",
    "TitlesRightDataLeft": "ItemsLeftTitlesRight",
    "TitlesRightDataRight": "ItemsRightTitlesRight",
    "GroupBox": "StrongSeparation",
    "Margin": "NormalSeparation",
    "Square": "Rect",
}
# Умолчания: значение, которое платформа у этого типа не пишет (выброшено при загрузке-выгрузке 8.3.24
# и ни разу не встречается в корпусе) — тег с ним не пишется
enum_default_values = {
    "Attribute.FillCheck": "DontCheck",
    "AutoCommandBar.GroupHorizontalAlign": "Auto",
    "AutoCommandBar.GroupVerticalAlign": "Auto",
    "AutoCommandBar.HorizontalAlign": "Left",
    "AutoCommandBar.HorizontalStretch": "auto",
    "AutoCommandBar.ToolTipRepresentation": "Auto",
    "AutoCommandBar.VerticalStretch": "auto",
    "Button.GroupHorizontalAlign": "Auto",
    "Button.GroupVerticalAlign": "Auto",
    "Button.LocationInCommandBar": "Auto",
    "Button.OnMainServerUnavalableBehavior": "Auto",
    "Button.PictureLocation": "Auto",
    "Button.PlacementArea": "userCmds",
    "Button.Representation": "Auto",
    "Button.RepresentationInContextMenu": "Auto",
    "Button.Shape": "Auto",
    "Button.ShapeRepresentation": "Auto",
    "Button.SkipOnInput": "auto",
    "Button.ToolTipRepresentation": "Auto",
    "ButtonGroup.GroupHorizontalAlign": "Auto",
    "ButtonGroup.GroupVerticalAlign": "Auto",
    "ButtonGroup.HorizontalStretch": "auto",
    "ButtonGroup.PlacementArea": "userCmds",
    "ButtonGroup.Representation": "Auto",
    "ButtonGroup.ToolTipRepresentation": "Auto",
    "ButtonGroup.VerticalStretch": "auto",
    "CalendarField.EditMode": "Enter",
    "CalendarField.FixingInTable": "None",
    "CalendarField.FooterHorizontalAlign": "Auto",
    "CalendarField.GroupHorizontalAlign": "Auto",
    "CalendarField.GroupVerticalAlign": "Auto",
    "CalendarField.HeaderHorizontalAlign": "Left",
    "CalendarField.HorizontalAlign": "Auto",
    "CalendarField.OnMainServerUnavalableBehavior": "Auto",
    "CalendarField.SelectionMode": "Single",
    "CalendarField.SkipOnInput": "auto",
    "CalendarField.TitleLocation": "Auto",
    "CalendarField.ToolTipRepresentation": "Auto",
    "CalendarField.VerticalAlign": "Auto",
    "CalendarField.WarningOnEditRepresentation": "Auto",
    "ChartField.EditMode": "Enter",
    "ChartField.FixingInTable": "None",
    "ChartField.FooterHorizontalAlign": "Auto",
    "ChartField.GroupHorizontalAlign": "Auto",
    "ChartField.GroupVerticalAlign": "Auto",
    "ChartField.HeaderHorizontalAlign": "Left",
    "ChartField.HorizontalAlign": "Auto",
    "ChartField.OnMainServerUnavalableBehavior": "Auto",
    "ChartField.SkipOnInput": "auto",
    "ChartField.TitleLocation": "Auto",
    "ChartField.ToolTipRepresentation": "Auto",
    "ChartField.VerticalAlign": "Auto",
    "ChartField.WarningOnEditRepresentation": "Auto",
    "CheckBoxField.EditMode": "Enter",
    "CheckBoxField.EqualItemsWidth": "auto",
    "CheckBoxField.FixingInTable": "None",
    "CheckBoxField.FooterHorizontalAlign": "Auto",
    "CheckBoxField.GroupHorizontalAlign": "Auto",
    "CheckBoxField.GroupVerticalAlign": "Auto",
    "CheckBoxField.HeaderHorizontalAlign": "Left",
    "CheckBoxField.HorizontalAlign": "Auto",
    "CheckBoxField.OnMainServerUnavalableBehavior": "Auto",
    "CheckBoxField.SkipOnInput": "auto",
    "CheckBoxField.TitleLocation": "Auto",
    "CheckBoxField.ToolTipRepresentation": "Auto",
    "CheckBoxField.VerticalAlign": "Auto",
    "CheckBoxField.WarningOnEditRepresentation": "Auto",
    "Column.FillCheck": "DontCheck",
    "ColumnGroup.FixingInTable": "None",
    "ColumnGroup.Group": "Vertical",
    "ColumnGroup.GroupHorizontalAlign": "Auto",
    "ColumnGroup.GroupVerticalAlign": "Auto",
    "ColumnGroup.HeaderHorizontalAlign": "Auto",
    "ColumnGroup.HorizontalStretch": "auto",
    "ColumnGroup.ToolTipRepresentation": "Auto",
    "ColumnGroup.VerticalStretch": "auto",
    "Command.CurrentRowUse": "Auto",
    "Command.Representation": "Auto",
    "CommandBar.GroupHorizontalAlign": "Auto",
    "CommandBar.GroupVerticalAlign": "Auto",
    "CommandBar.HorizontalLocation": "Left",
    "CommandBar.HorizontalStretch": "auto",
    "CommandBar.ToolTipRepresentation": "Auto",
    "CommandBar.VerticalStretch": "auto",
    "ContextMenu.GroupHorizontalAlign": "Auto",
    "ContextMenu.GroupVerticalAlign": "Auto",
    "ContextMenu.HorizontalStretch": "auto",
    "ContextMenu.ToolTipRepresentation": "Auto",
    "ContextMenu.VerticalStretch": "auto",
    "ExtendedTooltip.GroupHorizontalAlign": "Auto",
    "ExtendedTooltip.GroupVerticalAlign": "Auto",
    "ExtendedTooltip.HorizontalAlign": "Left",
    "ExtendedTooltip.HorizontalStretch": "auto",
    "ExtendedTooltip.OnMainServerUnavalableBehavior": "Auto",
    "ExtendedTooltip.SkipOnInput": "auto",
    "ExtendedTooltip.ToolTipRepresentation": "Auto",
    "ExtendedTooltip.VerticalAlign": "Auto",
    "ExtendedTooltip.VerticalStretch": "auto",
    "Form.AutoSaveDataInSettings": "DontUse",
    "Form.ChildItemsWidth": "Auto",
    "Form.ChildrenAlign": "Auto",
    "Form.CollapseItemsByImportanceVariant": "Auto",
    "Form.CommandBarLocation": "Auto",
    "Form.ConversationsRepresentation": "Auto",
    "Form.EnterKeyBehavior": "ControlNavigation",
    "Form.Group": "Vertical",
    "Form.HorizontalAlign": "Auto",
    "Form.HorizontalSpacing": "Auto",
    "Form.SaveDataInSettings": "DontUse",
    "Form.ScalingMode": "Auto",
    "Form.VerticalAlign": "Auto",
    "Form.VerticalScroll": "auto",
    "Form.VerticalSpacing": "Auto",
    "Form.WindowOpeningMode": "Independent",
    "FormattedDocumentField.EditMode": "Enter",
    "FormattedDocumentField.FixingInTable": "None",
    "FormattedDocumentField.FooterHorizontalAlign": "Auto",
    "FormattedDocumentField.GroupHorizontalAlign": "Auto",
    "FormattedDocumentField.GroupVerticalAlign": "Auto",
    "FormattedDocumentField.HeaderHorizontalAlign": "Left",
    "FormattedDocumentField.HorizontalAlign": "Auto",
    "FormattedDocumentField.OnMainServerUnavalableBehavior": "Auto",
    "FormattedDocumentField.Output": "Auto",
    "FormattedDocumentField.SkipOnInput": "auto",
    "FormattedDocumentField.TitleLocation": "Auto",
    "FormattedDocumentField.ToolTipRepresentation": "Auto",
    "FormattedDocumentField.VerticalAlign": "Auto",
    "FormattedDocumentField.WarningOnEditRepresentation": "Auto",
    "GraphicalSchemaField.EditMode": "Enter",
    "GraphicalSchemaField.FixingInTable": "None",
    "GraphicalSchemaField.FooterHorizontalAlign": "Auto",
    "GraphicalSchemaField.GroupHorizontalAlign": "Auto",
    "GraphicalSchemaField.GroupVerticalAlign": "Auto",
    "GraphicalSchemaField.HeaderHorizontalAlign": "Left",
    "GraphicalSchemaField.HorizontalAlign": "Auto",
    "GraphicalSchemaField.OnMainServerUnavalableBehavior": "Auto",
    "GraphicalSchemaField.Output": "Auto",
    "GraphicalSchemaField.SkipOnInput": "auto",
    "GraphicalSchemaField.TitleLocation": "Auto",
    "GraphicalSchemaField.ToolTipRepresentation": "Auto",
    "GraphicalSchemaField.VerticalAlign": "Auto",
    "GraphicalSchemaField.WarningOnEditRepresentation": "Auto",
    "HTMLDocumentField.EditMode": "Enter",
    "HTMLDocumentField.FixingInTable": "None",
    "HTMLDocumentField.FooterHorizontalAlign": "Auto",
    "HTMLDocumentField.GroupHorizontalAlign": "Auto",
    "HTMLDocumentField.GroupVerticalAlign": "Auto",
    "HTMLDocumentField.HeaderHorizontalAlign": "Left",
    "HTMLDocumentField.HorizontalAlign": "Auto",
    "HTMLDocumentField.OnMainServerUnavalableBehavior": "Auto",
    "HTMLDocumentField.Output": "Auto",
    "HTMLDocumentField.SkipOnInput": "auto",
    "HTMLDocumentField.TitleLocation": "Auto",
    "HTMLDocumentField.ToolTipRepresentation": "Auto",
    "HTMLDocumentField.VerticalAlign": "Auto",
    "HTMLDocumentField.WarningOnEditRepresentation": "Auto",
    "InputField.AutoCapitalizationOnTextInput": "Auto",
    "InputField.AutoChoiceIncomplete": "auto",
    "InputField.AutoCorrectionOnTextInput": "Auto",
    "InputField.AutoMarkIncomplete": "auto",
    "InputField.AutoShowClearButtonMode": "Auto",
    "InputField.AutoShowOpenButtonMode": "Auto",
    "InputField.AutofillHint": "DontUse",
    "InputField.ChoiceButton": "auto",
    "InputField.ChoiceButtonRepresentation": "Auto",
    "InputField.ChoiceFoldersAndItems": "Auto",
    "InputField.ChoiceHistoryOnInput": "Auto",
    "InputField.ChoiceListButton": "auto",
    "InputField.ClearButton": "auto",
    "InputField.CreateButton": "auto",
    "InputField.DropListButton": "auto",
    "InputField.EditMode": "Enter",
    "InputField.EditTextUpdate": "Auto",
    "InputField.ExtendedEdit": "auto",
    "InputField.FixingInTable": "None",
    "InputField.FooterHorizontalAlign": "Auto",
    "InputField.GroupHorizontalAlign": "Auto",
    "InputField.GroupVerticalAlign": "Auto",
    "InputField.HeaderHorizontalAlign": "Left",
    "InputField.HeightControlVariant": "Auto",
    "InputField.HorizontalAlign": "Auto",
    "InputField.HorizontalStretch": "auto",
    "InputField.IncompleteChoiceMode": "OnEnterPressed",
    "InputField.MarkNegatives": "auto",
    "InputField.MultiLine": "auto",
    "InputField.MultipleValuePictureShape": "Auto",
    "InputField.MultipleValuePictureSize": "Auto",
    "InputField.MultipleValuesHyperlink": "auto",
    "InputField.OnMainServerUnavalableBehavior": "Auto",
    "InputField.OnScreenKeyboardReturnKeyText": "Auto",
    "InputField.OpenButton": "auto",
    "InputField.PasswordMode": "auto",
    "InputField.QuickChoice": "auto",
    "InputField.ShowCheckBoxesInDropList": "auto",
    "InputField.SkipOnInput": "auto",
    "InputField.SpecialTextInputMode": "Auto",
    "InputField.SpellCheckingOnTextInput": "Auto",
    "InputField.SpinButton": "auto",
    "InputField.TitleLocation": "Auto",
    "InputField.ToolTipRepresentation": "Auto",
    "InputField.VerticalAlign": "Auto",
    "InputField.VerticalStretch": "auto",
    "InputField.WarningOnEditRepresentation": "Auto",
    "LabelDecoration.GroupHorizontalAlign": "Auto",
    "LabelDecoration.GroupVerticalAlign": "Auto",
    "LabelDecoration.HorizontalAlign": "Left",
    "LabelDecoration.HorizontalStretch": "auto",
    "LabelDecoration.OnMainServerUnavalableBehavior": "Auto",
    "LabelDecoration.SkipOnInput": "auto",
    "LabelDecoration.ToolTipRepresentation": "Auto",
    "LabelDecoration.VerticalAlign": "Auto",
    "LabelDecoration.VerticalStretch": "auto",
    "LabelField.EditMode": "Enter",
    "LabelField.FixingInTable": "None",
    "LabelField.FooterHorizontalAlign": "Auto",
    "LabelField.GroupHorizontalAlign": "Auto",
    "LabelField.GroupVerticalAlign": "Auto",
    "LabelField.HeaderHorizontalAlign": "Left",
    "LabelField.HorizontalAlign": "Auto",
    "LabelField.HorizontalStretch": "auto",
    "LabelField.MarkNegatives": "auto",
    "LabelField.OnMainServerUnavalableBehavior": "Auto",
    "LabelField.PasswordMode": "auto",
    "LabelField.SkipOnInput": "auto",
    "LabelField.TitleLocation": "Auto",
    "LabelField.ToolTipRepresentation": "Auto",
    "LabelField.VerticalAlign": "Auto",
    "LabelField.VerticalStretch": "auto",
    "LabelField.WarningOnEditRepresentation": "Auto",
    "Page.ChildItemsWidth": "Auto",
    "Page.ChildrenAlign": "Auto",
    "Page.Group": "Vertical",
    "Page.GroupHorizontalAlign": "Auto",
    "Page.GroupVerticalAlign": "Auto",
    "Page.HorizontalAlign": "Auto",
    "Page.HorizontalSpacing": "Auto",
    "Page.HorizontalStretch": "auto",
    "Page.ToolTipRepresentation": "Auto",
    "Page.VerticalAlign": "Auto",
    "Page.VerticalSpacing": "Auto",
    "Page.VerticalStretch": "auto",
    "Pages.CurrentRowUse": "Auto",
    "Pages.GroupHorizontalAlign": "Auto",
    "Pages.GroupVerticalAlign": "Auto",
    "Pages.HorizontalStretch": "auto",
    "Pages.PagesRepresentation": "Auto",
    "Pages.ToolTipRepresentation": "Auto",
    "Pages.VerticalStretch": "auto",
    "PeriodField.EditMode": "Enter",
    "PeriodField.FixingInTable": "None",
    "PeriodField.FooterHorizontalAlign": "Auto",
    "PeriodField.GroupHorizontalAlign": "Auto",
    "PeriodField.GroupVerticalAlign": "Auto",
    "PeriodField.HeaderHorizontalAlign": "Left",
    "PeriodField.HorizontalAlign": "Auto",
    "PeriodField.OnMainServerUnavalableBehavior": "Auto",
    "PeriodField.SkipOnInput": "auto",
    "PeriodField.TitleLocation": "Auto",
    "PeriodField.ToolTipRepresentation": "Auto",
    "PeriodField.VerticalAlign": "Auto",
    "PeriodField.WarningOnEditRepresentation": "Auto",
    "PictureDecoration.FileDragMode": "AsFileRef",
    "PictureDecoration.GroupHorizontalAlign": "Auto",
    "PictureDecoration.GroupVerticalAlign": "Auto",
    "PictureDecoration.HorizontalStretch": "auto",
    "PictureDecoration.OnMainServerUnavalableBehavior": "Auto",
    "PictureDecoration.PictureSize": "RealSize",
    "PictureDecoration.SkipOnInput": "auto",
    "PictureDecoration.ToolTipRepresentation": "Auto",
    "PictureDecoration.VerticalStretch": "auto",
    "PictureField.EditMode": "Enter",
    "PictureField.FileDragMode": "AsFileRef",
    "PictureField.FixingInTable": "None",
    "PictureField.FooterHorizontalAlign": "Auto",
    "PictureField.GroupHorizontalAlign": "Auto",
    "PictureField.GroupVerticalAlign": "Auto",
    "PictureField.HeaderHorizontalAlign": "Left",
    "PictureField.HorizontalAlign": "Auto",
    "PictureField.OnMainServerUnavalableBehavior": "Auto",
    "PictureField.PictureSize": "RealSize",
    "PictureField.SkipOnInput": "auto",
    "PictureField.TitleLocation": "Auto",
    "PictureField.ToolTipRepresentation": "Auto",
    "PictureField.VerticalAlign": "Auto",
    "PictureField.WarningOnEditRepresentation": "Auto",
    "PlannerField.EditMode": "Enter",
    "PlannerField.FixingInTable": "None",
    "PlannerField.FooterHorizontalAlign": "Auto",
    "PlannerField.GroupHorizontalAlign": "Auto",
    "PlannerField.GroupVerticalAlign": "Auto",
    "PlannerField.HeaderHorizontalAlign": "Left",
    "PlannerField.HorizontalAlign": "Auto",
    "PlannerField.OnMainServerUnavalableBehavior": "Auto",
    "PlannerField.SkipOnInput": "auto",
    "PlannerField.TitleLocation": "Auto",
    "PlannerField.ToolTipRepresentation": "Auto",
    "PlannerField.VerticalAlign": "Auto",
    "PlannerField.WarningOnEditRepresentation": "Auto",
    "Popup.GroupHorizontalAlign": "Auto",
    "Popup.GroupVerticalAlign": "Auto",
    "Popup.HorizontalStretch": "auto",
    "Popup.PlacementArea": "userCmds",
    "Popup.Representation": "Auto",
    "Popup.Shape": "Auto",
    "Popup.ShapeRepresentation": "Auto",
    "Popup.ToolTipRepresentation": "Auto",
    "Popup.VerticalStretch": "auto",
    "ProgressBarField.EditMode": "Enter",
    "ProgressBarField.FixingInTable": "None",
    "ProgressBarField.FooterHorizontalAlign": "Auto",
    "ProgressBarField.GroupHorizontalAlign": "Auto",
    "ProgressBarField.GroupVerticalAlign": "Auto",
    "ProgressBarField.HeaderHorizontalAlign": "Left",
    "ProgressBarField.HorizontalAlign": "Auto",
    "ProgressBarField.OnMainServerUnavalableBehavior": "Auto",
    "ProgressBarField.Orientation": "Horizontal",
    "ProgressBarField.Representation": "Smooth",
    "ProgressBarField.SkipOnInput": "auto",
    "ProgressBarField.TitleLocation": "Auto",
    "ProgressBarField.ToolTipRepresentation": "Auto",
    "ProgressBarField.VerticalAlign": "Auto",
    "ProgressBarField.WarningOnEditRepresentation": "Auto",
    "RadioButtonField.EditMode": "Enter",
    "RadioButtonField.EqualColumnsWidth": "auto",
    "RadioButtonField.FixingInTable": "None",
    "RadioButtonField.FooterHorizontalAlign": "Auto",
    "RadioButtonField.GroupHorizontalAlign": "Auto",
    "RadioButtonField.GroupVerticalAlign": "Auto",
    "RadioButtonField.HeaderHorizontalAlign": "Left",
    "RadioButtonField.HorizontalAlign": "Auto",
    "RadioButtonField.OnMainServerUnavalableBehavior": "Auto",
    "RadioButtonField.SkipOnInput": "auto",
    "RadioButtonField.TitleLocation": "Auto",
    "RadioButtonField.ToolTipRepresentation": "Auto",
    "RadioButtonField.VerticalAlign": "Auto",
    "RadioButtonField.WarningOnEditRepresentation": "Auto",
    "SearchControlAddition.GroupHorizontalAlign": "Auto",
    "SearchControlAddition.GroupVerticalAlign": "Auto",
    "SearchControlAddition.HorizontalStretch": "auto",
    "SearchControlAddition.PlacementArea": "userCmds",
    "SearchControlAddition.ToolTipRepresentation": "Auto",
    "SearchStringAddition.GroupHorizontalAlign": "Auto",
    "SearchStringAddition.GroupVerticalAlign": "Auto",
    "SearchStringAddition.HorizontalStretch": "auto",
    "SearchStringAddition.PlacementArea": "userCmds",
    "SearchStringAddition.ToolTipRepresentation": "Auto",
    "Settings.KeyType": "Auto",
    "SpreadSheetDocumentField.DrawingSelectionShowMode": "Auto",
    "SpreadSheetDocumentField.EditMode": "Enter",
    "SpreadSheetDocumentField.FixingInTable": "None",
    "SpreadSheetDocumentField.FooterHorizontalAlign": "Auto",
    "SpreadSheetDocumentField.GroupHorizontalAlign": "Auto",
    "SpreadSheetDocumentField.GroupVerticalAlign": "Auto",
    "SpreadSheetDocumentField.HeaderHorizontalAlign": "Left",
    "SpreadSheetDocumentField.HorizontalAlign": "Auto",
    "SpreadSheetDocumentField.OnMainServerUnavalableBehavior": "Auto",
    "SpreadSheetDocumentField.Output": "Auto",
    "SpreadSheetDocumentField.PointerType": "Special",
    "SpreadSheetDocumentField.SelectionShowMode": "Always",
    "SpreadSheetDocumentField.SkipOnInput": "auto",
    "SpreadSheetDocumentField.TitleLocation": "Auto",
    "SpreadSheetDocumentField.ToolTipRepresentation": "Auto",
    "SpreadSheetDocumentField.VerticalAlign": "Auto",
    "SpreadSheetDocumentField.ViewScalingMode": "Auto",
    "SpreadSheetDocumentField.WarningOnEditRepresentation": "Auto",
    "Table.AutoAddIncomplete": "auto",
    "Table.AutoMarkIncomplete": "auto",
    "Table.BehaviorOnHorizontalCompression": "Auto",
    "Table.CommandBarLocation": "Auto",
    "Table.CurrentRowUse": "Auto",
    "Table.FileDragMode": "AsFileRef",
    "Table.GroupHorizontalAlign": "Auto",
    "Table.GroupVerticalAlign": "Auto",
    "Table.HeightControlVariant": "Auto",
    "Table.HorizontalScrollBar": "AutoUse",
    "Table.InitialListView": "Auto",
    "Table.InitialTreeView": "NoExpand",
    "Table.OnMainServerUnavalableBehavior": "Auto",
    "Table.Output": "Auto",
    "Table.RefreshRequest": "None",
    "Table.Representation": "HierarchicalList",
    "Table.RowInputMode": "EndOfList",
    "Table.RowSelectionMode": "Cell",
    "Table.SearchControlLocation": "Auto",
    "Table.SearchOnInput": "Auto",
    "Table.SearchStringLocation": "Auto",
    "Table.SelectionMode": "MultiRow",
    "Table.SkipOnInput": "auto",
    "Table.TitleLocation": "None",
    "Table.ToolTipRepresentation": "Auto",
    "Table.VerticalScrollBar": "AutoUse",
    "Table.ViewStatusLocation": "Auto",
    "TextDocumentField.EditMode": "Enter",
    "TextDocumentField.FixingInTable": "None",
    "TextDocumentField.FooterHorizontalAlign": "Auto",
    "TextDocumentField.GroupHorizontalAlign": "Auto",
    "TextDocumentField.GroupVerticalAlign": "Auto",
    "TextDocumentField.HeaderHorizontalAlign": "Left",
    "TextDocumentField.HorizontalAlign": "Auto",
    "TextDocumentField.OnMainServerUnavalableBehavior": "Auto",
    "TextDocumentField.Output": "Auto",
    "TextDocumentField.SkipOnInput": "auto",
    "TextDocumentField.TitleLocation": "Auto",
    "TextDocumentField.ToolTipRepresentation": "Auto",
    "TextDocumentField.VerticalAlign": "Auto",
    "TextDocumentField.WarningOnEditRepresentation": "Auto",
    "TrackBarField.EditMode": "Enter",
    "TrackBarField.FixingInTable": "None",
    "TrackBarField.FooterHorizontalAlign": "Auto",
    "TrackBarField.GroupHorizontalAlign": "Auto",
    "TrackBarField.GroupVerticalAlign": "Auto",
    "TrackBarField.HeaderHorizontalAlign": "Left",
    "TrackBarField.HorizontalAlign": "Auto",
    "TrackBarField.MarkingAppearance": "BottomRight",
    "TrackBarField.OnMainServerUnavalableBehavior": "Auto",
    "TrackBarField.Orientation": "Horizontal",
    "TrackBarField.SkipOnInput": "auto",
    "TrackBarField.TitleLocation": "Auto",
    "TrackBarField.ToolTipRepresentation": "Auto",
    "TrackBarField.VerticalAlign": "Auto",
    "TrackBarField.WarningOnEditRepresentation": "Auto",
    "UsualGroup.Behavior": "Auto",
    "UsualGroup.ChildItemsWidth": "Auto",
    "UsualGroup.ChildrenAlign": "Auto",
    "UsualGroup.ControlRepresentation": "TitleHyperlink",
    "UsualGroup.CurrentRowUse": "Auto",
    "UsualGroup.Group": "HorizontalIfPossible",
    "UsualGroup.GroupHorizontalAlign": "Auto",
    "UsualGroup.GroupVerticalAlign": "Auto",
    "UsualGroup.HorizontalAlign": "Auto",
    "UsualGroup.HorizontalSpacing": "Auto",
    "UsualGroup.HorizontalStretch": "auto",
    "UsualGroup.Representation": "WeakSeparation",
    "UsualGroup.ThroughAlign": "Auto",
    "UsualGroup.ToolTipRepresentation": "Auto",
    "UsualGroup.VerticalAlign": "Auto",
    "UsualGroup.VerticalSpacing": "Auto",
    "UsualGroup.VerticalStretch": "auto",
    "ViewStatusAddition.GroupHorizontalAlign": "Auto",
    "ViewStatusAddition.GroupVerticalAlign": "Auto",
    "ViewStatusAddition.HorizontalLocation": "Auto",
    "ViewStatusAddition.HorizontalStretch": "auto",
    "ViewStatusAddition.PlacementArea": "userCmds",
    "ViewStatusAddition.ToolTipRepresentation": "Auto",
}
# Узлы, у которых проверяются и приводятся значения перечислений (тег узла)
enum_scope_types = {
    'Attribute',
    'AutoCommandBar',
    'Button',
    'ButtonGroup',
    'CalendarField',
    'ChartField',
    'CheckBoxField',
    'Column',
    'ColumnGroup',
    'Command',
    'CommandBar',
    'ContextMenu',
    'ExtendedTooltip',
    'Form',
    'FormattedDocumentField',
    'GanttChartField',
    'GraphicalSchemaField',
    'HTMLDocumentField',
    'InputField',
    'LabelDecoration',
    'LabelField',
    'Page',
    'Pages',
    'PeriodField',
    'PictureDecoration',
    'PictureField',
    'PlannerField',
    'Popup',
    'ProgressBarField',
    'RadioButtonField',
    'SearchControlAddition',
    'SearchStringAddition',
    'Settings',
    'SpreadSheetDocumentField',
    'Table',
    'TextDocumentField',
    'TrackBarField',
    'UsualGroup',
    'ViewStatusAddition',
}
# Значение из соседнего перечисления того же свойства → значение этого типа (ввод DSL; в XML — ошибка)
enum_input_synonyms = {
    "Command.Representation": {"PictureAndText": "TextPicture"},
    "Button.Representation": {"TextPicture": "PictureAndText"},
    "Popup.Representation": {"TextPicture": "PictureAndText"},
    "Table.SelectionMode": {"Single": "SingleRow", "Multiple": "MultiRow"},
    "CalendarField.SelectionMode": {"SingleRow": "Single", "MultiRow": "Multiple"},
}
# --- /Перечисления свойств формы ---

# Порядок дочерних тегов элемента (копия form-compile; держат check-enum-drift и check-inline-drift)
CHILD_TAG_ORDER = {
    "AutoCommandBar": "HorizontalAlign Autofill ChildItems",
    "Button": "Type Visible TitleHeight UserVisible Representation DefaultButton SkipOnInput Enabled DefaultItem Width AutoMaxWidth MaxWidth Height AutoMaxHeight HorizontalStretch MaxHeight VerticalStretch GroupHorizontalAlign Check GroupVerticalAlign CommandName Parameter DataPath TextColor BackColor BorderColor Font Picture Title Shape ToolTipRepresentation RepresentationInContextMenu ShapeRepresentation PictureLocation LocationInCommandBar CommandUniqueness ExtendedTooltip",
    "ButtonGroup": "EnableContentChange Visible Title GroupVerticalAlign ToolTip HorizontalStretch GroupHorizontalAlign ToolTipRepresentation CommandSource Representation VerticalStretch ExtendedTooltip ChildItems",
    "CalendarField": "DataPath SkipOnInput Title TitleLocation ToolTip ToolTipRepresentation Width AutoMaxWidth Height HorizontalStretch SelectionMode ShowCurrentDate ShowMonthsPanel WidthInMonths HeightInMonths ContextMenu ExtendedTooltip Events",
    "ChartField": "DataPath Enabled Title TitleFont Visible TitleLocation GroupHorizontalAlign Width AutoMaxWidth MaxHeight MaxWidth Height AutoMaxHeight HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Events",
    "CheckBoxField": "DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip FooterHorizontalAlign HorizontalAlign ToolTipRepresentation Shortcut GroupHorizontalAlign VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode AutoCellHeight CellHyperlink FixingInTable ShowInHeader FooterDataPath HeaderPicture HeaderHorizontalAlign ShowInFooter CheckBoxType EditFormat ItemHeight ItemTitleHeight ItemWidth EqualItemsWidth ThreeState ContextMenu ExtendedTooltip Events",
    "ColumnGroup": "Visible Enabled ReadOnly UserVisible EnableContentChange Title GroupVerticalAlign TitleFont TitleTextColor ToolTip ToolTipRepresentation Width Height HorizontalStretch GroupHorizontalAlign VerticalStretch Group ShowTitle ShowInHeader HeaderDataPath HeaderHorizontalAlign HeaderFormat HeaderPicture FixingInTable ExtendedTooltip ChildItems",
    "CommandBar": "Enabled Visible EnableContentChange Title ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign HorizontalLocation CommandSource ExtendedTooltip ChildItems",
    "FormattedDocumentField": "DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleLocation CommandSet Font ToolTip EditMode Width AutoMaxWidth Height AutoMaxHeight BorderColor HorizontalStretch MaxWidth ContextMenu ExtendedTooltip Events",
    "GanttChartField": "DataPath DefaultItem TitleLocation Width Height HorizontalStretch VerticalStretch ContextMenu ExtendedTooltip Table Events",
    "GraphicalSchemaField": "DataPath DefaultItem ReadOnly Title TitleLocation WarningOnEditRepresentation Width Height Edit ContextMenu ExtendedTooltip Events",
    "HTMLDocumentField": "DataPath DefaultItem Enabled ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation ToolTipRepresentation Visible WarningOnEditRepresentation Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch Output BorderColor ContextMenu ExtendedTooltip Events",
    "InputField": "DataPath Visible UserVisible DefaultItem Enabled ReadOnly SkipOnInput Title TitleBackColor TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation WarningOnEditRepresentation WarningOnEdit Shortcut HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign EditMode CellHyperlink FixingInTable AutoCellHeight ShowInHeader HeaderHorizontalAlign HeaderPicture ShowInFooter FooterDataPath FooterText FooterTextColor FooterFont FooterHorizontalAlign FooterPicture Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch AllowInputEmptyMultipleValues MultipleValuesFont MultipleValuesTextColor MultipleValuesBackColor VerticalStretch Wrap MarkNegatives PasswordMode MultiLine ExtendedEdit DropListButton ChoiceButton ChoiceButtonRepresentation ClearButton SpinButton OpenButton CreateButton Mask ListChoiceMode ExtendedEditMultipleValues AutoChoiceIncomplete Format MultipleValuePictureShape QuickChoice ChoiceFoldersAndItems EditFormat AutoMarkIncomplete ChooseType AutoShowOpenButtonMode IncompleteChoiceMode ShowCheckBoxesInDropList MultipleValueDataPath MultipleValuePictureDataPath MultipleValuePresentDataPath SpellCheckingOnTextInput TypeDomainEnabled TextEdit AvailableTypes ChoiceForm ChoiceParameterLinks ChoiceParameters EditTextUpdate MinValue ChoiceButtonPicture MaxValue ChoiceList AutoCorrectionOnTextInput AutoShowClearButtonMode ChoiceListButton ChoiceListHeight DropListWidth TextColor BackColor BorderColor Font HeightControlVariant SpecialTextInputMode InputHint ChoiceHistoryOnInput TypeLink ContextMenu ExtendedTooltip Events",
    "LabelDecoration": "UserVisible Visible Enabled Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Shortcut Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink HorizontalAlign VerticalAlign BackColor BorderColor Border TitleHeight ContextMenu ExtendedTooltip Events",
    "LabelField": "DataPath Visible Enabled UserVisible DefaultItem ReadOnly SkipOnInput Title TitleTextColor TitleFont TitleLocation TitleHeight ToolTip ToolTipRepresentation HorizontalAlign VerticalAlign GroupHorizontalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit EditMode FixingInTable CellHyperlink AutoCellHeight FooterText ShowInHeader HeaderHorizontalAlign FooterDataPath HeaderPicture ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch MarkNegatives VerticalStretch Format Border BorderColor Hiperlink PasswordMode TextColor BackColor Font ContextMenu ExtendedTooltip Events",
    "Page": "Visible Enabled ReadOnly EnableContentChange UserVisible Title GroupVerticalAlign Shortcut TitleTextColor TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch ChildrenAlign Picture Format Group ChildItemsWidth HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign ShowTitle BackColor TitleDataPath ScrollOnCompress ExtendedTooltip ChildItems",
    "Pages": "Enabled ReadOnly EnableContentChange UserVisible Visible Title TitleFont ToolTip ToolTipRepresentation Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign PagesRepresentation CurrentRowUse ExtendedTooltip Events ChildItems",
    "PeriodField": "DataPath TitleLocation ContextMenu ExtendedTooltip",
    "PictureDecoration": "Enabled Visible Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch SkipOnInput TextColor Font Title ToolTip ToolTipRepresentation GroupHorizontalAlign GroupVerticalAlign Hyperlink PictureSize Zoomable ImageScale NonselectedPictureText EnableStartDrag EnableDrag Picture BorderColor Border FileDragMode ContextMenu ExtendedTooltip Events",
    "PictureField": "DataPath TitleBackColor UserVisible Visible Enabled ReadOnly SkipOnInput Title TitleTextColor TitleLocation TitleHeight ToolTip GroupHorizontalAlign GroupVerticalAlign Shortcut ToolTipRepresentation HorizontalAlign WarningOnEditRepresentation EditMode AutoCellHeight FixingInTable CellHyperlink ShowInHeader FooterDataPath HeaderPicture FooterText HeaderHorizontalAlign ShowInFooter FooterHorizontalAlign Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch PictureSize Zoomable Hyperlink NonselectedPictureText EnableDrag TextColor ValuesPicture BorderColor Border Font FileDragMode ContextMenu ExtendedTooltip Events",
    "PlannerField": "DataPath TitleLocation ContextMenu ExtendedTooltip Events",
    "Popup": "UserVisible Visible EnableContentChange Title Shape TitleTextColor TitleFont ToolTip ToolTipRepresentation VerticalStretch Width HorizontalStretch Picture CommandSource Representation BackColor ShapeRepresentation BorderColor ExtendedTooltip ChildItems",
    "ProgressBarField": "DataPath Title Visible ReadOnly TitleLocation ToolTip ToolTipRepresentation Width AutoMaxHeight AutoMaxWidth HorizontalStretch MaxValue ShowPercent ContextMenu ExtendedTooltip",
    "RadioButtonField": "DataPath DefaultItem Enabled SkipOnInput UserVisible Visible ReadOnly Title TitleTextColor TitleFont TitleLocation FooterHorizontalAlign TitleHeight ToolTip ToolTipRepresentation EditMode GroupHorizontalAlign Shortcut VerticalAlign GroupVerticalAlign WarningOnEditRepresentation WarningOnEdit RadioButtonType ItemHeight ItemTitleHeight ItemWidth ColumnsCount EqualColumnsWidth ChoiceList Font TextColor ContextMenu ExtendedTooltip Events",
    "SpreadSheetDocumentField": "DataPath Enabled ReadOnly SkipOnInput UserVisible Visible DefaultItem Title TitleLocation DrawingSelectionShowMode FooterHorizontalAlign GroupHorizontalAlign ToolTip ToolTipRepresentation CommandSet Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HorizontalStretch VerticalStretch ShowGrid ShowHeaders VerticalScrollBar HorizontalScrollBar Protection SelectionShowMode Edit Output PointerType ShowGroups EnableStartDrag EnableDrag BorderColor ShowCellNames ShowRowAndColumnNames ViewScalingMode ContextMenu ExtendedTooltip Events",
    "Table": "Representation Visible UserVisible TitleLocation CommandBarLocation Autofill Enabled TitleHeight ReadOnly SkipOnInput DefaultItem ChangeRowSet ChangeRowOrder Width AutoMaxWidth MaxWidth Height AutoMaxHeight MaxHeight HeightInTableRows HeightControlVariant AutoMaxRowsCount MaxRowsCount ChoiceMode MultipleChoice RowInputMode SelectionMode RowSelectionMode Header FooterHeight HeaderHeight Footer HorizontalScrollBar VerticalScrollBar HorizontalLines VerticalLines UseAlternationRowColor AutoInsertNewRow AutoAddIncomplete AutoMarkIncomplete SearchOnInput InitialListView InitialTreeView HorizontalStretch Output VerticalStretch EnableStartDrag EnableDrag FileDragMode DataPath Font RowPictureDataPath RowsPicture BackColor BorderColor TextColor Title BehaviorOnHorizontalCompression GroupVerticalAlign Shortcut TitleTextColor TitleFont CommandSet ToolTip ToolTipRepresentation SearchStringLocation ViewStatusLocation SearchControlLocation GroupHorizontalAlign CurrentRowUse RefreshRequest AutoRefresh AutoRefreshPeriod Period ChoiceFoldersAndItems RestoreCurrentRow RowFilter TopLevelParent ShowRoot AllowRootChoice UpdateOnDataChange UserSettingsGroup AllowGettingCurrentRowURL ViewMode SettingsNamedItemDetailedRepresentation ContextMenu AutoCommandBar ExtendedTooltip SearchStringAddition ViewStatusAddition SearchControlAddition Events ChildItems",
    "TextDocumentField": "DataPath DefaultItem ReadOnly Title TitleFont TitleLocation EditMode ToolTip Width AutoMaxWidth Font MaxWidth Height AutoMaxHeight ContextMenu ExtendedTooltip Events",
    "TrackBarField": "DataPath Title TitleLocation HorizontalAlign ToolTip ToolTipRepresentation Width AutoMaxWidth HorizontalStretch MaxWidth Height AutoMaxHeight MinValue MarkingAppearance MaxValue LargeStep Step MarkingStep ContextMenu ExtendedTooltip Events",
    "UsualGroup": "UserVisible Visible Enabled ReadOnly EnableContentChange Title TitleTextColor TitleFont ToolTip ToolTipRepresentation Shortcut Width Height HorizontalStretch VerticalStretch GroupHorizontalAlign GroupVerticalAlign Group ChildrenAlign HorizontalSpacing VerticalSpacing HorizontalAlign VerticalAlign Behavior CollapsedRepresentationTitle Collapsed ControlRepresentation Representation CurrentRowUse Format ShowLeftMargin United ChildItemsWidth ShowTitle BackColor ThroughAlign TitleDataPath ExtendedTooltip ChildItems",
}
CHILD_RANK = {t: {c: i for i, c in enumerate(v.split(" "))} for t, v in CHILD_TAG_ORDER.items()}


def get_child_rank(parent_tag, child_tag):
    return CHILD_RANK.get(parent_tag, {}).get(child_tag, -1)


# --- Структура элементов формы (генерируется) ---
# Структура элементов формы: теги членов ChildItems (с версии формата), компаньоны по родителю, свойства типа.
# Источник — XSD xcf-logform 2.10–2.21, корпус БП/ERP и замер загрузки 8.3.24/8.3.27 (#130).
# Перегенерировать: python debug/form-dsl-revision/gen_structure_table.py
FORM_ELEMENT_TAGS = {
    'AutoCommandBar': '2.10',
    'Button': '2.10',
    'ButtonGroup': '2.10',
    'CalendarField': '2.10',
    'ChartField': '2.10',
    'CheckBoxField': '2.10',
    'ColumnGroup': '2.10',
    'CommandBar': '2.10',
    'ContextMenu': '2.10',
    'DendrogramField': '2.10',
    'FormattedDocumentField': '2.10',
    'GanttChartField': '2.10',
    'GeographicalSchemaField': '2.10',
    'GraphicalSchemaField': '2.10',
    'HTMLDocumentField': '2.10',
    'InputField': '2.10',
    'LabelDecoration': '2.10',
    'LabelField': '2.10',
    'PDFDocumentField': '2.14',
    'Page': '2.10',
    'Pages': '2.10',
    'PeriodField': '2.10',
    'PictureDecoration': '2.10',
    'PictureField': '2.10',
    'PlannerField': '2.10',
    'Popup': '2.10',
    'ProgressBarField': '2.10',
    'RadioButtonField': '2.10',
    'RowActionsPanel': '2.21',
    'SearchControlAddition': '2.10',
    'SearchStringAddition': '2.10',
    'SelectedItemsActionsPanel': '2.21',
    'SpreadSheetDocumentField': '2.10',
    'Table': '2.10',
    'TextDocumentField': '2.10',
    'TrackBarField': '2.10',
    'UsualGroup': '2.10',
    'ViewStatusAddition': '2.10',
}
# Опечатки XSD, которые платформа читает как каноничный тег
FORM_ELEMENT_TAG_ALIASES = {
    'LableDecoration': 'LabelDecoration',
    'LableField': 'LabelField',
}
COMPANION_PARENTS = {
    'ContextMenu': 'CalendarField ChartField CheckBoxField DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField ViewStatusAddition',
    'AutoCommandBar': 'Table',
    'SearchStringAddition': 'Table',
    'SearchControlAddition': 'Table',
    'ViewStatusAddition': 'PDFDocumentField Table',
    'RowActionsPanel': 'AutoCommandBar Button ButtonGroup CalendarField ChartField CheckBoxField ColumnGroup CommandBar ContextMenu DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Page Pages PeriodField PictureDecoration PictureField PlannerField Popup ProgressBarField RadioButtonField RowActionsPanel SearchControlAddition SearchStringAddition SelectedItemsActionsPanel SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition',
    'SelectedItemsActionsPanel': 'AutoCommandBar Button ButtonGroup CalendarField ChartField CheckBoxField ColumnGroup CommandBar ContextMenu DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Page Pages PeriodField PictureDecoration PictureField PlannerField Popup ProgressBarField RadioButtonField RowActionsPanel SearchControlAddition SearchStringAddition SelectedItemsActionsPanel SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition',
}
CONTAINER_TYPES = 'AutoCommandBar ButtonGroup ColumnGroup CommandBar ContextMenu Page Pages Popup RowActionsPanel SearchControlAddition SelectedItemsActionsPanel Table UsualGroup'
# Контейнер → допустимые члены его ChildItems
CHILD_ITEMS_PLACEMENT = {
    'AutoCommandBar': 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition',
    'ButtonGroup': 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition',
    'ColumnGroup': 'CheckBoxField ColumnGroup InputField LabelField PictureField',
    'CommandBar': 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition',
    'ContextMenu': 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition',
    'Form': 'Button CalendarField ChartField CheckBoxField CommandBar DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Pages PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition',
    'Page': 'Button CalendarField ChartField CheckBoxField CommandBar DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Pages PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition',
    'Pages': 'Page',
    'Popup': 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition',
    'SearchControlAddition': 'Button ButtonGroup Popup SearchControlAddition SearchStringAddition ViewStatusAddition',
    'Table': 'CheckBoxField ColumnGroup InputField LabelField PictureField',
    'UsualGroup': 'Button CalendarField ChartField CheckBoxField CommandBar DendrogramField FormattedDocumentField GanttChartField GeographicalSchemaField GraphicalSchemaField HTMLDocumentField InputField LabelDecoration LabelField PDFDocumentField Pages PeriodField PictureDecoration PictureField PlannerField ProgressBarField RadioButtonField SearchControlAddition SearchStringAddition SpreadSheetDocumentField Table TextDocumentField TrackBarField UsualGroup ViewStatusAddition',
}
ELEMENT_PROPERTY_TAGS = {
    'AutoCommandBar': 'AppearanceMode Autofill EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalAlign HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'Button': 'AutoMaxHeight AutoMaxWidth BackColor BackPicture BackPictureEffect BorderColor ButtonImportance CardPictureAndTitleAlign Check CommandName CommandUniqueness DataPath DefaultButton DefaultItem Enabled Events Font GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch LocationInCommandBar MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior OnlyInAllActions Parameter Picture PictureHeight PictureLocation PlacementArea Representation RepresentationInContextMenu Shape ShapeRepresentation Shortcut ShowAsCard SkipOnInput TextColor Title TitleHeight ToolTipRepresentation Type UserVisible VerticalStretch Visible Width',
    'ButtonGroup': 'CommandSource EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch PlacementArea ReadOnly Representation Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'CalendarField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BeginOfRepresentationPeriod Border BorderColor CalendarNavigation CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode EnableDrag EnableStartDrag Enabled EndOfRepresentationPeriod Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HeightInMonths HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly SelectionMode Shortcut ShowCurrentDate ShowInCard ShowInFooter ShowInHeader ShowMonthsPanel ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard WidthInMonths',
    'ChartField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'CheckBoxField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CheckBoxType CommandSet DataPath DefaultItem DisplayImportance EditFormat EditMode Enabled EqualItemsWidth Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture HorizontalAlign HorizontalStretch ItemHeight ItemTitleHeight ItemWidth MarkRequiredComplete OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor ThreeState Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TumblerRepresentation UserVisible VerticalAlign Visible WarningOnEdit WarningOnEditRepresentation WidthInCard',
    'ColumnGroup': 'EnableContentChange Enabled Events FixInCard FixingInTable Group GroupHorizontalAlign GroupVerticalAlign HeaderDataPath HeaderFormat HeaderHorizontalAlign HeaderPicture Height HorizontalStretch ReadOnly Shortcut ShowInCard ShowInHeader ShowTitle ShowTitleInCard Title TitleBackColor TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'CommandBar': 'AppearanceMode CommandSource EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalLocation HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'ContextMenu': 'Autofill EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'DendrogramField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'FormattedDocumentField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'GanttChartField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch IntervalsSelectionMode MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowHorizontalLinesFlag ShowInCard ShowInFooter ShowInHeader ShowTitleInCard ShowVerticalLinesFlag SkipOnInput Table TableLocation Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible ValuesSelectionMode VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'GeographicalSchemaField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'GraphicalSchemaField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance Edit EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'HTMLDocumentField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'InputField': 'AllowInputEmptyMultipleValues AllowMultipleValuesDuplicates AppearanceInCard AutoCapitalizationOnTextInput AutoCellHeight AutoChoiceIncomplete AutoCorrectionOnTextInput AutoEditMode AutoMarkIncomplete AutoMaxHeight AutoMaxWidth AutoShowClearButtonMode AutoShowOpenButtonMode AutoWidthInTable AutofillHint AvailableTypes BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark ChoiceButton ChoiceButtonPicture ChoiceButtonRepresentation ChoiceButtonTitle ChoiceFoldersAndItems ChoiceForm ChoiceHistoryOnInput ChoiceList ChoiceListButton ChoiceListHeight ChoiceParameterLinks ChoiceParameters ChooseType ClearButton CommandSet CreateButton DataPath DefaultItem DisplayImportance DropListButton DropListHint DropListWidth EditFormat EditMode EditTextUpdate Enabled Events ExtendedEdit ExtendedEditMultipleValues FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor Format GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HeightControlVariant HorizontalAlign HorizontalStretch IncompleteChoiceMode InputHint ListChoiceMode MarkNegatives MarkRequiredComplete Mask MaxHeight MaxValue MaxWidth MinValue MinWidth MultiLine MultipleValueDataPath MultipleValuePictureDataPath MultipleValuePictureShape MultipleValuePictureSize MultipleValuePresentDataPath MultipleValuesBackColor MultipleValuesFont MultipleValuesHyperlink MultipleValuesPicture MultipleValuesTextColor OnMainServerUnavalableBehavior OnScreenKeyboardReturnKeyText OpenButton PasswordMode Picture QuickChoice ReadOnly Shortcut ShowCheckBoxesInDropList ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput SpecialTextInputMode SpellCheckingOnTextInput SpinButton TextColor TextEdit TextSize TimeChoiceMode Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TypeDomainEnabled TypeLink UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard Wrap',
    'LabelDecoration': 'AutoMaxHeight AutoMaxWidth BackColor Border BorderColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign Height HorizontalAlign HorizontalStretch Hyperlink MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Shortcut SkipOnInput TextColor Title TitleHeight ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible Width',
    'LabelField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackColor Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor Format GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height Hiperlink HorizontalAlign HorizontalStretch MarkNegatives MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior PasswordMode ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UseCopy UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'PDFDocumentField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet CurrentPageNumber DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Orientation Output ReadOnly Scale Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch ViewStatusLocation Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'Page': 'BackColor ChildItemsTitleLocation ChildItemsWidth ChildrenAlign EnableContentChange Enabled Events Format Group GroupHorizontalAlign GroupVerticalAlign Height HorizontalAlign HorizontalSpacing HorizontalStretch Picture ReadOnly ScrollOnCompress Shortcut ShowTitle Title TitleDataPath TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalSpacing VerticalStretch Visible Width',
    'Pages': 'AssociatedTableElementId CurrentRowUse EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch PagesRepresentation ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'PeriodField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'PictureDecoration': 'AutoMaxHeight AutoMaxWidth BackgroundShowMode Border BorderColor EnableDrag EnableStartDrag Enabled Events FileDragMode Font GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch Hyperlink ImageScale MaxHeight MaxWidth MinWidth NonselectedPictureText OnMainServerUnavalableBehavior Picture PictureColor PictureSize Shortcut SkipOnInput TextColor Title ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width Zoomable',
    'PictureField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackgroundShowMode Border BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode EnableDrag EnableStartDrag Enabled Events FileDragMode FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch Hyperlink ImageScale MarkRequiredComplete MaxHeight MaxWidth MinWidth NonselectedPictureText OnMainServerUnavalableBehavior PictureColor PictureSize ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible ValuesPicture VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard Zoomable',
    'PlannerField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DimensionItemHyperlink DisplayImportance EditMode EnableDrag EnableStartDrag Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TimeScaleItemHyperlink Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard WrappedTimeScaleHeaderHyperlink',
    'Popup': 'BackColor BorderColor CommandSource EnableContentChange Enabled Events GroupHorizontalAlign GroupVerticalAlign Height HorizontalStretch Importance Picture PlacementArea ReadOnly Representation Shape ShapeRepresentation Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'ProgressBarField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxValue MaxWidth MinValue MinWidth OnMainServerUnavalableBehavior Orientation ReadOnly Representation Shortcut ShowInCard ShowInFooter ShowInHeader ShowPercent ShowTitleInCard SkipOnInput Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'RadioButtonField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark ChoiceList ColumnsCount CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled EqualColumnsWidth Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture HorizontalAlign HorizontalStretch ItemHeight ItemTitleHeight ItemWidth MarkRequiredComplete OnMainServerUnavalableBehavior Orientation RadioButtonType ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TumblerRepresentation UserVisible VerticalAlign Visible WarningOnEdit WarningOnEditRepresentation WidthInCard',
    'RowActionsPanel': 'AppearanceMode EnableContentChange Enabled Events FillStdCommands GroupHorizontalAlign GroupVerticalAlign HAlign Height HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'SearchControlAddition': 'AdditionSource AutoMaxWidth BackColor BorderColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign HorizontalStretch MaxWidth MinWidth PlacementArea Source TextColor Title ToolTip ToolTipRepresentation UserVisible Visible Width',
    'SearchStringAddition': 'AdditionSource AutoMaxWidth BackColor BorderColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign HorizontalStretch MaxWidth MinWidth PlacementArea Source TextColor Title ToolTip ToolTipRepresentation UserVisible Visible Width',
    'SelectedItemsActionsPanel': 'AppearanceMode EnableContentChange Enabled Events FillStdCommands GroupHorizontalAlign GroupVerticalAlign HAlign Height HorizontalStretch ReadOnly Shortcut Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalStretch Visible Width',
    'SpreadSheetDocumentField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BlackAndWhiteView BorderColor CellActionsButtonViewMode CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance DrawingSelectionShowMode Edit EditMode EnableDrag EnableStartDrag Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalScrollBar HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output PointerType Protection ReadOnly SelectionShowMode Shortcut ShowCellNames ShowGrid ShowGroups ShowHeaders ShowInCard ShowInFooter ShowInHeader ShowRowAndColumnNames ShowTitleInCard SkipOnInput SpreadsheetDocumentMultipleSelectionPanelViewMode Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalScrollBar VerticalStretch ViewScalingMode Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'Table': 'AllowGettingCurrentRowURL AllowRootChoice AutoAddIncomplete AutoInsertNewRow AutoMarkIncomplete AutoMaxCardHeight AutoMaxHeight AutoMaxRowsCount AutoMaxWidth AutoRefresh AutoRefreshPeriod Autofill BackColor BehaviorOnHorizontalCompression BorderColor CardBehaviorOnVerticalCompression CellHyperlinksRepresentation ChangeRowOrder ChangeRowSet ChoiceFoldersAndItems ChoiceMode CommandBarLocation CommandSet ComplexSettingsViewMode CurrentRowUse DataPath DefaultItem EnableDrag EnableStartDrag Enabled Events FileDragMode FixedLeft FixedRight Font Footer FooterHeight GroupHorizontalAlign GroupVerticalAlign Header HeaderHeight Height HeightControlVariant HeightInTableRows HierarchyPanelLocation HorizontalLines HorizontalLinesBWA HorizontalScrollBar HorizontalStretch IconSaveColorsKey InitialListView InitialRowActivation InitialTreeView MarkRequiredComplete MaxCardHeight MaxHeight MaxRowsCount MaxWidth MinWidth MobileDeviceTableType MultipleChoice OnMainServerUnavalableBehavior Output Period ReadOnly RefreshRequest Representation RestoreCurrentRow RowActionsShowType RowFilter RowInputMode RowPictureDataPath RowSelectionMode RowsPicture SaveColors SearchControlLocation SearchOnInput SearchStringLocation SelectionMode SettingsNamedItemDetailedRepresentation ShapeSaveColorsKey Shortcut ShowCommandBar ShowRoot SkipOnInput TextColor Title TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation TopLevelParent TreeSpecialSearch UpdateOnDataChange UseAlternationRowColor UseAlternationRowColorBWA UserSettingsGroup UserVisible VerticalLines VerticalLinesBWA VerticalScrollBar VerticalStretch ViewMode ViewStatusLocation Visible Width',
    'TextDocumentField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BackColor BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable Font FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch MarkRequiredComplete MaxHeight MaxWidth MinWidth OnMainServerUnavalableBehavior Output ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput TextColor Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'TrackBarField': 'AppearanceInCard AutoCellHeight AutoEditMode AutoMaxHeight AutoMaxWidth AutoWidthInTable BorderColor CellHyperlink CellHyperlinkDisplayVariant CellHyperlinkRepresentation CellMark CommandSet DataPath DefaultItem DisplayImportance EditMode Enabled Events FixInCard FixingInTable FooterBackColor FooterDataPath FooterFont FooterHorizontalAlign FooterPicture FooterText FooterTextColor GroupHorizontalAlign GroupVerticalAlign HeaderHorizontalAlign HeaderPicture Height HorizontalAlign HorizontalStretch LargeStep MarkRequiredComplete MarkingAppearance MarkingStep MaxHeight MaxValue MaxWidth MinValue MinWidth OnMainServerUnavalableBehavior Orientation ReadOnly Shortcut ShowInCard ShowInFooter ShowInHeader ShowTitleInCard SkipOnInput Step Title TitleBackColor TitleFont TitleHeight TitleLocation TitleTextColor ToolTip ToolTipRepresentation UserVisible VerticalAlign VerticalStretch Visible WarningOnEdit WarningOnEditRepresentation Width WidthInCard',
    'UsualGroup': 'AssociatedTableElementId BackColor BackPicture BackPictureEffect Behavior CardRepresentationType ChildItemsTitleLocation ChildItemsWidth ChildrenAlign Collapsed CollapsedRepresentationItem CollapsedRepresentationTitle ControlRepresentation CurrentRowUse EnableContentChange Enabled Events Format Group GroupHorizontalAlign GroupVerticalAlign Height HiddenStateTitleBackColor HorizontalAlign HorizontalSpacing HorizontalStretch Hyperlink ReadOnly Representation ScrollOnCompress Shortcut ShowAsCard ShowLeftMargin ShowTitle ThroughAlign Title TitleDataPath TitleFont TitleTextColor ToolTip ToolTipRepresentation United UserVisible VerticalAlign VerticalSpacing VerticalStretch Visible Width',
    'ViewStatusAddition': 'AdditionSource AutoMaxWidth BackColor Border BorderColor ButtonColor Enabled Events Font GroupHorizontalAlign GroupVerticalAlign HorizontalLocation HorizontalStretch MaxWidth MinWidth PlacementArea Source TextColor Title TitleFont TitleTextColor ToolTip ToolTipRepresentation UserVisible Visible Width',
}
# --- /Структура элементов формы ---


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Validate 1C managed form", allow_abbrev=False)
    parser.add_argument("-FormPath", "-Path", required=True)
    parser.add_argument("-Detailed", action="store_true")
    parser.add_argument("-MaxErrors", type=int, default=30)
    args = ci_parse_args(parser)

    form_path = args.FormPath
    detailed = args.Detailed
    max_errors = args.MaxErrors

    if not os.path.isabs(form_path):
        form_path = os.path.join(os.getcwd(), form_path)

    # A: Directory → Ext/Form.xml
    if os.path.isdir(form_path):
        form_path = os.path.join(form_path, 'Ext', 'Form.xml')
    # B1: Missing Ext/ (e.g. Forms/Форма/Form.xml → Forms/Форма/Ext/Form.xml)
    if not os.path.exists(form_path):
        fn = os.path.basename(form_path)
        if fn == 'Form.xml':
            c = os.path.join(os.path.dirname(form_path), 'Ext', fn)
            if os.path.exists(c):
                form_path = c
    # B2: Descriptor (Forms/Форма.xml → Forms/Форма/Ext/Form.xml)
    if not os.path.exists(form_path) and form_path.endswith('.xml'):
        stem = os.path.splitext(os.path.basename(form_path))[0]
        parent = os.path.dirname(form_path)
        c = os.path.join(parent, stem, 'Ext', 'Form.xml')
        if os.path.exists(c):
            form_path = c

    if not os.path.isfile(form_path):
        print(f"File not found: {form_path}", file=sys.stderr)
        sys.exit(1)

    # --- Load XML ---
    try:
        xml_parser = etree.XMLParser(remove_blank_text=True)
        tree = etree.parse(form_path, xml_parser)
    except Exception as e:
        print(f"[ERROR] XML parse error: {e}")
        print()
        print("---")
        print("Errors: 1, Warnings: 0")
        sys.exit(1)

    root = tree.getroot()

    # Detect context: config vs EPF/ERF
    # Ближайший якорь выгрузки вверх от формы. Configuration.xml → конфигурация; корень EPF/ERF → внешняя
    # обработка/отчёт. Ближайший побеждает: автономная обработка остаётся автономной, даже если её
    # исходники лежат внутри дерева с Configuration.xml (типовая раскладка проекта: src/cf рядом с
    # src/epf). Иначе её собственные External*-типы считались бы ошибкой.
    dump_anchor = find_dump_anchor(os.path.dirname(os.path.abspath(form_path)))
    is_config_context = bool(dump_anchor) and os.path.basename(dump_anchor) == 'Configuration.xml'

    errors = 0
    warnings = 0
    ok_count = 0
    stopped = False
    output_lines = []

    def report_ok(msg):
        nonlocal ok_count
        ok_count += 1
        if detailed:
            output_lines.append(f"[OK]    {msg}")

    def report_error(msg):
        nonlocal errors, stopped
        errors += 1
        output_lines.append(f"[ERROR] {msg}")
        if errors >= max_errors:
            stopped = True

    def report_warn(msg):
        nonlocal warnings
        warnings += 1
        output_lines.append(f"[WARN]  {msg}")

    # --- Form name from path ---
    form_name = os.path.splitext(os.path.basename(form_path))[0]
    parent_dir = os.path.dirname(form_path)
    if parent_dir:
        ext_dir = os.path.basename(parent_dir)
        if ext_dir == "Ext":
            form_dir = os.path.dirname(parent_dir)
            if form_dir:
                form_name = os.path.basename(form_dir)

    output_lines.append(f"=== Validation: Form.{form_name} ===")
    output_lines.append("")

    # Early BaseForm detection
    has_base_form = root.find(f"{{{F_NS}}}BaseForm") is not None

    # --- Check 1: Root element and version ---
    if localname(root) != "Form":
        report_error(f"Root element is '{localname(root)}', expected 'Form'")
    else:
        version = root.get("version", "")
        version_rank = format_rank(version)
        if not version:
            report_warn("Form version attribute missing")
        elif version_rank == 0:
            report_error(f"Malformed version '{version}' (expected N.N)")
        elif version_rank < format_rank(FORMAT_VERIFIED_MIN):
            report_warn(f"Format version '{version}' is below the tested range "
                        f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — skills were not verified on it")
        elif version_rank > format_rank(FORMAT_VERIFIED_MAX):
            report_warn(f"Format version '{version}' is above the tested range "
                        f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — skills were not verified on it")
        else:
            report_ok(f"Root element: Form version={version}")

    # --- Check 2: AutoCommandBar ---
    if not stopped:
        acb = root.find(f"{{{F_NS}}}AutoCommandBar")
        if acb is not None:
            acb_name = acb.get("name", "")
            acb_id = acb.get("id", "")
            # id=-1 — соглашение, а не требование: в корпусе УТ/БП/ERP так у 21 094 форм из 21 097,
            # но три формы платформа выгружает с обычным id и грузит их без нареканий. Поэтому
            # предупреждение; ошибка — только если id вовсе не число.
            if acb_id == "-1":
                report_ok(f"AutoCommandBar: name='{acb_name}', id={acb_id}")
            elif re.match(r'^-?\d+$', acb_id):
                report_warn(f"AutoCommandBar id='{acb_id}', usually '-1'")
            else:
                report_error(f"AutoCommandBar id='{acb_id}' is not a number")
        else:
            report_error("AutoCommandBar element missing")

    # --- Collect all elements with IDs ---
    element_ids = {}    # id -> name
    element_names = {}  # name -> id (имена элементов уникальны в пределах формы)
    all_elements = []  # list of dicts {Name, Tag, Id, ParentName, Node}

    def collect_elements(node, parent_name):
        nonlocal stopped
        for child in node:
            if not isinstance(child.tag, str):
                continue

            name = child.get("name", "")
            eid = child.get("id", "")

            if name and eid:
                tag = localname(child)

                all_elements.append({
                    "Name": name,
                    "Tag": tag,
                    "Id": eid,
                    "ParentName": parent_name,
                    "Node": child,
                })

                if eid != "-1":
                    if eid in element_ids:
                        report_error(f"Duplicate element id={eid}: '{name}' and '{element_ids[eid]}'")
                    else:
                        element_ids[eid] = name

                    # Имена элементов уникальны (требование 1С)
                    if name in element_names:
                        report_error(f"Duplicate element name '{name}': id={eid} and id={element_names[name]}")
                    else:
                        element_names[name] = eid

                child_items = child.find(f"{{{F_NS}}}ChildItems")
                if child_items is not None:
                    collect_elements(child_items, name)

    child_items_root = root.find(f"{{{F_NS}}}ChildItems")
    if child_items_root is not None:
        collect_elements(child_items_root, "(root)")

    acb = root.find(f"{{{F_NS}}}AutoCommandBar")
    if acb is not None:
        acb_children = acb.find(f"{{{F_NS}}}ChildItems")
        if acb_children is not None:
            collect_elements(acb_children, "\u0424\u043e\u0440\u043c\u0430\u041a\u043e\u043c\u0430\u043d\u0434\u043d\u0430\u044f\u041f\u0430\u043d\u0435\u043b\u044c")

    # --- Check 3: Unique element IDs ---
    if not stopped:
        # Duplicates already reported during collection
        dup_count = 0
        id_counts = {}
        for el in all_elements:
            eid = el["Id"]
            if eid == "-1":
                continue
            id_counts[eid] = id_counts.get(eid, 0) + 1
        dup_count = sum(1 for v in id_counts.values() if v > 1)
        if dup_count == 0:
            report_ok(f"Unique element IDs: {len(element_ids)} elements")

    # --- Collect attributes (separate ID pool) ---
    attr_map = {}   # name -> node
    attr_ids = {}   # id -> name

    attr_nodes_parent = root.find(f"{{{F_NS}}}Attributes")
    attr_nodes = []
    if attr_nodes_parent is not None:
        attr_nodes = attr_nodes_parent.findall(f"{{{F_NS}}}Attribute")

    for attr in attr_nodes:
        attr_name = attr.get("name", "")
        attr_id = attr.get("id", "")
        if attr_name:
            # Имена реквизитов уникальны среди реквизитов (отдельный неймспейс от элементов)
            if attr_name in attr_map:
                report_error(f"Duplicate attribute name '{attr_name}': id={attr_id} and id={attr_map[attr_name].get('id', '')}")
            attr_map[attr_name] = attr
        if attr_id:
            if attr_id in attr_ids:
                report_error(f"Duplicate attribute id={attr_id}: '{attr_name}' and '{attr_ids[attr_id]}'")
            else:
                attr_ids[attr_id] = attr_name

        # Column IDs uniqueness within parent
        col_ids = {}
        col_names = {}  # имена колонок уникальны в пределах своего реквизита
        columns = attr.find(f"{{{F_NS}}}Columns")
        if columns is not None:
            for col in columns.findall(f"{{{F_NS}}}Column"):
                col_id = col.get("id", "")
                col_name = col.get("name", "")
                if col_id:
                    if col_id in col_ids:
                        report_error(f"Duplicate column id={col_id} in '{attr_name}': '{col_name}' and '{col_ids[col_id]}'")
                    else:
                        col_ids[col_id] = col_name
                if col_name:
                    if col_name in col_names:
                        report_error(f"Duplicate column name '{col_name}' in '{attr_name}': id={col_id} and id={col_names[col_name]}")
                    else:
                        col_names[col_name] = col_id

    if not stopped:
        if attr_ids:
            report_ok(f"Unique attribute IDs: {len(attr_ids)} entries")

    # --- Collect commands (separate ID pool) ---
    cmd_map = {}   # name -> node
    cmd_ids = {}   # id -> name

    cmd_nodes_parent = root.find(f"{{{F_NS}}}Commands")
    cmd_nodes = []
    if cmd_nodes_parent is not None:
        cmd_nodes = cmd_nodes_parent.findall(f"{{{F_NS}}}Command")

    for cmd in cmd_nodes:
        cmd_name = cmd.get("name", "")
        cmd_id = cmd.get("id", "")
        if cmd_name:
            # Имена команд уникальны среди команд (отдельный неймспейс)
            if cmd_name in cmd_map:
                report_error(f"Duplicate command name '{cmd_name}': id={cmd_id} and id={cmd_map[cmd_name].get('id', '')}")
            cmd_map[cmd_name] = cmd
        if cmd_id:
            if cmd_id in cmd_ids:
                report_error(f"Duplicate command id={cmd_id}: '{cmd_name}' and '{cmd_ids[cmd_id]}'")
            else:
                cmd_ids[cmd_id] = cmd_name

    if not stopped:
        if cmd_ids:
            report_ok(f"Unique command IDs: {len(cmd_ids)} entries")

    # --- Collect parameters (separate name pool, без id) ---
    param_names = {}  # name -> True (имена параметров уникальны среди параметров)
    params_parent = root.find(f"{{{F_NS}}}Parameters")
    if params_parent is not None:
        for param in params_parent.findall(f"{{{F_NS}}}Parameter"):
            param_name = param.get("name", "")
            if param_name:
                if param_name in param_names:
                    report_error(f"Duplicate parameter name '{param_name}'")
                else:
                    param_names[param_name] = True

    # --- Check 4: Companion elements ---
    companion_rules = {
        "InputField": ["ContextMenu", "ExtendedTooltip"],
        "CheckBoxField": ["ContextMenu", "ExtendedTooltip"],
        "LabelDecoration": ["ContextMenu", "ExtendedTooltip"],
        "LabelField": ["ContextMenu", "ExtendedTooltip"],
        "PictureDecoration": ["ContextMenu", "ExtendedTooltip"],
        "PictureField": ["ContextMenu", "ExtendedTooltip"],
        "CalendarField": ["ContextMenu", "ExtendedTooltip"],
        "UsualGroup": ["ExtendedTooltip"],
        "Pages": ["ExtendedTooltip"],
        "Page": ["ExtendedTooltip"],
        "Button": ["ExtendedTooltip"],
        "Table": ["ContextMenu", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition"],
    }

    if not stopped:
        companion_errors = 0
        companion_checked = 0

        for el in all_elements:
            if stopped:
                break
            tag = el["Tag"]
            el_name = el["Name"]
            node = el["Node"]

            if tag not in companion_rules:
                continue

            required = companion_rules[tag]
            companion_checked += 1

            for comp_tag in required:
                comp_node = node.find(f"{{{F_NS}}}{comp_tag}")
                if comp_node is None:
                    report_error(f"[{tag}] '{el_name}': missing companion <{comp_tag}>")
                    companion_errors += 1

        if companion_errors == 0 and companion_checked > 0:
            report_ok(f"Companion elements: {companion_checked} elements checked")

    # --- Check 5: DataPath -> Attribute references ---
    if not stopped:
        path_errors = 0
        path_checked = 0
        # \u041f\u0443\u0442\u0438, \u043e \u043a\u043e\u0442\u043e\u0440\u044b\u0445 \u0443\u0436\u0435 \u0441\u043a\u0430\u0437\u0430\u043d\u043e \u043f\u043e\u044d\u043b\u0435\u043c\u0435\u043d\u0442\u043d\u043e, — \u043f\u0440\u043e\u0445\u043e\u0434 \u043f\u043e \u043f\u0440\u043e\u0447\u0438\u043c \u043f\u0440\u0438\u0432\u044f\u0437\u043a\u0430\u043c \u043d\u0438\u0436\u0435 \u0438\u0445 \u043d\u0435 \u043f\u043e\u0432\u0442\u043e\u0440\u044f\u0435\u0442
        reported_paths = set()
        # \u0418\u043c\u0435\u043d\u0430 \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u043e\u0432 — \u0431\u0435\u0437 \u0443\u0447\u0451\u0442\u0430 \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0430, \u043a\u0430\u043a \u0443 \u043f\u043b\u0430\u0442\u0444\u043e\u0440\u043c\u044b
        attr_upper = {n.upper() for n in attr_map}

        # All data-binding tags whose value is an attribute path (root must exist in <Attributes>).
        binding_tags = ["DataPath", "TitleDataPath", "FooterDataPath", "HeaderDataPath",
                        "MultipleValueDataPath", "MultipleValuePresentDataPath", "RowPictureDataPath", "MultipleValuePictureDataPath"]

        skip_tags = {"ContextMenu", "ExtendedTooltip", "AutoCommandBar", "SearchStringAddition", "ViewStatusAddition", "SearchControlAddition"}

        # \u0417\u0430\u0438\u043c\u0441\u0442\u0432\u043e\u0432\u0430\u043d\u043d\u0430\u044f \u0444\u043e\u0440\u043c\u0430 \u0431\u0435\u0437 \u043e\u0441\u043d\u043e\u0432\u043d\u043e\u0433\u043e \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u0430: \u043f\u0443\u0442\u044c \u041e\u0431\u044a\u0435\u043a\u0442.* \u043d\u0430 \u043d\u0435\u0439 — \u0440\u043e\u0432\u043d\u043e \u044d\u0442\u043e\u0442 \u0441\u043b\u0443\u0447\u0430\u0439. \u041f\u043e\u0434\u0441\u043a\u0430\u0437\u043a\u0430 —
        # \u0442\u043e\u043b\u044c\u043a\u043e \u043a \u043a\u043e\u0440\u043d\u044e, \u043a\u043e\u0442\u043e\u0440\u044b\u0439 \u0438 \u0431\u044b\u043b \u0431\u044b \u043e\u0441\u043d\u043e\u0432\u043d\u044b\u043c \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u043e\u043c: \u0438\u043c\u044f \u0438\u0437 <BaseForm>, \u0430 \u043d\u0435\u0442 \u0435\u0433\u043e \u0442\u0430\u043c — \u043e\u0431\u044b\u0447\u043d\u044b\u0435
        # \u0438\u043c\u0435\u043d\u0430 \u043e\u0441\u043d\u043e\u0432\u043d\u043e\u0433\u043e \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u0430. \u041e\u043f\u0435\u0447\u0430\u0442\u043a\u0435 \u0432 \u043a\u043e\u0440\u043d\u0435 \u0438\u043b\u0438 \u0447\u0443\u0436\u043e\u043c\u0443 \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u0443 \u043e\u043d\u0430 \u043d\u0435 \u043d\u0443\u0436\u043d\u0430.
        main_root_names = set()
        if has_base_form:
            main_root_names = {'\u041e\u0411\u042a\u0415\u041a\u0422', '\u0421\u041f\u0418\u0421\u041e\u041a', '\u0417\u0410\u041f\u0418\u0421\u042c', '\u041e\u0422\u0427\u0415\u0422', '\u041d\u0410\u0411\u041e\u0420\u0417\u0410\u041f\u0418\u0421\u0415\u0419', '\u041d\u0410\u0411\u041e\u0420\u041a\u041e\u041d\u0421\u0422\u0410\u041d\u0422',
                               'OBJECT', 'LIST', 'RECORD', 'REPORT', 'RECORDSET', 'CONSTANTSSET'}
            main_base = root.find(f"{{{F_NS}}}BaseForm/{{{F_NS}}}Attributes/{{{F_NS}}}Attribute[{{{F_NS}}}MainAttribute='true']")
            if main_base is not None and main_base.get("name"):
                main_root_names = {main_base.get("name").upper()}
            for attr in attr_nodes:
                ma_node = attr.find(f"{{{F_NS}}}MainAttribute")
                if ma_node is not None and (ma_node.text or "").strip() == "true":
                    main_root_names = set()
                    break

        def no_main_hint(r):
            return " (the borrowed form declares no MainAttribute)" if r.upper() in main_root_names else ""

        for el in all_elements:
            if stopped:
                break
            tag = el["Tag"]
            el_name = el["Name"]
            node = el["Node"]

            if tag in skip_tags:
                continue

            # \u0411\u0430\u0437\u043e\u0432\u044b\u0435 \u044d\u043b\u0435\u043c\u0435\u043d\u0442\u044b \u0437\u0430\u0438\u043c\u0441\u0442\u0432\u043e\u0432\u0430\u043d\u043d\u043e\u0439 \u0444\u043e\u0440\u043c\u044b (id < 1000000) \u043f\u0440\u043e\u0432\u0435\u0440\u044f\u044e\u0442\u0441\u044f \u0442\u0430\u043a \u0436\u0435: \u0432\u0438\u0441\u044f\u0447\u0443\u044e \u043f\u0440\u0438\u0432\u044f\u0437\u043a\u0443
            # \u043f\u043b\u0430\u0442\u0444\u043e\u0440\u043c\u0430 \u043e\u0442\u0432\u0435\u0440\u0433\u0430\u0435\u0442 \u0438 \u043d\u0430 \u043d\u0438\u0445 — «\u041d\u0435\u0432\u0435\u0440\u043d\u044b\u0439 \u043f\u0443\u0442\u044c \u043a \u0434\u0430\u043d\u043d\u044b\u043c».
            for b_tag in binding_tags:
                if stopped:
                    break
                dp_node = node.find(f"{{{F_NS}}}{b_tag}")
                if dp_node is None:
                    continue

                data_path = (dp_node.text or "").strip()
                if not data_path:
                    continue

                # \u0421\u0441\u044b\u043b\u043a\u0438, \u043a\u043e\u0442\u043e\u0440\u044b\u0435 \u041a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0442\u043e\u0440 \u043f\u0438\u0448\u0435\u0442 \u043d\u043e\u043c\u0435\u0440\u0430\u043c\u0438, \u043f\u043e Form.xml \u043d\u0435 \u0440\u0430\u0437\u0440\u0435\u0448\u0438\u0442\u044c: «10», «1/0:<uuid>»,
                # «306:<uuid>/8:<uuid>», «1/-5». \u0418\u043c\u044f \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u0430 \u0441 \u0446\u0438\u0444\u0440\u044b \u043d\u0435 \u043d\u0430\u0447\u0438\u043d\u0430\u0435\u0442\u0441\u044f.
                if data_path[0].isdigit():
                    continue

                path_checked += 1

                clean_path = re.sub(r'\[\d+\]', '', data_path)
                # Strip leading '~' (current row of DynamicList: ~Список.Поле)
                if clean_path.startswith('~'):
                    clean_path = clean_path[1:]
                segments = clean_path.split(".")
                root_attr = segments[0]

                # Resolve Items.<TableName>.CurrentData.<Field>... — table element, not attribute.
                # Разрешаем ЦЕПОЧКОЙ: таблица во вложенной таблице сама привязана через Items.*, и один
                # шаг оставлял корнем литерал «Items» — форма платформы объявлялась битой (типовые
                # НастройкаПравилОбработкиЗаявокСотрудников в БП и ERP).
                items_hops = 0
                items_broken = False
                while root_attr.upper() == 'ITEMS':
                    items_hops += 1
                    if items_hops > 10:          # страховка от кольца ссылок
                        items_broken = True
                        break
                    if len(segments) < 3 or segments[2].upper() != 'CURRENTDATA':
                        report_warn(f"[{tag}] '{el_name}': {b_tag}='{data_path}' — unknown Items.* shape, expected Items.<Table>.CurrentData.*")
                        items_broken = True
                        break
                    table_name = segments[1]
                    table_el = None
                    for candidate in all_elements:
                        if candidate["Tag"] == 'Table' and candidate["Name"] == table_name:
                            table_el = candidate
                            break
                    if table_el is None:
                        report_error(f"[{tag}] '{el_name}': {b_tag}='{data_path}' — table element '{table_name}' not found")
                        path_errors += 1
                        items_broken = True
                        break
                    table_dp_node = table_el["Node"].find(f"{{{F_NS}}}DataPath")
                    if table_dp_node is None or not (table_dp_node.text or "").strip():
                        items_broken = True
                        break
                    table_dp = re.sub(r'\[\d+\]', '', (table_dp_node.text or "").strip())
                    if table_dp.startswith('~'):
                        table_dp = table_dp[1:]
                    segments = table_dp.split(".")
                    root_attr = segments[0]
                if items_broken:
                    continue

                if root_attr.upper() not in attr_upper:
                    report_error(f"[{tag}] '{el_name}': {b_tag}='{data_path}' — attribute '{root_attr}' not found{no_main_hint(root_attr)}")
                    path_errors += 1
                    reported_paths.add(data_path.upper())

        # \u041f\u0440\u043e\u0447\u0438\u0435 \u043f\u0440\u0438\u0432\u044f\u0437\u043a\u0438 — <xr:DataPath> \u0432 <ChoiceParameterLinks>/<TypeLink> \u0438 \u043b\u044e\u0431\u043e\u0439 *DataPath \u0432\u043d\u0435 \u0442\u0435\u0433\u043e\u0432
        # \u0432\u044b\u0448\u0435: \u043a\u043e\u0440\u0435\u043d\u044c \u0442\u043e\u0436\u0435 \u0434\u043e\u043b\u0436\u0435\u043d \u0431\u044b\u0442\u044c \u0440\u0435\u043a\u0432\u0438\u0437\u0438\u0442\u043e\u043c \u0444\u043e\u0440\u043c\u044b. \u0422\u043e\u043b\u044c\u043a\u043e \u0441\u0432\u043e\u044f \u0447\u0430\u0441\u0442\u044c: <BaseForm> — \u0441\u043d\u0438\u043c\u043e\u043a \u0438\u0441\u0445\u043e\u0434\u043d\u043e\u0439
        # \u0444\u043e\u0440\u043c\u044b, \u0435\u0433\u043e \u043f\u043b\u0430\u0442\u0444\u043e\u0440\u043c\u0430 \u0440\u0430\u0437\u0440\u0435\u0448\u0430\u0435\u0442 \u043f\u043e \u043a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0446\u0438\u0438. Items.* \u0438 \u043d\u043e\u043c\u0435\u0440\u043d\u044b\u0435 \u0441\u0441\u044b\u043b\u043a\u0438 — \u043a\u0430\u043a \u0432\u044b\u0448\u0435.
        with open(form_path, "r", encoding="utf-8-sig") as fh:
            own_text = fh.read().split('<BaseForm', 1)[0]
        undeclared = {}   # \u043a\u043e\u0440\u0435\u043d\u044c \u0432 \u0432\u0435\u0440\u0445\u043d\u0435\u043c \u0440\u0435\u0433\u0438\u0441\u0442\u0440\u0435 -> (\u043a\u043e\u0440\u0435\u043d\u044c \u043a\u0430\u043a \u0432 \u043f\u0435\u0440\u0432\u043e\u043c \u043f\u0443\u0442\u0438, \u043f\u0443\u0442\u0438); \u043f\u043e\u0440\u044f\u0434\u043e\u043a — \u043a\u0430\u043a \u0432 \u0444\u0430\u0439\u043b\u0435
        for m in re.finditer(r'<(?:\w+:)?\w*DataPath[^>]*>([^<]+)</(?:\w+:)?\w*DataPath>', own_text):
            dp = m.group(1).strip()
            if not dp or dp[0].isdigit() or dp.upper() in reported_paths:
                continue
            root_attr = re.sub(r'^~', '', re.sub(r'\[\d+\]', '', dp)).split('.', 1)[0]
            if root_attr.upper() == 'ITEMS' or root_attr.upper() in attr_upper:
                continue
            entry = undeclared.setdefault(root_attr.upper(), (root_attr, []))
            if dp not in entry[1]:
                entry[1].append(dp)
        for root_attr, shown in undeclared.values():
            if stopped:
                break
            sample = ", ".join(shown[:3])
            suffix = f" (and {len(shown) - 3} more)" if len(shown) > 3 else ""
            report_error(f"Path(s) rooted at '{root_attr}' — attribute '{root_attr}' not found{no_main_hint(root_attr)}: {sample}{suffix}")
            path_errors += 1

        if path_errors == 0 and path_checked > 0:
            report_ok(f"Data bindings: {path_checked} paths checked")
        elif path_errors == 0:
            report_ok("Data bindings: none")

    # --- Check 6: Button command references ---
    if not stopped:
        cmd_errors = 0
        cmd_checked = 0

        for el in all_elements:
            if stopped:
                break
            tag = el["Tag"]
            el_name = el["Name"]
            node = el["Node"]

            if tag != "Button":
                continue

            cmd_node = node.find(f"{{{F_NS}}}CommandName")
            if cmd_node is None:
                continue

            cmd_ref = (cmd_node.text or "").strip()
            if not cmd_ref:
                continue

            m = re.match(r'^Form\.Command\.(.+)$', cmd_ref)
            if m:
                cmd_name_ref = m.group(1)
                cmd_checked += 1
                if cmd_name_ref not in cmd_map:
                    report_error(f"[Button] '{el_name}': CommandName='{cmd_ref}' \u2014 command '{cmd_name_ref}' not found in Commands")
                    cmd_errors += 1

        if cmd_errors == 0 and cmd_checked > 0:
            report_ok(f"Command references: {cmd_checked} buttons checked")
        elif cmd_checked == 0:
            report_ok("Command references: none")

    # --- Check 7: Events have handler names ---
    if not stopped:
        event_errors = 0
        event_checked = 0

        # Form-level events
        form_events = root.find(f"{{{F_NS}}}Events")
        if form_events is not None:
            for evt in form_events.findall(f"{{{F_NS}}}Event"):
                evt_name = evt.get("name", "")
                handler = (evt.text or "").strip()
                event_checked += 1
                if not handler:
                    report_error(f"Form event '{evt_name}': empty handler name")
                    event_errors += 1

        # Element-level events
        for el in all_elements:
            if stopped:
                break
            tag = el["Tag"]
            el_name = el["Name"]
            node = el["Node"]

            events_node = node.find(f"{{{F_NS}}}Events")
            if events_node is None:
                continue

            for evt in events_node.findall(f"{{{F_NS}}}Event"):
                evt_name = evt.get("name", "")
                handler = (evt.text or "").strip()
                event_checked += 1
                if not handler:
                    report_error(f"[{tag}] '{el_name}' event '{evt_name}': empty handler name")
                    event_errors += 1

        if event_errors == 0 and event_checked > 0:
            report_ok(f"Event handlers: {event_checked} events checked")
        elif event_checked == 0:
            report_ok("Event handlers: none")

    # --- Check 8: Command actions ---
    if not stopped:
        action_errors = 0
        action_checked = 0

        # Предупреждение, а не ошибка: <Action> может назначаться в рантайме
        # (`Команда.Действие = "Подключаемый_…"` в ПриСозданииНаСервере) — приём типовых конфигураций
        # там, где обработчик существует не во всякой сборке. Назначать может и чужой модуль
        # (переопределяемый слой, подключаемые команды), так что по одному Form.xml не решить.
        # Корпус УТ/БП/ERP: 406 таких команд на 275 формах, произведённых платформой.
        for cmd in cmd_nodes:
            if stopped:
                break
            cmd_name = cmd.get("name", "")
            action_node = cmd.find(f"{{{F_NS}}}Action")
            action_checked += 1
            if action_node is None or not (action_node.text or "").strip():
                report_warn(f"Command '{cmd_name}': no Action — handler must be assigned at runtime, otherwise the command does nothing")
                action_errors += 1

        if action_errors == 0 and action_checked > 0:
            report_ok(f"Command actions: {action_checked} commands checked")
        elif action_checked == 0:
            report_ok("Command actions: none")

    # --- Check 9: MainAttribute count ---
    if not stopped:
        main_count = 0
        for attr in attr_nodes:
            main_node = attr.find(f"{{{F_NS}}}MainAttribute")
            if main_node is not None and (main_node.text or "") == "true":
                main_count += 1

        if main_count <= 1:
            main_info = "1 main attribute" if main_count == 1 else "no main attribute"
            report_ok(f"MainAttribute: {main_info}")
        else:
            report_error(f"Multiple MainAttribute=true ({main_count} found, expected 0 or 1)")

    # --- Check 10: Title must be multilingual XML ---
    if not stopped:
        title_node = root.find(f"{{{F_NS}}}Title")
        if title_node is not None:
            v8_items = title_node.findall(f"{{{V8_NS}}}item")
            if len(v8_items) == 0 and (title_node.text or "").strip():
                report_error(f"Form Title is plain text ('{(title_node.text or '').strip()}') \u2014 must be multilingual XML (<v8:item>). Use top-level 'title' key in form-compile DSL.")
            else:
                report_ok("Title: multilingual XML")

    # --- Check 11: Extension-specific validations ---
    base_form_node = root.find(f"{{{F_NS}}}BaseForm")
    is_extension = base_form_node is not None

    if not stopped and is_extension:
        # 11a. BaseForm version
        bf_version = base_form_node.get("version", "")
        if bf_version:
            report_ok(f"BaseForm: version={bf_version}")
        else:
            report_warn("BaseForm: version attribute missing")

        # 11b. callType values validation
        valid_call_types = {"Before", "After", "Override"}
        ct_errors = 0
        ct_checked = 0

        form_events_node = root.find(f"{{{F_NS}}}Events")
        if form_events_node is not None:
            for evt in form_events_node.findall(f"{{{F_NS}}}Event"):
                ct = evt.get("callType", "")
                if ct:
                    ct_checked += 1
                    if ct not in valid_call_types:
                        report_error(f"Form event '{evt.get('name', '')}': invalid callType='{ct}' (expected: Before, After, Override)")
                        ct_errors += 1

        for el in all_elements:
            if stopped:
                break
            events_node = el["Node"].find(f"{{{F_NS}}}Events")
            if events_node is None:
                continue
            for evt in events_node.findall(f"{{{F_NS}}}Event"):
                ct = evt.get("callType", "")
                if ct:
                    ct_checked += 1
                    if ct not in valid_call_types:
                        report_error(f"[{el['Tag']}] '{el['Name']}' event '{evt.get('name', '')}': invalid callType='{ct}'")
                        ct_errors += 1

        for cmd in cmd_nodes:
            if stopped:
                break
            cmd_name = cmd.get("name", "")
            for action in cmd.findall(f"{{{F_NS}}}Action"):
                ct = action.get("callType", "")
                if ct:
                    ct_checked += 1
                    if ct not in valid_call_types:
                        report_error(f"Command '{cmd_name}' Action: invalid callType='{ct}'")
                        ct_errors += 1

        if not stopped and ct_errors == 0 and ct_checked > 0:
            report_ok(f"callType values: {ct_checked} checked")

        # 11c. Extension ID ranges
        base_attr_names = set()
        base_cmd_names = set()

        bf_attrs = base_form_node.find(f"{{{F_NS}}}Attributes")
        if bf_attrs is not None:
            for b_attr in bf_attrs.findall(f"{{{F_NS}}}Attribute"):
                ba_name = b_attr.get("name", "")
                if ba_name:
                    base_attr_names.add(ba_name)

        bf_cmds = base_form_node.find(f"{{{F_NS}}}Commands")
        if bf_cmds is not None:
            for b_cmd in bf_cmds.findall(f"{{{F_NS}}}Command"):
                bc_name = b_cmd.get("name", "")
                if bc_name:
                    base_cmd_names.add(bc_name)

        id_warn_count = 0
        for attr in attr_nodes:
            a_name = attr.get("name", "")
            a_id = attr.get("id", "")
            if a_name and a_name not in base_attr_names and a_id:
                try:
                    int_id = int(a_id)
                    if int_id < 1000000:
                        report_warn(f"Attribute '{a_name}' (id={a_id}): extension-added attribute has id < 1000000")
                        id_warn_count += 1
                except (ValueError, TypeError):
                    pass

        for cmd in cmd_nodes:
            c_name = cmd.get("name", "")
            c_id = cmd.get("id", "")
            if c_name and c_name not in base_cmd_names and c_id:
                try:
                    int_id = int(c_id)
                    if int_id < 1000000:
                        report_warn(f"Command '{c_name}' (id={c_id}): extension-added command has id < 1000000")
                        id_warn_count += 1
                except (ValueError, TypeError):
                    pass

        if not stopped and id_warn_count == 0:
            ext_attr_count = sum(1 for a in attr_nodes if a.get("name", "") not in base_attr_names)
            ext_cmd_count = sum(1 for c in cmd_nodes if c.get("name", "") not in base_cmd_names)
            if (ext_attr_count + ext_cmd_count) > 0:
                report_ok(f"Extension ID ranges: {ext_attr_count} attr(s), {ext_cmd_count} cmd(s) \u2014 all >= 1000000")

    # Check callType without BaseForm
    if not stopped and not is_extension:
        call_type_without_base = False
        fe_node = root.find(f"{{{F_NS}}}Events")
        if fe_node is not None:
            for evt in fe_node.findall(f"{{{F_NS}}}Event"):
                if evt.get("callType"):
                    call_type_without_base = True
                    break
        if not call_type_without_base:
            for cmd in cmd_nodes:
                for action in cmd.findall(f"{{{F_NS}}}Action"):
                    if action.get("callType"):
                        call_type_without_base = True
                        break
                if call_type_without_base:
                    break
        if call_type_without_base:
            report_warn("callType attributes found but no BaseForm \u2014 possible incorrect structure")

    # --- Check 12: Type validation ---
    if not stopped:
        type_nodes = root.xpath('//v8:Type', namespaces={'v8': V8_NS})
        type_error_count = 0
        type_warn_count = 0
        type_count = len(type_nodes)

        for tn in type_nodes:
            if stopped:
                break
            tv = (tn.text or "").strip()
            if not tv:
                continue

            if tv in KNOWN_INVALID_TYPES:
                report_error(f'12. Type "{tv}": invalid runtime/UI type (not valid in XDTO schema)')
                type_error_count += 1
            elif tv in VALID_CLOSED_TYPES:
                pass  # OK
            elif tv.startswith("cfg:"):
                suffix = tv[4:]  # after "cfg:"
                prefix = suffix.split(".")[0]
                # Тип без имени объекта: динамический список, набор констант, любой отчёт — ровно те три,
                # что встречаются в формах корпуса (УТ, ERP, БП, УНФ); иное без имени — вероятная опечатка
                if ("." in suffix and prefix in VALID_CFG_PREFIXES) or suffix in ("DynamicList", "ConstantsSet", "ReportObject"):
                    # ExternalDataProcessorObject/ExternalReportObject valid only in EPF/ERF context
                    if is_config_context and prefix in ('ExternalDataProcessorObject', 'ExternalReportObject'):
                        report_error(f'12. Type "{tv}": External* type in configuration context (use DataProcessorObject/ReportObject instead)')
                        type_error_count += 1
                else:
                    report_warn(f'12. Type "{tv}": unrecognized cfg prefix')
                    type_warn_count += 1
            elif ":" in tv:
                pass  # unknown namespace, pass through
            else:
                report_warn(f'12. Type "{tv}": bare type without namespace prefix')
                type_warn_count += 1

        if type_error_count == 0 and type_warn_count == 0:
            if type_count > 0:
                report_ok(f'12. Types: {type_count} values, all valid')
            else:
                report_ok('12. Types: no type values to check')

    # --- Check 13: префиксы в значениях объявлены в самом файле ---
    # `cfg:DataProcessorObject.X` в <v8:Type> при незадекларированном xmlns:cfg — валидный XML, который
    # платформа не читает вовсе: «Исключение XDTO произошло при чтении файла». Ошибка типична для
    # рукописного XML: префикс скопирован из чужой формы, а объявление в корне забыто. Область видимости
    # считаем по узлу (nsmap элемента), а не по корню: локальная xmlns на элементе законна.
    if not stopped:
        prefix_errors = 0
        prefix_checked = 0
        prefix_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_.-]*):.+$')

        for node in root.iter():
            if not isinstance(node.tag, str):
                continue
            ln = localname(node)
            values = []
            if ln in ('Type', 'TypeSet'):
                values.append((node.text or '').strip())
            xsi_type = node.get(f'{{{"http://www.w3.org/2001/XMLSchema-instance"}}}type')
            if xsi_type:
                values.append(xsi_type.strip())
            for val in values:
                if not val:
                    continue
                m = prefix_re.match(val)
                if not m:
                    continue
                prefix_checked += 1
                pfx = m.group(1)
                if pfx not in node.nsmap:
                    kind = "xsi:type" if val == xsi_type else "Type"
                    report_error(f"13. {kind} '{val}': namespace prefix '{pfx}:' is not declared "
                                 "— the platform cannot read the file (XDTO)")
                    prefix_errors += 1

        if prefix_checked == 0:
            report_ok('13. Namespace prefixes: nothing to check')
        elif prefix_errors == 0:
            report_ok(f'13. Namespace prefixes: {prefix_checked} values, all declared')

    # --- Check 14: версия формата формы — как у её дескриптора; сверка с выгрузкой ---
    # Тело формы и дескриптор Forms/<Имя>.xml (у общей формы — CommonForms/<Имя>.xml) платформа загружает
    # только в одной версии: «Версия формата загружаемого файла … отличается от версии формата ранее
    # загруженных файлов». С остальной выгрузкой форма может расходиться — платформа такое грузит, это
    # лишь неоднородность выгрузки (типично после мержа веток, выгруженных разными платформами).
    if not stopped:
        form_ver = root.get('version', '')
        owner_path = ext_body_owner(os.path.abspath(form_path))
        owner_ver = root_version(owner_path) if owner_path else None
        dump_ver = root_version(dump_anchor) if dump_anchor else None

        # У заимствованной формы расширения второй штамп — <BaseForm version=…>; платформа сверяет с дескриптором и его.
        base_form_ver = ''
        for ch in root:
            if isinstance(ch.tag, str) and etree.QName(ch.tag).localname == 'BaseForm':
                base_form_ver = ch.get('version', '')
                break

        if not form_ver:
            report_ok('14. Format version: not comparable')
        elif owner_ver and form_ver != owner_ver:
            report_error(f'14. Format version {form_ver} differs from the form descriptor '
                         f'{os.path.basename(owner_path)} ({owner_ver}) '
                         '— the platform refuses to load parts of one object in different formats')
        elif owner_ver and base_form_ver and base_form_ver != owner_ver:
            report_error(f'14. <BaseForm> format version {base_form_ver} differs from the form descriptor '
                         f'{os.path.basename(owner_path)} ({owner_ver}) '
                         '— the platform refuses to load parts of one object in different formats')
        elif dump_ver and form_ver != dump_ver:
            report_warn(f'14. Format version {form_ver} differs from the dump ({dump_ver}) — the platform loads it, '
                        'but the dump is no longer uniform (typical after merging branches dumped by different platforms)')
        elif owner_ver or dump_ver:
            report_ok(f'14. Format version: {form_ver}, matches the descriptor and the dump')

    # Узлы формы с типом из scope (вне <BaseForm> — его пишет платформа): корень, именованные узлы и
    # настройки динамического списка (без имени — подпись по реквизиту; Settings у ValueList/Planner/Chart —
    # не список). Перечисления проверяются по enum_scope_types, порядок — по CHILD_TAG_ORDER.
    def enum_check_nodes(scope):
        out = [(root, 'Form', 'Form')]
        for n in root.iter():
            if not isinstance(n.tag, str) or (n.get('name') is None and not n.tag.endswith('}Settings')):
                continue
            q = etree.QName(n.tag)
            if q.namespace != F_NS or q.localname not in scope:
                continue
            par = n.getparent()
            if n.get('name') is None and n.get('{http://www.w3.org/2001/XMLSchema-instance}type') != 'DynamicList':
                continue
            if any(isinstance(a.tag, str) and etree.QName(a.tag).localname == 'BaseForm' for a in n.iterancestors()):
                continue
            label = (f"{q.localname} '{n.get('name')}'" if n.get('name') is not None
                     else f"{q.localname} of {etree.QName(par.tag).localname} '{par.get('name', '')}'")
            out.append((n, q.localname, label))
        return out

    # --- Check 15: значения свойств-перечислений ---
    # Платформа читает перечисление по точному имени: значение в другом регистре или вне списка — ошибка
    # загрузки XDTO. Старое имя (синоним) платформа примет и переведёт в современное — предупреждение.
    if not stopped:
        enum_checked = 0
        check15_ok = True
        for node, typ, label in enum_check_nodes(enum_scope_types):
            if stopped:
                break
            for c in node:
                if not isinstance(c.tag, str) or etree.QName(c.tag).namespace != F_NS:
                    continue
                if any(isinstance(x.tag, str) for x in c) or not (c.text or ''):
                    continue
                prop = etree.QName(c.tag).localname
                allowed = valid_enum_values.get(f'{typ}.{prop}') or valid_enum_values.get(prop)
                if not allowed:
                    continue
                val = c.text
                enum_checked += 1
                if val in enum_value_aliases and enum_value_aliases[val] in allowed and val in allowed:
                    report_warn(f"15. {label}: {prop} '{val}' is an old name — the platform converts it to '{enum_value_aliases[val]}'")
                elif val not in allowed:
                    hint = [a for a in allowed if a.lower() == val.lower()]
                    if hint:
                        report_error(f"15. {label}: {prop} '{val}' — wrong case, the platform will not load it; use '{hint[0]}'")
                    else:
                        # Значение из соседнего перечисления (у кнопки PictureAndText, у команды TextPicture) — подсказать замену
                        syn = enum_input_synonyms.get(f'{typ}.{prop}') or {}
                        use = [b for a, b in syn.items() if a.lower() == val.lower()]
                        if use:
                            report_error(f"15. {label}: {prop} '{val}' is not valid for {typ}, the platform will not load it; use '{use[0]}'")
                        else:
                            report_error(f"15. {label}: {prop} has invalid value '{val}' (allowed: {', '.join(allowed)})")
                    check15_ok = False
        if check15_ok:
            report_ok(f'15. Enum values: {enum_checked} checked')

    # --- Check 16: порядок свойств элемента ---
    # Платформа пишет дочерние теги в своём порядке (таблица — по корпусу выгрузок). Чужой порядок она
    # принимает и переставляет при выгрузке — предупреждение, а не ошибка.
    if not stopped:
        order_bad = 0
        for node, typ, _ in enum_check_nodes(CHILD_TAG_ORDER):
            if typ == 'Form':
                continue
            prev, prev_rank = None, -1
            for c in node:
                if not isinstance(c.tag, str):
                    continue
                r = get_child_rank(typ, etree.QName(c.tag).localname)
                if r < 0:
                    continue
                if r < prev_rank:
                    report_warn(f"16. {typ} '{node.get('name', '')}': <{etree.QName(c.tag).localname}> stands after <{prev}>, the platform writes it before — it reorders them on dump")
                    order_bad += 1
                    break
                prev, prev_rank = etree.QName(c.tag).localname, r
        if order_bad == 0:
            report_ok('16. Property order: matches the platform')

    # --- Check 17: настройки динамического списка в режиме совместимости ниже 8.3.19 ---
    # Field / CalculatedField / Parameter списка такая конфигурация принимает при загрузке и хранит в
    # базе, но в выгрузку XML не пишет — исходник с ними после выгрузки «теряет» их в диффе. Только для
    # конфигурации: у внешней обработки режим базы на форму не влияет.
    if not stopped and is_config_context:
        with open(dump_anchor, 'r', encoding='utf-8-sig') as f:
            cfg_head = f.read(65536)
        m = re.search(r'<CompatibilityMode>([^<]+)</CompatibilityMode>', cfg_head)
        # Расширение: своего CompatibilityMode нет, форму ведёт его собственный режим. В основной
        # конфигурации этот тег — режим для её расширений, не её собственный: только для расширения.
        if not m and '<ConfigurationExtensionPurpose>' in cfg_head:
            m = re.search(r'<ConfigurationExtensionCompatibilityMode>([^<]+)</ConfigurationExtensionCompatibilityMode>', cfg_head)
        compat_mode = m.group(1).strip() if m else ''
        m = re.match(r'^Version(\d+)_(\d+)(?:_(\d+))?$', compat_mode)   # и двухчастный Version8_1
        compat_rank = int(m.group(1)) * 10000 + int(m.group(2)) * 100 + int(m.group(3) or 0) if m else 0
        if 0 < compat_rank < 80319:
            dyn_bad = 0
            for a in attr_nodes:
                st = a.find(f"{{{F_NS}}}Settings")
                if st is None or st.get('{http://www.w3.org/2001/XMLSchema-instance}type') != 'DynamicList':
                    continue
                if any(isinstance(c.tag, str) and etree.QName(c.tag).localname in ('Field', 'CalculatedField', 'Parameter')
                       and etree.QName(c.tag).namespace == F_NS for c in st):
                    report_warn(f"17. Dynamic list '{a.get('name', '')}': Field/CalculatedField/Parameter under compatibility mode {compat_mode} (< 8.3.19) are kept in the infobase but not written to the XML dump")
                    dyn_bad += 1
            if dyn_bad == 0:
                report_ok(f'17. Dynamic list settings: dumpable under {compat_mode}')

    # Члены ChildItems вне <BaseForm> (его пишет платформа) — элементы формы, командных панелей и меню
    def child_items_members():
        return root.xpath("//f:ChildItems/*[not(ancestor::*[local-name()='BaseForm'])]", namespaces={'f': F_NS})

    def ci_key(table, tag):
        return next((k for k in table if k.lower() == tag.lower()), None)

    companion_tags = list(COMPANION_PARENTS)
    # Списки таблиц — множества, разобранные один раз
    companion_parent_sets = {k: set(v.split(' ')) for k, v in COMPANION_PARENTS.items()}
    property_sets = {k: set(v.split(' ')) for k, v in ELEMENT_PROPERTY_TAGS.items()}
    placement_sets = {k: set(v.split(' ')) for k, v in CHILD_ITEMS_PLACEMENT.items()}

    def is_form_child(c):
        return isinstance(c.tag, str) and etree.QName(c.tag).namespace == F_NS

    # --- Check 18: тег элемента формы ---
    # Тег члена ChildItems — из словаря формата (XSD logform) и не новее версии формата формы.
    members = child_items_members() if not stopped else []
    member_types = {}   # узел → каноничный тег (для 19/20; незнакомые теги не проверяются дальше)
    if not stopped:
        check18_ok = True
        form_ver = root.get("version", "")
        form_rank = format_rank(form_ver)
        for m in members:
            if stopped:
                break
            tag = localname(m)
            if m.get('name') is not None:
                label = f"<{tag}> '{m.get('name')}'"
            elif m.get('id') is not None:
                label = f"<{tag}> id={m.get('id')}"
            else:
                label = f"<{tag}>"
            # Без name/id платформа загружает элемент с пустым именем / id=0
            missing = [a for a in ('name', 'id') if not m.get(a)]
            if missing:
                report_error(f"18. {label}: missing {' and '.join(missing)} attribute{'s' if len(missing) > 1 else ''}")
                check18_ok = False
            if tag in FORM_ELEMENT_TAGS:
                since = FORM_ELEMENT_TAGS[tag]
                if form_rank > 0 and format_rank(since) > form_rank:
                    report_error(f"18. {label}: not available in format {form_ver} (since {since})")
                    check18_ok = False
                else:
                    member_types[m] = tag
            elif tag in FORM_ELEMENT_TAG_ALIASES:
                report_warn(f"18. {label} is an old name — the platform reads it as <{FORM_ELEMENT_TAG_ALIASES[tag]}>")
                member_types[m] = FORM_ELEMENT_TAG_ALIASES[tag]
            else:
                hint = ci_key(FORM_ELEMENT_TAGS, tag)
                if not hint:
                    alias_key = ci_key(FORM_ELEMENT_TAG_ALIASES, tag)
                    hint = FORM_ELEMENT_TAG_ALIASES[alias_key] if alias_key else None
                if hint:
                    report_error(f"18. {label}: wrong case, use <{hint}>")
                else:
                    report_error(f"18. {label} is not a form element type")
                check18_ok = False
        if check18_ok:
            report_ok(f"18. Element types: {len(members)} checked")

    # --- Check 19: компаньоны элемента ---
    # Контекстное меню, командная панель и дополнения таблицы бывают только у своих типов; каждый — один.
    if not stopped:
        check19_ok = True
        for m in members:
            if stopped:
                break
            if m not in member_types:
                continue
            typ = member_types[m]
            seen = set()
            for c in m:
                if not is_form_child(c):
                    continue
                ct = localname(c)
                if ct != 'ExtendedTooltip' and ct not in companion_tags:
                    continue
                if ct in seen:
                    report_error(f"19. {typ} '{m.get('name', '')}': duplicate <{ct}>")
                    check19_ok = False
                    continue
                seen.add(ct)
                if ct == 'ExtendedTooltip':
                    continue
                if typ not in companion_parent_sets[ct]:
                    report_error(f"19. {typ} '{m.get('name', '')}' cannot have <{ct}>")
                    check19_ok = False
        if check19_ok:
            report_ok("19. Companions: match element types")

    # --- Check 20: свойства элемента ---
    # Дочерний тег — свойство своего типа (корпус выгрузок ∪ XSD); ChildItems — только у контейнеров.
    if not stopped:
        check20_ok = True
        containers = CONTAINER_TYPES.split(' ')
        for m in members:
            if stopped:
                break
            if m not in member_types:
                continue
            typ = member_types[m]
            allowed = property_sets.get(typ)
            for c in m:
                if not is_form_child(c):
                    continue
                pt = localname(c)
                if pt == 'ExtendedTooltip' or pt in companion_tags:
                    continue
                if pt == 'ChildItems':
                    if typ not in containers:
                        report_error(f"20. {typ} '{m.get('name', '')}' cannot have <ChildItems>")
                        check20_ok = False
                    continue
                if allowed is None or pt in allowed:
                    continue
                hint = sorted(a for a in allowed if a.lower() == pt.lower())
                if hint:
                    report_warn(f"20. {typ} '{m.get('name', '')}': <{pt}> — wrong case, use <{hint[0]}>")
                else:
                    report_warn(f"20. {typ} '{m.get('name', '')}': <{pt}> is not a property of {typ}")
                check20_ok = False
        if check20_ok:
            report_ok("20. Element properties: match element types")

    # --- Check 21: размещение элемента в контейнере ---
    # Что можно положить в контейнер — по правилам редактора форм (их отпечаток — корпус выгрузок):
    # в Pages — только страницы, колонка таблицы — поле или группа колонок, подменю и группа кнопок —
    # только в командной панели. Платформа такое загружает, поэтому предупреждение.
    if not stopped:
        check21_ok = True
        for m in members:
            if stopped:
                break
            if m not in member_types:
                continue
            owner = m.getparent().getparent()
            # Владелец — элемент (каноничный тег) или компаньон (ContextMenu, AutoCommandBar) — тег как есть
            owner_type = 'Form' if owner is root else member_types.get(owner, localname(owner))
            allowed = placement_sets.get(owner_type)
            if not allowed or member_types[m] in allowed:
                continue
            where = 'the form' if owner_type == 'Form' else f"{owner_type} '{owner.get('name', '')}'"
            report_warn(f"21. {member_types[m]} '{m.get('name', '')}' cannot be placed in {where}")
            check21_ok = False
        if check21_ok:
            report_ok("21. Element placement: match containers")

    # --- Finalize ---
    checks = ok_count + errors + warnings
    if errors == 0 and warnings == 0 and not detailed:
        result = f"=== Validation OK: Form.{form_name} ({checks} checks) ==="
    else:
        output_lines.append("")
        output_lines.append(f"=== Result: {errors} errors, {warnings} warnings ({checks} checks) ===")
        result = "\n".join(output_lines)

    print(result)

    if errors > 0:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
