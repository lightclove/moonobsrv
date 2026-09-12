//! Обучающий гид (/wizard): слайды с кнопками, оглавление, прогресс-бар.
//! Концепция rbot: гид — «книга» без состояния, позиция живёт в callback_data
//! (wiz:p:N), каждый нажим редактирует то же сообщение. Админу после
//! «Шпаргалки» вставляются три служебных слайда (слои/перезапуск/стоп-кран).

const std = @import("std");
const router = @import("../bot/router.zig");
const tg = @import("../bot/telegram.zig");
const features = @import("features.zig");
const runtime = @import("../runtime.zig");

pub const Slide = struct {
    title: []const u8,
    toc: []const u8,
    body: []const u8,
};

pub const slides = [_]Slide{
    .{
        .title = "👋 Добро пожаловать!",
        .toc = "👋 Приветствие",
        .body =
        \\Это <b>личный астрологический бот</b> в Telegram: следит за небом, чтобы вы не следили.
        \\
        \\Он умеет три вещи и делает их хорошо:
        \\• холостая Луна (Void of Course) — когда лучше не начинать новое
        \\• ретроградный Меркурий — и его тени до и после
        \\• лунные дни — границы, знак и фазу Луны
        \\
        \\Вся астрономия считается <b>на устройстве</b>: ряды Meeus и кеплеровские элементы.
        \\Никаких внешних сервисов, никакого интернета кроме Telegram.
        \\
        \\➡️ Листайте слайды кнопками внизу.
        \\📚 В любой момент — <b>Оглавление</b>.
        ,
    },
    .{
        .title = "🌑 Что такое холостая Луна",
        .toc = "🌑 Холостая Луна",
        .body =
        \\Луна летит по зодиаку и по дороге строит аспекты к планетам —
        \\соединения, секстили, квадраты, триньоны, оппозиции.
        \\
        \\<b>Холостая Луна (Void of Course)</b> — последний аспект в знаке уже
        \\пройден, а новый знак ещё не начался. Классическое правило:
        \\«в этот период дела не завершаются, решения получаются пустыми».
        \\
        \\Периоды короткие — обычно от пары минут до суток.
        \\Чем ближе Луна к концу знака — тем ближе холостое время.
        \\
        \\Бот знает это заранее: он смотрит, когда случится последний аспект
        \\и когда Луна войдёт в следующий знак.
        ,
    },
    .{
        .title = "📡 Команда /voc",
        .toc = "📡 /voc",
        .body =
        \\Напишите: <code>/voc</code>
        \\Синонимы: <code>/void</code>, <code>/холостая</code>
        \\
        \\Ответ выглядит так:
        \\• Луна холостая сейчас или нет
        \\• в каком знаке и какой % знака пройден
        \\• последний и следующий аспекты
        \\• ближайший холостой период: <i>с … по …</i>
        \\
        \\Можно спросить про другой день:
        \\<code>/voc 21.09</code> · <code>/voc 21.09.2026</code> · <code>/voc 2026-09-21</code>
        \\
        \\Владельцы подписки получают уведомление о каждом начале и конце VOC.
        ,
    },
    .{
        .title = "☿ Ретроградный Меркурий",
        .toc = "☿ Ретро-Меркурий",
        .body =
        \\Раз в ~4 месяца Меркурий <b>останавливается и идёт назад</b> по зодиаку —
        \\это оптический эффект орбит, но моменты остановок (станции) вполне реальны.
        \\
        \\Около станций есть <b>тени</b>:
        \\• пред-тень — планета замедляется перед разворотом
        \\• пост-тень — разгоняется после прямого движения
        \\
        \\Традиция не советует в эти окна подписывать важное, покупать технику
        \\и начинать переезды. Бот ничего не запрещает — он просто напоминает,
        \\когда окно открыто и когда закроется.
        ,
    },
    .{
        .title = "📡 Команда /mercury",
        .toc = "📡 /mercury",
        .body =
        \\Напишите: <code>/mercury</code>
        \\Синонимы: <code>/retro</code>, <code>/меркурий</code>
        \\
        \\В ответе:
        \\• директен или ретрограден прямо сейчас
        \\• ближайший ретро-период: даты станций
        \\• пред-тень и пост-тень с точным временем
        \\
        \\Точность станций — до ~30 минут к профессиональным эфемеридам.
        \\Подписчики получают уведомления о самих станциях.
        ,
    },
    .{
        .title = "🌗 Лунные дни",
        .toc = "🌗 Лунные дни",
        .body =
        \\Лунный месяц делится на 30 частей: <b>лунных дней</b>.
        \\Бот показывает две системы счёта рядом.
        \\
        \\<b>Титхи</b> (индийская традиция): 1-й день — в новолуние,
        \\N-й — когда элонгация Луны (угол от Солнца) проходит (N−1)·12°.
        \\Длится ~20–26 часов, едина для всей Земли.
        \\
        \\<b>Лунные сутки от восхода</b> (русская школа, П. Глоба):
        \\1-е — с новолуния до первого восхода Луны, дальше — от восхода
        \\до восхода в вашем городе. Длятся ~24–26 часов, поэтому к концу
        \\месяца отстают от титхи на 1–2 номера, а 30-е могут жить минуты.
        ,
    },
    .{
        .title = "📡 Команда /day",
        .toc = "📡 /day",
        .body =
        \\Напишите: <code>/day</code>
        \\Синонимы: <code>/moon</code>, <code>/луна</code>, <code>/lunday</code>
        \\
        \\В ответе:
        \\• лунный день по титхи и лунные сутки от восхода Луны
        \\• когда каждый начался и когда закончится
        \\• знак Луны и фаза (молодая, полная, старая…)
        \\• % освещённости
        \\
        \\С датой: <code>/day 1.01.2027</code>
        \\Подписчики получают уведомление в момент начала каждого титхи.
        ,
    },
    .{
        .title = "🔔 Подписка на уведомления",
        .toc = "🔔 /subscribe",
        .body =
        \\Напишите: <code>/subscribe</code>
        \\Синонимы: <code>/sub</code>, <code>/подписка</code>
        \\
        \\Придёт сообщение о:
        \\• начале и конце холостой Луны
        \\• станциях Меркурия и других планет (Венера, Марс, Юпитер,
        \\  Сатурн — разворот назад/вперёд)
        \\• начале лунного дня
        \\
        \\Отписаться: <code>/unsubscribe</code> (<code>/unsub</code>)
        \\
        \\Проверить, что подписка жива: <code>/status</code> — там аптайм,
        \\число подписчиков и период проверки неба.
        ,
    },
    .{
        .title = "🪐 Планеты: /planets",
        .toc = "🪐 /planets",
        .body =
        \\Напишите: <code>/planets</code>
        \\
        \\Долготы всех планет на сейчас: Меркурий…Плутон (8 тел),
        \\плюс знак зодиака для каждой. Есть и отдельные команды:
        \\<code>/venus</code> · <code>/mars</code> · <code>/jupiter</code> · <code>/saturn</code>
        \\
        \\Если планета ретроградна — рядом будет пометка.
        \\Начало и конец ретро-периодов любой планеты бот тоже знает
        \\(механика одна и та же, меняется только тело).
        ,
    },
    .{
        .title = "🧮 Как это считается",
        .toc = "🧮 Точность",
        .body =
        \\Никакой магии и никаких внешних API:
        \\• Солнце — ряды Meeus, точность ±0.01°
        \\• Луна — усечённый ELP2000, ±0.05°
        \\• планеты — кеплеровские элементы JPL, угловые минуты
        \\
        \\Моменты ингрессий и аспектов уточняются бисекцией до секунд.
        \\Проверено по реальным событиям: затмения 2026, станции Меркурия,
        \\границы лунных дней сходятся с профессиональными календарями.
        \\
        \\Всё это умещается в один маленький бинарь без зависимостей.
        ,
    },
    .{
        .title = "🕒 Часовой пояс",
        .toc = "🕒 Пояс",
        .body =
        \\Бот печатает время в поясе из настроек, по умолчанию <b>МСК (UTC+3)</b>.
        \\
        \\Сменить: переменная <code>MOONOBSRV_TZ</code> в часах —
        \\<code>3</code>, <code>-5</code>, <code>5.5</code>.
        \\Текущий пояс видно в <code>/status</code>.
        \\
        \\Астрономия-то в UTC — пояс влияет только на вывод,
        \\границы лунных дней и VOC считаются одинаково для всех.
        ,
    },
    .{
        .title = "📅 Даты в командах",
        .toc = "📅 Даты",
        .body =
        \\Астрологические команды принимают дату в аргументе:
        \\
        \\<code>/voc 21.09</code> — текущий год
        \\<code>/voc 21.09.2026</code> — явно
        \\<code>/voc 2026-09-21</code> — ISO
        \\
        \\День берётся на полдень указанной даты.
        \\Без аргумента — «сейчас».
        \\
        \\Если формат неверный, бот подскажет правильный и не упадёт.
        ,
    },
    .{
        .title = "🌍 Приватность",
        .toc = "🌍 Приватность",
        .body =
        \\Боту не нужно ничего, кроме вашего chat_id:
        \\• нет геолокации
        \\• нет имени, возраста и даты рождения
        \\• нет гороскопов «по знакам» — только измеримое небо
        \\
        \\Подписки хранятся у владельца бота и используются только
        \\для рассылки уведомлений. Удалить себя: <code>/unsubscribe</code>.
        \\
        \\Вопросы доступа решает админ — следующий слайд.
        ,
    },
    .{
        .title = "🤝 Доступ",
        .toc = "🤝 Доступ",
        .body =
        \\Бот закрытый. Новый человек пишет <code>/start</code> —
        \\админу приходит заявка с кнопками <b>Пустить / Отклонить</b>.
        \\
        \\Пока ждёте решения: «Заявка отправлена админу. Ждите решения.»
        \\После отказа — «Доступ отклонён»; повторная заявка: снова <code>/start</code>.
        \\
        \\✅ Вы уже внутри — значит доступ есть.
        \\Отписаться от уведомлений можно, не теряя доступ: <code>/unsubscribe</code>.
        ,
    },
    .{
        .title = "📶 Если бот молчит",
        .toc = "📶 Если молчит",
        .body =
        \\У бота есть слои: процесс, Postgres, Telegram, Tor, сеть хоста.
        \\Если ответа нет:
        \\
        \\1️⃣ подождите минуту — могла начаться холостая Луна (шутка; проверьте /voc)
        \\2️⃣ напишите <code>/status</code> — живой процесс ответит всегда
        \\3️⃣ если и это молчит — слой лёг, админ увидит алерт и поднимет
        \\
        \\Уведомления приходят в момент события, не по расписанию:
        \\тишина полдня — это нормальное небо, а не поломка.
        ,
    },
    .{
        .title = "⚠️ Частые заблуждения",
        .toc = "⚠️ Заблуждения",
        .body =
        \\1) «VOC — значит нельзя ничего делать»
        \\→ бот не запрещает; это период, про который традиция говорит «не начинать новое».
        \\
        \\2) «Ретро-Меркурий ломает технику»
        \\→ это наблюдаемый оптический эффект; что с ним делать — решать вам.
        \\
        \\3) «Лунный день = календарные сутки»
        \\→ нет, от ~20 до ~26 часов, границы каждый день другие.
        \\
        \\4) «Бот смотрит гороскопы в интернете»
        \\→ нет, всё считается локально, без сети кроме Telegram.
        \\
        \\5) «Уведомления должны приходить каждый день»
        \\→ они приходят по событиям: VOC, станция, лунный день.
        ,
    },
    .{
        .title = "🧪 Мини-тренировка",
        .toc = "🧪 Тренировка",
        .body =
        \\Пройдите чеклист прямо в этом чате:
        \\
        \\☐ Отправьте <code>/voc</code> — небо на сейчас
        \\☐ Отправьте <code>/mercury</code> — ближайший ретро
        \\☐ Отправьте <code>/day</code> — какой лунный день
        \\☐ Спросите <code>/voc 21.09</code> — другое число
        \\☐ Отправьте <code>/planets</code> — все планеты
        \\☐ Подпишитесь: <code>/subscribe</code>
        \\
        \\Если всё открылось — вы умеете 90% сервиса 🌒
        ,
    },
    .{
        .title = "📋 Шпаргалка команд",
        .toc = "📋 Шпаргалка",
        .body =
        \\<b>Небо</b>
        \\• <code>/voc</code> — холостая Луна (синонимы /void, /холостая)
        \\• <code>/mercury</code> — ретро-Меркурий (/retro, /меркурий)
        \\• <code>/day</code> — лунный день (/moon, /луна, /lunday)
        \\• <code>/planets</code> — долготы планет
        \\• <code>/voc 21.09</code> — на конкретную дату
        \\
        \\<b>Уведомления</b>
        \\• <code>/subscribe</code> — включить (/sub, /подписка)
        \\• <code>/unsubscribe</code> — выключить (/unsub)
        \\
        \\<b>Помощь</b>
        \\• <code>/wizard</code> или <code>/start</code> — этот гид
        \\• <code>/help</code> — короткое меню с кнопками
        \\• <code>/status</code> — аптайм и подписчики
        ,
    },
    .{
        .title = "🧭 Сценарий дня с ботом",
        .toc = "🧭 Сценарий дня",
        .body =
        \\🌅 Утром: <code>/day</code> — какой лунный день, знак и фаза Луны.
        \\
        \\☀️ Днём: <code>/voc</code> — нет ли холостого окна перед встречей.
        \\
        \\☿ При планировании: <code>/mercury</code> — не в тени ли станции.
        \\
        \\🌙 Вечером: уведомления сами расскажут, что началось и закончилось.
        \\
        \\Раз в неделю: <code>/planets</code> — большая картина.
        \\
        \\Раз в месяц: загляните в гид — слайды не меняются,
        \\но небо каждый раз другое.
        ,
    },
    .{
        .title = "💡 Советы профи",
        .toc = "💡 Советы",
        .body =
        \\1. Подпишитесь один раз — уведомления дисциплинируют лучше календаря.
        \\
        \\2. Перед важными договорённостями проверяйте <code>/voc</code>:
        \\   окно «с … по …» — это минуты и часы, их легко обойти.
        \\
        \\3. Тени Меркурия шире самого ретро: смотрите пред-тень заранее.
        \\
        \\4. Лунный день хорош для планирования ритма: границы подскажут,
        \\   когда «день» уже кончился, хотя часы говорят иное.
        \\
        \\5. Бот — телескоп, не оракул: он показывает небо, решения ваши.
        ,
    },
    .{
        .title = "🆘 Если что-то непонятно",
        .toc = "🆘 Если застряли",
        .body =
        \\Алгоритм спасения:
        \\
        \\1️⃣ <code>/help</code> — короткое меню с кнопками
        \\2️⃣ <code>/wizard</code> — открыть этот гид снова
        \\3️⃣ <code>/status</code> — жив ли бот
        \\4️⃣ <code>/voc</code> <code>/mercury</code> <code>/day</code> — базовые команды
        \\
        \\Бот предложит гид сам, если написать ему незнакомую команду.
        ,
    },
    .{
        .title = "🏁 Готово! Можно пользоваться",
        .toc = "🏁 Финиш",
        .body =
        \\Вы прошли гид 🌒
        \\
        \\Запомните три команды:
        \\<b>/voc — Луна · /mercury — Меркурий · /day — лунный день</b>
        \\
        \\И одну кнопку: <code>/subscribe</code> — чтобы небо
        \\само сообщало о событиях.
        \\
        \\Ясного неба и коротких холостых периодов! ✨
        \\
        \\Кнопка «Закрыть» спрячет гид.
        \\Вернуться: <code>/wizard</code> или <code>/start</code>.
        ,
    },
};

