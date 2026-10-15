# Custom Skybox Files

- Put source PNG images in `input/png/`.
- Other source JPEGs are kept separately in `input/jpg/` (the generator scans PNGs only).
- Put game-ready DDS or PAYDAY `.texture` files in `input/dds/`.
- The generator writes `input/dds/generated/<same-name>.dds`; these outputs override same-named DDS files in the parent folder.
- It also writes 120-frame, 1024px DXT1 vertical-scroll loops to `input/dds/animated/`; the loader keeps them separate from selectable skybox textures.
- The mod scans only `input/dds/`; PNGs are never used directly by the game.
- In-game, use **Generate DDS from PNGs** to make base DDS files and vertical frames, then the mod rescans automatically.
- The hidden generator is monitored and stopped when `PAYDAY2.exe` exits. If you close the game during generation, rerun the generator to complete any partial output.

## File Format

**Required in `input/dds/`:** DDS format (DXT1 or DXT5 compression)
**Dimensions:** Both width and height must be multiples of 4 (e.g., 1024x1024, 2048x1024, 512x512)

## Naming Convention

For each skybox, provide up to 3 files with matching base name:

```
your_skybox_name_df.dds    # Diffuse/base texture (REQUIRED)
your_skybox_name_il.dds    # Illumination/glow texture (optional)
your_skybox_name_cm.dds    # Cubemap texture (optional)
```

Examples:
```
tropical_sunset_df.dds
tropical_sunset_il.dds
tropical_sunset_cm.dds

night_stars_df.dds
night_stars_cm.dds
```

## After Adding Files

1. Place source PNGs in `input/png/`.
2. In-game, go to Mod Options > skybox_animated > Generator.
3. Click **"Generate DDS from PNGs"**.
4. Generated base files named exactly like the PNG (with `.dds`) appear in `input/dds/generated/`; vertical frames appear in `input/dds/animated/`. The mod rescans when generation completes. Keep PAYDAY 2 open until the completion message appears.

## Tips

- For best results, use panoramic/equirectangular textures for sky domes
- The `_il` (illumination) texture adds glowing/emissive effects
- The `_cm` (cubemap) texture enables cubemap-based rendering
- Keep file sizes reasonable (< 10MB each) for faster loading
- You can also use `.texture` files (PAYDAY 2's native format) instead of `.dds`

## Troubleshooting

If a skybox doesn't appear after rescanning:
- Check the console (F11) for error messages like "not a DDS file" or "unsupported DDS format"
- Ensure dimensions are multiples of 4
- Use DXT1 for opaque textures, DXT5 for textures with alpha
- Filenames must be lowercase with underscores only (no spaces, special chars)
