Title: Thumbnails are decoded twice, and old paths are never freed

Text:

Two related leaks in the decode workers. A thumbnail stays unmarked after it is queued, so the same image can be decoded again and the first texture is left behind. Image paths are kept for the whole run, including after that image is gone and no worker still holds it. The change marks a thumbnail loading when it is queued, destroys the old texture before replacing it, and frees a path once nothing in the list or in a running job still uses that id. Moving to another image rebuilds the thumbnail queue. Ids that were marked loading but never started are marked free again first, so they are queued again. A decode already running stays loading.

## Thumbnails

`src/main.zig`

```diff
-        a.sh.want_thumb.clearRetainingCapacity();
+        for (a.sh.want_thumb.items) |id| {
+            const i = a.indexOf(id) orelse continue;
+            if (a.items.items[i].thumb_state == .loading) a.items.items[i].thumb_state = .none;
+        }
+        a.sh.want_thumb.clearRetainingCapacity();
```

```diff
                 const it = &a.items.items[@intCast(i)];
-                if (it.thumb_state == .none) a.sh.want_thumb.append(gpa, it.id) catch {};
+                if (it.thumb_state == .none) {
+                    it.thumb_state = .loading;
+                    a.sh.want_thumb.append(gpa, it.id) catch {
+                        it.thumb_state = .none;
+                    };
+                }
```

```diff
                 .thumb => {
+                    if (it.thumb) |old| c.SDL_DestroyTexture(old);
+                    it.thumb = null;
                     if (d.surface) |s| {
```

## Paths

`src/main.zig`

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

`sweepPaths` runs at the end of `collect`, after trash, and after `reopen`.