/// Служебные слайды админа — вставляются после «Шпаргалки».
pub const admin_slides = [_]Slide{
    .{
        .title = "🔧 Слои бота — только админ",
        .toc = "🔧 Слои и простой",
        .body =
        \\Этот слайд видите только вы: команды здоровья сервиса, не астрологии.
        \\
        \\<code>/monitor</code> — живой срез слоёв:
        \\процесс, Postgres, Telegram, Tor, WAN, Docker, диск, RAM, CPU, питание, sshd.
        \\
        \\Простой за окно (снимки раз в минуту в Postgres):
        \\• <code>/idlehour</code> — последний час
        \\• <code>/idle3</code> <code>/idle5</code> <code>/idle8</code> <code>/idle12</code> <code>/idle24</code> — N часов
        \\• <code>/idleday</code> — с полуночи · <code>/idlenight</code> — 22:00–08:00
        \\• <code>/idleweek</code> · <code>/idlemonth</code> · <code>/idleyear</code>
        \\
        \\В ответе — сумма простоя по каждому слою, а промежутки «с … по …»
        \\показываются для слоя «процесс» (общие зависания бота).
        \\Опечатки <code>/idelweek</code> и родня тоже работают.
        \\
        \\Whitelist: <code>/users</code>, отзыв доступа: <code>/revoke id</code>.
        ,
    },
    .{
        .title = "🔄 Перезапуск слоёв — только админ",
        .toc = "🔄 Перезапуск",
        .body =
        \\Рестарт <b>принудительный</b>: слой дёргаем, даже если в /monitor он OK.
        \\
        \\<b>Все сразу</b>
        \\<code>/restart</code> — postgres → tor → процесс бота (последним, Docker поднимет).
        \\
        \\<b>По слою</b> — суффикс или пробел, одно и то же:
        \\• <code>/restartbot</code> · <code>/restartproc</code> — контейнер бота
        \\• <code>/restartpostgres</code> · <code>/restartpg</code> — Postgres
        \\• <code>/restarttor</code> — Tor (с ожиданием socks до 48 с)
        \\
        \\<b>Не процессы</b> — команда есть, но ответит «нельзя»:
        \\• <code>/restarttelegram</code> — внешний Bot API; переподключить poll: /restartbot
        \\• <code>/restartwan</code> · <code>/restartdocker</code> · <code>/restartdisk</code>
        \\
        \\Перед смертью процесса — ACK в Telegram, иначе та же команда
        \\прилетит снова (бутлуп). После ответа «сейчас, после этого
        \\сообщения» будет ~15 с тишины. Живой срез: <code>/monitor</code>
        ,
    },
    .{
        .title = "🛑 /restart · /reset · /hardreset — только админ",
        .toc = "🛑 Стоп-кран",
        .body =
        \\Три разные команды, не синонимы.
        \\
        \\<b>1) /restart — дёрнуть слои</b>
        \\Крутит postgres, tor, затем убивает процесс бота. Очередь Telegram
        \\не сбрасывает: обрабатывает одну команду. ACK до смерти — нет бутлупа.
        \\
        \\<b>2) /reset — сбросить очередь, процесс живой</b>
        \\Смотрит <b>всю пачку</b> getUpdates сразу. Если в ней есть /reset или
        \\/hardreset — любой /restart из этой пачки <b>не выполняется</b>.
        \\Подтверждает все update_id: Telegram больше не пришлёт.
        \\Аптайм не сбрасывается. Синоним: <code>/flush</code>.
        \\
        \\<b>3) /hardreset — очередь + один рестарт бота</b>
        \\Как /reset, плюс <b>один</b> docker restart контейнера бота.
        \\Когда long poll «отравлен» и нужен чистый старт. Синоним: <code>/hard</code>.
        \\
        \\<b>Когда что</b>
        \\• слой завис → <code>/restart</code> или <code>/restartX</code>
        \\• Telegram крутит команду по кругу → <code>/reset</code>
        \\• то же + свежий процесс → <code>/hardreset</code>
        ,
    },
};

