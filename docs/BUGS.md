# Доска багов

Учёт багов по карточкам: каждая проблема — файл `bugs/BUG-NNN-*.md`
(шаблон — [bugs/_TEMPLATE.md](bugs/_TEMPLATE.md)). Статусов два:

- **ОТКРЫТ** — баг жив, чинить;
- **ЗАКРЫТ** — починено, в карточке ссылка на фикс и профилактику.

Правила ведения — в [AGENTS.md](../AGENTS.md), раздел «Учёт багов».
Кратко: баг найден → карточка в тот же ход; починен → статус ЗАКРЫТ,
fix-коммит, строка в changelog; переоткрыли — новый статус ОТКРЫТ (снова)
и запись о рецидиве, старый фикс не стираем.

Сводка: **0 открытых, 63 закрытых** (обновлено 2026-09-12; деплой-гейт
кросс-сборки поймал BUG-065 — релизный путь не компилировался).

## Открыт

| Карточка | Серьёзность | Что болит | Открыт |
| --- | --- | --- | --- |
| — | — | пусто | — |

## Закрыт

| Карточка | Серьёзность | Что болело | Фикс | Закрыт |
| --- | --- | --- | --- | --- |
| [BUG-001](bugs/BUG-001-parseupdates-uaf.md) | критическая | краш-луп на первом сообщении: use-after-free в `parseUpdates` | `9b25474` | 2026-09-09 |
| [BUG-002](bugs/BUG-002-tls-writer-buffer.md) | критическая | TLS кладёт кадр в буфер сокета целиком, буфер был 8 КБ < ~17 КБ → зависание/UB | `bot: буферы 17 КБ` | 2026-09-09 |
| [BUG-003](bugs/BUG-003-tls-double-flush.md) | критическая | flush TLS-писателя не отправлял шифротекст в сокет — запрос не уходил | `bot: двойной flush` | 2026-09-09 |
| [BUG-004](bugs/BUG-004-pg-frame-layout.md) | высокая | кадры PostgreSQL: порядок `[len][tag]` вместо `[tag][len]` и длина +1 — зависание хендшейка | `db/pg: кадры` | 2026-09-09 |
| [BUG-005](bugs/BUG-005-socks5-off-by-two.md) | средняя | длина доменного ответа SOCKS5 считалась на 2 байта больше | `net/socks5` | 2026-09-09 |
| [BUG-006](bugs/BUG-006-delimiter-exclusive.md) | средняя | `takeDelimiterExclusive` в Zig 0.15.2 не съедает разделитель — «пустые строки» в HTTP-парсере | `net/https` | 2026-09-09 |
| [BUG-007](bugs/BUG-007-ncurses-base.md) | низкая | `ncurses-base` не существует в alpine 3.22 (nc — busybox) — tor-образ не собирался | `ci/tor` | 2026-09-09 |
| [BUG-008](bugs/BUG-008-exec-bit-tar.md) | средняя | tar из Windows не хранит exec-бит — контейнер бота не стартовал (permission denied) | `Dockerfile: chmod` | 2026-09-09 |
| [BUG-009](bugs/BUG-009-ps5-ascii.md) | низкая | PowerShell 5 читает .ps1 без BOM как ANSI — кириллица в скрипте ломала парсер | `ci/deploy.ps1: ASCII` | 2026-09-09 |
| [BUG-010](bugs/BUG-010-zig-url-404.md) | средняя | URL тарболла Zig 404 (сменилась схема имён), затем сеть продa не качала — перешли на кросс-сборку на dev-машине | `deploy.ps1 + Dockerfile` | 2026-09-09 |
| [BUG-011](bugs/BUG-011-win-raw-read.md) | средняя | сырой `stream.read` (ReadFile) на сокетах Windows даёт ошибку 87 — ввели Reader/Writer-интерфейсы везде | `net/*` | 2026-09-09 |
| [BUG-014](bugs/BUG-014-wizard-lunar-day-same-number.md) | низкая | слайд гида утверждал, что при счёте от восхода Луны «номер дня тот же» — на деле отставание до 2 номеров к концу месяца | `features/wizard.zig` | 2026-09-09 |
| [BUG-015](bugs/BUG-015-voc-duplicate-aspects.md) | средняя | VOC: соединения и оппозиции в списке аспектов (и тексте `/voc`) дважды | `astro/voc.zig` | 2026-09-09 |
| [BUG-016](bugs/BUG-016-parse-date-nonexistent-day.md) | средняя | «31.02» и прочие несуществующие дни молча принимались (небо чужого дня) | `util.zig` | 2026-09-09 |
| [BUG-017](bugs/BUG-017-tzlabel-minutes-seconds.md) | низкая | tzLabel дробных поясов: «UTC+5:1800» вместо «UTC+5:30» | `util.zig` | 2026-09-09 |
| [BUG-018](bugs/BUG-018-access-request-unreachable.md) | критическая | заявки на доступ не создаются: requestAccess недостижим | `access.zig + store.zig` | 2026-09-09 |
| [BUG-019](bugs/BUG-019-requestaccess-sql-aliasing.md) | высокая | SQL заявки всегда битый: буфер имени затирался префиксом INSERT | `store.zig` | 2026-09-09 |
| [BUG-020](bugs/BUG-020-acl-deny-off-by-one.md) | высокая | кнопка «Отклонить» всегда «Неверный id» (срез с 4 вместо 5) | `access.zig` | 2026-09-09 |
| [BUG-021](bugs/BUG-021-webhook-allowed-updates.md) | высокая | webhook подписан только на message — кнопки в webhook-режиме мертвы | `telegram.zig` | 2026-09-09 |
| [BUG-022](bugs/BUG-022-monitor-fmtdur-aliasing.md) | средняя | /monitor: аптайм затирался возрастом heartbeat + битый UTF-8 | `mon.zig` | 2026-09-09 |
| [BUG-023](bugs/BUG-023-idle-header-aliasing.md) | средняя | /idle*: шапка «окно: …» затёрта длительностью | `mon.zig` | 2026-09-09 |
| [BUG-024](bugs/BUG-024-setupdatecursor-buffer.md) | средняя | курсор tg_offset не писался в Postgres (SQL не влезал в буфер) | `store.zig` | 2026-09-09 |
| [BUG-025](bugs/BUG-025-statusof-fail-open.md) | средняя | при сбое PG закрытый бот открывался всем (fail-open) | `store.zig + access.zig` | 2026-09-09 |
| [BUG-026](bugs/BUG-026-admin-html-no-parse-mode.md) | средняя | /idle* /reset /users /revoke: HTML без parse_mode — сырые теги | `router.zig + dispatch.zig + monitor.zig` | 2026-09-09 |
| [BUG-027](bugs/BUG-027-pollfail-recovery-dead.md) | средняя | «Telegram снова доступен» не шлётся; алерт течёт и повторяет старый текст | `main.zig` | 2026-09-09 |
| [BUG-028](bugs/BUG-028-layerline-no-data-unreachable.md) | низкая | слой без наблюдений рисовался «0 · 100%» вместо «нет данных» | `mon.zig` | 2026-09-09 |
| [BUG-029](bugs/BUG-029-leading-gap-no-span.md) | низкая | ведущий гэп не попадал в список «с … по …» | `mon.zig` | 2026-09-09 |
| [BUG-030](bugs/BUG-030-spans-cap-undercount.md) | низкая | «… ещё N» занижал число скрытых промежутков | `mon.zig` | 2026-09-09 |
| [BUG-031](bugs/BUG-031-wizard-render-no-clamp.md) | низкая | wiz:p:999 рисовал счётчик «1000/22» | `wizard.zig` | 2026-09-09 |
| [BUG-032](bugs/BUG-032-subssnapshot-truncation.md) | низкая | рассылка молча резалась по буферу вызова (128) | `store.zig + features/*` | 2026-09-09 |
| [BUG-033](bugs/BUG-033-preview-utf8-cut.md) | низкая | preview[0..200] резал UTF-8 — карточка заявки могла не дойти | `access.zig` | 2026-09-09 |
| [BUG-034](bugs/BUG-034-onac-empty-index.md) | низкая | [0] по пустому online-файлу — паника/UB на проде | `monitor.zig + hostwatch.zig` | 2026-09-09 |
| [BUG-035](bugs/BUG-035-hardreset-webhook-no-reply.md) | низкая | /hardreset (webhook) умирал до отправки подтверждения | `monitor.zig` | 2026-09-09 |
| [BUG-036](bugs/BUG-036-planrestart-cooldown-dead.md) | низкая | 90-с кулдаун рестартов не работал в командном пути | `rst.zig` | 2026-09-09 |
| [BUG-037](bugs/BUG-037-planets-command-missing.md) | средняя | /planets была заявлена в доках и кнопке меню, но не реализована | `features/planets.zig` | 2026-09-09 |
| [BUG-012](bugs/BUG-012-status-race.md) | низкая | /status читал число подписчиков без мьютекса стора | `store.subsCount()` | 2026-09-10 |
| [BUG-013](bugs/BUG-013-setmycommands-64.md) | низкая | буфер setMyCommands — 64 команды при лимите Telegram 100 | `main.zig + features.zig: 100` | 2026-09-10 |
| [BUG-038](bugs/BUG-038-voc-pct-hundred.md) | низкая | «пройдено 100% знака» до фактической ингрессии | `features/voc.zig: потолок 99` | 2026-09-10 |
| [BUG-039](bugs/BUG-039-denied-no-restart-request.md) | средняя | после отказа повторная заявка через /start была невозможна | `access.zig` | 2026-09-10 |
| [BUG-040](bugs/BUG-040-deploy-tar-fail-stale-apply.md) | средняя | неудача tar не останавливала выкат — применялся старый код | `ci/deploy.ps1` | 2026-09-10 |
| [BUG-041](bugs/BUG-041-webhook-watchdog-kill.md) | критическая | webhook: watchdog убивал процесс при 5 мин тишины (рестарт-луп) | `main.zig + webhook.zig: beat` | 2026-09-10 |
| [BUG-042](bugs/BUG-042-docker-labels-null-panic.md) | высокая | Docker «Labels»: null паникул разбор контейнеров (UB на проде) | `wd.zig: теги Value` | 2026-09-10 |
| [BUG-043](bugs/BUG-043-webhook-parse-leak.md) | средняя | утечка page_allocator на каждый webhook-апдейт | `webhook.zig: арена` | 2026-09-10 |
| [BUG-044](bugs/BUG-044-child-run-leak.md) | средняя | утечка вывода df (Child.run) раз в минуту | `hostwatch + monitor: defer free` | 2026-09-10 |
| [BUG-045](bugs/BUG-045-envfile-utf16-crash.md) | высокая | UTF-16 .env крашил процесс на старте (WTF-8 assert) | `envfile.zig` | 2026-09-10 |
| [BUG-046](bugs/BUG-046-https-retry-append.md) | средняя | ретрай HTTPS дописывал тело к обрывку | `https.zig: shrink` | 2026-09-10 |
| [BUG-047](bugs/BUG-047-pg-url-slash-password.md) | средняя | '/' в пароле URL PG → бот тихо уходил в открытый режим | `pg.zig: parseUrl` | 2026-09-10 |
| [BUG-048](bugs/BUG-048-datarow-negative-count.md) | средняя | отрицательный count DataRow → @intCast → UB | `pg.zig: n<0` | 2026-09-10 |
| [BUG-049](bugs/BUG-049-dockerhttp-no-timeout.md) | средняя | dockerHttp без таймаута вешал hostwatch навсегда | `wd.zig: SO_RCVTIMEO` | 2026-09-10 |
| [BUG-050](bugs/BUG-050-webhook-keepalive-parking.md) | средняя | webhook парковался на простаивающем keep-alive соединении | `webhook.zig: close` | 2026-09-10 |
| [BUG-051](bugs/BUG-051-dockerrestart-sent-lie.md) | низкая | dockerRestart врал «ушло в Docker» при неотправленном запросе | `wd.zig: wrote-флаг` | 2026-09-10 |
| [BUG-052](bugs/BUG-052-dockerhttp-truncation.md) | низкая | ответы Docker >64 КиБ обрезались → ложные «упали» | `wd.zig: рост до 1 МиБ` | 2026-09-10 |
| [BUG-053](bugs/BUG-053-pg-unreachable-overflow.md) | низкая | pg: catch unreachable на длинных user/пароле — UB | `pg.zig: ошибки` | 2026-09-10 |
| [BUG-054](bugs/BUG-054-socks5-host-overflow.md) | низкая | SOCKS5: домен >255 переполнял стек-буфер | `socks5.zig: ?slice` | 2026-09-10 |
| [BUG-055](bugs/BUG-055-socks5-rep-codes.md) | низкая | коды REP SOCKS5 смещены против RFC 1928 | `socks5.zig: маппинг` | 2026-09-10 |
| [BUG-056](bugs/BUG-056-moment-hint-swallowed.md) | средняя | подсказка о неправильной дате подменялась «Внутренней ошибкой» | `dispatch.zig` | 2026-09-10 |
| [BUG-057](bugs/BUG-057-retro-shadows-degenerate.md) | средняя | тени ретро вырождены у 7 из 8 планет (окно 30 сут) | `retro.zig: 200 сут` | 2026-09-10 |
| [BUG-058](bugs/BUG-058-tzlabel-negative-quarters.md) | низкая | tzLabel: «UTC-13:15» вместо «UTC-13:45» | `util.zig: abs-арифметика` | 2026-09-10 |
| [BUG-059](bugs/BUG-059-socks-ipv6-brackets.md) | низкая | IPv6-прокси со скобками конфигурировался, но был «мёртв» | `config.zig + socks5.zig: ATYP=4` | 2026-09-10 |
| [BUG-060](bugs/BUG-060-rise-high-latitudes.md) | средняя | лунные сутки «от восхода» вымирали с ~62° с.ш. | `rise.zig + lunday_rise.zig` | 2026-09-10 |
| [BUG-061](bugs/BUG-061-upcoming-backscan-short.md) | низкая | старт идущего ретро внешних планет не восстанавливался | `retro.zig: 200 сут` | 2026-09-10 |
| [BUG-062](bugs/BUG-062-menu-admin-help.md) | низкая | «Меню команд» админу без админ-строки | `cb.zig: admin` | 2026-09-10 |
| [BUG-063](bugs/BUG-063-restart-cursor-noop.md) | низкая | no-op setUpdateCursor(updateCursor()) на рестарт-пути | `monitor.zig: удалена` | 2026-09-10 |
| [BUG-064](bugs/BUG-064-wizard-text-mismatches.md) | низкая | 7 текстовых расхождений слайдов/подписки с фактом | `wizard.zig + service.zig` | 2026-09-10 |
| [BUG-065](bugs/BUG-065-release-realloc-args.md) | высокая | релизная сборка не компилировалась: `realloc(u8, …)` по старой сигнатуре — деплой падал на кросс-сборке | `wd.zig: realloc(buf, cap)` | 2026-09-12 |
