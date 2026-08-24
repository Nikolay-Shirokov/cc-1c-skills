#!/usr/bin/env node
// Анти-дрейф общих inline-реализаций. Навыки автономны (общих runtime-модулей нет, утилиты
// копируются в каждый .ps1/.py — docs/python-porting-guide.md), поэтому нужен гард от расхождения
// копий. Реестр семей держим здесь же: реестр про дрейф не должен дрейфовать относительно проверки.
//
// Семья хранит не одно эталонное тело, а список вариантов: расхождение бывает и законным. У такого
// варианта обязано быть поле `why`; вариант без `why` — необоснованный, идёт в список долга (WARN).
//
// Важно не путать «вариант» с «разными задачами под одним именем»: esc_xml и esc_xml_text — это
// ДВЕ семьи, а не два варианта одной. Платформа в тексте элемента экранирует только & < >, а в
// значении атрибута добавляет &quot;, поэтому им нужны разные функции с говорящими именами, каждая
// со своим единственным эталоном. Свести такое в один вариант с флагом — значит спрятать разницу.
//
// Запуск: node tests/skills/check-inline-drift.mjs [--list]
// Выход 1 при ERROR, 0 при WARN. Кандидатов в реестр искать: node debug/inline-utils/scan-dupes.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SKILLS = join(ROOT, '.claude', 'skills');

// ─── Реестр семей ───────────────────────────────────────────────────────────
// name    — как называть семью в отчёте
// py/ps1  — имя функции в соответствующем порте (null, если в порте её нет)
// variants[].authority — навык-эталон варианта: правку вносим в него и копируем в consumers
// variants[].why       — обоснование, почему вариант отличается от остальных. Нет why → долг.
// variants[].consumersPs1 / consumersPy — потребители, которые есть только в этом порте
// variants[].port — вариант существует только в указанном порте (расхождение одного порта)
// Заготовку по новой семье печатает: node debug/inline-utils/scan-dupes.mjs --stub <py>:<ps1>