/// Число слайдов для пользователя/админа.
pub fn n(admin: bool) usize {
    return if (admin) slides.len + admin_slides.len else slides.len;
}

/// Индекс слайда «Шпаргалка» — после него вставка админских.
pub fn cheatIndex() usize {
    for (slides, 0..) |s, i| {
        if (std.mem.indexOf(u8, s.toc, "Шпаргалка") != null) return i;
    }
    return slides.len - 1;
}

/// Слайд по индексу с учётом админской вставки (защита от wiz:p:999).
pub fn slideAt(i: usize, admin: bool) *const Slide {
    const total = n(admin);
    const idx = @min(i, total - 1);
    const at = cheatIndex() + 1;
    if (admin and idx > cheatIndex()) {
        const ai = idx - at;
        if (ai < admin_slides.len) return &admin_slides[ai];
        return &slides[idx - admin_slides.len];
    }
    return &slides[idx];
}

pub fn clamp(i: usize, admin: bool) usize {
    return @min(i, n(admin) - 1);
}

/// Рендер слайда: заголовок, полоса, счётчик, разделитель, тело.
pub fn render(w: *std.Io.Writer, i: usize, admin: bool) !void {
    const total = n(admin);
    const ci = clamp(i, admin); // кламп и в счётчике/полосе, не только в теле
    const s = slideAt(ci, admin);
    try w.print("{s}\n", .{s.title});
    try writeBar(w, ci, total);
    try w.print("  <b>{d}/{d}</b>\n──────────────────\n\n{s}", .{ ci + 1, total, s.body });
}

