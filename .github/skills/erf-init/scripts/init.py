#!/usr/bin/env python3
# erf-init v1.8 — Init 1C external report scaffold (+write_xml_file/write_utf8_bom: общий эталон записи)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""Generates minimal XML source files for a 1C external report."""
import sys, os, re, argparse, uuid

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


def esc_xml_text(s):
    # Эскейп ТЕКСТА элемента: только & < > — кавычку и апостроф платформа держит сырыми.
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

def new_uuid():
    return str(uuid.uuid4())

def write_utf8_bom(path, content):
    # newline='' — без трансляции: иначе текстовый режим Python дал бы CRLF на Windows
    # и LF на macOS, то есть вывод навыка зависел бы от ОС.
    with open(path, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(content)


def write_xml_file(path, content):
    """XML в каноне выгрузки Конфигуратора: CRLF в разделителях, без перевода в конце.

    Копия этой функции есть в каждом навыке-эмиттере (навыки автономны). Держать
    копии одинаковыми — сознательно: разошедшиеся копии сводят на нет весь смысл.
    """
    text = content.replace('\r\n', '\n').replace('\n', '\r\n').rstrip('\r\n')
    write_utf8_bom(path, text)


def format_rank(ver):
    """"2.20" → 220, "2.9" → 209. Строковое сравнение неверно ("2.9" > "2.17")."""
    m = re.match(r'^(\d+)\.(\d+)$', ver or '')
    return int(m.group(1)) * 100 + int(m.group(2)) if m else 0


FORMAT_VERIFIED_MIN = "2.17"
FORMAT_VERIFIED_MAX = "2.21"


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Init 1C external report scaffold', allow_abbrev=False)
    parser.add_argument('-Name', dest='Name', required=True)
    parser.add_argument('-Synonym', dest='Synonym', default=None)
    parser.add_argument('-SrcDir', dest='SrcDir', default='src')
    # Версия формата выгрузки. Своей конфигурации у автономного объекта нет, наследовать
    # версию неоткуда — поэтому её задают явно. Формы, макеты и справку внутри объекта
    # навыки берут уже отсюда: их детектор читает version из корня этого файла.
    parser.add_argument('-FormatVersion', dest='FormatVersion', default='2.17')
    parser.add_argument('-WithSKD', dest='WithSKD', action='store_true')
    args = ci_parse_args(parser)

    # Проверенный диапазон: 2.17 (8.3.24) … 2.21 (8.5). Полная лестница —
    # docs/1c-configuration-spec.md, «Лестница версий». Версии ниже 2.17 (платформы 8.3.23 и
    # старше) реальны, поэтому запретом их не закрываем: за пределами диапазона —
    # ПРЕДУПРЕЖДЕНИЕ, скаффолд всё равно выпускается. Ошибка — только на нечисловое значение.
    format_rank_value = format_rank(args.FormatVersion)
    if format_rank_value == 0:
        print(f"Malformed -FormatVersion '{args.FormatVersion}' (expected N.N, e.g. 2.17)", file=sys.stderr)
        sys.exit(1)
    if not (format_rank(FORMAT_VERIFIED_MIN) <= format_rank_value <= format_rank(FORMAT_VERIFIED_MAX)):
        print(f"WARNING: Format version '{args.FormatVersion}' is outside the tested range "
              f"{FORMAT_VERIFIED_MIN}-{FORMAT_VERIFIED_MAX} — the scaffold is emitted as requested "
              f"but was not verified on that platform", file=sys.stderr)

    name = args.Name
    synonym = args.Synonym if args.Synonym else name
    src_dir = args.SrcDir

    uuid1 = new_uuid()
    uuid2 = new_uuid()
    uuid3 = new_uuid()
    uuid4 = new_uuid()

    # Объявления пространств имён — одной переменной: места эмиссии её только подставляют.
    xmlns_decl = (
        'xmlns="http://v8.1c.ru/8.3/MDClasses"'
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
    )
    format_version = args.FormatVersion
    # 2.21 (8.5) добавила в шапку пространство палитры. Вставляем НА МЕСТО (после lf, перед
    # style): платформа держит объявления по алфавиту, дописать в конец нельзя.
    if format_rank(format_version) >= 221:
        xmlns_decl = xmlns_decl.replace(
            ' xmlns:style=',
            ' xmlns:pal="http://v8.1c.ru/8.1/data/ui/colors/palette" xmlns:style=')

    # --- Properties ---
    main_dcs_value = ""
    child_objects_content = ""

    if args.WithSKD:
        main_dcs_value = f"ExternalReport.{name}.Template.ОсновнаяСхемаКомпоновкиДанных"
        child_objects_content = f"\n\t\t\t<Template>ОсновнаяСхемаКомпоновкиДанных</Template>\n"

    main_dcs_element = f"<MainDataCompositionSchema>{main_dcs_value}</MainDataCompositionSchema>" if main_dcs_value else "<MainDataCompositionSchema/>"
    child_objects_xml = f"<ChildObjects>{child_objects_content}\t\t</ChildObjects>" if child_objects_content else "<ChildObjects/>"

    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {xmlns_decl} version="{format_version}">
\t<ExternalReport uuid="{uuid1}">
\t\t<InternalInfo>
\t\t\t<xr:ContainedObject>
\t\t\t\t<xr:ClassId>e41aff26-25cf-4bb6-b6c1-3f478a75f374</xr:ClassId>
\t\t\t\t<xr:ObjectId>{uuid2}</xr:ObjectId>
\t\t\t</xr:ContainedObject>
\t\t\t<xr:GeneratedType name="ExternalReportObject.{name}" category="Object">
\t\t\t\t<xr:TypeId>{uuid3}</xr:TypeId>
\t\t\t\t<xr:ValueId>{uuid4}</xr:ValueId>
\t\t\t</xr:GeneratedType>
\t\t</InternalInfo>
\t\t<Properties>
\t\t\t<Name>{esc_xml_text(name)}</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>{esc_xml_text(synonym)}</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<DefaultForm/>
\t\t\t<AuxiliaryForm/>
\t\t\t{main_dcs_element}
\t\t\t<DefaultSettingsForm/>
\t\t\t<AuxiliarySettingsForm/>
\t\t\t<DefaultVariantForm/>
\t\t\t<VariantsStorage/>
\t\t\t<SettingsStorage/>
\t\t</Properties>
\t\t{child_objects_xml}
\t</ExternalReport>
</MetaDataObject>'''

    root_file = os.path.join(src_dir, f"{name}.xml")
    report_dir = os.path.join(src_dir, name)

    if os.path.exists(root_file):
        print(f"Файл уже существует: {root_file}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(src_dir, exist_ok=True)
    ext_dir = os.path.join(report_dir, "Ext")
    os.makedirs(ext_dir, exist_ok=True)

    write_xml_file(os.path.join(os.path.abspath(src_dir), f"{name}.xml"), xml)

    # --- Модуль объекта ---
    module_bsl = """\
#Область ОписаниеПеременных

#КонецОбласти

#Область ПрограммныйИнтерфейс

#КонецОбласти

#Область СлужебныеПроцедурыИФункции

#КонецОбласти"""

    module_path = os.path.join(ext_dir, "ObjectModule.bsl")
    # Модуль пишем в каноне платформы: CRLF в разделителях строк (корпус: 2643 CRLF,
    # чисто-LF 0 из 3001). Хвостовой перевод НЕ навязываем — у платформы он
    # неканоничен (1235 модулей с ним, 766 без).
    write_utf8_bom(module_path, module_bsl.replace('\r\n', '\n').replace('\n', '\r\n'))

    print(f"[OK] Создан отчёт: {root_file}")
    print(f"     Каталог: {report_dir}")
    print(f"     Модуль:  {module_path}")

    # --- СКД-макет ---
    if args.WithSKD:
        templates_dir = os.path.join(report_dir, "Templates")
        skd_name = "ОсновнаяСхемаКомпоновкиДанных"
        skd_meta_path = os.path.join(templates_dir, f"{skd_name}.xml")
        skd_ext_dir = os.path.join(templates_dir, skd_name, "Ext")
        os.makedirs(skd_ext_dir, exist_ok=True)

        skd_uuid = new_uuid()

        skd_meta_xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<MetaDataObject {xmlns_decl} version="{format_version}">
\t<Template uuid="{skd_uuid}">
\t\t<Properties>
\t\t\t<Name>{skd_name}</Name>
\t\t\t<Synonym>
\t\t\t\t<v8:item>
\t\t\t\t\t<v8:lang>ru</v8:lang>
\t\t\t\t\t<v8:content>Основная схема компоновки данных</v8:content>
\t\t\t\t</v8:item>
\t\t\t</Synonym>
\t\t\t<Comment/>
\t\t\t<TemplateType>DataCompositionSchema</TemplateType>
\t\t</Properties>
\t</Template>
</MetaDataObject>'''

        write_xml_file(skd_meta_path, skd_meta_xml)

        skd_content = '''<?xml version="1.0" encoding="UTF-8"?>
<DataCompositionSchema xmlns="http://v8.1c.ru/8.1/data-composition-system/schema"
\t\txmlns:dcscom="http://v8.1c.ru/8.1/data-composition-system/common"
\t\txmlns:dcscor="http://v8.1c.ru/8.1/data-composition-system/core"
\t\txmlns:dcsset="http://v8.1c.ru/8.1/data-composition-system/settings"
\t\txmlns:v8="http://v8.1c.ru/8.1/data/core"
\t\txmlns:v8ui="http://v8.1c.ru/8.1/data/ui"
\t\txmlns:xs="http://www.w3.org/2001/XMLSchema"
\t\txmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
\t<dataSource>
\t\t<name>ИсточникДанных1</name>
\t\t<dataSourceType>Local</dataSourceType>
\t</dataSource>
</DataCompositionSchema>'''

        skd_file_path = os.path.join(skd_ext_dir, "Template.xml")
        write_xml_file(skd_file_path, skd_content)

        print(f"     СКД:     {skd_meta_path}")
        print(f"     Тело:    {skd_file_path}")

if __name__ == '__main__':
    main()
