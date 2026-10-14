# skybox

Replace the sky in PAYDAY 2 heists with your own textures.

The mod swaps the diffuse texture on the game's Underlay `sky` material, so it
works on every heist without touching any vanilla file. Nine skyboxes ship with
it, and you can bake your own from PNGs without leaving the main menu.

## Requirements

- PAYDAY 2
- [BLT](https://github.com/userthug/BLT) and
  [BeardLib](https://github.com/DrakModding/BeardLib) (Underlay comes from
  BeardLib; the mod does nothing without it)
- Python with Pillow, numpy and quicktex - **only** if you want to bake your own
  images (`py -m pip install -r requirements.txt`)

## Install

**SuperBLT:** *Downloader > Install from GitHub* > select this repository

**Manual:** drop this folder into your PAYDAY 2 `mods/` directory and restart.

## Using it

Everything lives under **Mod Options > skybox**.

### Skybox tab

| Option | Effect |
|---|---|
| **Mod Enabled** | Master on/off switch. |
| **Global Heist Skybox** | Applies one skybox to every heist. Turning this off lets you set each heist separately. |
| **Global Custom Skybox** | The skybox used while Global Heist Skybox is on. |
| **Developer Logs** | Verbose `[SA]` output to the game log and `skybox_animated.log`. |

### Heists tab

Disabled while Global Heist Skybox is on. Turn it off first.

Pick a heist, choose its **Heist Skybox**, toggle **Heist Override Enabled**, then
press **Save Heist**.

### Generator tab

| Button | Effect |
|---|---|
| **Generate DDS from PNGs** | Bakes everything in `input/png/` into `input/dds/generated/`, then rescans. |
| **Check DDS Progress** | Shows how many files are done and how many remain. |
| **Rescan Skyboxes** | Rescans `input/dds/` without baking. |
| **Generate SA Logs** | Writes a diagnostic report. The first thing to check when something looks wrong. |

The bake runs detached and is cancelled if you close PAYDAY 2. Closing the game
part-way through leaves a partial result - just run it again to finish.

## Adding your own skybox

1. Drop a PNG into `input/png/`.
2. **Mod Options > skybox > Generator > Generate DDS from PNGs**.
3. Pick it from the skybox dropdown.

Baked files land in `input/dds/generated/` and are picked up automatically. Give
it a friendly menu label by adding an entry to `data/skyboxes.json`. See
[`input/README.txt`](input/README.txt) for the `_df` / `_il` / `_cm` naming
convention and format requirements.

Source images are not committed to this repo, so a fresh clone has an empty
`input/png/`.

## Shipped skyboxes

| Id | Name |
|---|---|
| `0` | Violet Mandala |
| `51` | Rose Mandala |
| `67` | Electric Storm |
| `girly` | Portrait |
| `nightsky` | Night Sky Panorama |
| `prototype` | Night Horizon |
| `sky` | Violet Nebula |
| `skyproto` | Pixel Bloom |
| `welcome` | Glitch Storm |

## Scope

This mod does one thing: **swap the sky texture.** It does not rotate skies or
scroll clouds.

Earlier versions carried rotation, UV scrolling, brightness and tint controls
and per-frame animation frames. None of it ever had a visible effect - the
stock sky material exposes no `uv_speed` or pattern variable to drive, so the
engine silently rejected every generated material config - while the frame
swapping measurably cost framerate. It was removed rather than left in as a
control panel that does nothing. The dead code and the README section describing
it are gone as of this version.

Sky animation is only possible with a custom sky shader, which is a much larger
job than a texture swap.

## How it works

| File | Role |
|---|---|
| `lua/environment_hook.lua` | Hooks `GameSetupUpdate` and re-applies the texture via `Application:set_material_texture`. Also owns the diagnostics dump. |
| `lua/loader.lua` | Scans `input/dds/`, validates each file, and registers DB entries. |
| `lua/core.lua` | Per-heist config and the heist-to-skybox fallback table. |
| `lua/settings/` | The Mod Options menu. |
| `data/skyboxes.json` | Display names for menu entries. |
| `tools/` | Python PNG-to-DDS generator (plus two offline Blender helpers). |

Two details worth knowing:

- **Nothing uploads at startup.** Scanning only creates DB entries; the
  selected texture is loaded on demand, and only while a heist is running. This
  is why the main menu stays responsive.
- **Texture ids are content-hashed.** Each registration path includes a hash of
  the file contents, so re-baking a texture automatically produces a new
  resource instead of serving a stale cache.

## Settings files

| Path | Contents |
|---|---|
| `saves/skybox_animated_settings.json` | Global settings |
| `saves/skybox_animated_heists.json` | Per-heist overrides |
| `saves/skybox_animated.log` | Log output |

## Troubleshooting

Turn on **Developer Logs**, run **Generate SA Logs**, and read
`skybox_animated.log`. The report names the failure directly - missing texture,
unsupported DDS compression, dimensions not divisible by 4, or Underlay not
loaded.

If nothing changes at all, confirm BeardLib is installed and enabled. Without
Underlay there is no sky material to modify.

## License

MIT - see [LICENSE](LICENSE).