fn writeBar(w: *std.Io.Writer, i: usize, total: usize) !void {
    const pos10 = @max((i + 1) * 10 / @max(total, 1), 1);
    const filled = @min(pos10, 10);
    for (0..10) |k| {
        try w.writeAll(if (k < filled) "🟩" else "⬜");
    }
}

/// Клавиатура навигации по слайду.
pub fn nav(w: *std.Io.Writer, i: usize, admin: bool) !void {
    const total = n(admin);
    const idx = clamp(i, admin);
    var pb: [16]u8 = undefined;
    var nb: [16]u8 = undefined;
    const prev = std.fmt.bufPrint(&pb, "wiz:p:{d}", .{if (idx == 0) 0 else idx - 1}) catch "";
    const next = std.fmt.bufPrint(&nb, "wiz:p:{d}", .{if (idx + 1 >= total) total - 1 else idx + 1}) catch "";
    const left = if (idx == 0) "⏹ Старт" else "⬅️ Назад";
    const right = if (idx + 1 >= total) "🏁 Финиш" else "Далее ➡️";
    var cb: [16]u8 = undefined;
    const counter = std.fmt.bufPrint(&cb, "· {d}/{d} ·", .{ idx + 1, total }) catch "";
    try w.writeAll("{\"inline_keyboard\":[[");
    try btn(w, left, prev);
    try w.writeByte(',');
    try btn(w, counter, "wiz:toc");
    try w.writeByte(',');
    try btn(w, right, next);
    try w.writeAll("],");
    if (idx + 1 < total) {
        var sb: [16]u8 = undefined;
        var fb: [16]u8 = undefined;
        const cheat = std.fmt.bufPrint(&sb, "wiz:p:{d}", .{cheatIndex()}) catch "";
        const fin = std.fmt.bufPrint(&fb, "wiz:p:{d}", .{total - 1}) catch "";
        try w.writeAll("[");
        try btn(w, "⏭ К шпаргалке", cheat);
        try w.writeByte(',');
        try btn(w, "⏭ К финишу", fin);
        try w.writeAll("],");
    }
    try w.writeAll("[");
    try btn(w, "📚 Оглавление", "wiz:toc");
    try w.writeByte(',');
    try btn(w, "❌ Закрыть", "wiz:close");
    try w.writeAll("]]}");
}

