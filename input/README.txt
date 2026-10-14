# Custom Skybox Textures

Put source PNG images in `input/png/` (or `input/jpg/`). The in-game
**Generate DDS from PNGs** button bakes them into `input/dds/generated/`.
The game only ever reads `input/dds/`.

## File format

| Requirement | Value |
|---|---|
| Container | DDS, or PAYDAY's native `.texture` |
| Compression | DXT1 or DXT5 |
| Dimensions | Width and height must both be multiples of 4 |

DXT5 is used for the shipped assets. DXT1 is fine for opaque images.

## Naming convention

For each skybox, provide up to three files sharing a base name:

```
your_skybox_name_df.dds    # diffuse / base texture (REQUIRED unless using a plain file)
your_skybox_name_il.dds    # illumination / glow texture (optional)
your_skybox_name_cm.dds    # cubemap texture (optional)
```

A single file with no `_df` / `_il` / `_cm` suffix is accepted and reused for all
three slots. This is how the shipped skyboxes are stored.

```
tropical_sunset_df.dds
tropical_sunset_il.dds
tropical_sunset_cm.dds
```

Names must be lowercase with underscores only. `default` and `black` are
reserved and will be skipped.

`data/skyboxes.json` supplies the display name shown in the menu. Add an entry
there to give a new skybox a friendly label; without one the raw filename is
shown.

## After adding files

1. Drop PNGs into `input/png/`.
2. In game, open **Mod Options > skybox > Generator**.
3. Click **Generate DDS from PNGs**.
4. Outputs land in `input/dds/generated/` and the mod rescans automatically.

The bake runs in a hidden background process and is cancelled if PAYDAY 2
closes. If you close the game mid-bake, rerun it to finish the remaining files.

## Tips

- Panoramic / equirectangular images give the most convincing result.
- The bake resizes to 2048x2048 by default.
- A `.manifest.json` is written beside each output to skip work on reruns.

## Troubleshooting

A skybox that does not appear is almost always a rejected file. Enable
**Developer Logs** and press **Generate SA Logs** to see the exact reason:

- `not a DDS file` - the file is not a DDS container.
- `unsupported DDS format` - only DXT1 and DXT5 are accepted.
- `size WxH: both sides must be multiples of 4` - resize the source.
- `needs a diffuse _df texture or a plain DDS` - a stray `_il` or `_cm` was
  found with no matching `_df`.