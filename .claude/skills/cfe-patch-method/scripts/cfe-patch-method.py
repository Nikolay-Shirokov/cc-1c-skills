#!/usr/bin/env python3
# cfe-patch-method v1.0 — Generate method interceptor for 1C extension (CFE)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import sys
import xml.etree.ElementTree as ET


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(
        description="Generate method interceptor for 1C extension (CFE)",
        allow_abbrev=False,
    )
    parser.add_argument("-ExtensionPath", required=True)
    parser.add_argument("-ModulePath", required=True)
    parser.add_argument("-MethodName", required=True)
    parser.add_argument(
        "-InterceptorType",
        required=True,
        choices=["Before", "After", "ModificationAndControl"],
    )
    parser.add_argument("-Context", default="\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435")  # НаСервере
    parser.add_argument("-IsFunction", action="store_true")
    args = parser.parse_args()

    extension_path = args.ExtensionPath
    module_path = args.ModulePath
    method_name = args.MethodName
    interceptor_type = args.InterceptorType
    context = args.Context
    is_function = args.IsFunction

    # --- Resolve extension path ---
    if not os.path.isabs(extension_path):
        extension_path = os.path.join(os.getcwd(), extension_path)
    if os.path.isfile(extension_path):
        extension_path = os.path.dirname(extension_path)

    cfg_file = os.path.join(extension_path, "Configuration.xml")
    if not os.path.isfile(cfg_file):
        print(f"Configuration.xml not found in: {extension_path}", file=sys.stderr)
        sys.exit(1)

    # --- Read NamePrefix from Configuration.xml ---
    tree = ET.parse(cfg_file)
    root = tree.getroot()

    ns = {"md": "http://v8.1c.ru/8.3/MDClasses"}
    props_node = root.find(".//md:Configuration/md:Properties", ns)
    name_prefix = "\u0420\u0430\u0441\u0448_"  # Расш_
    if props_node is not None:
        prefix_node = props_node.find("md:NamePrefix", ns)
        if prefix_node is not None and prefix_node.text:
            name_prefix = prefix_node.text

    # --- Map ModulePath to file path ---
    # ModulePath formats:
    #   Catalog.X.ObjectModule       -> Catalogs/X/Ext/ObjectModule.bsl
    #   Catalog.X.ManagerModule      -> Catalogs/X/Ext/ManagerModule.bsl
    #   Catalog.X.Form.Y             -> Catalogs/X/Forms/Y/Ext/Form/Module.bsl
    #   CommonModule.X               -> CommonModules/X/Ext/Module.bsl
    #   Document.X.ObjectModule      -> Documents/X/Ext/ObjectModule.bsl
    #   Document.X.ManagerModule     -> Documents/X/Ext/ManagerModule.bsl
    #   Document.X.Form.Y            -> Documents/X/Forms/Y/Ext/Form/Module.bsl

    type_dir_map = {
        "Catalog": "Catalogs",
        "Document": "Documents",
        "Enum": "Enums",
        "CommonModule": "CommonModules",
        "Report": "Reports",
        "DataProcessor": "DataProcessors",
        "ExchangePlan": "ExchangePlans",
        "ChartOfAccounts": "ChartsOfAccounts",
        "ChartOfCharacteristicTypes": "ChartsOfCharacteristicTypes",
        "ChartOfCalculationTypes": "ChartsOfCalculationTypes",
        "BusinessProcess": "BusinessProcesses",
        "Task": "Tasks",
        "InformationRegister": "InformationRegisters",
        "AccumulationRegister": "AccumulationRegisters",
        "AccountingRegister": "AccountingRegisters",
        "CalculationRegister": "CalculationRegisters",
    }

    parts = module_path.split(".")
    if len(parts) < 2:
        print(
            f"Invalid ModulePath format: {module_path}. "
            "Expected: Type.Name.Module or CommonModule.Name",
            file=sys.stderr,
        )
        sys.exit(1)

    obj_type = parts[0]
    obj_name = parts[1]

    if obj_type not in type_dir_map:
        print(f"Unknown object type: {obj_type}", file=sys.stderr)
        sys.exit(1)

    dir_name = type_dir_map[obj_type]

    bsl_file = None
    if obj_type == "CommonModule":
        # CommonModule.X -> CommonModules/X/Ext/Module.bsl
        bsl_file = os.path.join(extension_path, dir_name, obj_name, "Ext", "Module.bsl")
    elif len(parts) >= 4 and parts[2] == "Form":
        # Type.X.Form.Y -> Types/X/Forms/Y/Ext/Form/Module.bsl
        form_name = parts[3]
        bsl_file = os.path.join(
            extension_path, dir_name, obj_name, "Forms", form_name, "Ext", "Form", "Module.bsl"
        )
    elif len(parts) >= 3:
        # Type.X.ObjectModule -> Types/X/Ext/ObjectModule.bsl
        module_name = parts[2]
        module_file_map = {
            "ObjectModule": "ObjectModule.bsl",
            "ManagerModule": "ManagerModule.bsl",
            "RecordSetModule": "RecordSetModule.bsl",
            "CommandModule": "CommandModule.bsl",
        }
        module_file_name = module_file_map.get(module_name, f"{module_name}.bsl")
        bsl_file = os.path.join(extension_path, dir_name, obj_name, "Ext", module_file_name)
    else:
        print(
            f"Invalid ModulePath format: {module_path}. "
            "Expected: Type.Name.Module, Type.Name.Form.FormName, or CommonModule.Name",
            file=sys.stderr,
        )
        sys.exit(1)

    # --- Map InterceptorType to decorator ---
    decorator_map = {
        "Before": "&\u041f\u0435\u0440\u0435\u0434",                    # &Перед
        "After": "&\u041f\u043e\u0441\u043b\u0435",                     # &После
        "ModificationAndControl": "&\u0418\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u0435\u0418\u041a\u043e\u043d\u0442\u0440\u043e\u043b\u044c",  # &ИзменениеИКонтроль
    }
    decorator = decorator_map[interceptor_type]

    # --- Map Context to annotation ---
    context_map = {
        "\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435": "&\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435",                          # НаСервере -> &НаСервере
        "\u041d\u0430\u041a\u043b\u0438\u0435\u043d\u0442\u0435": "&\u041d\u0430\u041a\u043b\u0438\u0435\u043d\u0442\u0435",                          # НаКлиенте -> &НаКлиенте
        "\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435\u0411\u0435\u0437\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u0430": "&\u041d\u0430\u0421\u0435\u0440\u0432\u0435\u0440\u0435\u0411\u0435\u0437\u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442\u0430",  # НаСервереБезКонтекста -> &НаСервереБезКонтекста
    }
    context_annotation = context_map.get(context, f"&{context}")

    # --- Procedure name ---
    proc_name = f"{name_prefix}{method_name}"

    # --- Generate BSL code ---
    keyword = "\u0424\u0443\u043d\u043a\u0446\u0438\u044f" if is_function else "\u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u0430"        # Функция / Процедура
    end_keyword = "\u041a\u043e\u043d\u0435\u0446\u0424\u0443\u043d\u043a\u0446\u0438\u0438" if is_function else "\u041a\u043e\u043d\u0435\u0446\u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u044b"  # КонецФункции / КонецПроцедуры

    body_lines = []
    if interceptor_type == "Before":
        body_lines.append("\t// TODO: \u043a\u043e\u0434 \u043f\u0435\u0440\u0435\u0434 \u0432\u044b\u0437\u043e\u0432\u043e\u043c \u043e\u0440\u0438\u0433\u0438\u043d\u0430\u043b\u044c\u043d\u043e\u0433\u043e \u043c\u0435\u0442\u043e\u0434\u0430")  # код перед вызовом оригинального метода
    elif interceptor_type == "After":
        body_lines.append("\t// TODO: \u043a\u043e\u0434 \u043f\u043e\u0441\u043b\u0435 \u0432\u044b\u0437\u043e\u0432\u0430 \u043e\u0440\u0438\u0433\u0438\u043d\u0430\u043b\u044c\u043d\u043e\u0433\u043e \u043c\u0435\u0442\u043e\u0434\u0430")  # код после вызова оригинального метода
    elif interceptor_type == "ModificationAndControl":
        body_lines.append("\t// \u0421\u043a\u043e\u043f\u0438\u0440\u0443\u0439\u0442\u0435 \u0442\u0435\u043b\u043e \u043e\u0440\u0438\u0433\u0438\u043d\u0430\u043b\u044c\u043d\u043e\u0433\u043e \u043c\u0435\u0442\u043e\u0434\u0430 \u0438 \u0432\u043d\u0435\u0441\u0438\u0442\u0435 \u0438\u0437\u043c\u0435\u043d\u0435\u043d\u0438\u044f,")  # Скопируйте тело оригинального метода и внесите изменения,
        body_lines.append("\t// \u0438\u0441\u043f\u043e\u043b\u044c\u0437\u0443\u044f \u043c\u0430\u0440\u043a\u0435\u0440\u044b #\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u0435 / #\u041a\u043e\u043d\u0435\u0446\u0423\u0434\u0430\u043b\u0435\u043d\u0438\u044f \u0438 #\u0412\u0441\u0442\u0430\u0432\u043a\u0430 / #\u041a\u043e\u043d\u0435\u0446\u0412\u0441\u0442\u0430\u0432\u043a\u0438")  # используя маркеры #Удаление / #КонецУдаления и #Вставка / #КонецВставки

    if is_function:
        body_lines.append("\t")
        body_lines.append("\t\u0412\u043e\u0437\u0432\u0440\u0430\u0442 \u041d\u0435\u043e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u043e; // TODO: \u0437\u0430\u043c\u0435\u043d\u0438\u0442\u044c \u043d\u0430 \u0440\u0435\u0430\u043b\u044c\u043d\u043e\u0435 \u0432\u043e\u0437\u0432\u0440\u0430\u0449\u0430\u0435\u043c\u043e\u0435 \u0437\u043d\u0430\u0447\u0435\u043d\u0438\u0435")  # Возврат Неопределено; // TODO: заменить на реальное возвращаемое значение

    bsl_code = [
        context_annotation,
        f'{decorator}("{method_name}")',
        f"{keyword} {proc_name}()",
    ]
    bsl_code.extend(body_lines)
    bsl_code.append(end_keyword)

    bsl_text = "\r\n".join(bsl_code) + "\r\n"

    # --- Check form borrowing for .Form. paths ---
    if len(parts) >= 4 and parts[2] == "Form":
        form_name = parts[3]
        form_meta_file = os.path.join(
            extension_path, dir_name, obj_name, "Forms", f"{form_name}.xml"
        )
        form_xml_file = os.path.join(
            extension_path, dir_name, obj_name, "Forms", form_name, "Ext", "Form.xml"
        )

        if not os.path.isfile(form_meta_file) or not os.path.isfile(form_xml_file):
            print(f"[WARN] Form '{form_name}' metadata or Form.xml not found in extension.")
            print("       Run /cfe-borrow first:")
            print(
                f"       /cfe-borrow -ExtensionPath {extension_path} "
                f'-ConfigPath <ConfigPath> -Object "{obj_type}.{obj_name}.Form.{form_name}"'
            )
            print()

    # --- Check if file exists and append ---
    bsl_dir = os.path.dirname(bsl_file)
    if not os.path.isdir(bsl_dir):
        os.makedirs(bsl_dir, exist_ok=True)

    if os.path.isfile(bsl_file):
        # Append to existing file
        with open(bsl_file, "r", encoding="utf-8-sig", newline="") as f:
            existing = f.read()

        separator = "\r\n"
        if existing and not existing.endswith("\n"):
            separator = "\r\n\r\n"
        new_content = existing + separator + bsl_text

        with open(bsl_file, "w", encoding="utf-8-sig", newline="") as f:
            f.write(new_content)
        print("[OK] \u0414\u043e\u0431\u0430\u0432\u043b\u0435\u043d \u043f\u0435\u0440\u0435\u0445\u0432\u0430\u0442\u0447\u0438\u043a \u0432 \u0441\u0443\u0449\u0435\u0441\u0442\u0432\u0443\u044e\u0449\u0438\u0439 \u0444\u0430\u0439\u043b")  # Добавлен перехватчик в существующий файл
    else:
        with open(bsl_file, "w", encoding="utf-8-sig", newline="") as f:
            f.write(bsl_text)
        print("[OK] \u0421\u043e\u0437\u0434\u0430\u043d \u0444\u0430\u0439\u043b \u043c\u043e\u0434\u0443\u043b\u044f")  # Создан файл модуля

    print(f"     \u0424\u0430\u0439\u043b:         {bsl_file}")          # Файл:
    print(f'     \u0414\u0435\u043a\u043e\u0440\u0430\u0442\u043e\u0440:    {decorator}("{method_name}")')  # Декоратор:
    print(f"     \u041f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u0430:    {proc_name}()")  # Процедура:
    print(f"     \u041a\u043e\u043d\u0442\u0435\u043a\u0441\u0442:     {context_annotation}")  # Контекст:


if __name__ == "__main__":
    main()
