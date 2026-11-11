// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Drew (justaguylinux)

//! The XDG desktop portal, over libdbus: the one way to ask any desktop
//! (GNOME, KDE, COSMIC, anything with a portal backend) for its color
//! scheme and accent, and for its folder chooser. Nothing here knows
//! which desktop it is talking to.
//!
//! libdbus rather than a shelled-out `busctl`: a portal request lives as
//! long as the caller's bus connection, so a one-shot command would have
//! its request closed, and the desktop's dialog with it, the
//! moment it exited. The connection here stays open until the desktop
//! answers.

const std = @import("std");
pub const c = @cImport({
    @cInclude("dbus/dbus.h");
    @cInclude("time.h");
});

/// A monotonic clock in milliseconds, for deadlines.
fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

const dest = "org.freedesktop.portal.Desktop";
const path = "/org/freedesktop/portal/desktop";

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Scheme = enum { unknown, dark, light };

/// org.freedesktop.appearance, as the Settings portal reports it.
pub const Appearance = struct {
    scheme: Scheme = .unknown,
    accent: ?Rgb = null,
};

/// What the folder chooser came back with.
pub const Chosen = struct {
    /// the folder or file picked, owned by the caller; null when none
    path: ?[]u8 = null,
    status: enum { chosen, canceled, unavailable, failed } = .failed,
};

fn connect() ?*c.DBusConnection {
    // a private connection: it is closed when done, which also ends any
    // request still open on it
    const conn = c.dbus_bus_get_private(c.DBUS_BUS_SESSION, null) orelse return null;
    c.dbus_connection_set_exit_on_disconnect(conn, 0);
    return conn;
}

/// Send and wait for the reply, which may be an error message (its name
/// says which). DBusError is not used: its bitfields make it opaque to
/// Zig, and the reply carries the same information.
fn call(conn: *c.DBusConnection, msg: *c.DBusMessage, timeout_ms: c_int, stop: *const std.atomic.Value(bool)) ?*c.DBusMessage {
    var pending: ?*c.DBusPendingCall = null;
    if (c.dbus_connection_send_with_reply(conn, msg, &pending, timeout_ms) == 0) return null;
    const p = pending orelse return null;
    defer c.dbus_pending_call_unref(p);
    const deadline = nowMs() + timeout_ms;
    while (nowMs() < deadline) {
        if (stop.load(.acquire)) {
            c.dbus_pending_call_cancel(p);
            return null;
        }
        if (c.dbus_pending_call_get_completed(p) != 0) break;
        if (c.dbus_connection_read_write_dispatch(conn, 200) == 0) return null;
    }
    if (c.dbus_pending_call_get_completed(p) == 0) return null;
    return c.dbus_pending_call_steal_reply(p);
}

fn isError(reply: *c.DBusMessage, name: [*:0]const u8) bool {
    return c.dbus_message_is_error(reply, name) != 0;
}

fn appendString(it: *c.DBusMessageIter, value: [*:0]const u8) void {
    var p: ?[*:0]const u8 = value;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_STRING, @ptrCast(&p));
}

fn disconnect(conn: *c.DBusConnection) void {
    c.dbus_connection_close(conn);
    c.dbus_connection_unref(conn);
}

/// Walk into nested variants until something that is not a variant.
fn unwrapVariants(it: *c.DBusMessageIter, depth: u8) void {
    var i: u8 = 0;
    while (i < depth and c.dbus_message_iter_get_arg_type(it) == c.DBUS_TYPE_VARIANT) : (i += 1) {
        var inner: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(it, &inner);
        it.* = inner;
    }
}

/// Settings.ReadOne(namespace, key); the older Read on portals that lack
/// it. The reply is a variant (Read: a variant in a variant).
fn readSetting(conn: *c.DBusConnection, key: [*:0]const u8, timeout_ms: c_int, stop: *const std.atomic.Value(bool)) ?*c.DBusMessage {
    const methods = [_][*:0]const u8{ "ReadOne", "Read" };
    for (methods) |m| {
        const msg = c.dbus_message_new_method_call(dest, path, "org.freedesktop.portal.Settings", m) orelse return null;
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(msg, &it);
        appendString(&it, "org.freedesktop.appearance");
        appendString(&it, key);
        const reply = call(conn, msg, timeout_ms, stop) orelse return null;
        if (c.dbus_message_get_type(reply) != c.DBUS_MESSAGE_TYPE_ERROR) return reply;
        // an unknown method means an older portal: try the next name; any
        // other error (no portal, no such key) is the answer
        const unknown = isError(reply, c.DBUS_ERROR_UNKNOWN_METHOD);
        c.dbus_message_unref(reply);
        if (!unknown) return null;
    }
    return null;
}

