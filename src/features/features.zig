//! Реестр фич. Фича = набор команд + опциональный ватчер (on_tick).
//! Чтобы добавить функциональность: создайте src/features/xxx.zig с
//! `pub const feature = Feature{...}` и допишите модуль в `all` ниже.

const std = @import("std");
const router = @import("../bot/router.zig");

pub const Feature = struct {
    commands: []const router.Command = &.{},
    /// Вызывается в цикле мониторинга: сравнивает состояние неба с
    /// сохранённым и рассылает уведомления при переходах.
    on_tick: ?*const fn (router.Base) anyerror!void = null,
};

const f_voc = @import("voc.zig");
const f_mercury = @import("mercury.zig");
const f_lunday = @import("lunday.zig");
const f_planets = @import("planets.zig");
const f_service = @import("service.zig");
const f_wizard = @import("wizard.zig");
const f_monitor = @import("monitor.zig");

pub const all = [_]Feature{
    f_voc.feature,
    f_mercury.feature,
    f_lunday.feature,
    f_planets.feature,
    f_service.feature,
    f_wizard.feature,
    f_monitor.feature,
};

/// Плоский реестр команд, собранный на компиляции из всех фич.
pub const commands = blk: {
    var total: usize = 0;
    for (all) |f| total += f.commands.len;
    var cmds: [total]router.Command = undefined;
    var i: usize = 0;
    for (all) |f| {
        for (f.commands) |c| {
            cmds[i] = c;
            i += 1;
        }
    }
    break :blk cmds;
};

comptime {
    if (commands.len == 0) @compileError("реестр команд пуст");
    // буфер setMyCommands в main.zig рассчитан на 64 команды
    if (commands.len > 64) @compileError("слишком много команд для setMyCommands");
}
