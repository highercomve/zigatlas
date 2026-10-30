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

/// Files nested deeper than this are reported, not parsed: std's parser
/// recurses per level and overflows the stack in the low thousands.
const max_nesting = 200;
/// Containers walked deeper than this are skipped (real code stays far below).
const max_container_depth = 64;
/// Re-export hops followed for one call before giving up on it.
const max_reexport_hops = 8;
/// Passes over a file's declarations to resolve aliases defined out of order.
const max_alias_rounds = 8;
/// Longest text kept for a doc line, a signature and a field type.
const doc_max = 160;
const signature_max = 200;
const field_type_max = 80;

/// A function body as clone detection sees it: one hash per token, with local
/// names and literal values erased so renamed copies still match. Names of
/// file-scope functions, constants, imports and primitive types are kept, so
/// code that calls different functions is not "the same"; type names are
/// erased, so the same logic written for two types still matches.
pub const Body = struct {
    function: u32,
    hashes: []const u64,
    lines: []const u32,
};

/// What the whole project does with names: how often each identifier
/// appears, and which names are handed around as bare values (`App(Commands)`,
/// `.commands = Commands`), which for a namespace means its declarations are
/// reached by reflection.
pub const Names = struct {
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    bare: std.StringHashMapUnmanaged(void) = .empty,
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
    names: Names = .{},
    /// File-scope import aliases of each file, to follow re-exports.
    exports: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Alias)) = .empty,

    pub fn init(arena: Allocator, cfg: *const Config) Builder {
        return .{ .arena = arena, .cfg = cfg };
    }

    pub fn addFile(b: *Builder, path: []const u8, source: [:0]const u8) !void {
        const line_starts = try lineStarts(b.arena, source);
        const lines: u32 = if (source.len == 0) 0 else @intCast(line_starts.len);
        const dir = std.fs.path.dirnamePosix(path) orelse ".";

        if (tooDeep(source)) |line| {
            try b.files.append(b.arena, .{
                .path = path,
                .dir = dir,
                .layer = b.cfg.layerOf(path),
                .lines = lines,
                .parse_errors = 1,
                .parse_error_line = line,
                .parse_note = "nested more than 200 levels deep; not analysed",
            });
            return;
        }

        // The tree and per-file tables live only while the file is scanned.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const tree = try Ast.parse(scratch.allocator(), source, .zig);
        var s: FileScan = .{
            .b = b,
            .tmp = scratch.allocator(),
            .tree = &tree,
            .path = path,
            .dir = dir,
            .line_starts = line_starts,
            .lines = lines,
        };
        try s.run();
    }

    /// Counts the identifiers of a file that is not scanned (tests, tools), so
    /// a public function used only there is not reported as unused.
    pub fn countUsage(b: *Builder, source: [:0]const u8) !void {
        var tokenizer = std.zig.Tokenizer.init(source);
        var prev: std.zig.Token.Tag = .invalid;
        var pending: ?std.zig.Token = null;
        var before_pending: std.zig.Token.Tag = .invalid;
        while (true) {
            const tok = tokenizer.next();
            if (pending) |p| try b.noteIdent(identText(source[p.loc.start..p.loc.end]), before_pending, tok.tag);
            pending = null;
            if (tok.tag == .eof) break;
            if (tok.tag == .identifier) {
                pending = tok;
                before_pending = prev;
            }
            prev = tok.tag;
        }
    }

    /// Counts one identifier, and records it as a bare value when it is not
    /// being declared, accessed (`name.x`) or called (`name(`).
    fn noteIdent(b: *Builder, name: []const u8, prev: std.zig.Token.Tag, next: std.zig.Token.Tag) !void {
        const gop = try b.names.counts.getOrPut(b.arena, name);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        const declared = prev == .keyword_const or prev == .keyword_var or prev == .keyword_fn;
        if (!declared and next != .period and next != .l_paren) try b.names.bare.put(b.arena, name, {});
    }

    /// Rewrites calls made through re-exports (`pkg.settings.cacheInfo(` with
    /// `pub const settings = @import("settings.zig")` in pkg's root) to the
    /// file that defines the function. Call after every file is added.
    pub fn resolveCalls(b: *Builder) !void {
        for (b.functions.items) |*f| {
            var out: std.ArrayList([]const u8) = .empty;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (f.calls) |call| {
                const resolved = try b.resolveCall(call);
                const gop = try seen.getOrPut(b.arena, resolved);
                if (!gop.found_existing) try out.append(b.arena, resolved);
            }
            f.calls = out.items;
        }
    }

    fn resolveCall(b: *Builder, call: []const u8) ![]const u8 {
        const colon = std.mem.indexOfScalar(u8, call, ':') orelse return call;
        var file = call[0..colon];
        var path = call[colon + 1 ..];
        var hops: u32 = 0;
        while (true) : (hops += 1) {
            const exports = b.exports.get(file) orelse break;
            const dot = std.mem.indexOfScalar(u8, path, '.') orelse break;
            const alias = exports.get(path[0..dot]) orelse break;
            if (!alias.is_project) break;
            // A re-export loop: keep what the source said.
            if (hops == max_reexport_hops) return call;
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
    /// Tokens of a generic type's returned struct, measured as that type.
    exclude: ?[2]TokenIndex = null,
};

const PendingVar = struct {
    node: Node.Index,
    owner: []const u8,
    done: bool = false,
};

const FileScan = struct {
    b: *Builder,
    /// Per-file scratch, freed after the file.
    tmp: Allocator,
    tree: *const Ast,
    path: []const u8,
    dir: []const u8,
    line_starts: []const u32,
    lines: u32,
    /// Aliases keyed by "owner\x00name": visible in that container and below.
    aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    file_aliases: std.StringHashMapUnmanaged(Alias) = .empty,
    /// Names declared at file scope; clone hashes keep them.
    file_names: std.StringHashMapUnmanaged(void) = .empty,
    pending: std.ArrayList(PendingFn) = .empty,
    vars: std.ArrayList(PendingVar) = .empty,
    imports: std.ArrayList(model.Import) = .empty,
    tests: u32 = 0,
    /// Token ranges of test blocks, ignored by import and clone scanning.
    test_ranges: std.ArrayList([2]TokenIndex) = .empty,
    /// Per line (1-based), the `@atlas allow` reason on it or in the comment block above it.
    allow_at: []?[]const u8 = &.{},

    fn run(s: *FileScan) !void {
        const b = s.b;
        const tree = s.tree;

        try s.indexAllows();
        try s.walkMembers(tree.rootDecls(), "", null, 0);
        try s.resolveAliases();
        std.mem.sort([2]TokenIndex, s.test_ranges.items, {}, rangeLess);
        try s.collectImports();
        for (s.pending.items) |p| try s.addFunction(p);
        try s.countIdents();
        try b.exports.put(b.arena, s.path, s.file_aliases);

        var layer = b.cfg.layerOf(s.path);
        if (s.headerAnnotation("layer")) |named| {
            if (b.cfg.layerIndex(named) != null) {
                layer = named;
            } else try s.unknownLayer(named);
        }
        const first_error: u32 = if (tree.errors.len > 0) s.lineOf(tree.errors[0].token) else 0;
        try b.files.append(b.arena, .{
            .path = s.path,
            .dir = s.dir,
            .layer = layer,
            .doc = try s.fileDoc(),
            .lines = s.lines,
            .tests = s.tests,
            .imports = s.imports.items,
            .parse_errors = @intCast(tree.errors.len),
            .parse_error_line = first_error,
            .allowed = s.headerAnnotation("allow"),
        });
    }

    fn unknownLayer(s: *FileScan, named: []const u8) !void {
        const arena = s.b.arena;
        const locs = try arena.alloc(model.Location, 1);
        locs[0] = .{ .file = s.path, .line = 1 };
        try s.b.findings.append(arena, .{
            .kind = .unknown_layer,
            .severity = .@"error",
            .message = try std.fmt.allocPrint(arena, "@atlas layer names \"{s}\", which is not a configured layer; the file falls back to its path's layer", .{named}),
            .locations = locs,
        });
    }

    // ---- declarations -------------------------------------------------

    fn walkMembers(s: *FileScan, members: []const Node.Index, owner: []const u8, allowed: ?[]const u8, depth: u32) Allocator.Error!void {
        if (depth > max_container_depth) return;
        const tree = s.tree;
        for (members) |member| {
            switch (tree.nodeTag(member)) {
                .fn_decl => try s.fnDecl(member, owner, allowed, depth),
                .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto => try s.externFn(member, owner, allowed),
                .test_decl => {
                    s.tests += 1;
                    try s.test_ranges.append(s.tmp, .{ tree.firstToken(member), tree.lastToken(member) });
                },
                .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => try s.varDecl(member, owner, allowed, depth),
                else => {},
            }
        }
    }

    fn fnDecl(s: *FileScan, node: Node.Index, owner: []const u8, allowed: ?[]const u8, depth: u32) !void {
        const tree = s.tree;
        var buf: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse return;
        const name_tok = proto.name_token orelse return;
        if (owner.len == 0) try s.file_names.put(s.tmp, identName(tree, name_tok), {});

        var pending: PendingFn = .{ .node = node, .owner = owner, .allowed = s.allowAt(s.lineOf(tree.firstToken(node))) orelse allowed };
        // `fn List(comptime T: type) type { return struct { ... }; }`: the
        // struct is a type of its own, named after the function.
        if (returnedContainer(tree, node)) |container_node| {
            const qualified = try s.qualify(owner, identName(tree, name_tok));
            var cbuf: [2]Node.Index = undefined;
            const container = tree.fullContainerDecl(&cbuf, container_node).?;
            try s.addContainer(container, node, qualified, proto.visib_token != null, pending.allowed);
            try s.walkMembers(container.ast.members, qualified, pending.allowed, depth + 1);
            pending.exclude = .{ tree.firstToken(container_node), tree.lastToken(container_node) };
        }
        try s.pending.append(s.tmp, pending);
    }

    fn varDecl(s: *FileScan, node: Node.Index, owner: []const u8, allowed: ?[]const u8, depth: u32) !void {
        const tree = s.tree;
        const decl = tree.fullVarDecl(node) orelse return;
        const name = identName(tree, decl.ast.mut_token + 1);
        const init_node = decl.ast.init_node.unwrap() orelse return;

        var buf: [2]Node.Index = undefined;
        const container = tree.fullContainerDecl(&buf, init_node) orelse {
            // Constants and imports keep their name in clone hashes; type
            // names don't, so the same logic on two types still matches.
            if (owner.len == 0) try s.file_names.put(s.tmp, name, {});
            // Maybe an alias; resolved once every declaration is known.
            try s.vars.append(s.tmp, .{ .node = node, .owner = owner });
            return;
        };
        const qualified = try s.qualify(owner, name);
        const container_allowed = s.allowAt(s.lineOf(tree.firstToken(node))) orelse allowed;
        try s.addContainer(container, node, qualified, decl.visib_token != null, container_allowed);
        try s.walkMembers(container.ast.members, qualified, container_allowed, depth + 1);
    }

    fn addContainer(s: *FileScan, container: Ast.full.ContainerDecl, decl_node: Node.Index, qualified: []const u8, is_pub: bool, allowed: ?[]const u8) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        var fields: std.ArrayList(model.Field) = .empty;
        var methods: u32 = 0;
        var tuple = false;
        for (container.ast.members) |m| {
            if (tree.nodeTag(m) == .fn_decl) methods += 1;
            const field = tree.fullContainerField(m) orelse continue;
            if (field.ast.tuple_like) {
                // Tuple fields are named by position; the main token is the type.
                tuple = true;
                const type_src = if (field.ast.type_expr.unwrap()) |t| tree.getNodeSource(t) else tree.tokenSlice(field.ast.main_token);
                const type_text = try cleanText(arena, type_src, field_type_max);
                try fields.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{d}", .{fields.items.len}), .type = type_text });
                continue;
            }
            const type_text = if (field.ast.type_expr.unwrap()) |t| try cleanText(arena, tree.getNodeSource(t), field_type_max) else "";
            try fields.append(arena, .{ .name = try arena.dupe(u8, identName(tree, field.ast.main_token)), .type = type_text });
        }

        const first = tree.firstToken(decl_node);
        try s.b.containers.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.path, qualified }),
            .name = qualified,
            .kind = kindName(tree.tokenTag(container.ast.main_token)),
            .file = s.path,
            .line = s.lineOf(first),
            .is_pub = is_pub,
            .tuple = tuple,
            .doc = try s.docBefore(first),
            .fields = fields.items,
            .methods = methods,
            .allowed = allowed,
        });
    }

    fn qualify(s: *FileScan, owner: []const u8, name: []const u8) ![]const u8 {
        if (owner.len == 0) return s.b.arena.dupe(u8, name);
        return std.fmt.allocPrint(s.b.arena, "{s}.{s}", .{ owner, name });
    }

    /// Resolves every alias declaration, in as many passes as needed for
    /// aliases declared before what they refer to.
    fn resolveAliases(s: *FileScan) !void {
        const tree = s.tree;
        var round: u32 = 0;
        while (round < max_alias_rounds) : (round += 1) {
            var changed = false;
            for (s.vars.items) |*v| {
                if (v.done) continue;
                const decl = tree.fullVarDecl(v.node).?;
                const alias = (try s.aliasOf(decl.ast.init_node.unwrap().?, v.owner)) orelse continue;
                const name = identName(tree, decl.ast.mut_token + 1);
                try s.aliases.put(s.tmp, try scopedKey(s.tmp, v.owner, name), alias);
                if (v.owner.len == 0) try s.file_aliases.put(s.b.arena, try s.b.arena.dupe(u8, name), alias);
                v.done = true;
                changed = true;
            }
            if (!changed) break;
        }
    }

    /// `@import("x")`, `@import("x").A.B`, `alias.A.B` where `alias` is known,
    /// or `if (c) <one of those> else ...`: another name for something imported.
    fn aliasOf(s: *FileScan, init_node: Node.Index, owner: []const u8) Allocator.Error!?Alias {
        const tree = s.tree;
        if (tree.fullIf(init_node)) |full_if| return s.aliasOf(full_if.ast.then_expr, owner);

        const first = tree.firstToken(init_node);
        const last = tree.lastToken(init_node);
        var base: Alias = undefined;
        var t: TokenIndex = first;

        if (isImportCall(tree, t, last)) |target| {
            base = try s.resolveImport(target);
            t = closingParen(tree, t);
        } else if (tree.tokenTag(t) == .identifier) {
            base = s.lookup(owner, identName(tree, t)) orelse return null;
        } else return null;

        var member: std.ArrayList(u8) = .empty;
        try member.appendSlice(s.b.arena, base.member);
        while (t < last) {
            if (tree.tokenTag(t + 1) != .period or t + 2 > last or tree.tokenTag(t + 2) != .identifier) return null;
            if (member.items.len > 0) try member.append(s.b.arena, '.');
            try member.appendSlice(s.b.arena, identName(tree, t + 2));
            t += 2;
        }
        base.member = member.items;
        return base;
    }

    /// The alias `name` as seen from container `owner`: its own, then its parents'.
    fn lookup(s: *FileScan, owner: []const u8, name: []const u8) ?Alias {
        var scope = owner;
        var key_buf: [512]u8 = undefined;
        while (true) {
            const key = std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ scope, name }) catch return null;
            if (s.aliases.get(key)) |a| return a;
            if (scope.len == 0) return null;
            scope = if (std.mem.lastIndexOfScalar(u8, scope, '.')) |dot| scope[0..dot] else "";
        }
    }

    fn resolveImport(s: *FileScan, target: []const u8) !Alias {
        if (s.b.cfg.moduleFor(target, s.path)) |path| return .{ .file = path, .is_project = true, .member = "" };
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
            const target = isImportCall(tree, i, @intCast(tags.len - 1)) orelse continue;
            if (s.inTest(i)) continue;
            const resolved = try s.resolveImport(target);
            const alias = if (i >= 3 and tags[i - 1] == .equal and tags[i - 2] == .identifier) identName(tree, i - 2) else "";
            const line = s.lineOf(i);
            try s.imports.append(s.b.arena, .{
                .alias = alias,
                .target = target,
                .resolved = if (resolved.is_project) resolved.file else null,
                .line = line,
                .allowed = s.allowAt(line),
            });
        }
    }

    // ---- functions ----------------------------------------------------

    fn externFn(s: *FileScan, node: Node.Index, owner: []const u8, allowed: ?[]const u8) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        var buf: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, node) orelse return;
        const name_tok = proto.name_token orelse return;
        const name = identName(tree, name_tok);
        const first = tree.firstToken(node);
        const line = s.lineOf(first);
        const qualified = try s.qualify(owner, name);
        try s.b.functions.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.path, qualified }),
            .name = try arena.dupe(u8, name),
            .owner = owner,
            .file = s.path,
            .line = line,
            .end_line = s.lineOf(tree.lastToken(node)),
            .lines = s.lineOf(tree.lastToken(node)) - line + 1,
            .params = countParams(tree, proto),
            .complexity = 1,
            .depth = 0,
            .is_pub = proto.visib_token != null,
            .is_extern = true,
            .signature = try cleanText(arena, s.sourceBetween(first, tree.lastToken(node)), signature_max),
            .doc = try s.docBefore(first),
            .allowed = s.allowAt(line) orelse allowed,
        });
    }

    fn addFunction(s: *FileScan, p: PendingFn) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        var buf: [1]Node.Index = undefined;
        const proto = tree.fullFnProto(&buf, p.node) orelse return;
        const name = identName(tree, proto.name_token.?);
        const body = tree.nodeData(p.node).node_and_node[1];

        const first = tree.firstToken(p.node);
        const body_first = tree.firstToken(body);
        const body_last = tree.lastToken(body);
        const line = s.lineOf(first);
        const end_line = s.lineOf(body_last);
        std.debug.assert(line <= end_line);

        const m = s.metrics(body_first, body_last, p.exclude);
        const index: u32 = @intCast(s.b.functions.items.len);
        const qualified = try s.qualify(p.owner, name);
        const excluded: u32 = if (p.exclude) |r| r[1] - r[0] + 1 else 0;

        try s.b.functions.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ s.path, qualified }),
            .name = try arena.dupe(u8, name),
            .owner = p.owner,
            .file = s.path,
            .line = line,
            .end_line = end_line,
            .lines = end_line - line + 1,
            .params = countParams(tree, proto),
            .complexity = m.complexity,
            .depth = m.depth,
            .is_pub = proto.visib_token != null,
            .is_export = if (proto.extern_export_inline_token) |t| tree.tokenTag(t) == .keyword_export else false,
            .signature = try cleanText(arena, s.sourceBetween(first, tree.lastToken(proto.ast.proto_node)), signature_max),
            .doc = try s.docBefore(first),
            .tokens = body_last - body_first + 1 - excluded,
            .calls = try s.calls(proto, p.owner, body_first, body_last),
            .allowed = p.allowed,
        });
        try s.addBody(index, body_first, body_last, p.exclude);
    }

    const Metrics = struct { complexity: u32, depth: u32 };

    fn metrics(s: *FileScan, first: TokenIndex, last: TokenIndex, exclude: ?[2]TokenIndex) Metrics {
        const tags = s.tree.tokens.items(.tag);
        var m: Metrics = .{ .complexity = 1, .depth = 0 };
        // Which open braces are blocks (counted) and which are literals.
        var stack: std.bit_set.IntegerBitSet(256) = .initEmpty();
        var open: u32 = 0;
        var depth: u32 = 0;
        var switches: u32 = 0;
        var prongs: u32 = 0;
        var i = first;
        while (i <= last) : (i += 1) {
            if (exclude) |r| if (i >= r[0] and i <= r[1]) {
                i = r[1];
                continue;
            };
            switch (tags[i]) {
                .keyword_if, .keyword_while, .keyword_for, .keyword_catch, .keyword_orelse, .keyword_and, .keyword_or => m.complexity += 1,
                .keyword_switch => switches += 1,
                .equal_angle_bracket_right => prongs += 1,
                .l_brace => {
                    const block = i == first or opensBlock(tags[i - 1]);
                    if (open < 256) stack.setValue(open, block);
                    open += 1;
                    if (block) {
                        depth += 1;
                        m.depth = @max(m.depth, depth);
                    }
                },
                .r_brace => if (open > 0) {
                    open -= 1;
                    if (open < 256 and stack.isSet(open)) depth -|= 1;
                },
                else => {},
            }
        }
        m.complexity += prongs -| switches;
        // The body's own braces are not nesting.
        m.depth -|= 1;
        return m;
    }

    /// Calls through import aliases: `alias.f(`, `alias.Type.f(`, a local
    /// `const x = @import(...)`, or a parameter typed `alias.Type`. Names a
    /// parameter or local shadows are not aliases.
    fn calls(s: *FileScan, proto: Ast.full.FnProto, owner: []const u8, first: TokenIndex, last: TokenIndex) ![][]const u8 {
        const tree = s.tree;
        const arena = s.b.arena;
        const tags = tree.tokens.items(.tag);
        var locals = try s.localAliases(proto, owner, first, last);
        defer locals.deinit(s.tmp);

        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var i = first;
        while (i <= last) : (i += 1) {
            if (tags[i] != .identifier or (i > 0 and tags[i - 1] == .period)) continue;
            const name = identName(tree, i);
            const alias = if (locals.get(name)) |local| (local orelse continue) else (s.lookup(owner, name) orelse continue);
            if (!alias.is_project) continue;

            var path: std.ArrayList(u8) = .empty;
            try path.appendSlice(arena, alias.member);
            var j = i;
            while (j + 2 <= last and tags[j + 1] == .period and tags[j + 2] == .identifier) : (j += 2) {
                if (path.items.len > 0) try path.append(arena, '.');
                try path.appendSlice(arena, identName(tree, j + 2));
            }
            if (j + 1 > last or tags[j + 1] != .l_paren or path.items.len == 0) continue;
            const target = try std.fmt.allocPrint(arena, "{s}:{s}", .{ alias.file, path.items });
            const gop = try seen.getOrPut(arena, target);
            if (!gop.found_existing) try out.append(arena, target);
            i = j;
        }
        return out.items;
    }

    /// Names bound inside a function: null means "shadows an alias".
    fn localAliases(s: *FileScan, proto: Ast.full.FnProto, owner: []const u8, first: TokenIndex, last: TokenIndex) !std.StringHashMapUnmanaged(?Alias) {
        const tree = s.tree;
        const tags = tree.tokens.items(.tag);
        var locals: std.StringHashMapUnmanaged(?Alias) = .empty;

        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const name_tok = param.name_token orelse continue;
            const name = identName(tree, name_tok);
            const typed = if (param.type_expr) |t| s.typeAlias(owner, tree.firstToken(t), tree.lastToken(t)) else null;
            try locals.put(s.tmp, name, typed);
        }

        var i = first;
        while (i + 3 <= last) : (i += 1) {
            if (tags[i] != .keyword_const and tags[i] != .keyword_var) continue;
            if (tags[i + 1] != .identifier) continue;
            const name = identName(tree, i + 1);
            var alias: ?Alias = null;
            if (tags[i + 2] == .equal) {
                if (isImportCall(tree, i + 3, last)) |target| {
                    alias = try s.resolveImport(target);
                    // `@import("x").A.B`
                    var t = closingParen(tree, i + 3);
                    var member: std.ArrayList(u8) = .empty;
                    while (t + 2 <= last and tags[t + 1] == .period and tags[t + 2] == .identifier) : (t += 2) {
                        if (member.items.len > 0) try member.append(s.b.arena, '.');
                        try member.appendSlice(s.b.arena, identName(tree, t + 2));
                    }
                    alias.?.member = member.items;
                }
            }
            try locals.put(s.tmp, name, alias);
        }
        return locals;
    }

    /// `alias.Type`, `*alias.Type`, `?*const alias.Type`: the alias it names.
    fn typeAlias(s: *FileScan, owner: []const u8, first: TokenIndex, last: TokenIndex) ?Alias {
        const tree = s.tree;
        var t = first;
        while (t <= last) : (t += 1) {
            switch (tree.tokenTag(t)) {
                .asterisk, .question_mark, .keyword_const => continue,
                else => break,
            }
        }
        if (t > last or tree.tokenTag(t) != .identifier) return null;
        var alias = s.lookup(owner, identName(tree, t)) orelse return null;
        if (!alias.is_project) return null;
        var member: std.ArrayList(u8) = .empty;
        member.appendSlice(s.b.arena, alias.member) catch return null;
        while (t + 2 <= last and tree.tokenTag(t + 1) == .period and tree.tokenTag(t + 2) == .identifier) : (t += 2) {
            if (member.items.len > 0) member.append(s.b.arena, '.') catch return null;
            member.appendSlice(s.b.arena, identName(tree, t + 2)) catch return null;
        }
        if (t != last) return null;
        alias.member = member.items;
        return alias;
    }

    fn addBody(s: *FileScan, function: u32, first: TokenIndex, last: TokenIndex, exclude: ?[2]TokenIndex) !void {
        const tree = s.tree;
        const arena = s.b.arena;
        const tags = tree.tokens.items(.tag);
        const n = last - first + 1;
        var hashes: std.ArrayList(u64) = try .initCapacity(arena, n);
        var lines: std.ArrayList(u32) = try .initCapacity(arena, n);
        var i = first;
        while (i <= last) : (i += 1) {
            if (exclude) |r| if (i >= r[0] and i <= r[1]) {
                i = r[1];
                continue;
            };
            const h: u64 = switch (tags[i]) {
                .doc_comment, .container_doc_comment => continue,
                .identifier => s.identHash(i),
                .builtin => textHash(tree.tokenSlice(i)),
                .number_literal => 0x2d,
                .string_literal, .multiline_string_literal_line => 0x3d,
                .char_literal => 0x4d,
                else => @as(u64, @intFromEnum(tags[i])) + 0x100,
            };
            hashes.appendAssumeCapacity(h);
            lines.appendAssumeCapacity(s.lineOf(i));
        }
        try s.b.bodies.append(arena, .{ .function = function, .hashes = hashes.items, .lines = lines.items });
    }

    /// Fields, methods and enum tags (after a dot), file-scope names and
    /// primitive types keep their name; locals and parameters don't.
    fn identHash(s: *FileScan, i: TokenIndex) u64 {
        const tree = s.tree;
        const name = identName(tree, i);
        const after_dot = i > 0 and tree.tokenTag(i - 1) == .period;
        if (after_dot or s.file_names.contains(name) or std.zig.primitives.isPrimitive(name)) return textHash(name);
        return 0x1d;
    }

    fn countIdents(s: *FileScan) !void {
        const tree = s.tree;
        const tags = tree.tokens.items(.tag);
        for (tags, 0..) |tag, i| {
            if (tag != .identifier) continue;
            const prev: std.zig.Token.Tag = if (i > 0) tags[i - 1] else .invalid;
            const next: std.zig.Token.Tag = if (i + 1 < tags.len) tags[i + 1] else .eof;
            try s.b.noteIdent(identName(tree, @intCast(i)), prev, next);
        }
    }

    // ---- comments and annotations ---------------------------------------

    /// First line of the `//!` comment at the top of the file, skipping annotations.
    fn fileDoc(s: *FileScan) ![]const u8 {
        const tree = s.tree;
        const tags = tree.tokens.items(.tag);
        for (tags, 0..) |tag, i| {
            if (tag != .container_doc_comment) break;
            const text = std.mem.trim(u8, tree.tokenSlice(@intCast(i))[3..], " \t\r");
            if (text.len > 0 and std.mem.indexOf(u8, text, "@atlas") == null) return cleanText(s.b.arena, text, doc_max);
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
            if (text.len > 0 and std.mem.indexOf(u8, text, "@atlas") == null) return cleanText(s.b.arena, text, doc_max);
        }
        return "";
    }

    /// Fills `allow_at`: per line, the `@atlas allow` reason on that line or in
    /// the comment block directly above it. One pass, so files with many
    /// declarations per comment block stay linear.
    fn indexAllows(s: *FileScan) !void {
        s.allow_at = try s.tmp.alloc(?[]const u8, s.line_starts.len + 1);
        @memset(s.allow_at, null);
        var block: ?[]const u8 = null;
        for (1..s.line_starts.len + 1) |line| {
            const text = s.lineText(@intCast(line));
            const own = annotationIn(text, "allow");
            s.allow_at[line] = own orelse block;
            if (isComment(text)) {
                if (block == null) block = own;
            } else block = null;
        }
    }

    fn allowAt(s: *FileScan, line: u32) ?[]const u8 {
        if (line == 0 or line >= s.allow_at.len) return null;
        return s.allow_at[line];
    }

    /// Value of `@atlas <key> <value>` in the file's `//!` header.
    fn headerAnnotation(s: *FileScan, key: []const u8) ?[]const u8 {
        for (1..s.line_starts.len + 1) |line| {
            const text = std.mem.trimStart(u8, s.lineText(@intCast(line)), " \t");
            if (!std.mem.startsWith(u8, text, "//!")) continue;
            if (annotationIn(text, key)) |v| return v;
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
        const ranges = s.test_ranges.items;
        // Ranges are sorted and don't overlap: find the last one starting at or before t.
        const idx = std.sort.upperBound([2]TokenIndex, ranges, t, struct {
            fn order(key: TokenIndex, r: [2]TokenIndex) std.math.Order {
                return std.math.order(key, r[0]);
            }
        }.order);
        return idx > 0 and t <= ranges[idx - 1][1];
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

/// `@import ( "x" [,] )` starting at `t`: the import's target.
fn isImportCall(tree: *const Ast, t: TokenIndex, last: TokenIndex) ?[]const u8 {
    if (t + 3 > last) return null;
    if (tree.tokenTag(t) != .builtin or !std.mem.eql(u8, tree.tokenSlice(t), "@import")) return null;
    if (tree.tokenTag(t + 1) != .l_paren or tree.tokenTag(t + 2) != .string_literal) return null;
    return stringValue(tree.tokenSlice(t + 2));
}

/// The `)` closing an `@import (` call that starts at `t` (allowing a trailing comma).
fn closingParen(tree: *const Ast, t: TokenIndex) TokenIndex {
    return if (tree.tokenTag(t + 3) == .comma) t + 4 else t + 3;
}

/// The container a `fn ... type` function returns: `return struct { ... };`.
fn returnedContainer(tree: *const Ast, fn_node: Node.Index) ?Node.Index {
    var buf: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, fn_node) orelse return null;
    const ret = proto.ast.return_type.unwrap() orelse return null;
    if (!std.mem.eql(u8, tree.getNodeSource(ret), "type")) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var sbuf: [2]Node.Index = undefined;
    const statements = tree.blockStatements(&sbuf, body) orelse return null;
    for (statements) |stmt| {
        if (tree.nodeTag(stmt) != .@"return") continue;
        const operand = tree.nodeData(stmt).opt_node.unwrap() orelse continue;
        var cbuf: [2]Node.Index = undefined;
        if (tree.fullContainerDecl(&cbuf, operand) != null) return operand;
    }
    return null;
}

fn countParams(tree: *const Ast, proto: Ast.full.FnProto) u32 {
    var n: u32 = 0;
    var it = proto.iterate(tree);
    while (it.next()) |_| n += 1;
    return n;
}

/// Whether a `{` after this token opens a block (not a struct or array literal,
/// an error set or a type body).
fn opensBlock(prev: std.zig.Token.Tag) bool {
    return switch (prev) {
        .period, .identifier, .keyword_error, .keyword_struct, .keyword_enum, .keyword_union, .keyword_opaque, .r_bracket => false,
        else => true,
    };
}

/// The line where brace and paren nesting first goes past `max_nesting`.
fn tooDeep(source: [:0]const u8) ?u32 {
    var tokenizer = std.zig.Tokenizer.init(source);
    var depth: u32 = 0;
    while (true) {
        const tok = tokenizer.next();
        switch (tok.tag) {
            .eof => return null,
            .l_brace, .l_paren, .l_bracket => {
                depth += 1;
                if (depth > max_nesting) return @intCast(std.mem.countScalar(u8, source[0..tok.loc.start], '\n') + 1);
            },
            .r_brace, .r_paren, .r_bracket => depth -|= 1,
            else => {},
        }
    }
}

/// An identifier's name: `@"name"` becomes `name` when that is a plain identifier.
fn identName(tree: *const Ast, t: TokenIndex) []const u8 {
    return identText(tree.tokenSlice(t));
}

fn identText(raw: []const u8) []const u8 {
    if (raw.len < 3 or raw[0] != '@' or raw[1] != '"' or raw[raw.len - 1] != '"') return raw;
    const inner = raw[2 .. raw.len - 1];
    if (inner.len == 0 or !(std.ascii.isAlphabetic(inner[0]) or inner[0] == '_')) return raw;
    for (inner) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return raw;
    }
    return inner;
}

