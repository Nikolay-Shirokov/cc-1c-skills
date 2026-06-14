#!/usr/bin/env python3
# switch.py v1.7 — Переключение навыков 1С между AI-платформами и рантаймами
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
"""
Копирует (или создаёт ссылки на) навыки из .claude/skills/ на другие AI-платформы
(Cursor, Codex, Copilot, Kiro, Gemini CLI, OpenCode, Windsurf, Kilo Code, Cline,
Roo Code, Augment и др.) с перезаписью путей, и/или переключает рантайм (PowerShell ↔ Python).

Использование:
  python scripts/switch.py                                       # интерактивный режим
  python scripts/switch.py cursor                                # скопировать на Cursor
  python scripts/switch.py cursor --runtime python               # скопировать + Python
  python scripts/switch.py claude-code --project-dir /my/proj    # установить в проект
  python scripts/switch.py claude-code --project-dir /my/proj --link  # ссылки вместо копий
  python scripts/switch.py --undo cursor                         # удалить копию
  python scripts/switch.py --runtime python                      # сменить runtime in-place
"""
import argparse
import glob
import os
import re
import shutil
import sys

# ---------------------------------------------------------------------------
# Platform registry
# ---------------------------------------------------------------------------
PLATFORMS = {
    'claude-code': '.claude/skills',
    'agents':      '.agents/skills',
    'augment':     '.augment/skills',
    'cline':       '.cline/skills',
    'codeassistant': '.codeassistant/skills',
    'codex':       '.codex/skills',
    'cursor':      '.cursor/skills',
    'copilot':     '.github/skills',
    'gemini':      '.gemini/skills',
    'kilo':        '.kilocode/skills',
    'kiro':        '.kiro/skills',
    'opencode':    '.opencode/skills',
    'roo':         '.roo/skills',
    'windsurf':    '.windsurf/skills',
}

SOURCE_PREFIX = '.claude/skills'

# ${CLAUDE_SKILL_DIR}/../<other>/<rest>  — cross-skill reference (more specific, match first)
RX_SKILL_DIR_CROSS = re.compile(r'\$\{CLAUDE_SKILL_DIR\}/\.\./([a-z][a-z0-9-]+)/')
# ${CLAUDE_SKILL_DIR}/<rest>  — same-skill reference
SKILL_DIR_VAR = '${CLAUDE_SKILL_DIR}/'

# Рекомендуемые записи для .gitignore целевого проекта
GITIGNORE_RECOMMENDATIONS = [
    '.v8-project.json',
    'build/',
    'base/',
    '*.epf',
    '*.erf',
    '*.log',
]

# ---------------------------------------------------------------------------
# Runtime regex patterns (from switch-to-python.py / switch-to-powershell.py)
# ---------------------------------------------------------------------------
# Capture optional surrounding quote (group 'q') and bare path (group 'path').
# Path matches non-whitespace non-quote chars to support ${CLAUDE_SKILL_DIR}/...
# Optional -ExecutionPolicy <value> between -NoProfile and -File (used for codex target).
RX_PS = re.compile(
    r'powershell\.exe\s+'
    r'(?:-NoProfile\s+)?'
    r'(?:-ExecutionPolicy\s+\S+\s+)?'
    r'-File\s+(?P<q>["\']?)(?P<path>[^"\s]+?)\.ps1(?P=q)?'
)
RX_PY = re.compile(r"python\s+(?P<q>[\"']?)(?P<path>[^\"\s]+?)\.py(?P=q)?")

# Платформы, требующие -ExecutionPolicy Bypass (Codex запускает powershell как
# login-shell, профиль грузится и упирается в Restricted policy).
PS_BYPASS_PLATFORMS = {'codex'}


def emit_ps_invocation(path, quote, platform):
    """Build canonical powershell.exe invocation for a target platform."""
    ep = ' -ExecutionPolicy Bypass' if platform in PS_BYPASS_PLATFORMS else ''
    return f"powershell.exe -NoProfile{ep} -File {quote}{path}.ps1{quote}"


