//! Turns one Zig source file into atlas entries: its imports, types, functions
//! with their metrics and cross-file calls, and the normalized token streams
//! clone detection compares.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const model = @import("model.zig");
const Config = @import("config.zig").Config;

/// A function body as clone detection sees it: one hash per token, with local
/// names and literal values erased so renamed copies still match.
pub const Body = struct {
    function: u32,
    hashes: []const u64,
    lines: []const u32,
};

/// Collects every scanned file into shared lists.
pub const Builder = struct {
    arena: Allocator,
    cfg: *const Config,
    files: std.ArrayList(model.File) = .empty,
    functions: std.ArrayList(model.Function) = .empty,
    containers: std.ArrayList(model.Container) = .empty,
    findings: std.ArrayList(model.Finding) = .empty,
    bodies: std.ArrayList(Body) = .empty,
    /// How often each identifier appears across all files.
    ident_counts: std.StringHashMapUnmanaged(u32) = .empty,
    /// File-scope import aliases of each file, to follow re-exports.
    exports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Alias)) = .empty,

    pub fn init(arena: Allocator, cfg: *const Config) Builder {
        return .{ .arena = arena, .cfg = cfg };
    }

    pub fn addFile(b: *Builder, path: []const u8, source: [:0]const u8) !void {
        var tree = try Ast.parse(b.arena, source, .zig);
        var s: FileScan = .{
            .b = b,
            .tree = &tree,
            .path = path,
            .dir = std.fs.path.dirnamePosix(path) orelse ".",
            .line_starts = try lineStarts(b.arena, source),
        };
        try s.run();
    }

    /// Rewrites calls made through re-exports (`pkg.settings.cacheInfo(` with
    /// `pub const settings = @import("settings.zig")` in pkg's root) to the
    /// file that defines the function. Call after every file is added.
    pub fn resolveCalls(b: *Builder) !void {
        for (b.functions.items) |*f| {
            for (f.calls) |*call| call.* = try b.resolveCall(call.*);
        }
    }

    fn resolveCall(b: *Builder, call: []const u8) ![]const u8 {
        const colon = std.mem.indexOfScalar(u8, call, ':') orelse return call;
        var file = call[0..colon];
        var path = call[colon + 1 ..];
        var hops: u32 = 0;
        while (hops < 8) : (hops += 1) {
            const exports = b.exports.get(file) orelse break;
            const dot = std.mem.indexOfScalar(u8, path, '.') orelse break;
            const alias = exports.get(path[0..dot]) orelse break;
            if (!alias.is_project) break;
            file = alias.file;
            path = if (alias.member.len == 0)
                path[dot + 1 ..]
            else
                try std.fmt.allocPrint(b.arena, "{s}{s}", .{ alias.member, path[dot..] });
        }
        if (hops == 0) return call;
        return std.fmt.allocPrint(b.arena, "{s}:{s}", .{ file, path });
    }
};

const Alias = struct {
    /// Project file path, or the bare `@import` name for packages.
    file: []const u8,
    is_project: bool,
    /// Dotted path inside that file, e.g. `Node` for `@import("root.zig").Node`.
    member: []const u8,
};

const PendingFn = struct {
    node: Node.Index,
    owner: []const u8,
    /// `@atlas allow` on an enclosing type covers its members.
    allowed: ?[]const u8,
};

