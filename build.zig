const std = @import("std");
const config = @import("src/config.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigatlas",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests and the command-line fixtures");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    addFixtureTests(b, exe, test_step);

    // zigatlas maps itself: the CLI drives the pipeline, the renderers only
    // read the atlas, the checks and clone detection judge what scanning
    // collected, and the model and config sit underneath everything.
    _ = addAtlasRun(b, exe, .{
        .name = "zigatlas",
        .layers = &.{
            .{ .name = "cli", .paths = &.{"src/main.zig"}, .thin = true },
            .{ .name = "render", .paths = &.{"src/render.zig"} },
            .{ .name = "analysis", .paths = &.{ "src/checks.zig", "src/clones.zig" } },
            .{ .name = "scan", .paths = &.{"src/scan.zig"} },
            .{ .name = "base", .paths = &.{ "src/config.zig", "src/model.zig" } },
        },
    });
}

/// Runs the built tool on `testdata/` the way a project would.
fn addFixtureTests(b: *std.Build, exe: *std.Build.Step.Compile, test_step: *std.Build.Step) void {
    // `--root .` must still see the layers and resolve imports: the fixture's
    // forbidden import fails `--check`, and the log names it.
    const dot_root = b.addRunArtifact(exe);
    dot_root.setCwd(b.path("testdata/layered"));
    dot_root.addArgs(&.{ "--root", ".", "--layer", "fs=src/fs", "--layer", "net=src/net", "--forbid", "fs:net", "--check", "--out" });
    _ = dot_root.addOutputDirectoryArg("atlas");
    dot_root.expectExitCode(1);
    dot_root.addCheck(.{ .expect_stderr_match = "src/fs/share.zig:1: error: forbidden_import" });
    test_step.dependOn(&dot_root.step);

    // A root that doesn't exist is an error, not an empty, passing atlas.
    const missing = b.addRunArtifact(exe);
    missing.setCwd(b.path("testdata/layered"));
    missing.addArgs(&.{ "--root", "nosuch", "--check", "--out" });
    _ = missing.addOutputDirectoryArg("atlas");
    missing.expectExitCode(2);
    test_step.dependOn(&missing.step);
}

/// A layer of the architecture. Give layers top (front ends) to bottom
/// (foundations): a layer may import itself and the layers below it.
pub const Layer = config.Layer;

/// Imports that must not happen even though the layer order allows them,
/// e.g. a layer skipping the one below it.
pub const Rule = config.Rule;

/// `@import("name")` resolving to a project file that the build graph
/// doesn't show (see `addAtlasStep`).
pub const Module = config.Module;

const defaults: config.Config = .{};

pub const Options = struct {
    /// Project name for the report; defaults to the build root's directory name.
    name: ?[]const u8 = null,
    step_name: []const u8 = "atlas",
    step_description: []const u8 = "Map the code (imports, API, calls) and report duplication and architecture problems",
    roots: []const []const u8 = &.{"src"},
    /// Where else to look for uses of names (tests, tools); default: the
    /// whole build root.
    usage_roots: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    layers: []const Layer = &.{},
    forbid: []const Rule = &.{},
    /// Extra `@import` names, on top of the ones found in the build graph.
    modules: []const Module = &.{},
    /// Output directory under the install prefix (zig-out by default).
    output: []const u8 = "atlas",
    min_clone_tokens: u32 = defaults.min_clone_tokens,
    min_fn_tokens: u32 = defaults.min_fn_tokens,
    max_fn_lines: u32 = defaults.max_fn_lines,
    max_complexity: u32 = defaults.max_complexity,
    max_params: u32 = defaults.max_params,
    max_file_lines: u32 = defaults.max_file_lines,
    thin_max_complexity: u32 = defaults.thin_max_complexity,
};

/// Adds `zig build atlas` (or `options.step_name`) to a project that depends
/// on zigatlas. Extra arguments go to the tool: `zig build atlas -- --check`
/// fails the build when error findings (layer breaks, forbidden imports) exist.
///
/// Call it at the end of `build()`: `@import` names are read from the modules
/// and compile steps defined so far.
pub fn addAtlasStep(b: *std.Build, options: Options) *std.Build.Step {
    const dep = b.dependencyFromBuildZig(@This(), .{ .optimize = .ReleaseSafe });
    return addAtlasRun(b, dep.artifact("zigatlas"), options);
}

