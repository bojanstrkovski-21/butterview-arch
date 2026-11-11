# Stop and join portal threads before quit

## Problem

The folder dialog and the appearance query are detached and can use SDL after quit.

## Change

`butterview-arch/src/portal.zig` takes a stop flag and polls instead of blocking. `call`, `readSetting`, `appearance`, `Request.send`, and `chooseFolder` all gain `stop: *const std.atomic.Value(bool)`. The wait loops cancel or return when that flag is set.

`butterview-arch/src/main.zig`

```diff
     busy_full: [8]u32 = @splat(0),
+    /// Portal threads watch this and leave before SDL_Quit.
+    stop: std.atomic.Value(bool) = .init(false),
```

```diff
     appearance_pending: bool = false,
+    appearance_thread: ?*c.SDL_Thread = null,
     open_pending: bool = false,
+    open_thread: ?*c.SDL_Thread = null,
```

```diff
-        c.SDL_DetachThread(t);
+        a.open_thread = t;
```

```diff
-        c.SDL_DetachThread(t);
+        a.appearance_thread = t;
```

```diff
-    const ap = portal.appearance(3000);
+    const ap = portal.appearance(3000, &sh.stop);
+    if (sh.stop.load(.acquire)) return 0;
```

```diff
-    const r = portal.chooseFolder(gpa, job.start, parent, 10 * 60 * 1000);
+    const r = portal.chooseFolder(gpa, job.start, parent, &sh.stop, 10 * 60 * 1000);
+    if (sh.stop.load(.acquire)) {
+        if (r.path) |p| gpa.free(p);
+        return 0;
+    }
```

```diff
+    shared.stop.store(true, .release);
     c.SDL_LockMutex(shared.mutex);
     shared.quit = true;
```

```diff
     if (font_thread) |th| c.SDL_WaitThread(th, null);
+    if (app.open_thread) |th| c.SDL_WaitThread(th, null);
+    if (app.appearance_thread) |th| c.SDL_WaitThread(th, null);
```

A second open or appearance query waits for the previous handle before starting another.
