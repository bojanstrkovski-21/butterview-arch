const std = @import("std");

pub fn build(b: *std.Build) void {
    // Baseline x86-64 unless told otherwise: a binary built here must run
    // on every machine it is copied to, not only this one's CPU.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // SDL3 normally comes from the system's -dev packages. -Dlocal-sdl uses
    // the same Debian packages unpacked into .deps/ next to the source, so
    // it builds and runs without installing anything.
    const local = b.option(bool, "local-sdl", "use SDL3 unpacked in .deps/") orelse false;
    if (local) {
        mod.addIncludePath(b.path(".deps/usr/include"));
        mod.addLibraryPath(b.path(".deps/usr/lib/x86_64-linux-gnu"));
        mod.addRPath(b.path(".deps/usr/lib/x86_64-linux-gnu"));
    }
    mod.linkSystemLibrary("SDL3", .{ .use_pkg_config = if (local) .no else .yes });
    mod.linkSystemLibrary("SDL3_image", .{ .use_pkg_config = if (local) .no else .yes });
    mod.linkSystemLibrary("SDL3_ttf", .{ .use_pkg_config = if (local) .no else .yes });
    mod.linkSystemLibrary("turbojpeg", .{ .use_pkg_config = if (local) .no else .yes });
    // The desktop portal (color scheme, accent, set the wallpaper) is a
    // D-Bus call; libdbus is the library every desktop already has.
    mod.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .yes });

    // The version the binary reports (--version, window metadata). The
    // package build passes the release tag; a plain `zig build` says so.
    const version = b.option([]const u8, "version", "version string reported by --version") orelse "0.1.0-dev";
    const opts = b.addOptions();
    opts.addOption([:0]const u8, "version", b.allocator.dupeZ(u8, version) catch @panic("oom"));
    mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{ .name = "butterview", .root_module = mod });
    // Position-independent, as Debian expects of every binary (hardening).
    exe.pie = true;
    b.installArtifact(exe);
}
