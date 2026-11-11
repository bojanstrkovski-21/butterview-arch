// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Drew (justaguylinux)

//! Colors from the GTK theme, read the way GTK apps read them: the
//! `@define-color` lines of the theme's gtk.css. No GTK is linked; it is a
//! text file. GTK4 (libadwaita names) first, else the GTK3 theme named in
//! settings.ini (or, on Xfce, in xfconf). A css that only `@import`s
//! another (KDE's GTK bridge, COSMIC's export) is followed one level.

const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// The six roles the viewer paints with; null where the theme says nothing.
pub const Roles = struct {
    background: ?Rgb = null,
    surface: ?Rgb = null,
    text: ?Rgb = null,
    muted: ?Rgb = null,
    accent: ?Rgb = null,
    border: ?Rgb = null,
};

const Rgba = struct { r: f32, g: f32, b: f32, a: f32 };

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn number(s: []const u8) f32 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len > 0 and t[t.len - 1] == '%') {
        return (std.fmt.parseFloat(f32, t[0 .. t.len - 1]) catch 0) * 2.55;
    }
    return std.fmt.parseFloat(f32, t) catch 0;
}

/// `#rrggbb`, `#rgb`, `rgb(r, g, b)`, `rgba(r, g, b, a)`, `white`, `black`,
/// `transparent`; `@name` is resolved through `defs` one level at a time.
fn parseColor(raw: []const u8, defs: *const std.StringHashMapUnmanaged([]const u8), depth: u8) ?Rgba {
    const v = std.mem.trim(u8, raw, " \t\r\n;");
    if (v.len == 0) return null;
    if (v[0] == '@') {
        if (depth > 8) return null;
        const ref = defs.get(v[1..]) orelse return null;
        return parseColor(ref, defs, depth + 1);
    }
    if (v[0] == '#') {
        const h = v[1..];
        if (h.len == 6 or h.len == 8) {
            var out: [4]u8 = .{ 0, 0, 0, 255 };
            var i: usize = 0;
            while (i + 1 < h.len) : (i += 2) {
                out[i / 2] = ((hexDigit(h[i]) orelse return null) << 4) | (hexDigit(h[i + 1]) orelse return null);
            }
            return .{ .r = @floatFromInt(out[0]), .g = @floatFromInt(out[1]), .b = @floatFromInt(out[2]), .a = @as(f32, @floatFromInt(out[3])) / 255 };
        }
        if (h.len == 3) {
            const r = hexDigit(h[0]) orelse return null;
            const g = hexDigit(h[1]) orelse return null;
            const b = hexDigit(h[2]) orelse return null;
            return .{ .r = @floatFromInt(r * 17), .g = @floatFromInt(g * 17), .b = @floatFromInt(b * 17), .a = 1 };
        }
        return null;
    }
    if (std.mem.startsWith(u8, v, "rgb")) {
        const open = std.mem.findScalar(u8, v, '(') orelse return null;
        const close = std.mem.findScalarLast(u8, v, ')') orelse return null;
        if (close <= open) return null;
        var parts = std.mem.splitScalar(u8, v[open + 1 .. close], ',');
        const r = number(parts.next() orelse return null);
        const g = number(parts.next() orelse return null);
        const b = number(parts.next() orelse return null);
        const a = if (parts.next()) |p| (std.fmt.parseFloat(f32, std.mem.trim(u8, p, " \t")) catch 1) else 1;
        return .{
            .r = std.math.clamp(r, 0, 255),
            .g = std.math.clamp(g, 0, 255),
            .b = std.math.clamp(b, 0, 255),
            .a = std.math.clamp(a, 0, 1),
        };
    }
    if (std.mem.eql(u8, v, "white")) return .{ .r = 255, .g = 255, .b = 255, .a = 1 };
    if (std.mem.eql(u8, v, "black")) return .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    if (std.mem.eql(u8, v, "transparent")) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return null;
}

/// A translucent color as it would look painted over `bg`.
fn over(c: Rgba, bg: Rgb) Rgb {
    const a = std.math.clamp(c.a, 0, 1);
    const mix = struct {
        fn f(fg: f32, back: u8, alpha: f32) u8 {
            return @intFromFloat(std.math.clamp(fg * alpha + @as(f32, @floatFromInt(back)) * (1 - alpha), 0, 255));
        }
    }.f;
    return .{ .r = mix(c.r, bg.r, a), .g = mix(c.g, bg.g, a), .b = mix(c.b, bg.b, a) };
}