const FAMILIES = [
  // ─── support-guard: запрет правки объекта на поддержке ───────────────────
  {
    name: 'support-guard: assert_edit_allowed', py: 'assert_edit_allowed', ps1: 'Assert-EditAllowed',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'] },
    ],
  },
  {
    name: 'support-guard: get_edit_mode', py: '_sg_get_edit_mode', ps1: 'Get-EditMode',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'] },
    ],
  },
  {
    name: 'support-guard: is_external_root', py: '_sg_is_external_root', ps1: 'Test-ExternalObjectRoot',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit',
          // *-info навыки читают тем же хелпером СОСТОЯНИЕ поддержки для вывода, а не запрещают
          // правку. Тело то же, поэтому семья общая.
          'form-info', 'meta-info', 'mxl-info', 'role-info', 'skd-info', 'subsystem-info',
          // form-validate отличает автономную обработку от конфигурации: границей служит тот же корень
          'form-validate'] },
    ],
  },
  {
    name: 'support-guard: find_v8project', py: '_sg_find_v8project', ps1: 'Find-V8Project',
    variants: [
      // Имя с префиксом _sg_ историческое: функция просто ищет .v8-project.json обходом
      // вверх. Группа db-* использует её же, чтобы найти запись базы и взять реквизиты
      // хранилища — задача одна, поэтому семья общая, а не вторая с тем же телом.
      { id: 'full', authority: 'cf-edit',
        consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-repo', 'db-update',
          'form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'] },
    ],
  },
  {
    name: 'support-guard: root_uuid', py: '_sg_root_uuid', ps1: 'Get-RootUuid',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'],
        // support-edit и *-info читают uuid для ОТОБРАЖЕНИЯ состояния поддержки; в PY-портах
        // *-info пользуются другим путём, поэтому копия только в PS1.
        consumersPs1: ['form-info', 'mxl-info', 'role-info', 'skd-info', 'subsystem-info', 'support-edit'] },
    ],
  },

  // ─── Версия формата выгрузки ─────────────────────────────────────────────
  {
    name: 'detect_format_version', py: 'detect_format_version', ps1: 'Detect-FormatVersion',
    variants: [
      // Ветка автономной EPF/ERF безвредна для конфигурационных навыков: она срабатывает только
      // если <каталог>.xml — корень ExternalDataProcessor/ExternalReport, чего в дереве
      // конфигурации не бывает. Поэтому вариант один на всех, переключателя не нужно.
      { id: 'base', authority: 'form-compile',
        consumers: ['cfe-borrow', 'cfe-patch-method', 'form-add', 'form-validate', 'help-add', 'interface-edit',
          'meta-compile', 'mxl-compile', 'role-compile', 'subsystem-compile', 'template-add', 'xdto-compile'] },
    ],
  },
  {
    name: 'format_rank', py: 'format_rank', ps1: 'Get-FormatRank',
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: ['cf-init', 'cf-validate', 'cfe-borrow', 'cfe-init', 'cfe-patch-method', 'cfe-validate', 'epf-build',
          'epf-init', 'epf-validate', 'erf-init', 'form-add', 'form-compile', 'form-validate',
          'meta-validate', 'mxl-compile', 'role-compile', 'subsystem-compile', 'subsystem-edit',
          'template-add', 'xdto-compile'] },
    ],
  },

  // ─── Пометка расширенного свойства в расширении ──────────────────────────
  // Флаг <xr:PropertyState> ставит тот навык, который создал файл модуля: cfe-borrow — при
  // заимствовании, cfe-patch-method — когда модуль появляется вместе с перехватчиком. Копии
  // обязаны совпадать, иначе один навык пишет пометку, а другой — нет.
  {
    name: 'build_property_state_xml', py: 'build_property_state_xml', ps1: 'Build-PropertyStateXml',
    variants: [
      { id: 'base', authority: 'cfe-borrow', consumers: ['cfe-patch-method'] },
    ],
  },
  {
    name: 'set_property_state_flag', py: 'set_property_state_flag', ps1: 'Set-PropertyStateFlag',
    variants: [
      { id: 'base', authority: 'cfe-borrow', consumers: ['cfe-patch-method'] },
    ],
  },

  // ─── Запись файла в каноне выгрузки ──────────────────────────────────────
  {
    name: 'write_xml_file', py: 'write_xml_file', ps1: 'Write-XmlFile',
    variants: [
      { id: 'base', authority: 'cf-init',
        consumers: ['cfe-init', 'epf-init', 'erf-init', 'form-add', 'help-add', 'template-add'],
        consumersPy: ['cfe-borrow'] },
    ],
  },
  {
    name: 'write_utf8_bom', py: 'write_utf8_bom', ps1: null,
    variants: [
      { id: 'base', authority: 'cf-init',
        consumers: ['cfe-borrow', 'cfe-init', 'epf-init', 'erf-init', 'form-add', 'form-compile',
          'help-add', 'meta-compile', 'mxl-compile', 'role-compile', 'skd-compile',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile'] },
    ],
  },

  // ─── Отчёт валидаторов ───────────────────────────────────────────────────
  // Два варианта по способу вывода: буферизованный Out-Line копит отчёт в $script:output, что даёт
  // -OutFile (та же выдача в файл) и вставку заголовка в начало; потоковый Write-Host этого не умеет.
  // Для модели-потребителя stdout одинаков: на успешном прогоне обе ветки дают одну строку.
  {
    name: 'validate: report_error', py: null, ps1: 'Report-Error',
    variants: [
      { id: 'buffered', authority: 'cf-validate',
        consumers: ['cfe-validate', 'epf-validate', 'interface-validate', 'meta-validate',
          'role-validate', 'skd-validate', 'subsystem-validate', 'xdto-validate'] },
      { id: 'streamed', authority: 'form-validate', consumers: ['mxl-validate'],
        why: 'потоковый вывод вместо буферизованного — эти навыки не поддерживают -OutFile' },
    ],
  },
  {
    name: 'validate: report_warn', py: null, ps1: 'Report-Warn',
    variants: [
      { id: 'buffered', authority: 'cf-validate',
        consumers: ['cfe-validate', 'epf-validate', 'interface-validate', 'meta-validate',
          'role-validate', 'skd-validate', 'subsystem-validate', 'xdto-validate'] },
      { id: 'streamed', authority: 'form-validate', consumers: ['mxl-validate'],
        why: 'потоковый вывод вместо буферизованного — эти навыки не поддерживают -OutFile' },
    ],
  },
  {
    name: 'validate: report_ok', py: null, ps1: 'Report-OK',
    variants: [
      { id: 'buffered', authority: 'cf-validate',
        consumers: ['cfe-validate', 'epf-validate', 'interface-validate', 'meta-validate',
          'role-validate', 'skd-validate', 'subsystem-validate', 'xdto-validate'] },
      { id: 'streamed', authority: 'form-validate', consumers: ['mxl-validate'],
        why: 'потоковый вывод вместо буферизованного — эти навыки не поддерживают -OutFile' },
    ],
  },

  // ─── Прощающий ввод: разбор строки типа ──────────────────────────────────
  {
    name: 'resolve_type_str', py: 'resolve_type_str', ps1: 'Resolve-TypeStr',
    // Тело одинаково во всех навыках, а словари синонимов разные — навык объявляет алиас
    // TYPE_SYNONYMS / $script:typeSynonyms на свой локальный словарь.
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: ['form-compile', 'form-edit', 'meta-edit', 'mxl-compile', 'skd-compile', 'skd-edit'] },
    ],
  },

  // ─── Экранирование XML ───────────────────────────────────────────────────
  // Платформа в ТЕКСТЕ элемента экранирует только & < > (кавычка и апостроф остаются сырыми —
  // проверено раундтрипом через базу), а в ЗНАЧЕНИИ АТРИБУТА добавляет &quot;: внутри "..."
  // литеральная кавычка невалидна. Отсюда две функции, а не одна с переключателем.
  {
    name: 'esc_xml (значение атрибута)', py: 'esc_xml', ps1: 'Esc-Xml',
    variants: [
      { id: 'attr-with-quot', authority: 'meta-compile',
        consumers: ['form-compile', 'form-edit', 'meta-edit', 'mxl-compile', 'role-compile',
          'skd-compile', 'skd-edit', 'subsystem-compile', 'subsystem-edit'] },
    ],
  },
  {
    name: 'esc_xml_text (текст элемента)', py: 'esc_xml_text', ps1: 'Esc-XmlText',
    variants: [
      { id: 'text-no-quot', authority: 'meta-compile',
        consumers: ['cf-init', 'cfe-init', 'epf-init', 'erf-init', 'form-compile', 'form-edit',
          'meta-edit', 'mxl-compile', 'role-compile', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'xdto-compile'] },
    ],
  },
  // ─── Сохранение стиля XML при round-trip (#44/#46/#47) ───────────────────
  {
    name: 'detect_xml_style', py: '_detect_xml_style', ps1: null,
    variants: [
      { id: 'base', authority: 'cf-edit',
        consumers: ['cfe-borrow', 'form-add', 'form-remove', 'help-add', 'interface-edit', 'meta-edit',
          'meta-remove', 'subsystem-edit', 'template-add', 'template-remove'] },
    ],
  },
  {
    name: 'finalize_xml_bytes', py: '_finalize_xml_bytes', ps1: null,
    variants: [
      { id: 'base', authority: 'cf-edit',
        consumers: ['cfe-borrow', 'form-add', 'form-remove', 'help-add', 'interface-edit', 'meta-edit',
          'meta-remove', 'subsystem-edit', 'template-add', 'template-remove'] },
    ],
  },

  // ─── Обвязка вызова платформы 1С (db-* и потребители) ────────────────────
  // Детектор строк, о которых платформа сообщает, НЕ поднимая код возврата. Живёт во всех
  // навыках, читающих /Out-лог загрузки: разъехавшийся список паттернов означал бы, что один
  // навык ловит тихий отказ, а соседний по той же операции — нет.
  {
    name: 'platform: silent_rejections', py: 'find_silent_rejections', ps1: 'Find-SilentRejections',
    variants: [
      { id: 'base', authority: 'db-load-xml', consumers: ['db-load-git', 'db-update'] },
    ],
  },
  {
    name: 'platform: resolve_extra_args', py: 'resolve_extra_args', ps1: 'Resolve-ExtraArgs',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-run', 'db-update', 'epf-build', 'epf-dump'] },
      { id: 'v8-only', authority: 'db-repo', consumers: [],
        why: 'хранилище конфигурации ibcmd не поддерживает вовсе — нет такого режима, поэтому ветки ibcmd нет; вместо неё проверка усечённых ключей /ConfigurationRepository*, которые платформа не считает ошибкой, а запускает конфигуратор интерактивно' },
    ],
  },
  {
    name: 'platform: run_v8', py: 'run_v8', ps1: 'Invoke-PlatformProcess',
    variants: [
      // db-run запускает Предприятие и не ждёт процесс — общей обвязки запуска не использует.
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-update', 'epf-build', 'epf-dump'] },
    ],
  },
  {
    name: 'platform: decode_platform_bytes', py: 'decode_platform_bytes', ps1: 'ConvertFrom-PlatformBytes',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-update', 'epf-build', 'epf-dump'] },
    ],
  },
  {
    name: 'platform: redact', py: '_redact', ps1: 'Protect-Secrets',
    variants: [
      { id: 'base', authority: 'db-dump-cf',
        consumers: ['db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump'] },
    ],
  },
  {
    name: 'platform: version_key', py: '_version_key', ps1: null,
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'web-publish'] },
    ],
  },
  {
    name: 'platform: version_dir', py: '_version_dir', ps1: null,
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'web-publish'] },
    ],
  },
  {
    name: 'platform: find_project_v8path', py: '_find_project_v8path', ps1: 'Find-ProjectV8Path',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'web-publish'] },
    ],
  },

  {
    name: 'repository: load hints', py: 'write_repository_hints', ps1: 'Write-RepositoryHints',
    variants: [{ id: 'base', authority: 'db-load-xml', consumers: ['db-load-git'] }],
  },
  // ─── Реквизиты хранилища конфигурации ────────────────────────────────────
  // База под хранилищем не принимает ни одной операции конфигуратора без реквизитов
  // доступа, и модель их не передаёт: скрипт сам сопоставляет параметры соединения с
  // записью в databases[]. Блок копируется во все навыки группы, работающие с
  // конфигурацией базы.
  {
    name: 'repository: same_path', py: 'same_path', ps1: 'Test-SamePath',
    variants: [{ id: 'base', authority: 'db-repo', consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-update'] }],
  },
  {
    name: 'repository: find_project_database', py: 'find_project_database', ps1: 'Find-ProjectDatabase',
    variants: [{ id: 'base', authority: 'db-repo', consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-update'] }],
  },
  {
    name: 'repository: resolve_settings', py: 'resolve_repository_settings', ps1: 'Resolve-RepositorySettings',
    variants: [{ id: 'base', authority: 'db-repo', consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-update'] }],
  },
  {
    name: 'repository: args', py: 'repository_args', ps1: 'Get-RepositoryArgs',
    variants: [{ id: 'base', authority: 'db-repo', consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-update'] }],
  },

  // ─── Значения свойств-перечислений ───────────────────────────────────────
  // Сама функция одинакова в обоих портах; СПИСКИ значений, на которые она опирается, держит
  // отдельный гард check-enum-drift.mjs (авторитет тот же — meta-compile).
  {
    name: 'normalize_enum_value', py: 'normalize_enum_value', ps1: 'Normalize-EnumValue',
    variants: [{ id: 'base', authority: 'meta-compile', consumers: ['meta-edit'] }],
  },

  // ─── Регистронезависимый ввод: паритет с PS1 ─────────────────────────────
  // Существует только в PY: PowerShell регистронезависим сам по себе (свойства PSObject, ключи
  // Hashtable, -eq/-contains, имена параметров, ValidateSet), поэтому в .ps1 копии нет и быть
  // не должно — ps1: null.
  {
    name: 'case-insensitive input: CIDict', py: 'CIDict', ps1: null,
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: [
          'cf-edit', 'form-compile', 'form-edit', 'interface-edit', 'meta-edit', 'mxl-compile',
          'role-compile', 'skd-compile', 'subsystem-compile', 'subsystem-edit'] }],
  },
  {
    name: 'case-insensitive input: ci_json', py: 'ci_json', ps1: null,
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: [
          'cf-edit', 'form-compile', 'form-edit', 'interface-edit', 'meta-edit', 'mxl-compile',
          'role-compile', 'skd-compile', 'subsystem-compile', 'subsystem-edit'] }],
  },
  {
    // Единственная из трёх, которая нужна КАЖДОМУ порту: DSL читают не все навыки, а параметры — все.
    name: 'case-insensitive input: ci_parse_args', py: 'ci_parse_args', ps1: null,
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: [
          'cf-edit', 'cf-info', 'cf-init', 'cf-validate', 'cfe-borrow', 'cfe-diff', 'cfe-init',
          'cfe-patch-method', 'cfe-validate', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml',
          'db-load-cf', 'db-load-dt', 'db-load-git', 'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build',
          'epf-dump', 'epf-init', 'epf-validate', 'erf-init', 'form-add', 'form-compile',
          'form-decompile', 'form-edit', 'form-info', 'form-remove', 'form-validate', 'help-add',
          'img-grid', 'interface-edit', 'interface-validate', 'meta-decompile', 'meta-edit', 'meta-info',
          'meta-remove', 'meta-validate', 'mxl-compile', 'mxl-decompile', 'mxl-info', 'mxl-validate',
          'role-compile', 'role-info', 'role-validate', 'skd-compile', 'skd-decompile', 'skd-edit',
          'skd-info', 'skd-validate', 'subsystem-compile', 'subsystem-edit', 'subsystem-info',
          'subsystem-validate', 'support-edit', 'template-add', 'template-remove', 'web-info',
          'web-publish', 'web-stop', 'web-unpublish', 'xdto-compile', 'xdto-decompile', 'xdto-edit',
          'xdto-info', 'xdto-validate'] },
    ],
  },

  // ─── Компактный JSON декомпиляторов ─────────────────────────────────────
  // Штатные сериализаторы не годятся: ConvertTo-Json (PS5.1) выравнивает ключи по самому
  // длинному и эскейпит кириллицу в \uXXXX, json.dumps даёт иную раскладку inline/multiline.
  // Поэтому у декомпиляторов свой сериализатор — и он обязан совпадать в портах байт в байт,
  // иначе один и тот же макет даёт разный DSL на разных рантаймах.
  {
    name: 'decompile json: string literal',
    py: 'convert_string_to_json_literal', ps1: 'Convert-StringToJsonLiteral',
    variants: [
      { id: 'base', authority: 'skd-decompile', consumers: ['form-decompile', 'mxl-decompile'] }],
  },
  {
    name: 'decompile json: try inline',
    py: 'try_inline_json', ps1: 'Try-InlineJson',
    variants: [
      { id: 'base', authority: 'skd-decompile', consumers: ['mxl-decompile'] },
      { id: 'no-pscustomobject', authority: 'form-decompile', consumers: [],
        why: 'form-decompile строит дерево на ordered-хэштейблах и ветку PSCustomObject не проходит' }],
  },
  {
    // Только в PY: в ps1 числа печатает [System.Convert]::ToString с InvariantCulture прямо
    // в теле сериализатора, отдельной функции там нет — ps1: null.
    name: 'decompile json: number', py: '_fmt_number', ps1: null,
    variants: [
      { id: 'base', authority: 'skd-decompile', consumers: ['mxl-decompile'] }],
  },
  {
    name: 'decompile json: compact',
    py: 'convert_to_compact_json', ps1: 'ConvertTo-CompactJson',
    variants: [
      { id: 'base', authority: 'skd-decompile', consumers: ['mxl-decompile'] },
      { id: 'line-limit-120', authority: 'form-decompile', consumers: [],
        why: 'у форм строки DSL длиннее, порог inline снижен со 400 до 120' },
      { id: 'legacy', authority: 'meta-decompile', consumers: [],
        why: 'ранний вариант со своим Quote-Json и без inline-попытки; сведение меняет вывод meta-decompile' }],
  },
  // ─── Регистрация объекта в <ChildObjects> файла конфигурации ─────────────
  {
    name: 'ChildObjects: регистрация объекта в составе',
    py: 'register_in_childobjects', ps1: 'Register-InChildObjects',
    variants: [
      { id: 'grouped', authority: 'meta-compile', consumers: ['role-compile', 'xdto-compile'] },
      { id: 'nested-parent', authority: 'subsystem-compile', consumers: [],
        why: 'родителем бывает вложенный Subsystem.xml произвольной глубины: отступ берётся из документа, а запись (при childObjectsOrder=append) дописывается в конец блока — фиксированные три табуляции там неверны, и группировать по типу нечего' },
    ],
  },
  // Порядок вставки — настройка childObjectsOrder из .v8-project.json (append | alphabetical).
  // Резолвер отдельно от Get-EditMode: файл ищется от каталога конфигурации, а не от cwd,
  // и configSrc считается от корня проекта — семья support-guard этих правил не имеет.
  {
    name: 'ChildObjects: настройка childObjectsOrder',
    py: 'get_childobjects_order', ps1: 'Get-ChildObjectsOrder',
    variants: [
      { id: 'base', authority: 'meta-compile', consumers: ['role-compile', 'subsystem-compile', 'xdto-compile'] },
    ],
  },
  // Порядок имён, как в дереве Конфигуратора: ключ «ранг+символ» вместо культурного сравнения,
  // чтобы порты совпадали байт-в-байт на любой ОС (см. комментарий у функции).
  {
    name: 'ChildObjects: порядок имён объектов',
    py: 'compare_metadata_names', ps1: 'Compare-MetadataNames',
    variants: [
      { id: 'base', authority: 'meta-compile', consumers: ['role-compile', 'subsystem-compile', 'xdto-compile'] },
    ],
  },

  // ─── Разбор пользовательского JSON ─────────────────────────────────────
  // Сообщение об ошибке разбора одинаково во всех навыках (issue #80): стектрейс парсера
  // агент читает как «скрипт сломан» и идёт чинить не то место. Вся специфика навыка —
  // в аргументах source/expected на месте вызова, тело функции общее.
  {
    name: 'read_json_file', py: 'read_json_file', ps1: 'Read-JsonInputFile',
    variants: [
      { id: 'base', authority: 'interface-edit',
        consumers: ['cf-edit', 'form-compile', 'form-edit', 'meta-compile', 'meta-edit', 'mxl-compile',
          'role-compile', 'skd-compile', 'skd-decompile', 'subsystem-compile', 'subsystem-edit'] },
    ],
  },
  {
    name: 'parse_json_input', py: 'parse_json_input', ps1: 'ConvertFrom-JsonInput',
    variants: [
      { id: 'base', authority: 'interface-edit',
        consumers: ['cf-edit', 'form-compile', 'form-edit', 'meta-compile', 'meta-edit', 'mxl-compile',
          'role-compile', 'skd-compile', 'skd-decompile', 'subsystem-compile', 'subsystem-edit'] },
    ],
  },

];

// ─── Семьи, разъехавшиеся целиком ───────────────────────────────────────────
// Перечислять «вариант на каждую копию» бессмысленно — эталона у них сейчас нет. Держим храповик:
// число групп не должно расти. Фаза 2 сводит семью к одному телу и переносит её в FAMILIES.

// Разбор каждой оставшейся семьи уже сделан — сведение упирается не в аккуратность, а в решение,
// поэтому note описывает ПРИРОДУ расхождения, а не «когда-нибудь свести».
const DRIFTED = [
  { name: 'emit_mltext', py: 'emit_mltext', ps1: 'Emit-MLText', maxVariants: { py: 5, ps1: 5 },
    note: 'разные сигнатуры: (lines,indent,tag,text) / +xsi_type / +no_xsi_type / meta-compile пишет через глобальный X(). Сведение = принять самую богатую сигнатуру и переписать все вызовы' },
  { name: 'get_ml_text', py: 'get_ml_text', ps1: 'Get-MLText', maxVariants: { py: 7, ps1: 6 },
    note: 'одна задача, разная полнота: cf-info берёт первый item, meta-info предпочитает ru с фолбэком, skd-info добавляет itertext. Сведение = принять самый способный вариант, меняет вывод *-info' },
  { name: 'import_fragment', py: 'import_fragment', ps1: 'Import-Fragment', maxVariants: { py: 5, ps1: 4 },
    note: 'НЕ общая семья: разные сигнатуры и разные наборы xmlns по навыкам (meta-edit добавляет cfg:, xdto-edit строит ns из схемы). Одно имя — разные задачи, сводить нельзя' },
  { name: 'get_child_indent', py: 'get_child_indent', ps1: 'Get-ChildIndent', maxVariants: { py: 4, ps1: 3 },
    note: 'одна задача, разные эвристики определения отступа (skd-edit ловит только табы). Сведение меняет форматирование вывода — нужен разбор снэпшотов' },
];

// ─── Извлечение тел функций ─────────────────────────────────────────────────
// PY: от `def name(` до первой строки без отступа.
// PS1: от `function Name` до первой строки, равной ровно `}` — так отформатирован репозиторий.
// Балансировка фигурных скобок в PS1 НЕ работает: скобки внутри строк и хэштейблов дают ложные
// расхождения (18 вариантов из 18 копий Assert-EditAllowed там, где реально 3).

function extractPy(text) {
  const lines = text.split('\n');
  const out = new Map();
  for (let i = 0; i < lines.length; i++) {
    // Определение бывает вложенным: *-info объявляют is_external_root внутри другой функции.
    // Поиск только по `^def` делал такие копии невидимыми для гарда — то есть давал ложное «OK».
    // Классы забирает та же ветка: общая утилита бывает и классом (CIDict), а без этого её тело
    // гарду невидимо и семью для неё не завести.
    const m = /^(\s*)(?:def|class) ([A-Za-z_]\w*)[(:]/.exec(lines[i]);
    if (!m) continue;
    const indent = m[1].length;
    const body = [lines[i]];
    let j = i + 1;
    for (; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === '') { body.push(l); continue; }
      const li = l.length - l.trimStart().length;
      if (li > indent) { body.push(l); continue; }
      break;
    }
    if (!out.has(m[2])) out.set(m[2], body);
    // НЕ перескакиваем через тело: иначе вложенные определения внутри него остались бы невидимыми.
  }
  return out;
}

function extractPs1(text) {
  const lines = text.split('\n');
  const out = new Map();
  for (let i = 0; i < lines.length; i++) {
    // Определение может быть вложенным (db-load-git объявляет Find-ProjectV8Path внутри if),
    // поэтому конец ищем по закрывающей скобке НА ТОМ ЖЕ отступе, что и слово function.
    const m = /^(\s*)function\s+([A-Za-z][\w-]*)/.exec(lines[i]);
    if (!m) continue;
    // Однострочное определение (`function Out(...) { ... }`) закрывается на своей же строке.
    // Без этой ветки «телом» такой функции становилось всё до следующей одиночной `}` — то есть
    // следующая функция проглатывалась и была невидима для гарда.
    const opens = (lines[i].match(/\{/g) || []).length;
    const closes = (lines[i].match(/\}/g) || []).length;
    if (opens > 0 && opens === closes) {
      if (!out.has(m[2])) out.set(m[2], [lines[i]]);
      continue;
    }
    const closing = m[1] + '}';
    const body = [lines[i]];
    let j = i + 1;
    for (; j < lines.length; j++) {
      body.push(lines[j]);
      if (lines[j].replace(/\s+$/, '') === closing) break;
    }
    if (!out.has(m[2])) out.set(m[2], body);
  }
  return out;
}

// Docstring-и снимаем наравне с комментариями: одинаковый код с разным описанием — не расхождение.
function stripDocstrings(lines) {
  const out = [];
  let closing = null;
  for (const l of lines) {
    const t = l.trim();
    if (closing) {
      if (t.endsWith(closing) && t.length >= closing.length) closing = null;
      continue;
    }
    const m = /^(?:[rубf]*)("""|''')/i.exec(t);
    if (m) {
      const q = m[1];
      const rest = t.slice(t.indexOf(q) + q.length);
      if (!rest.endsWith(q) || rest.length < q.length) closing = q;
      continue;
    }
    out.push(l);
  }
  return out;
}

function hashBody(body, lang) {
  let lines = body.slice(1);
  if (lang === 'py') lines = stripDocstrings(lines);
  const sig = lines.map((l) => l.trim()).filter((l) => l !== '' && !l.startsWith('#'));
  return createHash('md5').update(sig.join(' ').replace(/\s+/g, ' ')).digest('hex').slice(0, 8);
}

// ─── Индекс: навык+порт → функции ───────────────────────────────────────────

function buildIndex() {
  const index = new Map(); // `${skill}|${lang}` -> Map(name -> body)
  for (const skill of readdirSync(SKILLS)) {
    const dir = join(SKILLS, skill, 'scripts');
    if (!existsSync(dir)) continue;
    for (const file of readdirSync(dir)) {
      const lang = file.endsWith('.py') ? 'py' : file.endsWith('.ps1') ? 'ps1' : null;
      if (!lang) continue;
      const text = readFileSync(join(dir, file), 'utf8').replace(/^﻿/, '');
      const fns = lang === 'py' ? extractPy(text) : extractPs1(text);
      const key = `${skill}|${lang}`;
      const acc = index.get(key) || new Map();
      for (const [n, b] of fns) if (!acc.has(n)) acc.set(n, b);
      index.set(key, acc);
    }
  }
  return index;
}

// ─── Проверка ───────────────────────────────────────────────────────────────

const index = buildIndex();
const errors = [];
const warns = [];

function membersOf(v, lang) {
  const extra = lang === 'ps1' ? v.consumersPs1 : v.consumersPy;
  return [v.authority, ...v.consumers, ...(extra || [])];
}

// Варианты, применимые к порту: общие + объявленные именно для него. Навыки, захваченные
// портовым вариантом, из общих вариантов этого порта исключаются.
function variantsFor(family, lang) {
  const applicable = family.variants.filter((v) => !v.port || v.port === lang);
  const claimed = new Set(applicable.filter((v) => v.port === lang).flatMap((v) => membersOf(v, lang)));
  return applicable.map((v) => {
    if (v.port === lang) return { v, members: membersOf(v, lang) };
    return { v, members: membersOf(v, lang).filter((s) => !claimed.has(s)) };
  }).filter((e) => e.members.length);
}

for (const family of FAMILIES) {
  for (const lang of ['py', 'ps1']) {
    const fnName = family[lang];
    if (!fnName) continue;
    const effective = variantsFor(family, lang);
    const declared = new Set(effective.flatMap((e) => e.members));

    // 1. Каждый объявленный потребитель содержит функцию, и внутри варианта тела совпадают.
    const hashByVariant = new Map();
    for (const { v, members } of effective) {
      const hashes = new Map();
      for (const skill of members) {
        const body = index.get(`${skill}|${lang}`)?.get(fnName);
        if (!body) {
          errors.push(`${family.name} [${lang}]: ${skill} объявлен в варианте '${v.id}', но функции ${fnName} в нём нет`);
          continue;
        }
        hashes.set(skill, hashBody(body, lang));
      }
      const authorityHash = hashes.get(v.authority);
      if (authorityHash === undefined) continue;
      hashByVariant.set(v.id, authorityHash);
      for (const [skill, h] of hashes) {
        if (h !== authorityHash) {
          errors.push(`${family.name} [${lang}]: ${skill} разошёлся с эталоном ${v.authority} (вариант '${v.id}')`);
        }
      }
    }

    // 2. Разные варианты обязаны различаться телом — иначе реестр протух и их пора слить.
    const seen = new Map();
    for (const [id, h] of hashByVariant) {
      if (seen.has(h)) {
        errors.push(`${family.name} [${lang}]: варианты '${seen.get(h)}' и '${id}' объявлены разными, но тела совпадают — слить в реестре`);
      }
      seen.set(h, id);
    }

    // 3. Навык содержит функцию, но в реестре не объявлен — новая копия проехала мимо.
    for (const [key, fns] of index) {
      const [skill, l] = key.split('|');
      if (l !== lang || declared.has(skill) || !fns.has(fnName)) continue;
      errors.push(`${family.name} [${lang}]: ${skill} содержит ${fnName}, но в реестре не объявлен`);
    }
  }

  // 4. Долг: отклоняющийся вариант без обоснования. Базовым считаем самый массовый — ему
  // обоснование не нужно, оно нужно тем, кто от него отклонился.
  if (family.variants.length > 1) {
    const sized = family.variants.map((v) => ({
      v, members: [...new Set([...membersOf(v, 'py'), ...membersOf(v, 'ps1')])],
    })).sort((a, b) => b.members.length - a.members.length);
    for (const { v, members } of sized.slice(1)) {
      if (v.why) continue;
      warns.push(`${family.name}: вариант '${v.id}' (${members.join(', ')}) без обоснования`);
    }
  }
}

// Храповик по разъехавшимся семьям: число групп не должно расти.
const drift = [];
for (const family of DRIFTED) {
  for (const lang of ['py', 'ps1']) {
    const fnName = family[lang];
    if (!fnName) continue;
    const groups = new Map();
    for (const [key, fns] of index) {
      const [skill, l] = key.split('|');
      if (l !== lang || !fns.has(fnName)) continue;
      const h = hashBody(fns.get(fnName), lang);
      if (!groups.has(h)) groups.set(h, []);
      groups.get(h).push(skill);
    }
    if (!groups.size) continue;
    const limit = family.maxVariants[lang];
    drift.push({ family: family.name, lang, actual: groups.size, limit, groups });
    if (limit === undefined) {
      errors.push(`${family.name} [${lang}]: семья не имеет предела вариантов в реестре`);
    } else if (groups.size > limit) {
      errors.push(`${family.name} [${lang}]: вариантов стало ${groups.size} при пределе ${limit} — новая копия разошлась`);
    }
  }
}

// ─── Вывод ──────────────────────────────────────────────────────────────────

if (process.argv.includes('--list')) {
  for (const family of FAMILIES) {
    const ports = [family.py && `py:${family.py}`, family.ps1 && `ps1:${family.ps1}`].filter(Boolean).join('  ');
    console.log(`\n${family.name}  (${ports})`);
    const sized = family.variants.map((v) => ({
      v, members: [...new Set([...membersOf(v, 'py'), ...membersOf(v, 'ps1')])],
    })).sort((a, b) => b.members.length - a.members.length);
    for (const [i, { v, members }] of sized.entries()) {
      const tag = i === 0 ? 'базовый' : v.why || 'БЕЗ ОБОСНОВАНИЯ';
      console.log(`  [${v.id}] эталон: ${v.authority}  — ${tag}`);
      const copies = members.filter((s) => s !== v.authority);
      if (copies.length) console.log(`      копии: ${copies.join(', ')}`);
    }
  }
  console.log('\nРазъехавшиеся семьи (эталона нет, храповик на число вариантов):');
  for (const d of DRIFTED) {
    const limits = ['py', 'ps1'].filter((l) => d[l]).map((l) => `${l}≤${d.maxVariants[l]}`).join(', ');
    console.log(`  ${d.name}  (${limits})${d.note ? `  — ${d.note}` : ''}`);
  }
  process.exit(0);
}

const copies = FAMILIES.reduce((n, f) => n + f.variants.reduce(
  (m, v) => m + new Set([...membersOf(v, 'py'), ...membersOf(v, 'ps1')]).size, 0), 0);
console.log(`Семей с эталоном: ${FAMILIES.length} (объявленных копий: ${copies}), разъехавшихся: ${DRIFTED.length}`);

if (drift.length) {
  console.log('\nРазъехавшиеся семьи (храповик — число вариантов не должно расти):');
  for (const d of drift) console.log(`  ${d.family} [${d.lang}]: ${d.actual}/${d.limit}`);
}

if (warns.length) {
  console.log(`\nДолг — необоснованные варианты (${warns.length}):`);
  for (const w of warns) console.log(`  [WARN] ${w}`);
}

if (errors.length) {
  console.log(`\n${errors.length} РАСХОЖДЕНИЙ:`);
  for (const e of errors) console.log(`  [ERROR] ${e}`);
  console.log('\nПравка общей утилиты: меняем эталон и копируем во всех потребителей варианта.');
  process.exit(1);
}

console.log('\nOK — все копии совпадают с эталонами своих вариантов.');
