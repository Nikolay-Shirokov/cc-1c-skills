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
  // ─── внешние источники данных: формат файла таблицы один на всех ─────────
  // Таблица внешнего источника — отдельный файл, и создать его может как meta-compile
  // (источник целиком), так и meta-edit (добавить таблицу в существующий). Формат обязан
  // быть один и тот же, поэтому эмиттеры скопированы, а не написаны заново.
  ...[
    // Общие утилиты (Emit-MLText, Emit-FormRef, X и т.п.) сюда не входят: они живут в доброй
    // половине навыков и сводить их — отдельная работа, не относящаяся к внешним источникам.
    ['Get-EdsTables', 'get_eds_tables'],
    ['Get-EdsFieldRef', 'get_eds_field_ref'],
    ['Emit-EdsFieldRefList', 'emit_eds_field_ref_list'],
    ['Emit-EdsFieldRefScalar', 'emit_eds_field_ref_scalar'],
    ['Emit-EdsFunction', 'emit_eds_function'],
    ['Emit-EdsTableProperties', 'emit_eds_table_properties'],
    ['Build-EdsTableXml', 'build_eds_table_xml'],
  ].map(([ps1, py]) => ({
    name: `внешние источники: ${py}`, py, ps1,
    variants: [{ id: 'full', authority: 'meta-compile', consumers: ['meta-edit'] }],
  })),

  // ─── support-guard: запрет правки объекта на поддержке ───────────────────
  {
    name: 'support-guard: assert_edit_allowed', py: 'assert_edit_allowed', ps1: 'Assert-EditAllowed',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'role-edit', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'] },
    ],
  },
  {
    name: 'support-guard: get_edit_mode', py: '_sg_get_edit_mode', ps1: 'Get-EditMode',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'role-edit', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'] },
    ],
  },
  {
    name: 'support-guard: is_external_root', py: '_sg_is_external_root', ps1: 'Test-ExternalObjectRoot',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'role-edit', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit',
          // *-info навыки читают тем же хелпером СОСТОЯНИЕ поддержки для вывода, а не запрещают
          // правку. Тело то же, поэтому семья общая.
          'form-info', 'meta-info', 'mxl-info', 'role-info', 'skd-info', 'subsystem-info',
          // Валидаторы отличают автономную обработку от конфигурации: тот же корень — якорь выгрузки
          // для сверки штампа версии (find_dump_anchor)
          'form-validate', 'interface-validate', 'meta-validate', 'role-validate', 'skd-validate', 'subsystem-validate'] },
    ],
  },
  {
    name: 'support-guard: find_v8project', py: '_sg_find_v8project', ps1: 'Find-V8Project',
    variants: [
      // Имя с префиксом _sg_ историческое: функция просто ищет .v8-project.json обходом
      // вверх. Группа db-* использует её же, чтобы найти запись базы и взять реквизиты
      // хранилища и путь к платформе — задача одна, поэтому семья общая, а не вторая с тем же телом.
      { id: 'full', authority: 'cf-edit',
        consumers: ['cfe-borrow', 'db-cfe-admin', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml',
          'db-load-cf', 'db-load-dt', 'db-load-git', 'db-load-xml', 'db-repo', 'db-run', 'db-update',
          'epf-build', 'epf-dump', 'web-publish', 'v8-xsd-fetch', 'skd-validate',
          'form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'role-edit', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'template-add', 'xdto-compile', 'xdto-edit'] },
    ],
  },
  {
    name: 'support-guard: root_uuid', py: '_sg_root_uuid', ps1: 'Get-RootUuid',
    variants: [
      { id: 'full', authority: 'cf-edit',
        consumers: ['form-add', 'form-compile', 'form-edit', 'help-add', 'interface-edit', 'meta-compile',
          'meta-edit', 'meta-remove', 'mxl-compile', 'role-compile', 'role-edit', 'skd-compile', 'skd-edit',
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
        consumers: ['cfe-borrow', 'cfe-patch-method', 'form-add', 'form-edit', 'help-add', 'interface-edit',
          'meta-compile', 'mxl-compile', 'role-compile', 'role-edit', 'subsystem-compile', 'template-add', 'xdto-compile'] },
    ],
  },
  // Валидаторы сверяют штамп файла со своим дескриптором (ошибка — платформа отвергает части одного
  // объекта в разных версиях) и с якорем выгрузки (предупреждение). Генераторный detect_format_version
  // сюда не годится: без якоря он отдаёт дефолт 2.17, и сравнение с ним было бы ложным.
  {
    name: 'root_version', py: 'root_version', ps1: 'Get-RootVersion',
    variants: [
      { id: 'base', authority: 'meta-validate', consumers: ['cf-validate', 'cfe-validate', 'epf-validate', 'form-validate', 'interface-validate', 'role-validate', 'skd-validate', 'subsystem-validate'] },
    ],
  },
  {
    name: 'find_dump_anchor', py: 'find_dump_anchor', ps1: 'Find-DumpAnchor',
    variants: [
      { id: 'base', authority: 'meta-validate', consumers: ['form-validate', 'interface-validate', 'role-validate', 'skd-validate', 'subsystem-validate'] },
    ],
  },
  {
    name: 'ext_body_owner', py: 'ext_body_owner', ps1: 'Get-ExtBodyOwner',
    variants: [
      { id: 'base', authority: 'form-validate', consumers: ['interface-validate', 'role-validate'] },
    ],
  },
  {
    name: 'format_rank', py: 'format_rank', ps1: 'Get-FormatRank',
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: ['cf-init', 'cf-validate', 'cfe-borrow', 'cfe-init', 'cfe-patch-method', 'cfe-validate', 'epf-build',
          'epf-init', 'epf-validate', 'erf-init', 'form-add', 'form-compile', 'form-edit', 'form-validate',
          'meta-validate', 'mxl-compile', 'role-compile', 'role-edit', 'skd-validate', 'subsystem-compile', 'subsystem-edit',
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

  // ─── Встроенный язык 1С в двух написаниях ────────────────────────────────
  // Платформа принимает и русские, и английские ключевые слова, поэтому разбор модуля обязан
  // читать оба написания. Таблица пар — данные, но живёт функцией: гард видит только функции,
  // а разъехавшаяся пара слов даёт ровно тот тихий ложно-чистый отчёт, из-за которого всё это
  // и делалось (ишью #97).
  {
    name: 'BSL: таблица ключевых слов', py: 'bsl_keywords', ps1: 'Get-BslKeywords',
    variants: [
      { id: 'base', authority: 'cfe-patch-method', consumers: ['cfe-diff', 'cfe-validate'] },
    ],
  },
  {
    name: 'BSL: вид маркера правки', py: 'bsl_marker_kind', ps1: 'Get-BslMarkerKind',
    variants: [
      { id: 'base', authority: 'cfe-patch-method', consumers: ['cfe-diff'] },
    ],
  },
  {
    name: 'BSL: разбор аннотаций перехвата', py: 'get_interceptors', ps1: 'Get-Interceptors',
    variants: [
      { id: 'base', authority: 'cfe-patch-method', consumers: ['cfe-diff'] },
    ],
  },

  // ─── СКД: краткая запись значения ────────────────────────────────────────
  // compile и edit читают вариант стандартного периода в краткой записи как период, а decompile
  // по тому же списку решает, можно ли строку записать кратко. Разъехавшийся список даёт тихую
  // подмену строки периодом на круге decompile → compile (ревью #119).
  {
    name: 'СКД: варианты стандартного периода', py: 'standard_period_variants', ps1: 'Get-StandardPeriodVariants',
    variants: [
      { id: 'base', authority: 'skd-compile', consumers: ['skd-edit', 'skd-decompile'] },
    ],
  },
  // Вариант периода принимается в любом регистре, а в XML уходит написанием платформы — иначе
  // значение перечисления недопустимо, а compile и edit напишут одно и то же по-разному.
  {
    name: 'СКД: вариант периода в каноничном написании', py: 'resolve_standard_period_variant', ps1: 'Resolve-StandardPeriodVariant',
    variants: [
      { id: 'base', authority: 'skd-compile', consumers: ['skd-edit'] },
    ],
  },
  // Какое значение краткой записи — ссылка (DesignTimeValue). Урезанные копии регулярки писали
  // Задача.X.Y в отборе строкой, а decompile при этом опускал тип, полагаясь на авто-определение.
  {
    name: 'СКД: литерал ссылки в значении', py: 'is_ref_value_literal', ps1: 'Test-RefValueLiteral',
    variants: [
      { id: 'base', authority: 'skd-compile', consumers: ['skd-edit', 'skd-decompile'] },
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
  // ─── Код языка страницы ──────────────────────────────────────────────────
  // Формат «дескриптор + страница» общий у справки объекта и HTML-макета, поэтому проверка
  // кода языка обязана быть одна и та же: он идёт и в текст XML, и в имя файла.
  {
    name: 'is_valid_lang', py: 'is_valid_lang', ps1: 'Test-LangCode',
    variants: [
      { id: 'base', authority: 'template-add', consumers: ['help-add'] },
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

  {
    name: 'parse_primitive_type', py: 'parse_primitive_type', ps1: 'Parse-PrimitiveType',
    // Number/String/Date: грамматика и синонимы одни на все навыки; умолчание голого типа зависит
    // от места (хранимый реквизит 10,0/10, СКД и макет — без ограничения) и приходит аргументами.
    variants: [
      { id: 'base', authority: 'meta-compile', consumers: ['meta-edit', 'form-compile', 'form-edit', 'skd-compile', 'skd-edit', 'mxl-compile'] },
    ],
  },

  {
    name: 'get_value_kind_type', py: 'get_value_kind_type', ps1: 'Get-ValueKindType',
    // Вид значения для эмиттеров значений параметров: примитив любого написания → decimal/string/date/…
    variants: [
      { id: 'base', authority: 'skd-compile', consumers: ['skd-edit', 'form-compile', 'form-edit'] },
    ],
  },
  {
    name: 'add_nonneg_flag', py: 'add_nonneg_flag', ps1: 'Add-NonnegFlag',
    variants: [{ id: 'base', authority: 'meta-compile', consumers: ['meta-edit'] }],
  },
  {
    name: 'get_fill_type_category', py: 'get_fill_type_category', ps1: 'Get-FillTypeCategory',
    // Категория типа реквизита для пустого FillValue — одна у создания и правки
    variants: [{ id: 'base', authority: 'meta-compile', consumers: ['meta-edit'] }],
  },

  // ─── Экранирование XML ───────────────────────────────────────────────────
  // Платформа в ТЕКСТЕ элемента экранирует только & < > (кавычка и апостроф остаются сырыми —
  // проверено раундтрипом через базу), а в ЗНАЧЕНИИ АТРИБУТА добавляет &quot;: внутри "..."
  // литеральная кавычка невалидна. Отсюда две функции, а не одна с переключателем.
  {
    name: 'esc_xml (значение атрибута)', py: 'esc_xml', ps1: 'Esc-Xml',
    variants: [
      { id: 'attr-with-quot', authority: 'meta-compile',
        consumers: ['form-compile', 'form-edit', 'meta-edit', 'mxl-compile', 'role-compile', 'role-edit',
          'skd-compile', 'skd-edit', 'subsystem-compile', 'subsystem-edit'] },
    ],
  },
  {
    name: 'esc_xml_text (текст элемента)', py: 'esc_xml_text', ps1: 'Esc-XmlText',
    variants: [
      { id: 'text-no-quot', authority: 'meta-compile',
        consumers: ['cf-init', 'cfe-init', 'epf-init', 'erf-init', 'form-compile', 'form-edit',
          'meta-edit', 'mxl-compile', 'role-compile', 'role-edit', 'skd-compile', 'skd-edit',
          'subsystem-compile', 'subsystem-edit', 'xdto-compile'] },
    ],
  },
  // ─── Ошибка разбора XML: блок для вывода вместо трассы ───────────────────
  // Функция только строит строки (место, сообщение парсера, выдержка с указателем); что печатать
  // вокруг — итог валидатора, коды выхода — решает навык. Поэтому тело общее у validate и info.
  {
    name: 'format_xml_parse_error', py: 'format_xml_parse_error', ps1: 'Format-XmlParseError',
    variants: [
      { id: 'excerpt', authority: 'mxl-validate', consumers: ['mxl-info'] },
    ],
  },
  // ─── Сохранение стиля XML при round-trip (#44/#46/#47) ───────────────────
  {
    name: 'detect_xml_style', py: '_detect_xml_style', ps1: 'Detect-XmlStyle',
    variants: [
      { id: 'base', authority: 'cf-edit', consumers: ['role-edit'],
        // PS-сторона семьи пока закрыта только в радиусе задачи про порядок объектов;
        // в остальных навыках та же канонизация лежит инлайном — отдельная волна.
        consumersPy: ['cfe-borrow', 'form-add', 'form-remove', 'help-add', 'interface-edit', 'meta-edit',
          'meta-remove', 'subsystem-edit', 'template-add', 'template-remove'],
        consumersPs1: ['cfe-borrow'] },
    ],
  },
  {
    name: 'finalize_xml_bytes', py: '_finalize_xml_bytes', ps1: 'Finalize-XmlText',
    variants: [
      { id: 'base', authority: 'cf-edit', consumers: ['role-edit'],
        // PS-сторона семьи пока закрыта только в радиусе задачи про порядок объектов;
        // в остальных навыках та же канонизация лежит инлайном — отдельная волна.
        consumersPy: ['cfe-borrow', 'form-add', 'form-remove', 'help-add', 'interface-edit', 'meta-edit',
          'meta-remove', 'subsystem-edit', 'template-add', 'template-remove'],
        consumersPs1: ['cfe-borrow'] },
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
  // ─── Постусловие применимости расширения ────────────────────────────────
  // Проверку ОБЯЗАТЕЛЬНО запускать отдельным процессом: в одной командной строке DESIGNER
  // выполняет только последнюю пакетную команду, и дописанная проверка отменяет саму загрузку.
  // Разъехавшиеся копии означали бы, что один навык предупреждает о неприменимом расширении,
  // а соседний по той же операции — молчит.
  {
    name: 'apply check: run', py: 'run_apply_check', ps1: 'Invoke-ApplyCheck',
    variants: [
      { id: 'base', authority: 'db-load-xml', consumers: ['db-load-cf', 'db-load-git', 'db-update'] },
    ],
  },
  {
    name: 'apply check: report', py: 'apply_check_report', ps1: 'Invoke-ApplyCheckReport',
    variants: [
      { id: 'base', authority: 'db-load-xml', consumers: ['db-load-cf', 'db-load-git', 'db-update'] },
    ],
  },
  {
    name: 'apply check: enabled', py: 'apply_check_enabled', ps1: 'Get-ApplyCheckEnabled',
    variants: [
      { id: 'base', authority: 'db-load-xml', consumers: ['db-load-cf', 'db-load-git', 'db-update'] },
    ],
  },
  // Дополнительные аргументы: и владение ключами, и запрет пакетных команд. Разъехавшиеся копии
  // означали бы, что один навык отбивает команду, отменяющую его же операцию, а соседний — нет.
  {
    name: 'platform: assert_extra_args', py: 'assert_extra_args', ps1: 'Assert-ExtraArgs',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-cfe-admin', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt',
          'db-load-git', 'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump'] },
      // В epf-build два скрипта, и копия семьи есть в каждом — гард сверяет обе.
    ],
  },
  // Проектные v8args/ibcmdargs: 15 копий чтения .v8-project.json — разъехавшись, порт режет строку
  // на символы, а соседний берёт её одним аргументом.
  {
    name: 'platform: project_extra_args', py: 'project_extra_args', ps1: 'Get-ProjectExtraArgs',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-cfe-admin', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt',
          'db-load-git', 'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump'] },
    ],
  },
  // Квотирование доп. аргументов 1cv8: без кавычек платформа молча режет значение по пробелу
  // (debug/v8args-quoting). db-run собирает строку для Start-Process/Popen сам — вне семьи.
  {
    name: 'platform: quote_if_needed', py: 'quote_if_needed', ps1: 'ConvertTo-QuotedIfNeeded',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-cfe-admin', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt',
          'db-load-git', 'db-load-xml', 'db-repo', 'db-update', 'epf-build', 'epf-dump'] },
    ],
  },
  {
    name: 'platform: arg_key_match', py: 'arg_key_match', ps1: 'Test-ArgKeyMatch',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-cfe-admin', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt',
          'db-load-git', 'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump'] },
    ],
  },
  {
    name: 'platform: resolve_extra_args', py: 'resolve_extra_args', ps1: 'Resolve-ExtraArgs',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'db-cfe-admin'] },
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
          'db-load-xml', 'db-repo', 'db-update', 'epf-build', 'epf-dump', 'db-cfe-admin'] },
    ],
  },
  {
    name: 'platform: decode_platform_bytes', py: 'decode_platform_bytes', ps1: 'ConvertFrom-PlatformBytes',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-update', 'epf-build', 'epf-dump', 'db-cfe-admin'] },
    ],
  },
  {
    name: 'platform: redact', py: '_redact', ps1: 'Protect-Secrets',
    variants: [
      { id: 'base', authority: 'db-dump-cf',
        consumers: ['db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'db-cfe-admin'] },
    ],
  },
  {
    name: 'platform: version_key', py: '_version_key', ps1: null,
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'web-publish', 'db-cfe-admin'] },
    ],
  },
  {
    name: 'platform: version_dir', py: '_version_dir', ps1: null,
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'web-publish', 'db-cfe-admin'] },
    ],
  },
  {
    // Обёртка выбора платформы: запись базы → корневой v8path → автопоиск. В PS1 её роль
    // играет не функция, а блок кода после объявления Find-ProjectV8Path, поэтому ps1: null.
    name: 'platform: resolve_v8path', py: 'resolve_v8path', ps1: null,
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'db-cfe-admin'] },
    ],
  },
  {
    name: 'platform: find_project_v8path', py: '_find_project_v8path', ps1: 'Find-ProjectV8Path',
    variants: [
      { id: 'base', authority: 'db-create',
        consumers: ['db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt', 'db-load-git',
          'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump', 'web-publish', 'db-cfe-admin'] },
    ],
  },

  {
    name: 'repository: load hints', py: 'write_repository_hints', ps1: 'Write-RepositoryHints',
    variants: [{ id: 'base', authority: 'db-load-xml', consumers: ['db-load-git'] }],
  },
  // ─── Запись базы в .v8-project.json ──────────────────────────────────────
  // Модель не передаёт ни реквизиты хранилища (без них база под хранилищем не принимает
  // ни одной операции конфигуратора), ни путь к платформе конкретной базы: скрипт сам
  // сопоставляет параметры соединения с записью в databases[]. Матч один на обе задачи,
  // поэтому блок копируется во все навыки, запускающие платформу.
  {
    name: 'repository: same_path', py: 'same_path', ps1: 'Test-SamePath',
    variants: [{ id: 'base', authority: 'db-repo',
      consumers: ['db-cfe-admin', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf',
        'db-load-dt', 'db-load-git', 'db-load-xml', 'db-run', 'db-update', 'epf-build', 'epf-dump',
        'web-publish'] }],
  },
  {
    name: 'repository: find_project_database', py: 'find_project_database', ps1: 'Find-ProjectDatabase',
    variants: [{ id: 'base', authority: 'db-repo',
      consumers: ['db-cfe-admin', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf',
        'db-load-dt', 'db-load-git', 'db-load-xml', 'db-run', 'db-update', 'epf-build', 'epf-dump',
        'web-publish'] }],
  },
  {
    // Относительный -InfoBasePath — от корня проекта, как configSrc: ibcmd считает его от --data.
    name: 'repository: resolve_infobase_path', py: 'resolve_infobase_path', ps1: 'Resolve-InfoBasePath',
    variants: [{ id: 'base', authority: 'db-repo',
      consumers: ['db-cfe-admin', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf',
        'db-load-dt', 'db-load-git', 'db-load-xml', 'db-run', 'db-update', 'epf-build', 'epf-dump',
        'web-publish'] }],
  },
  {
    // Пути файлов и каталогов — абсолютные от рабочего каталога: ibcmd отбрасывает ведущие «..».
    name: 'paths: resolve_work_path', py: 'resolve_work_path', ps1: 'Resolve-WorkPath',
    variants: [{ id: 'base', authority: 'db-load-xml',
      consumers: ['db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf', 'db-load-dt',
        'db-load-git', 'epf-build', 'epf-dump'] }],
  },
  {
    // Очистка пути, переданного вызывающим: кавычки, хвостовой разделитель, отказ на «C:x».
    name: 'paths: clean_path', py: 'clean_path', ps1: 'ConvertTo-CleanPath',
    variants: [{ id: 'base', authority: 'db-load-xml',
      consumers: ['db-cfe-admin', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml', 'db-load-cf',
        'db-load-dt', 'db-load-git', 'db-repo', 'db-run', 'db-update', 'epf-build', 'epf-dump',
        'web-publish'] }],
  },
  {
    name: 'repository: resolve_settings', py: 'resolve_repository_settings', ps1: 'Resolve-RepositorySettings',
    variants: [{ id: 'base', authority: 'db-repo', consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-update', 'db-cfe-admin'] }],
  },
  {
    name: 'repository: args', py: 'repository_args', ps1: 'Get-RepositoryArgs',
    variants: [{ id: 'base', authority: 'db-repo', consumers: ['db-dump-xml', 'db-load-git', 'db-load-xml', 'db-update', 'db-cfe-admin'] }],
  },

  // ─── Значения свойств-перечислений ───────────────────────────────────────
  // Сама функция одинакова в обоих портах; СПИСКИ значений, на которые она опирается, держит
  // отдельный гард check-enum-drift.mjs (авторитет тот же — meta-compile).
  {
    name: 'normalize_enum_value', py: 'normalize_enum_value', ps1: 'Normalize-EnumValue',
    variants: [{ id: 'base', authority: 'meta-compile', consumers: ['meta-edit', 'form-compile', 'form-edit'] }],
  },

  // ─── Регистронезависимый ввод: паритет с PS1 ─────────────────────────────
  // Существует только в PY: PowerShell регистронезависим сам по себе (свойства PSObject, ключи
  // Hashtable, -eq/-contains, имена параметров, ValidateSet), поэтому в .ps1 копии нет и быть
  // не должно — ps1: null.
  // Замыкание прав и фильтр значений по умолчанию: обе роли обязаны считать одинаково, иначе
  // созданная и отредактированная роль разойдутся между собой и с платформой.
  {
    name: 'права роли: get_rights_object_uuid', py: 'get_rights_object_uuid', ps1: 'Get-RightsObjectUuid',
    variants: [{ id: 'base', authority: 'role-compile', consumers: ['role-edit'] }],
  },
  {
    name: 'права роли: is_standard_kind', py: 'is_standard_kind', ps1: 'Test-StandardKind',
    variants: [{ id: 'base', authority: 'role-compile', consumers: ['role-edit'] }],
  },
  {
    name: 'права роли: close_rights_dependencies', py: 'close_rights_dependencies', ps1: 'Close-RightsDependencies',
    variants: [{ id: 'base', authority: 'role-compile', consumers: ['role-edit'] }],
  },
  {
    name: 'права роли: get_default_right_value', py: 'get_default_right_value', ps1: 'Get-DefaultRightValue',
    variants: [{ id: 'base', authority: 'role-compile', consumers: ['role-edit'] }],
  },
  // Значение операции может быть "@путь" — текст читается из файла. Правило поиска общее:
  // абсолютный путь как есть, относительный — рядом с DSL (или с редактируемым объектом),
  // затем в текущем каталоге. Разъедется — и один навык начнёт искать не там, где другой.
  {
    name: 'значение из файла: resolve_text_from_file', py: 'resolve_text_from_file', ps1: 'Resolve-TextFromFile',
    variants: [
      { id: 'base', authority: 'skd-edit',
        consumers: ['form-compile', 'form-edit', 'role-compile', 'role-edit', 'skd-compile'] },
    ],
  },
  {
    name: 'case-insensitive input: CIDict', py: 'CIDict', ps1: null,
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: [
          'cf-edit', 'form-compile', 'form-edit', 'interface-edit', 'meta-edit', 'mxl-compile',
          'role-compile', 'role-edit', 'skd-compile', 'subsystem-compile', 'subsystem-edit'] }],
  },
  {
    name: 'case-insensitive input: ci_json', py: 'ci_json', ps1: null,
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: [
          'cf-edit', 'form-compile', 'form-edit', 'interface-edit', 'meta-edit', 'mxl-compile',
          'role-compile', 'role-edit', 'skd-compile', 'subsystem-compile', 'subsystem-edit'] }],
  },
  {
    // Единственная из трёх, которая нужна КАЖДОМУ порту: DSL читают не все навыки, а параметры — все.
    name: 'case-insensitive input: ci_parse_args', py: 'ci_parse_args', ps1: null,
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: [
          'cf-edit', 'cf-info', 'cf-init', 'cf-validate', 'cfe-borrow', 'cfe-diff', 'cfe-init',
          'cfe-patch-method', 'cfe-validate', 'db-cfe-admin', 'db-create', 'db-dump-cf', 'db-dump-dt', 'db-dump-xml',
          'db-load-cf', 'db-load-dt', 'db-load-git', 'db-load-xml', 'db-repo', 'db-run', 'db-update', 'epf-build',
          'epf-dump', 'epf-init', 'epf-validate', 'erf-init', 'form-add', 'form-compile',
          'form-decompile', 'form-edit', 'form-info', 'form-remove', 'form-validate', 'help-add',
          'img-grid', 'interface-edit', 'interface-validate', 'meta-decompile', 'meta-edit', 'meta-info',
          'meta-remove', 'meta-validate', 'mxl-compile', 'mxl-decompile', 'mxl-info', 'mxl-validate',
          'role-compile', 'role-edit', 'role-info', 'role-validate', 'skd-compile', 'skd-decompile', 'skd-edit',
          'skd-info', 'skd-validate', 'subsystem-compile', 'subsystem-edit', 'subsystem-info',
          'subsystem-validate', 'support-edit', 'template-add', 'template-remove', 'web-info',
          'web-publish', 'web-stop', 'web-unpublish', 'xdto-compile', 'xdto-decompile', 'xdto-edit',
          'xdto-info', 'xdto-validate', 'v8-xsd-fetch'] },
    ],
  },

  // ─── Авто-вывод заголовка из имени элемента формы ────────────────────────
  // Компилятор пишет заголовок, которого нет в DSL, декомпилятор на этом же выводе решает, можно
  // ли заголовок опустить. Разъехались копии — заголовок либо теряется, либо дублируется, и в
  // обоих случаях текст на форме меняется молча, без ошибки платформы (PR #91).
  {
    name: 'авто-заголовок из имени: title_from_name', py: 'title_from_name', ps1: 'Title-FromName',
    variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-decompile', 'form-edit'] }],
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
        why: 'родителем бывает вложенный Subsystem.xml произвольной глубины: отступ берётся из документа, а запись дописывается в конец блока — фиксированные три табуляции там неверны, и группировать по типу нечего' },
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
          'role-compile', 'role-edit', 'skd-compile', 'skd-decompile', 'subsystem-compile', 'subsystem-edit'] },
    ],
  },
  {
    name: 'parse_json_input', py: 'parse_json_input', ps1: 'ConvertFrom-JsonInput',
    variants: [
      { id: 'base', authority: 'interface-edit',
        consumers: ['cf-edit', 'form-compile', 'form-edit', 'meta-compile', 'meta-edit', 'mxl-compile',
          'role-compile', 'role-edit', 'skd-compile', 'skd-decompile', 'subsystem-compile', 'subsystem-edit'] },
    ],
  },

  // ─── Порядок объектов метаданных в <ChildObjects> ────────────────────────
  // Куда встаёт новая запись — решение проекта (newObjectPosition в .v8-project.json),
  // а не навыка. Компаратор при этом константа: он моделирует дерево Конфигуратора и
  // одинаков для всех проектов, поэтому команда сортировки cf-edit настройку не читает.
  {
    name: 'ChildObjects: настройка newObjectPosition',
    py: 'get_new_object_position', ps1: 'Get-NewObjectPosition',
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: ['cf-edit', 'cfe-borrow', 'role-compile', 'xdto-compile'] },
    ],
  },
  {
    name: 'ChildObjects: виды с осмысленным порядком',
    py: 'is_order_sensitive_type', ps1: 'Test-OrderSensitiveType',
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: ['cf-edit', 'cfe-borrow', 'role-compile', 'xdto-compile'] },
    ],
  },
  {
    name: 'ChildObjects: порядок имён объектов',
    py: 'compare_metadata_names', ps1: 'Compare-MetadataNames',
    variants: [
      { id: 'base', authority: 'meta-compile',
        consumers: ['cf-edit', 'cfe-borrow', 'role-compile', 'xdto-compile'] },
    ],
  },
  // ─── Имя команды объекта ≠ стандартная команда вида (замер 8.3.24/8.3.27) ─────
  {
    name: 'Команды объекта: имена стандартных команд по виду',
    py: 'reserved_command_names', ps1: 'Get-ReservedCommandNames',
    variants: [
      { id: 'base', authority: 'meta-validate', consumers: ['meta-compile', 'meta-edit'] },
    ],
  },
  // ─── Порядок групп в <ChildObjects> ОБЪЕКТА (#123) ──────────────────────
  // Канон зависит от вида (у документа Form до TabularSection) и равен xs:sequence <Вид>ChildObjects
  // из MDClasses XSD; таблицу в коде с таблицей спеки (и с XSD, если скачан) сверяет check-object-child-order.
  {
    name: 'ChildObjects объекта: канон групп по виду',
    py: 'object_child_order', ps1: 'Get-ObjectChildOrder',
    variants: [
      { id: 'base', authority: 'meta-edit',
        consumers: ['cfe-borrow', 'form-add', 'form-compile', 'meta-validate', 'template-add'] },
    ],
  },
  {
    name: 'ChildObjects объекта: место вставки (DOM)',
    py: 'find_child_anchor', ps1: 'Find-ChildAnchor',
    variants: [
      { id: 'base', authority: 'meta-edit',
        consumers: ['cfe-borrow', 'form-add', 'template-add'],
        consumersPs1: ['form-compile'] },
    ],
  },
  {
    name: 'ChildObjects объекта: место вставки (текст)',
    py: 'insert_into_own_child_objects_by_canon', ps1: 'Insert-IntoOwnChildObjectsByCanon',
    variants: [
      { id: 'base', authority: 'cfe-borrow', consumers: [],
        consumersPy: ['form-compile'] },
    ],
  },
  // ── Эмиттер элементов формы: form-edit добавляет элементы тем же кодом, что form-compile ──
  { name: 'Assert-UniqueName', py: null, ps1: 'Assert-UniqueName', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_ml_items', py: 'emit_ml_items', ps1: 'Emit-MLItems', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'own', authority: 'meta-compile', consumers: ['meta-edit'], why: 'своя реализация для свойств метаданных объекта (meta-*), не копия эмиттера формы' }] },
  { name: 'Test-HasRealMarkup', py: null, ps1: 'Test-HasRealMarkup', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-decompile', 'form-edit'] }] },
  { name: 'resolve_ml_formatted', py: 'resolve_ml_formatted', ps1: 'Resolve-MLFormatted', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_type', py: 'emit_type', ps1: 'Emit-Type', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_single_type', py: 'emit_single_type', ps1: 'Emit-SingleType', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_handler_name', py: 'get_handler_name', ps1: 'Get-HandlerName', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_element_name', py: 'get_element_name', ps1: 'Get-ElementName', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_call_type', py: 'normalize_call_type', ps1: 'Normalize-CallType', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'resolve_event_name', py: 'resolve_event_name', ps1: 'Resolve-EventName', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_event_pairs', py: 'get_event_pairs', ps1: 'Get-EventPairs', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_events', py: 'emit_events', ps1: 'Emit-Events', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Test-CompanionStructured', py: null, ps1: 'Test-CompanionStructured', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_companion_title', py: 'emit_companion_title', ps1: 'Emit-CompanionTitle', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'di_attr', py: 'di_attr', ps1: 'DI-Attr', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_companion', py: 'emit_companion', ps1: 'Emit-Companion', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_companion_panel', py: 'emit_companion_panel', ps1: 'Emit-CompanionPanel', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_hlocation', py: 'get_hlocation', ps1: 'Get-HLocation', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_addition_body', py: 'emit_addition_body', ps1: 'Emit-AdditionBody', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_addition', py: 'emit_addition', ps1: 'Emit-Addition', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_table_addition', py: 'emit_table_addition', ps1: 'Emit-TableAddition', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_addition_override', py: 'get_addition_override', ps1: 'Get-AdditionOverride', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_element_type_synonyms', py: 'normalize_element_type_synonyms', ps1: 'Normalize-ElementTypeSynonyms', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_element', py: 'emit_element', ps1: 'Emit-Element', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_xr_flag', py: 'emit_xr_flag', ps1: 'Emit-XrFlag', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_common_flags', py: 'emit_common_flags', ps1: 'Emit-CommonFlags', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_common_element_props', py: 'emit_common_element_props', ps1: 'Emit-CommonElementProps', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_picture_ref', py: 'emit_picture_ref', ps1: 'Emit-PictureRef', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_column_pics', py: 'emit_column_pics', ps1: 'Emit-ColumnPics', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_command_picture', py: 'emit_command_picture', ps1: 'Emit-CommandPicture', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'own', authority: 'meta-compile', consumers: [], why: 'своя реализация для свойств метаданных объекта (meta-*), не копия эмиттера формы' }] },
  { name: 'emit_generic_scalars', py: 'emit_generic_scalars', ps1: 'Emit-GenericScalars', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_appearance_value', py: 'get_appearance_value', ps1: 'Get-AppearanceValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_font_tag', py: 'emit_font_tag', ps1: 'Emit-FontTag', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_border_tag', py: 'emit_border_tag', ps1: 'Emit-BorderTag', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_appearance', py: 'emit_appearance', ps1: 'Emit-Appearance', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_layout', py: 'emit_layout', ps1: 'Emit-Layout', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_title', py: 'emit_title', ps1: 'Emit-Title', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'map_title_loc', py: 'map_title_loc', ps1: 'Map-TitleLoc', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_title_location', py: 'emit_title_location', ps1: 'Emit-TitleLocation', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_warn_unrecognized', py: '_warn_unrecognized', ps1: 'Warn-Unrecognized', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_group', py: 'emit_group', ps1: 'Emit-Group', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_column_group', py: 'emit_column_group', ps1: 'Emit-ColumnGroup', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_input', py: 'emit_input', ps1: 'Emit-Input', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_check', py: 'emit_check', ps1: 'Emit-Check', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_choice_value', py: 'normalize_choice_value', ps1: 'Normalize-ChoiceValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'meta-compile', authority: 'meta-compile', consumers: [], why: 'своя реализация для свойств метаданных объекта (meta-*), не копия эмиттера формы' }, { id: 'meta-edit', authority: 'meta-edit', consumers: [], why: 'правка свойства на месте, своя реализация' }] },
  { name: 'emit_choice_presentation', py: 'emit_choice_presentation', ps1: 'Emit-ChoicePresentation', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Get-ChoiceValueTag', py: null, ps1: 'Get-ChoiceValueTag', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_choice_list', py: 'emit_choice_list', ps1: 'Emit-ChoiceList', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_el_prop', py: 'get_el_prop', ps1: 'Get-ElProp', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'ConvertTo-ScalarLiteral', py: null, ps1: 'ConvertTo-ScalarLiteral', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'ConvertFrom-ChoiceParamShorthand', py: null, ps1: 'ConvertFrom-ChoiceParamShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'ConvertFrom-ChoiceParamLinkShorthand', py: null, ps1: 'ConvertFrom-ChoiceParamLinkShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'ConvertFrom-TypeLinkShorthand', py: null, ps1: 'ConvertFrom-TypeLinkShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_choice_param_value', py: 'emit_choice_param_value', ps1: 'Emit-ChoiceParamValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_choice_parameters', py: 'emit_choice_parameters', ps1: 'Emit-ChoiceParameters', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'own', authority: 'meta-compile', consumers: [], why: 'своя реализация для свойств метаданных объекта (meta-*), не копия эмиттера формы' }] },
  { name: 'emit_choice_parameter_links', py: 'emit_choice_parameter_links', ps1: 'Emit-ChoiceParameterLinks', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'own', authority: 'meta-compile', consumers: [], why: 'своя реализация для свойств метаданных объекта (meta-*), не копия эмиттера формы' }] },
  { name: 'emit_type_link', py: 'emit_type_link', ps1: 'Emit-TypeLink', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Emit-Radio', py: null, ps1: 'Emit-Radio', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_decoration_title', py: 'emit_decoration_title', ps1: 'Emit-DecorationTitle', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_label', py: 'emit_label', ps1: 'Emit-Label', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_label_field', py: 'emit_label_field', ps1: 'Emit-LabelField', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dynlist_table_block', py: 'emit_dynlist_table_block', ps1: 'Emit-DynListTableBlock', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_table', py: 'emit_table', ps1: 'Emit-Table', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_pages', py: 'emit_pages', ps1: 'Emit-Pages', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_page', py: 'emit_page', ps1: 'Emit-Page', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_button', py: 'emit_button', ps1: 'Emit-Button', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_picture_decoration', py: 'emit_picture_decoration', ps1: 'Emit-PictureDecoration', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_picture_field', py: 'emit_picture_field', ps1: 'Emit-PictureField', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_calendar', py: 'emit_calendar', ps1: 'Emit-Calendar', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_simple_field', py: 'emit_simple_field', ps1: 'Emit-SimpleField', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_gantt_chart', py: 'emit_gantt_chart', ps1: 'Emit-GanttChart', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_command_bar', py: 'emit_command_bar', ps1: 'Emit-CommandBar', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_button_group', py: 'emit_button_group', ps1: 'Emit-ButtonGroup', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_popup', py: 'emit_popup', ps1: 'Emit-Popup', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_panel_synonyms', py: 'normalize_panel_synonyms', ps1: 'Normalize-PanelSynonyms', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Normalize-ElementSynonyms', py: null, ps1: 'Normalize-ElementSynonyms', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'ApplyDynamicListTableHeuristic', py: null, ps1: 'ApplyDynamicListTableHeuristic', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_ensure_unique', py: '_ensure_unique', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'choice_value_tag', py: 'choice_value_tag', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'to_scalar_literal', py: 'to_scalar_literal', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'from_choice_param_shorthand', py: 'from_choice_param_shorthand', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'from_choice_param_link_shorthand', py: 'from_choice_param_link_shorthand', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'from_type_link_shorthand', py: 'from_type_link_shorthand', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_radio_button_type', py: 'normalize_radio_button_type', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_has_real_markup', py: '_has_real_markup', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_radio_button_field', py: 'emit_radio_button_field', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_normalize_synonyms', py: '_normalize_synonyms', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_apply_dlist_table_heuristic', py: '_apply_dlist_table_heuristic', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  // ── Эмиттеры секций формы (реквизиты, команды, параметры, оформление, интерфейс, свойства) — общие с form-compile ──
  { name: 'emit_us_presentation', py: 'emit_us_presentation', ps1: 'Emit-USPresentation', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'New-Guid-String', py: null, ps1: 'New-Guid-String', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'], why: 'эмиттеры формы (настройки дин-списка)' }, { id: 'meta-compile', authority: 'meta-compile', consumers: ['meta-edit', 'role-edit', 'skd-compile', 'subsystem-compile', 'subsystem-edit'], why: 'своя реализация вне форм' }] },
  { name: 'parse_filter_shorthand', py: 'parse_filter_shorthand', ps1: 'Parse-FilterShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }, { id: 'skd-edit', authority: 'skd-edit', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'Get-ValueTypeNsAttr', py: null, ps1: 'Get-ValueTypeNsAttr', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_filter_item', py: 'emit_filter_item', ps1: 'Emit-FilterItem', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_filter', py: 'emit_filter', ps1: 'Emit-Filter', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_order', py: 'emit_order', ps1: 'Emit-Order', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_appearance_value', py: 'emit_appearance_value', ps1: 'Emit-AppearanceValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_conditional_appearance', py: 'emit_conditional_appearance', ps1: 'Emit-ConditionalAppearance', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'get_list_grouping_value', py: 'get_list_grouping_value', ps1: 'Get-ListGroupingValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'parse_list_grouping', py: 'parse_list_grouping', ps1: 'Parse-ListGrouping', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_group_item_field', py: 'emit_group_item_field', ps1: 'Emit-GroupItemField', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_list_grouping_levels', py: 'emit_list_grouping_levels', ps1: 'Emit-ListGroupingLevels', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_list_grouping', py: 'emit_list_grouping', ps1: 'Emit-ListGrouping', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'parse_calc_shorthand', py: 'parse_calc_shorthand', ps1: 'Parse-CalcShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }, { id: 'skd-edit', authority: 'skd-edit', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_calc_fields', py: 'emit_calc_fields', ps1: 'Emit-CalcFields', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'Get-RestrictList', py: null, ps1: 'Get-RestrictList', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_restrict_block', py: 'emit_restrict_block', ps1: 'Emit-RestrictBlock', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_pl_get', py: '_pl_get', ps1: 'PL-Get', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_pl_bool', py: '_pl_bool', ps1: 'PL-Bool', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_color', py: 'emit_planner_color', ps1: 'Emit-PlannerColor', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_text', py: 'emit_planner_text', ps1: 'Emit-PlannerText', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'test_planner_ref', py: 'test_planner_ref', ps1: 'Test-PlannerRef', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_value', py: 'emit_planner_value', ps1: 'Emit-PlannerValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_font', py: 'emit_planner_font', ps1: 'Emit-PlannerFont', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_border', py: 'emit_planner_border', ps1: 'Emit-PlannerBorder', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_level', py: 'emit_planner_level', ps1: 'Emit-PlannerLevel', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_timescale', py: 'emit_planner_timescale', ps1: 'Emit-PlannerTimeScale', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_item', py: 'emit_planner_item', ps1: 'Emit-PlannerItem', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_dim_element', py: 'emit_planner_dim_element', ps1: 'Emit-PlannerDimElement', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_dimension', py: 'emit_planner_dimension', ps1: 'Emit-PlannerDimension', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_planner_settings', py: 'emit_planner_settings', ps1: 'Emit-PlannerSettings', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Get-Keys', py: null, ps1: 'Get-Keys', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Get-Prop', py: null, ps1: 'Get-Prop', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_chart_node', py: 'emit_chart_node', ps1: 'Emit-ChartNode', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_chart_settings', py: 'emit_chart_settings', ps1: 'Emit-ChartSettings', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_meta_type_ref', py: 'normalize_meta_type_ref', ps1: 'Normalize-MetaTypeRef', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_functional_options', py: 'emit_functional_options', ps1: 'Emit-FunctionalOptions', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_attr_column', py: 'emit_attr_column', ps1: 'Emit-AttrColumn', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dl_mltext', py: 'emit_dl_mltext', ps1: 'Emit-DLMLText', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Has-DLProp', py: null, ps1: 'Has-DLProp', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'split_dl_valuelist_csv', py: 'split_dl_valuelist_csv', ps1: 'Split-DLValueListCsv', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'parse_dl_param_shorthand', py: 'parse_dl_param_shorthand', ps1: 'Parse-DLParamShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Test-DLEmptyValue', py: null, ps1: 'Test-DLEmptyValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dl_value', py: 'emit_dl_value', ps1: 'Emit-DLValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dl_value_type', py: 'emit_dl_value_type', ps1: 'Emit-DLValueType', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dl_available_value', py: 'emit_dl_available_value', ps1: 'Emit-DLAvailableValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dl_input_parameters', py: 'emit_dl_input_parameters', ps1: 'Emit-DLInputParameters', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_test_empty_value', py: '_test_empty_value', ps1: 'Test-EmptyValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'], consumersPs1: ['skd-compile', 'skd-edit'] }] },
  { name: 'emit_empty_value', py: 'emit_empty_value', ps1: 'Emit-EmptyValue', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit', 'skd-compile'] }] },
  { name: 'parse_data_param_shorthand', py: 'parse_data_param_shorthand', ps1: 'Parse-DataParamShorthand', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }, { id: 'skd-edit', authority: 'skd-edit', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_data_parameters', py: 'emit_data_parameters', ps1: 'Emit-DataParameters', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_dl_parameter', py: 'emit_dl_parameter', ps1: 'Emit-DLParameter', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_dl_parameters', py: 'emit_dl_parameters', ps1: 'Emit-DLParameters', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_attributes', py: 'emit_attributes', ps1: 'Emit-Attributes', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_parameters', py: 'emit_parameters', ps1: 'Emit-Parameters', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }, { id: 'skd-compile', authority: 'skd-compile', consumers: [], why: 'своя реализация вне форм' }] },
  { name: 'emit_commands', py: 'emit_commands', ps1: 'Emit-Commands', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_resolve_command_group_key', py: '_resolve_command_group_key', ps1: 'Resolve-CommandGroupKey', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_command_interface', py: 'emit_command_interface', ps1: 'Emit-CommandInterface', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_form_root_rank', py: 'get_form_root_rank', ps1: 'Get-FormRootRank', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'emit_properties', py: 'emit_properties', ps1: 'Emit-Properties', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'new_uuid', py: 'new_uuid', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['cf-init', 'cfe-init', 'epf-build', 'epf-init', 'erf-init', 'form-edit', 'meta-compile', 'meta-edit', 'role-compile', 'skd-compile', 'skd-edit', 'subsystem-compile', 'subsystem-edit'] }] },
  { name: '_value_type_for', py: '_value_type_for', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_value_type_ns_attr', py: '_value_type_ns_attr', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'parse_restrict', py: 'parse_restrict', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'is_dl_empty_value', py: 'is_dl_empty_value', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  // ── Эмиттеры секций формы (реквизиты, команды, параметры, оформление, интерфейс, свойства) — общие с form-compile ──
  { name: 'get_child_rank', py: 'get_child_rank', ps1: 'Get-ChildRank', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit', 'form-validate'] }] },
  { name: 'sort_element_tag_order', py: 'sort_element_tag_order', ps1: 'Sort-ElementTagOrder', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'Get-TagBlockEnd', py: null, ps1: 'Get-TagBlockEnd', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: '_sort_tag_blocks', py: '_sort_tag_blocks', ps1: 'Sort-TagBlocks', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  // ── Каталог событий формы: генерируется из корпуса (debug/form-handlers/gen_event_catalog.py) в оба навыка ──
  { name: 'формы: каталог событий', py: 'get_form_event_catalog', ps1: 'Get-FormEventCatalog', variants: [{ id: 'full', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_event_entry', py: 'get_event_entry', ps1: 'Get-EventEntry', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'test_event_pairs', py: 'test_event_pairs', ps1: 'Test-EventPairs', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'warn_events_ignored', py: 'warn_events_ignored', ps1: 'Warn-EventsIgnored', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_form_owner_kind', py: 'get_form_owner_kind', ps1: 'Get-FormOwnerKind', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_event_rank', py: 'get_event_rank', ps1: 'Get-EventRank', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_edit_distance', py: 'get_edit_distance', ps1: 'Get-EditDistance', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_event_hint', py: 'get_event_hint', ps1: 'Get-EventHint', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'report_unknown_events', py: 'report_unknown_events', ps1: 'Report-UnknownEvents', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'sort_event_pairs', py: 'sort_event_pairs', ps1: 'Sort-EventPairs', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'normalize_main_flag', py: 'normalize_main_flag', ps1: 'Normalize-MainFlag', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  // ── Заготовки обработчиков в модуле формы ──
  { name: 'get_form_module_template', py: 'get_form_module_template', ps1: 'Get-FormModuleTemplate', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit', 'form-add'] }] },
  { name: 'get_extension_name_prefix', py: 'get_extension_name_prefix', ps1: 'Get-ExtensionNamePrefix', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'register_handler', py: 'register_handler', ps1: 'Register-Handler', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_module_code_outline', py: 'get_module_code_outline', ps1: 'Get-ModuleCodeOutline', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_module_outline', py: 'get_module_outline', ps1: 'Get-ModuleOutline', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit', 'form-validate', 'form-info'] }] },
  { name: 'read_module_text', py: 'read_module_text', ps1: 'Read-ModuleText', variants: [{ id: 'base', authority: 'form-validate', consumers: ['form-info'] }] },
  { name: 'get_bsl_scan', py: 'get_bsl_scan', ps1: 'Get-BslScan', variants: [{ id: 'base', authority: 'form-edit', consumers: ['form-validate', 'form-info', 'form-compile'] }] },
  { name: 'get_event_params', py: 'get_event_params', ps1: 'Get-EventParams', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_handler_stub', py: 'get_handler_stub', ps1: 'Get-HandlerStub', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_region_rank', py: 'get_region_rank', ps1: 'Get-RegionRank', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'get_handler_region_name', py: 'get_handler_region_name', ps1: 'Get-HandlerRegionName', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'add_stub_to_module', py: 'add_stub_to_module', ps1: 'Add-StubToModule', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  { name: 'update_form_module', py: 'update_form_module', ps1: 'Update-FormModule', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  {
    name: 'get_table_source', py: 'get_table_source', ps1: 'Get-TableSource',
    variants: [
      { id: 'dsl', authority: 'form-compile', consumers: [],
        why: 'тип реквизита берётся из attributes DSL: форма собирается целиком' },
      { id: 'xml', authority: 'form-edit', consumers: [],
        why: 'тип реквизита берётся из Attributes правимой формы: в DSL правки реквизита таблицы может не быть' },
    ],
  },
  { name: '_tag_block_end', py: '_tag_block_end', ps1: null, variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
  // ── Эмиттеры секций формы (реквизиты, команды, параметры, оформление, интерфейс, свойства) — общие с form-compile ──
  { name: 'normalize_enum_tags', py: 'normalize_enum_tags', ps1: 'Normalize-EnumTags', variants: [{ id: 'base', authority: 'form-compile', consumers: ['form-edit'] }] },
];

// ─── Семьи, разъехавшиеся целиком ───────────────────────────────────────────
// Перечислять «вариант на каждую копию» бессмысленно — эталона у них сейчас нет. Держим храповик:
// число групп не должно расти. Фаза 2 сводит семью к одному телу и переносит её в FAMILIES.

// Разбор каждой оставшейся семьи уже сделан — сведение упирается не в аккуратность, а в решение,
// поэтому note описывает ПРИРОДУ расхождения, а не «когда-нибудь свести».
const DRIFTED = [
  { name: 'emit_mltext', py: 'emit_mltext', ps1: 'Emit-MLText', maxVariants: { py: 4, ps1: 4 },
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

// Навык может держать несколько скриптов (epf-build: epf-build + stub-db-create), и копия
// семьи живёт в каждом из них. Раньше индекс брал ПЕРВУЮ копию по алфавиту, и вторая
// была гарду невидима: в stub-db-create.py так прожили три расхождения, одно из них —
// потерянная POSIX-ветка run_v8. Теперь сверяются ВСЕ копии.
function buildIndex() {
  const index = new Map(); // `${skill}|${lang}` -> Map(name -> [{ file, body }])
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
      for (const [n, b] of fns) acc.set(n, [...(acc.get(n) || []), { file, body: b }]);
      index.set(key, acc);
    }
  }
  return index;
}

// Все копии функции в навыке: [{ file, body }]
function copiesOf(index, skill, lang, name) {
  return index.get(`${skill}|${lang}`)?.get(name) || [];
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
      const hashes = new Map(); // `${skill}` или `${skill} (${file})` -> хеш
      for (const skill of members) {
        const copies = copiesOf(index, skill, lang, fnName);
        if (!copies.length) {
          errors.push(`${family.name} [${lang}]: ${skill} объявлен в варианте '${v.id}', но функции ${fnName} в нём нет`);
          continue;
        }
        for (const { file, body } of copies) {
          // Эталон берётся из главного скрипта навыка (`<навык>.ps1`/`.py`), остальные
          // его скрипты — такие же копии и сверяются наравне.
          const main = file.startsWith(`${skill}.`);
          const label = main ? skill : `${skill} (${file})`;
          hashes.set(label, { hash: hashBody(body, lang), main, skill });
        }
      }
      const authorityHash = hashes.get(v.authority)?.hash;
      if (authorityHash === undefined) continue;
      hashByVariant.set(v.id, authorityHash);
      for (const [label, { hash }] of hashes) {
        if (hash !== authorityHash) {
          errors.push(`${family.name} [${lang}]: ${label} разошёлся с эталоном ${v.authority} (вариант '${v.id}')`);
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

    // 4. Копия обязана быть не только ИДЕНТИЧНОЙ, но и РАЗРЕШИМОЙ: всё, что её тело зовёт,
    // должно быть определено в том же навыке. Иначе получаем вызов несуществующей функции —
    // в PowerShell это тихий ложный успех (CommandNotFoundException, но код возврата 0),
    // а в python трейсбек, то есть ещё и расхождение потоков ошибок между портами.
    // Что считать «вызовом своей функции»: имя, определённое в НАВЫКЕ-ЭТАЛОНЕ. Командлеты и
    // встроенные функции в эталоне не определены, поэтому список исключений не нужен.
    for (const { v, members } of effective) {
      const authorityFns = index.get(`${v.authority}|${lang}`);
      if (!authorityFns) continue;
      for (const skill of members) {
        if (skill === v.authority) continue;
        const skillFns = index.get(`${skill}|${lang}`);
        if (!skillFns) continue;
        for (const { file, body: bodyLines } of copiesOf(index, skill, lang, fnName)) {
          const body = bodyLines.join('\n');   // тело хранится списком строк
          const called = lang === 'ps1'
            ? body.match(/(?<![\w-])[A-Z][a-z]+-[A-Z]\w*/g) || []
            : body.match(/(?<![\w.])[a-z_]\w*(?=\s*\()/g) || [];
          const missing = [...new Set(called)]
            .filter((c) => c !== fnName && authorityFns.has(c) && !skillFns.has(c));
          if (missing.length) {
            const label = file.startsWith(`${skill}.`) ? skill : `${skill} (${file})`;
            errors.push(`${family.name} [${lang}]: ${label} зовёт ${missing.join(', ')} — этих функций в навыке нет, копия неразрешима`);
          }
        }
      }
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
      for (const { file, body } of fns.get(fnName)) {
        const h = hashBody(body, lang);
        if (!groups.has(h)) groups.set(h, []);
        groups.get(h).push(file.startsWith(`${skill}.`) ? skill : `${skill} (${file})`);
      }
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

// ─── Копии документации ─────────────────────────────────────────────────────
// Справочники навыка, который пользуется тем же DSL, что и другой, — копии каталога эталона:
// документация меняется вместе с кодом, а код у них общий (семьи выше). Сверка — файл в файл,
// без BOM и с LF; лишний файл у потребителя — тоже расхождение (он не попадёт в эталон).
const FILE_FAMILIES = [
  { name: 'справочники DSL формы', dir: 'references', authority: 'form-compile', consumers: ['form-edit'] },
];

const normDoc = (p) => readFileSync(p, 'utf8').replace(/^\uFEFF/, '').replace(/\r\n/g, '\n');
for (const ff of FILE_FAMILIES) {
  const src = join(SKILLS, ff.authority, ff.dir);
  const files = readdirSync(src).filter((f) => f.endsWith('.md')).sort();
  for (const c of ff.consumers) {
    const dst = join(SKILLS, c, ff.dir);
    if (!existsSync(dst)) { errors.push(`${ff.name}: у ${c} нет каталога ${ff.dir}/`); continue; }
    for (const f of files) {
      if (!existsSync(join(dst, f))) errors.push(`${ff.name}: у ${c} нет ${ff.dir}/${f} (есть у эталона ${ff.authority})`);
      else if (normDoc(join(src, f)) !== normDoc(join(dst, f))) errors.push(`${ff.name}: ${c}/${ff.dir}/${f} разошёлся с эталоном ${ff.authority}`);
    }
    for (const f of readdirSync(dst).filter((x) => x.endsWith('.md'))) {
      if (!files.includes(f)) errors.push(`${ff.name}: ${c}/${ff.dir}/${f} — нет у эталона ${ff.authority} (правку вносим в эталон и копируем)`);
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
