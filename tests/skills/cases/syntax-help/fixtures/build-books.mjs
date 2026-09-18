#!/usr/bin/env node
// Собирает синтетические книги справки для кейсов syntax-help: node build-books.mjs
// Настоящие .hbk платформы — собственность 1С, в репозиторий их класть нельзя. Здесь тот же
// формат с выдуманным текстом: контейнер 1С (документы цепочками блоков), в нём элемент
// FileStorage — zip со страницами HTML. Хранилище одной из книг нарочно разрезано на два
// блока с переходом назад по файлу: так кейсы проверяют сборку документа по цепочке, а не
// только файлы, где документ лежит одним куском.
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

const OUT = join(dirname(fileURLToPath(import.meta.url)), 'books');

// ─── zip (deflate, UTF-8 имена) ─────────────────────────────────────────────
const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xFFFFFFFF;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}
function zip(files) {
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const [name, text] of files) {
    const nameBuf = Buffer.from(name, 'utf8');
    const data = Buffer.from(text, 'utf8');
    const packed = deflateRawSync(data);
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(0x0800, 6);
    local.writeUInt16LE(8, 8); local.writeUInt32LE(crc, 14); local.writeUInt32LE(packed.length, 18);
    local.writeUInt32LE(data.length, 22); local.writeUInt16LE(nameBuf.length, 26);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8); central.writeUInt16LE(8, 10); central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(packed.length, 20); central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuf.length, 28); central.writeUInt32LE(offset, 42);
    locals.push(local, nameBuf, packed);
    centrals.push(central, nameBuf);
    offset += local.length + nameBuf.length + packed.length;
  }
  const cd = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10);
  end.writeUInt32LE(cd.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, cd, end]);
}

// ─── контейнер 1С ───────────────────────────────────────────────────────────
const hex8 = (n) => n.toString(16).padStart(8, '0');
const END = 0x7FFFFFFF;
function block(docLength, payload, blockLength, next) {
  const head = Buffer.from(`\r\n${hex8(docLength)} ${hex8(blockLength)} ${hex8(next)} \r\n`, 'ascii');
  const body = Buffer.alloc(blockLength);
  payload.copy(body);
  return Buffer.concat([head, body]);
}
// items: [name, data, splitAt?]. splitAt — длина первого куска: второй кусок пишется в файл
// РАНЬШЕ первого, и первый блок ссылается на него назад.
function container(items) {
  const HEADER = 16;
  const tocLength = 12 * items.length;
  const tocBlockLength = Math.max(512, tocLength);
  const parts = [];
  let pos = HEADER + 31 + tocBlockLength;
  const toc = Buffer.alloc(tocLength);
  items.forEach(([name, data, splitAt], i) => {
    const itemHeader = Buffer.concat([Buffer.alloc(20), Buffer.from(name, 'utf16le'), Buffer.alloc(4)]);
    const headerAddress = pos;
    parts.push(block(itemHeader.length, itemHeader, itemHeader.length, END));
    pos += 31 + itemHeader.length;
    let dataAddress;
    if (splitAt) {
      const tail = data.subarray(splitAt);
      const tailAddress = pos;
      parts.push(block(tail.length, tail, tail.length, END));
      pos += 31 + tail.length;
      dataAddress = pos;
      parts.push(block(data.length, data.subarray(0, splitAt), splitAt, tailAddress));
      pos += 31 + splitAt;
    } else {
      dataAddress = pos;
      parts.push(block(data.length, data, data.length, END));
      pos += 31 + data.length;
    }
    toc.writeUInt32LE(headerAddress, i * 12);
    toc.writeUInt32LE(dataAddress, i * 12 + 4);
    toc.writeUInt32LE(END, i * 12 + 8);
  });
  const fileHeader = Buffer.alloc(HEADER);
  fileHeader.writeUInt32LE(END, 0); fileHeader.writeUInt32LE(512, 4);
  return Buffer.concat([fileHeader, block(tocLength, toc, tocBlockLength, END), ...parts]);
}

// ─── страницы ───────────────────────────────────────────────────────────────
const page = (title, body) => '\uFEFF<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">'
  + `<title>служебный заголовок</title></head><body><h1 class="V8SH_pagetitle">${title}</h1>\n${body}\n</body></html>`;