fn blend(a: Rgb, b: Rgb, t: f32) Rgb {
    const m = struct {
        fn f(x: u8, y: u8, tt: f32) u8 {
            return @intFromFloat(@as(f32, @floatFromInt(x)) * (1 - tt) + @as(f32, @floatFromInt(y)) * tt);
        }
    }.f;
    return .{ .r = m(a.r, b.r, t), .g = m(a.g, b.g, t), .b = m(a.b, b.b, t) };
}

/// Read every `@define-color name value;` in a gtk.css and map the names
/// both GTK generations use onto the viewer's roles.
pub fn fromCss(gpa: std.mem.Allocator, css: []const u8) Roles {
    var defs: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer defs.deinit(gpa);
    var rest = css;
    while (std.mem.find(u8, rest, "@define-color")) |at| {
        rest = rest[at + "@define-color".len ..];
        const end = std.mem.findScalar(u8, rest, ';') orelse break;
        const line = std.mem.trim(u8, rest[0..end], " \t\r\n");
        rest = rest[end + 1 ..];
        const sp = std.mem.findAny(u8, line, " \t") orelse continue;
        defs.put(gpa, line[0..sp], std.mem.trim(u8, line[sp..], " \t")) catch {};
    }
    if (defs.count() == 0) return .{};

    const get = struct {
        fn f(d: *const std.StringHashMapUnmanaged([]const u8), names: []const []const u8) ?Rgba {
            for (names) |n| {
                if (d.get(n)) |v| {
                    if (parseColor(v, d, 0)) |col| return col;
                }
            }
            return null;
        }
    }.f;

    var roles: Roles = .{};
    const bg_c = get(&defs, &.{ "window_bg_color", "theme_bg_color", "bg_color" }) orelse return .{};
    const bg: Rgb = .{
        .r = @intFromFloat(std.math.clamp(bg_c.r, 0, 255)),
        .g = @intFromFloat(std.math.clamp(bg_c.g, 0, 255)),
        .b = @intFromFloat(std.math.clamp(bg_c.b, 0, 255)),
    };
    roles.background = bg;
    if (get(&defs, &.{ "window_fg_color", "theme_fg_color", "fg_color", "theme_text_color" })) |t| roles.text = over(t, bg);
    if (get(&defs, &.{ "accent_bg_color", "theme_selected_bg_color", "selected_bg_color" })) |a| roles.accent = over(a, bg);
    // a raised surface: what the theme uses for popovers or the header bar
    // when it is not the window color, else the window color nudged
    if (get(&defs, &.{ "popover_bg_color", "headerbar_backdrop_color", "theme_base_color", "base_color" })) |s| {
        const sc = over(s, bg);
        roles.surface = if (sc.r == bg.r and sc.g == bg.g and sc.b == bg.b) blend(bg, roles.text orelse bg, 0.08) else sc;
    } else roles.surface = blend(bg, roles.text orelse bg, 0.08);
    if (get(&defs, &.{ "headerbar_border_color", "borders", "theme_unfocused_bg_color" })) |b| roles.border = over(b, bg) else roles.border = blend(bg, roles.text orelse bg, 0.15);
    if (roles.text) |t| roles.muted = blend(bg, t, 0.45);
    return roles;
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, gpa, .limited(4 * 1024 * 1024)) catch null;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

/// The file named by an `@import` line: `@import url("x.css");`,
/// `@import "x.css";` or `@import 'x.css';`, relative to the importing
/// file's folder unless absolute.
fn importTarget(gpa: std.mem.Allocator, css_path: []const u8, line: []const u8) ?[]u8 {
    var t = std.mem.trim(u8, line, " \t\r");
    if (std.mem.startsWith(u8, t, "url(")) {
        const close = std.mem.findScalar(u8, t, ')') orelse return null;
        t = t[4..close];
    }
    t = std.mem.trim(u8, t, " \t\"'");
    if (t.len == 0) return null;
    if (t[0] == '/') return gpa.dupe(u8, t) catch null;
    const dir = std.fs.path.dirname(css_path) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, t }) catch null;
}

