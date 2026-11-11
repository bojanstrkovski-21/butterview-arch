Title: Portal threads can outlive quit, and q in the folder view does not quit

Text:

Two quit bugs. The folder dialog and the appearance query run on detached threads and can still use SDL after the window has quit. In the folder view, q closes the view, while the readme says q quits. The change keeps those thread handles, asks them to stop, and joins them before SDL quits. q quits from the folder view too. Esc and Backspace close the view.

Should q quit there, or keep closing only the view?

## Portal threads

`src/portal.zig` takes a stop flag and polls instead of blocking. `call`, `readSetting`, `appearance`, `Request.send`, and `chooseFolder` all gain `stop: *const std.atomic.Value(bool)`. The wait loops cancel or return when that flag is set.

`src/main.zig`

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

## q in the folder view

`src/main.zig`

```diff
         switch (k) {
-            c.SDLK_ESCAPE, c.SDLK_BACKSPACE, c.SDLK_Q => a.viewClose(),
+            c.SDLK_ESCAPE, c.SDLK_BACKSPACE => a.viewClose(),
```

```diff
         if (a.view != null) {
+            if (k == c.SDLK_Q) return false;
             if (k == c.SDLK_H and ctrl) a.toggleHidden() else if (!is_mod) a.viewKey(k);
```