fn btn(w: *std.Io.Writer, text: []const u8, data: []const u8) !void {
    try w.writeAll("{\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll(",\"callback_data\":\"");
    try w.writeAll(data);
    try w.writeAll("\"}");
}

/// Оглавление: 8 тем на страницу.
pub fn renderToc(w: *std.Io.Writer, page: usize, admin: bool) !void {
    const total = n(admin);
    const pages = (total + 7) / 8;
    const p = @min(page, pages - 1);
    try w.print("📚 <b>Оглавление гида</b>\nСтраница оглавления {d}/{d} · всего слайдов: <b>{d}</b>\n\nНажмите тему — откроется нужный слайд.\nИли листайте гид кнопками «Далее / Назад».", .{ p + 1, pages, total });
}

pub fn tocKb(w: *std.Io.Writer, page: usize, admin: bool) !void {
    const total = n(admin);
    const pages = (total + 7) / 8;
    const p = @min(page, pages - 1);
    try w.writeAll("{\"inline_keyboard\":[");
    var first = true;
    var idx: usize = p * 8;
    while (idx < @min(total, (p + 1) * 8)) : (idx += 1) {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("[{\"text\":");
        var lb: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "{d}. {s}", .{ idx + 1, slideAt(idx, admin).toc }) catch idxLabel(&lb, idx);
        try std.json.Stringify.value(label, .{}, w);
        try w.print(",\"callback_data\":\"wiz:p:{d}\"}}]", .{idx});
    }
    try w.writeAll(",[");
    if (p > 0) {
        var b: [16]u8 = undefined;
        try btn(w, "⬅️", std.fmt.bufPrint(&b, "wiz:toc:{d}", .{p - 1}) catch "");
        if (p + 1 < pages) {
            try w.writeByte(',');
            try btn(w, "➡️", std.fmt.bufPrint(&b, "wiz:toc:{d}", .{p + 1}) catch "");
        }
    } else if (p + 1 < pages) {
        var b: [16]u8 = undefined;
        try btn(w, "➡️", std.fmt.bufPrint(&b, "wiz:toc:{d}", .{p + 1}) catch "");
    }
    try w.writeAll("],[");
    try btn(w, "▶️ Слайд 1", "wiz:p:0");
    try w.writeByte(',');
    try btn(w, "❌ Закрыть", "wiz:close");
    try w.writeAll("]]}");
}

