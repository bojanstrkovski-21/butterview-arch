# Do not overwrite the last save name

## Problem

When every name through `-99` exists, the save writes over `-99`. A failed check is treated as a free name.

## Change

`butterview-arch/src/main.zig`

```diff
         var n: u32 = 1;
+        var free_name = false;
         while (n < 100) : (n += 1) {
             name = (if (n == 1)
                 std.fmt.bufPrint(&name_buf, "{s}-{s}.{s}", .{ stem, what, out_ext })
             else
                 std.fmt.bufPrint(&name_buf, "{s}-{s}-{d}.{s}", .{ stem, what, n, out_ext })) catch return;
             path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ a.dir, name }) catch return;
-            var pi: c.SDL_PathInfo = undefined;
-            if (!c.SDL_GetPathInfo(path.ptr, &pi)) break;
+            const rc = std.c.access(path.ptr, std.c.F_OK);
+            if (rc != 0) switch (std.c.errno(rc)) {
+                .NOENT => {
+                    free_name = true;
+                    break;
+                },
+                else => {
+                    a.say("Could not save {s}", .{name});
+                    return;
+                },
+            };
+        }
+        if (!free_name) {
+            a.say("Could not save: names through -99 are taken", .{});
+            return;
         }
```
