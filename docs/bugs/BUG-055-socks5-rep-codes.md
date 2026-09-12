# BUG-055 — SOCKS5: коды REP смещены против RFC 1928 (нет network_unreachable)

- Статус: ЗАКРЫТ (был ОТКРЫТ, закрыт 2026-09-10)
- Фикс: `src/net/socks5.zig` (маппинг 0x03/0x04/0x05/0x06 по RFC + вариант network_unreachable) + тест
- Открыт: 2026-09-10
- Где найдено: код-ревью (сверка с RFC 1928)
- Серьёзность: низкая

## Симптом

Публичный enum врал: 0x03 (network unreachable) назывался
host_unreachable, 0x04 (host unreachable) — refused, 0x05 (refused) — ttl,
0x06 (ttl) не мапился вовсе. Сегодня влияние нулевое (handshake сворачивает
все не-ok в SocksConnectRejected), но любой будущий потребитель кодов
получал ложь.

## Причина

Опечатка при переносе таблицы RFC.

## Лечение

Маппинг сверен с RFC 1928; добавлен network_unreachable; тест-таблица
обновлена (в т.ч. комментарий «REP=4 (refused)» → host_unreachable).

## Профилактика

Тест «разбор ответа CONNECT (REP по RFC 1928)» фиксирует все коды.