function write(name, pages, splitStorage) {
  const storage = zip(pages);
  const bookInfo = Buffer.from('\uFEFF{7,"SyntaxHelperTest",{1,1,{"#","test"}}}', 'utf8');
  const buf = container([
    ['Book', bookInfo],
    ['FileStorage', storage, splitStorage ? Math.floor(storage.length / 2) : 0],
  ]);
  mkdirSync(OUT, { recursive: true });
  writeFileSync(join(OUT, name), buf);
  console.log(`${name}: ${buf.length} bytes, ${pages.length} entries`);
}

write('shlang_ru.hbk', [
  ['struct_If.st', '{1,{"ru","Если"}}'],
  ['Pragma', page('Директивы компиляции',
    '<p class="Usual">Синтетическая страница для тестов: директива&nbsp;задаёт, где компилируется метод.</p>\n'
    + '<ul>\n<li><strong>&amp;НаКлиенте</strong> — клиент;\n<li><strong>&amp;НаСервере</strong> — сервер;\n'
    + '<li><strong>&amp;НаКлиентеНаСервереБезКонтекста</strong> — клиент и сервер без контекста.\n</ul>\n'
    + '<table><tr><td>Модуль формы</td><td>&amp;НаКлиенте, &amp;НаСервере</td></tr></table>')],
  ['Loop', page('Цикл Для каждого', '<p>Синтетическая страница без упоминания директив.</p>')],
], true);

write('shlang_root.hbk', [
  ['Pragma', page('Compilation directives', '<p>Synthetic page for tests.</p>')],
], false);

write('shcntx_ru.hbk', [
  ['objects/__categories__', '{1,"Global context.html"}'],
  ['objects/Global context.html', page('Глобальный контекст', '<p>Синтетический корень контекста.</p>')],
  ['objects/Global context/methods/catalog1/StrTemplate1.html',
    page('Глобальный контекст.СтрШаблон (Global context.StrTemplate)', '<p>Подставляет параметры в строку.</p>')],
  ['objects/catalog2/FixArray.html', page('ФМассив (FA)', '<p>Синтетический тип.</p>')],
  ['objects/catalog2/Array.html', page('Массив (Array)', '<p>Синтетический тип.</p>')],
  ['objects/catalog2/Array/methods/Count1.html', page('Массив.Количество (Array.Count)', '<p>Число элементов.</p>')],
  ['objects/catalog2/Array/methods/Add1.st', '{1,{"ru","Добавить()"}}'],
  ['objects/catalog2/Array/methods/Add1.html', page('Массив.Добавить (Array.Add)', '<p>Добавляет элемент в конец.</p>')],
  ['objects/catalog2/Array/methods/Insert1.html', page('Массив.Вставить (Array.Insert)',
    '<p>Синтетическая длинная страница.</p>\n<ul>\n'
    + Array.from({ length: 20 }, (_, i) => `<li>Пункт ${i + 1}\n`).join('') + '</ul>')],
], false);

write('shquery_ru.hbk', [
  ['LEFTJOIN', page('Левое внешнее соединение', '<p>Синтетическая страница: ЛЕВОЕ СОЕДИНЕНИЕ.</p>')],
], false);

// Книга вне синтакс-помощника: её находит только поиск без -Book. Картинка — как в настоящих
// книгах: двоичная запись без <h1>, в индекс заголовков не попадает.
write('1cv8_ru.hbk', [
  ['zif3_dumpconfigtofiles', page('DumpConfigToFiles',
    '<p>Синтетическая страница ключа пакетного режима: выгрузка конфигурации в файлы.</p>')],
  ['dump_dialog.png', Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0xFE, 0x00, 0xC0, 0x80])],
], false);

mkdirSync(OUT, { recursive: true });
writeFileSync(join(OUT, 'broken_ru.hbk'), Buffer.from('not a 1C container', 'ascii'));
writeFileSync(join(OUT, '.v8-project.json'), '{\n  "v8path": "."\n}\n');
console.log('broken_ru.hbk, .v8-project.json');
