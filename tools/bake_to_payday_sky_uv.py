"""Bake a panorama onto PAYDAY 2's sky UVs and write a DXT5 DDS directly.

Run with Blender:
  blender --background --python bake_to_payday_sky_uv.py
    (batch-process PNGs in the mod's input folder)
  blender --background --python bake_to_payday_sky_uv.py -- MESH_GLB SOURCE_IMAGE OUTPUT_DDS

The default mesh path below points at the extracted default sky GLB. Any image
may be supplied: it is stretched to a fixed 2048x1024 panorama, its horizontal
wrap edge is feathered, and it is baked to the mesh's first UV map. Cycles margin
padding and a pure-Python BC3/DXT5 encoder are used; no external converter is
needed. Stretching deliberately ignores the source aspect ratio.
"""

import os
import struct
import sys
from array import array

import bpy


DEFAULT_MESH = r"C:\Users\meow\AppData\Local\Temp\opencode\skybox_x_zip\x\skies\default\default.glb"
DEFAULT_SOURCE = r"D:\SteamLibrary\steamapps\common\PAYDAY 2\mods\skybox_animated\input\png\50_df.png"
DEFAULT_OUTPUT = r"D:\SteamLibrary\steamapps\common\PAYDAY 2\mods\skybox_animated\input\dds\sky_baked_payday_uv_python.dds"
BAKE_SIZE = 2048
BAKE_MARGIN = 24
PANORAMA_WIDTH = 2048
PANORAMA_HEIGHT = 1024
SEAM_FEATHER_PIXELS = 24


def arguments():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    return (
        os.path.abspath(args[0]) if len(args) > 0 else DEFAULT_MESH,
        os.path.abspath(args[1]) if len(args) > 1 else DEFAULT_SOURCE,
        os.path.abspath(args[2]) if len(args) > 2 else DEFAULT_OUTPUT,
    )


