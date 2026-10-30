//! zigatlas: maps a Zig code base (files, imports, types, functions, calls)
//! and points at duplication and architecture problems, in forms an LLM agent
//! or a reviewer can read quickly. Run it through `zig build atlas`.
//!
//! This file only runs the stages: read the arguments, find the files, scan,
//! judge, write. Exit codes: 0 done, 1 `--check` failed, 2 bad usage or
//! nothing to scan.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const config = @import("config.zig");
const scan = @import("scan.zig");
const clones = @import("clones.zig");
const checks = @import("checks.zig");
const render = @import("render.zig");

/// Directories never scanned: build output, caches, vendored packages.
const skip_dirs = [_][]const u8{ "zig-out", "zig-cache", "zig-pkg", "node_modules", "build" };
/// Largest source file read.
const max_file_bytes = 64 << 20;
/// Failing findings printed by `--check`.
const max_check_lines = 50;

pub fn main(init: std.process.Init) !void {
    // One short run: everything lives until exit.
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try Io.File.stdout().writeStreamingAll(io, config.usage);
            return;
        }
    }
    const cwd = try std.process.currentPathAlloc(io, arena);
    const cfg = config.parse(arena, args[1..], cwd) catch std.process.exit(2);

    const atlas = try buildAtlas(arena, io, &cfg);
    try writeOutputs(arena, io, &cfg, atlas);

    const counts = model.countBySeverity(atlas.findings);
    try Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(arena, "zigatlas: {d} files, {d} functions; {d} errors, {d} warnings, {d} notes → {s}/ATLAS.md\n", .{
        atlas.stats.files, atlas.stats.functions, counts[2], counts[1], counts[0], cfg.out_dir,
    }));
    if (cfg.check) |level| {
        if (!passesCheck(atlas.findings, level)) std.process.exit(1);
    }
}

/// Finds the files, scans them, and runs every check.
fn buildAtlas(arena: Allocator, io: Io, cfg: *const config.Config) !model.Atlas {
    const paths = try collectFiles(arena, io, cfg, cfg.roots, true);
    if (paths.len == 0) fatal("no .zig files under the roots", "");

    var b = scan.Builder.init(arena, cfg);
    var scanned: std.StringHashMapUnmanaged(void) = .empty;
    for (paths) |path| {
        try scanned.put(arena, path, {});
        const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(max_file_bytes), .of(u8), 0) catch |err| {
            std.debug.print("zigatlas: cannot read {s}: {t}\n", .{ path, err });
            continue;
        };
        try b.addFile(path, source);
    }
    // Uses of names in tests and tools count, so their callees aren't "unused".
    for (try collectFiles(arena, io, cfg, cfg.usage_roots, false)) |path| {
        if (scanned.contains(path)) continue;
        const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(max_file_bytes), .of(u8), 0) catch continue;
        try b.countUsage(source);
    }

    try b.resolveCalls();
    try checks.run(arena, cfg, b.files.items, b.functions.items, b.containers.items, &b.ident_counts, &b.findings);
    try clones.detect(arena, cfg, b.bodies.items, b.functions.items, &b.findings);
    checks.sortFindings(b.findings.items);

    return .{
        .layers = cfg.layers,
        .files = b.files.items,
        .functions = b.functions.items,
        .containers = b.containers.items,
        .findings = b.findings.items,
        .stats = .compute(b.files.items, b.functions.items, b.containers.items),
    };
}

fn writeOutputs(arena: Allocator, io: Io, cfg: *const config.Config, atlas: model.Atlas) !void {
    var out_dir = try Io.Dir.cwd().createDirPathOpen(io, cfg.out_dir, .{});
    defer out_dir.close(io);
    const outputs = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "ATLAS.md", .data = try render.overview(arena, cfg, atlas) },
        .{ .name = "api.md", .data = try render.api(arena, cfg, atlas) },
        .{ .name = "atlas.json", .data = try render.json(arena, atlas) },
        .{ .name = "deps.mmd", .data = try render.mermaid(arena, cfg, atlas) },
        .{ .name = "files.dot", .data = try render.dot(arena, atlas) },
    };
    for (outputs) |o| try out_dir.writeFile(io, .{ .sub_path = o.name, .data = o.data });
}

/// Prints the findings at `level` or above, so a failing CI log says what failed.
fn passesCheck(findings: []const model.Finding, level: model.Severity) bool {
    var failing: u32 = 0;
    for (findings) |f| {
        if (f.severity.rank() < level.rank()) continue;
        failing += 1;
        if (failing > max_check_lines) continue;
        const loc: model.Location = if (f.locations.len > 0) f.locations[0] else .{ .file = "?", .line = 0 };
        std.debug.print("{s}:{d}: {t}: {t}: {s}\n", .{ loc.file, loc.line, f.severity, f.kind, f.message });
    }
    if (failing == 0) return true;
    if (failing > max_check_lines) std.debug.print("… {d} more\n", .{failing - max_check_lines});
    std.debug.print("zigatlas: {d} findings at {t} or above\n", .{ failing, level });
    return false;
}

/// Every .zig file under `roots`, normalised, sorted and without duplicates.
/// A root that can't be opened is fatal when `required`.
fn collectFiles(arena: Allocator, io: Io, cfg: *const config.Config, roots: []const []const u8, required: bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                try out.append(arena, root);
                continue;
            },
            else => {
                if (required) fatal("cannot open root", root);
                continue;
            },
        };
        defer dir.close(io);
        try walkRoot(arena, io, cfg, dir, root, &out);
    }
    std.mem.sort([]const u8, out.items, {}, lessString);
    // Overlapping roots (`src` and `src/core`) find the same files twice.
    var unique: std.ArrayList([]const u8) = .empty;
    for (out.items) |path| {
        if (unique.items.len > 0 and std.mem.eql(u8, unique.items[unique.items.len - 1], path)) continue;
        try unique.append(arena, path);
    }
    return unique.items;
}

fn walkRoot(arena: Allocator, io: Io, cfg: *const config.Config, dir: Io.Dir, root: []const u8, out: *std.ArrayList([]const u8)) !void {
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.basename[0] == '.' or isSkipped(entry.basename)) walker.leave(io);
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fs.path.resolvePosix(arena, &.{ root, entry.path });
        std.mem.replaceScalar(u8, path, '\\', '/');
        if (isExcluded(cfg, path)) continue;
        try out.append(arena, path);
    }
}

fn fatal(what: []const u8, arg: []const u8) noreturn {
    std.debug.print("zigatlas: {s}{s}{s}\n", .{ what, if (arg.len > 0) ": " else "", arg });
    std.process.exit(2);
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isSkipped(name: []const u8) bool {
    for (skip_dirs) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn isExcluded(cfg: *const config.Config, path: []const u8) bool {
    for (cfg.exclude) |prefix| {
        if (config.pathHasPrefix(path, prefix)) return true;
    }
    return false;
}

test {
    _ = config;
    _ = scan;
    _ = clones;
    _ = checks;
    _ = render;
}
