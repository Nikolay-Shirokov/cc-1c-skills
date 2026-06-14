# 1C Skills for Roo Code (PowerShell)

Автоматическая сборка из [main](https://github.com/Nikolay-Shirokov/cc-1c-skills) — навыки 1С:Предприятие 8.3 для AI-агента **Roo Code** с рантаймом **PowerShell**.

> Эта ветка генерируется CI на каждый push в main. **Не редактируйте напрямую** — все правки идут в [main](https://github.com/Nikolay-Shirokov/cc-1c-skills).

## Установка

1. Скачайте ZIP этой ветки: **Code → Download ZIP** (или `git archive`).
2. Распакуйте в корень своего проекта — должна появиться папка `.roo/skills/`.
3. Запустите Roo Code из этого проекта — навыки станут доступны.

## Требования

- **Windows** с PowerShell 5.1+ (входит в Windows) — для PowerShell-сборки.
- **Python 3.10+** — для Python-сборки. Зависимости: `lxml>=4.9.0`, `psutil>=5.9.0` (для DOM- и web-навыков).
- **1С:Предприятие 8.3** — для сборки/разборки EPF/ERF и работы с базами.
- **Node.js 18+** — для `/web-test`.

## Документация

Полные гайды, спецификации и описание навыков — в [main](https://github.com/Nikolay-Shirokov/cc-1c-skills).

---

Source: https://github.com/Nikolay-Shirokov/cc-1c-skills
Build commit: `ae8241237753850307d94b10df93e5293e29dc74`