fn scopedKey(arena: Allocator, owner: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ owner, name });
}

/// Value of `@atlas <key> <value>` inside the comment on this line.
fn annotationIn(text: []const u8, key: []const u8) ?[]const u8 {
    const comment = std.mem.indexOf(u8, text, "//") orelse return null;
    const at = std.mem.indexOfPos(u8, text, comment, "@atlas") orelse return null;
    var rest = std.mem.trimStart(u8, text[at + "@atlas".len ..], " \t");
    if (!std.mem.startsWith(u8, rest, key)) return null;
    rest = std.mem.trim(u8, rest[key.len..], " \t\r:");
    return if (rest.len == 0) "annotated" else rest;
}

fn rangeLess(_: void, a: [2]TokenIndex, b: [2]TokenIndex) bool {
    return a[0] < b[0];
}

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

/// Text for the output: whitespace runs collapsed to one space, invalid UTF-8
/// replaced with '?', and at most `max` bytes, cut on a character boundary.
/// Everything that goes into atlas.json passes through here, so the JSON
/// writer always sees valid UTF-8 (it writes anything else as numbers).
pub fn cleanText(arena: Allocator, text: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (std.ascii.isWhitespace(c)) {
            space = out.items.len > 0;
            i += 1;
            continue;
        }
        const len: usize = std.unicode.utf8ByteSequenceLength(c) catch 0;
        const valid = len > 0 and i + len <= text.len and (std.unicode.utf8Decode(text[i .. i + len]) catch null) != null;
        const width: usize = if (valid) len else 1;
        if (out.items.len + @intFromBool(space) + width > max) {
            try out.appendSlice(arena, "…");
            break;
        }
        if (space) try out.append(arena, ' ');
        space = false;
        if (valid) try out.appendSlice(arena, text[i .. i + len]) else try out.append(arena, '?');
        i += width;
    }
    return out.items;
}

