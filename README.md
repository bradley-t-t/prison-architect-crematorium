# Crematorium

A Prison Architect mod. It adds a Crematorium Furnace and a Vaporizer Pod that
dispose of the dead on site. Guards carry bodies straight into either machine,
from wherever they fell and from nearby Morgue Slabs, one at a time, so no
hearse is needed.

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
| `data/materials.txt` | The Crematorium Furnace, Vaporizer Pod and Morgue Slab objects, and the Morgue room |
| `data/scripts/` | One Lua script per scripted object |
| `data/sprites.png` | The sprite sheet |
| `data/language/base-language.txt` | The names and tooltips the game shows |
