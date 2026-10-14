"""Prepare a square custom sky texture as a 2:1 equirectangular panorama.

Run from Blender's command prompt:
    blender --background --python ".../skybox_animated/tools/prepare_sky_panorama.py"

Defaults:
    input/png/50_df.png -> input/png/50_df_equirectangular.png

Optional arguments after Blender's `--`:
    blender --background --python SCRIPT -- INPUT_IMAGE OUTPUT_IMAGE

This preserves the source image and feathers its left/right wrap seam before
mapping it onto an inward-viewed sphere and rendering an equirectangular image.
The resulting PNG must still be converted to PAYDAY 2's accepted DDS or native
.texture format before placing it in the mod's input folder.
"""

import os
import sys

import bpy


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MOD_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_SOURCE = os.path.join(MOD_DIR, "input", "png", "50_df.png")
DEFAULT_OUTPUT = os.path.join(MOD_DIR, "input", "png", "50_df_equirectangular.png")
OUTPUT_WIDTH = 2048
OUTPUT_HEIGHT = 1024
SEAM_BLEND_PIXELS = 24


def paths_from_args():
    args = sys.argv
    if "--" in args:
        args = args[args.index("--") + 1:]
    else:
        args = []
    source = os.path.abspath(args[0]) if len(args) > 0 else DEFAULT_SOURCE
    output = os.path.abspath(args[1]) if len(args) > 1 else DEFAULT_OUTPUT
    return source, output


def feather_horizontal_wrap(image, band):
    width, height = image.size[:]
    band = max(1, min(int(band), width // 4))
    src = list(image.pixels[:])
    dst = src[:]
    channels = 4

    for y in range(height):
        row = y * width * channels
        for d in range(band):
            left = row + d * channels
            right = row + (width - 1 - d) * channels
            weight = 1.0 - (d / float(band))
            for c in range(channels):
                seam_average = (src[left + c] + src[right + c]) * 0.5
                dst[left + c] = src[left + c] * (1.0 - weight) + seam_average * weight
                dst[right + c] = src[right + c] * (1.0 - weight) + seam_average * weight

    image.pixels[:] = dst
    image.update()


def clear_scene(scene):
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.cameras, bpy.data.meshes):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def main():
    source_path, output_path = paths_from_args()
    if not os.path.isfile(source_path):
        raise FileNotFoundError("Source image not found: " + source_path)

    scene = bpy.context.scene
    clear_scene(scene)

    image = bpy.data.images.load(source_path, check_existing=False)
    image.colorspace_settings.name = "sRGB"
    feather_horizontal_wrap(image, SEAM_BLEND_PIXELS)

    material = bpy.data.materials.new("SA_Equirectangular_Source")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    nodes.clear()

    texture = nodes.new("ShaderNodeTexImage")
    texture.image = image
    texture.interpolation = "Linear"
    texture.extension = "REPEAT"

    emission = nodes.new("ShaderNodeEmission")
    output = nodes.new("ShaderNodeOutputMaterial")
    links.new(texture.outputs["Color"], emission.inputs["Color"])
    links.new(emission.outputs["Emission"], output.inputs["Surface"])

    bpy.ops.mesh.primitive_uv_sphere_add(segments=256, ring_count=128, radius=100)
    sphere = bpy.context.object
    sphere.name = "SA_Sky_Sphere"
    sphere.data.materials.append(material)

    camera_data = bpy.data.cameras.new("SA_Equirectangular_Camera")
    camera_data.type = "PANO"
    camera_data.panorama_type = "EQUIRECTANGULAR"
    camera = bpy.data.objects.new("SA_Equirectangular_Camera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = (0, 0, 0)
    scene.camera = camera

    scene.render.engine = "CYCLES"
    scene.cycles.samples = 16
    scene.render.resolution_x = OUTPUT_WIDTH
    scene.render.resolution_y = OUTPUT_HEIGHT
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.film_transparent = False
    scene.render.filepath = output_path

    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0
    scene.view_settings.gamma = 1

    world = scene.world or bpy.data.worlds.new("SA_Black_World")
    scene.world = world
    world.use_nodes = True
    background = world.node_tree.nodes.get("Background")
    if background:
        background.inputs["Color"].default_value = (0, 0, 0, 1)
        background.inputs["Strength"].default_value = 0

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    bpy.ops.render.render(write_still=True)
    print("[SA] Wrote equirectangular panorama:", output_path)
    print("[SA] Convert the PNG to DDS/native .texture before using it in-game.")


if __name__ == "__main__":
    main()
