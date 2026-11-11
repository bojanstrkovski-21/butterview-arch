# Save the GIF frame on screen

## Problem

Saving a GIF writes the still decode of the file, which is the first frame.

## Change

`butterview-arch/src/main.zig`

```diff
+    fn gifSurface(a: *App) ?*c.SDL_Surface {
+        const f = a.currentFull() orelse return null;
+        if (f.anim == null) return null;
+        const tex = f.tex orelse return null;
+        const w: c_int = @intFromFloat(@max(f.tex_w, 1));
+        const h: c_int = @intFromFloat(@max(f.h, 1));
+        var pixels: ?*anyopaque = null;
+        var pitch: c_int = 0;
+        if (!c.SDL_LockTexture(tex, null, &pixels, &pitch)) return null;
+        defer c.SDL_UnlockTexture(tex);
+        const src = pixels orelse return null;
+        const out = c.SDL_CreateSurface(w, h, c.SDL_PIXELFORMAT_RGBA32) orelse return null;
+        const dst = out[0].pixels orelse {
+            c.SDL_DestroySurface(out);
+            return null;
+        };
+        if (pitch < w * 4 or out[0].pitch < w * 4) {
+            c.SDL_DestroySurface(out);
+            return null;
+        }
+        const row: usize = @intCast(w * 4);
+        const src_pitch: usize = @intCast(pitch);
+        const dst_pitch: usize = @intCast(out[0].pitch);
+        const src_bytes: [*]const u8 = @ptrCast(src);
+        const dst_bytes: [*]u8 = @ptrCast(dst);
+        var y: usize = 0;
+        while (y < @as(usize, @intCast(h))) : (y += 1) {
+            @memcpy(dst_bytes[y * dst_pitch ..][0..row], src_bytes[y * src_pitch ..][0..row]);
+        }
+        return out;
+    }
```

```diff
-        var s = (decode(it.path, std.math.maxInt(c_int)) orelse {
+        var s = a.gifSurface() orelse (decode(it.path, std.math.maxInt(c_int)) orelse {
             a.say("Could not read {s}", .{it.name});
             return;
         }).surface;
```
