# Mark a thumbnail loading and drop the old texture

## Problem

A queued thumbnail stays unmarked, so it can be decoded twice. The first texture leaks.

## Change

`butterview-arch/src/main.zig`

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
