const std = @import("std");

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
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

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

/// A layer of the architecture. Give layers top (front ends) to bottom
/// (foundations): a layer may import itself and the layers below it.
pub const Layer = struct {
    name: []const u8,
    /// Directories or files, relative to the build root.
    paths: []const []const u8,
    /// Front ends: should only parse input and present output.
    thin: bool = false,
};

/// Imports that must not happen even though the layer order allows them,
/// e.g. a layer skipping the one below it.
pub const Rule = struct {
    /// Layer name or path prefix.
    from: []const u8,
    to: []const u8,
    reason: []const u8 = "",
};

pub const Options = struct {
    /// Project name for the report; defaults to the root package name.
    name: ?[]const u8 = null,
    step_name: []const u8 = "atlas",
    step_description: []const u8 = "Map the code (imports, API, calls) and report duplication and architecture problems",
    roots: []const []const u8 = &.{"src"},
    exclude: []const []const u8 = &.{},
    layers: []const Layer = &.{},
    forbid: []const Rule = &.{},
    /// Output directory under the install prefix (zig-out by default).
    output: []const u8 = "atlas",
    min_clone_tokens: u32 = 60,
    min_fn_tokens: u32 = 40,
    max_fn_lines: u32 = 80,
    max_complexity: u32 = 20,
    max_params: u32 = 6,
    max_file_lines: u32 = 1000,
    thin_max_complexity: u32 = 10,
};

/// Adds `zig build atlas` (or `options.step_name`) to a project that depends
/// on zigatlas. Extra arguments go to the tool: `zig build atlas -- --check`
/// fails the build when error findings (layer breaks, forbidden imports) exist.
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
    for (options.exclude) |e| run.addArgs(&.{ "--exclude", e });
    for (options.layers) |layer| {
        run.addArgs(&.{ "--layer", b.fmt("{s}={s}", .{ layer.name, joinPaths(b, layer.paths) }) });
        if (layer.thin) run.addArgs(&.{ "--thin", layer.name });
    }
    for (options.forbid) |r| run.addArgs(&.{ "--forbid", b.fmt("{s}:{s}:{s}", .{ r.from, r.to, r.reason }) });

    // Public modules of this build resolve `@import("name")` to project files.
    for (b.modules.keys(), b.modules.values()) |name, module| {
        const root = module.root_source_file orelse continue;
        switch (root) {
            .src_path => |p| if (p.owner == b) run.addArgs(&.{ "--module", b.fmt("{s}={s}", .{ name, p.sub_path }) }),
            else => {},
        }
    }

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

fn joinPaths(b: *std.Build, paths: []const []const u8) []const u8 {
    return std.mem.join(b.allocator, ",", paths) catch @panic("OOM");
}
