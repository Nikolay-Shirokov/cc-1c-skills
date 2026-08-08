#!/usr/bin/env python3
# support-edit v1.0 — Toggle 1C configuration support state (Ext/ParentConfigurations.bin)
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

import argparse
import os
import re
import sys

from lxml import etree

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

parser = argparse.ArgumentParser(description="Toggle 1C support state", allow_abbrev=False)
parser.add_argument("-Path", "-TargetPath", dest="Path", required=True, help="Путь к объекту/форме/макету или каталогу дампа")
parser.add_argument("-Set", choices=["editable", "off-support", "locked"], default=None)
parser.add_argument("-Capability", choices=["on", "off"], default=None)
args = parser.parse_args()

if (not args.Set and not args.Capability) or (args.Set and args.Capability):
    sys.stderr.write("Укажите ровно одно: -Set editable|off-support|locked  ЛИБО  -Capability on|off\n")
    sys.exit(1)


def root_uuid(xml_path):
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


target_path = args.Path
if not os.path.exists(target_path):
    sys.stderr.write(f"Путь не найден: {target_path}\n")
    sys.exit(1)
rp = os.path.abspath(target_path)
elem_uuid = root_uuid(rp)
cfg_dir = None
bin_path = None
d = rp if os.path.isdir(rp) else os.path.dirname(rp)
for _ in range(12):
    if not d:
        break
    if not elem_uuid:
        elem_uuid = root_uuid(d + ".xml")
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
    elem_uuid = root_uuid(os.path.join(cfg_dir, "Configuration.xml"))

if not cfg_dir:
    sys.stderr.write(f"Не найден корень конфигурации (Configuration.xml) над путём: {rp}\n")
    sys.exit(1)
if not os.path.exists(bin_path):
    print("Конфигурация не на поддержке (Ext/ParentConfigurations.bin отсутствует) — переключать нечего.")
    sys.exit(0)

raw = open(bin_path, "rb").read()
if len(raw) <= 32:
    print("Поддержка снята полностью (пустой ParentConfigurations.bin) — переключать нечего.")
    sys.exit(0)
text = raw[3:].decode("utf-8") if raw[:3] == b"\xef\xbb\xbf" else raw.decode("utf-8")
hm = re.match(r"\{6,(\d+),(\d+),", text)
if not hm:
    sys.stderr.write("Неизвестный формат ParentConfigurations.bin\n")
    sys.exit(1)
g = int(hm.group(1))
k = int(hm.group(2))


def save_bin(txt):
    open(bin_path, "wb").write(b"\xef\xbb\xbf" + txt.encode("utf-8"))


# === Capability (global G) ===
if args.Capability:
    target = "0" if args.Capability == "on" else "1"
    if g == int(target):
        word = "включена" if args.Capability == "on" else "выключена"
        print(f"Возможность изменения конфигурации уже {word} — изменений нет.")
        sys.exit(0)
    text = re.sub(r"^(\{6,)\d+(,)", r"\g<1>" + target + r"\g<2>", text)
    text = re.sub(r"([0-9a-f-]{36}),\d+,([0-9a-f-]{36})", r"\1," + target + r",\2", text)
    text = re.sub(r"[0-2],0,([0-9a-f-]{36})", target + r",0,\1", text)
    save_bin(text)
    if args.Capability == "on":
        print("Возможность изменения конфигурации ВКЛЮЧЕНА. Все объекты поставщика — на замке.")
        print("Включайте редактирование точечно: support-edit -Path <объект> -Set editable")
    else:
        print("Возможность изменения конфигурации ВЫКЛЮЧЕНА. Вся конфигурация стала read-only; пообъектные правила сброшены.")
    sys.exit(0)

# === Per-object -Set ===
if g == 1:
    sys.stderr.write(
        "Возможность изменения конфигурации выключена — пообъектное переключение недоступно.\n"
        f"  Сначала: support-edit -Path {target_path} -Capability on\n"
    )
    sys.exit(1)
if not elem_uuid:
    sys.stderr.write(f"Не удалось определить объект по пути: {rp}\n")
    sys.exit(1)
u = re.escape(elem_uuid.lower())
n = len(re.findall(r"[0-2],0," + u, text))
if n == 0:
    print(f"Объект (uuid {elem_uuid}) не на поддержке (своё добавление или не найден в bin) — переключать нечего.")
    sys.exit(0)
new_f1 = {"editable": "1", "off-support": "2", "locked": "0"}[args.Set]
text = re.sub(r"[0-2],0," + u, new_f1 + ",0," + elem_uuid.lower(), text)
save_bin(text)
state = {
    "editable": "редактируется с сохранением поддержки (объект продолжит получать обновления вендора — возможны конфликты при обновлении)",
    "off-support": "снят с поддержки (обновления вендора по этому объекту прекращаются)",
    "locked": "на замке (правка запрещена)",
}[args.Set]
print(f"Объект uuid {elem_uuid} → {state}.")
print(f"Записей в bin изменено: {n}. Цель: {rp}")
sys.exit(0)
