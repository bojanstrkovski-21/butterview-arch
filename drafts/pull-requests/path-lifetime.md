# Free a path when nothing still uses it

## Problem

Image paths are kept for the whole run, including after the image is gone and no decode holds it.

## Change

`butterview-arch/src/main.zig`

```diff
-    /// id -> path, for the workers. Entries are never removed.
+    /// id -> path, for the workers. Freed once the id is gone and idle.
     paths: std.AutoHashMapUnmanaged(u32, [:0]const u8) = .empty,
     busy_full: [8]u32 = @splat(0),
+    busy_thumb: [8]u32 = @splat(0),
```

```diff
         const id = sh.want_thumb.orderedRemove(0);
+        for (&sh.busy_thumb) |*b| {
+            if (b.* == 0) {
+                b.* = id;
+                break;
+            }
+        }
         return .{ .kind = .thumb, .id = id };
```

```diff
             for (&sh.busy_full) |*b| {
                 if (b.* == j.id) b.* = 0;
             }
+        } else {
+            for (&sh.busy_thumb) |*b| {
+                if (b.* == j.id) b.* = 0;
+            }
         }
```

```diff
+    fn pathBusy(sh: *const Shared, id: u32) bool {
+        for (sh.busy_full) |b| if (b == id) return true;
+        for (sh.busy_thumb) |b| if (b == id) return true;
+        for (sh.want_full[0..sh.want_full_n]) |w| if (w.id == id) return true;
+        for (sh.want_thumb.items) |t| if (t == id) return true;
+        for (sh.done.items) |d| if (d.id == id) return true;
+        return false;
+    }
+
+    fn sweepPaths(a: *App) void {
+        c.SDL_LockMutex(a.sh.mutex);
+        defer c.SDL_UnlockMutex(a.sh.mutex);
+        var drop: [32]u32 = undefined;
+        var n: usize = 0;
+        var it = a.sh.paths.iterator();
+        while (it.next()) |e| {
+            const id = e.key_ptr.*;
+            if (a.indexOf(id) != null) continue;
+            if (pathBusy(a.sh, id)) continue;
+            if (n == drop.len) break;
+            drop[n] = id;
+            n += 1;
+        }
+        for (drop[0..n]) |id| {
+            if (a.sh.paths.fetchRemove(id)) |kv| gpa.free(kv.value);
+        }
+    }
```

`sweepPaths` is called at the end of `collect`, after trash, and after `reopen`.
