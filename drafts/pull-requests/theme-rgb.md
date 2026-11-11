# Clamp theme rgb() channels

## Problem

A theme color outside 0..255 can crash when it is turned into a byte.

## Change

`butterview-arch/src/theme.zig`

```diff
-        return .{ .r = r, .g = g, .b = b, .a = a };
+        return .{
+            .r = std.math.clamp(r, 0, 255),
+            .g = std.math.clamp(g, 0, 255),
+            .b = std.math.clamp(b, 0, 255),
+            .a = std.math.clamp(a, 0, 1),
+        };
```

```diff
-    const bg: Rgb = .{ .r = @intFromFloat(bg_c.r), .g = @intFromFloat(bg_c.g), .b = @intFromFloat(bg_c.b) };
+    const bg: Rgb = .{
+        .r = @intFromFloat(std.math.clamp(bg_c.r, 0, 255)),
+        .g = @intFromFloat(std.math.clamp(bg_c.g, 0, 255)),
+        .b = @intFromFloat(std.math.clamp(bg_c.b, 0, 255)),
+    };
```