test "clean text keeps valid UTF-8 when it cuts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cut = try cleanText(arena, "a" ++ "é" ** 100, 160);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expect(std.mem.endsWith(u8, cut, "…"));
    try std.testing.expectEqualStrings("caf? ok", try cleanText(arena, "caf\xe9   ok", 80));
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
        \\const settings = pkg.settings;
        \\pub export fn info() void {
        \\    pkg.settings.cacheInfo();
        \\    settings.cacheInfo();
        \\}
    );
    try b.resolveCalls();
    const info = b.functions.items[1];
    try std.testing.expect(info.is_export);
    try std.testing.expectEqual(@as(usize, 1), info.calls.len);
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
        \\const Peer = net.Peer;
        \\const net = @import("../net/mod.zig",);
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
    // `Peer` is declared before the import it refers to, and still resolves.
    try std.testing.expectEqual(@as(usize, 2), send.calls.len);
    try std.testing.expectEqualStrings("src/net/mod.zig:transport.send", send.calls[0]);
    try std.testing.expectEqualStrings("src/net/mod.zig:Peer.connect", send.calls[1]);

    const helper = b.functions.items[1];
    try std.testing.expect(!helper.is_pub);
    try std.testing.expectEqual(@as(u32, 3), helper.complexity);
    try std.testing.expectEqualStrings("kept for the bench", helper.allowed.?);
}

