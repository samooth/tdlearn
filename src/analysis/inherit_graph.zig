const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const classes_mod = @import("classes.zig");

/// Build inheritance edges from extracted classes.
///
/// Resolution of a base-class name declared in file F:
///   1. Defined in F itself — same-file inheritance, no cross-file edge
///   2. Defined in a file F imports → InheritEdge
///   3. Defined exactly once project-wide → InheritEdge (unique fallback;
///      class names are usually distinct enough to be unambiguous)
///
/// All allocations come from `allocator` — use an arena for one-shot scans.
pub const InheritGraphBuilder = struct {
    pub const FileClasses = struct {
        file: []const u8,
        classes: []const core.types.ClassInfo,
    };

    const EdgeSet = struct {
        map: std.StringHashMap(void),
        allocator: Allocator,

        fn init(allocator: Allocator) EdgeSet {
            return .{ .map = std.StringHashMap(void).init(allocator), .allocator = allocator };
        }

        fn deinit(self: *EdgeSet) void {
            var iter = self.map.iterator();
            while (iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
            self.map.deinit();
        }
    };

    /// Build inheritance edges from per-file class lists.
    /// `import_edges` are the resolved file-level import edges.
    pub fn buildInheritEdges(
        allocator: Allocator,
        file_classes: []const FileClasses,
        import_edges: []const core.types.ImportEdge,
    ) ![]core.types.InheritEdge {
        const FileList = std.ArrayList([]const u8);

        var edges = std.ArrayList(core.types.InheritEdge).empty;
        errdefer edges.deinit(allocator);
        var edge_set = EdgeSet.init(allocator);
        defer edge_set.deinit();

        // class name → list of defining files
        var class_index = std.StringHashMap(*FileList).init(allocator);
        defer {
            var iter = class_index.iterator();
            while (iter.next()) |e| {
                e.value_ptr.*.deinit(allocator);
                allocator.destroy(e.value_ptr.*);
            }
            class_index.deinit();
        }

        // file path → imported file paths
        var imports_by_file = std.StringHashMap(*std.ArrayList([]const u8)).init(allocator);
        defer {
            var iter2 = imports_by_file.iterator();
            while (iter2.next()) |e| {
                e.value_ptr.*.deinit(allocator);
                allocator.destroy(e.value_ptr.*);
            }
            imports_by_file.deinit();
        }

        // Build class index
        for (file_classes) |fc| {
            for (fc.classes) |cls| {
                const gop = try class_index.getOrPut(cls.name);
                if (!gop.found_existing) {
                    const list = try allocator.create(FileList);
                    list.* = .empty;
                    gop.value_ptr.* = list;
                }
                // dedupe: same class declared twice in one file (e.g. Rust impl blocks)
                var already = false;
                for (gop.value_ptr.*.items) |existing| {
                    if (std.mem.eql(u8, existing, fc.file)) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try gop.value_ptr.*.append(allocator, fc.file);
                }
            }
        }

        // Build imports index
        for (import_edges) |edge| {
            const gop = try imports_by_file.getOrPut(edge.from_file);
            if (!gop.found_existing) {
                const list = try allocator.create(std.ArrayList([]const u8));
                list.* = .empty;
                gop.value_ptr.* = list;
            }
            try gop.value_ptr.*.append(allocator, edge.to_file);
        }

        try appendResolvedEdges(
            allocator,
            file_classes,
            &class_index,
            &imports_by_file,
            &edges,
            &edge_set,
        );

        return try edges.toOwnedSlice(allocator);
    }

    fn appendResolvedEdges(
        allocator: Allocator,
        file_classes: []const FileClasses,
        class_index: *const std.StringHashMap(*std.ArrayList([]const u8)),
        imports_by_file: *const std.StringHashMap(*std.ArrayList([]const u8)),
        edges: *std.ArrayList(core.types.InheritEdge),
        edge_set: *EdgeSet,
    ) !void {
        for (file_classes) |fc| {
            const imported = imports_by_file.get(fc.file);
            for (fc.classes) |cls| {
                const bases = cls.bases orelse continue;
                for (bases) |base| {
                    const candidates = class_index.get(base) orelse continue;
                    const parent_file = resolveBaseFile(candidates, imported, fc.file) orelse continue;
                    try appendEdge(allocator, edges, edge_set, .{
                        .child_file = fc.file,
                        .child_class = cls.name,
                        .parent_file = parent_file,
                        .parent_class = base,
                    });
                }
            }
        }
    }

    /// Which file, if any, defines `base` for a class in `child_file`.
    ///
    /// A base declared in a file the child imports wins. When the child does
    /// import files, that list is decisive: a base defined only outside the
    /// imports stays unresolved instead of being guessed from the project. With
    /// no imports to go by, the name has to be unique in the whole project, and
    /// a same-file definition never counts as a parent.
    fn resolveBaseFile(
        candidates: *const std.ArrayList([]const u8),
        imported: ?*const std.ArrayList([]const u8),
        child_file: []const u8,
    ) ?[]const u8 {
        if (imported) |files| {
            for (candidates.items) |cand_file| {
                if (std.mem.eql(u8, cand_file, child_file)) continue;
                for (files.items) |imp_file| {
                    if (std.mem.eql(u8, imp_file, cand_file)) return cand_file;
                }
            }
            return null;
        }
        if (candidates.items.len != 1) return null;
        const only = candidates.items[0];
        if (std.mem.eql(u8, only, child_file)) return null;
        return only;
    }

    fn appendEdge(
        allocator: Allocator,
        edges: *std.ArrayList(core.types.InheritEdge),
        edge_set: *EdgeSet,
        edge: core.types.InheritEdge,
    ) !void {
        const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}\x00{s}", .{ edge.child_file, edge.child_class, edge.parent_file, edge.parent_class });
        if (edge_set.map.contains(key)) {
            allocator.free(key);
            return;
        }
        errdefer allocator.free(key);
        try edge_set.map.put(key, {});
        errdefer _ = edge_set.map.remove(key);
        try edges.append(allocator, edge);
    }
};

