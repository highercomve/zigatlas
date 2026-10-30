//! What to scan and which rules to hold the code to, parsed from the command
//! line. build.zig's `addAtlasStep` turns its Options into these arguments.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Severity = @import("model.zig").Severity;

pub const Layer = struct {
    name: []const u8,
    /// Path prefixes (directories or single files) that belong to the layer.
    paths: []const []const u8,
    /// Front ends: should only parse input and present output.
    thin: bool = false,
};

pub const Rule = struct {
    /// Layer name or path prefix.
    from: []const u8,
    to: []const u8,
    reason: []const u8 = "",
};

pub const Module = struct {
    name: []const u8,
    path: []const u8,
};

pub const Config = struct {
    name: []const u8 = "project",
    roots: []const []const u8 = &.{},
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
};

/// True when `path` is `prefix` itself or lies under the directory `prefix`.
pub fn pathHasPrefix(path: []const u8, prefix: []const u8) bool {
    const p = std.mem.trimEnd(u8, prefix, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
    if (!std.mem.startsWith(u8, path, p)) return false;
    return path.len == p.len or path[p.len] == '/';
}

pub const usage =
    \\usage: zigatlas [options]
    \\
    \\  --name NAME              project name for the report
    \\  --root PATH              directory or file to scan (repeatable, default: src)
    \\  --exclude PATH           path prefix to skip (repeatable)
    \\  --layer NAME=P1,P2       layer owning these paths; give layers top to bottom
    \\  --thin NAME              mark a layer as a thin front end
    \\  --forbid FROM:TO[:WHY]   forbid imports from a layer/path to another
    \\  --module NAME=PATH       resolve @import("NAME") to a project file
    \\  --out DIR                output directory (default: zig-out/atlas)
    \\  --min-clone-tokens N     shortest duplicated fragment reported (60)
    \\  --min-fn-tokens N        smallest function compared as a whole (40)
    \\  --max-fn-lines N         (80)   --max-complexity N  (20)
    \\  --max-params N           (6)    --max-file-lines N  (1000)
    \\  --thin-max-complexity N  (10)
    \\  --check [warn|error]     exit 1 when findings at this severity exist
    \\
;

pub const ParseError = error{InvalidArguments} || Allocator.Error;

pub fn parse(arena: Allocator, args: []const []const u8) ParseError!Config {
    var cfg: Config = .{};
    var roots: std.ArrayList([]const u8) = .empty;
    var exclude: std.ArrayList([]const u8) = .empty;
    var layers: std.ArrayList(Layer) = .empty;
    var forbid: std.ArrayList(Rule) = .empty;
    var modules: std.ArrayList(Module) = .empty;
    var thin: std.ArrayList([]const u8) = .empty;

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
        const value = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--name")) {
            cfg.name = value;
        } else if (std.mem.eql(u8, arg, "--root")) {
            try roots.append(arena, trimSlash(value));
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            try exclude.append(arena, trimSlash(value));
        } else if (std.mem.eql(u8, arg, "--layer")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return fail("--layer wants NAME=PATHS", value);
            var paths: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, value[eq + 1 ..], ',');
            while (it.next()) |p| try paths.append(arena, trimSlash(p));
            try layers.append(arena, .{ .name = value[0..eq], .paths = paths.items });
        } else if (std.mem.eql(u8, arg, "--thin")) {
            try thin.append(arena, value);
        } else if (std.mem.eql(u8, arg, "--forbid")) {
            var it = std.mem.splitScalar(u8, value, ':');
            const from = it.next() orelse "";
            const to = it.next() orelse return fail("--forbid wants FROM:TO[:WHY]", value);
            try forbid.append(arena, .{ .from = trimSlash(from), .to = trimSlash(to), .reason = it.rest() });
        } else if (std.mem.eql(u8, arg, "--module")) {
            const eq = std.mem.indexOfScalar(u8, value, '=') orelse return fail("--module wants NAME=PATH", value);
            try modules.append(arena, .{ .name = value[0..eq], .path = value[eq + 1 ..] });
        } else if (std.mem.eql(u8, arg, "--out")) {
            cfg.out_dir = value;
        } else if (std.mem.eql(u8, arg, "--min-clone-tokens")) {
            cfg.min_clone_tokens = try number(value);
        } else if (std.mem.eql(u8, arg, "--min-fn-tokens")) {
            cfg.min_fn_tokens = try number(value);
        } else if (std.mem.eql(u8, arg, "--max-fn-lines")) {
            cfg.max_fn_lines = try number(value);
        } else if (std.mem.eql(u8, arg, "--max-complexity")) {
            cfg.max_complexity = try number(value);
        } else if (std.mem.eql(u8, arg, "--max-params")) {
            cfg.max_params = try number(value);
        } else if (std.mem.eql(u8, arg, "--max-file-lines")) {
            cfg.max_file_lines = try number(value);
        } else if (std.mem.eql(u8, arg, "--thin-max-complexity")) {
            cfg.thin_max_complexity = try number(value);
        } else {
            return fail("unknown option", arg);
        }
    }

    for (thin.items) |name| {
        var found = false;
        for (layers.items) |*layer| {
            if (std.mem.eql(u8, layer.name, name)) {
                layer.thin = true;
                found = true;
            }
        }
        if (!found) return fail("--thin names an unknown layer", name);
    }
    if (roots.items.len == 0) try roots.append(arena, "src");
    if (cfg.min_clone_tokens < 10) cfg.min_clone_tokens = 10;

    cfg.roots = roots.items;
    cfg.exclude = exclude.items;
    cfg.layers = layers.items;
    cfg.forbid = forbid.items;
    cfg.modules = modules.items;
    return cfg;
}

fn trimSlash(s: []const u8) []const u8 {
    const t = if (std.mem.startsWith(u8, s, "./")) s[2..] else s;
    return std.mem.trimEnd(u8, t, "/");
}

fn number(s: []const u8) ParseError!u32 {
    return std.fmt.parseInt(u32, s, 10) catch fail("not a number", s);
}

fn fail(what: []const u8, arg: []const u8) ParseError {
    std.debug.print("zigatlas: {s}: {s}\n\n{s}", .{ what, arg, usage });
    return error.InvalidArguments;
}

test "parse layers, rules and thresholds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try parse(arena_state.allocator(), &.{
        "--root",       "src/",      "--layer",  "cli=src/main.zig",
        "--layer",      "fs=src/fs", "--layer",  "net=src/net,src/dht",
        "--thin",       "cli",       "--forbid", "fs:net:go through cluster",
        "--max-params", "4",         "--check",
    });
    try std.testing.expectEqualStrings("src", cfg.roots[0]);
    try std.testing.expectEqual(@as(usize, 3), cfg.layers.len);
    try std.testing.expect(cfg.layers[0].thin);
    try std.testing.expectEqualStrings("go through cluster", cfg.forbid[0].reason);
    try std.testing.expectEqual(@as(u32, 4), cfg.max_params);
    try std.testing.expectEqual(Severity.@"error", cfg.check.?);
    try std.testing.expectEqualStrings("net", cfg.layerOf("src/dht/kad.zig").?);
    try std.testing.expectEqualStrings("cli", cfg.layerOf("src/main.zig").?);
    try std.testing.expect(cfg.layerOf("src/mainly.zig") == null);
}
