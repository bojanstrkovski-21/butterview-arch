// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Drew (justaguylinux)

//! butterview: a small image viewer.
//!
//! The image, a strip of the folder's thumbnails across the top, and a status
//! line. SDL3 opens the window, decodes the files and draws; this program is
//! the part in between: which image, how big, where. Decoding happens on
//! worker threads, so moving through a folder never waits on a file.
//!
//!   butterview [file-or-folder]
//!
//! Without a screen (for checking a change):
//!   butterview --shot out.png [--size 1280x800] [--goto N] [--zoom 2] path

const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_image/SDL_image.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
    @cInclude("turbojpeg.h");
    @cInclude("malloc.h");
    @cInclude("locale.h");
    @cInclude("unistd.h");
});

const exif = @import("exif.zig");
const gif = @import("gif.zig");
const theme = @import("theme.zig");
const portal = @import("portal.zig");
// -Dversion=... at build time; the package build passes the release tag.
const version = @import("build_options").version;

const gpa = std.heap.c_allocator;

// ================= colors =================

const Rgb = struct { r: u8, g: u8, b: u8 };

/// Six roles. Anything that themes the desktop can write them to
/// $XDG_CONFIG_HOME/butterview/colors.conf; without that file the GTK
/// theme is read; without one the desktop is asked, over the portal,
/// whether it is dark or light and which accent it uses, and one of the
/// two built-in sets is painted with that accent.
const Palette = struct {
    background: Rgb = .{ .r = 0x13, .g = 0x15, .b = 0x20 },
    surface: Rgb = .{ .r = 0x1e, .g = 0x22, .b = 0x33 },
    text: Rgb = .{ .r = 0xd2, .g = 0xc9, .b = 0xbc },
    muted: Rgb = .{ .r = 0x60, .g = 0x64, .b = 0x76 },
    accent: Rgb = .{ .r = 0x69, .g = 0xa5, .b = 0xd3 },
    border: Rgb = .{ .r = 0x2a, .g = 0x34, .b = 0x3c },

    const dark: Palette = .{};
    const light: Palette = .{
        .background = .{ .r = 0xf2, .g = 0xf2, .b = 0xf2 },
        .surface = .{ .r = 0xfb, .g = 0xfb, .b = 0xfb },
        .text = .{ .r = 0x2e, .g = 0x34, .b = 0x36 },
        .muted = .{ .r = 0x8c, .g = 0x8f, .b = 0x94 },
        .accent = .{ .r = 0x35, .g = 0x84, .b = 0xe4 },
        .border = .{ .r = 0xd5, .g = 0xd5, .b = 0xd5 },
    };

    fn eql(a: Palette, b: Palette) bool {
        inline for (std.meta.fields(Palette)) |f| {
            const x = @field(a, f.name);
            const y = @field(b, f.name);
            if (x.r != y.r or x.g != y.g or x.b != y.b) return false;
        }
        return true;
    }

    /// The built-in set the desktop's answer picks, with its accent.
    fn fromAppearance(ap: portal.Appearance) Palette {
        var pal: Palette = if (ap.scheme == .light) light else dark;
        if (ap.accent) |a| pal.accent = .{ .r = a.r, .g = a.g, .b = a.b };
        return pal;
    }
};

/// $XDG_CONFIG_HOME, or ~/.config. Looked up once.
var config_dir: ?[]const u8 = null;
fn configDir() []const u8 {
    if (config_dir) |d| return d;
    const d = blk: {
        if (c.SDL_getenv("XDG_CONFIG_HOME")) |x| {
            const xs = std.mem.span(x);
            if (xs.len > 0 and xs[0] == '/') break :blk gpa.dupe(u8, xs) catch "";
        }
        const home = if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else "";
        break :blk std.fmt.allocPrint(gpa, "{s}/.config", .{home}) catch "";
    };
    config_dir = d;
    return d;
}

fn parseHex(s: []const u8) ?Rgb {
    const t = std.mem.trim(u8, s, " \t\r\"'");
    if (t.len != 7 or t[0] != '#') return null;
    const v = std.fmt.parseInt(u32, t[1..], 16) catch return null;
    return .{ .r = @intCast((v >> 16) & 0xff), .g = @intCast((v >> 8) & 0xff), .b = @intCast(v & 0xff) };
}

/// key = value lines; `names` maps a key in the file to a palette role.
fn loadPaletteFile(path: [:0]const u8, pal: *Palette, names: []const [2][]const u8) bool {
    var size: usize = 0;
    const raw = c.SDL_LoadFile(path.ptr, &size) orelse return false;
    defer c.SDL_free(raw);
    const data = @as([*]const u8, @ptrCast(raw))[0..size];
    var lines = std.mem.splitScalar(u8, data, '\n');
    var found: usize = 0;
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const rgb = parseHex(line[eq + 1 ..]) orelse continue;
        for (names) |n| {
            if (!std.mem.eql(u8, key, n[0])) continue;
            inline for (std.meta.fields(Palette)) |f| {
                if (std.mem.eql(u8, n[1], f.name)) {
                    @field(pal, f.name) = rgb;
                    found += 1;
                }
            }
        }
    }
    // a file that names none of the roles says nothing
    return found > 0;
}

/// The shell line for the `wallpaper =` setting: the command with the
/// image's path, "$1", added on the end, or as written when it already
/// says where the path goes (`swaybg -i "$1" &`).
fn wallpaperScript(path: [:0]const u8) ?[:0]u8 {
    var size: usize = 0;
    const raw = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(raw);
    var lines = std.mem.splitScalar(u8, @as([*]const u8, @ptrCast(raw))[0..size], '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "wallpaper")) continue;
        const cmd = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (cmd.len == 0) return null;
        if (std.mem.find(u8, cmd, "$1") != null) return gpa.dupeZ(u8, cmd) catch null;
        return std.fmt.allocPrintSentinel(gpa, "{s} \"$1\"", .{cmd}, 0) catch null;
    }
    return null;
}

// ================= files =================

const exts = [_][]const u8{ "png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "avif", "jxl", "svg", "qoi", "tga" };

fn isImage(name: []const u8) bool {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return false;
    const ext = name[dot + 1 ..];
    for (exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// What the clipboard calls a file of this name; null for the formats
/// that have no type other programs would know.
fn clipType(name: []const u8) ?[:0]const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return null;
    const ext = name[dot + 1 ..];
    const types = [_]struct { []const u8, [:0]const u8 }{
        .{ "png", "image/png" },   .{ "jpg", "image/jpeg" },    .{ "jpeg", "image/jpeg" },
        .{ "webp", "image/webp" }, .{ "gif", "image/gif" },     .{ "bmp", "image/bmp" },
        .{ "tif", "image/tiff" },  .{ "tiff", "image/tiff" },   .{ "avif", "image/avif" },
        .{ "jxl", "image/jxl" },   .{ "svg", "image/svg+xml" },
    };
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    }
    return null;
}

/// "img2" before "img10", and case does not matter.
/// Hidden files and folders (dot-names) listed or not. `.` or Ctrl-h
/// flips it; remembered between runs.
var show_hidden: bool = false;

/// How the folder is ordered: by name (naturally: img2 before img10),
/// newest first, or oldest first. `s` cycles; remembered between runs.
const SortMode = enum {
    name,
    newest,
    oldest,
    fn label(m: SortMode) []const u8 {
        return switch (m) {
            .name => "by name",
            .newest => "newest first",
            .oldest => "oldest first",
        };
    }
    fn key(m: SortMode) []const u8 {
        return switch (m) {
            .name => "name",
            .newest => "newest",
            .oldest => "oldest",
        };
    }
};

fn itemLess(mode: SortMode, a: Item, b: Item) bool {
    switch (mode) {
        .name => {},
        .newest => if (a.mtime != b.mtime) return a.mtime > b.mtime,
        .oldest => if (a.mtime != b.mtime) return a.mtime < b.mtime,
    }
    return naturalLess({}, a, b);
}

fn naturalLess(_: void, a: Item, b: Item) bool {
    const x = a.name;
    const y = b.name;
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        if (std.ascii.isDigit(x[i]) and std.ascii.isDigit(y[j])) {
            var ni: u64 = 0;
            var nj: u64 = 0;
            while (i < x.len and std.ascii.isDigit(x[i])) : (i += 1) ni = ni *% 10 +% (x[i] - '0');
            while (j < y.len and std.ascii.isDigit(y[j])) : (j += 1) nj = nj *% 10 +% (y[j] - '0');
            if (ni != nj) return ni < nj;
            continue;
        }
        const ca = std.ascii.toLower(x[i]);
        const cb = std.ascii.toLower(y[j]);
        if (ca != cb) return ca < cb;
        i += 1;
        j += 1;
    }
    return x.len < y.len;
}

const ThumbState = enum(u8) { none, loading, ready, failed };

const Item = struct {
    id: u32,
    /// Absolute path. Never freed while workers run, so a job may hold it.
    path: [:0]const u8,
    name: []const u8,
    /// when the file was last written (SDL time), for sorting by date
    mtime: i64 = 0,
    thumb: ?*c.SDL_Texture = null,
    thumb_w: f32 = 0,
    thumb_h: f32 = 0,
    thumb_state: ThumbState = .none,
};

// ================= decoding (worker threads) =================

/// What the head of a JPEG says about itself; empty for anything else.
fn readExif(path: [:0]const u8) exif.Info {
    const dot = std.mem.findScalarLast(u8, path, '.') orelse return .{};
    const ext = path[dot + 1 ..];
    if (!std.ascii.eqlIgnoreCase(ext, "jpg") and !std.ascii.eqlIgnoreCase(ext, "jpeg")) return .{};
    const io = c.SDL_IOFromFile(path.ptr, "rb") orelse return .{};
    defer _ = c.SDL_CloseIO(io);
    var buf: [131072]u8 = undefined;
    const n = c.SDL_ReadIO(io, &buf, buf.len);
    return exif.parse(buf[0..n]);
}

/// A copy of `s` turned the way the camera meant. Takes ownership of `s`.
fn orient(s: *c.SDL_Surface, o: u8) *c.SDL_Surface {
    if (o <= 1 or o > 8) return s;
    const w: usize = @intCast(s.w);
    const h: usize = @intCast(s.h);
    const swap = o >= 5;
    const out = c.SDL_CreateSurface(@intCast(if (swap) h else w), @intCast(if (swap) w else h), c.SDL_PIXELFORMAT_RGBA32) orelse return s;
    const sp: [*]const u8 = @ptrCast(s.pixels.?);
    const dp: [*]u8 = @ptrCast(out.*.pixels.?);
    const spitch: usize = @intCast(s.pitch);
    const dpitch: usize = @intCast(out.*.pitch);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const srow: [*]const u32 = @ptrCast(@alignCast(sp + y * spitch));
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var dx: usize = x;
            var dy: usize = y;
            switch (o) {
                2 => dx = w - 1 - x,
                3 => {
                    dx = w - 1 - x;
                    dy = h - 1 - y;
                },
                4 => dy = h - 1 - y,
                5 => {
                    dx = y;
                    dy = x;
                },
                6 => {
                    dx = h - 1 - y;
                    dy = x;
                },
                7 => {
                    dx = h - 1 - y;
                    dy = w - 1 - x;
                },
                8 => {
                    dx = y;
                    dy = w - 1 - x;
                },
                else => {},
            }
            const drow: [*]u32 = @ptrCast(@alignCast(dp + dy * dpitch));
            drow[dx] = srow[x];
        }
    }
    c.SDL_DestroySurface(s);
    return out;
}

/// Scale down to fit inside max_w x max_h, halving first so a big photo
/// does not turn to sand. Takes ownership of `s`; never scales up.
fn shrink(s: *c.SDL_Surface, max_w: c_int, max_h: c_int) *c.SDL_Surface {
    var cur = s;
    while (cur.w >= max_w * 4 and cur.h >= max_h * 4) {
        const half = c.SDL_ScaleSurface(cur, @divTrunc(cur.w, 2), @divTrunc(cur.h, 2), c.SDL_SCALEMODE_LINEAR) orelse break;
        c.SDL_DestroySurface(cur);
        cur = half;
    }
    if (cur.w <= max_w and cur.h <= max_h) return cur;
    const fw = @as(f32, @floatFromInt(max_w)) / @as(f32, @floatFromInt(cur.w));
    const fh = @as(f32, @floatFromInt(max_h)) / @as(f32, @floatFromInt(cur.h));
    const f = @min(fw, fh);
    const nw: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(cur.w)) * f)));
    const nh: c_int = @max(1, @as(c_int, @intFromFloat(@as(f32, @floatFromInt(cur.h)) * f)));
    const out = c.SDL_ScaleSurface(cur, nw, nh, c.SDL_SCALEMODE_LINEAR) orelse return cur;
    c.SDL_DestroySurface(cur);
    return out;
}

const Decoded = struct {
    surface: *c.SDL_Surface,
    /// The image's real size, which the surface may be smaller than.
    src_w: c_int,
    src_h: c_int,
};

fn isJpeg(path: []const u8) bool {
    const dot = std.mem.findScalarLast(u8, path, '.') orelse return false;
    const ext = path[dot + 1 ..];
    return std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg");
}

/// A JPEG, decoded no larger than it has to be. libjpeg-turbo can hand back
/// a half, quarter or eighth-size picture for a fraction of the work, which
/// is the difference between a thumbnail of a camera photo taking 3 ms and
/// taking 60. `want` is the long side the caller needs.
fn decodeJpeg(path: [:0]const u8, want: c_int) ?Decoded {
    var size: usize = 0;
    const raw = c.SDL_LoadFile(path.ptr, &size) orelse return null;
    defer c.SDL_free(raw);
    const tj = c.tjInitDecompress() orelse return null;
    defer _ = c.tjDestroy(tj);
    var w: c_int = 0;
    var h: c_int = 0;
    var subsamp: c_int = 0;
    var space: c_int = 0;
    if (c.tjDecompressHeader3(tj, @ptrCast(raw), @intCast(size), &w, &h, &subsamp, &space) != 0) return null;

    // the smallest scale whose long side still covers what is wanted
    var out_w = w;
    var out_h = h;
    var n: c_int = 0;
    const factors = c.tjGetScalingFactors(&n);
    if (factors != null) {
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const f = factors[k];
            if (f.num > f.denom) continue;
            const sw = @divTrunc(w * f.num + f.denom - 1, f.denom);
            const sh = @divTrunc(h * f.num + f.denom - 1, f.denom);
            if (@max(sw, sh) >= want and sw < out_w) {
                out_w = sw;
                out_h = sh;
            }
        }
    }
    const surf = c.SDL_CreateSurface(out_w, out_h, c.SDL_PIXELFORMAT_RGBA32) orelse return null;
    if (c.tjDecompress2(tj, @ptrCast(raw), @intCast(size), @ptrCast(surf.*.pixels), out_w, surf.*.pitch, out_h, c.TJPF_RGBA, 0) != 0) {
        c.SDL_DestroySurface(surf);
        return null;
    }
    return .{ .surface = surf, .src_w = w, .src_h = h };
}

/// Decode a file into an upright RGBA surface whose long side is at least
/// `want` (or the whole image, when it is smaller than that).
fn decode(path: [:0]const u8, want: c_int) ?Decoded {
    var d: Decoded = undefined;
    const jpeg = isJpeg(path);
    if (jpeg) {
        if (decodeJpeg(path, want)) |ok| {
            d = ok;
        } else return decodeAny(path);
    } else return decodeAny(path);
    // turned the way the camera meant; a quarter turn swaps the sizes
    const o = readExif(path).orientation;
    d.surface = orient(d.surface, o);
    if (o >= 5) std.mem.swap(c_int, &d.src_w, &d.src_h);
    return d;
}

/// Everything SDL_image reads, at full size (and JPEGs libjpeg-turbo's
/// quick path would not take, CMYK among them).
fn decodeAny(path: [:0]const u8) ?Decoded {
    const raw = c.IMG_Load(path.ptr) orelse return null;
    const rgba = c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_RGBA32) orelse {
        c.SDL_DestroySurface(raw);
        return null;
    };
    c.SDL_DestroySurface(raw);
    const s: *c.SDL_Surface = if (isJpeg(path)) orient(rgba, readExif(path).orientation) else rgba;
    return .{ .surface = s, .src_w = s.w, .src_h = s.h };
}

fn isGif(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    return std.ascii.eqlIgnoreCase(name[dot + 1 ..], "gif");
}

/// A playing GIF: a thread decodes frames a few ahead of what is shown,
/// into a small ring, so a long animation costs a handful of frames of
/// memory rather than all of them, and the first frame is there at once.
const Anim = struct {
    mutex: *c.SDL_Mutex,
    cond: *c.SDL_Condition,
    thread: ?*c.SDL_Thread = null,
    file: *anyopaque,
    dec: gif.Decoder,
    ring: [3][]u8,
    delays: [3]u32 = @splat(0),
    head: usize = 0,
    count: usize = 0,
    produced: usize = 0,
    quit: bool = false,
    /// Only one frame in the file: nothing to play.
    single: bool = false,

    fn create(path: [:0]const u8) ?*Anim {
        var n: usize = 0;
        const file = c.SDL_LoadFile(path.ptr, &n) orelse return null;
        const bytes = @as([*]u8, @ptrCast(file))[0..n];
        const dec = gif.Decoder.init(gpa, bytes) catch {
            c.SDL_free(file);
            return null;
        };
        const a = gpa.create(Anim) catch {
            c.SDL_free(file);
            return null;
        };
        a.* = .{ .mutex = c.SDL_CreateMutex().?, .cond = c.SDL_CreateCondition().?, .file = file, .dec = dec, .ring = undefined };
        for (&a.ring) |*r| r.* = gpa.alloc(u8, a.dec.canvas.len) catch unreachable;
        // the first frame now, so the picture is there the moment the
        // slot is filled; the thread takes over from the second
        if (!a.decodeOne()) {
            a.destroy();
            return null;
        }
        a.thread = c.SDL_CreateThreadRuntime(animWorker, "gif", a, null, null);
        return a;
    }

    fn destroy(a: *Anim) void {
        c.SDL_LockMutex(a.mutex);
        a.quit = true;
        _ = c.SDL_BroadcastCondition(a.cond);
        c.SDL_UnlockMutex(a.mutex);
        if (a.thread) |t| c.SDL_WaitThread(t, null);
        c.SDL_DestroyCondition(a.cond);
        c.SDL_DestroyMutex(a.mutex);
        for (a.ring) |r| gpa.free(r);
        a.dec.deinit();
        c.SDL_free(a.file);
        gpa.destroy(a);
    }

    /// Decode the next frame (looping) into the free ring slot. False
    /// when the file holds a single frame, or nothing readable at all.
    fn decodeOne(a: *Anim) bool {
        const slot = (a.head + a.count) % a.ring.len;
        const fr = a.dec.next() orelse blk: {
            if (a.produced <= 1) return false;
            a.dec.rewind();
            break :blk a.dec.next() orelse return false;
        };
        @memcpy(a.ring[slot], a.dec.canvas);
        a.delays[slot] = fr.delay;
        c.SDL_LockMutex(a.mutex);
        a.count += 1;
        a.produced += 1;
        c.SDL_UnlockMutex(a.mutex);
        return true;
    }

    /// The oldest ready frame, to copy into the texture; null when the
    /// thread has not caught up.
    fn peek(a: *Anim) ?usize {
        c.SDL_LockMutex(a.mutex);
        defer c.SDL_UnlockMutex(a.mutex);
        return if (a.count > 0) a.head else null;
    }

    fn release(a: *Anim) void {
        c.SDL_LockMutex(a.mutex);
        a.head = (a.head + 1) % a.ring.len;
        a.count -= 1;
        _ = c.SDL_BroadcastCondition(a.cond);
        c.SDL_UnlockMutex(a.mutex);
    }
};

fn animWorker(data: ?*anyopaque) callconv(.c) c_int {
    const a: *Anim = @ptrCast(@alignCast(data.?));
    while (true) {
        c.SDL_LockMutex(a.mutex);
        while (a.count == a.ring.len and !a.quit) _ = c.SDL_WaitCondition(a.cond, a.mutex);
        if (a.quit) {
            c.SDL_UnlockMutex(a.mutex);
            return 0;
        }
        c.SDL_UnlockMutex(a.mutex);
        if (!a.decodeOne()) {
            c.SDL_LockMutex(a.mutex);
            a.single = true;
            c.SDL_UnlockMutex(a.mutex);
            return 0;
        }
    }
}

