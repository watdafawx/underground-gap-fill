# Underground Gap Fill

Factorio 2.0 mod. Fills the one-tile gap after an underground:

- **Pipes**: between two underground pipes (straight or round a corner), or between an underground pipe and a
  machine's pipe connection (tanks, pumps, assemblers…). A plain pipe beside the gap doesn't count, so parallel
  lines aren't joined. Gaps that would mix fluids are left empty.
- **Belts**: between an underground belt's exit and the next entrance, straight or round a corner. The belt faces
  the entrance.

The pipe or belt matches the underground: belts by `related_transport_belt` (or the same speed), pipes by the
underground's recipe, then its name without `-to-ground`, then plain `pipe`. It gets the underground's quality.
It comes out of your inventory; without one (or next to a ghost) it's a ghost for your robots.

## Drag building

Nothing is placed while you build. Each underground you place is queued, and the gaps are filled once you've
built nothing for half a second. The game's drag-build never meets one of our entities in its path, so dragged
undergrounds keep their full range.

Replaces *Automatic Underground Pipe Connectors* (Sparr), which placed the pipe mid-drag and found the pipe from
recipes only. Don't run both.

## Settings (per player)

- Fill gaps after underground pipes (on)
- Fill gaps after underground belts (on)
- Pipe choice: **Same kind as the underground** (default: steel with steel, then one you have, can craft or have
  researched), **One I have or can craft** (inventory first, then hand-craftable, then same kind) or **Researched
  pipes only** (never an unresearched pipe unless you carry it). Pipes that can't connect to the underground
  (another connection category) are never used.

Map setting: **Never fill with** (`void-pipe`): entity names, comma or space separated, never put into a gap.
The next match is used instead (recipe pipe, name, plain `pipe`), or the gap stays empty.

## Remote

`remote.call("underground-gap-fill", "fill", entity, player_index?)` fills now and returns the entity placed.
`fill_name(underground_name)` returns the pipe/belt it would use. `set_blocked("a, b")` sets Never fill with. `pick_pipe(ug, mode, force?, {[item]=count}?)` returns the pipe a mode picks.

## Tests

`python test/run.py --all` (headless, `ugf-test`: pipe straight/corner/tank, fluid mixing, ghosts, occupied gap,
belt straight/corner/both ends, fast belts, quality, block list, pipe choice modes, connection categories; its data.lua adds an unresearched steel pipe family and a pipe of another category).
