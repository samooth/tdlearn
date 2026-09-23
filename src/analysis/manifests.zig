const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("core");
const toml_mod = core.toml;

/// Package-name aliases from manifest files.
///
/// Rust workspaces split code across crates: `tdlearn-bin/Cargo.toml` declares
/// `[lib] name = "tdlearn_bin"`, and sibling crates do `use tdlearn_core::...`.
/// The file list has no `tdlearn_core` path — the alias resolves to the
/// package root (`src/lib.rs`). Same for npm: `package.json` `name` + `main`.
///
/// An alias maps a crate/package name (hyphens → underscores) to its root
/// source file, relative to the scan root exactly like other file paths.
pub const Alias = struct {
    name: []const u8,
    root_file: []const u8,
};

/// Read manifest files found among `file_paths` and collect package aliases.
/// Only aliases whose root file is also in `file_paths` are returned.
/// All returned strings are duplicated into `allocator` (use an arena).
pub fn readPackageAliases(
    allocator: Allocator,
    io: Io,
    file_paths: []const []const u8,
) ![]Alias {
    return readPackageAliasesAtRoot(allocator, io, "", file_paths);
}

pub fn readPackageAliasesAtRoot(
    allocator: Allocator,
    io: Io,
    root_path: []const u8,
    file_paths: []const []const u8,
) ![]Alias {
    var aliases = std.ArrayList(Alias).empty;
    errdefer aliases.deinit(allocator);

    for (file_paths) |path| {
        const name = core.path_utils.fileName(path);
        const is_cargo = std.mem.eql(u8, name, "Cargo.toml");
        const is_pkg_json = std.mem.eql(u8, name, "package.json");
        if (!is_cargo and !is_pkg_json) continue;

        // Skip manifests inside excluded paths (target/, node_modules/)
        if (isInExcludedDir(path)) continue;

        const contents = readSmallFile(allocator, io, root_path, path) catch continue orelse continue;
        const dir = core.path_utils.parentDir(path) orelse "";

        if (is_cargo) {
            try parseCargoAliases(allocator, contents, dir, &aliases);
        } else {
            try parsePackageJsonAliases(allocator, contents, dir, &aliases);
        }
    }

    // Keep only aliases whose root file is actually in the scan
    var in_scan = std.StringHashMap(void).init(allocator);
    defer in_scan.deinit();
    for (file_paths) |p| {
        try in_scan.put(p, {});
    }

    var filtered = std.ArrayList(Alias).empty;
    errdefer filtered.deinit(allocator);
    for (aliases.items) |alias| {
        if (in_scan.contains(alias.root_file)) {
            try filtered.append(allocator, alias);
        }
    }
    aliases.deinit(allocator);

    return try filtered.toOwnedSlice(allocator);
}

/// Parse Cargo.toml contents into aliases for `manifest_dir`.
///   [package] name = "tdlearn-core"   → alias "tdlearn_core"
///   [lib] name/path                   → overrides root and alias
///
/// Both the lib name and the package name (normalized to underscores)
/// map to the lib root; the lib name wins conflicts.
pub fn parseCargoAliases(
    allocator: Allocator,
    contents: []const u8,
    manifest_dir: []const u8,
    aliases: *std.ArrayList(Alias),
) !void {
    var toml = toml_mod.Toml.init(allocator);
    defer toml.deinit();
    toml.parse(contents) catch return; // malformed manifest — skip silently

    const pkg_name = blk: {
        const t = toml.table("package") orelse break :blk null;
        const v = t.get("name") orelse break :blk null;
        break :blk v.asString();
    } orelse return; // no package name — not a package manifest

    // Lib target: explicit [lib] path, else src/lib.rs
    var lib_name: ?[]const u8 = null;
    var lib_path: []const u8 = "src/lib.rs";
    if (toml.table("lib")) |lib| {
        if (lib.get("name")) |v| lib_name = v.asString();
        if (lib.get("path")) |v| {
            if (v.asString()) |p| lib_path = p;
        }
    }

    const root = try joinPath(allocator, manifest_dir, lib_path);

    if (lib_name) |ln| {
        try appendCargoAlias(allocator, aliases, ln, root);
    }
    try appendCargoAlias(allocator, aliases, pkg_name, root);
}

/// Parse package.json contents into aliases for `manifest_dir`.
///   { "name": "left-pad", "main": "lib/index.js" } → alias "left-pad"
pub fn parsePackageJsonAliases(
    allocator: Allocator,
    contents: []const u8,
    manifest_dir: []const u8,
    aliases: *std.ArrayList(Alias),
) !void {
    const PkgJson = struct {
        name: ?[]const u8 = null,
        main: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(PkgJson, allocator, contents, .{}) catch return;
    defer parsed.deinit();

    const pkg_name = parsed.value.name orelse return;
    const main: []const u8 = parsed.value.main orelse "index.js";

    const root = try joinPath(allocator, manifest_dir, main);
    try appendPackageAlias(allocator, aliases, pkg_name, root);
}

fn appendCargoAlias(allocator: Allocator, aliases: *std.ArrayList(Alias), raw_name: []const u8, root_file: []const u8) !void {
    const name = try allocator.dupe(u8, raw_name);
    defer allocator.free(name);
    for (name) |*c| {
        if (c.* == '-') c.* = '_';
    }
    try appendAlias(allocator, aliases, name, root_file);
}

fn appendPackageAlias(allocator: Allocator, aliases: *std.ArrayList(Alias), raw_name: []const u8, root_file: []const u8) !void {
    try appendAlias(allocator, aliases, raw_name, root_file);
}

fn appendAlias(allocator: Allocator, aliases: *std.ArrayList(Alias), name: []const u8, root_file: []const u8) !void {
    for (aliases.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) return;
    }
    try aliases.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .root_file = try allocator.dupe(u8, root_file),
    });
}