const JobKind = enum { full, thumb };

const Done = struct {
    kind: JobKind,
    id: u32,
    surface: ?*c.SDL_Surface,
    /// Size of the file's image before any shrinking (full only).
    src_w: c_int = 0,
    src_h: c_int = 0,
    /// A GIF with frames to play; `surface` is then null.
    anim: ?*Anim = null,
};

/// A full image to decode, no larger than `limit` pixels on its long side.
const Want = struct { id: u32 = 0, limit: c_int = 0 };

const thumb_px_h = 144;
const thumb_px_w = 256;

/// Everything the workers share with the main thread, under one mutex.
const Shared = struct {
    mutex: *c.SDL_Mutex,
    cond: *c.SDL_Condition,
    quit: bool = false,
    /// What the main thread would like next: these ids, in this order.
    want_full: [4]Want = @splat(.{}),
    want_full_n: usize = 0,
    /// Thumbnails still to make, nearest the current image first.
    want_thumb: std.ArrayList(u32) = .empty,
    /// id -> path, for the workers. Freed once the id is gone and idle.
    paths: std.AutoHashMapUnmanaged(u32, [:0]const u8) = .empty,
    /// Being decoded right now, so two workers do not take the same file.
    busy_full: [8]u32 = @splat(0),
    busy_thumb: [8]u32 = @splat(0),
    /// Portal threads watch this and leave before SDL_Quit.
    stop: std.atomic.Value(bool) = .init(false),
    done: std.ArrayList(Done) = .empty,
    max_texture: c_int = 8192,
    wake_event: u32 = 0,
};

fn takeJob(sh: *Shared) ?struct { kind: JobKind, id: u32, limit: c_int = 0 } {
    var k: usize = 0;
    outer: while (k < sh.want_full_n) : (k += 1) {
        const id = sh.want_full[k].id;
        const limit = sh.want_full[k].limit;
        for (sh.busy_full) |b| {
            if (b == id) continue :outer;
        }
        for (&sh.busy_full) |*b| {
            if (b.* == 0) {
                b.* = id;
                break;
            }
        }
        // drop it from the wish list; the result or a new wish replaces it
        var m = k;
        while (m + 1 < sh.want_full_n) : (m += 1) sh.want_full[m] = sh.want_full[m + 1];
        sh.want_full_n -= 1;
        return .{ .kind = .full, .id = id, .limit = limit };
    }
    if (sh.want_thumb.items.len > 0) {
        const id = sh.want_thumb.orderedRemove(0);
        for (&sh.busy_thumb) |*b| {
            if (b.* == 0) {
                b.* = id;
                break;
            }
        }
        return .{ .kind = .thumb, .id = id };
    }
    return null;
}

fn worker(data: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(data.?));
    while (true) {
        c.SDL_LockMutex(sh.mutex);
        var job = takeJob(sh);
        while (job == null and !sh.quit) {
            _ = c.SDL_WaitCondition(sh.cond, sh.mutex);
            job = takeJob(sh);
        }
        if (sh.quit) {
            c.SDL_UnlockMutex(sh.mutex);
            return 0;
        }
        const j = job.?;
        const path = sh.paths.get(j.id);
        c.SDL_UnlockMutex(sh.mutex);

        var out: Done = .{ .kind = j.kind, .id = j.id, .surface = null };
        if (path) |p| {
            const want: c_int = if (j.kind == .full) j.limit else thumb_px_w;
            if (j.kind == .full and isGif(p)) out.anim = Anim.create(p);
            if (out.anim) |an| {
                out.src_w = an.dec.w;
                out.src_h = an.dec.h;
            } else if (decode(p, want)) |d| {
                out.src_w = d.src_w;
                out.src_h = d.src_h;
                out.surface = switch (j.kind) {
                    .full => shrink(d.surface, j.limit, j.limit),
                    .thumb => shrink(d.surface, thumb_px_w, thumb_px_h),
                };
            }
        }

        c.SDL_LockMutex(sh.mutex);
        if (j.kind == .full) {
            for (&sh.busy_full) |*b| {
                if (b.* == j.id) b.* = 0;
            }
        } else {
            for (&sh.busy_thumb) |*b| {
                if (b.* == j.id) b.* = 0;
            }
        }
        sh.done.append(gpa, out) catch {
            if (out.surface) |s| c.SDL_DestroySurface(s);
            if (out.anim) |an| an.destroy();
        };
        c.SDL_UnlockMutex(sh.mutex);

        var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        ev.type = sh.wake_event;
        _ = c.SDL_PushEvent(&ev);
    }
}

// ================= the viewer =================

const Full = struct {
    id: u32 = 0,
    tex: ?*c.SDL_Texture = null,
    /// The file's real size, which the texture may be smaller than.
    w: f32 = 0,
    h: f32 = 0,
    /// The texture's own width, and whether it holds every pixel of the file.
    tex_w: f32 = 0,
    whole: bool = false,
    failed: bool = false,
    /// A playing GIF: `tex` is streamed, and the next frame is due at
    /// `next_at` (SDL ticks).
    anim: ?*Anim = null,
    next_at: u64 = 0,
    /// The decoder has stopped and the ring is empty. Do not keep waking.
    settled: bool = false,

    fn animated(f: *const Full) bool {
        return f.anim != null;
    }

    fn playing(f: *const Full) bool {
        return f.anim != null and !f.settled;
    }

    /// Let go of the textures and become empty.
    fn clear(f: *Full) void {
        if (f.anim) |an| an.destroy();
        if (f.tex) |t| c.SDL_DestroyTexture(t);
        f.* = .{};
    }

    /// Put up whichever frame is due at `now`, true if it changed.
    fn advance(f: *Full, now: u64) bool {
        const an = f.anim orelse return false;
        if (f.settled or now < f.next_at) return false;
        const slot = an.peek() orelse {
            c.SDL_LockMutex(an.mutex);
            const done = an.single;
            c.SDL_UnlockMutex(an.mutex);
            if (done) {
                f.settled = true;
                return false;
            }
            // the decoder is behind; look again shortly
            f.next_at = now + 5;
            return false;
        };
        _ = c.SDL_UpdateTexture(f.tex, null, an.ring[slot].ptr, @as(c_int, an.dec.w) * 4);
        f.next_at = now + an.delays[slot];
        an.release();
        return true;
    }
};

const HelpRow = struct { key: []const u8 = "", what: []const u8 = "" };

/// The keys, for `?`, as ghee lists them: groups under a heading (a row
/// with no key), in two columns. The --help text says the same.
const help_left = [_]HelpRow{
    .{ .what = "Looking" },
    .{ .key = "wheel  + -", .what = "zoom" },
    .{ .key = "0  1", .what = "fit, actual size" },
    .{ .key = "double-click", .what = "fit or 100%" },
    .{ .key = "drag", .what = "pan" },
    .{ .key = "f  F11", .what = "full screen; Esc leaves it" },
    .{ .key = "t", .what = "thumbnail strip" },
    .{ .key = "i", .what = "image info" },
    .{},
    .{ .what = "Changing" },
    .{ .key = "r  Shift-r", .what = "rotate right, left" },
    .{ .key = "x", .what = "crop; Enter saves, Esc cancels" },
    .{ .key = "Ctrl-s", .what = "save a copy" },
    .{ .key = "y  Ctrl-c", .what = "copy to the clipboard" },
    .{ .key = "w", .what = "set as wallpaper" },
    .{ .key = "Del", .what = "move to the trash" },
};
const help_right = [_]HelpRow{
    .{ .what = "Moving" },
    .{ .key = "Left  Right  Space", .what = "previous, next" },
    .{ .key = "Home  End", .what = "first, last" },
    .{ .key = "PgUp  PgDn", .what = "ten at a time" },
    .{ .key = "Backspace  Enter", .what = "folder view; + - size it" },
    .{ .key = "s", .what = "sort: name, newest, oldest" },
    .{ .key = ".  Ctrl-h", .what = "hidden files" },
    .{ .key = "o", .what = "open a folder" },
    .{},
    .{ .what = "Other" },
    .{ .key = "right-click", .what = "all of this as a menu" },
    .{ .key = "?  F1", .what = "this list" },
    .{ .key = "q", .what = "quit" },
};
const help_rows = help_left ++ help_right;

const InfoRow = struct { label: ?*c.SDL_Texture = null, value: ?*c.SDL_Texture = null };

const Action = enum { fullscreen, fit, actual, rotate_cw, rotate_ccw, crop, save, info, thumbs, copy, wallpaper, browse, open, folder, trash };

const MenuItem = struct { label: []const u8, hint: []const u8, action: Action };

/// The right-click menu: everything the keys do, for the hand on the mouse.
const menu_items = [_]MenuItem{
    .{ .label = "Full screen", .hint = "f", .action = .fullscreen },
    .{ .label = "Fit to window", .hint = "0", .action = .fit },
    .{ .label = "Actual size", .hint = "1", .action = .actual },
    .{ .label = "Rotate right", .hint = "r", .action = .rotate_cw },
    .{ .label = "Rotate left", .hint = "Shift-r", .action = .rotate_ccw },
    .{ .label = "Crop", .hint = "x", .action = .crop },
    .{ .label = "Save a copy", .hint = "Ctrl-s", .action = .save },
    .{ .label = "Image info", .hint = "i", .action = .info },
    .{ .label = "Thumbnails", .hint = "t", .action = .thumbs },
    .{ .label = "Copy", .hint = "y", .action = .copy },
    .{ .label = "Set as wallpaper", .hint = "w", .action = .wallpaper },
    .{ .label = "Folder view", .hint = "Backspace", .action = .browse },
    .{ .label = "Open a folder…", .hint = "o", .action = .open },
    .{ .label = "Show in folder", .hint = "", .action = .folder },
    .{ .label = "Move to trash", .hint = "Del", .action = .trash },
};

const Menu = struct {
    x: f32,
    y: f32,
    w: f32 = 0,
    row_h: f32,
    hover: ?usize = null,
    labels: [menu_items.len]?*c.SDL_Texture = @splat(null),
    hints: [menu_items.len]?*c.SDL_Texture = @splat(null),
};

/// `path` with $HOME as `~`, for showing. A slice of `path` or of a
/// small static buffer.
fn tilde(path: []const u8) []const u8 {
    const S = struct {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
    };
    const home = if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/')) {
        const rest = path[home.len..];
        if (rest.len + 1 > S.buf.len) return path;
        S.buf[0] = '~';
        @memcpy(S.buf[1 .. 1 + rest.len], rest);
        return S.buf[0 .. 1 + rest.len];
    }
    return path;
}

/// qimgv's folder view: the folders as a tree down the left, with how
/// many images each holds, and the folder's thumbnails in a grid on the
/// right. The tree is a flat list in display order: expanding a folder
/// inserts its subfolders after it, collapsing removes everything deeper.
const FolderView = struct {
    const Node = struct {
        path: []u8,
        name: []u8,
        depth: u16,
        expanded: bool = false,
        /// images directly inside (counting stops at count_cap)
        count: usize = 0,
        /// false once expanding found no subfolders
        has_sub: bool = true,
    };
    const count_cap: usize = 500;
    /// entries looked at per folder when counting, so a huge folder of
    /// something else does not stall the tree
    const scan_cap: usize = 4000;

    nodes: std.ArrayList(Node) = .empty,
    sel: usize = 0,
    tree_scroll: usize = 0,
    focus: enum { tree, grid } = .tree,
    grid_sel: usize = 0,
    grid_scroll: usize = 0,
    // laid out by drawView, for the mouse and for scrolling
    pane_w: f32 = 0,
    row_h: f32 = 24,
    tree_y: f32 = 0,
    tree_rows: usize = 1,
    grid: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    cell_w: f32 = 1,
    cell_h: f32 = 1,
    cols: usize = 1,
    grid_rows: usize = 1,

    /// The roots: home, then `/`; the path to `dir` expanded and selected.
    fn init(dir: []const u8) ?FolderView {
        var v: FolderView = .{};
        const home = if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else "";
        if (home.len > 1) v.addNode(v.nodes.items.len, home, "~", 0) catch return null;
        v.addNode(v.nodes.items.len, "/", "/", 0) catch return null;
        v.reveal(dir);
        return v;
    }

    fn deinit(v: *FolderView) void {
        for (v.nodes.items) |n| {
            gpa.free(n.path);
            gpa.free(n.name);
        }
        v.nodes.deinit(gpa);
    }

    fn addNode(v: *FolderView, at: usize, path: []const u8, name: []const u8, depth: u16) !void {
        const pth = try gpa.dupe(u8, path);
        errdefer gpa.free(pth);
        const nm = try gpa.dupe(u8, name);
        errdefer gpa.free(nm);
        try v.nodes.insert(gpa, at, .{ .path = pth, .name = nm, .depth = depth, .count = countImages(pth).images });
    }

    /// Expand `dir`'s ancestors from a root and stand on it.
    fn reveal(v: *FolderView, dir: []const u8) void {
        var root: usize = v.nodes.items.len;
        for (v.nodes.items, 0..) |n, i| {
            if (n.depth == 0 and std.mem.startsWith(u8, dir, n.path) and (dir.len == n.path.len or dir[n.path.len] == '/' or std.mem.eql(u8, n.path, "/"))) {
                root = i;
                break;
            }
        }
        if (root == v.nodes.items.len) return;
        var i = root;
        while (!std.mem.eql(u8, v.nodes.items[i].path, dir)) {
            v.expand(i);
            // the child that is the next step down
            var next: ?usize = null;
            var k = i + 1;
            while (k < v.nodes.items.len and v.nodes.items[k].depth > v.nodes.items[i].depth) : (k += 1) {
                const np = v.nodes.items[k].path;
                if (v.nodes.items[k].depth == v.nodes.items[i].depth + 1 and std.mem.startsWith(u8, dir, np) and (dir.len == np.len or dir[np.len] == '/')) next = k;
            }
            if (next == null) {
                // a hidden folder on the way (the tree leaves those out):
                // it goes in all the same, so the path to here is shown
                const here = v.nodes.items[i].path;
                const rest = if (std.mem.eql(u8, here, "/")) dir[1..] else dir[here.len + 1 ..];
                const end = std.mem.findScalar(u8, rest, '/') orelse rest.len;
                const child = dir[0 .. dir.len - rest.len + end];
                v.nodes.items[i].expanded = true;
                v.nodes.items[i].has_sub = true;
                v.addNode(i + 1, child, rest[0..end], v.nodes.items[i].depth + 1) catch break;
                next = i + 1;
            }
            i = next orelse break;
        }
        v.sel = i;
        // the folder itself open, so its children are on screen
        v.expand(i);
    }

    fn expand(v: *FolderView, i: usize) void {
        const n = &v.nodes.items[i];
        if (n.expanded or !n.has_sub) return;
        n.expanded = true;
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |x| gpa.free(x);
            names.deinit(gpa);
        }
        const dz = gpa.dupeZ(u8, if (std.mem.eql(u8, n.path, "/")) "/." else n.path) catch return;
        defer gpa.free(dz);
        var scan: Scan = .{ .dir = n.path, .names = &names };
        _ = c.SDL_EnumerateDirectory(dz.ptr, scanCb, &scan);
        std.mem.sort([]u8, names.items, {}, nameLess);
        if (names.items.len == 0) {
            v.nodes.items[i].has_sub = false;
            return;
        }
        const depth = v.nodes.items[i].depth + 1;
        for (names.items, 0..) |nm, k| {
            const parent = v.nodes.items[i].path;
            const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ if (std.mem.eql(u8, parent, "/")) "" else parent, nm }) catch return;
            defer gpa.free(full);
            v.addNode(i + 1 + k, full, nm, depth) catch return;
        }
    }

    fn collapse(v: *FolderView, i: usize) void {
        const depth = v.nodes.items[i].depth;
        v.nodes.items[i].expanded = false;
        while (i + 1 < v.nodes.items.len and v.nodes.items[i + 1].depth > depth) {
            const n = v.nodes.orderedRemove(i + 1);
            gpa.free(n.path);
            gpa.free(n.name);
        }
        if (v.sel > i) v.sel = i;
    }

    fn toggle(v: *FolderView, i: usize) void {
        if (v.nodes.items[i].expanded) v.collapse(i) else v.expand(i);
    }

    fn parentOf(v: *const FolderView, i: usize) ?usize {
        const depth = v.nodes.items[i].depth;
        if (depth == 0) return null;
        var k = i;
        while (k > 0) : (k -= 1) {
            if (v.nodes.items[k - 1].depth < depth) return k - 1;
        }
        return null;
    }

    fn select(v: *FolderView, i: usize) void {
        if (v.nodes.items.len == 0) return;
        v.sel = @min(i, v.nodes.items.len - 1);
    }

    /// The tree row under the pointer, and whether it is on the arrow.
    fn rowAt(v: *const FolderView, mx: f32, my: f32, ui: f32) ?struct { i: usize, arrow: bool } {
        if (mx >= v.pane_w or my < v.tree_y) return null;
        const r: usize = @intFromFloat(@floor((my - v.tree_y) / v.row_h));
        if (r >= v.tree_rows) return null;
        const i = v.tree_scroll + r;
        if (i >= v.nodes.items.len) return null;
        const indent = @as(f32, @floatFromInt(v.nodes.items[i].depth)) * 16 * ui;
        return .{ .i = i, .arrow = mx < 8 * ui + indent + v.row_h };
    }

    fn cellAt(v: *const FolderView, mx: f32, my: f32, n: usize) ?usize {
        const g = v.grid;
        if (mx < g.x or mx >= g.x + g.w or my < g.y or my >= g.y + g.h) return null;
        const col: usize = @intFromFloat(@floor((mx - g.x) / v.cell_w));
        const row: usize = @intFromFloat(@floor((my - g.y) / v.cell_h));
        if (col >= v.cols) return null;
        const i = (v.grid_scroll + row) * v.cols + col;
        return if (i < n) i else null;
    }

    const Scan = struct { dir: []const u8, names: *std.ArrayList([]u8) };

    /// Subfolders of a folder, hidden ones left out unless shown.
    fn scanCb(userdata: ?*anyopaque, dirname: [*c]const u8, fname: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
        _ = dirname;
        const scan: *Scan = @ptrCast(@alignCast(userdata.?));
        const name = std.mem.span(fname);
        if (name.len == 0 or (name[0] == '.' and !show_hidden)) return c.SDL_ENUM_CONTINUE;
        const full = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ if (std.mem.eql(u8, scan.dir, "/")) "" else scan.dir, name }, 0) catch return c.SDL_ENUM_CONTINUE;
        defer gpa.free(full);
        var info: c.SDL_PathInfo = undefined;
        if (!c.SDL_GetPathInfo(full.ptr, &info) or info.type != c.SDL_PATHTYPE_DIRECTORY) return c.SDL_ENUM_CONTINUE;
        scan.names.append(gpa, gpa.dupe(u8, name) catch return c.SDL_ENUM_CONTINUE) catch {};
        return c.SDL_ENUM_CONTINUE;
    }

    const Count = struct { images: usize = 0, seen: usize = 0, uncertain: bool = false };
    const ImageCount = struct { images: usize = 0, uncertain: bool = false };

    fn countImages(path: []const u8) ImageCount {
        const z = gpa.dupeZ(u8, if (std.mem.eql(u8, path, "/")) "/." else path) catch return .{};
        defer gpa.free(z);
        var cnt: Count = .{};
        _ = c.SDL_EnumerateDirectory(z.ptr, countCb, &cnt);
        return .{ .images = cnt.images, .uncertain = cnt.uncertain };
    }

    fn countCb(userdata: ?*anyopaque, dirname: [*c]const u8, fname: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
        _ = dirname;
        const cnt: *Count = @ptrCast(@alignCast(userdata.?));
        const name = std.mem.span(fname);
        if (name.len > 0 and name[0] == '.' and !show_hidden) return c.SDL_ENUM_CONTINUE;
        cnt.seen += 1;
        if (isImage(name)) cnt.images += 1;
        if (cnt.images >= count_cap) return c.SDL_ENUM_SUCCESS;
        if (cnt.seen >= scan_cap) {
            if (cnt.images == 0) cnt.uncertain = true;
            return c.SDL_ENUM_SUCCESS;
        }
        return c.SDL_ENUM_CONTINUE;
    }

    fn nameLess(_: void, x: []u8, y: []u8) bool {
        return naturalLess({}, .{ .id = 0, .path = "", .name = x }, .{ .id = 0, .path = "", .name = y });
    }
};