def normalize_ps_invocation(content, platform):
    """Re-emit existing powershell.exe ...ps1 invocations with platform flags.

    Idempotent: matches both with and without -ExecutionPolicy in source.
    """
    def repl(m):
        return emit_ps_invocation(m.group('path'), m.group('q'), platform)
    return RX_PS.sub(repl, content)


# ---------------------------------------------------------------------------
# Junction / symlink helpers
# ---------------------------------------------------------------------------
def is_junction(path):
    """Check if path is a junction or symlink."""
    if os.path.islink(path):
        return True
    if hasattr(os.path, 'isjunction'):
        return os.path.isjunction(path)
    return False


def remove_junction(path):
    """Remove junction/symlink without following it."""
    if sys.platform == 'win32':
        os.rmdir(path)
    else:
        os.unlink(path)


def create_junction(src, dst):
    """Create directory junction (Windows) or symlink (Unix)."""
    if sys.platform == 'win32':
        import _winapi
        _winapi.CreateJunction(src, dst)
    else:
        os.symlink(src, dst, target_is_directory=True)


def safe_rmtree(path):
    """Remove directory tree, handling junctions/symlinks safely.

    Unlike shutil.rmtree, this does not follow junctions/symlinks —
    it removes the link itself without touching the target.
    """
    for entry in os.listdir(path):
        entry_path = os.path.join(path, entry)
        if is_junction(entry_path):
            remove_junction(entry_path)
        elif os.path.isdir(entry_path):
            shutil.rmtree(entry_path)
        else:
            os.unlink(entry_path)
    os.rmdir(path)


