# v18 — crash fix + responsiveness pass

- Fixed death crash: `sounds` is now a shared local table available to early callbacks like `endRun()`.
- Added safe guard before playing game-over sound.
- Added attack buffering: pressing attack slightly before cooldown ends now triggers the hit on the first available frame.
- Added hold-to-attack for `Space` and left mouse button.
- Added left mouse attack and right mouse interact.
- Added attack pulse feedback on crosshair.
- Movement input is normalized, so diagonal movement no longer behaves oddly.
- Default movement speed raised from 150 to 175.
- Default mouse sensitivity raised from 0.002 to 0.003.
- Menu/input cooldown reduced from 0.20s to 0.12s.
- Footstep interval slightly reduced to better match faster movement.
- Melee/ranged hit cones and ranges widened a bit to make combat less fussy.
