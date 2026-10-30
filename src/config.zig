//! What to scan and which rules to hold the code to, parsed from the command
//! line. build.zig's `addAtlasStep` turns its Options into these arguments and
//! takes its defaults and its Layer and Rule types from here.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const Severity = model.Severity;

pub const Layer = model.Layer;

pub const Rule = struct {
    /// Layer name or path prefix.
    from: []const u8,
    to: []const u8,
    reason: []const u8 = "",
};

pub const Module = struct {
    /// The name in `@import("name")`.
    name: []const u8,
    /// The project file it resolves to.
    path: []const u8,
    /// Directory of the module that imports it under this name; empty means
    /// everywhere. Lets one name mean different files in different modules.
    scope: []const u8 = "",
};

pub const Config = struct {
    name: []const u8 = "project",
    roots: []const []const u8 = &.{},
    /// Extra places whose files are only searched for uses of names (tests,
    /// tools), so their calls count for `unused_pub`. Default: the whole cwd.
    usage_roots: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    /// Ordered top (front ends) to bottom (foundations): a layer may import
    /// itself and anything below it.
    layers: []const Layer = &.{},
    forbid: []const Rule = &.{},
    /// `@import("name")` targets that are project files.
    modules: []const Module = &.{},
    out_dir: []const u8 = "zig-out/atlas",
    min_clone_tokens: u32 = 60,
    min_fn_tokens: u32 = 40,
    max_fn_lines: u32 = 80,
    max_complexity: u32 = 20,
    max_params: u32 = 6,
    max_file_lines: u32 = 1000,
    thin_max_complexity: u32 = 10,
    /// Exit non-zero when a finding at or above this severity exists.
    check: ?Severity = null,

    pub fn layerIndex(cfg: Config, name: []const u8) ?usize {
        for (cfg.layers, 0..) |layer, i| {
            if (std.mem.eql(u8, layer.name, name)) return i;
        }
        return null;
    }

    /// The layer owning `path`: the one with the longest matching prefix.
    pub fn layerOf(cfg: Config, path: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_len: usize = 0;
        for (cfg.layers) |layer| {
            for (layer.paths) |prefix| {
                if (pathHasPrefix(path, prefix) and prefix.len >= best_len) {
                    best = layer.name;
                    best_len = prefix.len;
                }
            }
        }
        return best;
    }

    /// The file `@import(name)` means inside `importer`: the module with the
    /// longest scope containing the importer, else an unscoped one.
    pub fn moduleFor(cfg: Config, name: []const u8, importer: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_len: usize = 0;
        var found = false;
        for (cfg.modules) |m| {
            if (!std.mem.eql(u8, m.name, name)) continue;
            if (m.scope.len > 0 and !pathHasPrefix(importer, m.scope)) continue;
            if (!found or m.scope.len > best_len) {
                best = m.path;
                best_len = m.scope.len;
                found = true;
            }
        }
        return best;
    }
};

/// True when `path` is `prefix` itself or lies under the directory `prefix`.
pub fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
    if (!std.mem.startsWith(u8, path, p)) return false;
    return path.len == p.len or path[p.len] == '/';
}

/// The one spelling of a path zigatlas uses everywhere: relative to the cwd,
/// '/' separators, no `.` or `..` steps where they can be removed, no
/// trailing slash; the cwd itself is ".". Roots, scanned files, layers,
/// excludes, rules and modules all go through here so they compare equal.
pub fn normalizePath(arena: Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    const slashed = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, slashed, '\\', '/');
    const relative = if (std.fs.path.isAbsolutePosix(slashed))
        try std.fs.path.relativePosix(arena, cwd, cwd, slashed)
    else
        try std.fs.path.resolvePosix(arena, &.{slashed});
    return if (relative.len == 0) "." else relative;
}

const defaults: Config = .{};

pub const usage = std.fmt.comptimePrint(
    \\usage: zigatlas [options]
    \\
    \\  --name NAME              project name for the report
    \\  --root PATH              directory or file to scan (repeatable, default: src)
    \\  --usage-root PATH        only count uses of names here, e.g. tests (default: .)
    \\  --exclude PATH           path prefix to skip (repeatable)
    \\  --layer NAME=P1,P2       layer owning these paths; give layers top to bottom
    \\  --thin NAME              mark a layer as a thin front end
    \\  --forbid FROM:TO[:WHY]   forbid imports from a layer/path to another
    \\  --module NAME=PATH[@DIR] resolve @import("NAME") (inside DIR) to a project file
    \\  --out DIR                output directory (default: {s})
    \\  --min-clone-tokens N     shortest duplicated fragment reported ({d})
    \\  --min-fn-tokens N        smallest function compared as a whole ({d})
    \\  --max-fn-lines N         ({d})   --max-complexity N  ({d})
    \\  --max-params N           ({d})    --max-file-lines N  ({d})
    \\  --thin-max-complexity N  ({d})
    \\  --check [info|warn|error] exit 1 when findings at this severity exist (default: error)
    \\
, .{
    defaults.out_dir,        defaults.min_clone_tokens, defaults.min_fn_tokens,  defaults.max_fn_lines,
    defaults.max_complexity, defaults.max_params,       defaults.max_file_lines, defaults.thin_max_complexity,
});

