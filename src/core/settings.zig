const std = @import("std");
const Allocator = std.mem.Allocator;

/// All tunable parameters for tdlearn in one place.
/// Previously scattered across many files — now centralized.
/// Cloned per analysis request so worker threads read consistent values.
pub const Settings = struct {
    // ── Graph analysis ──
    /// Maximum cyclomatic complexity threshold
    max_cc: u32 = 25,
    /// Maximum function line count
    max_fn_lines: u32 = 100,
    /// Maximum allowed dependency cycles (0 = no cycles allowed)
    max_cycles: u32 = 0,
    /// Maximum coupling grade (A-F scale, F is worst)
    max_coupling: CouplingGrade = .b,
    /// Whether to detect god files (files with disproportionate responsibilities)
    detect_god_files: bool = true,
    /// Maximum call targets per function (limits ambiguous resolution)
    max_call_targets: u32 = 20,

    // ── Scanner limits ──
    /// Maximum file size to include in scan (kilobytes)
    max_file_size_kb: u64 = 512,
    /// Maximum file size to attempt tree-sitter parsing (kilobytes)
    max_parse_size_kb: u32 = 100,
    /// Directories to exclude from scanning
    exclude_dirs: []const []const u8 = &.{ ".git", "node_modules", "target", "__pycache__", ".zig-cache" },

    // ── Edge rendering ──
    /// Import edge color (RGB)
    import_color: Rgb = .{ .r = 70, .g = 130, .b = 230 },
    /// Call edge color (RGB)
    call_color: Rgb = .{ .r = 230, .g = 140, .b = 40 },
    /// Inherit edge color (RGB)
    inherit_color: Rgb = .{ .r = 80, .g = 200, .b = 120 },

    // ── Layout: Treemap ──
    /// Padding inside directory sections (world units)
    treemap_dir_pad: f64 = 4.0,
    /// Header height for directory labels (world units)
    treemap_dir_header: f64 = 20.0,
    /// Minimum dimension for file rectangles (smaller = hidden)
    treemap_min_rect: f64 = 3.0,
    /// Gutter between top-level sibling sections
    treemap_gutter_root: f64 = 6.0,
    /// Gutter between sibling sections at depth >= 1
    treemap_gutter_inner: f64 = 2.0,

    // ── Viewport ──
    /// Minimum zoom level
    zoom_min: f64 = 0.05,
    /// Maximum zoom level
    zoom_max: f64 = 20.0,
    /// Zoom multiplier per scroll wheel tick
    zoom_scroll_factor: f64 = 1.1,
    /// Padding when fitting content to viewport (world units)
    fit_content_padding: f64 = 30.0,

    // ── Animation / Heat ──
    /// Heat exponential decay half-life in seconds
    heat_half_life: f64 = 3.0,
    /// Duration of the ripple border animation in seconds
    ripple_duration: f64 = 1.5,
    /// Maximum age of trail entries before pruning (seconds)
    trail_max_age: f64 = 60.0,

    // ── Timing / Debounce ──
    /// Debounce window for accumulating file changes before rescan (ms)
    file_change_debounce_ms: u64 = 300,
    /// Debounce window for the filesystem watcher (ms)
    watcher_debounce_ms: u64 = 100,

    // ── Font ──
    /// Scale factor for zoom-proportional text
    font_scale: f32 = 0.15,
    /// UI scale factor for panel/toolbar text
    ui_scale: f32 = 1.0,
    /// Whether to load CJK fallback fonts
    load_cjk_fonts: bool = false,

    // ── Quality thresholds ──
    /// Minimum quality signal to consider "healthy"
    quality_healthy: u32 = 8000,
    /// Quality signal below this is "degraded"
    quality_degraded: u32 = 6000,
    /// Quality signal below this is "critical"
    quality_critical: u32 = 4000,

    // ── Sanitization ──
    pub fn validate(self: *const Settings) !void {
        if (self.max_cc == 0 or self.max_fn_lines == 0 or self.max_file_size_kb == 0 or
            self.max_parse_size_kb == 0 or self.max_call_targets == 0) return error.InvalidSettings;
        if (!std.math.isFinite(self.treemap_min_rect) or self.treemap_min_rect <= 0.0 or
            !std.math.isFinite(self.zoom_min) or self.zoom_min <= 0.0 or
            !std.math.isFinite(self.zoom_max) or self.zoom_max <= self.zoom_min or
            !std.math.isFinite(self.heat_half_life) or self.heat_half_life <= 0.0 or
            !std.math.isFinite(self.font_scale) or self.font_scale <= 0.0 or
            !std.math.isFinite(self.ui_scale) or self.ui_scale <= 0.0) return error.InvalidSettings;
        if (self.quality_critical > self.quality_degraded or self.quality_degraded > self.quality_healthy) {
            return error.InvalidSettings;
        }
    }

    /// Clamp common invalid values into a usable configuration.
    pub fn sanitize(self: *Settings) void {
        if (self.max_cc == 0) self.max_cc = 1;
        if (self.max_fn_lines == 0) self.max_fn_lines = 1;
        if (self.max_file_size_kb == 0) self.max_file_size_kb = 1;
        if (self.max_parse_size_kb == 0) self.max_parse_size_kb = 1;
        if (self.max_call_targets == 0) self.max_call_targets = 1;
        if (!std.math.isFinite(self.treemap_min_rect) or self.treemap_min_rect < 0.1) self.treemap_min_rect = 0.1;
        if (!std.math.isFinite(self.zoom_min) or self.zoom_min <= 0.0) self.zoom_min = 0.01;
        if (!std.math.isFinite(self.zoom_max) or self.zoom_max <= self.zoom_min) self.zoom_max = self.zoom_min * 100.0;
        if (!std.math.isFinite(self.heat_half_life) or self.heat_half_life <= 0.0) self.heat_half_life = 1.0;
        if (!std.math.isFinite(self.font_scale) or self.font_scale <= 0.0) self.font_scale = 0.05;
        if (!std.math.isFinite(self.ui_scale) or self.ui_scale <= 0.0) self.ui_scale = 0.5;
        if (self.quality_degraded > self.quality_healthy) self.quality_degraded = self.quality_healthy;
        if (self.quality_critical > self.quality_degraded) self.quality_critical = self.quality_degraded;
        _ = self.validate() catch {};
    }
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const CouplingGrade = enum {
    a,
    b,
    c,
    d,
    e,
    f,

    pub fn label(self: CouplingGrade) []const u8 {
        return switch (self) {
            .a => "A",
            .b => "B",
            .c => "C",
            .d => "D",
            .e => "E",
            .f => "F",
        };
    }

    pub fn toInt(self: CouplingGrade) u8 {
        return @intFromEnum(self);
    }
};

// ── Layer definitions for architectural rules ──

pub const Layer = struct {
    name: []const u8,
    paths: []const []const u8,
    order: u32,
};

pub const BoundaryRule = struct {
    from: []const u8,
    to: []const u8,
    reason: []const u8,
};

// ── Theme ──

pub const Theme = enum {
    calm,
    dark,
    light,
    midnight,
    solarized,

    pub fn label(self: Theme) []const u8 {
        return switch (self) {
            .calm => "Calm",
            .dark => "Dark",
            .light => "Light",
            .midnight => "Midnight",
            .solarized => "Solarized",
        };
    }
};

// ── Tests ──

test "Settings default values" {
    const s = Settings{};
    try std.testing.expectEqual(@as(u32, 25), s.max_cc);
    try std.testing.expectEqual(@as(u32, 100), s.max_fn_lines);
    try std.testing.expectEqual(@as(u32, 0), s.max_cycles);
    try std.testing.expect(s.detect_god_files);
}

test "Settings sanitize prevents zero values" {
    var s = Settings{
        .max_cc = 0,
        .max_fn_lines = 0,
        .max_file_size_kb = 0,
        .max_parse_size_kb = 0,
        .max_call_targets = 0,
        .treemap_min_rect = 0.0,
        .zoom_min = 0.0,
        .zoom_max = 0.0,
        .heat_half_life = 0.0,
        .font_scale = 0.0,
        .ui_scale = 0.0,
    };
    s.sanitize();
    try std.testing.expect(s.max_cc >= 1);
    try std.testing.expect(s.max_fn_lines >= 1);
    try std.testing.expect(s.max_file_size_kb >= 1);
    try std.testing.expect(s.treemap_min_rect >= 0.1);
    try std.testing.expect(s.zoom_min > 0.0);
    try std.testing.expect(s.zoom_max > s.zoom_min);
    try std.testing.expect(s.heat_half_life > 0.0);
    try std.testing.expect(s.font_scale > 0.0);
    try std.testing.expect(s.ui_scale > 0.0);
}

test "Settings validate rejects non-finite values" {
    var s = Settings{};
    s.zoom_min = std.math.nan(f64);
    try std.testing.expectError(error.InvalidSettings, s.validate());
    s = Settings{};
    s.quality_critical = 7000;
    s.quality_degraded = 6000;
    try std.testing.expectError(error.InvalidSettings, s.validate());
    s.sanitize();
    try s.validate();
}

test "CouplingGrade label" {
    try std.testing.expectEqualStrings("A", CouplingGrade.a.label());
    try std.testing.expectEqualStrings("F", CouplingGrade.f.label());
}

test "Theme label" {
    try std.testing.expectEqualStrings("Dark", Theme.dark.label());
    try std.testing.expectEqualStrings("Light", Theme.light.label());
}
