const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Talon dependency ---
    const talon_dep = b.dependency("talon-zig", .{
        .target = target,
        .optimize = optimize,
    });
    const talon_mod = talon_dep.module("talon");

    // --- UI embed module (lives at project root so @embedFile reaches ui/dist/) ---
    const ui_mod = b.addModule("ui", .{
        .root_source_file = b.path("ui_embed.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Corvo library module ---
    const corvo_mod = b.addModule("corvo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    corvo_mod.addImport("talon", talon_mod);
    corvo_mod.addImport("ui", ui_mod);
    corvo_mod.link_libc = true;
    corvo_mod.linkSystemLibrary("sqlite3", .{});

    // --- Static library ---
    const lib = b.addLibrary(.{
        .name = "corvo",
        .root_module = corvo_mod,
    });
    b.installArtifact(lib);

    // --- Unit tests ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("talon", talon_mod);
    test_mod.addImport("ui", ui_mod);
    test_mod.link_libc = true;
    test_mod.linkSystemLibrary("sqlite3", .{});
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // --- SQLite mirror tests (separate binary to avoid talon interaction) ---
    const sqlite_test_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlite_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_test_mod.link_libc = true;
    sqlite_test_mod.linkSystemLibrary("sqlite3", .{});
    const sqlite_tests = b.addTest(.{
        .root_module = sqlite_test_mod,
    });
    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);
    const sqlite_test_step = b.step("test-sqlite", "Run SQLite mirror tests");
    sqlite_test_step.dependOn(&run_sqlite_tests.step);

    // --- Simulator tests ---
    const sim_mod = b.createModule(.{
        .root_source_file = b.path("src/sim/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_mod.addImport("talon", talon_mod);
    sim_mod.addImport("corvo", corvo_mod);
    const sim_tests = b.addTest(.{
        .root_module = sim_mod,
    });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    const sim_step = b.step("sim", "Run VOPR simulator");
    sim_step.dependOn(&run_sim_tests.step);

    // --- Benchmark executable ---
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("talon", talon_mod);
    // bench.zig imports corvo modules directly (same src/ tree), but needs talon
    // for the DB. Add corvo's source files as imports so it resolves.
    bench_mod.addImport("corvo", corvo_mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // --- RPC Benchmark executable ---
    const bench_rpc_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_rpc.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_rpc_mod.addImport("corvo", corvo_mod);
    const bench_rpc_exe = b.addExecutable(.{
        .name = "bench-rpc",
        .root_module = bench_rpc_mod,
    });
    b.installArtifact(bench_rpc_exe);
    const run_bench_rpc = b.addRunArtifact(bench_rpc_exe);
    if (b.args) |a| run_bench_rpc.addArgs(a);
    const bench_rpc_step = b.step("bench-rpc", "Run RPC benchmarks");
    bench_rpc_step.dependOn(&run_bench_rpc.step);

    // --- Corvo server executable ---
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("talon", talon_mod);
    main_mod.addImport("corvo", corvo_mod);
    main_mod.addImport("ui", ui_mod);
    const server_exe = b.addExecutable(.{
        .name = "corvo",
        .root_module = main_mod,
    });
    b.installArtifact(server_exe);
    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |a| run_server.addArgs(a);
    const run_step = b.step("run", "Run the Corvo server");
    run_step.dependOn(&run_server.step);
}
