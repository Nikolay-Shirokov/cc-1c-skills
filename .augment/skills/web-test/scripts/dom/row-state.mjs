// web-test dom/row-state v1.0 — leading row-state sprite decoding
// Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
/**
 * Ведущая иконка состояния строки списка.
 *
 * 1С рисует состояние строки (проведён / помечен на удаление / выполнена / …) отдельным спрайтом,
 * приходящим из `e1cib/convertPicture?url=e1csys/<dir>/<file>.zip&…&gx=<N>`, где `gx` — индекс кадра.
 * Это НЕ то же самое, что именованные pic-колонки (`pictureCollection/picture/<id>`) — у тех другой
 * URL и другой смысл (значение ячейки), их разбирает picInfo() в grid.mjs.
 *
 * Ключ словаря — ПОЛНЫЙ путь спрайта, не имя файла: `basic/folder.zip` (справочники) и
 * `accnt/folder.zip` (план счетов) — разные файлы с одинаковым именем и РАЗНОЙ раскладкой gx
 * (у basic gx=1 — элемент, у accnt gx=1 — предопределённый). Нормализация до имени файла склеила бы
 * их и дала неверную расшифровку.
 *
 * Набор осей свой у каждого спрайта: docList → deleted+posted, folder → deleted+predefined,
 * Task → deleted+completed. Неприменимая ось не эмитится. Незнакомый путь или нерасшифрованный gx →
 * только `_rowPic`, без булевых: ОТСУТСТВИЕ БУЛЕВА ЗНАЧИТ «НЕ ЗНАЮ», а не false.
 *
 * Раскладки сняты живьём на ERP и подтверждены отрисовкой кадров спрайта (convertPicture&scale).
 */
export const ROW_STATE_FN = `function rowStateInfo(line) {
  // Словарь: полный путь → (gx → набор осей). null = кадр не расшифрован (только _rowPic).
  const SPRITES = {
    // Документы, журналы документов. Спрайт — СЕТКА: база + 3·пометка_удаления.
    // База: 0 записан, 1 проведён, 2 «загнутый угол» (не расшифрован).
    // Кадров ровно 6 (gx 6..8 пустые). gx4 (проведён+помечен) на практике недостижим:
    // пометка проведённого документа его распроводит.
    'e1csys/basic/docList.zip': function (gx) {
      if (gx > 5) return null;
      const base = gx % 3, deleted = gx >= 3;
      if (base === 2) return { deleted: deleted };   // база не расшифрована → posted не эмитим
      return { deleted: deleted, posted: base === 1 };
    },
    // Справочники, планы видов характеристик. Ось группа/элемент СОЗНАТЕЛЬНО не выводим —
    // _kind живёт от .gridListH/.gridListV, на нём завязана иерархия.
    //
    // Кадры 4/5 — не «неизвестное состояние», а ВТОРОЕ измерение: у справочника с иерархией
    // элементов (ERP «Партнеры») родитель — элемент, а не папка, и платформа берёт кадр 4.
    // Кадры попарно байт-в-байт равны: gx4 ≡ gx1 (чистый элемент), gx5 ≡ gx3 (элемент + красный
    // крест), gx8 ≡ gx7. Что означает второе измерение — знать не нужно: обе НАШИ оси кадр
    // задаёт однозначно (крест есть → помечен).
    'e1csys/basic/folder.zip': {
      0: { deleted: false, predefined: false },   // группа
      1: { deleted: false, predefined: false },   // элемент
      2: { deleted: true,  predefined: false },   // группа, помечена
      3: { deleted: true,  predefined: false },   // элемент, помечен
      4: { deleted: false, predefined: false },   // элемент-узел иерархии (кадр ≡ gx1)
      5: { deleted: true,  predefined: false },   // элемент-узел, помечен (кадр ≡ gx3)
      6: { deleted: false, predefined: true },    // группа, предопределённая
      7: { deleted: false, predefined: true },    // элемент, предопределённый
      8: { deleted: false, predefined: true },    // кадр ≡ gx7
    },
    // План счетов — ОТДЕЛЬНЫЙ спрайт с той же basename, но иной раскладкой.
    'e1csys/accnt/folder.zip': {
      0: { deleted: false, predefined: false },
      1: { deleted: false, predefined: true },
      2: { deleted: true,  predefined: false },
    },
    // Задачи. Бит-поле: 1·Выполнена + 2·ПометкаУдаления. Сверено с данными на ERP.
    'e1csys/bp/Task.zip': function (gx) {
      if (gx > 3) return null;
      return { completed: (gx & 1) === 1, deleted: (gx & 2) === 2 };
    },
    // Бизнес-процессы. Бит-поле: 4·Стартован + 2·Завершён + 1·ПометкаУдаления. Сверено с данными.
    'e1csys/bp/BusinessProcess.zip': function (gx) {
      if (gx > 7) return null;
      return { started: (gx & 4) === 4, finished: (gx & 2) === 2, deleted: (gx & 1) === 1 };
    },
    // Планы видов расчёта.
    'e1csys/calc/calcKindImg.zip': {
      0: { deleted: false, predefined: false },
      1: { deleted: true,  predefined: false },
      2: { deleted: false, predefined: true },
    },
    // Планы обмена. gx 1, 4..7 не сняты → только _rowPic.
    'e1csys/backend/DataExchangeImages.zip': {
      0: { thisNode: false },
      2: { thisNode: true },
    },
  };

  function decodeUrl(s) {
    // В DOM путь закодирован ДВАЖДЫ: url=e1csys%252Fbasic%252FdocList.zip
    let v = s;
    for (let i = 0; i < 3; i++) {
      let d;
      try { d = decodeURIComponent(v); } catch (e) { break; }
      if (d === v) break;
      v = d;
    }
    return v;
  }

  // Ведущих значков в строке может быть несколько в РАЗНЫХ боксах: вид операции
  // (pictureCollection, произвольная картинка конфигурации), tree-toggle и состояние.
  // Поэтому перебираем все .dIB строки, а не берём первый .gridBoxImg.
  const dibs = line.querySelectorAll('.gridBoxImg .dIB');
  for (let i = 0; i < dibs.length; i++) {
    const d = dibs[i];
    if (d.getAttribute('tree') === 'true') continue;
    const bg = d.style.backgroundImage || '';
    if (!bg.includes('convertPicture')) continue;
    const um = bg.match(/[?&]url=([^&"')]+)/);
    if (!um) continue;
    const path = decodeUrl(um[1]);
    if (!/\\.zip$/.test(path)) continue;
    const gm = bg.match(/[?&]gx=(\\d+)/);
    const gx = gm ? parseInt(gm[1], 10) : 0;

    const entry = SPRITES[path];
    const axes = typeof entry === 'function' ? entry(gx) : (entry ? entry[gx] : null);
    return { rowPic: path + ':' + gx, axes: axes || null };
  }
  return null;
}`;
