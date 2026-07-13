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

    // --- zig-raft dependency ---
    // Note: pass only `target` (not `optimize`). zig-raft's build.zig declares
    // `standardOptimizeOption` per-step, so forwarding `optimize` produces a
    // spurious "invalid option: -Doptimize" stderr line. Tests work either way,
    // but skipping it keeps the build output clean.
    const raft_dep = b.dependency("zig-raft", .{
        .target = target,
    });
    const raft_mod = raft_dep.module("raft");

    // --- Corvo library module ---
    const corvo_mod = b.addModule("corvo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    corvo_mod.addImport("talon", talon_mod);
    corvo_mod.addImport("zigstache", zigstache_mod);
    corvo_mod.addImport("raft", raft_mod);
    corvo_mod.addAnonymousImport("ui_embed", .{ .root_source_file = b.path("ui_embed.zig") });
    corvo_mod.link_libc = true; // required by talon (memory-mapped I/O)

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
    test_mod.addImport("raft", raft_mod);
    test_mod.addAnonymousImport("ui_embed", .{ .root_source_file = b.path("ui_embed.zig") });
    test_mod.link_libc = true;
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    // Debug-mode tests materialize by-value temporaries of the ~5MB Pipeline
    // struct in test-fn frames (a "maintenance scheduling"-sized test frame is
    // ~38MB). The default limit sat within 64KB of that — any struct growth
    // segfaulted at a function prologue with no trace. Make the bound explicit
    // and generous.
    tests.stack_size = 128 * 1024 * 1024;
    if (b.args) |a| tests.filters = a;
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // --- Simulator tests ---
    const sim_mod = b.createModule(.{
        .root_source_file = b.path("src/sim/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_mod.addImport("talon", talon_mod);
    sim_mod.addImport("corvo", corvo_mod);
    sim_mod.addImport("raft", raft_mod);
    const sim_tests = b.addTest(.{
        .root_module = sim_mod,
    });
    sim_tests.stack_size = 128 * 1024 * 1024; // same test-frame growth issue as unit tests
    if (b.args) |a| sim_tests.filters = a;
    const run_sim_tests = b.addRunArtifact(sim_tests);
    const sim_step = b.step("sim", "Run VOPR simulator");
    sim_step.dependOn(&run_sim_tests.step);

    // --- Benchmark executable (zig build bench) — always ReleaseFast ---
    // Build a ReleaseFast corvo module for the bench (independent of user's -Drelease).
    const bench_corvo_mod = b.addModule("corvo-bench", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_corvo_mod.addImport("talon", talon_mod);
    bench_corvo_mod.addImport("zigstache", zigstache_mod);
    bench_corvo_mod.addImport("raft", raft_mod);
    bench_corvo_mod.addAnonymousImport("ui_embed", .{ .root_source_file = b.path("ui_embed.zig") });
    bench_corvo_mod.link_libc = true;

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("corvo", bench_corvo_mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    // Also build a ReleaseFast server for bench to spawn.
    const bench_server_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_server_mod.addImport("talon", talon_mod);
    bench_server_mod.addImport("corvo", bench_corvo_mod);
    const bench_server_exe = b.addExecutable(.{
        .name = "corvo-bench-server",
        .root_module = bench_server_mod,
    });
    b.installArtifact(bench_server_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |a| run_bench.addArgs(a);
    const install_bench_server = b.addInstallArtifact(bench_server_exe, .{});
    run_bench.step.dependOn(&install_bench_server.step); // ensure server is installed first
    const bench_step = b.step("bench", "Run self-contained benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

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

    // --- Seed step (runs: corvo seed [args]) ---
    const run_seed = b.addRunArtifact(server_exe);
    run_seed.addArg("seed");
    if (b.args) |a| run_seed.addArgs(a);
    const seed_step = b.step("seed", "Seed server with sample data for manual testing");
    seed_step.dependOn(&run_seed.step);

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