/// The color scheme in a Settings reply: a variant (Read: a variant in
/// a variant) holding 0 no preference, 1 prefer dark, 2 prefer light.
pub fn parseScheme(reply: *c.DBusMessage) Scheme {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &it) == 0) return .unknown;
    unwrapVariants(&it, 2);
    if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_UINT32) return .unknown;
    var v: u32 = 0;
    c.dbus_message_iter_get_basic(&it, @ptrCast(&v));
    return switch (v) {
        1 => .dark,
        2 => .light,
        else => .unknown,
    };
}

/// The accent in a Settings reply: a variant holding (ddd) in 0..1; a
/// value out of that range means the desktop has no accent set.
pub fn parseAccent(reply: *c.DBusMessage) ?Rgb {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &it) == 0) return null;
    unwrapVariants(&it, 2);
    if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_STRUCT) return null;
    var s: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&it, &s);
    var rgb: [3]f64 = .{ -1, -1, -1 };
    for (&rgb) |*ch| {
        if (c.dbus_message_iter_get_arg_type(&s) != c.DBUS_TYPE_DOUBLE) return null;
        c.dbus_message_iter_get_basic(&s, @ptrCast(ch));
        _ = c.dbus_message_iter_next(&s);
    }
    for (rgb) |ch| {
        if (!(ch >= 0 and ch <= 1)) return null;
    }
    return .{
        .r = @intFromFloat(@round(rgb[0] * 255)),
        .g = @intFromFloat(@round(rgb[1] * 255)),
        .b = @intFromFloat(@round(rgb[2] * 255)),
    };
}

/// Color scheme and accent color, or what the desktop does not say.
/// Blocks for the round trip; `timeout_ms` bounds a portal that has to be
/// started first.
pub fn appearance(timeout_ms: c_int, stop: *const std.atomic.Value(bool)) Appearance {
    var out: Appearance = .{};
    const conn = connect() orelse return out;
    defer disconnect(conn);
    if (readSetting(conn, "color-scheme", timeout_ms, stop)) |reply| {
        defer c.dbus_message_unref(reply);
        out.scheme = parseScheme(reply);
    }
    if (stop.load(.acquire)) return out;
    if (readSetting(conn, "accent-color", timeout_ms, stop)) |reply| {
        defer c.dbus_message_unref(reply);
        out.accent = parseAccent(reply);
    }
    return out;
}

fn appendDictEntryString(dict: *c.DBusMessageIter, key: [*:0]const u8, value: [*:0]const u8) void {
    var entry: c.DBusMessageIter = undefined;
    var variant: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry);
    appendString(&entry, key);
    _ = c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, "s", &variant);
    appendString(&variant, value);
    _ = c.dbus_message_iter_close_container(&entry, &variant);
    _ = c.dbus_message_iter_close_container(dict, &entry);
}

fn appendDictEntryBool(dict: *c.DBusMessageIter, key: [*:0]const u8, value: bool) void {
    var entry: c.DBusMessageIter = undefined;
    var variant: c.DBusMessageIter = undefined;
    var val: c.dbus_bool_t = if (value) 1 else 0;
    _ = c.dbus_message_iter_open_container(dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry);
    appendString(&entry, key);
    _ = c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, "b", &variant);
    _ = c.dbus_message_iter_append_basic(&variant, c.DBUS_TYPE_BOOLEAN, @ptrCast(&val));
    _ = c.dbus_message_iter_close_container(&entry, &variant);
    _ = c.dbus_message_iter_close_container(dict, &entry);
}

