# BUG-026 — HTML-теги админских ответов уходят без parse_mode: админ видит литеральные <b>/<code>

- Статус: ЗАКРЫТ (был ОТКРЫТ, закрыт 2026-09-09)
- Фикс: `src/bot/router.zig` (флаг `ctx.reply_html`) + `src/dispatch.zig` (sendReply с parse_mode) + `src/features/monitor.zig` (выставляют флаг)
- Открыт: 2026-09-09
- Где найдено: код-ревью (злой QA, TC-148/E8–E12)
- Серьёзность: средняя

## Симптом

`/idlehour` отвечает «⏱ <b>Простой слоёв · час</b>…», `/reset` — «🛑 <b>Сброс
очереди</b>…», `/users` и `/revoke` показывают сырые `<code>` — теги не
рендерятся, читать неудобно. /monitor и /restart* шлют HTML корректно
(они вызывают sendMessageOpts с html=true напрямую).

## Причина

`src/features/monitor.zig` (cmdIdle/cmdReset/cmdUsers/cmdRevoke) пишут
HTML в `ctx.reply`, а `dispatch.sendReply` отправляет через
`api.sendMessage` → `sendMessageOpts(..., html=false)` — без
`parse_mode`.

## Лечение

Дать Ctx флаг `reply_html` (по умолчанию false): админские хендлеры,
пишущие HTML, выставляют его; `sendReply` вызывает `sendMessageOpts` с
этим флагом. Астрофичи остаются плоским текстом — режимы не смешиваются.

## Профилактика

Ручная проверка E8/E10/E12 (MANUAL_TESTING.md): в ответах не видно сырых
`<b>`/`<code>`. Юнит: флаг по умолчанию false (плоский текст не ломается
в HTML-режиме из-за <в пользовательском вводе).
