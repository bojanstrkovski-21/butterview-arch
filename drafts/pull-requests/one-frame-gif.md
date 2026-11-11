# Stop waking a finished one-frame GIF

## Problem

A one-frame GIF keeps a 5 ms wake after the decoder is done. The single-frame flag is never read.

## Change

`butterview-arch/src/main.zig`

```diff
     next_at: u64 = 0,
+    /// The decoder has stopped and the ring is empty. Do not keep waking.
+    settled: bool = false,

     fn animated(f: *const Full) bool {
         return f.anim != null;
     }
+
+    fn playing(f: *const Full) bool {
+        return f.anim != null and !f.settled;
+    }
```

```diff
         const an = f.anim orelse return false;
-        if (now < f.next_at) return false;
+        if (f.settled or now < f.next_at) return false;
         const slot = an.peek() orelse {
+            c.SDL_LockMutex(an.mutex);
+            const done = an.single;
+            c.SDL_UnlockMutex(an.mutex);
+            if (done) {
+                f.settled = true;
+                return false;
+            }
             // the decoder is behind; look again shortly
             f.next_at = now + 5;
```

```diff
-            const anim: ?*Full = if (app.currentFull()) |f| (if (f.animated()) f else null) else null;
+            const anim: ?*Full = if (app.currentFull()) |f| (if (f.playing()) f else null) else null;
```