// ── Tests ─────────────────────────────────────────────────────

fn makeClass(name: []const u8, bases: ?[]const []const u8) core.types.ClassInfo {
    return .{
        .name = name,
        .bases = if (bases) |b| @constCast(b) else null,
        .kind = .class,
    };
}

test "cross-file inheritance via import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const animal = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const dog = [_]core.types.ClassInfo{makeClass("Dog", &.{"Animal"})};
    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "src/animals.zig", .classes = &animal },
        .{ .file = "src/dog.py", .classes = &dog },
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/dog.py", .to_file = "src/animals.zig" },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(arena.allocator(), &fc, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("src/dog.py", edges[0].child_file);
    try std.testing.expectEqualStrings("Dog", edges[0].child_class);
    try std.testing.expectEqualStrings("src/animals.zig", edges[0].parent_file);
    try std.testing.expectEqualStrings("Animal", edges[0].parent_class);
}

test "same-file inheritance no edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const animal = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const dog = [_]core.types.ClassInfo{makeClass("Dog", &.{"Animal"})};
    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "src/animals.py", .classes = &animal },
        .{ .file = "src/animals.py", .classes = &dog },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(arena.allocator(), &fc, &.{});
    try std.testing.expectEqual(@as(usize, 0), edges.len);
}

test "unique project-wide fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // No import edges — Animal defined once, Dog inherits from it
    const animal = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const dog = [_]core.types.ClassInfo{makeClass("Dog", &.{"Animal"})};
    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "src/base.py", .classes = &animal },
        .{ .file = "src/derived.py", .classes = &dog },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(arena.allocator(), &fc, &.{});
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("src/base.py", edges[0].parent_file);
}

test "ambiguous base names no edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Animal defined in two files, no imports — ambiguous
    const animal_a = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const animal_b = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const dog = [_]core.types.ClassInfo{makeClass("Dog", &.{"Animal"})};
    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "src/a.py", .classes = &animal_a },
        .{ .file = "src/b.py", .classes = &animal_b },
        .{ .file = "src/dog.py", .classes = &dog },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(arena.allocator(), &fc, &.{});
    try std.testing.expectEqual(@as(usize, 0), edges.len);
}

test "import preferred over unique fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Animal in two files; dog.py imports a.py — resolves to the imported one
    const animal_a = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const animal_b = [_]core.types.ClassInfo{makeClass("Animal", null)};
    const dog = [_]core.types.ClassInfo{makeClass("Dog", &.{"Animal"})};
    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "src/a.py", .classes = &animal_a },
        .{ .file = "src/b.py", .classes = &animal_b },
        .{ .file = "src/dog.py", .classes = &dog },
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/dog.py", .to_file = "src/a.py" },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(arena.allocator(), &fc, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("src/a.py", edges[0].parent_file);
}

test "rust trait impl inheritance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // impl Drawable for Circle in one file, trait in another
    const drawable = [_]core.types.ClassInfo{
        .{ .name = "Drawable", .kind = .trait },
    };
    const impls = [_]core.types.ClassInfo{
        .{ .name = "Circle", .bases = @constCast(&[_][]const u8{"Drawable"}), .kind = .struct_kind },
    };
    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "src/drawable.rs", .classes = &drawable },
        .{ .file = "src/circle.rs", .classes = &impls },
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "src/circle.rs", .to_file = "src/drawable.rs" },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(arena.allocator(), &fc, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("Circle", edges[0].child_class);
    try std.testing.expectEqualStrings("Drawable", edges[0].parent_class);
}

test "end-to-end: extract classes then build edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Python: base.py defines Animal; app.py imports base and subclasses it
    const base_src = "class Animal:\n    pass\n";
    const app_src = "from base import Animal\nclass Dog(Animal):\n    pass\n";

    const base_classes = try classes_mod.ClassExtractor.extract(a, base_src, "python");
    const app_classes = try classes_mod.ClassExtractor.extract(a, app_src, "python");

    const fc = [_]InheritGraphBuilder.FileClasses{
        .{ .file = "base.py", .classes = base_classes },
        .{ .file = "app.py", .classes = app_classes },
    };
    const imports = [_]core.types.ImportEdge{
        .{ .from_file = "app.py", .to_file = "base.py" },
    };
    const edges = try InheritGraphBuilder.buildInheritEdges(a, &fc, &imports);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqualStrings("Dog", edges[0].child_class);
    try std.testing.expectEqualStrings("Animal", edges[0].parent_class);
}