const FileScan = struct {
    b: *Builder,
    tree: *const Ast,
    path: []const u8,
    dir: []const u8,
    line_starts: []const u32,
    aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    file_aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    pending: std.ArrayList(PendingFn) = .empty,
    imports: std.ArrayList(model.Import) = .empty,
    tests: u32 = 0,
    /// Token ranges of test blocks, ignored by import and clone scanning.
    test_ranges: std.ArrayList([2]TokenIndex) = .empty,

    fn run(s: *FileScan) !void {
        const b = s.b;
        const tree = s.tree;

        try s.walkMembers(tree.rootDecls(), "", null);
        try s.collectImports();
        for (s.pending.items) |p| try s.addFunction(p);
        try s.countIdents();
        try b.exports.put(b.arena, s.path, s.file_aliases);

        const layer = s.annotation(0, std.math.maxInt(u32), "layer") orelse b.cfg.layerOf(s.path);
        try b.files.append(b.arena, .{
            .path = s.path,
            .dir = s.dir,
            .layer = layer,
            .doc = s.fileDoc(),
            .lines = @intCast(s.line_starts.len),
            .tests = s.tests,
            .imports = s.imports.items,
            .parse_errors = @intCast(tree.errors.len),
        });
    }

    // ---- declarations -------------------------------------------------

    fn walkMembers(s: *FileScan, members: []const Node.Index, owner: []const u8, allowed: ?[]const u8) Allocator.Error!void {
        const tree = s.tree;
        const arena = s.b.arena;
        for (members) |member| {
            switch (tree.nodeTag(member)) {
                .fn_decl => try s.pending.append(arena, .{ .node = member, .owner = owner, .allowed = allowed }),
                .test_decl => {
                    s.tests += 1;
                    try s.test_ranges.append(arena, .{ tree.firstToken(member), tree.lastToken(member) });
                },
                .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => try s.varDecl(member, owner, allowed),
                else => {},
            }
        }
    }

    fn varDecl(s: *FileScan, node: Node.Index, owner: []const u8, owner_allowed: ?[]const u8) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        const decl = tree.fullVarDecl(node) orelse return;
        const init_node = decl.ast.init_node.unwrap() orelse return;
        const name = tree.tokenSlice(decl.ast.mut_token + 1);

        if (try s.aliasOf(init_node)) |alias| {
            try s.aliases.put(arena, name, alias);
            if (owner.len == 0) try s.file_aliases.put(arena, name, alias);
            return;
        }

        var buf: [2]Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, init_node) orelse return;
        const qualified = if (owner.len == 0) name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ owner, name });

        var fields: std.ArrayList(model.Field) = .empty;
        var methods: u32 = 0;
        for (container.ast.members) |m| {
            if (tree.nodeTag(m) == .fn_decl) methods += 1;
            const field = tree.fullContainerField(m) orelse continue;
            const type_text = if (field.ast.type_expr.unwrap()) |t| try collapse(arena, tree.getNodeSource(t), 80) else "";
            try fields.append(arena, .{ .name = tree.tokenSlice(field.ast.main_token), .type = type_text });
        }

        const first = tree.firstToken(node);
        const allowed = s.annotation(s.lineOf(first), s.lineOf(first), "allow") orelse owner_allowed;
        try s.b.containers.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.path, qualified }),
            .name = qualified,
            .kind = kindName(tree.tokenTag(container.ast.main_token)),
            .file = s.path,
            .line = s.lineOf(first),
            .is_pub = decl.visib_token != null,
            .doc = try s.docBefore(first),
            .fields = fields.items,
            .methods = methods,
            .allowed = allowed,
        });
        try s.walkMembers(container.ast.members, qualified, allowed);
    }

    /// `@import("x")`, `@import("x").A.B` or `alias.A.B` where `alias` is
    /// already known: the declaration is another name for something imported.
    fn aliasOf(s: *FileScan, init_node: Node.Index) !?Alias {
        const tree = s.tree;
        const first = tree.firstToken(init_node);
        const last = tree.lastToken(init_node);
        var base: Alias = undefined;
        var t: TokenIndex = first;

        if (tree.tokenTag(t) == .builtin and std.mem.eql(u8, tree.tokenSlice(t), "@import")) {
            if (t + 3 > last or tree.tokenTag(t + 2) != .string_literal) return null;
            base = try s.resolveImport(stringValue(tree.tokenSlice(t + 2)));
            t += 3; // at ')'
        } else if (tree.tokenTag(t) == .identifier) {
            base = s.aliases.get(tree.tokenSlice(t)) orelse return null;
        } else return null;

        var member: std.ArrayList(u8) = .empty;
        try member.appendSlice(s.b.arena, base.member);
        while (t < last) {
            if (tree.tokenTag(t + 1) != .period or t + 2 > last or tree.tokenTag(t + 2) != .identifier) return null;
            if (member.items.len > 0) try member.append(s.b.arena, '.');
            try member.appendSlice(s.b.arena, tree.tokenSlice(t + 2));
            t += 2;
        }
        base.member = member.items;
        return base;
    }

    fn resolveImport(s: *FileScan, target: []const u8) !Alias {
        for (s.b.cfg.modules) |m| {
            if (std.mem.eql(u8, m.name, target)) return .{ .file = m.path, .is_project = true, .member = "" };
        }
        if (!std.mem.endsWith(u8, target, ".zig") and !std.mem.endsWith(u8, target, ".zon")) {
            return .{ .file = target, .is_project = false, .member = "" };
        }
        const joined = try std.fs.path.resolvePosix(s.b.arena, &.{ s.dir, target });
        return .{ .file = joined, .is_project = true, .member = "" };
    }

    /// Every `@import("...")` outside test blocks, with the name it is bound to.
    fn collectImports(s: *FileScan) !void {
        const tree = s.tree;
        const tags = tree.tokens.items(.tag);
        var i: TokenIndex = 0;
        while (i + 2 < tags.len) : (i += 1) {
            if (tags[i] != .builtin or !std.mem.eql(u8, tree.tokenSlice(i), "@import")) continue;
            if (tags[i + 2] != .string_literal or s.inTest(i)) continue;
            const target = stringValue(tree.tokenSlice(i + 2));
            const resolved = try s.resolveImport(target);
            const alias = if (i >= 3 and tags[i - 1] == .equal and tags[i - 2] == .identifier) tree.tokenSlice(i - 2) else "";
            const line = s.lineOf(i);
            try s.imports.append(s.b.arena, .{
                .alias = alias,
                .target = target,
                .resolved = if (resolved.is_project) resolved.file else null,
                .line = line,
                .allowed = s.annotation(line, line, "allow"),
            });
        }
    }

    // ---- functions ----------------------------------------------------

    fn addFunction(s: *FileScan, p: PendingFn) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        var buf: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, p.node) orelse return;
        const name_tok = proto.name_token orelse return;
        const name = tree.tokenSlice(name_tok);
        const body = tree.nodeData(p.node).node_and_node[1];

        const first = tree.firstToken(p.node);
        const body_first = tree.firstToken(body);
        const body_last = tree.lastToken(body);
        const line = s.lineOf(first);
        const end_line = s.lineOf(body_last);

        var params: u32 = 0;
        var it = proto.iterate(tree);
        while (it.next()) |_| params += 1;

        const m = s.metrics(body_first, body_last);
        const index: u32 = @intCast(s.b.functions.items.len);
        const qualified = if (p.owner.len == 0) name else try std.fmt.allocPrint(arena, "{s}.{s}", .{ p.owner, name });

        try s.b.functions.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.path, qualified }),
            .name = name,
            .owner = p.owner,
            .file = s.path,
            .line = line,
            .end_line = end_line,
            .lines = end_line - line + 1,
            .params = params,
            .complexity = m.complexity,
            .depth = m.depth,
            .is_pub = proto.visib_token != null,
            .is_export = if (proto.extern_export_inline_token) |t| tree.tokenTag(t) == .keyword_export else false,
            .signature = try collapse(arena, s.sourceBetween(first, tree.lastToken(proto.ast.proto_node)), 200),
            .doc = try s.docBefore(first),
            .tokens = body_last - body_first + 1,
            .calls = try s.calls(body_first, body_last),
            .allowed = s.annotation(line, line, "allow") orelse p.allowed,
        });
        try s.addBody(index, body_first, body_last);
    }

    const Metrics = struct { complexity: u32, depth: u32 };

    fn metrics(s: *FileScan, first: TokenIndex, last: TokenIndex) Metrics {
        const tags = s.tree.tokens.items(.tag);
        var m: Metrics = .{ .complexity = 1, .depth = 0 };
        var depth: u32 = 0;
        var switches: u32 = 0;
        var prongs: u32 = 0;
        for (tags[first .. last + 1]) |tag| {
            switch (tag) {
                .keyword_if, .keyword_while, .keyword_for, .keyword_catch, .keyword_orelse, .keyword_and, .keyword_or => m.complexity += 1,
                .keyword_switch => switches += 1,
                .equal_angle_bracket_right => prongs += 1,
                .l_brace => {
                    depth += 1;
                    m.depth = @max(m.depth, depth);
                },
                .r_brace => depth -|= 1,
                else => {},
            }
        }
        m.complexity += prongs -| switches;
        // The body's own braces are not nesting.
        m.depth -|= 1;
        return m;
    }

    /// Calls through import aliases: `alias.f(` or `alias.Type.f(`.
    fn calls(s: *FileScan, first: TokenIndex, last: TokenIndex) ![][]const u8 {
        const tree = s.tree;
        const arena = s.b.arena;
        const tags = tree.tokens.items(.tag);
        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var i = first;
        while (i <= last) : (i += 1) {
            if (tags[i] != .identifier or (i > 0 and tags[i - 1] == .period)) continue;
            const alias = s.aliases.get(tree.tokenSlice(i)) orelse continue;
            if (!alias.is_project) continue;

            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(arena, alias.member);
            var j = i;
            while (j + 2 <= last and tags[j + 1] == .period and tags[j + 2] == .identifier) : (j += 2) {
                if (path.items.len > 0) try path.append(arena, '.');
                try path.appendSlice(arena, tree.tokenSlice(j + 2));
            }
            if (j + 1 > last or tags[j + 1] != .l_paren or path.items.len == 0) continue;
            const target = try std.fmt.allocPrint(arena, "{s}:{s}", .{ alias.file, path.items });
            const gop = try seen.getOrPut(arena, target);
            if (!gop.found_existing) try out.append(arena, target);
            i = j;
        }
        return out.items;
    }

    fn addBody(s: *FileScan, function: u32, first: TokenIndex, last: TokenIndex) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        const tags = tree.tokens.items(.tag);
        var hashes: std.ArrayList(u64) = .empty;
        var lines: std.ArrayList(u32) = .empty;
        var i = first;
        while (i <= last) : (i += 1) {
            const h: u64 = switch (tags[i]) {
                .doc_comment, .container_doc_comment => continue,
                // Names after a dot (fields, methods, enum tags) carry meaning; local names do not.
                .identifier => if (i > 0 and tags[i - 1] == .period) textHash(tree.tokenSlice(i)) else 0x1d,
                .builtin => textHash(tree.tokenSlice(i)),
                .number_literal => 0x2d,
                .string_literal, .multiline_string_literal_line => 0x3d,
                .char_literal => 0x4d,
                else => @as(u64, @intFromEnum(tags[i])) + 0x100,
            };
            try hashes.append(arena, h);
            try lines.append(arena, s.lineOf(i));
        }
        try s.b.bodies.append(arena, .{ .function = function, .hashes = hashes.items, .lines = lines.items });
    }

    fn countIdents(s: *FileScan) !void {
        const tree = s.tree;
        const tags = tree.tokens.items(.tag);
        for (tags, 0..) |tag, i| {
            if (tag != .identifier) continue;
            const gop = try s.b.ident_counts.getOrPut(s.b.arena, tree.tokenSlice(@intCast(i)));
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }

    // ---- comments and annotations ---------------------------------------

    /// First line of the `//!` comment at the top of the file, skipping annotations.
    fn fileDoc(s: *FileScan) []const u8 {
        const tree = s.tree;
        const tags = tree.tokens.items(.tag);
        for (tags, 0..) |tag, i| {
            if (tag != .container_doc_comment) break;
            const text = std.mem.trim(u8, tree.tokenSlice(@intCast(i))[3..], " \t\r");
            if (text.len > 0 and std.mem.indexOf(u8, text, "@atlas") == null) return text;
        }
        return "";
    }

    /// First line of the `///` comment above a declaration.
    fn docBefore(s: *FileScan, first: TokenIndex) ![]const u8 {
        const tree = s.tree;
        var t = first;
        while (t > 0 and tree.tokenTag(t - 1) == .doc_comment) t -= 1;
        while (t < first) : (t += 1) {
            const text = std.mem.trim(u8, tree.tokenSlice(t)[3..], " \t\r");
            if (text.len > 0 and std.mem.indexOf(u8, text, "@atlas") == null) return collapse(s.b.arena, text, 160);
        }
        return "";
    }

    /// Value of `@atlas <key> <value>` in a comment on lines [from, to] or in
    /// the comment block right above `from`. Lines are 1-based; a range past
    /// the end means the whole file's `//!` header.
    fn annotation(s: *FileScan, from: u32, to: u32, key: []const u8) ?[]const u8 {
        const whole = to == std.math.maxInt(u32);
        var line: u32 = if (whole) 1 else from;
        // Walk up through the comment block directly above the declaration.
        if (!whole) {
            while (line > 1 and isComment(s.lineText(line - 1))) line -= 1;
        }
        const last = if (whole) @as(u32, @intCast(s.line_starts.len)) else to;
        while (line <= last) : (line += 1) {
            const text = s.lineText(line);
            if (whole and !std.mem.startsWith(u8, std.mem.trimStart(u8, text, " \t"), "//!")) continue;
            const comment = std.mem.indexOf(u8, text, "//") orelse continue;
            const at = std.mem.indexOfPos(u8, text, comment, "@atlas") orelse continue;
            var rest = std.mem.trimStart(u8, text[at + "@atlas".len ..], " \t");
            if (!std.mem.startsWith(u8, rest, key)) continue;
            rest = std.mem.trim(u8, rest[key.len..], " \t\r:");
            return if (rest.len == 0) "annotated" else rest;
        }
        return null;
    }

    fn lineText(s: *FileScan, line: u32) []const u8 {
        const src = s.tree.source;
        const start = s.line_starts[line - 1];
        const end = if (line < s.line_starts.len) s.line_starts[line] else @as(u32, @intCast(src.len));
        return std.mem.trimEnd(u8, src[start..end], "\r\n");
    }

    // ---- helpers ----------------------------------------------------------

    fn inTest(s: *FileScan, t: TokenIndex) bool {
        for (s.test_ranges.items) |r| {
            if (t >= r[0] and t <= r[1]) return true;
        }
        return false;
    }

    /// 1-based line of a token.
    fn lineOf(s: *FileScan, t: TokenIndex) u32 {
        const offset = s.tree.tokenStart(t);
        const idx = std.sort.upperBound(u32, s.line_starts, offset, orderU32);
        return @intCast(idx);
    }

    fn sourceBetween(s: *FileScan, first: TokenIndex, last: TokenIndex) []const u8 {
        const tree = s.tree;
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        return tree.source[start..end];
    }
};

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "//");
}

