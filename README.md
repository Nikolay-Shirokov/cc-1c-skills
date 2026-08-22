# 1C Skills for OpenCode (Python)

Автоматическая сборка из [main](https://github.com/Nikolay-Shirokov/cc-1c-skills) — навыки 1С:Предприятие 8.3 для AI-агента **OpenCode** с рантаймом **Python**.

> Эта ветка генерируется CI на каждый push в main. **Не редактируйте напрямую** — все правки идут в [main](https://github.com/Nikolay-Shirokov/cc-1c-skills).

## Установка

1. Скачайте ZIP этой ветки: **Code → Download ZIP** (или `git archive`).
2. Распакуйте в корень своего проекта — должна появиться папка `.opencode/skills/`.
3. Запустите OpenCode из этого проекта — навыки станут доступны.

## Требования

- **Python 3.9+**. Установка зависимостей: `pip install -r requirements.txt` (lxml, Pillow, psutil).
- **1С:Предприятие 8.3** — для сборки/разборки EPF/ERF и работы с базами.
- **Node.js 18+** — для `/web-test`.

## Документация

Полные гайды, спецификации и описание навыков — в [main](https://github.com/Nikolay-Shirokov/cc-1c-skills).

---

Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
Build commit: `0442aa015a0b9b8d08047ca79e8362a3d786dbeb`