/// One portal request: the answer comes as a Response signal on a request
/// object whose path is known in advance from our unique name and a token,
/// so the match is in place before the call and no answer can slip past.
const Request = struct {
    token: [:0]u8,
    handle: [:0]u8,

    fn begin(gpa: std.mem.Allocator, conn: *c.DBusConnection) ?Request {
        const unique = std.mem.span(c.dbus_bus_get_unique_name(conn) orelse return null);
        var sender: std.ArrayList(u8) = .empty;
        defer sender.deinit(gpa);
        for (unique) |ch| {
            if (ch == ':') continue;
            sender.append(gpa, if (ch == '.') '_' else ch) catch return null;
        }
        var seed: u64 = @bitCast(nowMs());
        seed ^= @intFromPtr(conn);
        const token = std.fmt.allocPrintSentinel(gpa, "butterview_{x}", .{seed}, 0) catch return null;
        const handle = std.fmt.allocPrintSentinel(gpa, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender.items, token }, 0) catch {
            gpa.free(token);
            return null;
        };
        watch(gpa, conn, handle);
        return .{ .token = token, .handle = handle };
    }

    fn deinit(r: Request, gpa: std.mem.Allocator) void {
        gpa.free(r.token);
        gpa.free(r.handle);
    }

    fn watch(gpa: std.mem.Allocator, conn: *c.DBusConnection, handle: [*:0]const u8) void {
        const rule = std.fmt.allocPrintSentinel(gpa, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{handle}, 0) catch return;
        defer gpa.free(rule);
        c.dbus_bus_add_match(conn, rule.ptr, null);
        c.dbus_connection_flush(conn);
    }

    const Answer = struct {
        /// 0 success, 1 the user canceled, 2 something else; 3 here when
        /// the interface is not there at all (no portal, or no backend
        /// for it), 4 when no answer came in time
        code: u32,
        /// the Response signal, for its results, when there was one
        signal: ?*c.DBusMessage = null,
    };

    /// Make the call and wait for the desktop's answer, up to `timeout_ms`.
    /// Null when the call itself could not be made.
    fn send(r: Request, gpa: std.mem.Allocator, conn: *c.DBusConnection, msg: *c.DBusMessage, timeout_ms: i64, stop: *const std.atomic.Value(bool)) ?Answer {
        const reply = call(conn, msg, 30_000, stop) orelse return null;
        if (c.dbus_message_get_type(reply) == c.DBUS_MESSAGE_TYPE_ERROR) {
            // no portal running and none to start, or one without a
            // backend for this: the interface is simply not there
            defer c.dbus_message_unref(reply);
            if (isError(reply, c.DBUS_ERROR_SERVICE_UNKNOWN) or
                isError(reply, c.DBUS_ERROR_UNKNOWN_METHOD) or
                isError(reply, c.DBUS_ERROR_UNKNOWN_INTERFACE) or
                isError(reply, c.DBUS_ERROR_UNKNOWN_OBJECT) or
                isError(reply, c.DBUS_ERROR_NAME_HAS_NO_OWNER))
                return .{ .code = 3 };
            return .{ .code = 2 };
        }
        // The reply names the request object. Portals honor handle_token,
        // but if this one did not, listen on the path it chose instead.
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(gpa);
        want.appendSlice(gpa, r.handle) catch return null;
        var rit0: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &rit0) != 0 and c.dbus_message_iter_get_arg_type(&rit0) == c.DBUS_TYPE_OBJECT_PATH) {
            var got: ?[*:0]const u8 = null;
            c.dbus_message_iter_get_basic(&rit0, @ptrCast(&got));
            if (got) |h| {
                if (!std.mem.eql(u8, std.mem.span(h), r.handle)) {
                    want.clearRetainingCapacity();
                    want.appendSlice(gpa, std.mem.span(h)) catch return null;
                    watch(gpa, conn, h);
                }
            }
        }
        c.dbus_message_unref(reply);
        const want_path: []const u8 = want.items;

        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            if (stop.load(.acquire)) return .{ .code = 1 };
            if (c.dbus_connection_read_write(conn, 200) == 0) return .{ .code = 2 }; // disconnected
            while (c.dbus_connection_pop_message(conn)) |m| {
                if (c.dbus_message_is_signal(m, "org.freedesktop.portal.Request", "Response") == 0) {
                    c.dbus_message_unref(m);
                    continue;
                }
                const p = c.dbus_message_get_path(m) orelse {
                    c.dbus_message_unref(m);
                    continue;
                };
                if (!std.mem.eql(u8, std.mem.span(p), want_path)) {
                    c.dbus_message_unref(m);
                    continue;
                }
                var rit: c.DBusMessageIter = undefined;
                if (c.dbus_message_iter_init(m, &rit) == 0 or c.dbus_message_iter_get_arg_type(&rit) != c.DBUS_TYPE_UINT32) {
                    c.dbus_message_unref(m);
                    return .{ .code = 2 };
                }
                var code: u32 = 2;
                c.dbus_message_iter_get_basic(&rit, @ptrCast(&code));
                return .{ .code = code, .signal = m };
            }
        }
        return .{ .code = 4 };
    }
};