def _rgb565(rgb):
    r, g, b = rgb
    return ((r * 31 + 127) // 255 << 11) | ((g * 63 + 127) // 255 << 5) | ((b * 31 + 127) // 255)


def _unpack565(value):
    r = (value >> 11) & 31
    g = (value >> 5) & 63
    b = value & 31
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def _srgb_byte(linear):
    linear = max(0.0, min(1.0, linear))
    srgb = 12.92 * linear if linear <= 0.0031308 else 1.055 * (linear ** (1.0 / 2.4)) - 0.055
    return max(0, min(255, int(srgb * 255.0 + 0.5)))


def _compress_block(pixels):
    # BC3 alpha block: 8-bit endpoints followed by sixteen 3-bit indices.
    alphas = [p[3] for p in pixels]
    a0, a1 = max(alphas), min(alphas)
    if a0 == a1:
        ap = [a0] * 8
    else:
        ap = [a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
    abitfield = 0
    for i, alpha in enumerate(alphas):
        idx = min(range(8), key=lambda j: (alpha - ap[j]) ** 2)
        abitfield |= idx << (3 * i)
    alpha_bytes = bytes((a0, a1)) + abitfield.to_bytes(6, "little")

    # BC1 color block in four-color mode (c0 > c1).
    colors = [p[:3] for p in pixels]
    lo = min(colors, key=lambda c: c[0] * 3 + c[1] * 6 + c[2])
    hi = max(colors, key=lambda c: c[0] * 3 + c[1] * 6 + c[2])
    c0, c1 = _rgb565(hi), _rgb565(lo)
    if c0 < c1:
        c0, c1 = c1, c0
    if c0 == c1:
        if c0 < 0xffff:
            c0 += 1
        else:
            c1 -= 1
    p0, p1 = _unpack565(c0), _unpack565(c1)
    palette = (p0, p1,
               tuple((2 * p0[k] + p1[k]) // 3 for k in range(3)),
               tuple((p0[k] + 2 * p1[k]) // 3 for k in range(3)))
    cfield = 0
    for i, color in enumerate(colors):
        idx = min(range(4), key=lambda j: sum((color[k] - palette[j][k]) ** 2 for k in range(3)))
        cfield |= idx << (2 * i)
    return alpha_bytes + struct.pack("<HHI", c0, c1, cfield)


def write_dxt5_dds(image, output_path):
    width, height = image.size[:]
    pixels = array("f", [0.0]) * (width * height * 4)
    image.pixels.foreach_get(pixels)
    blocks = bytearray()
    for by in range((height + 3) // 4):
        for bx in range((width + 3) // 4):
            block = []
            for dy in range(4):
                y = min(by * 4 + dy, height - 1)
                for dx in range(4):
                    x = min(bx * 4 + dx, width - 1)
                    off = (y * width + x) * 4
                    block.append((_srgb_byte(pixels[off]), _srgb_byte(pixels[off + 1]),
                                  _srgb_byte(pixels[off + 2]),
                                  max(0, min(255, int(pixels[off + 3] * 255 + 0.5)))))
            blocks.extend(_compress_block(block))

    # DDS_HEADER: one BC3/DXT5 mip level; the game accepts DXT5 input.
    flags = 0x00000001 | 0x00000002 | 0x00000004 | 0x00001000 | 0x00080000
    linear_size = ((width + 3) // 4) * ((height + 3) // 4) * 16
    header = struct.pack("<7I", 124, flags, height, width, linear_size, 0, 0)
    header += struct.pack("<11I", *([0] * 11))
    header += struct.pack("<II4s5I", 32, 0x4, b"DXT5", 0, 0, 0, 0, 0)
    header += struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    with open(output_path, "wb") as f:
        f.write(b"DDS ")
        f.write(header)
        f.write(blocks)


def prepare_source_panorama(image):
    """Stretch any source image to 2:1 and feather the repeating side seam."""
    image.scale(PANORAMA_WIDTH, PANORAMA_HEIGHT)
    width, height = image.size[:]
    band = min(SEAM_FEATHER_PIXELS, width // 4)
    pixels = array("f", [0.0]) * (width * height * 4)
    image.pixels.foreach_get(pixels)
    for y in range(height):
        row = y * width * 4
        for x in range(band):
            # Blend both edges toward the same value so horizontal wrapping
            # does not jump at the panorama boundary.
            strength = 1.0 - (x / float(band))
            left = row + x * 4
            right = row + (width - 1 - x) * 4
            for channel in range(4):
                average = (pixels[left + channel] + pixels[right + channel]) * 0.5
                pixels[left + channel] = pixels[left + channel] * (1.0 - strength) + average * strength
                pixels[right + channel] = pixels[right + channel] * (1.0 - strength) + average * strength
    image.pixels.foreach_set(pixels)
    image.update()
    print("[SA] Source stretched to 2:1 and horizontal wrap edge feathered")


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if args:
        mesh_path, source_path, output_path = arguments()
        bake_one(mesh_path, source_path, output_path)
        return

    input_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "input")
    generated_suffixes = ("_equirectangular", "_baked_payday_uv", "_payday_baked", "_test_view")
    sources = []
    for filename in sorted(os.listdir(input_dir)):
        stem, ext = os.path.splitext(filename)
        if ext.lower() != ".png" or stem.lower().endswith(generated_suffixes):
            continue
        sources.append((os.path.join(input_dir, filename),
                        os.path.join(input_dir, stem + "_payday_baked.dds")))
    if not sources:
        raise RuntimeError("No source PNG files found in " + input_dir)
    mesh_path = DEFAULT_MESH
    for source_path, output_path in sources:
        print("[SA] Generating from PNG:", source_path)
        bake_one(mesh_path, source_path, output_path)


def bake_one(mesh_path, source_path, output_path):
    if not os.path.isfile(mesh_path):
        raise FileNotFoundError("PAYDAY sky mesh GLB not found: " + mesh_path)
    if not os.path.isfile(source_path):
        raise FileNotFoundError("Equirectangular source image not found: " + source_path)

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    bpy.ops.import_scene.gltf(filepath=mesh_path)

    candidates = [o for o in bpy.context.scene.objects if o.type == "MESH" and o.data.uv_layers]
    if not candidates:
        raise RuntimeError("Imported GLB contains no mesh with UV coordinates")
    target = max(candidates, key=lambda o: len(o.data.polygons))
    target.name = "PAYDAY_Sky_Bake_Target"
    mesh = target.data
    mesh.uv_layers.active = mesh.uv_layers[0]
    mesh.uv_layers.active.active_render = True

    source = bpy.data.images.load(source_path, check_existing=False)
    source.colorspace_settings.name = "sRGB"
    prepare_source_panorama(source)

    material = bpy.data.materials.new("SA_Sky_Environment_Bake")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()
    texcoord = nodes.new("ShaderNodeTexCoord")
    env = nodes.new("ShaderNodeTexEnvironment")
    env.image = source
    env.projection = "EQUIRECTANGULAR"
    emission = nodes.new("ShaderNodeEmission")
    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(texcoord.outputs["Normal"], env.inputs["Vector"])
    links.new(env.outputs["Color"], emission.inputs["Color"])
    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    mesh.materials.clear()
    mesh.materials.append(material)

    bake_image = bpy.data.images.new(
        "SA_Payday_Sky_UV_Bake", width=BAKE_SIZE, height=BAKE_SIZE,
        alpha=False, float_buffer=False
    )
    bake_node = nodes.new("ShaderNodeTexImage")
    bake_node.image = bake_image
    nodes.active = bake_node

    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 1
    scene.render.bake.margin = BAKE_MARGIN
    scene.render.bake.use_clear = True
    scene.render.bake.target = "IMAGE_TEXTURES"
    scene.cycles.bake_type = "EMIT"

    bpy.ops.object.select_all(action="DESELECT")
    target.select_set(True)
    bpy.context.view_layer.objects.active = target

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    bpy.ops.object.bake(type="EMIT", use_clear=True, margin=BAKE_MARGIN)
    write_dxt5_dds(bake_image, output_path)
    print("[SA] Baked sky onto", mesh.uv_layers.active.name, "of", target.name)
    print("[SA] Output:", output_path)
    print("[SA] Format: DXT5/BC3; island edge padding:", BAKE_MARGIN, "pixels")


if __name__ == "__main__":
    main()