pub const ParseError = error{InvalidArguments} || Allocator.Error;

/// Lists collected while parsing, turned into the Config's slices at the end.
const Lists = struct {
    roots: std.ArrayList([]const u8) = .empty,
    usage_roots: std.ArrayList([]const u8) = .empty,
    exclude: std.ArrayList([]const u8) = .empty,
    layers: std.ArrayList(Layer) = .empty,
    forbid: std.ArrayList(Rule) = .empty,
    modules: std.ArrayList(Module) = .empty,
    thin: std.ArrayList([]const u8) = .empty,
};

/// Parses the arguments; every path is normalised against `cwd`.
pub fn parse(arena: Allocator, args: []const []const u8, cwd: []const u8) ParseError!Config {
    var cfg: Config = .{};
    var lists: Lists = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            cfg.check = .@"error";
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                cfg.check = std.meta.stringToEnum(Severity, args[i]) orelse return fail("bad --check level", args[i]);
            }
            continue;
        }
        if (i + 1 >= args.len) return fail("missing value for", arg);
        i += 1;
        try parseOption(arena, cwd, &cfg, &lists, arg, args[i]);
    }

    for (lists.thin.items) |name| {
        var found = false;
        for (lists.layers.items) |*layer| {
            if (std.mem.eql(u8, layer.name, name)) {
                layer.thin = true;
                found = true;
            }
        }
        if (!found) return fail("--thin names an unknown layer", name);
    }
    if (lists.roots.items.len == 0) try lists.roots.append(arena, "src");
    if (lists.usage_roots.items.len == 0) try lists.usage_roots.append(arena, ".");
    if (cfg.min_clone_tokens < 10) cfg.min_clone_tokens = 10;

    cfg.roots = lists.roots.items;
    cfg.usage_roots = lists.usage_roots.items;
    cfg.exclude = lists.exclude.items;
    cfg.layers = lists.layers.items;
    cfg.forbid = lists.forbid.items;
    cfg.modules = lists.modules.items;
    for (cfg.forbid) |rule| {
        try checkSelector(cfg, rule.from);
        try checkSelector(cfg, rule.to);
    }
    return cfg;
}

fn parseOption(arena: Allocator, cwd: []const u8, cfg: *Config, lists: *Lists, arg: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, arg, "--name")) {
        cfg.name = value;
    } else if (std.mem.eql(u8, arg, "--root")) {
        try lists.roots.append(arena, try normalizePath(arena, cwd, value));
    } else if (std.mem.eql(u8, arg, "--usage-root")) {
        try lists.usage_roots.append(arena, try normalizePath(arena, cwd, value));
    } else if (std.mem.eql(u8, arg, "--exclude")) {
        try lists.exclude.append(arena, try normalizePath(arena, cwd, value));
    } else if (std.mem.eql(u8, arg, "--layer")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return fail("--layer wants NAME=PATHS", value);
        var paths: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, value[eq + 1 ..], ',');
        while (it.next()) |p| try paths.append(arena, try normalizePath(arena, cwd, p));
        try lists.layers.append(arena, .{ .name = value[0..eq], .paths = paths.items });
    } else if (std.mem.eql(u8, arg, "--thin")) {
        try lists.thin.append(arena, value);
    } else if (std.mem.eql(u8, arg, "--forbid")) {
        var it = std.mem.splitScalar(u8, value, ':');
        const from = it.next() orelse "";
        const to = it.next() orelse return fail("--forbid wants FROM:TO[:WHY]", value);
        try lists.forbid.append(arena, .{ .from = try selector(arena, cwd, from), .to = try selector(arena, cwd, to), .reason = it.rest() });
    } else if (std.mem.eql(u8, arg, "--module")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return fail("--module wants NAME=PATH[@DIR]", value);
        const rest = value[eq + 1 ..];
        const at = std.mem.lastIndexOfScalar(u8, rest, '@');
        try lists.modules.append(arena, .{
            .name = value[0..eq],
            .path = try normalizePath(arena, cwd, if (at) |a| rest[0..a] else rest),
            .scope = if (at) |a| try normalizePath(arena, cwd, rest[a + 1 ..]) else "",
        });
    } else if (std.mem.eql(u8, arg, "--out")) {
        cfg.out_dir = value;
    } else {
        const field = numberField(arg) orelse return fail("unknown option", arg);
        const n = std.fmt.parseInt(u32, value, 10) catch return fail("not a number", value);
        switch (field) {
            inline else => |f| @field(cfg, @tagName(f)) = n,
        }
    }
}