test "generic types are types: their methods are scanned, the function measured without them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{};
    var b = Builder.init(arena_state.allocator(), &cfg);
    try b.addFile("q.zig",
        \\pub fn Queue(comptime T: type) type {
        \\    return struct {
        \\        items: []T,
        \\        pub fn push(self: *@This(), x: T) void {
        \\            if (x == 0) return;
        \\            if (self.items.len == 0) return;
        \\        }
        \\    };
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), b.containers.items.len);
    try std.testing.expectEqualStrings("Queue", b.containers.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), b.containers.items[0].fields.len);
    try std.testing.expectEqual(@as(usize, 2), b.functions.items.len);
    const push = b.functions.items[0];
    try std.testing.expectEqualStrings("q.zig:Queue.push", push.id);
    try std.testing.expectEqual(@as(u32, 3), push.complexity);
    const queue = b.functions.items[1];
    try std.testing.expectEqual(@as(u32, 1), queue.complexity);
}

test "aliases are scoped, shadowed by parameters, and found through typed parameters and local imports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{};
    var b = Builder.init(arena_state.allocator(), &cfg);
    try b.addFile("src/ui/view.zig",
        \\const core = @import("../core/svc.zig");
        \\const A = struct {
        \\    const other = @import("other.zig");
        \\    fn a() void { other.run(); }
        \\};
        \\fn shadowed(other: anytype) void { other.run(); }
        \\fn typed(svc: *core.Service) void { svc.charge(); }
        \\fn local() void {
        \\    const c = @import("../core/svc.zig");
        \\    c.decide();
        \\}
        \\fn @"quoted"() void {}
    );
    const fns = b.functions.items;
    try std.testing.expectEqualStrings("src/ui/other.zig:run", fns[0].calls[0]);
    try std.testing.expectEqual(@as(usize, 0), fns[1].calls.len);
    try std.testing.expectEqualStrings("src/core/svc.zig:Service.charge", fns[2].calls[0]);
    try std.testing.expectEqualStrings("src/core/svc.zig:decide", fns[3].calls[0]);
    try std.testing.expectEqualStrings("quoted", fns[4].name);
}

