# Should the next-folder step enter a folder it could not prove empty?

## Problem

The probe counts hidden names while they are hidden, and a scan that stops at 4000 entries with zero images looks empty. The step then skips a folder that still opens.

## Change

The code is in `drafts/issues/04-save-names-and-folders.md`. Hidden names are ignored when they are off, and a folder the scan could not prove empty is entered. The badge can still show 0.

Is entering it better than skipping it?