fn kindName(tag: std.zig.Token.Tag) []const u8 {
    return switch (tag) {
        .keyword_enum => "enum",
        .keyword_union => "union",
        .keyword_opaque => "opaque",
        else => "struct",
    };
}

fn lineStarts(arena: Allocator, source: []const u8) ![]const u32 {
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(arena, 0);
    for (source, 0..) |c, i| {
        if (c == '\n' and i + 1 < source.len) try starts.append(arena, @intCast(i + 1));
    }
    return starts.items;
}

fn textHash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0x9e3779b97f4a7c15, text);
}

fn stringValue(literal: []const u8) []const u8 {
    if (literal.len >= 2 and literal[0] == '"') return literal[1 .. literal.len - 1];
    return literal;
}

/// Collapses runs of whitespace to one space and caps the length.
pub fn collapse(arena: Allocator, text: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len > 0;
            continue;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        try out.append(arena, c);
        if (out.items.len >= max) {
            try out.appendSlice(arena, "…");
            break;
        }
    }
    return out.items;
}

test "calls through a package root's re-exports reach the defining file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .modules = &.{.{ .name = "pkg", .path = "src/root.zig" }} };
    var b = Builder.init(arena_state.allocator(), &cfg);
    try b.addFile("src/root.zig", "pub const settings = @import(\"core/settings.zig\");\n");
    try b.addFile("src/core/settings.zig", "pub fn cacheInfo() void {}\n");
    try b.addFile("app/main.zig",
        \\const pkg = @import("pkg");
        \\pub export fn info() void {
        \\    pkg.settings.cacheInfo();
        \\}
    );
    try b.resolveCalls();
    const info = b.functions.items[1];
    try std.testing.expect(info.is_export);
    try std.testing.expectEqualStrings("src/core/settings.zig:cacheInfo", info.calls[0]);
}

