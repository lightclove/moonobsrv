# BUG-035 — /hardreset в webhook-режиме убивает процесс до отправки подтверждения

- Статус: ЗАКРЫТ (был ОТКРЫТ, закрыт 2026-09-09)
- Фикс: `src/features/monitor.zig` (отправка подтверждения до `bounceSelf`)
- Открыт: 2026-09-09
- Где найдено: код-ревью (злой QA)
- Серьёзность: низкая

## Симптом

В webhook-режиме `/hardreset` выполняется через роутер (нет batch-brake),
`rst.bounceSelf()` делает exit(1) ещё до `dispatch.sendReply` — админ не
получает «🛑 Жёсткий сброс…» и не понимает, выполнилось ли. В polling
путь всегда идёт через batchBrake, там сообщение уходит до выхода —
поэтому баг вебхук-специчный.

## Причина

`src/features/monitor.zig:158-165`: текст пишется в `ctx.reply`, затем
сразу `bounceSelf()` (noreturn) — sendReply в handleMessage недостижим.

## Лечение

В hard-ветке cmdReset отправлять ответ напрямую
(`api.sendMessageOpts(…, html=true)`) до bounceSelf — зеркально
drainBrake в main.zig.

## Профилактика

Ручная проверка в webhook-режиме (TC-152); юнит невозможен без фейк-API —
отражено в чек-листе релиза.