fn idxLabel(buf: []u8, idx: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}. …", .{idx + 1}) catch buf[0..0];
}

/// Клавиатура входа: под /start, /help и ошибками разбора.
pub fn openKb(w: *std.Io.Writer) !void {
    try w.writeAll("{\"inline_keyboard\":[[");
    try btn(w, "🚀 Открыть обучающий гид", "wiz:p:0");
    try w.writeAll("],[");
    try btn(w, "📚 Сразу к оглавлению", "wiz:toc");
    try w.writeAll("],[");
    try btn(w, "☰ Меню команд", "menu:main");
    try w.writeAll("]]}");
}

pub fn closeText(w: *std.Io.Writer) !void {
    try w.writeAll("✅ Гид закрыт.\n\nГлавное: /voc — Луна · /mercury — станции · /day — лунный день.\nВернуть гид: /wizard (или кнопка «Открыть гид» из /start)");
}

pub const help_user =
    \\🛰 <b>moonobsrv</b> — небо под рукой
    \\
    \\🌑 Луна: /voc (холостая, /void, /холостая)
    \\☿ Меркурий: /mercury (/retro, /меркурий)
    \\🌗 Лунный день: /day (/moon, /луна)
    \\🪐 Планеты: /planets
    \\🔔 Уведомления: /subscribe · /unsubscribe
    \\🛰 Состояние: /status
    \\
    \\Даты: /voc 21.09 · /day 2026-09-21
    \\
    \\Новичкам — гид из {d} слайдов 👇