const App = struct {
    /// Null only for the first moments of start-up, while decoding has
    /// already begun and the window is still being made.
    window: ?*c.SDL_Window = null,
    ren: ?*c.SDL_Renderer = null,
    font: ?*c.TTF_Font = null,
    pal: Palette = .{},
    /// Where the colors came from; see findPalette.
    pal_source: enum { none, own, gtk, portal } = .none,
    /// The file that gave them, and its time, so a focus change re-reads
    /// it only when it changed.
    pal_path: ?[]const u8 = null,
    pal_mtime: i64 = 0,
    /// A portal query in flight (appearanceWorker), at most one at a time.
    appearance_pending: bool = false,
    appearance_thread: ?*c.SDL_Thread = null,
    /// The desktop's folder dialog is up (openWorker).
    open_pending: bool = false,
    open_thread: ?*c.SDL_Thread = null,
    /// The folder view (Backspace), when it is open.
    view: ?FolderView = null,
    /// Thumbnails are fetched outward from here instead of the current
    /// image while the folder view shows a grid of them.
    thumb_center: ?usize = null,
    sort: SortMode = .name,
    /// the grid's thumbnail size, one of thumb_scales
    thumb_scale: f32 = 1,

    items: std.ArrayList(Item) = .empty,
    next_id: u32 = 1,
    cur: usize = 0,
    dir: []const u8 = "",

    sh: *Shared,
    /// The current image and its neighbors, decoded.
    cache: [5]Full = @splat(.{}),
    /// The image we have asked every pixel of, 0 for none.
    sharp_id: u32 = 0,

    // view
    fit: bool = true,
    zoom: f32 = 1,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    dragging: bool = false,
    strip: bool = true,
    // the strip setting to come back to when full screen ends
    strip_before: bool = true,
    strip_scroll: f32 = 0,
    strip_follow: bool = true,

    // sizes, in pixels
    w: f32 = 1280,
    h: f32 = 800,
    density: f32 = 1,
    ui: f32 = 1,

    // status text, re-rendered only when it changes
    status_tex: ?*c.SDL_Texture = null,
    status_text: std.ArrayList(u8) = .empty,
    toast: std.ArrayList(u8) = .empty,
    toast_until: u64 = 0,
    toast_tex: ?*c.SDL_Texture = null,

    dirty: bool = true,

    // tools
    /// Quarter turns clockwise of the image on screen; the file is untouched
    /// until a copy is saved.
    rot: u2 = 0,
    info: bool = false,
    info_for: u32 = 0,
    info_rows: std.ArrayList(InfoRow) = .empty,
    menu: ?Menu = null,
    fullscreen: bool = false,
    /// The `?` overlay, and whether the menu or it has ever been opened:
    /// until then the status line says they exist.
    help: bool = false,
    help_tex: [help_rows.len][2]?*c.SDL_Texture = @splat(.{ null, null }),
    help_title: ?*c.SDL_Texture = null,
    help_version: ?*c.SDL_Texture = null,
    hinted: bool = false,
    hint_tex: ?*c.SDL_Texture = null,
    // where the window was before full screen; SDL moves it to the
    // screen's corner on the way in and leaves it there on the way out
    win_x: c_int = 0,
    win_y: c_int = 0,
    /// Del was pressed; a dialog is up and the next key or click answers it.
    confirm_trash: bool = false,
    confirm_tex: [4]?*c.SDL_Texture = @splat(null),
    confirm_yes: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    confirm_no: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The "Open a folder" button of the empty window, for clicks.
    open_btn: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    crop: bool = false,
    /// The crop rectangle, in pixels of the image as shown (turned or not).
    sel: ?c.SDL_FRect = null,
    sel_anchor: ?[2]f32 = null,
    sel_before: ?c.SDL_FRect = null,

    fn stripH(a: *const App) f32 {
        return if (a.strip and a.items.items.len > 1) @round(92 * a.ui) else 0;
    }
    fn statusH(a: *const App) f32 {
        return if (a.fullscreen) 0 else @round(28 * a.ui);
    }

    // ---------- folder ----------

    fn addFile(a: *App, dir: []const u8, name: []const u8) void {
        if (!isImage(name)) return;
        if (name.len > 0 and name[0] == '.' and !show_hidden) return;
        const path = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0) catch return;
        const id = a.next_id;
        a.next_id += 1;
        var info: c.SDL_PathInfo = undefined;
        const mtime: i64 = if (c.SDL_GetPathInfo(path.ptr, &info)) info.modify_time else 0;
        a.items.append(gpa, .{ .id = id, .path = path, .name = path[dir.len + 1 ..], .mtime = mtime }) catch return;
        c.SDL_LockMutex(a.sh.mutex);
        a.sh.paths.put(gpa, id, path) catch {};
        c.SDL_UnlockMutex(a.sh.mutex);
    }

    fn enumCb(userdata: ?*anyopaque, dirname: [*c]const u8, fname: [*c]const u8) callconv(.c) c.SDL_EnumerationResult {
        const a: *App = @ptrCast(@alignCast(userdata.?));
        _ = dirname;
        a.addFile(a.dir, std.mem.span(fname));
        return c.SDL_ENUM_CONTINUE;
    }

    /// List the folder of `path` (or `path` itself when it is a folder) and
    /// stand on `path`.
    fn open(a: *App, path: []const u8) void {
        var info: c.SDL_PathInfo = undefined;
        const z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(z);
        const is_dir = c.SDL_GetPathInfo(z.ptr, &info) and info.type == c.SDL_PATHTYPE_DIRECTORY;
        const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
        a.dir = gpa.dupe(u8, if (is_dir) trimmed else (std.fs.path.dirname(trimmed) orelse ".")) catch return;
        // SDL trims the trailing slash off the folder it is given, which
        // turns "/" into "" and fails; "/." is the same folder and survives.
        const dz = gpa.dupeZ(u8, if (std.mem.eql(u8, a.dir, "/")) "/." else a.dir) catch return;
        defer gpa.free(dz);
        _ = c.SDL_EnumerateDirectory(dz.ptr, enumCb, a);
        std.mem.sort(Item, a.items.items, a.sort, itemLess);
        a.cur = 0;
        if (!is_dir) {
            const base = std.fs.path.basename(trimmed);
            for (a.items.items, 0..) |it, i| {
                if (std.mem.eql(u8, it.name, base)) a.cur = i;
            }
        }
    }

    // ---------- what to decode next ----------

    fn cached(a: *App, id: u32) ?*Full {
        for (&a.cache) |*f| {
            if (f.id == id and (f.tex != null or f.failed)) return f;
        }
        return null;
    }

    /// Tell the workers what we are looking at: this image first, then the
    /// next and the previous, then the thumbnails nearest to it.
    fn plan(a: *App) void {
        const n = a.items.items.len;
        if (n == 0) return;
        c.SDL_LockMutex(a.sh.mutex);
        defer {
            _ = c.SDL_BroadcastCondition(a.sh.cond);
            c.SDL_UnlockMutex(a.sh.mutex);
        }
        a.sh.want_full_n = 0;
        // Zoomed in past what the screen-sized copy holds: every pixel, now.
        if (a.sharp_id != 0 and a.sharp_id == a.items.items[a.cur].id) {
            a.sh.want_full[0] = .{ .id = a.sharp_id, .limit = a.sh.max_texture };
            a.sh.want_full_n = 1;
        }
        // Otherwise a copy the size of the window is all a fitted image
        // needs, and it keeps three decoded photos from costing 300 MB.
        const limit: c_int = @intFromFloat(std.math.clamp(@max(a.w, a.h), 512, @as(f32, @floatFromInt(a.sh.max_texture))));
        const order = [_]isize{ 0, 1, -1 };
        for (order) |d| {
            const i = @as(isize, @intCast(a.cur)) + d;
            if (i < 0 or i >= n) continue;
            const id = a.items.items[@intCast(i)].id;
            if (a.cached(id) != null) continue;
            a.sh.want_full[a.sh.want_full_n] = .{ .id = id, .limit = limit };
            a.sh.want_full_n += 1;
        }
        // thumbnails: outward from the current one (or the grid's middle),
        // a few hundred at most. Clearing the queue abandons ids that were
        // marked loading but never taken. Put those back so this plan can
        // queue them again. A decode already running stays loading.
        for (a.sh.want_thumb.items) |id| {
            const i = a.indexOf(id) orelse continue;
            if (a.items.items[i].thumb_state == .loading) a.items.items[i].thumb_state = .none;
        }
        a.sh.want_thumb.clearRetainingCapacity();
        const center: usize = @min(n - 1, a.thumb_center orelse a.cur);
        var step: usize = 0;
        while (step < 300 and step < n) : (step += 1) {
            const offs = [_]isize{ @intCast(step), -@as(isize, @intCast(step)) };
            for (offs, 0..) |d, k| {
                if (step == 0 and k == 1) continue;
                const i = @as(isize, @intCast(center)) + d;
                if (i < 0 or i >= n) continue;
                const it = &a.items.items[@intCast(i)];
                if (it.thumb_state == .none) {
                    it.thumb_state = .loading;
                    a.sh.want_thumb.append(gpa, it.id) catch {
                        it.thumb_state = .none;
                    };
                }
            }
        }
    }

    fn indexOf(a: *App, id: u32) ?usize {
        for (a.items.items, 0..) |it, i| {
            if (it.id == id) return i;
        }
        return null;
    }

    fn pathBusy(sh: *const Shared, id: u32) bool {
        for (sh.busy_full) |b| if (b == id) return true;
        for (sh.busy_thumb) |b| if (b == id) return true;
        for (sh.want_full[0..sh.want_full_n]) |w| if (w.id == id) return true;
        for (sh.want_thumb.items) |t| if (t == id) return true;
        for (sh.done.items) |d| if (d.id == id) return true;
        return false;
    }

    /// Drop paths for ids no longer on screen and not in a worker's hands.
    fn sweepPaths(a: *App) void {
        c.SDL_LockMutex(a.sh.mutex);
        defer c.SDL_UnlockMutex(a.sh.mutex);
        var drop: [32]u32 = undefined;
        var n: usize = 0;
        var it = a.sh.paths.iterator();
        while (it.next()) |e| {
            const id = e.key_ptr.*;
            if (a.indexOf(id) != null) continue;
            if (pathBusy(a.sh, id)) continue;
            if (n == drop.len) break;
            drop[n] = id;
            n += 1;
        }
        for (drop[0..n]) |id| {
            if (a.sh.paths.fetchRemove(id)) |kv| gpa.free(kv.value);
        }
    }

    /// Take what the workers finished and turn it into textures.
    fn collect(a: *App) void {
        if (a.font == null) {
            c.SDL_LockMutex(a.sh.mutex);
            const f = found_font;
            c.SDL_UnlockMutex(a.sh.mutex);
            if (f) |path| {
                a.font = c.TTF_OpenFont(path.ptr, @round(13 * a.ui));
                a.info_for = 0;
                a.dirty = true;
            }
        }
        c.SDL_LockMutex(a.sh.mutex);
        const ap = found_appearance;
        found_appearance = null;
        const ch = chosen;
        chosen = null;
        c.SDL_UnlockMutex(a.sh.mutex);
        if (ch) |answer| {
            a.open_pending = false;
            switch (answer.status) {
                .chosen => {
                    const p = answer.path orelse "";
                    defer if (answer.path) |x| gpa.free(x);
                    a.reopen(p);
                },
                .canceled => {},
                .unavailable => a.say("No folder dialog here: Backspace shows the folders, or drop one on the window", .{}),
                .failed => a.say("The desktop's folder dialog failed", .{}),
            }
        }
        if (ap) |answer| {
            a.appearance_pending = false;
            // a file may have appeared meanwhile; only the portal's answer
            // paints when nothing else does
            if (a.pal_source == .portal) {
                a.applyPalette(Palette.fromAppearance(answer));
                mark("palette: desktop portal");
            }
        }
        var done: std.ArrayList(Done) = .empty;
        defer done.deinit(gpa);
        c.SDL_LockMutex(a.sh.mutex);
        done.appendSlice(gpa, a.sh.done.items) catch {};
        a.sh.done.clearRetainingCapacity();
        c.SDL_UnlockMutex(a.sh.mutex);

        for (done.items) |d| {
            defer if (d.surface) |s| c.SDL_DestroySurface(s);
            const idx = a.indexOf(d.id) orelse continue;
            const it = &a.items.items[idx];
            switch (d.kind) {
                .thumb => {
                    if (it.thumb) |old| c.SDL_DestroyTexture(old);
                    it.thumb = null;
                    if (d.surface) |s| {
                        it.thumb = c.SDL_CreateTextureFromSurface(a.ren, s);
                        it.thumb_w = @floatFromInt(s.w);
                        it.thumb_h = @floatFromInt(s.h);
                        it.thumb_state = if (it.thumb != null) .ready else .failed;
                    } else it.thumb_state = .failed;
                },
                .full => {
                    // the slot this image already has (a sharper copy
                    // arriving), else an empty one, else the one farthest
                    // from where we are
                    var slot: ?*Full = null;
                    for (&a.cache) |*f| {
                        if (f.id == d.id) slot = f;
                    }
                    if (slot == null) {
                        for (&a.cache) |*f| {
                            if (f.id == 0) slot = f;
                        }
                    }
                    if (slot == null) {
                        var worst: usize = 0;
                        for (&a.cache) |*f| {
                            const fi = a.indexOf(f.id) orelse {
                                slot = f;
                                break;
                            };
                            const dist = if (fi > a.cur) fi - a.cur else a.cur - fi;
                            if (dist >= worst) {
                                worst = dist;
                                slot = f;
                            }
                        }
                    }
                    const sl = slot orelse &a.cache[0];
                    // a second copy of what is already playing (two workers
                    // took the same file at start-up): keep the first
                    if (sl.id == d.id and sl.anim != null and d.anim != null) {
                        d.anim.?.destroy();
                        continue;
                    }
                    sl.clear();
                    sl.id = d.id;
                    if (d.anim) |an| {
                        const w: c_int = an.dec.w;
                        const h: c_int = an.dec.h;
                        const tex = if (w <= a.sh.max_texture and h <= a.sh.max_texture)
                            c.SDL_CreateTexture(a.ren, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STREAMING, w, h)
                        else
                            null;
                        if (tex) |t| {
                            sl.anim = an;
                            sl.tex = t;
                            sl.w = @floatFromInt(w);
                            sl.h = @floatFromInt(h);
                            sl.tex_w = sl.w;
                            sl.whole = true;
                            _ = sl.advance(c.SDL_GetTicks());
                        } else an.destroy();
                    } else if (d.surface) |s| {
                        sl.tex = c.SDL_CreateTextureFromSurface(a.ren, s);
                        sl.w = @floatFromInt(d.src_w);
                        sl.h = @floatFromInt(d.src_h);
                        sl.tex_w = @floatFromInt(s.w);
                        sl.whole = s.w == d.src_w;
                    }
                    sl.failed = sl.tex == null;
                    if (a.sharp_id == d.id and sl.whole) a.sharp_id = 0;
                    a.info_for = 0;
                },
            }
            a.dirty = true;
        }
        // Decoding a photo passes through buffers of tens of megabytes;
        // hand them back instead of letting the allocator sit on them.
        if (done.items.len > 0) _ = c.malloc_trim(0);
        // mark thumbs we just asked for, so plan() does not ask twice
        a.plan();
        a.sweepPaths();
    }

    // ---------- moving ----------

    fn go(a: *App, to: isize) void {
        const n: isize = @intCast(a.items.items.len);
        if (n == 0) return;
        const t: usize = @intCast(std.math.clamp(to, 0, n - 1));
        if (t == a.cur) return;
        a.cancelTrash();
        // An every-pixel copy is only worth its memory while it is on screen.
        if (a.currentFull()) |f| {
            if (f.whole and f.tex_w > @max(a.w, a.h)) f.clear();
        }
        a.sharp_id = 0;
        a.rot = 0;
        a.crop = false;
        a.sel = null;
        a.cur = t;
        a.fit = true;
        a.pan_x = 0;
        a.pan_y = 0;
        a.strip_follow = true;
        a.dirty = true;
        a.plan();
    }

    fn infoW(a: *const App) f32 {
        return if (a.info) @round(320 * a.ui) else 0;
    }

    fn viewRect(a: *const App) c.SDL_FRect {
        return .{ .x = 0, .y = a.stripH(), .w = @max(1, a.w - a.infoW()), .h = @max(1, a.h - a.stripH() - a.statusH()) };
    }

    fn fitZoom(a: *const App, iw: f32, ih: f32) f32 {
        const v = a.viewRect();
        // never blow a small image up just because there is room
        return @min(1, @min(v.w / iw, v.h / ih));
    }

    /// The image's size as shown: width and height trade places on a
    /// quarter turn.
    fn shown(a: *const App, f: *const Full) [2]f32 {
        return if (a.rot % 2 == 1) .{ f.h, f.w } else .{ f.w, f.h };
    }

    /// Where the image sits on screen right now.
    fn imageRect(a: *App) ?c.SDL_FRect {
        const f = a.currentFull() orelse return null;
        if (f.tex == null) return null;
        const z = a.effectiveZoom();
        const sz = a.shown(f);
        const v = a.viewRect();
        return .{ .x = v.x + (v.w - sz[0] * z) / 2 + a.pan_x, .y = v.y + (v.h - sz[1] * z) / 2 + a.pan_y, .w = sz[0] * z, .h = sz[1] * z };
    }

    fn currentFull(a: *App) ?*Full {
        if (a.items.items.len == 0) return null;
        return a.cached(a.items.items[a.cur].id);
    }

    fn effectiveZoom(a: *App) f32 {
        const f = a.currentFull() orelse return 1;
        if (f.tex == null) return 1;
        const sz = a.shown(f);
        return if (a.fit) a.fitZoom(sz[0], sz[1]) else a.zoom;
    }

    /// Zoom by `factor`, keeping the point under (mx, my) where it is.
    fn zoomAt(a: *App, factor: f32, mx: f32, my: f32) void {
        const f = a.currentFull() orelse return;
        if (f.tex == null) return;
        const old = a.effectiveZoom();
        const new = std.math.clamp(old * factor, 0.02, 32);
        const v = a.viewRect();
        const cx = v.x + v.w / 2 + a.pan_x;
        const cy = v.y + v.h / 2 + a.pan_y;
        // image-space point under the cursor stays put
        const ix = (mx - cx) / old;
        const iy = (my - cy) / old;
        a.pan_x = mx - ix * new - (v.x + v.w / 2);
        a.pan_y = my - iy * new - (v.y + v.h / 2);
        a.zoom = new;
        a.fit = false;
        a.clampPan();
        a.dirty = true;
    }

    fn clampPan(a: *App) void {
        const f = a.currentFull() orelse return;
        const z = a.effectiveZoom();
        const v = a.viewRect();
        const sz = a.shown(f);
        const mx = @max(0, (sz[0] * z - v.w) / 2);
        const my = @max(0, (sz[1] * z - v.h) / 2);
        a.pan_x = std.math.clamp(a.pan_x, -mx, mx);
        a.pan_y = std.math.clamp(a.pan_y, -my, my);
    }

    // ---------- small actions ----------

    fn say(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.toast.clearRetainingCapacity();
        a.toast.print(gpa, fmt, args) catch {};
        // with BUTTERVIEW_TIMING the toasts go to the terminal too, for
        // checking a change without a screen
        if (timing_on) std.debug.print("        say: {s}\n", .{a.toast.items});
        a.toast_until = c.SDL_GetTicks() + 2200;
        if (a.toast_tex) |t| c.SDL_DestroyTexture(t);
        a.toast_tex = null;
        a.dirty = true;
    }

    /// Run a command and wait for it; true when it exited 0.
    fn run(argv: []const ?[*:0]const u8) bool {
        const p = c.SDL_CreateProcess(@ptrCast(argv.ptr), false) orelse return false;
        defer c.SDL_DestroyProcess(p);
        var code: c_int = 1;
        _ = c.SDL_WaitProcess(p, true, &code);
        return code == 0;
    }

    /// Ask first, in the middle of the window where it cannot be missed. It
    /// is only the trash, but one stray key should not be able to send a
    /// picture there.
    fn askTrash(a: *App) void {
        if (a.items.items.len == 0) return;
        a.closeMenu();
        a.freeConfirm();
        a.confirm_trash = true;
        a.confirm_tex[0] = a.textTexture("Move to the trash?", a.pal.text);
        a.confirm_tex[1] = a.textTexture(a.items.items[a.cur].name, a.pal.accent);
        a.confirm_tex[2] = a.textTexture("Move to trash   Enter", a.pal.background);
        a.confirm_tex[3] = a.textTexture("Keep   Esc", a.pal.text);
        a.dirty = true;
    }

    fn freeConfirm(a: *App) void {
        for (&a.confirm_tex) |*t| {
            if (t.*) |tex| c.SDL_DestroyTexture(tex);
            t.* = null;
        }
    }

    fn cancelTrash(a: *App) void {
        if (!a.confirm_trash) return;
        a.confirm_trash = false;
        a.freeConfirm();
        a.dirty = true;
    }

    /// The answer, from a key or a click.
    fn answerTrash(a: *App, yes: bool) void {
        if (!a.confirm_trash) return;
        a.confirm_trash = false;
        a.freeConfirm();
        if (yes) {
            a.trash();
        } else {
            a.say("Kept {s}", .{if (a.items.items.len > 0) a.items.items[a.cur].name else ""});
        }
        a.dirty = true;
    }

    fn drawConfirm(a: *App) void {
        if (!a.confirm_trash) return;
        // everything behind the question steps back
        _ = c.SDL_SetRenderDrawColor(a.ren, 0, 0, 0, 140);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = 0, .w = a.w, .h = a.h });

        var tw: [4]f32 = @splat(0);
        var th: [4]f32 = @splat(0);
        for (a.confirm_tex, 0..) |t, i| {
            if (t) |tex| _ = c.SDL_GetTextureSize(tex, &tw[i], &th[i]);
        }
        const pad = @round(22 * a.ui);
        const gap = @round(12 * a.ui);
        const btn_h = @round(34 * a.ui);
        const btn_pad = @round(16 * a.ui);
        const yes_w = tw[2] + btn_pad * 2;
        const no_w = tw[3] + btn_pad * 2;
        const name_w = @min(tw[1], a.w * 0.6);
        const inner = @max(@max(tw[0], name_w), yes_w + gap + no_w);
        const bw = inner + pad * 2;
        const bh = pad + th[0] + gap + th[1] + pad + btn_h + pad;
        const bx = @round((a.w - bw) / 2);
        const by = @round((a.h - bh) / 2);

        a.setColor(a.pal.accent, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = bx - 2, .y = by - 2, .w = bw + 4, .h = bh + 4 });
        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = bx, .y = by, .w = bw, .h = bh });

        if (a.confirm_tex[0]) |t| a.drawTexture(t, bx + (bw - tw[0]) / 2, by + pad);
        if (a.confirm_tex[1]) |t| {
            // a long file name is cut, not squeezed
            _ = c.SDL_RenderTexture(a.ren, t, &.{ .x = 0, .y = 0, .w = name_w, .h = th[1] }, &.{ .x = @round(bx + (bw - name_w) / 2), .y = @round(by + pad + th[0] + gap), .w = name_w, .h = th[1] });
        }
        const row_y = by + bh - pad - btn_h;
        const row_x = bx + (bw - (yes_w + gap + no_w)) / 2;
        a.confirm_yes = .{ .x = @round(row_x), .y = @round(row_y), .w = yes_w, .h = btn_h };
        a.confirm_no = .{ .x = @round(row_x + yes_w + gap), .y = @round(row_y), .w = no_w, .h = btn_h };
        a.setColor(a.pal.accent, 255);
        _ = c.SDL_RenderFillRect(a.ren, &a.confirm_yes);
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderFillRect(a.ren, &a.confirm_no);
        if (a.confirm_tex[2]) |t| a.drawTexture(t, a.confirm_yes.x + btn_pad, a.confirm_yes.y + (btn_h - th[2]) / 2);
        if (a.confirm_tex[3]) |t| a.drawTexture(t, a.confirm_no.x + btn_pad, a.confirm_no.y + (btn_h - th[3]) / 2);
    }

    fn trash(a: *App) void {
        if (a.items.items.len == 0) return;
        const it = a.items.items[a.cur];
        if (!run(&.{ "gio", "trash", "--", it.path.ptr, null })) {
            a.say("Could not move {s} to the trash", .{it.name});
            return;
        }
        a.say("Moved {s} to the trash", .{it.name});
        if (it.thumb) |t| c.SDL_DestroyTexture(t);
        // the picture that slides in starts fresh, as it does after moving
        for (&a.cache) |*f| {
            if (f.id == it.id) f.clear();
        }
        a.sharp_id = 0;
        a.rot = 0;
        a.crop = false;
        a.sel = null;
        _ = a.items.orderedRemove(a.cur);
        if (a.cur >= a.items.items.len and a.cur > 0) a.cur -= 1;
        a.fit = true;
        a.pan_x = 0;
        a.pan_y = 0;
        a.plan();
        a.sweepPaths();
    }

    fn copy(a: *App) void {
        if (a.items.items.len == 0) return;
        const it = a.items.items[a.cur];
        // the file's own bytes go on the clipboard, so they must be called
        // what they are: a JPEG offered as image/png pastes as nothing
        const mime = clipType(it.name) orelse {
            a.say("Cannot copy {s}: no clipboard type for it", .{it.name});
            return;
        };
        const wayland = c.SDL_getenv("WAYLAND_DISPLAY") != null;
        const script: [*:0]const u8 = if (wayland)
            "wl-copy --type \"$2\" < \"$1\""
        else
            "xclip -selection clipboard -t \"$2\" -i \"$1\"";
        if (run(&.{ "sh", "-c", script, "sh", it.path.ptr, mime.ptr, null })) {
            a.say("Copied {s}", .{it.name});
        } else {
            a.say("Could not copy (is {s} installed?)", .{if (wayland) "wl-clipboard" else "xclip"});
        }
    }

    /// Set the image as the wallpaper with the user's own command, the
    /// `wallpaper =` line of $XDG_CONFIG_HOME/butterview/butterview.conf.
    /// The file is read here, on the key, so start-up never touches it.
    fn wallpaper(a: *App) void {
        if (a.items.items.len == 0) return;
        const it = a.items.items[a.cur];
        const conf = std.fmt.allocPrintSentinel(gpa, "{s}/butterview/butterview.conf", .{configDir()}, 0) catch return;
        defer gpa.free(conf);
        const script = wallpaperScript(conf) orelse {
            a.say("No wallpaper command: add a line like  wallpaper = awww img  to {s}", .{conf});
            return;
        };
        defer gpa.free(script);
        if (run(&.{ "sh", "-c", script.ptr, "sh", it.path.ptr, null })) {
            a.say("Wallpaper set to {s}", .{it.name});
        } else {
            a.say("The wallpaper command failed: {s}", .{script});
        }
    }

    /// The portal's name for our window, so the desktop's dialog is placed
    /// over it: `x11:<id>` or `wayland:<exported handle>`, else empty.
    fn portalParent(a: *App) ?[:0]u8 {
        const win = a.window orelse return null;
        const props = c.SDL_GetWindowProperties(win);
        if (props == 0) return null;
        const xid = c.SDL_GetNumberProperty(props, c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
        if (xid != 0) return std.fmt.allocPrintSentinel(gpa, "x11:{x}", .{@as(u64, @intCast(xid))}, 0) catch null;
        const h = c.SDL_GetStringProperty(props, c.SDL_PROP_WINDOW_WAYLAND_XDG_TOPLEVEL_EXPORT_HANDLE_STRING, null);
        if (h != null and std.mem.span(h).len > 0) return std.fmt.allocPrintSentinel(gpa, "wayland:{s}", .{std.mem.span(h)}, 0) catch null;
        return null;
    }

    // ---------- tools ----------

    fn act(a: *App, action: Action) void {
        const v = a.viewRect();
        switch (action) {
            .fullscreen => {
                // Full screen is the picture alone: the strip and the status
                // line go, and come back with the window (t still shows the
                // strip). The window manager does the rest; one that only
                // pretends (dwm with fakefullscreen) leaves SDL believing
                // the window is the screen, and that is left alone here.
                a.fullscreen = !a.fullscreen;
                if (a.fullscreen) {
                    a.strip_before = a.strip;
                    a.strip = false;
                    _ = c.SDL_GetWindowPosition(a.window, &a.win_x, &a.win_y);
                    _ = c.SDL_SetWindowFullscreen(a.window, true);
                } else {
                    a.strip = a.strip_before;
                    _ = c.SDL_SetWindowFullscreen(a.window, false);
                    _ = c.SDL_SyncWindow(a.window);
                    _ = c.SDL_SetWindowPosition(a.window, a.win_x, a.win_y);
                }
                a.clampPan();
                a.dirty = true;
            },
            .fit => {
                a.fit = true;
                a.pan_x = 0;
                a.pan_y = 0;
                a.dirty = true;
            },
            .actual => a.zoomAt(1 / a.effectiveZoom(), v.x + v.w / 2, v.y + v.h / 2),
            .rotate_cw => a.turn(1),
            .rotate_ccw => a.turn(3),
            .crop => {
                const f = a.currentFull() orelse return;
                if (f.tex == null) return;
                // start with a rectangle already there, so crop mode is
                // unmistakable; a drag replaces it
                const sz = a.shown(f);
                a.crop = true;
                a.sel = .{ .x = @round(sz[0] * 0.2), .y = @round(sz[1] * 0.2), .w = @round(sz[0] * 0.6), .h = @round(sz[1] * 0.6) };
                a.say("Drag to choose the area  ·  Enter saves a copy  ·  Esc cancels", .{});
            },
            .save => a.saveCopy(),
            .browse => a.viewOpen(),
            .open => a.openDialog(),
            .info => {
                a.info = !a.info;
                a.clampPan();
                a.dirty = true;
            },
            .thumbs => {
                a.strip = !a.strip;
                a.clampPan();
                a.dirty = true;
            },
            .copy => a.copy(),
            .wallpaper => a.wallpaper(),
            .trash => a.askTrash(),
            .folder => {
                const z = gpa.dupeZ(u8, a.dir) catch return;
                defer gpa.free(z);
                // in the background: some file managers stay in the
                // foreground until their window closes, and run() waits
                if (!run(&.{ "sh", "-c", "command -v xdg-open >/dev/null && { xdg-open \"$1\" >/dev/null 2>&1 & }", "sh", z.ptr, null }))
                    a.say("Could not open the folder (is xdg-utils installed?)", .{});
            },
        }
    }

    /// Turn the picture on screen. Nothing is written until a copy is saved.
    fn turn(a: *App, quarters: u2) void {
        if (a.imageRect() == null) return;
        a.rot +%= quarters;
        a.fit = true;
        a.pan_x = 0;
        a.pan_y = 0;
        a.sel = null;
        if (a.rot != 0) a.say("Turned on screen only  ·  Ctrl-s saves a copy", .{}) else a.dirty = true;
    }

    /// The GIF frame in the streaming texture, which is the one on screen.
    /// Null when the current image is not a playing GIF.
    fn gifSurface(a: *App) ?*c.SDL_Surface {
        const f = a.currentFull() orelse return null;
        if (f.anim == null) return null;
        const tex = f.tex orelse return null;
        const w: c_int = @intFromFloat(@max(f.tex_w, 1));
        const h: c_int = @intFromFloat(@max(f.h, 1));
        var pixels: ?*anyopaque = null;
        var pitch: c_int = 0;
        if (!c.SDL_LockTexture(tex, null, &pixels, &pitch)) return null;
        defer c.SDL_UnlockTexture(tex);
        const src = pixels orelse return null;
        const out = c.SDL_CreateSurface(w, h, c.SDL_PIXELFORMAT_RGBA32) orelse return null;
        const dst = out[0].pixels orelse {
            c.SDL_DestroySurface(out);
            return null;
        };
        if (pitch < w * 4 or out[0].pitch < w * 4) {
            c.SDL_DestroySurface(out);
            return null;
        }
        const row: usize = @intCast(w * 4);
        const src_pitch: usize = @intCast(pitch);
        const dst_pitch: usize = @intCast(out[0].pitch);
        const src_bytes: [*]const u8 = @ptrCast(src);
        const dst_bytes: [*]u8 = @ptrCast(dst);
        var y: usize = 0;
        while (y < @as(usize, @intCast(h))) : (y += 1) {
            @memcpy(dst_bytes[y * dst_pitch ..][0..row], src_bytes[y * src_pitch ..][0..row]);
        }
        return out;
    }

    /// Write what is on screen (turned, cropped, or both) next to the
    /// original, under a new name. The original is never touched.
    fn saveCopy(a: *App) void {
        if (a.items.items.len == 0) return;
        const it = a.items.items[a.cur];
        const cropped = a.crop and a.sel != null;
        if (a.rot == 0 and !cropped) {
            a.say("Nothing to save: rotate or crop first", .{});
            return;
        }
        var s = a.gifSurface() orelse (decode(it.path, std.math.maxInt(c_int)) orelse {
            a.say("Could not read {s}", .{it.name});
            return;
        }).surface;
        s = orient(s, switch (a.rot) {
            0 => 1,
            1 => 6,
            2 => 3,
            3 => 8,
        });
        if (cropped) {
            const r = a.sel.?;
            const x: c_int = std.math.clamp(@as(c_int, @intFromFloat(@round(r.x))), 0, s.w - 1);
            const y: c_int = std.math.clamp(@as(c_int, @intFromFloat(@round(r.y))), 0, s.h - 1);
            const w: c_int = std.math.clamp(@as(c_int, @intFromFloat(@round(r.w))), 1, s.w - x);
            const h: c_int = std.math.clamp(@as(c_int, @intFromFloat(@round(r.h))), 1, s.h - y);
            if (c.SDL_CreateSurface(w, h, c.SDL_PIXELFORMAT_RGBA32)) |out| {
                _ = c.SDL_SetSurfaceBlendMode(s, c.SDL_BLENDMODE_NONE);
                _ = c.SDL_BlitSurface(s, &.{ .x = x, .y = y, .w = w, .h = h }, out, null);
                c.SDL_DestroySurface(s);
                s = out;
            }
        }
        defer c.SDL_DestroySurface(s);

        // photo.jpg -> photo-cropped.jpg, then -2, -3 if that is taken
        const dot = std.mem.findScalarLast(u8, it.name, '.') orelse it.name.len;
        const stem = it.name[0..dot];
        const ext = if (dot < it.name.len) it.name[dot + 1 ..] else "";
        const jpeg = std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg");
        const out_ext: []const u8 = if (jpeg) "jpg" else "png";
        const what: []const u8 = if (cropped and a.rot != 0) "edited" else if (cropped) "cropped" else "rotated";
        var name_buf: [512]u8 = undefined;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var name: []const u8 = "";
        var path: [:0]const u8 = "";
        var n: u32 = 1;
        var free_name = false;
        while (n < 100) : (n += 1) {
            name = (if (n == 1)
                std.fmt.bufPrint(&name_buf, "{s}-{s}.{s}", .{ stem, what, out_ext })
            else
                std.fmt.bufPrint(&name_buf, "{s}-{s}-{d}.{s}", .{ stem, what, n, out_ext })) catch return;
            path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ a.dir, name }) catch return;
            // libc access: a missing name is free; any other error refuses the save.
            const rc = std.c.access(path.ptr, std.c.F_OK);
            if (rc != 0) switch (std.c.errno(rc)) {
                .NOENT => {
                    free_name = true;
                    break;
                },
                else => {
                    a.say("Could not save {s}", .{name});
                    return;
                },
            };
        }
        if (!free_name) {
            a.say("Could not save: names through -99 are taken", .{});
            return;
        }
        const ok = if (jpeg) c.IMG_SaveJPG(s, path.ptr, 95) else c.IMG_SavePNG(s, path.ptr);
        if (!ok) {
            a.say("Could not save {s}", .{name});
            return;
        }

        // stand on the new file
        a.addFile(a.dir, name);
        std.mem.sort(Item, a.items.items, a.sort, itemLess);
        for (a.items.items, 0..) |x, i| {
            if (std.mem.eql(u8, x.name, name)) a.cur = i;
        }
        a.rot = 0;
        a.crop = false;
        a.sel = null;
        a.fit = true;
        a.pan_x = 0;
        a.pan_y = 0;
        a.info_for = 0;
        a.say("Saved {s}", .{name});
        a.plan();
    }

    // ---------- info panel ----------

    fn freeInfo(a: *App) void {
        for (a.info_rows.items) |r| {
            if (r.label) |t| c.SDL_DestroyTexture(t);
            if (r.value) |t| c.SDL_DestroyTexture(t);
        }
        a.info_rows.clearRetainingCapacity();
    }

    fn addInfo(a: *App, label: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, fmt, args) catch return;
        if (value.len == 0) return;
        a.info_rows.append(gpa, .{ .label = a.textTexture(label, a.pal.muted), .value = a.textTexture(value, a.pal.text) }) catch {};
    }

    fn buildInfo(a: *App) void {
        a.freeInfo();
        if (a.items.items.len == 0) return;
        const it = a.items.items[a.cur];
        a.info_for = it.id;
        a.addInfo("Name", "{s}", .{it.name});
        a.addInfo("Folder", "{s}", .{a.dir});
        if (a.currentFull()) |f| {
            if (!f.failed) a.addInfo("Size", "{d} × {d}  ·  {d:.1} MP", .{ @as(u32, @intFromFloat(f.w)), @as(u32, @intFromFloat(f.h)), f.w * f.h / 1_000_000 });
        }
        var pi: c.SDL_PathInfo = undefined;
        if (c.SDL_GetPathInfo(it.path.ptr, &pi)) {
            const bytes: f64 = @floatFromInt(pi.size);
            if (bytes >= 1048576) a.addInfo("On disk", "{d:.1} MB", .{bytes / 1048576}) else a.addInfo("On disk", "{d:.0} KB", .{@max(1, bytes / 1024)});
            var dt: c.SDL_DateTime = undefined;
            if (c.SDL_TimeToDateTime(pi.modify_time, &dt, true)) {
                a.addInfo("Changed", "{d}-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}", .{ @as(u32, @intCast(dt.year)), @as(u32, @intCast(dt.month)), @as(u32, @intCast(dt.day)), @as(u32, @intCast(dt.hour)), @as(u32, @intCast(dt.minute)) });
            }
        }
        const e = readExif(it.path);
        if (!e.found) return;
        // "2026:10:06 14:22:31" reads better with dashes in the date
        if (e.taken.len >= 16) {
            const t = e.taken.get();
            a.addInfo("Taken", "{s}-{s}-{s}  {s}", .{ t[0..4], t[5..7], t[8..10], t[11..16] });
        }
        const make = e.make.get();
        const model = e.model.get();
        if (model.len > 0 and std.ascii.startsWithIgnoreCase(model, make)) {
            a.addInfo("Camera", "{s}", .{model});
        } else if (make.len + model.len > 0) {
            a.addInfo("Camera", "{s} {s}", .{ make, model });
        }
        a.addInfo("Lens", "{s}", .{e.lens.get()});
        if (e.exposure.den != 0 and e.exposure.num != 0) {
            const secs = e.exposure.value();
            if (secs < 1) a.addInfo("Shutter", "1/{d:.0} s", .{1 / secs}) else a.addInfo("Shutter", "{d:.1} s", .{secs});
        }
        if (e.fnumber.den != 0) a.addInfo("Aperture", "f/{d:.1}", .{e.fnumber.value()});
        if (e.iso != 0) a.addInfo("ISO", "{d}", .{e.iso});
        if (e.focal.den != 0) a.addInfo("Focal length", "{d:.0} mm", .{e.focal.value()});
        if (e.has_gps) a.addInfo("Where", "{d:.5}, {d:.5}", .{ e.lat, e.lon });
    }

    fn drawInfo(a: *App) void {
        if (!a.info) return;
        if (a.items.items.len > 0 and a.info_for != a.items.items[a.cur].id) a.buildInfo();
        const pw = a.infoW();
        const x = a.w - pw;
        const y = a.stripH();
        const h = a.h - a.stripH() - a.statusH();
        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = x, .y = y, .w = pw, .h = h });
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = x, .y = y, .w = 1, .h = h });

        const pad = @round(14 * a.ui);
        const label_w = @round(96 * a.ui);
        const row_h = @round(26 * a.ui);
        var ry = y + pad;
        for (a.info_rows.items) |r| {
            if (r.label) |t| a.drawTexture(t, x + pad, ry);
            if (r.value) |t| {
                // a long value is cut at the panel's edge, not squeezed
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                const room = pw - pad * 2 - label_w;
                const vw = @min(tw, room);
                _ = c.SDL_RenderTexture(a.ren, t, &.{ .x = 0, .y = 0, .w = vw, .h = th }, &.{ .x = @round(x + pad + label_w), .y = @round(ry), .w = vw, .h = th });
            }
            ry += row_h;
        }
    }

    // ---------- right-click menu ----------

    fn closeMenu(a: *App) void {
        if (a.menu) |m| {
            for (m.labels) |t| {
                if (t) |tex| c.SDL_DestroyTexture(tex);
            }
            for (m.hints) |t| {
                if (t) |tex| c.SDL_DestroyTexture(tex);
            }
            a.menu = null;
            a.dirty = true;
        }
    }

    fn openMenu(a: *App, mx: f32, my: f32) void {
        a.closeMenu();
        a.hinted = true;
        var m: Menu = .{ .x = mx, .y = my, .row_h = @round(28 * a.ui) };
        var widest: f32 = 0;
        for (menu_items, 0..) |it, i| {
            m.labels[i] = a.textTexture(it.label, a.pal.text);
            m.hints[i] = a.textTexture(it.hint, a.pal.muted);
            var lw: f32 = 0;
            var hw: f32 = 0;
            var th: f32 = 0;
            if (m.labels[i]) |t| _ = c.SDL_GetTextureSize(t, &lw, &th);
            if (m.hints[i]) |t| _ = c.SDL_GetTextureSize(t, &hw, &th);
            widest = @max(widest, lw + hw);
        }
        m.w = widest + @round(64 * a.ui);
        const h = m.row_h * @as(f32, @floatFromInt(menu_items.len)) + @round(8 * a.ui);
        m.x = std.math.clamp(mx, 0, @max(0, a.w - m.w));
        m.y = std.math.clamp(my, 0, @max(0, a.h - h));
        a.menu = m;
        a.dirty = true;
    }

    fn menuRowAt(a: *const App, mx: f32, my: f32) ?usize {
        const m = a.menu orelse return null;
        const top = m.y + @round(4 * a.ui);
        if (mx < m.x or mx > m.x + m.w or my < top) return null;
        const i: usize = @intFromFloat((my - top) / m.row_h);
        return if (i < menu_items.len) i else null;
    }

    fn toggleHelp(a: *App) void {
        a.help = !a.help;
        a.hinted = true;
        a.closeMenu();
        a.dirty = true;
    }

    fn dropHelp(a: *App) void {
        if (a.help_title) |t| c.SDL_DestroyTexture(t);
        a.help_title = null;
        if (a.help_version) |t| c.SDL_DestroyTexture(t);
        a.help_version = null;
        for (&a.help_tex) |*row| {
            for (row) |*t| {
                if (t.*) |tex| c.SDL_DestroyTexture(tex);
                t.* = null;
            }
        }
    }

    fn drawHelp(a: *App) void {
        if (!a.help) return;
        if (a.help_title == null) {
            a.help_title = a.textTexture("Keys", a.pal.text);
            a.help_version = a.textTexture("butterview " ++ version, a.pal.muted);
            for (help_rows, 0..) |r, i| {
                if (r.key.len == 0) {
                    if (r.what.len > 0) a.help_tex[i][1] = a.textTexture(r.what, a.pal.accent);
                    continue;
                }
                a.help_tex[i][0] = a.textTexture(r.key, a.pal.text);
                a.help_tex[i][1] = a.textTexture(r.what, a.pal.text);
            }
        }
        // per column: the key part as wide as its widest key, rows a line apart
        var key_w: [2]f32 = .{ 0, 0 };
        var col_w: [2]f32 = .{ 0, 0 };
        var row_h: f32 = @round(20 * a.ui);
        const indent = @round(16 * a.ui);
        const gap = @round(20 * a.ui);
        for (a.help_tex, 0..) |row, i| {
            const col: usize = if (i < help_left.len) 0 else 1;
            var tw: f32 = 0;
            var th: f32 = 0;
            if (row[0]) |t| {
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                key_w[col] = @max(key_w[col], tw);
                row_h = @max(row_h, @round(th * 1.5));
            }
        }
        for (a.help_tex, 0..) |row, i| {
            const col: usize = if (i < help_left.len) 0 else 1;
            var tw: f32 = 0;
            var th: f32 = 0;
            if (row[1]) |t| {
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                col_w[col] = @max(col_w[col], if (row[0] == null) tw else indent + key_w[col] + gap + tw);
            }
        }
        const pad = @round(24 * a.ui);
        const col_gap = @round(48 * a.ui);
        const head_h = row_h * 1.5;
        const rows: f32 = @floatFromInt(@max(help_left.len, help_right.len));
        const bw = pad * 2 + col_w[0] + col_gap + col_w[1];
        const bh = pad * 2 + head_h + row_h * rows;
        const bx = @round((a.w - bw) / 2);
        const by = @round((a.h - bh) / 2);
        _ = c.SDL_SetRenderDrawColor(a.ren, 0, 0, 0, 140);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = 0, .w = a.w, .h = a.h });
        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = bx, .y = by, .w = bw, .h = bh });
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderRect(a.ren, &.{ .x = bx, .y = by, .w = bw, .h = bh });
        if (a.help_title) |t| {
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(t, &tw, &th);
            a.drawTexture(t, bx + pad, by + pad + (row_h - th) / 2);
        }
        // the version on the right of the title, for bug reports
        if (a.help_version) |t| {
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(t, &tw, &th);
            a.drawTexture(t, bx + bw - pad - tw, by + pad + (row_h - th) / 2);
        }
        // the rule under the title, as ghee draws it
        a.setColor(a.pal.muted, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = bx + pad, .y = @round(by + pad + row_h), .w = bw - pad * 2, .h = @max(1, @round(a.ui)) });
        for (a.help_tex, 0..) |row, i| {
            const col: usize = if (i < help_left.len) 0 else 1;
            const n = if (col == 0) i else i - help_left.len;
            const x = bx + pad + if (col == 0) 0 else col_w[0] + col_gap;
            const y = by + pad + head_h + row_h * @as(f32, @floatFromInt(n));
            if (row[0]) |t| {
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, x + indent, y + (row_h - th) / 2);
            }
            if (row[1]) |t| {
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, if (row[0] == null) x else x + indent + key_w[col] + gap, y + (row_h - th) / 2);
            }
        }
    }

    fn drawMenu(a: *App) void {
        const m = a.menu orelse return;
        const pad = @round(4 * a.ui);
        const h = m.row_h * @as(f32, @floatFromInt(menu_items.len)) + pad * 2;
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = m.x - 1, .y = m.y - 1, .w = m.w + 2, .h = h + 2 });
        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = m.x, .y = m.y, .w = m.w, .h = h });
        for (menu_items, 0..) |_, i| {
            const ry = m.y + pad + m.row_h * @as(f32, @floatFromInt(i));
            if (m.hover != null and m.hover.? == i) {
                a.setColor(a.pal.accent, 60);
                _ = c.SDL_RenderFillRect(a.ren, &.{ .x = m.x + pad, .y = ry, .w = m.w - pad * 2, .h = m.row_h });
            }
            var tw: f32 = 0;
            var th: f32 = 0;
            if (m.labels[i]) |t| {
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, m.x + @round(14 * a.ui), ry + (m.row_h - th) / 2);
            }
            if (m.hints[i]) |t| {
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, m.x + m.w - tw - @round(14 * a.ui), ry + (m.row_h - th) / 2);
            }
        }
    }

    // ---------- crop ----------

    /// A point on screen, as a pixel of the image as shown.
    fn toImage(a: *App, mx: f32, my: f32) ?[2]f32 {
        const r = a.imageRect() orelse return null;
        const f = a.currentFull() orelse return null;
        const z = a.effectiveZoom();
        const sz = a.shown(f);
        return .{ std.math.clamp((mx - r.x) / z, 0, sz[0]), std.math.clamp((my - r.y) / z, 0, sz[1]) };
    }

    fn dragCrop(a: *App, mx: f32, my: f32) void {
        const anchor = a.sel_anchor orelse return;
        const p = a.toImage(mx, my) orelse return;
        a.sel = .{ .x = @min(anchor[0], p[0]), .y = @min(anchor[1], p[1]), .w = @abs(p[0] - anchor[0]), .h = @abs(p[1] - anchor[1]) };
        a.dirty = true;
    }

    fn drawCrop(a: *App) void {
        if (!a.crop) return;
        const r = a.imageRect() orelse return;
        const sel = a.sel orelse return;
        const z = a.effectiveZoom();
        const v = a.viewRect();
        const box: c.SDL_FRect = .{ .x = @round(r.x + sel.x * z), .y = @round(r.y + sel.y * z), .w = @round(sel.w * z), .h = @round(sel.h * z) };
        _ = c.SDL_SetRenderClipRect(a.ren, &.{ .x = @intFromFloat(v.x), .y = @intFromFloat(v.y), .w = @intFromFloat(v.w), .h = @intFromFloat(v.h) });
        defer _ = c.SDL_SetRenderClipRect(a.ren, null);
        // everything outside the rectangle goes dark
        _ = c.SDL_SetRenderDrawColor(a.ren, 0, 0, 0, 150);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = v.x, .y = v.y, .w = v.w, .h = box.y - v.y });
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = v.x, .y = box.y + box.h, .w = v.w, .h = v.y + v.h - box.y - box.h });
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = v.x, .y = box.y, .w = box.x - v.x, .h = box.h });
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = box.x + box.w, .y = box.y, .w = v.x + v.w - box.x - box.w, .h = box.h });
        a.setColor(a.pal.accent, 255);
        _ = c.SDL_RenderRect(a.ren, &box);
        _ = c.SDL_RenderRect(a.ren, &.{ .x = box.x - 1, .y = box.y - 1, .w = box.w + 2, .h = box.h + 2 });
    }

    // ---------- drawing ----------

    fn setColor(a: *App, col: Rgb, alpha: u8) void {
        _ = c.SDL_SetRenderDrawColor(a.ren, col.r, col.g, col.b, alpha);
    }

    fn textTexture(a: *App, text: []const u8, col: Rgb) ?*c.SDL_Texture {
        const font = a.font orelse return null;
        if (text.len == 0) return null;
        const s = c.TTF_RenderText_Blended(font, text.ptr, text.len, .{ .r = col.r, .g = col.g, .b = col.b, .a = 255 }) orelse return null;
        defer c.SDL_DestroySurface(s);
        return c.SDL_CreateTextureFromSurface(a.ren, s);
    }

    fn drawTexture(a: *App, tex: *c.SDL_Texture, x: f32, y: f32) void {
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(tex, &tw, &th);
        const dst: c.SDL_FRect = .{ .x = @round(x), .y = @round(y), .w = tw, .h = th };
        _ = c.SDL_RenderTexture(a.ren, tex, null, &dst);
    }

    fn drawStrip(a: *App) void {
        const sh = a.stripH();
        if (sh == 0) return;
        const n = a.items.items.len;
        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = 0, .w = a.w, .h = sh });

        const pad = @round(6 * a.ui);
        const cell_h = sh - pad * 2;
        const cell_w = @round(cell_h * 1.5);
        const pitch = cell_w + pad;
        const total = pitch * @as(f32, @floatFromInt(n)) + pad;
        if (a.strip_follow) {
            const center = pad + pitch * @as(f32, @floatFromInt(a.cur)) + cell_w / 2;
            a.strip_scroll = center - a.w / 2;
        }
        a.strip_scroll = std.math.clamp(a.strip_scroll, 0, @max(0, total - a.w));

        const first: usize = @intFromFloat(@max(0, @floor((a.strip_scroll - pad) / pitch)));
        var i = first;
        while (i < n) : (i += 1) {
            const x = pad + pitch * @as(f32, @floatFromInt(i)) - a.strip_scroll;
            if (x > a.w) break;
            const it = &a.items.items[i];
            const cell: c.SDL_FRect = .{ .x = @round(x), .y = pad, .w = cell_w, .h = cell_h };
            a.setColor(a.pal.background, 255);
            _ = c.SDL_RenderFillRect(a.ren, &cell);
            if (it.thumb) |t| {
                // fit inside the cell, centered
                const f = @min(cell.w / it.thumb_w, cell.h / it.thumb_h);
                const tw = @round(it.thumb_w * f);
                const th = @round(it.thumb_h * f);
                const dst: c.SDL_FRect = .{ .x = @round(cell.x + (cell.w - tw) / 2), .y = @round(cell.y + (cell.h - th) / 2), .w = tw, .h = th };
                _ = c.SDL_RenderTexture(a.ren, t, null, &dst);
            }
            if (i == a.cur) {
                a.setColor(a.pal.accent, 255);
                const b = @max(2, @round(2 * a.ui));
                var k: f32 = 0;
                while (k < b) : (k += 1) {
                    _ = c.SDL_RenderRect(a.ren, &.{ .x = cell.x - 1 - k, .y = cell.y - 1 - k, .w = cell.w + 2 + 2 * k, .h = cell.h + 2 + 2 * k });
                }
            }
        }
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = sh - 1, .w = a.w, .h = 1 });
    }

    /// Nothing to show: say so, and offer the folder dialog.
    fn drawEmpty(a: *App) void {
        const font = a.font orelse return;
        const ui = a.ui;
        _ = c.TTF_SetFontSize(font, @round(20 * ui));
        const head = a.textTexture("Nothing to show", a.pal.text);
        _ = c.TTF_SetFontSize(font, @round(13 * ui));
        defer if (head) |t| c.SDL_DestroyTexture(t);
        const sub = a.textTexture("Drop an image or a folder here", a.pal.muted);
        defer if (sub) |t| c.SDL_DestroyTexture(t);
        const btn = a.textTexture("Open a folder\u{2026}   o", a.pal.background);
        defer if (btn) |t| c.SDL_DestroyTexture(t);
        var tw: [3]f32 = @splat(0);
        var th: [3]f32 = @splat(0);
        for ([_]?*c.SDL_Texture{ head, sub, btn }, 0..) |t, i| {
            if (t) |tex| _ = c.SDL_GetTextureSize(tex, &tw[i], &th[i]);
        }
        const gap = @round(14 * ui);
        const pad = @round(16 * ui);
        const btn_h = @round(34 * ui);
        const total = th[0] + gap + th[1] + gap * 2 + btn_h;
        var y = @round((a.h - a.statusH() - total) / 2);
        if (head) |t| a.drawTexture(t, (a.w - tw[0]) / 2, y);
        y += th[0] + gap;
        if (sub) |t| a.drawTexture(t, (a.w - tw[1]) / 2, y);
        y += th[1] + gap * 2;
        a.open_btn = .{ .x = @round((a.w - tw[2]) / 2 - pad), .y = y, .w = tw[2] + pad * 2, .h = btn_h };
        a.setColor(a.pal.accent, 255);
        _ = c.SDL_RenderFillRect(a.ren, &a.open_btn);
        if (btn) |t| a.drawTexture(t, a.open_btn.x + pad, y + (btn_h - th[2]) / 2);
    }

    fn drawImage(a: *App) void {
        const v = a.viewRect();
        if (a.items.items.len == 0) return a.drawEmpty();
        const it = &a.items.items[a.cur];
        _ = c.SDL_SetRenderClipRect(a.ren, &.{ .x = @intFromFloat(v.x), .y = @intFromFloat(v.y), .w = @intFromFloat(v.w), .h = @intFromFloat(v.h) });
        defer _ = c.SDL_SetRenderClipRect(a.ren, null);

        if (a.currentFull()) |f| {
            if (f.tex) |tex| {
                const z = a.effectiveZoom();
                // the texture's own (unturned) size; the turn happens about
                // its center, so the same rectangle serves all four ways up
                const dw = f.w * z;
                const dh = f.h * z;
                const dst: c.SDL_FRect = .{
                    .x = @round(v.x + (v.w - dw) / 2 + a.pan_x),
                    .y = @round(v.y + (v.h - dh) / 2 + a.pan_y),
                    .w = @round(dw),
                    .h = @round(dh),
                };
                // big pixels stay square when you zoom right in
                _ = c.SDL_SetTextureScaleMode(tex, if (z >= 3 and f.whole) c.SDL_SCALEMODE_NEAREST else c.SDL_SCALEMODE_LINEAR);
                if (timing_on and !image_marked) {
                    image_marked = true;
                    mark("image on screen");
                }
                if (a.rot == 0) {
                    _ = c.SDL_RenderTexture(a.ren, tex, null, &dst);
                } else {
                    _ = c.SDL_RenderTextureRotated(a.ren, tex, null, &dst, 90.0 * @as(f64, @floatFromInt(a.rot)), null, c.SDL_FLIP_NONE);
                }
                // drawn larger than the copy we hold: ask for the real thing
                if (!f.whole and dw > f.tex_w * 1.02 and a.sharp_id != f.id) {
                    a.sharp_id = f.id;
                    a.plan();
                }
                return;
            }
        }
        // not decoded yet: the thumbnail, large, so there is never a blank
        if (it.thumb) |t| {
            const f = @min(v.w / it.thumb_w, v.h / it.thumb_h);
            const dw = it.thumb_w * f;
            const dh = it.thumb_h * f;
            _ = c.SDL_SetTextureAlphaMod(t, 150);
            _ = c.SDL_RenderTexture(a.ren, t, null, &.{ .x = @round(v.x + (v.w - dw) / 2), .y = @round(v.y + (v.h - dh) / 2), .w = @round(dw), .h = @round(dh) });
            _ = c.SDL_SetTextureAlphaMod(t, 255);
        }
    }

    fn drawStatus(a: *App) void {
        const sh = a.statusH();
        if (sh == 0) {
            // full screen: only a toast, in a small box over the picture
            if (a.toast.items.len > 0 and c.SDL_GetTicks() < a.toast_until) {
                if (a.toast_tex == null) a.toast_tex = a.textTexture(a.toast.items, a.pal.accent);
                if (a.toast_tex) |t| {
                    var tw: f32 = 0;
                    var th: f32 = 0;
                    _ = c.SDL_GetTextureSize(t, &tw, &th);
                    const pad = @round(10 * a.ui);
                    const bx = a.w - tw - pad * 3;
                    const by = a.h - th - pad * 3;
                    a.setColor(a.pal.surface, 230);
                    _ = c.SDL_RenderFillRect(a.ren, &.{ .x = bx, .y = by, .w = tw + pad * 2, .h = th + pad * 2 });
                    a.drawTexture(t, bx + pad, by + pad);
                }
            }
            return;
        }
        const y = a.h - sh;
        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = y, .w = a.w, .h = sh });
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = y, .w = a.w, .h = 1 });

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const n = a.items.items.len;
        if (n == 0) {
            if (a.dir.len > 0) buf.print(gpa, "No images in {s}", .{tilde(a.dir)}) catch {};
        } else {
            const it = a.items.items[a.cur];
            buf.print(gpa, "{s}    {d} / {d}", .{ it.name, a.cur + 1, n }) catch {};
            if (a.currentFull()) |f| {
                if (f.failed) {
                    buf.appendSlice(gpa, "    cannot be shown") catch {};
                } else {
                    buf.print(gpa, "    {d} × {d}    {d}%", .{
                        @as(u32, @intFromFloat(f.w)),
                        @as(u32, @intFromFloat(f.h)),
                        @as(u32, @intFromFloat(@round(a.effectiveZoom() * 100))),
                    }) catch {};
                    if (a.rot != 0) buf.appendSlice(gpa, "    turned, not saved") catch {};
                    if (a.crop) {
                        if (a.sel) |r| {
                            buf.print(gpa, "    crop {d} × {d}", .{ @as(u32, @intFromFloat(@round(r.w))), @as(u32, @intFromFloat(@round(r.h))) }) catch {};
                        } else buf.appendSlice(gpa, "    crop: drag a rectangle") catch {};
                    }
                }
            }
        }
        if (!std.mem.eql(u8, buf.items, a.status_text.items) or a.status_tex == null) {
            a.status_text.clearRetainingCapacity();
            a.status_text.appendSlice(gpa, buf.items) catch {};
            if (a.status_tex) |t| c.SDL_DestroyTexture(t);
            a.status_tex = a.textTexture(buf.items, a.pal.text);
        }
        if (a.status_tex) |t| {
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(t, &tw, &th);
            a.drawTexture(t, @round(12 * a.ui), y + (sh - th) / 2);
        }

        if (a.toast.items.len > 0 and c.SDL_GetTicks() < a.toast_until) {
            if (a.toast_tex == null) a.toast_tex = a.textTexture(a.toast.items, a.pal.accent);
            if (a.toast_tex) |t| {
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, a.w - tw - @round(12 * a.ui), y + (sh - th) / 2);
            }
        } else if (!a.hinted) {
            // where the menu and the keys are, until they have been found
            if (a.hint_tex == null) a.hint_tex = a.textTexture("right-click  menu      ?  keys", a.pal.muted);
            if (a.hint_tex) |t| {
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, a.w - tw - @round(12 * a.ui), y + (sh - th) / 2);
            }
        }
    }

    fn render(a: *App) void {
        a.setColor(a.pal.background, 255);
        _ = c.SDL_RenderClear(a.ren);
        a.drawImage();
        a.drawCrop();
        a.drawStrip();
        a.drawInfo();
        a.drawStatus();
        a.drawView();
        a.drawMenu();
        a.drawHelp();
        a.drawConfirm();
    }

    fn present(a: *App) void {
        a.render();
        _ = c.SDL_RenderPresent(a.ren);
        a.dirty = false;
    }

    fn resized(a: *App) void {
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(a.window, &pw, &ph);
        a.w = @floatFromInt(pw);
        a.h = @floatFromInt(ph);
        var lw: c_int = 0;
        var lh: c_int = 0;
        _ = c.SDL_GetWindowSize(a.window, &lw, &lh);
        a.density = if (lw > 0) a.w / @as(f32, @floatFromInt(lw)) else 1;
        if (timing_on) std.debug.print("        window now {d}x{d} px ({d}x{d} logical)\n", .{ pw, ph, lw, lh });
        a.clampPan();
        a.dirty = true;
    }

    fn title(a: *App) void {
        var buf: [512]u8 = undefined;
        const t = if (a.items.items.len > 0)
            std.fmt.bufPrintZ(&buf, "{s} — butterview", .{a.items.items[a.cur].name}) catch return
        else
            std.fmt.bufPrintZ(&buf, "butterview", .{}) catch return;
        _ = c.SDL_SetWindowTitle(a.window, t.ptr);
    }

    // ---------- another folder ----------

    /// Show `path` (a folder, or an image in one) in place of what is up:
    /// the workers forget what they were about to decode, every texture
    /// goes, the new folder is listed. Paths of the old folder stay
    /// allocated: a worker may still be reading one.
    fn reopen(a: *App, path: []const u8) void {
        var info: c.SDL_PathInfo = undefined;
        const z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(z);
        if (!c.SDL_GetPathInfo(z.ptr, &info)) {
            a.say("No such file or folder", .{});
            return;
        }
        a.closeMenu();
        c.SDL_LockMutex(a.sh.mutex);
        a.sh.want_full_n = 0;
        a.sh.want_thumb.clearRetainingCapacity();
        c.SDL_UnlockMutex(a.sh.mutex);
        for (a.items.items) |*it| {
            if (it.thumb) |t| c.SDL_DestroyTexture(t);
        }
        a.items.clearRetainingCapacity();
        for (&a.cache) |*f| f.clear();
        a.sharp_id = 0;
        a.rot = 0;
        a.crop = false;
        a.sel = null;
        a.fit = true;
        a.pan_x = 0;
        a.pan_y = 0;
        a.strip_scroll = 0;
        a.strip_follow = true;
        a.info_for = 0;
        if (a.dir.len > 0) gpa.free(a.dir);
        a.dir = "";
        a.open(path);
        a.plan();
        a.sweepPaths();
        a.title();
        a.dirty = true;
        if (a.items.items.len == 0) a.say("No images in {s}", .{tilde(path)});
    }

    /// `o`: the desktop's folder dialog, on a thread, opened on the folder
    /// shown.
    fn openDialog(a: *App) void {
        if (a.open_pending) {
            a.say("The folder dialog is already open", .{});
            return;
        }
        if (a.open_thread) |th| {
            c.SDL_WaitThread(th, null);
            a.open_thread = null;
        }
        const job = gpa.create(OpenJob) catch return;
        job.* = .{ .sh = a.sh, .start = if (a.dir.len > 0) gpa.dupe(u8, a.dir) catch null else null, .parent = a.portalParent() };
        const t = c.SDL_CreateThreadRuntime(openWorker, "open", job, null, null) orelse {
            job.deinit();
            return;
        };
        a.open_thread = t;
        a.open_pending = true;
        if (timing_on) std.debug.print("        open: asking the portal (parent window {s})\n", .{job.parent orelse "none"});
    }

    const thumb_scales = [_]f32{ 0.75, 1, 1.5, 2 };

    /// `s`: the next sort order, the current image kept.
    fn cycleSort(a: *App) void {
        a.sort = switch (a.sort) {
            .name => .newest,
            .newest => .oldest,
            .oldest => .name,
        };
        a.resort();
        a.say("Sorted {s}", .{a.sort.label()});
        a.saveState();
    }

    fn resort(a: *App) void {
        const cur_id: u32 = if (a.items.items.len > 0) a.items.items[a.cur].id else 0;
        std.mem.sort(Item, a.items.items, a.sort, itemLess);
        if (a.indexOf(cur_id)) |i| a.cur = i;
        if (a.view) |*v| {
            v.grid_sel = a.cur;
            v.grid_scroll = 0;
        }
        a.strip_follow = true;
        a.plan();
        a.dirty = true;
    }

    /// `.` or Ctrl-h: hidden files and folders shown or not. The folder is
    /// listed again, standing on the same image; the tree is rebuilt.
    fn toggleHidden(a: *App) void {
        show_hidden = !show_hidden;
        a.saveState();
        const was = if (a.items.items.len > 0) gpa.dupe(u8, a.items.items[a.cur].name) catch null else null;
        defer if (was) |w| gpa.free(w);
        const had_view = a.view != null;
        if (had_view) a.viewClose();
        if (a.dir.len > 0) {
            const d = gpa.dupe(u8, a.dir) catch return;
            defer gpa.free(d);
            a.reopen(d);
            if (was) |w| {
                for (a.items.items, 0..) |it, i| {
                    if (std.mem.eql(u8, it.name, w)) a.go(@intCast(i));
                }
            }
        }
        if (had_view) a.viewOpen();
        if (show_hidden) a.say("Hidden files and folders shown", .{}) else a.say("Hidden files and folders left out", .{});
    }

    /// `+` and `-` in the folder view: bigger and smaller thumbnails.
    fn scaleThumbs(a: *App, up: bool) void {
        var i: usize = 0;
        for (thumb_scales, 0..) |x, k| {
            if (x == a.thumb_scale) i = k;
        }
        if (up and i + 1 < thumb_scales.len) i += 1;
        if (!up and i > 0) i -= 1;
        a.thumb_scale = thumb_scales[i];
        a.dirty = true;
        a.saveState();
    }

    /// What is remembered between runs, in $XDG_STATE_HOME/butterview/state:
    /// the sort order and the thumbnail size. Lines of key = value.
    fn statePath() ?[:0]u8 {
        const base = blk: {
            if (c.SDL_getenv("XDG_STATE_HOME")) |x| {
                const xs = std.mem.span(x);
                if (xs.len > 0 and xs[0] == '/') break :blk std.fmt.allocPrint(gpa, "{s}", .{xs}) catch return null;
            }
            const home = if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else return null;
            break :blk std.fmt.allocPrint(gpa, "{s}/.local/state", .{home}) catch return null;
        };
        defer gpa.free(base);
        return std.fmt.allocPrintSentinel(gpa, "{s}/butterview/state", .{base}, 0) catch null;
    }

    fn loadState(a: *App) void {
        const path = statePath() orelse return;
        defer gpa.free(path);
        var size: usize = 0;
        const raw = c.SDL_LoadFile(path.ptr, &size) orelse return;
        defer c.SDL_free(raw);
        var lines = std.mem.splitScalar(u8, @as([*]const u8, @ptrCast(raw))[0..size], '\n');
        while (lines.next()) |line| {
            const eq = std.mem.findScalar(u8, line, '=') orelse continue;
            const k = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            if (std.mem.eql(u8, k, "sort")) {
                inline for (std.meta.fields(SortMode)) |f| {
                    if (std.mem.eql(u8, val, f.name)) a.sort = @enumFromInt(f.value);
                }
            } else if (std.mem.eql(u8, k, "hidden")) {
                show_hidden = std.mem.eql(u8, val, "yes");
            } else if (std.mem.eql(u8, k, "thumbs")) {
                const v = std.fmt.parseFloat(f32, val) catch continue;
                for (thumb_scales) |x| {
                    if (x == v) a.thumb_scale = v;
                }
            }
        }
    }

    fn saveState(a: *App) void {
        const path = statePath() orelse return;
        defer gpa.free(path);
        const dir = std.fs.path.dirname(path) orelse return;
        const dz = gpa.dupeZ(u8, dir) catch return;
        defer gpa.free(dz);
        _ = c.SDL_CreateDirectory(dz.ptr);
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "sort = {s}\nthumbs = {d}\nhidden = {s}\n", .{ a.sort.key(), a.thumb_scale, @as([]const u8, if (show_hidden) "yes" else "no") }) catch return;
        _ = c.SDL_SaveFile(path.ptr, text.ptr, text.len);
    }

    /// Past the last image (or before the first): the next sibling folder
    /// with images, from its first image (or its last).
    fn stepFolder(a: *App, forward: bool) void {
        if (a.dir.len == 0 or std.mem.eql(u8, a.dir, "/")) return;
        const parent = std.fs.path.dirname(a.dir) orelse return;
        const me = std.fs.path.basename(a.dir);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |x| gpa.free(x);
            names.deinit(gpa);
        }
        const pz = gpa.dupeZ(u8, if (std.mem.eql(u8, parent, "/")) "/." else parent) catch return;
        defer gpa.free(pz);
        var scan: FolderView.Scan = .{ .dir = parent, .names = &names };
        _ = c.SDL_EnumerateDirectory(pz.ptr, FolderView.scanCb, &scan);
        std.mem.sort([]u8, names.items, {}, FolderView.nameLess);
        var at: ?usize = null;
        for (names.items, 0..) |nm, i| {
            if (std.mem.eql(u8, nm, me)) at = i;
        }
        var i: isize = if (at) |x| @intCast(x) else if (forward) -1 else @intCast(names.items.len);
        while (true) {
            i += if (forward) 1 else -1;
            if (i < 0 or i >= @as(isize, @intCast(names.items.len))) {
                if (forward) a.say("No folder with images after this one", .{}) else a.say("No folder with images before this one", .{});
                return;
            }
            const nm = names.items[@intCast(i)];
            const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ if (std.mem.eql(u8, parent, "/")) "" else parent, nm }) catch return;
            defer gpa.free(full);
            const counted = FolderView.countImages(full);
            if (counted.images == 0 and !counted.uncertain) continue;
            a.reopen(full);
            if (!forward and a.items.items.len > 1) a.go(@intCast(a.items.items.len - 1));
            a.say("Now in {s}", .{nm});
            return;
        }
    }

    /// Backspace: the folder view, on the folder shown; again closes it.
    fn viewOpen(a: *App) void {
        if (a.view != null) {
            a.viewClose();
            return;
        }
        a.closeMenu();
        if (a.dir.len == 0) {
            const home = if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else "";
            if (home.len > 1 and home[0] == '/') a.open(home);
        }
        const at = if (a.dir.len > 0) a.dir else if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else "/";
        a.view = FolderView.init(at) orelse return;
        if (a.items.items.len > 0) a.view.?.grid_sel = a.cur;
        a.hinted = true;
        a.dirty = true;
        a.plan();
    }

    fn viewClose(a: *App) void {
        if (a.view) |*v| v.deinit();
        a.view = null;
        a.thumb_center = null;
        a.dirty = true;
        a.plan();
    }

    /// Show the tree's folder `i` in the grid (and the viewer).
    fn viewShow(a: *App, i: usize) void {
        const v = &(a.view orelse return);
        if (i >= v.nodes.items.len) return;
        if (std.mem.eql(u8, v.nodes.items[i].path, a.dir)) return;
        const path = gpa.dupe(u8, v.nodes.items[i].path) catch return;
        defer gpa.free(path);
        a.reopen(path);
        if (a.view) |*nv| {
            nv.grid_sel = 0;
            nv.grid_scroll = 0;
        }
    }

    fn viewKey(a: *App, k: c.SDL_Keycode) void {
        const v = &(a.view orelse return);
        const n = a.items.items.len;
        defer a.dirty = true;
        switch (k) {
            c.SDLK_ESCAPE, c.SDLK_BACKSPACE => a.viewClose(),
            c.SDLK_TAB => v.focus = if (v.focus == .tree) .grid else .tree,
            c.SDLK_O => a.openDialog(),
            c.SDLK_S => a.cycleSort(),
            c.SDLK_PERIOD => a.toggleHidden(),
            c.SDLK_EQUALS, c.SDLK_PLUS, c.SDLK_KP_PLUS => a.scaleThumbs(true),
            c.SDLK_MINUS, c.SDLK_KP_MINUS => a.scaleThumbs(false),
            else => {},
        }
        if (a.view == null) return;
        if (v.focus == .tree) {
            switch (k) {
                c.SDLK_DOWN, c.SDLK_J => v.select(v.sel + 1),
                c.SDLK_UP, c.SDLK_K => v.select(v.sel -| 1),
                c.SDLK_PAGEDOWN => v.select(v.sel + 10),
                c.SDLK_PAGEUP => v.select(v.sel -| 10),
                c.SDLK_HOME => v.select(0),
                c.SDLK_END => v.select(v.nodes.items.len -| 1),
                // Right opens the folder's branch, or steps into it; Left
                // closes it, or steps out to the parent
                c.SDLK_RIGHT, c.SDLK_L => {
                    if (v.nodes.items[v.sel].expanded) {
                        if (v.sel + 1 < v.nodes.items.len and v.nodes.items[v.sel + 1].depth > v.nodes.items[v.sel].depth) v.sel += 1;
                    } else v.expand(v.sel);
                },
                c.SDLK_LEFT, c.SDLK_H => {
                    if (v.nodes.items[v.sel].expanded) v.collapse(v.sel) else if (v.parentOf(v.sel)) |p| v.sel = p;
                },
                c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_SPACE => a.viewShow(v.sel),
                else => {},
            }
        } else {
            switch (k) {
                c.SDLK_RIGHT, c.SDLK_L => v.grid_sel = @min(n -| 1, v.grid_sel + 1),
                c.SDLK_LEFT, c.SDLK_H => v.grid_sel -|= 1,
                c.SDLK_DOWN, c.SDLK_J => v.grid_sel = @min(n -| 1, v.grid_sel + v.cols),
                c.SDLK_UP, c.SDLK_K => v.grid_sel -|= v.cols,
                c.SDLK_HOME => v.grid_sel = 0,
                c.SDLK_END => v.grid_sel = n -| 1,
                c.SDLK_PAGEDOWN => v.grid_sel = @min(n -| 1, v.grid_sel + v.cols * v.grid_rows),
                c.SDLK_PAGEUP => v.grid_sel -|= v.cols * v.grid_rows,
                c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                    if (n > 0) {
                        a.go(@intCast(v.grid_sel));
                        a.viewClose();
                    }
                },
                else => {},
            }
        }
        if (a.view != null) a.viewFollow();
    }

    /// Keep the selections in sight, and ask for the thumbnails in sight.
    fn viewFollow(a: *App) void {
        const v = &(a.view orelse return);
        if (v.sel < v.tree_scroll) v.tree_scroll = v.sel;
        if (v.sel >= v.tree_scroll + v.tree_rows) v.tree_scroll = v.sel + 1 - v.tree_rows;
        const row = v.grid_sel / @max(1, v.cols);
        if (row < v.grid_scroll) v.grid_scroll = row;
        if (row >= v.grid_scroll + v.grid_rows) v.grid_scroll = row + 1 - v.grid_rows;
        const center = (v.grid_scroll + v.grid_rows / 2) * v.cols;
        if (a.thumb_center != center) {
            a.thumb_center = center;
            a.plan();
        }
    }

    fn viewWheel(a: *App, mx: f32, dy: f32) void {
        const v = &(a.view orelse return);
        const by: isize = if (dy > 0) -3 else 3;
        if (mx < v.pane_w) {
            const n: isize = @intCast(v.nodes.items.len);
            v.tree_scroll = @intCast(@max(0, @min(n - 1, @as(isize, @intCast(v.tree_scroll)) + by)));
        } else {
            const rows: isize = @intCast((a.items.items.len + v.cols - 1) / @max(1, v.cols));
            v.grid_scroll = @intCast(@max(0, @min(@max(0, rows - 1), @as(isize, @intCast(v.grid_scroll)) + by)));
            const center = (v.grid_scroll + v.grid_rows / 2) * v.cols;
            if (a.thumb_center != center) {
                a.thumb_center = center;
                a.plan();
            }
        }
        a.dirty = true;
    }

    fn viewClick(a: *App, mx: f32, my: f32) void {
        const v = &(a.view orelse return);
        if (v.rowAt(mx, my, a.ui)) |hit| {
            v.focus = .tree;
            v.sel = hit.i;
            if (hit.arrow) v.toggle(hit.i) else a.viewShow(hit.i);
        } else if (v.cellAt(mx, my, a.items.items.len)) |i| {
            a.go(@intCast(i));
            a.viewClose();
        }
        a.dirty = true;
    }

    fn drawView(a: *App) void {
        const v = &(a.view orelse return);
        const ui = a.ui;
        const pad = @round(10 * ui);
        const h = a.h - a.statusH();
        v.row_h = @round(24 * ui);
        v.pane_w = @round(@min(a.w * 0.35, 280 * ui));
        v.tree_y = pad;
        v.tree_rows = @intFromFloat(@max(1, @floor((h - pad * 2) / v.row_h)));
        v.cell_w = @round(164 * ui * a.thumb_scale);
        v.cell_h = @round(108 * ui * a.thumb_scale);
        // the header over the grid: where we are, how many, in what order
        const head_h = v.row_h;
        v.grid = .{ .x = v.pane_w + pad, .y = pad + head_h, .w = a.w - v.pane_w - pad * 2, .h = h - pad * 2 - head_h };
        v.cols = @intFromFloat(@max(1, @floor(v.grid.w / v.cell_w)));
        v.grid_rows = @intFromFloat(@max(1, @floor(v.grid.h / v.cell_h)));
        a.viewFollow();
        const inner = @round(6 * ui);

        a.setColor(a.pal.surface, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 0, .y = 0, .w = a.w, .h = h });
        a.setColor(a.pal.background, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = v.pane_w, .y = 0, .w = a.w - v.pane_w, .h = h });
        a.setColor(a.pal.border, 255);
        _ = c.SDL_RenderFillRect(a.ren, &.{ .x = v.pane_w - 1, .y = 0, .w = 1, .h = h });

        // the tree
        var buf: [64]u8 = undefined;
        var i = v.tree_scroll;
        var y = v.tree_y;
        while (i < v.nodes.items.len and i < v.tree_scroll + v.tree_rows) : (i += 1) {
            const n = v.nodes.items[i];
            const indent = @as(f32, @floatFromInt(n.depth)) * 16 * ui;
            const selected = i == v.sel;
            if (selected) {
                a.setColor(if (v.focus == .tree) a.pal.border else a.pal.background, 255);
                _ = c.SDL_RenderFillRect(a.ren, &.{ .x = 4 * ui, .y = y, .w = v.pane_w - 8 * ui, .h = v.row_h });
            }
            // the arrow: right when closed, down when open, none for a leaf
            if (n.has_sub) {
                const cx = 8 * ui + indent + v.row_h / 2;
                const cy = y + v.row_h / 2;
                const r = @round(4 * ui);
                const col = if (selected) a.pal.text else a.pal.muted;
                const tint: c.SDL_FColor = .{ .r = @as(f32, @floatFromInt(col.r)) / 255, .g = @as(f32, @floatFromInt(col.g)) / 255, .b = @as(f32, @floatFromInt(col.b)) / 255, .a = 1 };
                const verts = if (n.expanded) [3]c.SDL_Vertex{
                    .{ .position = .{ .x = cx - r, .y = cy - r / 2 }, .color = tint, .tex_coord = .{ .x = 0, .y = 0 } },
                    .{ .position = .{ .x = cx + r, .y = cy - r / 2 }, .color = tint, .tex_coord = .{ .x = 0, .y = 0 } },
                    .{ .position = .{ .x = cx, .y = cy + r / 2 + 1 }, .color = tint, .tex_coord = .{ .x = 0, .y = 0 } },
                } else [3]c.SDL_Vertex{
                    .{ .position = .{ .x = cx - r / 2, .y = cy - r }, .color = tint, .tex_coord = .{ .x = 0, .y = 0 } },
                    .{ .position = .{ .x = cx + r / 2 + 1, .y = cy }, .color = tint, .tex_coord = .{ .x = 0, .y = 0 } },
                    .{ .position = .{ .x = cx - r / 2, .y = cy + r }, .color = tint, .tex_coord = .{ .x = 0, .y = 0 } },
                };
                _ = c.SDL_RenderGeometry(a.ren, null, &verts, 3, null, 0);
            }
            const is_here = std.mem.eql(u8, n.path, a.dir);
            if (a.textTexture(n.name, if (is_here) a.pal.accent else a.pal.text)) |t| {
                defer c.SDL_DestroyTexture(t);
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                _ = c.SDL_SetRenderClipRect(a.ren, &.{ .x = 0, .y = @intFromFloat(y), .w = @intFromFloat(v.pane_w - 8 * ui), .h = @intFromFloat(v.row_h) });
                a.drawTexture(t, 8 * ui + indent + v.row_h, y + (v.row_h - th) / 2);
                _ = c.SDL_SetRenderClipRect(a.ren, null);
            }
            if (n.count > 0) {
                const cnt = if (n.count >= FolderView.count_cap) std.fmt.bufPrint(&buf, "{d}+", .{FolderView.count_cap}) catch "" else std.fmt.bufPrint(&buf, "{d}", .{n.count}) catch "";
                if (a.textTexture(cnt, a.pal.muted)) |t| {
                    defer c.SDL_DestroyTexture(t);
                    var tw: f32 = 0;
                    var th: f32 = 0;
                    _ = c.SDL_GetTextureSize(t, &tw, &th);
                    a.drawTexture(t, v.pane_w - 12 * ui - tw, y + (v.row_h - th) / 2);
                }
            }
            y += v.row_h;
        }

        // the header
        const n_items = a.items.items.len;
        {
            var hb: [96]u8 = undefined;
            const right = if (n_items == 1)
                std.fmt.bufPrint(&hb, "1 image, {s}", .{a.sort.label()}) catch ""
            else
                std.fmt.bufPrint(&hb, "{d} images, {s}", .{ n_items, a.sort.label() }) catch "";
            var rw: f32 = 0;
            if (a.textTexture(right, a.pal.muted)) |t| {
                defer c.SDL_DestroyTexture(t);
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &rw, &th);
                a.drawTexture(t, v.grid.x + v.grid.w - rw, pad + (head_h - th) / 2);
            }
            // the path, its front cut behind an ellipsis when too long
            var head = tilde(a.dir);
            var cut = false;
            if (a.font) |f| {
                var tw: c_int = 0;
                var th: c_int = 0;
                while (head.len > 1) {
                    _ = c.TTF_GetStringSize(f, head.ptr, head.len, &tw, &th);
                    if (@as(f32, @floatFromInt(tw)) + (if (cut) 12 * ui else 0) <= v.grid.w - rw - 24 * ui) break;
                    const slash = std.mem.findScalar(u8, head[1..], '/') orelse break;
                    head = head[slash + 1 ..];
                    cut = true;
                }
            }
            var pb: [std.fs.max_path_bytes + 8]u8 = undefined;
            const heading = if (cut) std.fmt.bufPrint(&pb, "\u{2026}{s}", .{head}) catch head else head;
            if (a.textTexture(heading, a.pal.text)) |t| {
                defer c.SDL_DestroyTexture(t);
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, v.grid.x + inner, pad + (head_h - th) / 2);
            }
        }

        // the grid
        if (n_items == 0) {
            if (a.textTexture("No images in this folder", a.pal.muted)) |t| {
                defer c.SDL_DestroyTexture(t);
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                a.drawTexture(t, v.grid.x + (v.grid.w - tw) / 2, v.grid.y + v.grid.h / 2 - th);
            }
        }
        var idx = v.grid_scroll * v.cols;
        while (idx < n_items and idx < (v.grid_scroll + v.grid_rows) * v.cols) : (idx += 1) {
            const k = idx - v.grid_scroll * v.cols;
            const cx = v.grid.x + @as(f32, @floatFromInt(k % v.cols)) * v.cell_w;
            const cy = v.grid.y + @as(f32, @floatFromInt(k / v.cols)) * v.cell_h;
            const cell: c.SDL_FRect = .{ .x = cx + inner, .y = cy + inner, .w = v.cell_w - inner * 2, .h = v.cell_h - inner * 2 };
            const it = &a.items.items[idx];
            a.setColor(a.pal.surface, 255);
            _ = c.SDL_RenderFillRect(a.ren, &cell);
            if (it.thumb) |t| {
                const f = @min(cell.w / it.thumb_w, cell.h / it.thumb_h);
                const tw = @round(it.thumb_w * f);
                const th = @round(it.thumb_h * f);
                _ = c.SDL_RenderTexture(a.ren, t, null, &.{ .x = @round(cell.x + (cell.w - tw) / 2), .y = @round(cell.y + (cell.h - th) / 2), .w = tw, .h = th });
            }
            if (idx == v.grid_sel) {
                a.setColor(if (v.focus == .grid) a.pal.accent else a.pal.border, 255);
                _ = c.SDL_RenderRect(a.ren, &.{ .x = cell.x - 1, .y = cell.y - 1, .w = cell.w + 2, .h = cell.h + 2 });
                _ = c.SDL_RenderRect(a.ren, &.{ .x = cell.x - 2, .y = cell.y - 2, .w = cell.w + 4, .h = cell.h + 4 });
            }
        }
    }

    // ---------- palette ----------

    /// Paint with `pal` if it differs from what is up: every text texture
    /// is dropped so it is re-rendered in the new colors.
    fn applyPalette(a: *App, pal: Palette) void {
        if (a.pal.eql(pal)) return;
        a.pal = pal;
        if (a.status_tex) |t| c.SDL_DestroyTexture(t);
        a.status_tex = null;
        if (a.hint_tex) |t| c.SDL_DestroyTexture(t);
        a.hint_tex = null;
        a.dropHelp();
        a.info_for = 0;
        a.closeMenu();
        a.dirty = true;
    }

    fn setPaletteFile(a: *App, path: []const u8) void {
        if (a.pal_path) |old| gpa.free(old);
        a.pal_path = gpa.dupe(u8, path) catch null;
        var info: c.SDL_PathInfo = undefined;
        const z = gpa.dupeZ(u8, path) catch return;
        defer gpa.free(z);
        a.pal_mtime = if (c.SDL_GetPathInfo(z.ptr, &info)) info.modify_time else 0;
    }

    /// Where the colors come from, the first that actually yields some:
    /// the viewer's own file, the GTK4 css every libadwaita app follows,
    /// the GTK3 theme the desktop names, else the desktop's own answer
    /// over the portal (dark or light, and the accent), which arrives on a
    /// thread. Called at start and whenever the window gains focus: a file
    /// already read is parsed again only when it changed.
    fn findPalette(a: *App) void {
        const cfg = configDir();
        const home = if (c.SDL_getenv("HOME")) |h| std.mem.span(h) else "";

        // 1. the viewer's own file
        const own = std.fmt.allocPrintSentinel(gpa, "{s}/butterview/colors.conf", .{cfg}, 0) catch return;
        defer gpa.free(own);
        if (!a.unchanged(own)) {
            var pal: Palette = .{};
            if (loadPaletteFile(own, &pal, &.{
                .{ "background", "background" }, .{ "surface", "surface" }, .{ "text", "text" },
                .{ "muted", "muted" },           .{ "accent", "accent" },   .{ "border", "border" },
            })) {
                a.pal_source = .own;
                a.setPaletteFile(own);
                a.applyPalette(pal);
                mark("palette: own colors.conf");
                return;
            }
        } else return;

        // 2. the GTK4 theme, 3. the GTK3 theme
        const gtk4 = std.fmt.allocPrint(gpa, "{s}/gtk-4.0/gtk.css", .{cfg}) catch return;
        defer gpa.free(gtk4);
        if (a.tryCss(gtk4)) return;
        const data_home = blk: {
            if (c.SDL_getenv("XDG_DATA_HOME")) |x| {
                const xs = std.mem.span(x);
                if (xs.len > 0 and xs[0] == '/') break :blk gpa.dupe(u8, xs) catch "";
            }
            break :blk std.fmt.allocPrint(gpa, "{s}/.local/share", .{home}) catch "";
        };
        defer gpa.free(data_home);
        const desktop = if (c.SDL_getenv("XDG_CURRENT_DESKTOP")) |d| std.mem.span(d) else "";
        if (theme.gtk3ThemePath(gpa, cfg, home, data_home, desktop)) |p| {
            defer gpa.free(p);
            if (a.tryCss(p)) return;
        }

        // 4. the desktop, asked
        if (a.pal_path) |old| gpa.free(old);
        a.pal_path = null;
        a.pal_source = .portal;
        if (a.appearance_pending) return;
        if (a.appearance_thread) |th| {
            c.SDL_WaitThread(th, null);
            a.appearance_thread = null;
        }
        a.appearance_pending = true;
        const t = c.SDL_CreateThreadRuntime(appearanceWorker, "appearance", a.sh, null, null) orelse {
            a.appearance_pending = false;
            return;
        };
        a.appearance_thread = t;
    }

    /// True when `path` is the file the colors already came from and it
    /// has not changed since: nothing to do.
    fn unchanged(a: *App, path: [:0]const u8) bool {
        const cur = a.pal_path orelse return false;
        if (!std.mem.eql(u8, cur, path)) return false;
        var info: c.SDL_PathInfo = undefined;
        if (!c.SDL_GetPathInfo(path.ptr, &info)) return false;
        return info.modify_time == a.pal_mtime;
    }

    /// A gtk.css: taken when it (or what it imports) defines the colors.
    fn tryCss(a: *App, path: []const u8) bool {
        const z = gpa.dupeZ(u8, path) catch return false;
        defer gpa.free(z);
        if (a.unchanged(z)) return true;
        const roles = theme.fromCssFile(gpa, path);
        const bg = roles.background orelse return false;
        var pal: Palette = .{};
        pal.background = .{ .r = bg.r, .g = bg.g, .b = bg.b };
        if (roles.surface) |x| pal.surface = .{ .r = x.r, .g = x.g, .b = x.b };
        if (roles.text) |x| pal.text = .{ .r = x.r, .g = x.g, .b = x.b };
        if (roles.muted) |x| pal.muted = .{ .r = x.r, .g = x.g, .b = x.b };
        if (roles.accent) |x| pal.accent = .{ .r = x.r, .g = x.g, .b = x.b };
        if (roles.border) |x| pal.border = .{ .r = x.r, .g = x.g, .b = x.b };
        a.pal_source = .gtk;
        a.setPaletteFile(path);
        a.applyPalette(pal);
        mark("palette: gtk css");
        return true;
    }

    // ---------- input ----------

    fn key(a: *App, k: c.SDL_Keycode, mods: c.SDL_Keymod) bool {
        const n: isize = @intCast(a.items.items.len);
        const cur: isize = @intCast(a.cur);
        const v = a.viewRect();
        const mid_x = v.x + v.w / 2;
        const mid_y = v.y + v.h / 2;
        const ctrl = (mods & c.SDL_KMOD_CTRL) != 0;
        const shift = (mods & c.SDL_KMOD_SHIFT) != 0;
        if (a.confirm_trash) {
            // modifier keys on their own are not an answer
            if (k == c.SDLK_LSHIFT or k == c.SDLK_RSHIFT or k == c.SDLK_LCTRL or k == c.SDLK_RCTRL or k == c.SDLK_LALT or k == c.SDLK_RALT) return true;
            a.answerTrash(k == c.SDLK_Y or k == c.SDLK_RETURN or k == c.SDLK_KP_ENTER);
            return true;
        }
        const is_mod = k == c.SDLK_LSHIFT or k == c.SDLK_RSHIFT or k == c.SDLK_LCTRL or k == c.SDLK_RCTRL or k == c.SDLK_LALT or k == c.SDLK_RALT;
        if (k == c.SDLK_QUESTION or k == c.SDLK_F1 or (k == c.SDLK_SLASH and shift)) {
            a.toggleHelp();
            return true;
        }
        // the key list goes away on any key
        if (a.help) {
            if (!is_mod) a.toggleHelp();
            return true;
        }
        if (a.view != null) {
            if (k == c.SDLK_Q) return false;
            if (k == c.SDLK_H and ctrl) a.toggleHidden() else if (!is_mod) a.viewKey(k);
            return true;
        }
        switch (k) {
            c.SDLK_Q => return false,
            // Esc backs out of whatever is open before it closes the window
            c.SDLK_ESCAPE => {
                if (a.menu != null) {
                    a.closeMenu();
                } else if (a.crop) {
                    a.crop = false;
                    a.sel = null;
                    a.dirty = true;
                } else if (a.fullscreen) {
                    a.act(.fullscreen);
                } else return false;
            },
            c.SDLK_RETURN, c.SDLK_KP_ENTER => {
                if (a.crop and a.sel != null) a.saveCopy() else if (!a.crop) a.viewOpen();
            },
            // past either end, the next folder along
            c.SDLK_RIGHT, c.SDLK_SPACE, c.SDLK_L, c.SDLK_J => if (cur + 1 < n) a.go(cur + 1) else a.stepFolder(true),
            c.SDLK_H => {
                if (ctrl) a.toggleHidden() else if (cur > 0) a.go(cur - 1) else a.stepFolder(false);
            },
            c.SDLK_LEFT, c.SDLK_K => if (cur > 0) a.go(cur - 1) else a.stepFolder(false),
            c.SDLK_PERIOD => a.toggleHidden(),
            c.SDLK_BACKSPACE => a.viewOpen(),
            c.SDLK_O => a.openDialog(),
            c.SDLK_HOME => a.go(0),
            c.SDLK_END => a.go(n - 1),
            c.SDLK_PAGEDOWN => a.go(cur + 10),
            c.SDLK_PAGEUP => a.go(cur - 10),
            c.SDLK_F, c.SDLK_F11 => a.act(.fullscreen),
            c.SDLK_0, c.SDLK_KP_0 => a.act(.fit),
            c.SDLK_1 => a.act(.actual),
            c.SDLK_EQUALS, c.SDLK_PLUS, c.SDLK_KP_PLUS => a.zoomAt(1.25, mid_x, mid_y),
            c.SDLK_MINUS, c.SDLK_KP_MINUS => a.zoomAt(0.8, mid_x, mid_y),
            c.SDLK_T => a.act(.thumbs),
            c.SDLK_I => a.act(.info),
            c.SDLK_R => a.act(if (shift) .rotate_ccw else .rotate_cw),
            c.SDLK_X => a.act(.crop),
            c.SDLK_S => {
                if (ctrl) a.act(.save) else a.cycleSort();
            },
            c.SDLK_DELETE => a.askTrash(),
            c.SDLK_C => {
                if (ctrl) a.copy();
            },
            c.SDLK_Y => a.copy(),
            c.SDLK_W => a.wallpaper(),
            else => {},
        }
        return true;
    }

    fn stripClick(a: *App, mx: f32) void {
        const sh = a.stripH();
        const pad = @round(6 * a.ui);
        const cell_w = @round((sh - pad * 2) * 1.5);
        const pitch = cell_w + pad;
        const i = @floor((mx + a.strip_scroll - pad / 2) / pitch);
        if (i >= 0) a.go(@intFromFloat(i));
    }
};