test "tuple structs are named by position; extern prototypes are listed; empty files have no lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{};
    var b = Builder.init(arena_state.allocator(), &cfg);
    try b.addFile("t.zig",
        \\pub const T = struct { u32, u8 };
        \\pub extern fn ext(a: c_int) c_int;
    );
    try b.addFile("empty.zig", "");
    const t = b.containers.items[0];
    try std.testing.expect(t.tuple);
    try std.testing.expectEqualStrings("0", t.fields[0].name);
    try std.testing.expectEqualStrings("u32", t.fields[0].type);
    try std.testing.expect(b.functions.items[0].is_extern);
    try std.testing.expectEqual(@as(u32, 0), b.files.items[1].lines);
}

test "struct literals are not nesting; deep files are reported, not parsed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg: Config = .{};
    var b = Builder.init(arena, &cfg);
    try b.addFile("lit.zig",
        \\fn lit() void {
        \\    const a = .{ .x = .{ .y = .{ .z = 1 } } };
        \\    if (a.x.y.z == 1) {
        \\        _ = a;
        \\    }
        \\}
    );
    try std.testing.expectEqual(@as(u32, 1), b.functions.items[0].depth);

    var deep: std.ArrayList(u8) = .empty;
    for (0..300) |_| try deep.appendSlice(arena, "const A = struct {\n");
    for (0..300) |_| try deep.appendSlice(arena, "};\n");
    try deep.append(arena, 0);
    try b.addFile("deep.zig", deep.items[0 .. deep.items.len - 1 :0]);
    const file = b.files.items[1];
    try std.testing.expectEqual(@as(u32, 1), file.parse_errors);
    try std.testing.expectEqual(@as(u32, 201), file.parse_error_line);
}

test "parse errors point at their line; unknown layer annotations are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg: Config = .{ .layers = &.{.{ .name = "base", .paths = &.{"src"} }} };
    var b = Builder.init(arena_state.allocator(), &cfg);
    try b.addFile("src/bad.zig", "//! @atlas layer: storge\nconst a = 1;\n\npub fn broken( void {\n}\n");
    const file = b.files.items[0];
    try std.testing.expect(file.parse_errors > 0);
    try std.testing.expectEqual(@as(u32, 4), file.parse_error_line);
    try std.testing.expectEqualStrings("base", file.layer.?);
    try std.testing.expectEqual(model.FindingKind.unknown_layer, b.findings.items[0].kind);
}
