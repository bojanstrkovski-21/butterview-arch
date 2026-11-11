# Do not skip a folder the probe could not prove empty

## Problem

The next-folder step counts hidden names while they are hidden, and it treats a 4000-entry scan with zero images as an empty folder.

## Change

`butterview-arch/src/main.zig`

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
