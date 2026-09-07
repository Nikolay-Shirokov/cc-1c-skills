#!/usr/bin/env python3
# web-info v1.5 — Apache & 1C publication status
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills

"""
Статус Apache HTTP Server и публикаций 1С.
Показывает состояние Apache, список опубликованных баз
и последние ошибки из error.log.
"""

import argparse
import os
import re
import socket
import sys

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



def get_httpd_by_exe(httpd_exe_norm):
    """Get httpd processes matching our exe path."""
    ours = []
    foreign = []
    for p in psutil.process_iter(['pid', 'name', 'exe']):
        try:
            if p.info['name'] and 'httpd' in p.info['name'].lower():
                if p.info['exe'] and os.path.normcase(os.path.normpath(p.info['exe'])) == httpd_exe_norm:
                    ours.append(p)
                else:
                    foreign.append(p)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return ours, foreign


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description='Apache & 1C publication status', allow_abbrev=False)
    parser.add_argument('-ApachePath', type=str, default='', help='Apache root (default: tools\\apache24)')
    args = ci_parse_args(parser)

    # --- Resolve ApachePath ---
    apache_path = args.ApachePath
    if not apache_path:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(script_dir))))
        apache_path = os.path.join(project_root, 'tools', 'apache24')

    # --- Check Apache installation ---
    httpd_exe = os.path.join(apache_path, 'bin', 'httpd.exe')

    print('=== Apache Web Server ===')

    if not os.path.exists(httpd_exe):
        print('Status: Не установлен')
        print(f'Path:   {apache_path} (не найден)')
        print('')
        print('Используйте /web-publish для установки Apache.')
        sys.exit(0)

    # --- Check process (only our Apache) ---
    httpd_exe_norm = os.path.normcase(os.path.normpath(os.path.realpath(httpd_exe)))
    our_proc, foreign_proc = get_httpd_by_exe(httpd_exe_norm)

    if our_proc:
        pids = ', '.join(str(p.pid) for p in our_proc)
        print(f'Status: Запущен (PID: {pids})')
    else:
        print('Status: Остановлен')

    if foreign_proc:
        fp = foreign_proc[0]
        try:
            fpath = fp.info['exe'] or '?'
        except Exception:
            fpath = '?'
        print(f'[WARN] Обнаружен сторонний Apache (PID: {fp.pid}, {fpath})')

    print(f'Path:   {apache_path}')

    # --- Parse httpd.conf ---
    conf_file = os.path.join(apache_path, 'conf', 'httpd.conf')
    if not os.path.exists(conf_file):
        print('Config: httpd.conf не найден')
        sys.exit(0)

    with open(conf_file, 'r', encoding='utf-8-sig') as f:
        conf_content = f.read()

    # Extract port from global block
    port = '\u2014'
    m = re.search(r'(?m)^Listen\s+(\d+)', conf_content)
    if m:
        port = m.group(1)
    # Проверяем именно TCP-порт: запрос к публикации поднял бы сеанс 1С и занял лицензию
    port_state = ''
    if port != '—':
        try:
            with socket.create_connection(('127.0.0.1', int(port)), timeout=1):
                port_state = ' (слушается)'
        except OSError:
            port_state = ' (не отвечает)'
    print(f'Port:   {port}{port_state}')

    # Extract wsap24 path
    m = re.search(r'LoadModule\s+_1cws_module\s+"([^"]+)"', conf_content)
    if m:
        print(f'Module: {m.group(1)}')

    # --- Publications ---
    print('')
    print('=== Опубликованные базы ===')

    pub_pattern = r'# --- 1C Publication: (.+?) ---'
    pub_matches = re.findall(pub_pattern, conf_content)

    if not pub_matches:
        print('(нет публикаций)')
    else:
        for app_name in pub_matches:
            # Read default.vrd for this publication
            vrd_path = os.path.join(apache_path, 'publish', app_name, 'default.vrd')
            ib_info = '\u2014'
            vrd_content = ''
            if os.path.exists(vrd_path):
                with open(vrd_path, 'r', encoding='utf-8-sig') as f:
                    vrd_content = f.read()
                m = re.search(r'ib="([^"]*)"', vrd_content)
                if m:
                    ib_info = m.group(1).replace('&quot;', '"')

            # Detect published services
            svc_tags = []
            if vrd_content:
                # "+ext" — publishExtensionsByDefault: сервисы расширений тоже опубликованы
                m_ws = re.search(r'<ws\s[^>]*>', vrd_content)
                if m_ws:
                    svc_tags.append('WS+ext' if re.search(
                        r'publishExtensionsByDefault\s*=\s*"true"', m_ws.group(0)) else 'WS')
                m_hs = re.search(r'<httpServices\s[^>]*>', vrd_content)
                if m_hs:
                    svc_tags.append('HTTP+ext' if re.search(
                        r'publishExtensionsByDefault\s*=\s*"true"', m_hs.group(0)) else 'HTTP')
                # Актуальная форма — <standardOdata enable="true"/>; enableStandardOdata — до 8.3.9
                if (re.search(r'<standardOdata\s[^>]*enable\s*=\s*"true"', vrd_content)
                        or re.search(r'enableStandardOdata\s*=\s*"true"', vrd_content)):
                    svc_tags.append('OData')
            svc_label = '   [' + ' '.join(svc_tags) + ']' if svc_tags else ''

            url = f'http://localhost:{port}/{app_name}'
            print(f'  {app_name}   {url}   {ib_info}{svc_label}')

    # --- Error log ---
    print('')
    print('=== Последние ошибки ===')

    # Имя файла берём из httpd.conf: сборки Apache расходятся (error.log / error_log)
    error_log = None
    m_log = re.search(r'(?m)^\s*ErrorLog\s+"?([^"\r\n]+)"?', conf_content)
    if m_log:
        log_path = m_log.group(1).strip()
        error_log = os.path.normpath(
            log_path if os.path.isabs(log_path) else os.path.join(apache_path, log_path))
    if not error_log or not os.path.exists(error_log):
        error_log = next((p for p in (os.path.join(apache_path, 'logs', n)
                                      for n in ('error_log', 'error.log'))
                          if os.path.exists(p)), None)

    if error_log and os.path.exists(error_log):
        print(f'Журнал: {error_log}')
        try:
            with open(error_log, 'r', encoding='utf-8-sig', errors='replace') as f:
                all_lines = f.readlines()
            # Только error и выше: warn забит штатным шумом winnt_accept, notice — строки старта.
            # AH02538 — след нашего же рестарта (родитель убит), пишется как crit при каждой публикации
            err_lines = [ln for ln in all_lines
                         if re.search(r'\[[a-z_]+:(error|crit|alert|emerg)\]', ln)
                         and 'AH02538' not in ln]
            if err_lines:
                for line in err_lines[-5:]:
                    print(f'  {line.rstrip()}')
            else:
                print('(ошибок нет)')
        except Exception:
            print('(ошибка чтения)')
    else:
        print('(нет файла)')


if __name__ == '__main__':
    main()
