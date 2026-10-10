#!/usr/bin/env python3
# web-stop v1.3 — Stop Apache HTTP Server
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

"""
Остановка Apache HTTP Server.
Сначала пытается graceful shutdown, при неудаче — принудительная остановка.
"""

import argparse
import os
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


def get_all_httpd():
    """Get all httpd processes."""
    result = []
    for p in psutil.process_iter(['pid', 'name', 'exe']):
        try:
            if p.info['name'] and 'httpd' in p.info['name'].lower():
                result.append(p)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return result


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Stop Apache HTTP Server', allow_abbrev=False)
    parser.add_argument('-ApachePath', type=str, default='', help='Apache root (default: tools\\apache24)')
    args = ci_parse_args(parser)

    # --- Resolve ApachePath ---
    apache_path = args.ApachePath
    if not apache_path:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(script_dir))))
        apache_path = os.path.join(project_root, 'tools', 'apache24')

    # --- Helper: normalize httpd exe path ---
    httpd_exe = os.path.join(apache_path, 'bin', 'httpd.exe')
    if os.path.exists(httpd_exe):
        httpd_exe_norm = os.path.normcase(os.path.normpath(os.path.realpath(httpd_exe)))
    else:
        httpd_exe_norm = os.path.normcase(os.path.normpath(httpd_exe))

    # --- Check process (only our Apache) ---
    httpd_proc = get_our_httpd(httpd_exe_norm)
    if not httpd_proc:
        foreign = get_all_httpd()
        if foreign:
            print('Наш Apache не запущен')
            print(f'[WARN] Обнаружен сторонний Apache (PID: {foreign[0].pid})')
        else:
            print('Apache не запущен')
        sys.exit(0)

    pids = ', '.join(str(p.pid) for p in httpd_proc)
    print(f'Останавливаю Apache (PID: {pids})...')

    # --- Stop our processes ---
    for p in httpd_proc:
        try:
            p.kill()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    # --- Wait for shutdown ---
    max_wait = 5
    elapsed = 0
    while elapsed < max_wait:
        time.sleep(1)
        elapsed += 1
        check = get_our_httpd(httpd_exe_norm)
        if not check:
            print('Apache остановлен')
            print('Публикации сохранены. Перезапуск: /web-publish <база>  Удаление: /web-unpublish --all')
            sys.exit(0)

    # --- Fallback: force kill ---
    remaining = get_our_httpd(httpd_exe_norm)
    if remaining:
        print('Принудительная остановка...')
        for p in remaining:
            try:
                p.kill()
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        time.sleep(1)
        final = get_our_httpd(httpd_exe_norm)
        if final:
            print('Error: не удалось остановить Apache')
            sys.exit(1)

    print('Apache остановлен')
    print('Публикации сохранены. Перезапуск: /web-publish <база>  Удаление: /web-unpublish --all')


if __name__ == '__main__':
    main()
