# Ignore a JPEG APP1 segment that is too short for Exif

## Problem

A short APP1 segment is sliced as if it held an Exif header. That can crash.

## Change

`butterview-arch/src/exif.zig`

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