fn appendDictEntryBytes(dict: *c.DBusMessageIter, key: [*:0]const u8, value: [:0]const u8) void {
    // a path as the portal wants it: a byte array with its NUL
    var entry: c.DBusMessageIter = undefined;
    var variant: c.DBusMessageIter = undefined;
    var arr: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(dict, c.DBUS_TYPE_DICT_ENTRY, null, &entry);
    appendString(&entry, key);
    _ = c.dbus_message_iter_open_container(&entry, c.DBUS_TYPE_VARIANT, "ay", &variant);
    _ = c.dbus_message_iter_open_container(&variant, c.DBUS_TYPE_ARRAY, "y", &arr);
    const bytes: [*]const u8 = value.ptr;
    _ = c.dbus_message_iter_append_fixed_array(&arr, c.DBUS_TYPE_BYTE, @ptrCast(&bytes), @intCast(value.len + 1));
    _ = c.dbus_message_iter_close_container(&variant, &arr);
    _ = c.dbus_message_iter_close_container(&entry, &variant);
    _ = c.dbus_message_iter_close_container(dict, &entry);
}

/// A `file://` URI back to a path, percent-decoded. Null for any other
/// scheme.
fn uriPath(gpa: std.mem.Allocator, uri: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    // file://localhost/… is the same as file:///…
    if (std.mem.startsWith(u8, rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const v = std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16) catch {
                out.append(gpa, rest[i]) catch return null;
                continue;
            };
            out.append(gpa, v) catch return null;
            i += 2;
        } else out.append(gpa, rest[i]) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// FileChooser.OpenFile for a folder (or an image inside one): the
/// desktop's own dialog, opened on `start`, placed over `parent`. Blocks
/// until the answer or `timeout_ms`.
pub fn chooseFolder(gpa: std.mem.Allocator, start: ?[]const u8, parent: [*:0]const u8, stop: *const std.atomic.Value(bool), timeout_ms: i64) Chosen {
    const conn = connect() orelse return .{ .status = .unavailable };
    defer disconnect(conn);
    const req = Request.begin(gpa, conn) orelse return .{};
    defer req.deinit(gpa);

    const msg = c.dbus_message_new_method_call(dest, path, "org.freedesktop.portal.FileChooser", "OpenFile") orelse return .{};
    defer c.dbus_message_unref(msg);
    var it: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(msg, &it);
    appendString(&it, parent);
    appendString(&it, "Open a folder");
    var dict: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "{sv}", &dict);
    appendDictEntryString(&dict, "handle_token", req.token.ptr);
    appendDictEntryString(&dict, "accept_label", "Open");
    appendDictEntryBool(&dict, "directory", true);
    appendDictEntryBool(&dict, "modal", true);
    if (start) |s| {
        const z = gpa.dupeZ(u8, s) catch null;
        if (z) |zz| {
            defer gpa.free(zz);
            appendDictEntryBytes(&dict, "current_folder", zz);
        }
    }
    _ = c.dbus_message_iter_close_container(&it, &dict);

    const answer = req.send(gpa, conn, msg, timeout_ms, stop) orelse return .{};
    defer if (answer.signal) |m| c.dbus_message_unref(m);
    switch (answer.code) {
        0 => {},
        1, 4 => return .{ .status = .canceled },
        3 => return .{ .status = .unavailable },
        else => return .{},
    }
    // results: a{sv} with "uris" as the chosen paths
    const m = answer.signal orelse return .{};
    var rit: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_init(m, &rit);
    if (c.dbus_message_iter_next(&rit) == 0 or c.dbus_message_iter_get_arg_type(&rit) != c.DBUS_TYPE_ARRAY) return .{};
    var entries: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&rit, &entries);
    while (c.dbus_message_iter_get_arg_type(&entries) == c.DBUS_TYPE_DICT_ENTRY) : (_ = c.dbus_message_iter_next(&entries)) {
        var entry: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&entries, &entry);
        var key: ?[*:0]const u8 = null;
        c.dbus_message_iter_get_basic(&entry, @ptrCast(&key));
        if (key == null or !std.mem.eql(u8, std.mem.span(key.?), "uris")) continue;
        if (c.dbus_message_iter_next(&entry) == 0) continue;
        var val: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&entry, &val);
        unwrapVariants(&val, 2);
        if (c.dbus_message_iter_get_arg_type(&val) != c.DBUS_TYPE_ARRAY) continue;
        var uris: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&val, &uris);
        if (c.dbus_message_iter_get_arg_type(&uris) != c.DBUS_TYPE_STRING) continue;
        var u: ?[*:0]const u8 = null;
        c.dbus_message_iter_get_basic(&uris, @ptrCast(&u));
        const uri = std.mem.span(u orelse continue);
        const p = uriPath(gpa, uri) orelse return .{};
        return .{ .path = p, .status = .chosen };
    }
    return .{};
}
