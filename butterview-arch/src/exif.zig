// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Drew (justaguylinux)

//! Just enough EXIF: which way up, and what a photographer would ask about.
//! Reads the head of a JPEG; anything it cannot follow it leaves empty.

const std = @import("std");

pub fn Text(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,
        pub fn get(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
        fn set(t: *@This(), s: []const u8) void {
            const v = std.mem.trim(u8, s, " \x00\t\r\n");
            const n = @min(v.len, N);
            @memcpy(t.buf[0..n], v[0..n]);
            t.len = n;
        }
    };
}

pub const Ratio = struct {
    num: u32 = 0,
    den: u32 = 0,
    pub fn value(r: Ratio) f64 {
        return if (r.den == 0) 0 else @as(f64, @floatFromInt(r.num)) / @as(f64, @floatFromInt(r.den));
    }
};

pub const Info = struct {
    found: bool = false,
    /// 1..8, 1 when the file says nothing.
    orientation: u8 = 1,
    make: Text(48) = .{},
    model: Text(64) = .{},
    lens: Text(64) = .{},
    taken: Text(24) = .{},
    exposure: Ratio = .{},
    fnumber: Ratio = .{},
    focal: Ratio = .{},
    iso: u32 = 0,
    has_gps: bool = false,
    lat: f64 = 0,
    lon: f64 = 0,
};

const Tiff = struct {
    d: []const u8,
    le: bool,

    fn u16at(t: Tiff, o: usize) u16 {
        if (o + 2 > t.d.len) return 0;
        return if (t.le) @as(u16, t.d[o]) | (@as(u16, t.d[o + 1]) << 8) else (@as(u16, t.d[o]) << 8) | t.d[o + 1];
    }
    fn u32at(t: Tiff, o: usize) u32 {
        if (o + 4 > t.d.len) return 0;
        return if (t.le)
            @as(u32, t.d[o]) | (@as(u32, t.d[o + 1]) << 8) | (@as(u32, t.d[o + 2]) << 16) | (@as(u32, t.d[o + 3]) << 24)
        else
            (@as(u32, t.d[o]) << 24) | (@as(u32, t.d[o + 1]) << 16) | (@as(u32, t.d[o + 2]) << 8) | t.d[o + 3];
    }
    /// Where an entry's value lives: inside the entry when it fits in four
    /// bytes, else at the offset the entry holds.
    fn valueAt(t: Tiff, entry: usize) usize {
        const typ = t.u16at(entry + 2);
        const count: usize = t.u32at(entry + 4);
        const unit: usize = switch (typ) {
            1, 2, 7 => 1,
            3 => 2,
            4, 9 => 4,
            5, 10 => 8,
            else => 1,
        };
        return if (unit * count <= 4) entry + 8 else t.u32at(entry + 8);
    }
    fn ascii(t: Tiff, entry: usize) []const u8 {
        const count: usize = t.u32at(entry + 4);
        const at = t.valueAt(entry);
        if (at >= t.d.len) return "";
        return t.d[at..@min(t.d.len, at + count)];
    }
    fn ratio(t: Tiff, entry: usize, index: usize) Ratio {
        const at = t.valueAt(entry) + index * 8;
        return .{ .num = t.u32at(at), .den = t.u32at(at + 4) };
    }
};

fn degrees(t: Tiff, entry: usize) f64 {
    return t.ratio(entry, 0).value() + t.ratio(entry, 1).value() / 60 + t.ratio(entry, 2).value() / 3600;
}

/// `d` is the start of a JPEG file (64 KB is plenty for the EXIF block).
pub fn parse(d: []const u8) Info {
    var info: Info = .{};
    if (d.len < 4 or d[0] != 0xff or d[1] != 0xd8) return info;
    var i: usize = 2;
    while (i + 4 <= d.len) {
        if (d[i] != 0xff) return info;
        const marker = d[i + 1];
        const seg: usize = (@as(usize, d[i + 2]) << 8) | d[i + 3];
        if (marker == 0xda) return info;
        const next = std.math.add(usize, i + 2, seg) catch return info;
        if (marker == 0xe1 and seg >= 8 and i + 10 <= d.len and i + 10 <= next and std.mem.eql(u8, d[i + 4 .. i + 10], "Exif\x00\x00")) {
            const body = d[i + 10 .. @min(d.len, next)];
            if (body.len < 8) return info;
            const t: Tiff = .{ .d = body, .le = body[0] == 'I' };
            info.found = true;

            var exif_ifd: usize = 0;
            var gps_ifd: usize = 0;
            const ifd0: usize = t.u32at(4);
            var k: usize = 0;
            while (k < t.u16at(ifd0)) : (k += 1) {
                const e = ifd0 + 2 + k * 12;
                switch (t.u16at(e)) {
                    0x010f => info.make.set(t.ascii(e)),
                    0x0110 => info.model.set(t.ascii(e)),
                    0x0112 => {
                        const v = t.u16at(e + 8);
                        if (v >= 1 and v <= 8) info.orientation = @intCast(v);
                    },
                    0x8769 => exif_ifd = t.u32at(e + 8),
                    0x8825 => gps_ifd = t.u32at(e + 8),
                    else => {},
                }
            }
            if (exif_ifd != 0) {
                k = 0;
                while (k < t.u16at(exif_ifd)) : (k += 1) {
                    const e = exif_ifd + 2 + k * 12;
                    switch (t.u16at(e)) {
                        0x829a => info.exposure = t.ratio(e, 0),
                        0x829d => info.fnumber = t.ratio(e, 0),
                        0x8827 => info.iso = t.u16at(e + 8),
                        0x9003 => info.taken.set(t.ascii(e)),
                        0x920a => info.focal = t.ratio(e, 0),
                        0xa434 => info.lens.set(t.ascii(e)),
                        else => {},
                    }
                }
            }
            if (gps_ifd != 0) {
                var south = false;
                var west = false;
                var got: u8 = 0;
                k = 0;
                while (k < t.u16at(gps_ifd)) : (k += 1) {
                    const e = gps_ifd + 2 + k * 12;
                    switch (t.u16at(e)) {
                        1 => south = t.d[@min(t.d.len - 1, e + 8)] == 'S',
                        2 => {
                            info.lat = degrees(t, e);
                            got |= 1;
                        },
                        3 => west = t.d[@min(t.d.len - 1, e + 8)] == 'W',
                        4 => {
                            info.lon = degrees(t, e);
                            got |= 2;
                        },
                        else => {},
                    }
                }
                if (got == 3) {
                    info.has_gps = true;
                    if (south) info.lat = -info.lat;
                    if (west) info.lon = -info.lon;
                }
            }
            return info;
        }
        if (next > d.len) return info;
        i = next;
    }
    return info;
}
