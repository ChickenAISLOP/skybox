# skybox

Replace the sky in PAYDAY 2 heists with your own textures.

The mod swaps the diffuse texture on the game's Underlay `sky` material, so it
works on every heist without touching any vanilla file. Nine skyboxes ship with
it, and you can bake your own from PNGs without leaving the main menu.

It also **rotates the sky**, per frame, at any speed you like - see the
**Sky Animation** tab below - and keeps the sun's shadow fixed while it turns.

## Requirements

- PAYDAY 2
- [BLT](https://modworkshop.net/mod/58342) and
  [BeardLib](https://modworkshop.net/mod/14924) (Underlay comes from
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
| **Global Custom Skybox** | The skybox applied to every heist. |
| **Developer Logs** | Verbose `[SA]` output to the game log and `skybox_animated.log`. |

### Sky Animation tab

| Control | Effect |
|---|---|
| **Rotate the sky** | Starts and stops the rotation driver. Off restores the angle the level loaded with. |
| **Rotation speed** | Degrees per second, `-360` to `360` in steps of `0.5`. Negative reverses. `4.0` is a full turn in 90 seconds. |
| **Rotation status** | Starts or stops the driver and prints its current state. |

While rotation is running, the mod holds the shadow-casting light at the angle the
level loaded with, so the visible sky moves but the shadow does not crawl. This is
always on and has no separate menu toggle.

Settings persist to `saves/sky_rotation_settings.json`, so the driver stays on across
heists and restarts once you have enabled it.

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

Three things: **swap the sky texture**, **rotate it**, and **hold the sun's shadow
still** while it turns.

Rotation drives `sky_orientation/rotation`, a live environment value:

```lua
local key = Idstring("sky_orientation/rotation"):key()   -- 3c084f67b1da34be
local h = managers.viewport:first_active_viewport()._env_handler
R.angle = (R.angle + speed * dt) % 360
h:editor_set_value(key, R.angle)
```

It is time-based rather than frame-based, so the rate is identical at 30, 60, 144 or
240 fps - only the number of writes changes.

The shadow needs separate work because the global shadow-casting light is linked to
the dome's `d_sun` child, so it turns with the sky. `shadow_freeze.lua` captures the
light's world rotation when rotation starts and counter-rotates its local rotation
every frame. The visible sun moves with the sky; the shadow does not. This is always
on while rotation runs, with no menu toggle.

### What is NOT possible

An earlier version of this README said the sky could not be rotated at all, on the
grounds that "the stock sky material exposes no `uv_speed` or pattern variable to
drive". That reasoning was wrong, and this section replaces it.

The material observation was correct - `Underlay:material("sky")` really does expose
only `params_a`, `params_b`, `color0` and `color2`. But rotation is not a material
variable. It lives on the viewport's environment handler, one layer up.

What *is* true, and was measured:

- `material:set_variable()` is a **silent no-op**. It returns without raising and the
  value reads back unchanged. Writes to `params_b.x` look like they work and are not.
  This is why brightness and tint controls were removed rather than shipped as a
  control panel that does nothing.
- Brightness has no working route. The environment key
  `underlay_effect/sky_top/sky_intensity` exists in only **51 of 225** environments
  (Tier 2 and 3); the other 174 are Tier 1 legacy with no sky-intensity key at all. A
  control that works on 23% of levels is worse than none.
- Scrolling cloud layers is **not** implemented. It is possible in principle -
  `sky_1945_sunset_clouds` and its Mexico DLC twin declare three cloud materials with
  their own `uv0_speed` - but no route to those materials has been found. Note that
  those skies already scroll their clouds in vanilla; rotation moves them, it does not
  scroll them.

Whole-environment swapping also exists but is not exposed here. It access-violates
inside `PackageManager:_script_data` when BeardLib is installed.

## How it works

| File | Role |
|---|---|
| `lua/sky_rotation.lua` | Drives `sky_orientation/rotation` every frame. Self-heals after a level load and persists its settings. |
| `lua/shadow_freeze.lua` | Holds the shadow-casting light's world rotation while the sky turns. Always on. |
| `lua/environment_hook.lua` | Hooks `GameSetupUpdate` and re-applies the texture via `Application:set_material_texture`. Also owns the diagnostics dump. |
| `lua/loader.lua` | Scans `input/dds/`, validates each file, and registers DB entries. |
| `lua/core.lua` | Global config plus legacy per-heist data compatibility. |
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
| `saves/skybox_animated_heists.json` | Legacy per-heist overrides (ignored) |
| `saves/skybox_animated.log` | Log output |
| `saves/sky_rotation_settings.json` | Rotation enabled state and speed |
| `saves/sky_rotation.log` | Rotation driver log |
| `saves/shadow_freeze.log` | Shadow capture / pin diagnostics |

## Troubleshooting

Turn on **Developer Logs**, run **Generate SA Logs**, and read
`skybox_animated.log`. The report names the failure directly - missing texture,
unsupported DDS compression, dimensions not divisible by 4, or Underlay not
loaded.

If nothing changes at all, confirm BeardLib is installed and enabled. Without
Underlay there is no sky material to modify.

## License

MIT - see [LICENSE](LICENSE).