const NumberField = enum { min_clone_tokens, min_fn_tokens, max_fn_lines, max_complexity, max_params, max_file_lines, thin_max_complexity };

/// `--max-fn-lines` -> .max_fn_lines
fn numberField(arg: []const u8) ?NumberField {
    if (!std.mem.startsWith(u8, arg, "--")) return null;
    var buf: [32]u8 = undefined;
    if (arg.len - 2 > buf.len) return null;
    const name = buf[0 .. arg.len - 2];
    for (arg[2..], name) |c, *o| o.* = if (c == '-') '_' else c;
    return std.meta.stringToEnum(NumberField, name);
}

/// A rule side: a layer name stays as it is, a path is normalised.
fn selector(arena: Allocator, cwd: []const u8, s: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, s, "/\\.") == null) return s;
    return normalizePath(arena, cwd, s);
}

/// A rule side must name a layer or a path inside (or around) a root, so a
/// typo can't switch the rule off.
fn checkSelector(cfg: Config, s: []const u8) ParseError!void {
    if (cfg.layerIndex(s) != null) return;
    for (cfg.roots) |root| {
        if (pathHasPrefix(s, root) or pathHasPrefix(root, s)) return;
    }
    return fail("--forbid names neither a layer nor a path under a root", s);
}

fn fail(what: []const u8, arg: []const u8) ParseError {
    std.debug.print("zigatlas: {s}: {s}\n\n{s}", .{ what, arg, usage });
    return error.InvalidArguments;
}

test "parse layers, rules and thresholds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try parse(arena_state.allocator(), &.{
        "--root",                 "./src/",    "--layer",  "cli=src/main.zig",
        "--layer",                "fs=src/fs", "--layer",  "net=/proj/src/net,src/dht",
        "--thin",                 "cli",       "--forbid", "fs:net:go through cluster",
        "--max-params",           "4",         "--check",  "--module",
        "pkg=./src/root.zig@app",
    }, "/proj");
    try std.testing.expectEqualStrings("src", cfg.roots[0]);
    try std.testing.expectEqualStrings(".", cfg.usage_roots[0]);
    try std.testing.expectEqual(@as(usize, 3), cfg.layers.len);
    try std.testing.expectEqualStrings("src/net", cfg.layers[2].paths[0]);
    try std.testing.expect(cfg.layers[0].thin);
    try std.testing.expectEqualStrings("go through cluster", cfg.forbid[0].reason);
    try std.testing.expectEqual(@as(u32, 4), cfg.max_params);
    try std.testing.expectEqual(Severity.@"error", cfg.check.?);
    try std.testing.expectEqualStrings("net", cfg.layerOf("src/dht/kad.zig").?);
    try std.testing.expectEqualStrings("cli", cfg.layerOf("src/main.zig").?);
    try std.testing.expect(cfg.layerOf("src/mainly.zig") == null);
    try std.testing.expectEqualStrings("src/root.zig", cfg.moduleFor("pkg", "app/main.zig").?);
    try std.testing.expect(cfg.moduleFor("pkg", "src/x.zig") == null);
}

test "paths are spelled one way" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(".", try normalizePath(a, "/p", "."));
    try std.testing.expectEqualStrings(".", try normalizePath(a, "/p", "./"));
    try std.testing.expectEqualStrings(".", try normalizePath(a, "/p", "/p"));
    try std.testing.expectEqualStrings("src/a.zig", try normalizePath(a, "/p", "./src//a.zig"));
    try std.testing.expectEqualStrings("src/a.zig", try normalizePath(a, "/p", "/p/src/a.zig"));
    try std.testing.expectEqualStrings("src/a", try normalizePath(a, "/p", "src\\a\\"));
}

test "a misspelt rule is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidArguments, parse(arena_state.allocator(), &.{
        "--layer", "top=src/top", "--forbid", "botom:top",
    }, "/p"));
}