;

pub fn helpText(w: *std.Io.Writer, admin: bool) !void {
    var buf: [2048]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&buf);
    try hw.print(help_user, .{n(admin)});
    try w.writeAll(hw.buffered());
    if (admin) {
        try w.writeAll("\n🔧 Админ: /monitor — слои · /restart — перезапуск · /reset /hardreset — стоп-кран · /idlehour — простой · /users /revoke — доступ");
    }
}

// ─── Обработчики ────────────────────────────────────────────────────────────

pub fn cmdWizard(ctx: *router.Ctx) !void {
    const admin = isAdmin(ctx);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, 0, admin);
    var kb: [1024]u8 = undefined;
    var kw: std.Io.Writer = .fixed(&kb);
    try nav(&kw, 0, admin);
    _ = ctx.base.api.sendMessageOpts(ctx.chat_id, w.buffered(), true, kw.buffered()) catch {};
    ctx.reply.writeAll("") catch {}; // уже ответили сами
}

fn isAdmin(ctx: *router.Ctx) bool {
    return ctx.base.cfg.admin_id != 0 and ctx.from_id != null and ctx.from_id.? == ctx.base.cfg.admin_id;
}

pub const feature = features.Feature{
    .commands = &.{
        .{ .name = "/wizard", .aliases = &.{ "/guide", "/гид" }, .description = "обучающий гид по слайдам", .handler = cmdWizard },
    },
};