/// The roles a css file gives, following one level of `@import` when the
/// file itself defines no colors (a gtk.css that is only a pointer to
/// where the colors are).
pub fn fromCssFile(gpa: std.mem.Allocator, path: []const u8) Roles {
    const css = readFile(gpa, path) orelse return .{};
    defer gpa.free(css);
    const own = fromCss(gpa, css);
    if (own.background != null) return own;
    var rest: []const u8 = css;
    while (std.mem.find(u8, rest, "@import")) |at| {
        rest = rest[at + "@import".len ..];
        const end = std.mem.findScalar(u8, rest, ';') orelse break;
        const target = importTarget(gpa, path, rest[0..end]) orelse continue;
        defer gpa.free(target);
        rest = rest[end + 1 ..];
        const imported = readFile(gpa, target) orelse continue;
        defer gpa.free(imported);
        const roles = fromCss(gpa, imported);
        if (roles.background != null) return roles;
    }
    return .{};
}

const Gtk3Settings = struct { name: []const u8 = "", prefer_dark: bool = false };

/// `gtk-theme-name` and `gtk-application-prefer-dark-theme` from a GTK3
/// settings.ini; the strings point into `ini`.
fn parseSettingsIni(ini: []const u8) Gtk3Settings {
    var out: Gtk3Settings = .{};
    var lines = std.mem.splitScalar(u8, ini, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        const eq = std.mem.findScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "gtk-theme-name")) out.name = val;
        if (std.mem.eql(u8, key, "gtk-application-prefer-dark-theme")) out.prefer_dark = std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
    }
    return out;
}

/// Xfce keeps the GTK theme in xfconf, not settings.ini: the `ThemeName`
/// property of the xsettings channel. The string points into `xml`.
fn parseXfconfTheme(xml: []const u8) []const u8 {
    const at = std.mem.find(u8, xml, "name=\"ThemeName\"") orelse return "";
    const rest = xml[at..];
    const end = std.mem.findScalar(u8, rest, '>') orelse return "";
    const tag = rest[0..end];
    const v = std.mem.find(u8, tag, "value=\"") orelse return "";
    const val = tag[v + "value=\"".len ..];
    const q = std.mem.findScalar(u8, val, '"') orelse return "";
    return val[0..q];
}

/// The GTK3 theme's gtk.css (gtk-dark.css when dark is preferred and the
/// theme has one), found through settings.ini under `cfg` (`$XDG_CONFIG_HOME`),
/// or on Xfce through xfconf there: the user's themes folders first, then
/// the system's.
pub fn gtk3ThemePath(gpa: std.mem.Allocator, cfg: []const u8, home: []const u8, data_home: []const u8, desktop: []const u8) ?[:0]u8 {
    var settings: Gtk3Settings = .{};
    const ini_path = std.fmt.allocPrint(gpa, "{s}/gtk-3.0/settings.ini", .{cfg}) catch return null;
    defer gpa.free(ini_path);
    const ini = readFile(gpa, ini_path);
    defer if (ini) |i| gpa.free(i);
    if (ini) |i| settings = parseSettingsIni(i);

    // Xfce: xfconf is what its GTK apps follow; a settings.ini beside it
    // is a leftover from some other tool
    var xfconf: ?[]u8 = null;
    defer if (xfconf) |x| gpa.free(x);
    if (std.ascii.indexOfIgnoreCase(desktop, "xfce") != null) {
        const xml_path = std.fmt.allocPrint(gpa, "{s}/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml", .{cfg}) catch return null;
        defer gpa.free(xml_path);
        xfconf = readFile(gpa, xml_path);
        if (xfconf) |x| {
            const n = parseXfconfTheme(x);
            if (n.len > 0) settings.name = n;
        }
    }
    const name = settings.name;
    if (name.len == 0) return null;

    const dirs = [_][]const u8{ home, data_home, "/usr/share" };
    const subs = [_][]const u8{ ".themes", "themes", "themes" };
    const files: [2][]const u8 = if (settings.prefer_dark) .{ "gtk-dark.css", "gtk.css" } else .{ "gtk.css", "gtk-dark.css" };
    for (files) |f| {
        for (dirs, subs) |d, sub| {
            const p = std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}/gtk-3.0/{s}", .{ d, sub, name, f }, 0) catch return null;
            if (exists(p)) return p;
            gpa.free(p);
        }
    }
    return null;
}