fn addAtlasRun(b: *std.Build, exe: *std.Build.Step.Compile, options: Options) *std.Build.Step {
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    // Inputs are whole source trees the build system does not track.
    run.has_side_effects = true;

    run.addArgs(&.{ "--name", options.name orelse std.fs.path.basename(b.build_root.path orelse ".") });
    for (options.roots) |r| run.addArgs(&.{ "--root", r });
    for (options.usage_roots) |r| run.addArgs(&.{ "--usage-root", r });
    for (options.exclude) |e| run.addArgs(&.{ "--exclude", e });
    for (options.layers) |layer| {
        run.addArgs(&.{ "--layer", b.fmt("{s}={s}", .{ layer.name, joinPaths(b, layer.paths) }) });
        if (layer.thin) run.addArgs(&.{ "--thin", layer.name });
    }
    for (options.forbid) |r| run.addArgs(&.{ "--forbid", b.fmt("{s}:{s}:{s}", .{ r.from, r.to, r.reason }) });
    for (options.modules) |m| run.addArgs(&.{ "--module", moduleArg(b, m.name, m.path, m.scope) });
    addModuleArgs(b, run);

    run.addArgs(&.{ "--out", b.getInstallPath(.prefix, options.output) });
    const numbers = [_]struct { []const u8, u32 }{
        .{ "--min-clone-tokens", options.min_clone_tokens },
        .{ "--min-fn-tokens", options.min_fn_tokens },
        .{ "--max-fn-lines", options.max_fn_lines },
        .{ "--max-complexity", options.max_complexity },
        .{ "--max-params", options.max_params },
        .{ "--max-file-lines", options.max_file_lines },
        .{ "--thin-max-complexity", options.thin_max_complexity },
    };
    for (numbers) |n| run.addArgs(&.{ n[0], b.fmt("{d}", .{n[1]}) });
    if (b.args) |args| run.addArgs(args);

    const step = b.step(options.step_name, options.step_description);
    step.dependOn(&run.step);
    return step;
}

/// Passes every `@import` name this build wires to one of its own files, the
/// way the compiler resolves it: public modules (`b.addModule`) by their
/// registered name everywhere, and each module's imports (`addImport`, also
/// on `createModule` modules and compile steps) by their import name inside
/// the importing module's directory.
fn addModuleArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    for (b.modules.keys(), b.modules.values()) |name, module| {
        if (ownPath(b, module)) |path| run.addArgs(&.{ "--module", moduleArg(b, name, path, "") });
    }

    var seen: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    var queue: std.ArrayList(*std.Build.Module) = .empty;
    for (b.modules.values()) |m| enqueue(b, &seen, &queue, m);
    var steps: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    for (b.top_level_steps.values()) |tls| collectCompileModules(b, &tls.step, &steps, &seen, &queue);

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const module = queue.items[i];
        const scope = if (ownPath(b, module)) |p| std.fs.path.dirname(p) orelse "." else continue;
        for (module.import_table.keys(), module.import_table.values()) |name, imported| {
            if (ownPath(b, imported)) |path| run.addArgs(&.{ "--module", moduleArg(b, name, path, scope) });
            enqueue(b, &seen, &queue, imported);
        }
    }
}

fn collectCompileModules(
    b: *std.Build,
    step: *std.Build.Step,
    steps: *std.AutoHashMapUnmanaged(*std.Build.Step, void),
    seen: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
    queue: *std.ArrayList(*std.Build.Module),
) void {
    const gop = steps.getOrPut(b.allocator, step) catch @panic("OOM");
    if (gop.found_existing) return;
    if (step.cast(std.Build.Step.Compile)) |compile| enqueue(b, seen, queue, compile.root_module);
    for (step.dependencies.items) |dep| collectCompileModules(b, dep, steps, seen, queue);
}

fn enqueue(b: *std.Build, seen: *std.AutoHashMapUnmanaged(*std.Build.Module, void), queue: *std.ArrayList(*std.Build.Module), m: *std.Build.Module) void {
    const gop = seen.getOrPut(b.allocator, m) catch @panic("OOM");
    if (!gop.found_existing) queue.append(b.allocator, m) catch @panic("OOM");
}

/// The module's root file, when it is a source file of this build.
fn ownPath(b: *std.Build, m: *std.Build.Module) ?[]const u8 {
    const root = m.root_source_file orelse return null;
    return switch (root) {
        .src_path => |p| if (p.owner == b) p.sub_path else null,
        else => null,
    };
}

fn moduleArg(b: *std.Build, name: []const u8, path: []const u8, scope: []const u8) []const u8 {
    if (scope.len == 0) return b.fmt("{s}={s}", .{ name, path });
    return b.fmt("{s}={s}@{s}", .{ name, path, scope });
}

fn joinPaths(b: *std.Build, paths: []const []const u8) []const u8 {
    return std.mem.join(b.allocator, ",", paths) catch @panic("OOM");
}
