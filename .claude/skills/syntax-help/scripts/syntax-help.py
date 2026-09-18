#!/usr/bin/env python3
# syntax-help v1.0 — Search and read the 1C platform help (.hbk): syntax helper and other help books
# Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
import argparse
import glob
import html
import io
import json
import os
import re
import sys
import tempfile
import zipfile

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

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


def _find_project_v8path():
    """Walk up from CWD to find .v8-project.json and read its v8path."""
    d = os.getcwd()
    while True:
        pf = os.path.join(d, ".v8-project.json")
        if os.path.isfile(pf):
            try:
                with open(pf, encoding="utf-8-sig") as f:
                    data = json.load(f)
                v = data.get("v8path")
                if v:
                    return v
            except Exception:
                pass
            return None
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _version_dir(p):
    """Version dir for both Windows (.../1cv8/<ver>/bin/1cv8.exe) and *nix (.../1cv8/<ver>/1cv8)."""
    parent = os.path.dirname(p)
    if os.path.basename(parent).lower() == "bin":
        parent = os.path.dirname(parent)
    return os.path.basename(parent)


def _version_key(p):
    """Numeric sort key from version dir name."""
    return [int(x) for x in re.findall(r"\d+", _version_dir(p))]


# ── arg parsing ──────────────────────────────────────────────

parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument("-Search", default="")
parser.add_argument("-Page", default="")
parser.add_argument("-InText", action="store_true")
parser.add_argument("-Book", default="")
parser.add_argument("-Language", default="ru")
parser.add_argument("-V8Path", default="")
parser.add_argument("-CacheDir", default="")
parser.add_argument("-Limit", type=int, default=150)
parser.add_argument("-Offset", type=int, default=0)
args = ci_parse_args(parser)

lines = []


def out(text):
    lines.append(text)


has_search = bool(args.Search.strip())
has_page = bool(args.Page.strip())
if has_search == has_page:
    print("[ERROR] Specify exactly one of -Search or -Page")
    sys.exit(1)
if has_page and not re.match(r"^[A-Za-z0-9_]+:.+$", args.Page, re.S):
    print(f"[ERROR] -Page expects <book>:<path> from the search output, got: {args.Page}")
    sys.exit(1)

# ── platform: -V8Path, then .v8-project.json, then the newest installed version ──

v8path = args.V8Path or _find_project_v8path()
if not v8path:
    if os.name == "nt":
        candidates = (
            glob.glob(r"C:\Program Files\1cv8\*\bin\1cv8.exe")
            + glob.glob(r"C:\Program Files (x86)\1cv8\*\bin\1cv8.exe")
        )
    else:
        # PY-only: PS-порт на *nix не исполняется, поэтому *nix-раскладки нет в .ps1.
        candidates = glob.glob("/opt/1cv8/*/1cv8") + glob.glob("/opt/1cv8/*/*/1cv8")
    if candidates:
        v8path = max(candidates, key=_version_key)
        print(f"Auto-selected platform {_version_dir(v8path)}: {v8path}")
    else:
        print("[ERROR] 1C platform not found. Specify -V8Path")
        sys.exit(1)
# Книги лежат рядом с исполняемым файлом: принимаем и каталог bin, и путь к 1cv8.exe/ibcmd.exe.
if os.path.isfile(v8path):
    bin_dir = os.path.dirname(os.path.abspath(v8path))
elif os.path.isdir(v8path):
    bin_dir = os.path.abspath(v8path)
else:
    print(f"[ERROR] Platform path not found: {v8path}")
    sys.exit(1)
bin_dir = bin_dir.rstrip("\\/") or bin_dir
platform_name = os.path.basename(bin_dir)
if platform_name.lower() == "bin":
    platform_name = os.path.basename(os.path.dirname(bin_dir))

# ── 1C container (.hbk) ──────────────────────────────────────
# Документ контейнера хранится цепочкой блоков. Заголовок блока — 31 байт текста: CRLF, длина
# документа, длина блока, адрес следующего блока (8 hex-цифр через пробел), пробел, CRLF.
# Длину документа несёт первый блок; конец цепочки — адрес 7fffffff.


