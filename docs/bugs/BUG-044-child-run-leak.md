# BUG-044 — утечка вывода df: Child.run возвращает память во владение, её не освобождали

- Статус: ЗАКРЫТ (был ОТКРЫТ, закрыт 2026-09-10)
- Фикс: `src/hostwatch.zig` (diskPct) + `src/features/monitor.zig` (hostDiskPct): defer free stdout/stderr
- Открыт: 2026-09-10
- Где найдено: код-ревью (std Child.zig: caller owns result)
- Серьёзность: средняя

## Симптом

Каждый сэмпл слоёв (раз в минуту) и каждый `/monitor` оставляли в
page_allocator ~0,5–1 КБ вывода `df` — линейный рост RSS без потолка
(десятки МБ в год на процесс, в hostwatch и боте).

## Причина

`std.process.Child.run` передаёт stdout/stderr во владение вызывающему;
обе функции читали поля и выходили без free (включая ранний выход по
`term != .Exited`).

## Лечение

`defer free(out.stdout); defer free(out.stderr);` сразу после успешного
`Child.run`.

## Профилактика

Ревью-правило: результат `Child.run` всегда парой defer-free. Юнит требует
GPA-проверки системного вызова — покрывается ревью.
