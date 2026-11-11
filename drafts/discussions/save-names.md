# What should happen when every save name is taken?

## Problem

Copies are named through `-99`. Today the last of those names is overwritten, and a failed name check is treated as free.

## Change

The code is in `drafts/issues/04-save-names-and-folders.md`. It refuses the save when `-99` is taken, and when the name check fails for any reason other than "not there".

Is stopping at `-99` what you want, or should the number keep going?
