# Make q quit from the folder view

## Problem

In the folder view, q closes the view. The readme says q quits.

## Change

`butterview-arch/src/main.zig`

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