def read_container_document(data, address):
    buf = bytearray()
    doc_length = -1
    visited = set()
    while True:
        if address < 0 or address + 31 > len(data) or address in visited:
            raise ValueError(f"broken block chain at offset {address}")
        visited.add(address)
        header = data[address:address + 31]
        if header[:2] != b"\r\n" or header[29:31] != b"\r\n":
            raise ValueError(f"no block header at offset {address}")
        if doc_length < 0:
            doc_length = int(header[2:10], 16)
        block_length = int(header[11:19], 16)
        nxt = int(header[20:28], 16)
        take = min(block_length, doc_length - len(buf))
        if address + 31 + take > len(data):
            raise ValueError(f"block at offset {address} runs past the end of file")
        buf += data[address + 31:address + 31 + take]
        if len(buf) >= doc_length or nxt == 0x7FFFFFFF:
            break
        address = nxt
    return bytes(buf)


# Оглавление — первый документ после 16 байт заголовка файла: тройки uint32 (адрес заголовка
# элемента, адрес данных, резерв). Имя элемента — UTF-16LE после 20 байт дат и резерва.
def get_container_items(data):
    toc = read_container_document(data, 16)
    items = {}
    for i in range(0, len(toc) - len(toc) % 12, 12):
        header_address = int.from_bytes(toc[i:i + 4], "little")
        data_address = int.from_bytes(toc[i + 4:i + 8], "little")
        if header_address == 0 and data_address == 0:
            continue
        item_header = read_container_document(data, header_address)
        name = item_header[20:].decode("utf-16-le", errors="replace").split("\x00")[0]
        items[name] = data_address
    return items


class HelpBook:
    def __init__(self, name, path, archive):
        self.name = name
        self.path = path
        self.archive = archive


# Страницы книги — zip в элементе FileStorage. skip_unreadable — для поиска по всем книгам:
# нечитаемая книга пропускается с предупреждением, а не обрывает поиск.
def open_help_book(book_name, skip_unreadable=False):
    path = os.path.join(bin_dir, f"{book_name}_{args.Language}.hbk")
    if not os.path.isfile(path):
        print(f"[ERROR] Help book not found: {path}")
        sys.exit(1)
    try:
        with open(path, "rb") as f:
            data = f.read()
        items = get_container_items(data)
        if "FileStorage" not in items:
            raise ValueError("no FileStorage item")
        archive = zipfile.ZipFile(io.BytesIO(read_container_document(data, items["FileStorage"])))
    except Exception as e:
        if skip_unreadable:
            print(f"[WARN] Skipped unreadable help book {path}: {e}")
            return None
        print(f"[ERROR] Cannot read help book {path}: {e}")
        sys.exit(1)
    return HelpBook(book_name, path, archive)


def read_help_entry(book, entry_path):
    return book.archive.read(entry_path).decode("utf-8-sig", errors="replace").lstrip("\ufeff")


# ── HTML -> text ─────────────────────────────────────────────

def get_help_title(page_html):
    m = re.search(r"(?is)<h1\b[^>]*>(.*?)</h1>", page_html)
    if not m:
        return None
    title = html.unescape(re.sub(r"<[^>]+>", "", m.group(1)))
    return re.sub(r"\s+", " ", title).strip()


def convert_help_html(page_html):
    text = re.sub(r"(?is)<head\b.*?</head>", "", page_html)
    text = re.sub(r"(?i)<li\b[^>]*>", "\n- ", text)
    text = re.sub(r"(?i)</t[dh]>", " | ", text)
    text = re.sub(r"(?i)<br\s*/?>|</?(p|div|h[1-6]|tr|table|ul|ol|pre|dl|dt|dd)\b[^>]*>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text)
    result = []
    for raw in re.split(r"\r?\n", text):
        line = re.sub(r"[ \t\u00a0]+", " ", raw).strip().rstrip("|").strip()
        # пункты списка идут подряд, без пустой строки между ними
        if line.startswith("- ") and len(result) > 1 and result[-1] == "" and result[-2].startswith("- "):
            result.pop()
        if line != "" or (result and result[-1] != ""):
            result.append(line)
    while result and result[-1] == "":
        result.pop()
    return result


# ── title index ──────────────────────────────────────────────
# Заголовок страницы — это её <h1>, и чтобы найти страницу по заголовку, надо распаковать все
# страницы книги. Поэтому список «путь — заголовок» кэшируется: ключ — платформа, книга, размер
# и время изменения файла, так что обновление платформы строит индекс заново.

def get_help_index(book):
    root = args.CacheDir or os.path.join(tempfile.gettempdir(), "1c-syntax-help")
    st = os.stat(book.path)
    index_path = os.path.join(root, f"{platform_name}-{book.name}_{args.Language}-{st.st_size}-{int(st.st_mtime)}.tsv")
    if os.path.isfile(index_path):
        rows = []
        with open(index_path, encoding="utf-8-sig") as f:
            for row in f.read().split("\n"):
                parts = row.rstrip("\r").split("\t", 1)
                if len(parts) == 2:
                    rows.append(parts)
        return rows
    rows = []
    for entry in book.archive.namelist():
        if entry.endswith(".st") or entry.endswith("__categories__"):
            continue
        title = get_help_title(read_help_entry(book, entry))
        if title:
            rows.append([entry, title])
    # Не удалось записать кэш — не ошибка: индекс просто построится и в следующий раз.
    try:
        os.makedirs(root, exist_ok=True)
        tmp = f"{index_path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8", newline="\r\n") as f:
            f.write("".join(f"{p}\t{t}\n" for p, t in rows))
        os.replace(tmp, index_path)
    except OSError:
        pass
    return rows