var found_font: ?[:0]const u8 = null;

/// The desktop's color scheme and accent, asked over the portal on a
/// thread: the call is quick when a portal runs, and must not hold the
/// first frame when one has to be started or is not there at all.
var found_appearance: ?portal.Appearance = null;
fn appearanceWorker(data: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(data.?));
    const ap = portal.appearance(3000, &sh.stop);
    if (sh.stop.load(.acquire)) return 0;
    c.SDL_LockMutex(sh.mutex);
    found_appearance = ap;
    c.SDL_UnlockMutex(sh.mutex);
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = sh.wake_event;
    _ = c.SDL_PushEvent(&ev);
    return 0;
}

const OpenJob = struct {
    sh: *Shared,
    start: ?[]const u8,
    parent: ?[:0]u8,
    fn deinit(j: *OpenJob) void {
        if (j.start) |x| gpa.free(x);
        if (j.parent) |x| gpa.free(x);
        gpa.destroy(j);
    }
};
/// The folder dialog's answer.
var chosen: ?portal.Chosen = null;
/// Put the desktop's folder dialog up and wait for the choice.
fn openWorker(data: ?*anyopaque) callconv(.c) c_int {
    const job: *OpenJob = @ptrCast(@alignCast(data.?));
    const sh = job.sh;
    defer job.deinit();
    const parent: [*:0]const u8 = if (job.parent) |p| p.ptr else "";
    const r = portal.chooseFolder(gpa, job.start, parent, &sh.stop, 10 * 60 * 1000);
    if (sh.stop.load(.acquire)) {
        if (r.path) |p| gpa.free(p);
        return 0;
    }
    c.SDL_LockMutex(sh.mutex);
    if (chosen) |old| if (old.path) |x| gpa.free(x);
    chosen = r;
    c.SDL_UnlockMutex(sh.mutex);
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = sh.wake_event;
    _ = c.SDL_PushEvent(&ev);
    return 0;
}

