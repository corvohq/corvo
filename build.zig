const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // --- Talon dependency ---
    const talon_dep = b.dependency("talon-zig", .{
        .target = target,
        .optimize = optimize,
    });
    const talon_mod = talon_dep.module("talon");

    // --- zigstache dependency ---
    const zigstache_dep = b.dependency("zigstache", .{
        .target = target,
        .optimize = optimize,
    });
    const zigstache_mod = zigstache_dep.module("zigstache");

    // --- Corvo library module ---
    const corvo_mod = b.addModule("corvo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    corvo_mod.addImport("talon", talon_mod);
    corvo_mod.addImport("zigstache", zigstache_mod);
    corvo_mod.addAnonymousImport("ui_embed", .{ .root_source_file = b.path("ui_embed.zig") });
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
    test_mod.addImport("zigstache", zigstache_mod);
    test_mod.addAnonymousImport("ui_embed", .{ .root_source_file = b.path("ui_embed.zig") });
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
    const server_exe = b.addExecutable(.{
        .name = "corvo",
        .root_module = main_mod,
    });
    b.installArtifact(server_exe);
    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |a| run_server.addArgs(a);
    const run_step = b.step("run", "Run the Corvo server");
    run_step.dependOn(&run_server.step);

    // --- corvo-inspect CLI ---
    const inspect_mod = b.createModule(.{
        .root_source_file = b.path("src/inspect.zig"),
        .target = target,
        .optimize = optimize,
    });
    inspect_mod.addImport("talon", talon_mod);
    inspect_mod.addImport("corvo", corvo_mod);
    const inspect_exe = b.addExecutable(.{
        .name = "corvo-inspect",
        .root_module = inspect_mod,
    });
    b.installArtifact(inspect_exe);
    const run_inspect = b.addRunArtifact(inspect_exe);
    if (b.args) |a| run_inspect.addArgs(a);
    const inspect_step = b.step("inspect", "Run corvo-inspect CLI");
    inspect_step.dependOn(&run_inspect.step);
}