if has_page:
    # ── page mode ──
    book_name, entry_path = args.Page.split(":", 1)
    book = open_help_book(book_name)
    if entry_path not in book.archive.namelist():
        print(f"[ERROR] Page not found: {args.Page} ({book.path})")
        sys.exit(1)
    out(f"[{platform_name}] {args.Page}")
    for ln in convert_help_html(read_help_entry(book, entry_path)):
        out(ln)
else:
    # ── search mode ──
    # Все слова запроса должны встретиться в заголовке (или в тексте при -InText). Порядок:
    # точное совпадение заголовка, заголовок начинается с запроса, запрос целиком внутри,
    # слова по отдельности, совпадение только в тексте; внутри группы — короткие заголовки выше.
    query = re.sub(r"\s+", " ", args.Search).strip()
    q = query.lower()
    words = q.split(" ")
    # Без -Book — все книги справки каталога: кроме синтакс-помощника там параметры запуска и
    # ключи пакетного режима (1cv8), конфигуратор, хранилище, отладчик, СКД.
    all_books = not args.Book.strip()
    if all_books:
        suffix = f"_{args.Language}.hbk"
        book_names = sorted(
            name[:-len(suffix)] for name in os.listdir(bin_dir)
            if len(name) > len(suffix) and name.lower().endswith(suffix.lower())
            and os.path.isfile(os.path.join(bin_dir, name))
        )
        if not book_names:
            print(f"[ERROR] No help books *{suffix} in {bin_dir}")
            sys.exit(1)
    else:
        book_names = [b.strip() for b in args.Book.split(",") if b.strip()]
    hits = []
    for book_name in book_names:
        book = open_help_book(book_name, skip_unreadable=all_books)
        if book is None:
            continue
        for entry_path, title in get_help_index(book):
            t = title.lower()
            rank = -1
            if t == q:
                rank = 0
            elif t.startswith(q):
                rank = 1
            elif q in t:
                rank = 2
            elif all(w in t for w in words):
                rank = 3
            elif args.InText:
                text = "\n".join(convert_help_html(read_help_entry(book, entry_path))).lower()
                if all(w in text for w in words):
                    rank = 4
            if rank >= 0:
                # Ключ сортировки несёт и саму строку вывода: порядок совпадает с PS-портом
                # (порядковое сравнение, без культуры).
                hits.append(f"{rank}|{len(title):06d}|{book_name}:{entry_path} | {title}")
    if not hits:
        print(f"[INFO] Nothing found: {query}")
        sys.exit(0)
    hits.sort()
    out(f"[{platform_name}] Found: {len(hits)}")
    for key in hits:
        out(key.split("|", 2)[2])

# ── pagination and output ────────────────────────────────────

total_lines = len(lines)
out_lines = lines[:]

if args.Offset > 0:
    if args.Offset >= total_lines:
        print(f"[INFO] Offset {args.Offset} exceeds total lines ({total_lines}). Nothing to show.")
        sys.exit(0)
    out_lines = out_lines[args.Offset:]

if args.Limit > 0 and len(out_lines) > args.Limit:
    shown = out_lines[:args.Limit]
    shown.append("")
    shown.append(f"[ОБРЕЗАНО] Показано {args.Limit} из {total_lines} строк. Используйте -Offset {args.Offset + args.Limit} для продолжения.")
    out_lines = shown

for ln in out_lines:
    print(ln)
sys.exit(0)
