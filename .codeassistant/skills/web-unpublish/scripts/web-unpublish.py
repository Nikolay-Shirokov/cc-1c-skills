#!/usr/bin/env python3
# web-unpublish v1.3 — Remove 1C web publication
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

"""
Удаление веб-публикации 1С из Apache.
Удаляет маркерный блок из httpd.conf и каталог публикации.
Если Apache запущен — перезапускает для применения.
С флагом -All удаляет все публикации и останавливает Apache.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

import psutil

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



def get_our_httpd(httpd_exe_norm):
    """Filter httpd processes by our ApachePath."""
    result = []
    if not httpd_exe_norm:
        return result
    for p in psutil.process_iter(['pid', 'name', 'exe']):
        try:
            if p.info['name'] and 'httpd' in p.info['name'].lower():
                if p.info['exe'] and os.path.normcase(os.path.normpath(p.info['exe'])) == httpd_exe_norm:
                    result.append(p)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return result


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Remove 1C web publication', allow_abbrev=False)
    parser.add_argument('-AppName', type=str, default='', help='Publication name')
    parser.add_argument('-ApachePath', type=str, default='', help='Apache root (default: tools\\apache24)')
    parser.add_argument('-All', action='store_true', help='Remove all publications')
    args = ci_parse_args(parser)

    # --- Resolve ApachePath ---
    apache_path = args.ApachePath
    if not apache_path:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(script_dir))))
        apache_path = os.path.join(project_root, 'tools', 'apache24')

    # --- Validate params ---
    if not args.All and not args.AppName:
        print('Error: укажите -AppName или -All')
        sys.exit(1)

    # --- Read httpd.conf ---
    conf_file = os.path.join(apache_path, 'conf', 'httpd.conf')
    if not os.path.exists(conf_file):
        print(f'Error: httpd.conf не найден: {conf_file}')
        sys.exit(1)

    with open(conf_file, 'r', encoding='utf-8-sig') as f:
        conf_content = f.read()

    # --- Helper: our httpd process ---
    httpd_exe = os.path.join(apache_path, 'bin', 'httpd.exe')
    if os.path.exists(httpd_exe):
        httpd_exe_norm = os.path.normcase(os.path.normpath(os.path.realpath(httpd_exe)))
    else:
        httpd_exe_norm = os.path.normcase(os.path.normpath(httpd_exe))

    # --- Collect app names to remove ---
    if args.All:
        pub_pattern = r'# --- 1C Publication: (.+?) ---'
        pub_matches = re.findall(pub_pattern, conf_content)
        if not pub_matches:
            print('Нет публикаций для удаления')
            sys.exit(0)
        app_names = pub_matches
        print(f'Удаление всех публикаций: {", ".join(app_names)}')
    else:
        app_names = [args.AppName]

    # --- Remove marker blocks ---
    for name in app_names:
        pub_marker_start = f'# --- 1C Publication: {name} ---'
        pub_marker_end = f'# --- End: {name} ---'

        if re.search(re.escape(pub_marker_start), conf_content):
            pattern = r'\r?\n?' + re.escape(pub_marker_start) + r'[\s\S]*?' + re.escape(pub_marker_end) + r'\r?\n?'
            conf_content = re.sub(pattern, '\n', conf_content)
            print(f"httpd.conf: блок публикации '{name}' удалён")
        else:
            print(f"Публикация '{name}' не найдена в httpd.conf")

    # --- Check if any publications remain; if not, remove global block ---
    remaining_pubs = re.findall(r'# --- 1C Publication: .+? ---', conf_content)
    if not remaining_pubs:
        global_marker_start = '# --- 1C: global ---'
        global_marker_end = '# --- End: global ---'
        if re.search(re.escape(global_marker_start), conf_content):
            global_pattern = r'\r?\n?' + re.escape(global_marker_start) + r'[\s\S]*?' + re.escape(global_marker_end) + r'\r?\n?'
            conf_content = re.sub(global_pattern, '\n', conf_content)
            print('httpd.conf: глобальный блок 1C удалён (нет публикаций)')

    with open(conf_file, 'w', encoding='utf-8') as f:
        f.write(conf_content)

    # --- Remove publish directories ---
    for name in app_names:
        publish_dir = os.path.join(apache_path, 'publish', name)
        if os.path.exists(publish_dir):
            shutil.rmtree(publish_dir, ignore_errors=True)
            print(f'Каталог удалён: {publish_dir}')
        else:
            print(f'Каталог не найден: {publish_dir}')

    # --- Restart/Stop Apache if running (only our instance) ---
    httpd_proc = get_our_httpd(httpd_exe_norm)
    if httpd_proc:
        if remaining_pubs:
            print('Перезапуск Apache...')
            for p in httpd_proc:
                try:
                    p.kill()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            time.sleep(1)
            subprocess.Popen(
                [httpd_exe],
                cwd=apache_path,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            time.sleep(2)
            check = get_our_httpd(httpd_exe_norm)
            if check:
                print('Apache перезапущен')
            else:
                print('Error: Apache не удалось перезапустить')
                sys.exit(1)
        else:
            print('Публикаций не осталось — останавливаю Apache...')
            for p in httpd_proc:
                try:
                    p.kill()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            time.sleep(1)
            print('Apache остановлен')

    print('')
    if args.All:
        print(f'Все публикации удалены ({len(app_names)} шт.)')
    else:
        print(f"Публикация '{args.AppName}' удалена")


if __name__ == '__main__':
    main()