test "scan a file: imports, aliases, types, functions, calls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg: Config = .{ .layers = &.{.{ .name = "core", .paths = &.{"src/core"} }} };
    var b = Builder.init(arena, &cfg);
    try b.addFile("src/core/a.zig",
        \\//! Core things.
        \\const std = @import("std");
        \\const net = @import("../net/mod.zig");
        \\const Peer = net.Peer;
        \\
        \\/// A thing with fields.
        \\/// @atlas allow: called by name
        \\pub const Thing = struct {
        \\    id: u64,
        \\    name: []const u8,
        \\
        \\    pub fn send(self: Thing, x: u32) !void {
        \\        if (x > 3 and self.id != 0) try net.transport.send(x);
        \\        _ = Peer.connect(self.name);
        \\    }
        \\};
        \\
        \\// @atlas allow: kept for the bench
        \\fn helper(a: u8, b: u8) u8 {
        \\    return switch (a) { 0 => b, 1 => a, else => 0 };
        \\}
        \\
        \\test "x" {
        \\    _ = @import("../net/test_only.zig");
        \\}
        \\
    );
    const file = b.files.items[0];
    try std.testing.expectEqualStrings("Core things.", file.doc);
    try std.testing.expectEqualStrings("core", file.layer.?);
    try std.testing.expectEqual(@as(usize, 2), file.imports.len);
    try std.testing.expectEqualStrings("src/net/mod.zig", file.imports[1].resolved.?);
    try std.testing.expectEqual(@as(u32, 1), file.tests);

    try std.testing.expectEqual(@as(usize, 1), b.containers.items.len);
    const thing = b.containers.items[0];
    try std.testing.expectEqualStrings("Thing", thing.name);
    try std.testing.expectEqualStrings("A thing with fields.", thing.doc);
    try std.testing.expectEqual(@as(usize, 2), thing.fields.len);

    try std.testing.expectEqual(@as(usize, 2), b.functions.items.len);
    const send = b.functions.items[0];
    try std.testing.expectEqualStrings("src/core/a.zig:Thing.send", send.id);
    try std.testing.expectEqual(@as(u32, 2), send.params);
    try std.testing.expectEqualStrings("called by name", send.allowed.?);
    try std.testing.expectEqual(@as(u32, 3), send.complexity);
    try std.testing.expectEqual(@as(usize, 2), send.calls.len);
    try std.testing.expectEqualStrings("src/net/mod.zig:transport.send", send.calls[0]);
    try std.testing.expectEqualStrings("src/net/mod.zig:Peer.connect", send.calls[1]);

    const helper = b.functions.items[1];
    try std.testing.expect(!helper.is_pub);
    try std.testing.expectEqual(@as(u32, 3), helper.complexity);
    try std.testing.expectEqualStrings("kept for the bench", helper.allowed.?);
}