fn fontWorker(data: ?*anyopaque) callconv(.c) c_int {
    const sh: *Shared = @ptrCast(@alignCast(data.?));
    const f = findFont();
    c.SDL_LockMutex(sh.mutex);
    found_font = f;
    c.SDL_UnlockMutex(sh.mutex);
    var ev: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    ev.type = sh.wake_event;
    _ = c.SDL_PushEvent(&ev);
    return 0;
}

fn findFont() ?[:0]const u8 {
    const argv = [_]?[*:0]const u8{ "fc-match", "-f", "%{file}", "sans-serif", null };
    const p = c.SDL_CreateProcess(@ptrCast(&argv), true) orelse return null;
    defer c.SDL_DestroyProcess(p);
    var size: usize = 0;
    var code: c_int = 0;
    const out = c.SDL_ReadProcess(p, &size, &code) orelse return null;
    defer c.SDL_free(out);
    if (size == 0) return null;
    const s = std.mem.trim(u8, @as([*]const u8, @ptrCast(out))[0..size], " \r\n");
    return gpa.dupeZ(u8, s) catch null;
}

var image_marked: bool = false;
var timing_on: bool = false;
var timing_t0: u64 = 0;
fn mark(what: []const u8) void {
    if (!timing_on) return;
    std.debug.print("{d:>6.1} ms  {s}\n", .{ @as(f64, @floatFromInt(c.SDL_GetTicksNS() - timing_t0)) / 1e6, what });
}