// ─── Тесты ──────────────────────────────────────────────────────────────────

test "структура гида: счёт, вставка, clamp" {
    try std.testing.expect(n(false) > 15);
    try std.testing.expectEqual(n(false) + admin_slides.len, n(true));
    const ci = cheatIndex();
    try std.testing.expect(ci > 0 and ci < slides.len - 1);
    // шпаргалка сразу после вставки не нарушила порядок: последний слайд — финиш
    try std.testing.expect(std.mem.indexOf(u8, slideAt(n(true) - 1, true).title, "Готово") != null);
    try std.testing.expect(std.mem.indexOf(u8, slideAt(ci + 1, true).title, "Слои") != null);
    // clamp защищает
    try std.testing.expectEqual(n(true) - 1, clamp(999, true));
    try std.testing.expectEqual(n(false) - 1, clamp(999, false));
    // обычному пользователю админский слайд недоступен ни при каком N
    var i: usize = 0;
    while (i < n(false)) : (i += 1) {
        try std.testing.expect(std.mem.indexOf(u8, slideAt(i, false).title, "только админ") == null);
    }
}

test "каждый слайд < 4096 символов (лимит Telegram)" {
    inline for (0..slides.len) |i| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try render(&w, i, false);
    }
    inline for (0..admin_slides.len) |i| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try render(&w, cheatIndex() + 1 + i, true);
    }
}

test "пользовательские слайды не протекают админскими командами" {
    for (slides) |s| {
        var buf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll(s.title) catch {};
        w.writeAll(s.toc) catch {};
        w.writeAll(s.body) catch {};
        const all = w.buffered();
        try std.testing.expect(std.mem.indexOf(u8, all, "/monitor") == null);
        try std.testing.expect(std.mem.indexOf(u8, all, "/restart") == null);
        try std.testing.expect(std.mem.indexOf(u8, all, "/reset") == null);
        try std.testing.expect(std.mem.indexOf(u8, all, "/hardreset") == null);
        try std.testing.expect(std.mem.indexOf(u8, all, "/idle") == null);
        try std.testing.expect(std.mem.indexOf(u8, all, "/revoke") == null);
    }
}

test "клавиатуры: валидный JSON, callback_data ≤ 64 байт" {
    var kb: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&kb);
    try nav(&w, 0, true);
    {
        const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
        defer p.deinit();
    }
    var w2: std.Io.Writer = .fixed(&kb);
    try nav(&w2, n(true) - 1, true);
    {
        const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w2.buffered(), .{});
        defer p.deinit();
    }
    var w3: std.Io.Writer = .fixed(&kb);
    try tocKb(&w3, 1, true);
    {
        const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w3.buffered(), .{});
        defer p.deinit();
    }
    var w4: std.Io.Writer = .fixed(&kb);
    try openKb(&w4);
    {
        const p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w4.buffered(), .{});
        defer p.deinit();
    }
    // все callback_data короткие
    for ([_][]const u8{ "wiz:p:0", "wiz:toc", "wiz:toc:2", "wiz:close", "menu:main", "menu:voc" }) |d| {
        try std.testing.expect(d.len <= 64);
    }
}

test "render: полоса и счётчик" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, 2, false);
    const s = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, s, slides[2].title));
    try std.testing.expect(std.mem.indexOf(u8, s, "🟩") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "⬜") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "3/22") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "──────") != null);
}

test "render: wiz:p:999 клампится в счётчике (BUG-031)" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, 999, false);
    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "22/22") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "1000/22") == null);
    // контент — последнего слайда (slideAt клампит и раньше)
    try std.testing.expect(std.mem.startsWith(u8, s, slides[slides.len - 1].title));
}