fn joinPath(allocator: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    if (dir.len == 0) return allocator.dupe(u8, rel);
    return std.mem.join(allocator, "/", &.{ dir, rel });
}

fn isInExcludedDir(path: []const u8) bool {
    const markers = [_][]const u8{ "/target/", "/node_modules/", "/.git/", "/vendor/" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, path, m) != null) return true;
    }
    return false;
}

fn readSmallFile(allocator: Allocator, io: Io, root_path: []const u8, path: []const u8) !?[]const u8 {
    const full_path = if (root_path.len == 0) path else try std.mem.join(allocator, "/", &.{ root_path, path });
    const file = std.Io.Dir.cwd().openFile(io, full_path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > 64 * 1024) return null;
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    const bytes_read = file.readPositionalAll(io, buf, 0) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..bytes_read];
}

// ── Tests ─────────────────────────────────────────────────────

test "read package aliases from scanned manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "Cargo.toml",
        .data = "[package]\nname = \"demo-core\"\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/lib.rs",
        .data = "pub fn demo() void {}\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/Cargo.toml", .{root});
    const source_path = try std.fmt.allocPrint(allocator, "{s}/src/lib.rs", .{root});
    const paths = [_][]const u8{ manifest_path, source_path };

    const aliases = try readPackageAliases(allocator, io, &paths);
    try std.testing.expectEqual(@as(usize, 1), aliases.len);
    try std.testing.expectEqualStrings("demo_core", aliases[0].name);
    try std.testing.expectEqualStrings(source_path, aliases[0].root_file);
}

test "package aliases skip roots outside scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{
        .sub_path = "Cargo.toml",
        .data = "[package]\nname = \"outside\"\n[lib]\npath = \"src/missing.rs\"\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/Cargo.toml", .{root});
    const paths = [_][]const u8{manifest_path};

    const aliases = try readPackageAliases(allocator, io, &paths);
    try std.testing.expectEqual(@as(usize, 0), aliases.len);
}

test "cargo package name alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    const cargo =
        \\[package]
        \\name = "tdlearn-core"
        \\version = "0.5.7"
    ;
    try parseCargoAliases(arena.allocator(), cargo, "tdlearn-core", &aliases);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("tdlearn_core", aliases.items[0].name);
    try std.testing.expectEqualStrings("tdlearn-core/src/lib.rs", aliases.items[0].root_file);
}

test "cargo lib name and path override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    const cargo =
        \\[package]
        \\name = "tdlearn"
        \\
        \\[lib]
        \\name = "tdlearn_bin"
        \\path = "src/lib.rs"
    ;
    try parseCargoAliases(arena.allocator(), cargo, "tdlearn-bin", &aliases);
    // lib name first, then package name — both → src/lib.rs
    try std.testing.expectEqual(@as(usize, 2), aliases.items.len);
    try std.testing.expectEqualStrings("tdlearn_bin", aliases.items[0].name);
    try std.testing.expectEqualStrings("tdlearn", aliases.items[1].name);
    for (aliases.items) |a| {
        try std.testing.expectEqualStrings("tdlearn-bin/src/lib.rs", a.root_file);
    }
}

test "cargo custom lib path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    const cargo =
        \\[package]
        \\name = "my-crate"
        \\
        \\[lib]
        \\path = "lib/root.rs"
    ;
    try parseCargoAliases(arena.allocator(), cargo, "crates/my-crate", &aliases);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("crates/my-crate/lib/root.rs", aliases.items[0].root_file);
}

test "cargo malformed skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    try parseCargoAliases(arena.allocator(), "not [ valid toml", "x", &aliases);
    try std.testing.expectEqual(@as(usize, 0), aliases.items.len);

    // No [package] name — skip
    try parseCargoAliases(arena.allocator(), "[lib]\nname = \"x\"", "x", &aliases);
    try std.testing.expectEqual(@as(usize, 0), aliases.items.len);
}

test "package json alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    const json = "{\"name\": \"left-pad\", \"main\": \"lib/main.js\"}";
    try parsePackageJsonAliases(arena.allocator(), json, "packages/left-pad", &aliases);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("left-pad", aliases.items[0].name);
    try std.testing.expectEqualStrings("packages/left-pad/lib/main.js", aliases.items[0].root_file);
}

test "package json defaults to index.js" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    const json = "{\"name\": \"my-app\"}";
    try parsePackageJsonAliases(arena.allocator(), json, "apps/my-app", &aliases);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("apps/my-app/index.js", aliases.items[0].root_file);
}

test "package json without name skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    const json = "{\"main\": \"lib/main.js\"}";
    try parsePackageJsonAliases(arena.allocator(), json, "x", &aliases);
    try std.testing.expectEqual(@as(usize, 0), aliases.items.len);
}

test "hyphen normalization dedupes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aliases = std.ArrayList(Alias).empty;
    defer aliases.deinit(arena.allocator());

    // lib name "tdlearn_core" and package "tdlearn-core" → same normalized alias
    const cargo =
        \\[package]
        \\name = "tdlearn-core"
        \\
        \\[lib]
        \\name = "tdlearn_core"
    ;
    try parseCargoAliases(arena.allocator(), cargo, "d", &aliases);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
}
