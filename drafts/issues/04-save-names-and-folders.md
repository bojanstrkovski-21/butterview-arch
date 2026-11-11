Title: Save names overwrite -99, and the next-folder step can skip a real folder

Text:

Two places treat "could not tell" as "empty". When every save name through `-99` exists, the last name is overwritten, and a failed name check is treated as a free name. The next-folder step counts hidden names while they are hidden, and a scan that stops at 4000 entries with zero images looks empty, so a folder that still opens is skipped. The change refuses the save when no name through `-99` is free, and it also refuses the save when the check fails for any other reason. Hidden names are ignored when they are off, and a folder the scan could not prove empty is entered. The badge can still show 0.

Is stopping at `-99` what you want, or should the number keep going? Is entering a folder the probe could not prove empty better than skipping it?

## Save names

`src/main.zig`

```diff
         var n: u32 = 1;
+        var free_name = false;
         while (n < 100) : (n += 1) {
             name = (if (n == 1)
                 std.fmt.bufPrint(&name_buf, "{s}-{s}.{s}", .{ stem, what, out_ext })
             else
                 std.fmt.bufPrint(&name_buf, "{s}-{s}-{d}.{s}", .{ stem, what, n, out_ext })) catch return;
             path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ a.dir, name }) catch return;
-            var pi: c.SDL_PathInfo = undefined;
-            if (!c.SDL_GetPathInfo(path.ptr, &pi)) break;
+            const rc = std.c.access(path.ptr, std.c.F_OK);
+            if (rc != 0) switch (std.c.errno(rc)) {
+                .NOENT => {
+                    free_name = true;
+                    break;
+                },
+                else => {
+                    a.say("Could not save {s}", .{name});
+                    return;
+                },
+            };
+        }
+        if (!free_name) {
+            a.say("Could not save: names through -99 are taken", .{});
+            return;
         }
```

## Folder probe

`src/main.zig`

```diff
-        try v.nodes.insert(gpa, at, .{ .path = pth, .name = nm, .depth = depth, .count = countImages(pth) });
+        try v.nodes.insert(gpa, at, .{ .path = pth, .name = nm, .depth = depth, .count = countImages(pth).images });
```

```diff
-    const Count = struct { images: usize = 0, seen: usize = 0 };
+    const Count = struct { images: usize = 0, seen: usize = 0, uncertain: bool = false };
+    const ImageCount = struct { images: usize = 0, uncertain: bool = false };

-    fn countImages(path: []const u8) usize {
-        const z = gpa.dupeZ(u8, if (std.mem.eql(u8, path, "/")) "/." else path) catch return 0;
+    fn countImages(path: []const u8) ImageCount {
+        const z = gpa.dupeZ(u8, if (std.mem.eql(u8, path, "/")) "/." else path) catch return .{};
         defer gpa.free(z);
         var cnt: Count = .{};
         _ = c.SDL_EnumerateDirectory(z.ptr, countCb, &cnt);
-        return cnt.images;
+        return .{ .images = cnt.images, .uncertain = cnt.uncertain };
     }
```

```diff
         const cnt: *Count = @ptrCast(@alignCast(userdata.?));
+        const name = std.mem.span(fname);
+        if (name.len > 0 and name[0] == '.' and !show_hidden) return c.SDL_ENUM_CONTINUE;
         cnt.seen += 1;
-        if (isImage(std.mem.span(fname))) cnt.images += 1;
-        return if (cnt.images >= count_cap or cnt.seen >= scan_cap) c.SDL_ENUM_SUCCESS else c.SDL_ENUM_CONTINUE;
+        if (isImage(name)) cnt.images += 1;
+        if (cnt.images >= count_cap) return c.SDL_ENUM_SUCCESS;
+        if (cnt.seen >= scan_cap) {
+            if (cnt.images == 0) cnt.uncertain = true;
+            return c.SDL_ENUM_SUCCESS;
+        }
+        return c.SDL_ENUM_CONTINUE;
```

```diff
-            if (FolderView.countImages(full) == 0) continue;
+            const counted = FolderView.countImages(full);
+            if (counted.images == 0 and !counted.uncertain) continue;
```
