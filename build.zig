const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Режим по умолчанию для релиза — минимальный размер (zig build -Drelease).
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // Агрессивное урезание бинарника: всё ненужное вычищается линкером.
    // gc-sections и function/data sections в релизе включены по умолчанию.
    // Потоки нужны (фоновый ватчер), иначе single_threaded тоже был бы здесь.
    const smol = optimize != .Debug;
    const exe = b.addExecutable(.{
        .name = "moonobsrv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = smol, // без символов
            .omit_frame_pointer = smol,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Запустить бота (аргументы: --today, --help)");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Юнит-тесты и астрономические якоря");
    test_step.dependOn(&run_tests.step);
}
