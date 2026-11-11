//! A streaming GIF decoder: one frame at a time, composited onto a canvas
//! the caller reads, so a long animation costs one frame of memory.
//! (SDL_image decodes every frame up front, which for a minute of 1080p
//! is gigabytes.)

const std = @import("std");

pub const Frame = struct {
    /// Milliseconds the frame stays up.
    delay: u32,
};

pub const Decoder = struct {
    bytes: []const u8,
    w: u16,
    h: u16,
    /// RGBA, w * h * 4, what is on screen after the last `next`.
    canvas: []u8,
    /// A copy for "restore to previous" disposal, made when asked for.
    saved: ?[]u8 = null,
    global_pal: ?[]const u8 = null,
    /// Where the next block starts; the first image block after init.
    pos: usize,
    first_image: usize,
    /// How the frame just drawn should be cleared before the next one.
    pending_dispose: u8 = 0,
    pending_rect: [4]u16 = .{ 0, 0, 0, 0 },
    gpa: std.mem.Allocator,
    /// LZW working memory, kept across frames.
    prefix: [4096]u16 = undefined,
    suffix: [4096]u8 = undefined,
    stack: [4097]u8 = undefined,
    /// Index row for the frame being decoded.
    row: []u8,

    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Decoder {
        if (bytes.len < 13 or !std.mem.eql(u8, bytes[0..3], "GIF")) return error.NotGif;
        const w = std.mem.readInt(u16, bytes[6..8], .little);
        const h = std.mem.readInt(u16, bytes[8..10], .little);
        if (w == 0 or h == 0) return error.NotGif;
        const packed_ = bytes[10];
        var pos: usize = 13;
        var global_pal: ?[]const u8 = null;
        if (packed_ & 0x80 != 0) {
            const n: usize = @as(usize, 3) << @intCast((packed_ & 7) + 1);
            if (pos + n > bytes.len) return error.Truncated;
            global_pal = bytes[pos .. pos + n];
            pos += n;
        }
        const canvas = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(canvas);
        @memset(canvas, 0);
        const row = try gpa.alloc(u8, w);
        return .{ .bytes = bytes, .w = w, .h = h, .canvas = canvas, .global_pal = global_pal, .pos = pos, .first_image = pos, .gpa = gpa, .row = row };
    }

    pub fn deinit(d: *Decoder) void {
        d.gpa.free(d.canvas);
        d.gpa.free(d.row);
        if (d.saved) |s| d.gpa.free(s);
    }

    /// Start over from the first frame.
    pub fn rewind(d: *Decoder) void {
        d.pos = d.first_image;
        d.pending_dispose = 0;
        @memset(d.canvas, 0);
    }

    fn byte(d: *Decoder) ?u8 {
        if (d.pos >= d.bytes.len) return null;
        d.pos += 1;
        return d.bytes[d.pos - 1];
    }

    fn skipSubBlocks(d: *Decoder) void {
        while (d.byte()) |n| {
            if (n == 0) return;
            d.pos += n;
        }
    }

    /// Decode the next frame onto the canvas. Null at the end of the file
    /// (or on a broken block): `rewind` to loop.
    pub fn next(d: *Decoder) ?Frame {
        // the previous frame's disposal happens before this one is drawn
        switch (d.pending_dispose) {
            2 => d.clearRect(d.pending_rect),
            3 => if (d.saved) |s| @memcpy(d.canvas, s),
            else => {},
        }
        d.pending_dispose = 0;

        var delay: u32 = 100;
        var transparent: ?u8 = null;
        var dispose: u8 = 0;
        while (true) {
            const tag = d.byte() orelse return null;
            switch (tag) {
                0x21 => {
                    const label = d.byte() orelse return null;
                    if (label == 0xF9) {
                        const n = d.byte() orelse return null;
                        if (n >= 4 and d.pos + n <= d.bytes.len) {
                            const p = d.bytes[d.pos];
                            dispose = (p >> 2) & 7;
                            const cs = std.mem.readInt(u16, d.bytes[d.pos + 1 ..][0..2], .little);
                            // browsers show a frame with no delay, or a
                            // very short one, for a tenth of a second
                            delay = if (cs <= 1) 100 else @as(u32, cs) * 10;
                            transparent = if (p & 1 != 0) d.bytes[d.pos + 3] else null;
                        }
                        d.pos += n;
                        d.skipSubBlocks();
                    } else {
                        d.skipSubBlocks();
                    }
                },
                0x2C => {
                    if (d.pos + 9 > d.bytes.len) return null;
                    const hdr = d.bytes[d.pos..][0..9];
                    d.pos += 9;
                    var rect: [4]u16 = .{
                        std.mem.readInt(u16, hdr[0..2], .little),
                        std.mem.readInt(u16, hdr[2..4], .little),
                        std.mem.readInt(u16, hdr[4..6], .little),
                        std.mem.readInt(u16, hdr[6..8], .little),
                    };
                    const p = hdr[8];
                    var pal = d.global_pal;
                    if (p & 0x80 != 0) {
                        const n: usize = @as(usize, 3) << @intCast((p & 7) + 1);
                        if (d.pos + n > d.bytes.len) return null;
                        pal = d.bytes[d.pos .. d.pos + n];
                        d.pos += n;
                    }
                    // clip to the canvas
                    if (rect[0] >= d.w or rect[1] >= d.h) {
                        rect[2] = 0;
                        rect[3] = 0;
                    }
                    rect[2] = @min(rect[2], d.w - rect[0]);
                    rect[3] = @min(rect[3], d.h - rect[1]);
                    if (dispose == 3) {
                        if (d.saved == null) d.saved = d.gpa.alloc(u8, d.canvas.len) catch null;
                        if (d.saved) |s| @memcpy(s, d.canvas);
                    }
                    const ok = d.drawImage(rect, p & 0x40 != 0, pal orelse return null, transparent);
                    if (!ok) return null;
                    d.pending_dispose = dispose;
                    d.pending_rect = rect;
                    return .{ .delay = delay };
                },
                0x3B => return null,
                else => return null,
            }
        }
    }

    fn clearRect(d: *Decoder, r: [4]u16) void {
        var y: usize = r[1];
        while (y < @as(usize, r[1]) + r[3]) : (y += 1) {
            const start = (y * d.w + r[0]) * 4;
            @memset(d.canvas[start .. start + @as(usize, r[2]) * 4], 0);
        }
    }

    /// LZW-decode the image data block into the canvas rectangle.
    fn drawImage(d: *Decoder, r: [4]u16, interlaced: bool, pal: []const u8, transparent: ?u8) bool {
        const min_code = d.byte() orelse return false;
        if (min_code < 2 or min_code > 8) return false;
        const clear: u16 = @as(u16, 1) << @intCast(min_code);
        const eoi = clear + 1;
        var code_size: u5 = @intCast(min_code + 1);
        var next_code: u16 = eoi + 1;
        var prev: ?u16 = null;
        var first: u8 = 0;

        // bit reader over the sub-blocks
        var block_left: usize = 0;
        var bits: u32 = 0;
        var nbits: u5 = 0;

        const rw: usize = r[2];
        const rh: usize = r[3];
        const total = rw * rh;
        var out: usize = 0; // pixels written, in decode order
        var col: usize = 0;
        var line: usize = 0; // which row of the rectangle, in decode order
        var pass: u8 = 0;
        var y: usize = 0; // the canvas-relative row for `line`

        var sp: usize = 0;
        while (true) {
            // fill bits; data that stops short still shows what it had
            while (nbits < code_size) {
                if (block_left == 0) {
                    const n = d.byte() orelse return out > 0;
                    if (n == 0) return out > 0;
                    block_left = n;
                }
                const b = d.byte() orelse return out > 0;
                block_left -= 1;
                bits |= @as(u32, b) << nbits;
                nbits += 8;
            }
            const code: u16 = @intCast(bits & ((@as(u32, 1) << code_size) - 1));
            bits >>= code_size;
            nbits -= code_size;

            if (code == clear) {
                code_size = @intCast(min_code + 1);
                next_code = eoi + 1;
                prev = null;
                continue;
            }
            if (code == eoi) break;

            // unroll the code onto the stack
            var cur = code;
            if (prev == null) {
                if (code >= clear) return false;
                first = @intCast(code);
                d.stack[0] = first;
                sp = 1;
            } else {
                if (code > next_code) return false;
                sp = 0;
                if (code == next_code) {
                    d.stack[sp] = first;
                    sp += 1;
                    cur = prev.?;
                }
                while (cur >= clear) {
                    d.stack[sp] = d.suffix[cur];
                    sp += 1;
                    cur = d.prefix[cur];
                }
                first = @intCast(cur);
                d.stack[sp] = first;
                sp += 1;
                if (next_code < 4096) {
                    d.prefix[next_code] = prev.?;
                    d.suffix[next_code] = first;
                    next_code += 1;
                    if (next_code == (@as(u16, 1) << @as(u4, @intCast(code_size))) and code_size < 12) code_size += 1;
                }
            }
            prev = code;

            // pop the stack into the row, flushing rows into the canvas
            while (sp > 0) {
                sp -= 1;
                if (out >= total) break;
                d.row[col] = d.stack[sp];
                col += 1;
                out += 1;
                if (col == rw) {
                    d.flushRow(r, y, pal, transparent);
                    col = 0;
                    line += 1;
                    if (interlaced) {
                        const steps = [_]usize{ 8, 8, 4, 2 };
                        const starts = [_]usize{ 0, 4, 2, 1 };
                        y += steps[pass];
                        while (y >= rh and pass < 3) {
                            pass += 1;
                            y = starts[pass];
                        }
                    } else y = line;
                }
            }
            if (out >= total) {
                // drain the rest of the sub-blocks so the next block lines up
                d.pos += block_left;
                d.skipSubBlocks();
                return true;
            }
        }
        d.pos += block_left;
        d.skipSubBlocks();
        return true;
    }

    fn flushRow(d: *Decoder, r: [4]u16, y: usize, pal: []const u8, transparent: ?u8) void {
        if (y >= r[3]) return;
        const cy = @as(usize, r[1]) + y;
        var dst = d.canvas[(cy * d.w + r[0]) * 4 ..];
        const npal = pal.len / 3;
        for (d.row[0..r[2]], 0..) |ix8, i| {
            if (transparent != null and ix8 == transparent.?) continue;
            const ix: usize = ix8;
            if (ix >= npal) continue;
            dst[i * 4] = pal[ix * 3];
            dst[i * 4 + 1] = pal[ix * 3 + 1];
            dst[i * 4 + 2] = pal[ix * 3 + 2];
            dst[i * 4 + 3] = 255;
        }
    }
};