def repo_root():
    """Return the repository root (parent of scripts/)."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def source_skills_dir():
    return os.path.join(repo_root(), '.claude', 'skills')


def scan_skills(skills_dir):
    """Return sorted list of skill directory names that contain SKILL.md."""
    result = []
    for entry in sorted(os.listdir(skills_dir)):
        skill_path = os.path.join(skills_dir, entry)
        if os.path.isdir(skill_path) and os.path.isfile(os.path.join(skill_path, 'SKILL.md')):
            result.append(entry)
    return result


def collect_md_files(skill_dir):
    """Return list of .md files in a skill directory."""
    return sorted(glob.glob(os.path.join(skill_dir, '*.md')))


def classify_skill_runtime(skill_dir):
    """Classify skill runtime based on invocations in .md files.

    Returns 'ps', 'py', 'both', or 'none'.
    """
    has_ps = has_py = False
    for md_path in collect_md_files(skill_dir):
        with open(md_path, 'r', encoding='utf-8') as f:
            content = f.read()
        if RX_PS.search(content):
            has_ps = True
        if RX_PY.search(content):
            has_py = True
    if has_ps and has_py:
        return 'both'
    return 'ps' if has_ps else ('py' if has_py else 'none')


def expand_skill_path(path, skill_name, source_prefix=SOURCE_PREFIX):
    """Expand ${CLAUDE_SKILL_DIR} placeholder to a path relative to source_prefix.

    ${CLAUDE_SKILL_DIR}/<rest>            -> <source_prefix>/<skill_name>/<rest>
    ${CLAUDE_SKILL_DIR}/../<other>/<rest> -> <source_prefix>/<other>/<rest>
    Anything else returned as-is (legacy literal path).
    """
    var = '${CLAUDE_SKILL_DIR}/'
    if not path.startswith(var):
        return path
    rest = path[len(var):]
    if rest.startswith('../'):
        return f'{source_prefix}/{rest[3:]}'
    return f'{source_prefix}/{skill_name}/{rest}'


def check_missing_files(skill_dir, target_runtime, root):
    """Check if target runtime script files exist for a skill.

    Returns list of missing file paths (relative to root).
    """
    missing = []
    skill_name = os.path.basename(os.path.normpath(skill_dir))
    for md_path in collect_md_files(skill_dir):
        with open(md_path, 'r', encoding='utf-8') as f:
            content = f.read()
        if target_runtime == 'python':
            for m in RX_PS.finditer(content):
                py_path = expand_skill_path(m.group('path'), skill_name) + '.py'
                if not os.path.isfile(os.path.join(root, py_path)):
                    missing.append(py_path)
        elif target_runtime == 'powershell':
            for m in RX_PY.finditer(content):
                ps1_path = expand_skill_path(m.group('path'), skill_name) + '.ps1'
                if not os.path.isfile(os.path.join(root, ps1_path)):
                    missing.append(ps1_path)
    return missing


def is_different_dir(dir1, dir2):
    """Check if two directories are different (resolved)."""
    return os.path.normcase(os.path.realpath(dir1)) != \
           os.path.normcase(os.path.realpath(dir2))


# ---------------------------------------------------------------------------
# Transformations
# ---------------------------------------------------------------------------
def rewrite_paths(content, platform, target_prefix, skill_name):
    """Resolve ${CLAUDE_SKILL_DIR} placeholders to target platform prefix.

    For claude-code target, leave ${CLAUDE_SKILL_DIR} untouched — Claude Code
    substitutes it natively at invocation time. For all other targets,
    expand to a literal path:
      ${CLAUDE_SKILL_DIR}/<rest>            → <target_prefix>/<skill_name>/<rest>
      ${CLAUDE_SKILL_DIR}/../<other>/<rest> → <target_prefix>/<other>/<rest>
    """
    if platform == 'claude-code':
        return content
    # Cross-skill first (more specific pattern)
    content = RX_SKILL_DIR_CROSS.sub(f'{target_prefix}/\\1/', content)
    # Then same-skill
    content = content.replace(SKILL_DIR_VAR, f'{target_prefix}/{skill_name}/')
    return content


def switch_runtime_content(content, target_runtime, platform='claude-code'):
    """Switch runtime invocations in .md content. Returns (new_content, switched).

    Platform controls flags on emitted powershell invocations
    (codex requires -ExecutionPolicy Bypass).
    """
    if target_runtime == 'python':
        def to_py(m):
            q = m.group('q')
            return f"python {q}{m.group('path')}.py{q}"
        new = RX_PS.sub(to_py, content)
    elif target_runtime == 'powershell':
        def to_ps(m):
            return emit_ps_invocation(m.group('path'), m.group('q'), platform)
        new = RX_PY.sub(to_ps, content)
    else:
        return content, False
    return new, new != content


def print_gitignore_recommendations(project_dir):
    """Print .gitignore recommendations for the target project."""
    gitignore_path = os.path.join(project_dir, '.gitignore')
    existing = set()
    if os.path.isfile(gitignore_path):
        with open(gitignore_path, 'r', encoding='utf-8') as f:
            for line in f:
                existing.add(line.strip())

    missing = [r for r in GITIGNORE_RECOMMENDATIONS if r not in existing]
    if missing:
        print(f"\nРекомендуется добавить в .gitignore проекта:")
        for r in missing:
            print(f"  {r}")


def collect_runtime_messages(skill_name, skill_dir, target_runtime, root):
    """Check runtime compatibility for a skill.

    Returns (info_list, warning_list).
    """
    info = []
    warnings = []
    src_rt = classify_skill_runtime(skill_dir)

    if target_runtime == 'python' and src_rt in ('ps', 'none'):
        missing = check_missing_files(skill_dir, 'python', root)
        if missing:
            info.append(f"  {skill_name} — только PowerShell "
                        f"(Python-версия не предусмотрена)")
    elif target_runtime == 'powershell' and src_rt in ('py', 'none'):
        missing = check_missing_files(skill_dir, 'powershell', root)
        if missing:
            info.append(f"  {skill_name} — только Python "
                        f"(PowerShell-версия не предусмотрена)")
    else:
        missing = check_missing_files(skill_dir, target_runtime, root)
        for m in missing:
            warnings.append(f"  {m} не найден ({skill_name})")

    return info, warnings


def print_runtime_messages(info, warnings):
    """Print collected info and warning messages."""
    if info:
        print(f"\nИнформация:")
        for i in info:
            print(i)
    if warnings:
        print(f"\nПредупреждения (отсутствующие файлы):")
        for w in warnings:
            print(w)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def cmd_install(platform, runtime, project_dir):
    """Copy skills to target platform directory with path rewriting."""
    src_dir = source_skills_dir()
    target_prefix = PLATFORMS[platform]
    target_dir = os.path.join(project_dir, target_prefix.replace('/', os.sep))

    skills = scan_skills(src_dir)
    if not skills:
        print(f"Ошибка: навыки не найдены в {src_dir}", file=sys.stderr)
        return 1

    if os.path.isdir(target_dir):
        existing = scan_skills(target_dir)
        if existing:
            print(f"В {target_prefix}/ уже есть {len(existing)} навыков. Обновляю...")
            safe_rmtree(target_dir)

    os.makedirs(target_dir, exist_ok=True)

    # Copy root-level files from source skills dir (.gitignore, etc.)
    for name in os.listdir(src_dir):
        src_path = os.path.join(src_dir, name)
        if os.path.isfile(src_path):
            shutil.copy2(src_path, os.path.join(target_dir, name))

    installed = 0
    all_info = []
    all_warnings = []

    print(f"\nКопирование {len(skills)} навыков в {target_prefix}/ ...")

    for skill_name in skills:
        src_skill = os.path.join(src_dir, skill_name)
        dst_skill = os.path.join(target_dir, skill_name)

        # Skip runtime conversion for single-runtime skills where
        # target files don't exist (e.g. img-grid has only .py)
        src_rt = classify_skill_runtime(src_skill)
        missing = check_missing_files(src_skill, runtime, repo_root())
        skip_runtime = bool(missing) and (
            (runtime == 'python' and src_rt in ('ps', 'none'))
            or (runtime == 'powershell' and src_rt in ('py', 'none'))
        )

        # Copy entire skill directory
        shutil.copytree(src_skill, dst_skill)

        # Rewrite paths in all .md files
        for md_path in collect_md_files(dst_skill):
            with open(md_path, 'r', encoding='utf-8') as f:
                content = f.read()

            new_content = rewrite_paths(content, platform, target_prefix, skill_name)

            # Apply runtime switch (skip for single-runtime skills
            # where target runtime is not available)
            if not skip_runtime:
                if runtime == 'python':
                    new_content, _ = switch_runtime_content(new_content, 'python', platform)
                elif runtime == 'powershell':
                    new_content, _ = switch_runtime_content(new_content, 'powershell', platform)

            # Normalize any remaining powershell invocations with platform flags
            # (covers skip_runtime=True case where source PS commands stayed)
            new_content = normalize_ps_invocation(new_content, platform)

            if new_content != content:
                with open(md_path, 'w', encoding='utf-8') as f:
                    f.write(new_content)

        # Check runtime compatibility (against source)
        info, warnings = collect_runtime_messages(
            skill_name, src_skill, runtime, repo_root())
        all_info.extend(info)
        all_warnings.extend(warnings)

        print(f"  [OK] {skill_name}")
        installed += 1

    print(f"\nГотово! {installed} навыков установлено в {target_prefix}/")

    print_runtime_messages(all_info, all_warnings)
    print_gitignore_recommendations(project_dir)

    if platform != 'claude-code':
        print(f"\nДля удаления: python scripts/switch.py --undo {platform}")
    return 0


def cmd_link(platform, project_dir):
    """Create junctions/symlinks to skills instead of copying."""
    if platform != 'claude-code':
        print(f"Ошибка: ссылки поддерживаются только для claude-code "
              f"(выбрано: {platform}).", file=sys.stderr)
        print("Для других платформ требуется перезапись путей в SKILL.md — "
              "используйте копирование.", file=sys.stderr)
        return 1

    src_dir = source_skills_dir()
    target_prefix = PLATFORMS[platform]
    target_dir = os.path.join(project_dir, target_prefix.replace('/', os.sep))

    if not is_different_dir(target_dir, src_dir):
        print("Ошибка: нельзя создать ссылки на самого себя.", file=sys.stderr)
        return 1

    skills = scan_skills(src_dir)
    if not skills:
        print(f"Ошибка: навыки не найдены в {src_dir}", file=sys.stderr)
        return 1

    if os.path.isdir(target_dir):
        existing = scan_skills(target_dir)
        if existing:
            print(f"В {target_prefix}/ уже есть {len(existing)} навыков. "
                  f"Обновляю...")
            safe_rmtree(target_dir)

    os.makedirs(target_dir, exist_ok=True)

    # Copy root-level files (.gitignore etc.)
    for name in os.listdir(src_dir):
        src_path = os.path.join(src_dir, name)
        if os.path.isfile(src_path):
            shutil.copy2(src_path, os.path.join(target_dir, name))

    linked = 0
    link_type = "junction" if sys.platform == 'win32' else "symlink"
    print(f"\nСоздание {link_type}-ссылок на {len(skills)} навыков "
          f"в {target_prefix}/ ...")

    for skill_name in skills:
        src_skill = os.path.join(src_dir, skill_name)
        dst_skill = os.path.join(target_dir, skill_name)
        create_junction(src_skill, dst_skill)
        print(f"  [OK] {skill_name}")
        linked += 1

    print(f"\nГотово! {linked} навыков подключено через {link_type} "
          f"в {target_prefix}/")
    print("Обновления в источнике автоматически подхватятся.")
    print("⚠ Режим --link экспериментальный. При ошибках запуска "
          "скриптов переключитесь на копирование (без --link).")
    print_gitignore_recommendations(project_dir)
    print(f"\nДля удаления: python scripts/switch.py --undo claude-code"
          f" --project-dir \"{project_dir}\"")
    return 0


def cmd_undo(platform, project_dir):
    """Remove installed skills for a platform."""
    target_prefix = PLATFORMS[platform]
    target_dir = os.path.join(project_dir, target_prefix.replace('/', os.sep))

    if not os.path.isdir(target_dir):
        print(f"Директория {target_prefix}/ не найдена — нечего удалять.")
        return 0

    skills = scan_skills(target_dir)
    safe_rmtree(target_dir)

    # Clean up empty parent directories
    parent = os.path.dirname(target_dir)
    if os.path.isdir(parent) and not os.listdir(parent):
        os.rmdir(parent)

    print(f"Удалено: {target_prefix}/ ({len(skills)} навыков)")
    return 0


def cmd_switch_runtime(runtime, project_dir):
    """Switch runtime in-place for skills in the current project."""
    # Find skills directory: try all known platform dirs
    skills_dir = None
    platform_name = None
    for name, prefix in PLATFORMS.items():
        candidate = os.path.join(project_dir, prefix.replace('/', os.sep))
        if os.path.isdir(candidate) and scan_skills(candidate):
            skills_dir = candidate
            platform_name = name
            break

    if not skills_dir:
        print("Ошибка: не найдена директория навыков в текущем каталоге.", file=sys.stderr)
        return 1

    skills = scan_skills(skills_dir)
    switched = 0
    all_info = []
    all_warnings = []

    print(f"\nПереключение на {runtime} в {PLATFORMS[platform_name]}/ ...")

    for skill_name in skills:
        skill_path = os.path.join(skills_dir, skill_name)

        # Skip runtime conversion for single-runtime skills where
        # target files don't exist (e.g. img-grid has only .py)
        cur_rt = classify_skill_runtime(skill_path)
        missing = check_missing_files(skill_path, runtime, project_dir)
        skip_runtime = bool(missing) and (
            (runtime == 'python' and cur_rt in ('ps', 'none'))
            or (runtime == 'powershell' and cur_rt in ('py', 'none'))
        )

        info, warnings = collect_runtime_messages(
            skill_name, skill_path, runtime, project_dir)
        all_info.extend(info)
        all_warnings.extend(warnings)

        if skip_runtime:
            continue

        for md_path in collect_md_files(skill_path):
            with open(md_path, 'r', encoding='utf-8') as f:
                content = f.read()

            new_content, _ = switch_runtime_content(content, runtime, platform_name)
            new_content = normalize_ps_invocation(new_content, platform_name)
            changed = new_content != content

            if changed:
                with open(md_path, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                md_name = os.path.basename(md_path)
                print(f"  [OK] {skill_name}/{md_name}")
                switched += 1

    print(f"\nПереключено {switched} файлов на {runtime}.")
    print_runtime_messages(all_info, all_warnings)
    return 0


# ---------------------------------------------------------------------------
# Interactive mode
# ---------------------------------------------------------------------------
def ask_choice(prompt, options, default=1):
    """Ask user to choose from numbered options. Returns 1-based index."""
    print(f"\n{prompt}")
    for i, (label, hint) in enumerate(options, 1):
        marker = "*" if i == default else " "
        print(f"  {marker}{i:>2}. {label:<16} ({hint})")
    while True:
        try:
            raw = input(f"\nВыбор [{default}]: ").strip()
            if not raw:
                return default
            val = int(raw)
            if 1 <= val <= len(options):
                return val
            print(f"  Введите число от 1 до {len(options)}")
        except ValueError:
            print(f"  Введите число от 1 до {len(options)}")
        except (EOFError, KeyboardInterrupt):
            print("\nОтмена.")
            sys.exit(0)


def ask_path(prompt, default=''):
    """Ask user for a directory path."""
    hint = f" [{default}]" if default else ""
    try:
        raw = input(f"\n{prompt}{hint}: ").strip()
        return raw if raw else default
    except (EOFError, KeyboardInterrupt):
        print("\nОтмена.")
        sys.exit(0)


def interactive_mode():
    """Run interactive setup wizard."""
    print("Навыки 1С — настройка платформы")
    print("=" * 31)

    platform_options = [
        ("Claude Code",    ".claude/skills/"),
        ("Augment",        ".augment/skills/"),
        ("Cline",          ".cline/skills/"),
        ("Cursor",         ".cursor/skills/"),
        ("GitHub Copilot", ".github/skills/"),
        ("Kilo Code",      ".kilocode/skills/"),
        ("Kiro",           ".kiro/skills/"),
        ("OpenAI Codex",   ".codex/skills/"),
        ("Gemini CLI",     ".gemini/skills/"),
        ("OpenCode",       ".opencode/skills/"),
        ("Roo Code",       ".roo/skills/"),
        ("Windsurf",       ".windsurf/skills/"),
        ("Code Assistant", ".codeassistant/skills/"),
        ("Agent Skills",   ".agents/skills/"),
    ]
    platform_keys = [
        'claude-code', 'augment', 'cline', 'cursor', 'copilot', 'kilo',
        'kiro', 'codex', 'gemini', 'opencode', 'roo', 'windsurf',
        'codeassistant', 'agents',
    ]

    choice = ask_choice("Для какой платформы настроить навыки?", platform_options)
    platform = platform_keys[choice - 1]

    project_dir = os.getcwd()
    install_mode = True

    # For claude-code in repo root, offer runtime switch as alternative
    if platform == 'claude-code' and not is_different_dir(project_dir, repo_root()):
        mode_options = [
            ("Переключить runtime", "сменить PowerShell \u2194 Python в текущем проекте"),
            ("Установить в проект", "скопировать навыки в другой проект"),
        ]
        mode = ask_choice("Что сделать?", mode_options)
        install_mode = (mode == 2)

    # Ask for project directory when installing
    if install_mode:
        default_dir = project_dir
        project_dir = ask_path("Путь к целевому проекту", default_dir)
        if not project_dir or not os.path.isdir(project_dir):
            print(f"Ошибка: директория '{project_dir}' не найдена.",
                  file=sys.stderr)
            return 1

    # Check if already installed — offer update or remove
    target_prefix = PLATFORMS[platform]
    target_dir = os.path.join(project_dir, target_prefix.replace('/', os.sep))

    if install_mode and os.path.isdir(target_dir):
        existing = scan_skills(target_dir)
        if existing:
            action_options = [
                ("Обновить", f"перезаписать {len(existing)} навыков"),
                ("Удалить",  f"удалить {target_prefix}/"),
                ("Отмена",   "ничего не делать"),
            ]
            action = ask_choice(
                f"В {target_prefix}/ уже есть {len(existing)} навыков.",
                action_options
            )
            if action == 2:
                return cmd_undo(platform, project_dir)
            if action == 3:
                print("Отмена.")
                return 0

    # Ask install method for claude-code to different project
    if platform == 'claude-code' and install_mode \
            and is_different_dir(project_dir, repo_root()):
        method_options = [
            ("Ссылки (junction)", "обновления подхватываются автоматически"),
            ("Копирование",       "независимая копия навыков"),
        ]
        method = ask_choice("Способ установки:", method_options)
        if method == 1:
            return cmd_link('claude-code', project_dir)

    runtime_options = [
        ("PowerShell", "рекомендуется для Windows"),
        ("Python",     "рекомендуется для Linux/Mac"),
    ]
    rt_choice = ask_choice("Какой рантайм скриптов?", runtime_options)
    runtime = 'powershell' if rt_choice == 1 else 'python'

    if install_mode:
        return cmd_install(platform, runtime, project_dir)
    else:
        return cmd_switch_runtime(runtime, project_dir)


# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) == 1:
        return interactive_mode()

    parser = argparse.ArgumentParser(
        description='Переключение навыков 1С между AI-платформами и рантаймами',
        epilog='Примеры:\n'
               '  python scripts/switch.py cursor\n'
               '  python scripts/switch.py cursor --runtime python\n'
               '  python scripts/switch.py claude-code --project-dir /my/proj\n'
               '  python scripts/switch.py claude-code --project-dir /my/proj --link\n'
               '  python scripts/switch.py --undo cursor\n'
               '  python scripts/switch.py --runtime python\n',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument('platform', nargs='?', choices=list(PLATFORMS.keys()),
                        help='целевая платформа')
    parser.add_argument('--runtime', choices=['python', 'powershell'],
                        help='рантайм скриптов (python или powershell)')
    parser.add_argument('--undo', action='store_true',
                        help='удалить навыки для указанной платформы')
    parser.add_argument('--project-dir', default=os.getcwd(),
                        help='путь к целевому проекту (по умолчанию: текущий каталог)')
    parser.add_argument('--link', action='store_true',
                        help='[экспериментально] создать ссылки (junction/symlink) '
                             'вместо копирования (только для claude-code)')

    args = parser.parse_args()

    # --link: create junctions/symlinks
    if args.link:
        if not args.platform:
            parser.error("--link требует указания платформы")
        if args.runtime:
            parser.error("--link несовместим с --runtime "
                         "(ссылки используют рантайм источника)")
        return cmd_link(args.platform, args.project_dir)

    # --undo requires platform
    if args.undo:
        if not args.platform:
            parser.error("--undo требует указания платформы")
        if args.platform == 'claude-code' \
                and not is_different_dir(args.project_dir, repo_root()):
            parser.error(
                "--undo не применим к claude-code в исходном репозитории")
        return cmd_undo(args.platform, args.project_dir)

    # --runtime without platform = in-place switch
    if args.runtime and not args.platform:
        return cmd_switch_runtime(args.runtime, args.project_dir)

    # platform specified
    if args.platform:
        if args.platform == 'claude-code':
            # claude-code + different project-dir → install
            if is_different_dir(args.project_dir, repo_root()):
                runtime = args.runtime or 'powershell'
                return cmd_install(args.platform, runtime, args.project_dir)
            # claude-code in repo root → runtime switch only
            if args.runtime:
                return cmd_switch_runtime(args.runtime, args.project_dir)
            else:
                parser.error(
                    "для claude-code без --project-dir укажите "
                    "--runtime python или --runtime powershell")
        runtime = args.runtime or 'powershell'
        return cmd_install(args.platform, runtime, args.project_dir)

    # No args at all — shouldn't reach here due to len(sys.argv)==1 check
    return interactive_mode()


if __name__ == '__main__':
    sys.exit(main() or 0)