/// A path the user named. The current directory and an unexpanded desktop
/// field code are not one: those open the folder view.
fn explicitPath(arg: []const u8) bool {
    if (arg.len == 0 or std.mem.eql(u8, arg, ".") or std.mem.eql(u8, arg, "./")) return false;
    if (arg.len == 2 and arg[0] == '%') switch (arg[1]) {
        'f', 'F', 'u', 'U' => return false,
        else => {},
    };
    return true;
}

pub fn main(init: std.process.Init) !void {
    timing_on = c.SDL_getenv("BUTTERVIEW_TIMING") != null;
    timing_t0 = c.SDL_GetTicksNS();
    var path: ?[]const u8 = null;
    var shot: ?[]const u8 = null;
    var win_w: c_int = 1280;
    var win_h: c_int = 800;
    var goto: ?usize = null;
    var zoom: ?f32 = null;
    var keys: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--shot")) {
            shot = args.next();
        } else if (std.mem.eql(u8, arg, "--size")) {
            const s = args.next() orelse continue;
            if (std.mem.findScalar(u8, s, 'x')) |x| {
                win_w = std.fmt.parseInt(c_int, s[0..x], 10) catch win_w;
                win_h = std.fmt.parseInt(c_int, s[x + 1 ..], 10) catch win_h;
            }
        } else if (std.mem.eql(u8, arg, "--goto")) {
            goto = std.fmt.parseInt(usize, args.next() orelse "0", 10) catch null;
        } else if (std.mem.eql(u8, arg, "--keys")) {
            keys = args.next();
        } else if (std.mem.eql(u8, arg, "--zoom")) {
            zoom = std.fmt.parseFloat(f32, args.next() orelse "1") catch null;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("butterview {s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\butterview — a small image viewer
                \\usage: butterview [file-or-folder]
                \\       butterview
                \\       butterview --version
                \\
                \\  With no file, the folder view is open. A file still opens that image.
                \\
                \\  Left/Right, Space             previous / next      Home/End  first / last
                \\  wheel, + and -                zoom                 0  fit    1  actual size
                \\  f or F11                      full screen: the picture alone (Esc leaves it)
                \\  drag                          pan                  double-click  fit <-> 100%
                \\  t                             thumbnail strip on / off (click one to jump)
                \\  i                             image info (size, date, camera settings)
                \\  r / Shift-r                   rotate right / left    x  crop    Ctrl-s  save a copy
                \\  right-click                   all of this as a menu    ?  or F1  the keys, on screen
                \\  y or Ctrl-c                   copy    Del  move to the trash    q  quit
                \\  w                             set as wallpaper (the  wallpaper = cmd  line in
                \\                                ~/.config/butterview/butterview.conf)
                \\  Backspace or Enter            folder view: the folders as a tree, the thumbnails
                \\  s                             sort by name / newest first / oldest first
                \\  . or Ctrl-h                   hidden files and folders shown / left out
                \\  (past the last image, Right goes on to the next folder with images)
                \\  o                             open a folder with the desktop's dialog
                \\  (a folder or an image dropped on the window is opened too)
                \\
            , .{});
            return;
        } else if (explicitPath(arg)) {
            path = arg;
        }
    }

    // A real path is opened. Anything else (no argument, `.`, an unexpanded
    // desktop code, a path that is not there) opens the folder view instead
    // of whatever directory the process was started in.
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    var opened = false;
    if (path) |p| {
        if (std.Io.Dir.cwd().realPathFile(init.io, p, &real_buf)) |real_len| {
            path = real_buf[0..real_len];
            opened = true;
        } else |_| {
            std.debug.print("butterview: no such file or folder: {s}\n", .{p});
            path = null;
        }
    }

    // Decoding passes through buffers of tens of megabytes. Left alone, the
    // allocator starts keeping buffers that size for reuse, one stock per
    // thread; fixed at 1 MB, anything larger goes straight back to the
    // system when it is freed.
    _ = c.mallopt(c.M_MMAP_THRESHOLD, 1 << 20);

    // The window's app id, so a compositor rule can name it.
    _ = c.SDL_SetAppMetadata("butterview", version, "butterview");
    // Under X11 a title with anything beyond ASCII needs the user's locale.
    _ = c.setlocale(c.LC_ALL, "");
    // Native Wayland where there is a Wayland session. SDL would otherwise
    // go through XWayland on compositors without the newest frame-timing
    // protocols (wlroots 0.19 among them); X11 stays the fallback.
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, if (shot != null) "dummy" else "wayland,x11");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("butterview: cannot start video: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    }
    defer c.SDL_Quit();
    mark("video up");
    _ = c.TTF_Init();
    defer c.TTF_Quit();

    var shared: Shared = .{
        .mutex = c.SDL_CreateMutex().?,
        .cond = c.SDL_CreateCondition().?,
        .wake_event = c.SDL_RegisterEvents(1),
    };
    var app: App = .{ .sh = &shared };

    // Decoding starts before there is a window. Making the window and its
    // renderer takes about as long as decoding a photo, so the two run side
    // by side and the image can be in the first frame. The window's final
    // size is not known yet; the screen's is, and a copy that size is never
    // too small for a fitted view.
    var bounds: c.SDL_Rect = undefined;
    if (shot == null and c.SDL_GetDisplayBounds(c.SDL_GetPrimaryDisplay(), &bounds)) {
        app.w = @floatFromInt(bounds.w);
        app.h = @floatFromInt(bounds.h);
    } else {
        app.w = @floatFromInt(win_w);
        app.h = @floatFromInt(win_h);
    }
    // The font is looked up on a thread too (it means running fc-match);
    // the first frame goes out without text rather than wait for it.
    const font_thread = c.SDL_CreateThreadRuntime(fontWorker, "font", &shared, null, null);
    app.findPalette();
    app.loadState();
    if (opened) if (path) |p| app.open(p);
    if (goto) |g| app.cur = @min(g, app.items.items.len -| 1);
    var threads: [3]?*c.SDL_Thread = @splat(null);
    for (&threads) |*t| t.* = c.SDL_CreateThreadRuntime(worker, "decode", &shared, null, null);
    app.plan();
    // No file: the folder view is the window. A named file stays on that image.
    if (!opened) app.viewOpen();
    mark("folder listed, decoding started");

    const window = c.SDL_CreateWindow("butterview", win_w, win_h, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse {
        std.debug.print("butterview: cannot open a window: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    };
    const ren = c.SDL_CreateRenderer(window, if (shot != null) "software" else null) orelse {
        std.debug.print("butterview: cannot create a renderer: {s}\n", .{c.SDL_GetError()});
        std.process.exit(1);
    };
    mark("window and renderer");
    if (timing_on) std.debug.print("          renderer: {s}\n", .{c.SDL_GetRendererName(ren)});
    _ = c.SDL_SetRenderVSync(ren, 1);
    _ = c.SDL_SetRenderDrawBlendMode(ren, c.SDL_BLENDMODE_BLEND);
    app.window = window;
    app.ren = ren;

    const max_tex = c.SDL_GetNumberProperty(c.SDL_GetRendererProperties(ren), c.SDL_PROP_RENDERER_MAX_TEXTURE_SIZE_NUMBER, 8192);
    c.SDL_LockMutex(shared.mutex);
    shared.max_texture = @intCast(std.math.clamp(max_tex, 1024, 16384));
    c.SDL_UnlockMutex(shared.mutex);

    app.ui = @max(1, c.SDL_GetWindowDisplayScale(window));
    app.resized();
    app.ui = @max(app.ui, app.density);
    app.title();
    // whatever finished decoding while the window was being made
    app.collect();

    if (shot) |out| {
        // No screen: wait for the image and the visible thumbnails, draw one
        // frame, save it.
        var waited: u32 = 0;
        while (waited < 8000) : (waited += 10) {
            app.collect();
            if (app.font == null) {
                c.SDL_Delay(5);
                continue;
            }
            c.SDL_LockMutex(shared.mutex);
            const idle = shared.want_full_n == 0 and shared.want_thumb.items.len == 0;
            var busy = false;
            for (shared.busy_full) |b| busy = busy or b != 0;
            c.SDL_UnlockMutex(shared.mutex);
            if (idle and !busy and app.currentFull() != null and waited > 150) break;
            c.SDL_Delay(10);
        }
        app.collect();
        if (zoom) |z| {
            const v = app.viewRect();
            app.zoomAt(z / app.effectiveZoom(), v.x + v.w / 2, v.y + v.h / 2);
        }
        // --keys i,r,f,t,sel=0.25:0.25:0.5:0.5,save,menu,w,browse,down,enter,drop=PATH : the tools, by name
        if (keys) |ks| {
            var toks = std.mem.splitScalar(u8, ks, ',');
            while (toks.next()) |tok| {
                if (std.mem.eql(u8, tok, "i")) app.act(.info);
                if (std.mem.eql(u8, tok, "r")) app.act(.rotate_cw);
                if (std.mem.eql(u8, tok, "R")) app.act(.rotate_ccw);
                if (std.mem.eql(u8, tok, "x")) app.act(.crop);
                if (std.mem.eql(u8, tok, "f")) {
                    // no event loop here to hear the resize
                    app.act(.fullscreen);
                    app.resized();
                }
                if (std.mem.eql(u8, tok, "t")) app.act(.thumbs);
                if (std.mem.eql(u8, tok, "?")) app.toggleHelp();
                if (std.mem.eql(u8, tok, "del")) _ = app.key(c.SDLK_DELETE, 0);
                if (std.mem.eql(u8, tok, "y")) _ = app.key(c.SDLK_Y, 0);
                if (std.mem.eql(u8, tok, "w")) _ = app.key(c.SDLK_W, 0);
                if (std.mem.eql(u8, tok, "n")) _ = app.key(c.SDLK_N, 0);
                // the folder view, for frames of it: browse, then the keys
                if (std.mem.eql(u8, tok, "browse")) app.viewOpen();
                if (std.mem.eql(u8, tok, "down")) app.viewKey(c.SDLK_DOWN);
                if (std.mem.eql(u8, tok, "up")) app.viewKey(c.SDLK_UP);
                if (std.mem.eql(u8, tok, "left")) app.viewKey(c.SDLK_LEFT);
                if (std.mem.eql(u8, tok, "right")) app.viewKey(c.SDLK_RIGHT);
                if (std.mem.eql(u8, tok, "enter")) app.viewKey(c.SDLK_RETURN);
                if (std.mem.eql(u8, tok, "tab")) app.viewKey(c.SDLK_TAB);
                if (std.mem.eql(u8, tok, "plus")) app.viewKey(c.SDLK_PLUS);
                if (std.mem.eql(u8, tok, "minus")) app.viewKey(c.SDLK_MINUS);
                if (std.mem.eql(u8, tok, "s")) app.cycleSort();
                if (std.mem.eql(u8, tok, "hidden")) app.toggleHidden();
                if (std.mem.eql(u8, tok, "next")) _ = app.key(c.SDLK_RIGHT, 0);
                if (std.mem.eql(u8, tok, "prev")) _ = app.key(c.SDLK_LEFT, 0);
                // a drop on the window, by path
                if (std.mem.startsWith(u8, tok, "drop=")) app.reopen(tok[5..]);
                if (std.mem.eql(u8, tok, "menu")) {
                    app.openMenu(app.w / 2, app.h / 3);
                    if (app.menu) |*m| m.hover = 2;
                }
                // a key that changed the folder: wait for its image
                var w4: u32 = 0;
                while (w4 < 3000) : (w4 += 10) {
                    app.collect();
                    c.SDL_LockMutex(shared.mutex);
                    const idle4 = shared.want_full_n == 0 and shared.want_thumb.items.len == 0;
                    var busy4 = false;
                    for (shared.busy_full) |b| busy4 = busy4 or b != 0;
                    c.SDL_UnlockMutex(shared.mutex);
                    if (idle4 and !busy4 and (app.currentFull() != null or app.items.items.len == 0)) break;
                    c.SDL_Delay(10);
                }
                if (std.mem.startsWith(u8, tok, "sel=")) {
                    var parts = std.mem.splitScalar(u8, tok[4..], ':');
                    var fr: [4]f32 = .{ 0, 0, 1, 1 };
                    for (&fr) |*x| x.* = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
                    if (app.currentFull()) |f| {
                        const sz = app.shown(f);
                        app.crop = true;
                        app.sel = .{ .x = fr[0] * sz[0], .y = fr[1] * sz[1], .w = fr[2] * sz[0], .h = fr[3] * sz[1] };
                    }
                }
                if (std.mem.eql(u8, tok, "save")) {
                    app.saveCopy();
                    // the saved copy is the current image now: let it load
                    var w2: u32 = 0;
                    while (app.currentFull() == null and w2 < 5000) : (w2 += 10) {
                        c.SDL_Delay(10);
                        app.collect();
                    }
                }
            }
        }
        app.render();
        // zoomed past the screen-sized copy: wait for every pixel, draw again
        var sharp_wait: u32 = 0;
        while (app.sharp_id != 0 and sharp_wait < 8000) : (sharp_wait += 10) {
            c.SDL_Delay(10);
            app.collect();
        }
        app.render();
        const surf = c.SDL_RenderReadPixels(ren, null);
        if (surf != null) {
            const z = gpa.dupeZ(u8, out) catch unreachable;
            _ = c.IMG_SavePNG(surf, z.ptr);
            c.SDL_DestroySurface(surf);
        }
    } else {
        var running = true;
        var last_click: u64 = 0;
        var first_frame_marked = false;
        while (running) {
            var ev: c.SDL_Event = undefined;
            const now_ms = c.SDL_GetTicks();
            const toast_live = app.toast.items.len > 0 and now_ms < app.toast_until;
            // an animation on screen sets the next frame's deadline
            const anim: ?*Full = if (app.currentFull()) |f| (if (f.playing()) f else null) else null;
            if (anim) |f| {
                if (f.advance(now_ms)) app.dirty = true;
            }
            var deadline: ?u64 = if (toast_live) app.toast_until else null;
            if (anim) |f| deadline = if (deadline) |d| @min(d, f.next_at) else f.next_at;
            const got = if (app.dirty)
                c.SDL_PollEvent(&ev)
            else if (deadline) |d|
                c.SDL_WaitEventTimeout(&ev, @intCast(d -| now_ms + 1))
            else
                c.SDL_WaitEvent(&ev);
            if (!got) {
                if (app.dirty or toast_live or app.toast.items.len > 0) {
                    if (!toast_live) app.toast.clearRetainingCapacity();
                    app.present();
                    if (timing_on and !first_frame_marked) {
                        first_frame_marked = true;
                        mark("first frame on screen");
                    }
                }
                continue;
            }
            const before = app.cur;
            if (ev.type == c.SDL_EVENT_QUIT) {
                running = false;
            } else if (ev.type == shared.wake_event) {
                app.collect();
            } else if (ev.type == c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED or ev.type == c.SDL_EVENT_WINDOW_RESIZED or ev.type == c.SDL_EVENT_WINDOW_EXPOSED) {
                app.resized();
            } else if (ev.type == c.SDL_EVENT_WINDOW_FOCUS_GAINED) {
                // the theme may have changed while we were away
                app.findPalette();
            } else if (ev.type == c.SDL_EVENT_DROP_FILE) {
                // a folder or an image dropped on the window: go there
                if (ev.drop.data) |d| app.reopen(std.mem.span(d));
            } else if (app.view != null and ev.type == c.SDL_EVENT_MOUSE_WHEEL) {
                app.viewWheel(ev.wheel.mouse_x * app.density, ev.wheel.y);
            } else if (app.view != null and ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                // a folder row shows that folder, its arrow opens the branch,
                // a thumbnail opens the image; the right button closes
                if (ev.button.button == c.SDL_BUTTON_LEFT) app.viewClick(ev.button.x * app.density, ev.button.y * app.density) else app.viewClose();
            } else if (app.view != null and (ev.type == c.SDL_EVENT_MOUSE_MOTION or ev.type == c.SDL_EVENT_MOUSE_BUTTON_UP)) {
                // the view does not follow the pointer
            } else if (ev.type == c.SDL_EVENT_KEY_DOWN) {
                running = app.key(ev.key.key, ev.key.mod);
            } else if (ev.type == c.SDL_EVENT_MOUSE_WHEEL) {
                const mx = ev.wheel.mouse_x * app.density;
                const my = ev.wheel.mouse_y * app.density;
                if (my < app.stripH()) {
                    app.strip_follow = false;
                    app.strip_scroll -= (ev.wheel.y + ev.wheel.x) * 120 * app.ui;
                    app.dirty = true;
                } else {
                    app.zoomAt(if (ev.wheel.y > 0) 1.15 else 1.0 / 1.15, mx, my);
                }
            } else if (app.confirm_trash and (ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN or ev.type == c.SDL_EVENT_MOUSE_WHEEL or ev.type == c.SDL_EVENT_MOUSE_MOTION)) {
                // the dialog owns the mouse: its first button says yes, a
                // click anywhere else says no, and nothing behind it moves
                if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                    const mx = ev.button.x * app.density;
                    const my = ev.button.y * app.density;
                    const y = app.confirm_yes;
                    app.answerTrash(mx >= y.x and mx < y.x + y.w and my >= y.y and my < y.y + y.h);
                }
            } else if (app.help and ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN) {
                app.toggleHelp();
            } else if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and ev.button.button == c.SDL_BUTTON_RIGHT) {
                const mx = ev.button.x * app.density;
                const my = ev.button.y * app.density;
                if (my >= app.stripH()) app.openMenu(mx, my) else app.closeMenu();
            } else if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and ev.button.button == c.SDL_BUTTON_LEFT and app.menu != null) {
                // a click on a row does it; a click anywhere else just closes
                const row = app.menuRowAt(ev.button.x * app.density, ev.button.y * app.density);
                app.closeMenu();
                if (row) |i| app.act(menu_items[i].action);
            } else if (ev.type == c.SDL_EVENT_MOUSE_MOTION and app.menu != null) {
                const row = app.menuRowAt(ev.motion.x * app.density, ev.motion.y * app.density);
                if (app.menu) |*m| {
                    if (m.hover != row) {
                        m.hover = row;
                        app.dirty = true;
                    }
                }
            } else if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN and ev.button.button == c.SDL_BUTTON_LEFT) {
                const mx = ev.button.x * app.density;
                const my = ev.button.y * app.density;
                if (my < app.stripH()) {
                    app.stripClick(mx);
                } else if (mx >= app.w - app.infoW() or my >= app.h - app.statusH()) {
                    // the info panel and the status line are not the picture
                } else if (app.items.items.len == 0) {
                    const b = app.open_btn;
                    if (mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h) app.openDialog();
                } else if (app.crop) {
                    app.sel_before = app.sel;
                    app.sel_anchor = app.toImage(mx, my);
                    app.sel = null;
                    app.dirty = true;
                } else {
                    const now = c.SDL_GetTicks();
                    if (now - last_click < 350) {
                        if (app.fit) app.zoomAt(1 / app.effectiveZoom(), mx, my) else {
                            app.fit = true;
                            app.pan_x = 0;
                            app.pan_y = 0;
                            app.dirty = true;
                        }
                    }
                    last_click = now;
                    app.dragging = true;
                }
            } else if (ev.type == c.SDL_EVENT_MOUSE_BUTTON_UP and ev.button.button == c.SDL_BUTTON_LEFT) {
                app.dragging = false;
                if (app.sel_anchor != null) {
                    app.sel_anchor = null;
                    // a click without a drag keeps the rectangle that was there
                    if (app.sel) |r| {
                        if (r.w < 4 or r.h < 4) app.sel = app.sel_before;
                    }
                    app.dirty = true;
                }
            } else if (ev.type == c.SDL_EVENT_MOUSE_MOTION and app.sel_anchor != null) {
                app.dragCrop(ev.motion.x * app.density, ev.motion.y * app.density);
            } else if (ev.type == c.SDL_EVENT_MOUSE_MOTION and app.dragging) {
                app.pan_x += ev.motion.xrel * app.density;
                app.pan_y += ev.motion.yrel * app.density;
                app.clampPan();
                app.dirty = true;
            }
            if (app.cur != before) app.title();
        }
    }

    shared.stop.store(true, .release);
    c.SDL_LockMutex(shared.mutex);
    shared.quit = true;
    _ = c.SDL_BroadcastCondition(shared.cond);
    c.SDL_UnlockMutex(shared.mutex);
    for (threads) |t| {
        if (t) |th| c.SDL_WaitThread(th, null);
    }
    if (font_thread) |th| c.SDL_WaitThread(th, null);
    if (app.open_thread) |th| c.SDL_WaitThread(th, null);
    if (app.appearance_thread) |th| c.SDL_WaitThread(th, null);
    // playing GIFs have threads of their own, in the cache and in results
    // nobody collected
    for (&app.cache) |*f| f.clear();
    for (shared.done.items) |d| {
        if (d.anim) |an| an.destroy();
        if (d.surface) |sf| c.SDL_DestroySurface(sf);
    }
}
