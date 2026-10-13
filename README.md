# Crematorium

A Prison Architect mod. It adds a Crematorium Furnace and a Vaporizer Pod that
dispose of the dead on site. Guards carry bodies straight into either machine,
from wherever they fell and from nearby Morgue Slabs, one at a time, so no
hearse is needed.

The game still sends a hearse whenever a body is waiting, so while a Crematorium
or Vaporizer is standing anywhere in the prison, a hearse is turned away the
moment it appears at the edge of the map. The same goes for the hearse boat and
helicopter on island maps. A hearse already carrying bodies finishes its run,
and with no machine in the prison the hearse works as it always did.

Machines can stand side by side. Each keeps its hidden slabs on its own spots
and leaves alone a slab lying on a neighbour's, so two machines that touch
never take down and rebuild each other's slabs.

A slab holds only the dead. Anybody alive a machine finds held down on one of
its slabs, or on a Morgue Slab it looks after, is let up where they lie.

## Install

Copy the contents of this repository into a folder named `Crematorium` in the
game's mod folder, then enable it under Extras, Mods.

| System | Mod folder |
| :--- | :--- |
| Windows | `%LOCALAPPDATA%\Introversion\Prison Architect\mods` |
| macOS | `~/Library/Application Support/Prison Architect/mods` |

## Layout

| Path | Holds |
| :--- | :--- |
| `manifest.txt` | The name, description and version the mod screen shows |
| `data/materials.txt` | The Crematorium Furnace, Vaporizer Pod and Morgue Slab objects, the Morgue room, and the game's hearse with scripting switched on. The Morgue Slab itself is not scripted, so a prison full of slabs costs nothing |
| `data/materials_dlc.txt` | The hearse boat and helicopter with scripting switched on. The game defines them in its own `materials_dlc.txt` and keeps the first definition it reads of a name, reading every mod's copy of a file ahead of its own, so an override has to sit in the file of the same name |
| `data/scripts/` | One Lua script per scripted object |
| `data/world.lua` | Removes the hidden slabs a machine spawned once that machine is gone. The game rebuilds its whole script API into Lua on every script call, so this is one call a tick for the prison rather than one per slab |
| `data/sprites.png` | The sprite sheet |
| `data/language/base-language.txt` | The names and tooltips the game shows |
