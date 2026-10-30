//! The atlas: everything zigatlas learns about a code base, in the shape it is
//! written to atlas.json. Scanning fills it, checks add findings to it and the
//! renderers only read it. Field changes are additive; `schema` goes up when
//! one is not.
const std = @import("std");

/// atlas.json format version.
pub const schema_version = 1;

pub const Atlas = struct {
    schema: u32 = schema_version,
    /// The layers the run checked, top to bottom.
    layers: []const Layer = &.{},
    files: []File,
    functions: []Function,
    containers: []Container,
    findings: []Finding,
    stats: Stats,
};

/// A layer of the architecture (configured in config.zig, recorded in the atlas).
pub const Layer = struct {
    name: []const u8,
    /// Path prefixes (directories or single files) that belong to the layer.
    paths: []const []const u8,
    /// Front ends: should only parse input and present output.
    thin: bool = false,
};

pub const Stats = struct {
    files: u32 = 0,
    lines: u32 = 0,
    functions: u32 = 0,
    pub_functions: u32 = 0,
    containers: u32 = 0,
    tests: u32 = 0,
    import_edges: u32 = 0,

    pub fn compute(files: []const File, functions: []const Function, containers: []const Container) Stats {
        var s: Stats = .{
            .files = @intCast(files.len),
            .functions = @intCast(functions.len),
            .containers = @intCast(containers.len),
        };
        for (files) |f| {
            s.lines += f.lines;
            s.tests += f.tests;
            for (f.imports) |imp| {
                if (imp.resolved != null) s.import_edges += 1;
            }
        }
        for (functions) |f| {
            if (f.is_pub) s.pub_functions += 1;
        }
        return s;
    }
};

pub const File = struct {
    /// Relative to the project root, always with '/'.
    path: []const u8,
    dir: []const u8,
    layer: ?[]const u8 = null,
    /// First line of the file's `//!` doc comment.
    doc: []const u8 = "",
    lines: u32 = 0,
    tests: u32 = 0,
    imports: []Import = &.{},
    /// Files importing this one (resolved imports only).
    fan_in: u32 = 0,
    parse_errors: u32 = 0,
    /// Line of the first parse error (0 when there is none).
    parse_error_line: u32 = 0,
    /// Why the file was not parsed at all, when it wasn't.
    parse_note: []const u8 = "",
    /// Reason from an `@atlas allow` in the `//!` header; mutes file-level findings.
    allowed: ?[]const u8 = null,
};

pub const Import = struct {
    /// The name the importing file binds, e.g. `fs` in `const fs = @import("fs/mod.zig");`.
    alias: []const u8,
    /// The literal `@import` argument.
    target: []const u8,
    /// Project file the import resolves to, null for std and other packages.
    resolved: ?[]const u8 = null,
    line: u32,
    /// Reason from an `@atlas allow` annotation; findings on this import are muted.
    allowed: ?[]const u8 = null,
};

pub const Function = struct {
    /// `path/to/file.zig:Type.name`
    id: []const u8,
    name: []const u8,
    /// Containing type chain inside the file, empty at file scope. Methods of
    /// a generic type (`fn List(T) type { return struct {...} }`) are owned by
    /// the function's name.
    owner: []const u8,
    file: []const u8,
    line: u32,
    end_line: u32,
    lines: u32,
    params: u32,
    /// Cyclomatic estimate: 1 + branches (if, while, for, catch, orelse, and, or, extra switch prongs).
    complexity: u32,
    /// Deepest block nesting inside the body (struct literals don't count).
    depth: u32,
    is_pub: bool,
    /// `export fn`: called from C or another language, never by name here.
    is_export: bool = false,
    /// `extern fn` prototype: no body.
    is_extern: bool = false,
    signature: []const u8,
    doc: []const u8 = "",
    /// Body size in tokens, the unit clone detection works in.
    tokens: u32 = 0,
    /// Cross-file calls through import aliases, re-exports and typed
    /// parameters, as `file.zig:Name.path`.
    calls: [][]const u8 = &.{},
    allowed: ?[]const u8 = null,
};

pub const Container = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    file: []const u8,
    line: u32,
    is_pub: bool,
    /// A tuple struct: fields are named by position.
    tuple: bool = false,
    doc: []const u8 = "",
    fields: []Field = &.{},
    methods: u32 = 0,
    allowed: ?[]const u8 = null,
};

pub const Field = struct {
    name: []const u8,
    type: []const u8,
};

pub const Severity = enum {
    info,
    warn,
    @"error",

    pub fn rank(s: Severity) u8 {
        return @intFromEnum(s);
    }
};

/// Findings per severity, indexed by `Severity.rank()`.
pub fn countBySeverity(findings: []const Finding) [3]u32 {
    var counts = [_]u32{ 0, 0, 0 };
    for (findings) |f| counts[f.severity.rank()] += 1;
    return counts;
}

pub const FindingKind = enum {
    /// Two or more functions whose bodies are the same once local names and literals are ignored.
    duplicate_function,
    /// A long run of identical code inside different functions.
    duplicate_fragment,
    /// Structs whose fields are (nearly) the same set of names.
    duplicate_shape,
    /// The same top-level function name implemented in several files.
    parallel_implementation,
    /// An import from a lower layer up into a higher one.
    layer_violation,
    /// An import forbidden by an explicit rule (e.g. a layer skipping the one below it).
    forbidden_import,
    /// Files or directories that import each other in a loop.
    import_cycle,
    /// A layer marked thin (front ends) carrying real logic.
    thick_frontend,
    long_function,
    complex_function,
    many_params,
    large_file,
    /// A public function whose name appears nowhere else in the project.
    unused_pub,
    parse_error,
    /// An `@atlas layer` annotation naming a layer the configuration doesn't have.
    unknown_layer,
};

pub const Location = struct {
    file: []const u8,
    line: u32,
    end_line: u32 = 0,
    symbol: []const u8 = "",
};

pub const Finding = struct {
    kind: FindingKind,
    severity: Severity,
    message: []const u8,
    locations: []Location,
};
