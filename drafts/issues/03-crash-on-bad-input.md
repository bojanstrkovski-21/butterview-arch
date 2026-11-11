Title: A short JPEG APP1 segment or an out-of-range theme color can crash

Text:

Two crashes on bad input. A JPEG APP1 segment shorter than an Exif header is sliced past its end. A theme `rgb()` or `rgba()` channel outside 0..255 is turned into a byte without clamping. The change reads an APP1 segment only when the Exif header fits inside it, and clamps each theme channel to 0..255 and alpha to 0..1.

## Short JPEG APP1

`src/exif.zig`

```diff
         if (marker == 0xda) return info;
-        if (marker == 0xe1 and i + 10 <= d.len and std.mem.eql(u8, d[i + 4 .. i + 10], "Exif\x00\x00")) {
-            const body = d[i + 10 .. @min(d.len, i + 2 + seg)];
+        const next = std.math.add(usize, i + 2, seg) catch return info;
+        if (marker == 0xe1 and seg >= 8 and i + 10 <= d.len and i + 10 <= next and std.mem.eql(u8, d[i + 4 .. i + 10], "Exif\x00\x00")) {
+            const body = d[i + 10 .. @min(d.len, next)];
             if (body.len < 8) return info;
```

```diff
             return info;
         }
-        i += 2 + seg;
+        if (next > d.len) return info;
+        i = next;
```

## Theme rgb()

`src/theme.zig`

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
