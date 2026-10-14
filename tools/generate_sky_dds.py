"""Standalone PNG -> PAYDAY sky-UV DXT5 DDS generator.

Install the fast native encoder once, then run with Python:
    py -m pip install quicktex numpy
    py generate_sky_dds.py

The script scans ../input/png/*.{png,jpg} and ../input/jpg/*.{png,jpg}, stretches each
source to a 2:1 panorama, projects it onto the PAYDAY sky mesh's first UV map from
the extracted GLB, and writes ../input/dds/generated/<source>.dds. Originals are
never modified. A source whose DDS already exists is skipped, never re-baked.
Animation frames are no longer baked.
It requires Python, Pillow and Quicktex, but no Blender or image-editor application.
"""

import json
import math
import msvcrt
import os
import re
import struct
import sys
import time
import zlib
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_ROOT = os.path.join(ROOT, "input")
PNG_DIR = os.path.join(DATA_ROOT, "png")
JPG_DIR = os.path.join(DATA_ROOT, "jpg")
DDS_DIR = os.path.join(DATA_ROOT, "dds")
GENERATED_DIR = os.path.join(DDS_DIR, "generated")
MESH_GLB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "default_sky.glb")
OUT_SIZE = 2048
MARGIN = 24
GENERATOR_VERSION = 2
SAMPLE_CHUNK_SIZE = 65536
SOURCE_SUFFIXES_TO_SKIP = ("_equirectangular", "_test_view", "_baked_payday_uv", "_payday_baked")
# JPEG panoramas are baked exactly like PNG ones; both folders feed the same list.
SOURCE_DIRS = (PNG_DIR, JPG_DIR)
SOURCE_EXTENSIONS = (".png", ".jpg", ".jpeg")
STATUS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate_sky_dds.status")
RESULT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate_sky_dds.last_result")
LOCK_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate_sky_dds.lock")


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("Not a PNG: " + path)
    pos, width, height, depth, ctype, compressed = 8, None, None, None, None, bytearray()
    while pos < len(data):
        length = struct.unpack_from(">I", data, pos)[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, ctype, comp, filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError("PNG must be non-interlaced 8-bit RGB/RGBA: " + path)
        elif kind == b"IDAT":
            compressed.extend(chunk)
        elif kind == b"IEND":
            break
    channels = 3 if ctype == 2 else 4
    raw = zlib.decompress(compressed)
    stride = width * channels
    pixels = bytearray(height * stride)
    src = 0
    for y in range(height):
        filt = raw[src]
        src += 1
        row = y * stride
        prev = row - stride
        for x in range(stride):
            value = raw[src]
            src += 1
            a = pixels[row + x - channels] if x >= channels else 0
            b = pixels[prev + x] if y else 0
            c = pixels[prev + x - channels] if y and x >= channels else 0
            if filt == 1:
                value += a
            elif filt == 2:
                value += b
            elif filt == 3:
                value += (a + b) // 2
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                value += a if pa <= pb and pa <= pc else (b if pb <= pc else c)
            elif filt != 0:
                raise ValueError("Unsupported PNG filter")
            pixels[row + x] = value & 255
    if channels == 3:
        rgba = bytearray(width * height * 4)
        for i in range(width * height):
            rgba[i * 4:i * 4 + 3] = pixels[i * 3:i * 3 + 3]
            rgba[i * 4 + 3] = 255
        pixels = rgba
    return width, height, pixels


def read_source(path):
    """Load a panorama as (width, height, RGBA bytearray).

    PNG keeps the hand-rolled decoder; JPEG is decoded by Pillow, which this
    generator already requires. Both therefore feed generate() identically.
    """
    with open(path, "rb") as handle:
        magic = handle.read(3)
    if magic[:2] == b"\xff\xd8":
        from PIL import Image
        with Image.open(path) as image:
            rgba = image.convert("RGBA")
            return rgba.width, rgba.height, bytearray(rgba.tobytes())
    return read_png(path)


def discover_sources():
    """List bake candidates as (stem, path), PNG and JPG treated identically.

    One entry per stem, with input/png winning any tie so a PNG is never
    shadowed by a same-named JPEG. Test renders and derived panoramas are
    dropped via SOURCE_SUFFIXES_TO_SKIP.
    """
    found = {}
    for directory in SOURCE_DIRS:
        if not os.path.isdir(directory):
            continue
        for filename in sorted(os.listdir(directory)):
            stem, extension = os.path.splitext(filename)
            if extension.lower() not in SOURCE_EXTENSIONS:
                continue
            if stem.lower().endswith(SOURCE_SUFFIXES_TO_SKIP):
                continue
            found.setdefault(stem.lower(), (stem, os.path.join(directory, filename)))
    return [found[key] for key in sorted(found)]


def glb_mesh(path):
    data = open(path, "rb").read()
    if data[:4] != b"glTF":
        raise ValueError("Not a GLB file")
    offset = 12
    doc = binary = None
    while offset < len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk = data[offset:offset + length]
        offset += length
        if kind == 0x4E4F534A:
            doc = json.loads(chunk.decode("utf-8"))
        elif kind == 0x004E4942:
            binary = chunk
    if doc is None or binary is None:
        raise ValueError("GLB missing JSON or binary chunk")

    def accessor(index):
        ac = doc["accessors"][index]
        bv = doc["bufferViews"][ac["bufferView"]]
        comp, typ = ac["componentType"], ac["type"]
        fmt = {5123: "H", 5125: "I", 5126: "f"}[comp]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[typ]
        stride = bv.get("byteStride", struct.calcsize("<" + fmt) * n)
        start = bv.get("byteOffset", 0) + ac.get("byteOffset", 0)
        step = struct.calcsize("<" + fmt)
        values = []
        for i in range(ac["count"]):
            values.append(struct.unpack_from("<" + fmt * n, binary, start + i * stride))
        return values

    mesh = doc["meshes"][0]["primitives"][0]
    attrs = mesh["attributes"]
    positions = accessor(attrs["POSITION"])
    normals = accessor(attrs["NORMAL"]) if "NORMAL" in attrs else positions
    uvs = accessor(attrs["TEXCOORD_0"])
    indices = [v[0] for v in accessor(mesh["indices"])] if "indices" in mesh else list(range(len(positions)))
    return positions, normals, uvs, indices


def sample_panorama(image, iw, ih, direction):
    x, y, z = direction
    length = math.sqrt(x * x + y * y + z * z)
    if length < 1e-12:
        return (0, 0, 0, 255)
    x, y, z = x / length, y / length, z / length
    u = (math.atan2(y, x) / (2 * math.pi) + 0.5) % 1.0
    v = 0.5 - math.asin(max(-1.0, min(1.0, z))) / math.pi
    fx, fy = u * iw - 0.5, max(0.0, min(ih - 1.0, v * ih - 0.5))
    x0, y0 = math.floor(fx), int(math.floor(fy))
    tx, ty = fx - x0, fy - y0
    x0 %= iw
    x1, y1 = (x0 + 1) % iw, min(ih - 1, y0 + 1)
    c00, c10 = (y0 * iw + x0) * 4, (y0 * iw + x1) * 4
    c01, c11 = (y1 * iw + x0) * 4, (y1 * iw + x1) * 4
    out = []
    for c in range(4):
        a = image[c00 + c] * (1 - tx) + image[c10 + c] * tx
        b = image[c01 + c] * (1 - tx) + image[c11 + c] * tx
        out.append(int(a * (1 - ty) + b * ty + 0.5))
    out[3] = 255
    return tuple(out)


def rasterize(src, sw, sh, positions, normals, uvs, indices,
              output_size=OUT_SIZE, offset_u=0.0, offset_v=0.0, vertical_repeat=False):
    w = h = output_size
    output = np.zeros((h, w, 4), dtype=np.uint8)
    covered = np.zeros((h, w), dtype=bool)
    source = np.frombuffer(src, dtype=np.uint8).reshape((sh, sw, 4))
    for tri in range(0, len(indices) - 2, 3):
        ids = indices[tri:tri + 3]
        uv = [(uvs[i][0], uvs[i][1]) for i in ids]
        # DDS/glTF UV origin differs from the top-down byte order used by the
        # PNG/DDS encoder here. PAYDAY's UV V maps directly to output row order.
        pts = [(u * (w - 1), v * (h - 1)) for u, v in uv]
        minx = max(0, int(math.floor(min(p[0] for p in pts))))
        maxx = min(w - 1, int(math.ceil(max(p[0] for p in pts))))
        miny = max(0, int(math.floor(min(p[1] for p in pts))))
        maxy = min(h - 1, int(math.ceil(max(p[1] for p in pts))))
        ax, ay = pts[0]
        bx, by = pts[1]
        cx, cy = pts[2]
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-9:
            continue
        gx, gy = np.meshgrid(np.arange(minx, maxx + 1, dtype=np.float32) + 0.5,
                             np.arange(miny, maxy + 1, dtype=np.float32) + 0.5)
        a = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
        b = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
        c = 1.0 - a - b
        mask = (a >= -1e-5) & (b >= -1e-5) & (c >= -1e-5)
        if not mask.any():
            continue
        n0, n1, n2 = (np.asarray(normals[i], dtype=np.float32) for i in ids)
        dx = a * n0[0] + b * n1[0] + c * n2[0]
        dy = a * n0[1] + b * n1[1] + c * n2[1]
        dz = a * n0[2] + b * n1[2] + c * n2[2]
        length = np.sqrt(dx * dx + dy * dy + dz * dz)
        dx, dy, dz = dx / np.maximum(length, 1e-12), dy / np.maximum(length, 1e-12), dz / np.maximum(length, 1e-12)
        uu = (np.arctan2(dy, dx) / (2 * np.pi) + 0.5 + offset_u) % 1.0
        base_v = 0.5 - np.arcsin(np.clip(dz, -1.0, 1.0)) / np.pi
        if vertical_repeat:
            # UV scrolling repeats vertically just like the engine's UVANIM
            # template. Apply the shift before projection, not to the baked atlas.
            vv = (base_v + (offset_v % 1.0)) % 1.0
        else:
            # Preserve the existing static bake's pole sampling exactly.
            vv = np.clip(base_v, 0.0, 1.0)
        fx, fy = uu * sw - 0.5, vv * sh - 0.5
        if not vertical_repeat:
            fy = np.clip(fy, 0.0, sh - 1.0)
        raw_iy0 = np.floor(fy).astype(np.int32)
        ty = fy - raw_iy0
        if vertical_repeat:
            iy0 = raw_iy0 % sh
            iy1 = (iy0 + 1) % sh
        else:
            iy0 = raw_iy0
            iy1 = np.minimum(sh - 1, iy0 + 1)
        ix0 = np.floor(fx).astype(np.int32)
        tx = fx - ix0
        ix0 %= sw
        ix1 = (ix0 + 1) % sw
        p00, p10 = source[iy0, ix0].astype(np.float32), source[iy0, ix1].astype(np.float32)
        p01, p11 = source[iy1, ix0].astype(np.float32), source[iy1, ix1].astype(np.float32)
        colors = (p00 * (1 - tx[..., None]) * (1 - ty[..., None])
                  + p10 * tx[..., None] * (1 - ty[..., None])
                  + p01 * (1 - tx[..., None]) * ty[..., None]
                  + p11 * tx[..., None] * ty[..., None])
        colors = np.clip(colors + 0.5, 0, 255).astype(np.uint8)
        colors[..., 3] = 255
        oy, ox = slice(miny, maxy + 1), slice(minx, maxx + 1)
        output[oy, ox][mask] = colors[mask]
        covered[oy, ox][mask] = True
    pad_edges(output, covered, w, h, MARGIN)
    return output.tobytes()


def pad_edges(image, covered, width, height, margin):
    """Dilate nearest baked edge colors into atlas padding, bounded by margin."""
    for _ in range(margin):
        previous = covered.copy()
        colors = image.copy()
        # Four-neighbor propagation copies nearby baked texels into atlas padding.
        for y0, y1, x0, x1 in ((1, height, 0, width), (0, height - 1, 0, width),
                               (0, height, 1, width), (0, height, 0, width - 1)):
            dy, dx = (1, 0) if y0 == 1 else ((-1, 0) if y1 == height - 1 else ((0, 1) if x0 == 1 else (0, -1)))
            ty0, ty1 = max(0, y0), min(height, y1)
            tx0, tx1 = max(0, x0), min(width, x1)
            sy0, sy1 = ty0 - dy, ty1 - dy
            sx0, sx1 = tx0 - dx, tx1 - dx
            target_covered = covered[ty0:ty1, tx0:tx1]
            source_covered = previous[sy0:sy1, sx0:sx1]
            take = (~target_covered) & source_covered
            if take.any():
                target_colors = image[ty0:ty1, tx0:tx1]
                source_colors = colors[sy0:sy1, sx0:sx1]
                target_colors[take] = source_colors[take]
                target_covered[take] = True


def build_sampling_map(mesh, output_size):
    """Precompute the sky mesh's equirectangular sample coordinates once."""
    _, normals, uvs, indices = mesh
    width = height = output_size
    coordinates = np.zeros((height, width, 2), dtype=np.float32)
    covered = np.zeros((height, width), dtype=bool)
    for tri in range(0, len(indices) - 2, 3):
        ids = indices[tri:tri + 3]
        uv = [(uvs[i][0], uvs[i][1]) for i in ids]
        pts = [(u * (width - 1), v * (height - 1)) for u, v in uv]
        minx = max(0, int(math.floor(min(p[0] for p in pts))))
        maxx = min(width - 1, int(math.ceil(max(p[0] for p in pts))))
        miny = max(0, int(math.floor(min(p[1] for p in pts))))
        maxy = min(height - 1, int(math.ceil(max(p[1] for p in pts))))
        ax, ay = pts[0]
        bx, by = pts[1]
        cx, cy = pts[2]
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-9:
            continue
        gx, gy = np.meshgrid(np.arange(minx, maxx + 1, dtype=np.float32) + 0.5,
                             np.arange(miny, maxy + 1, dtype=np.float32) + 0.5)
        a = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
        b = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
        c = 1.0 - a - b
        mask = (a >= -1e-5) & (b >= -1e-5) & (c >= -1e-5)
        if not mask.any():
            continue
        n0, n1, n2 = (np.asarray(normals[i], dtype=np.float32) for i in ids)
        dx = a * n0[0] + b * n1[0] + c * n2[0]
        dy = a * n0[1] + b * n1[1] + c * n2[1]
        dz = a * n0[2] + b * n1[2] + c * n2[2]
        length = np.sqrt(dx * dx + dy * dy + dz * dz)
        dx = dx / np.maximum(length, 1e-12)
        dy = dy / np.maximum(length, 1e-12)
        dz = dz / np.maximum(length, 1e-12)
        source_u = (np.arctan2(dy, dx) / (2 * np.pi) + 0.5) % 1.0
        source_v = 0.5 - np.arcsin(np.clip(dz, -1.0, 1.0)) / np.pi
        oy, ox = slice(miny, maxy + 1), slice(minx, maxx + 1)
        target = coordinates[oy, ox]
        target[mask] = np.stack((source_u[mask], source_v[mask]), axis=-1)
        covered[oy, ox][mask] = True

    # Match rasterize()'s atlas-edge dilation so filtering has the same padding.
    for _ in range(MARGIN):
        previous = covered.copy()
        previous_coordinates = coordinates.copy()
        for y0, y1, x0, x1 in ((1, height, 0, width), (0, height - 1, 0, width),
                               (0, height, 1, width), (0, height, 0, width - 1)):
            dy, dx = (1, 0) if y0 == 1 else ((-1, 0) if y1 == height - 1 else ((0, 1) if x0 == 1 else (0, -1)))
            ty0, ty1 = max(0, y0), min(height, y1)
            tx0, tx1 = max(0, x0), min(width, x1)
            sy0, sy1 = ty0 - dy, ty1 - dy
            sx0, sx1 = tx0 - dx, tx1 - dx
            target_covered = covered[ty0:ty1, tx0:tx1]
            take = (~target_covered) & previous[sy0:sy1, sx0:sx1]
            if take.any():
                target_coordinates = coordinates[ty0:ty1, tx0:tx1]
                source_coordinates = previous_coordinates[sy0:sy1, sx0:sx1]
                target_coordinates[take] = source_coordinates[take]
                target_covered[take] = True
    return coordinates, np.flatnonzero(covered)


def sample_from_map(src, source_width, source_height, sampling_map, covered_indices,
                    offset_v=0.0, vertical_repeat=False):
    """Sample an image through a cached map in bounded chunks to cap memory."""
    size = sampling_map.shape[0]
    source = np.frombuffer(src, dtype=np.uint8).reshape((source_height, source_width, 4))
    coordinates = sampling_map.reshape((-1, 2))
    output = np.zeros((size * size, 4), dtype=np.uint8)
    for start in range(0, covered_indices.size, SAMPLE_CHUNK_SIZE):
        indices = covered_indices[start:start + SAMPLE_CHUNK_SIZE]
        points = coordinates[indices]
        uu = points[:, 0]
        vv = (points[:, 1] + (offset_v % 1.0)) % 1.0 if vertical_repeat else points[:, 1]
        fx = uu * source_width - 0.5
        fy = vv * source_height - 0.5
        if vertical_repeat:
            raw_y0 = np.floor(fy).astype(np.int32)
            ty = fy - raw_y0
            y0 = raw_y0 % source_height
            y1 = (y0 + 1) % source_height
        else:
            fy = np.clip(fy, 0.0, source_height - 1.0)
            y0 = np.floor(fy).astype(np.int32)
            ty = fy - y0
            y1 = np.minimum(source_height - 1, y0 + 1)
        raw_x0 = np.floor(fx).astype(np.int32)
        tx = fx - raw_x0
        x0 = raw_x0 % source_width
        x1 = (x0 + 1) % source_width
        p00 = source[y0, x0].astype(np.float32)
        p10 = source[y0, x1].astype(np.float32)
        p01 = source[y1, x0].astype(np.float32)
        p11 = source[y1, x1].astype(np.float32)
        colors = (p00 * (1 - tx[:, None]) * (1 - ty[:, None])
                  + p10 * tx[:, None] * (1 - ty[:, None])
                  + p01 * (1 - tx[:, None]) * ty[:, None]
                  + p11 * tx[:, None] * ty[:, None])
        colors = np.clip(colors + 0.5, 0, 255).astype(np.uint8)
        colors[:, 3] = 255
        output[indices] = colors
    return output.reshape((size, size, 4)).tobytes()


def write_dds(path, rgba, width, height, compression="DXT5"):
    # Quicktex uses its native C++ BC3 encoder; the prior pure-Python block
    # compressor was correct but far too slow for an in-game generator.
    from PIL import Image
    temporary_path = path + ".tmp"
    try:
        from quicktex.dds import encode
        image = Image.frombytes("RGBA", (width, height), bytes(rgba))
        if compression == "DXT1":
            from quicktex.s3tc.bc1 import BC1Encoder
            encode(image, BC1Encoder(4), "DXT1").save(temporary_path)
        else:
            from quicktex.s3tc.bc3 import BC3Encoder
            # A modest quality level keeps 2048x2048 DXT5 encoding near seconds
            # while remaining visually clean for sky textures.
            encode(image, BC3Encoder(4), "DXT5").save(temporary_path)
        # Never fall back to an in-place rewrite for binary output: a partly
        # written DDS would fail the header validation and force a re-bake.
        replace_with_retry(temporary_path, path)
    except ImportError as exc:
        raise RuntimeError("Quicktex/Pillow is missing; install with: py -m pip install quicktex") from exc
    finally:
        if os.path.exists(temporary_path):
            try:
                os.remove(temporary_path)
            except OSError:
                pass


def generate(source_data, output_path, sampling_map, covered_indices):
    sw, sh, src = source_data
    result = sample_from_map(src, sw, sh, sampling_map, covered_indices)
    write_dds(output_path, result, OUT_SIZE, OUT_SIZE)
    print("[SA-PY] wrote", output_path)


def vertical_animation_stem(stem):
    """Retained for callers that ask; animation frames are no longer baked."""
    return None


def replace_with_retry(temporary_path, path, attempts=8, allow_rewrite=False):
    """Rename a temp file onto `path`, tolerating readers holding it open.

    The in-game Lua menu polls the status file every couple of seconds and the
    VBS watcher reads it every second. A reader's shared handle makes
    MoveFileEx fail with "Access is denied", so retry briefly and, for plain
    text status files, fall back to an in-place rewrite.
    """
    delay = 0.02
    for attempt in range(attempts):
        try:
            os.replace(temporary_path, path)
            return
        except OSError:
            if attempt == attempts - 1:
                break
            time.sleep(delay)
            delay = min(delay * 2, 0.25)
    if not allow_rewrite:
        raise
    with open(temporary_path, "r", encoding="utf-8") as source:
        contents = source.read()
    with open(path, "w", encoding="utf-8") as destination:
        destination.write(contents)
    try:
        os.remove(temporary_path)
    except OSError:
        pass


def write_text_file(path, message):
    temporary_path = path + ".tmp"
    with open(temporary_path, "w", encoding="utf-8") as text_file:
        text_file.write(message)
    replace_with_retry(temporary_path, path, allow_rewrite=True)


def write_status(message):
    write_text_file(STATUS_FILE, message)


def write_result(message):
    write_text_file(RESULT_FILE, message)


def acquire_generator_lock():
    """Hold a Windows byte-range lock so concurrent menu clicks cannot race."""
    lock_file = open(LOCK_FILE, "a+b")
    if os.fstat(lock_file.fileno()).st_size == 0:
        lock_file.write(b"\0")
        lock_file.flush()
    lock_file.seek(0)
    try:
        msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
    except OSError:
        lock_file.close()
        return None
    return lock_file


def dds_expected_sizes(width, height, bytes_per_block):
    """Valid on-disk sizes: the main level alone, and with a full mip chain.

    quicktex writes the whole chain, so the mip-less size is only accepted for
    files produced by a tool that omits mipmaps.
    """
    sizes = set()
    for with_mips in (False, True):
        total = 128
        level_width, level_height = width, height
        while True:
            total += ((level_width + 3) // 4) * ((level_height + 3) // 4) * bytes_per_block
            if not with_mips or (level_width == 1 and level_height == 1):
                break
            level_width, level_height = max(1, level_width // 2), max(1, level_height // 2)
        sizes.add(total)
    return sizes


def valid_dds(path, width, height, compression):
    """Reject missing, partial, or mismatched DDS files before resuming a bake."""
    try:
        with open(path, "rb") as dds:
            header = dds.read(128)
        if len(header) != 128 or header[:4] != b"DDS ":
            return False
        if struct.unpack_from("<I", header, 4)[0] != 124:
            return False
        actual_height, actual_width = struct.unpack_from("<II", header, 12)
        if (actual_width, actual_height) != (width, height):
            return False
        expected_fourcc = b"DXT1" if compression == "DXT1" else b"DXT5"
        if header[84:88] != expected_fourcc:
            return False
        bytes_per_block = 8 if compression == "DXT1" else 16
        return os.path.getsize(path) in dds_expected_sizes(width, height, bytes_per_block)
    except (OSError, struct.error):
        return False


def source_manifest(source_path):
    info = os.stat(source_path)
    return {
        "generator_version": GENERATOR_VERSION,
        "source_name": os.path.basename(source_path),
        "source_size": info.st_size,
        "source_mtime_ns": info.st_mtime_ns,
        "static_size": OUT_SIZE,
    }


def matching_manifest(path, expected):
    try:
        with open(path, "r", encoding="utf-8") as manifest:
            return json.load(manifest) == expected
    except (OSError, ValueError):
        return False


def write_manifest(path, data):
    temporary_path = path + ".tmp"
    with open(temporary_path, "w", encoding="utf-8") as manifest:
        json.dump(data, manifest, sort_keys=True)
    replace_with_retry(temporary_path, path, allow_rewrite=True)


def main():
    log_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generate_sky_dds.log")
    lock_handle = acquire_generator_lock()
    if lock_handle is None:
        with open(log_path, "a", buffering=1) as log_handle:
            log_handle.write("[SA-PY] another sky DDS generation run already owns the lock; exiting without touching its status or outputs\n")
        return
    original_stdout, original_stderr = sys.stdout, sys.stderr
    log_handle = None
    try:
        # Start a fresh log only after acquiring the lock, so a duplicate click
        # cannot erase the active run's diagnostics.
        log_handle = open(log_path, "w", buffering=1)
        sys.stdout = sys.stderr = log_handle
        write_status("RUNNING preparing generator")
        if not os.path.isfile(MESH_GLB):
            raise FileNotFoundError("Bundled PAYDAY sky mesh not found: " + MESH_GLB)
        mesh = glb_mesh(MESH_GLB)
        for directory in SOURCE_DIRS:
            os.makedirs(directory, exist_ok=True)
        os.makedirs(DDS_DIR, exist_ok=True)
        os.makedirs(GENERATED_DIR, exist_ok=True)
        sources = discover_sources()
        if not sources:
            raise RuntimeError("No eligible PNG or JPG sources found in " + ", ".join(SOURCE_DIRS))
        total = len(sources)
        progress_state = {"completed": 0, "total": total}

        def progress_message(state, detail):
            completed = progress_state["completed"]
            remaining = max(0, total - completed)
            return "{} DDS {}/{} done; {} remaining | {}".format(
                state, completed, total, remaining, detail,
            )

        write_status(progress_message("RUNNING", "preparing cached sky UV maps"))
        static_map, static_covered = build_sampling_map(mesh, OUT_SIZE)
        for source_number, (stem, source) in enumerate(sources, 1):
            filename = os.path.basename(source)
            output = os.path.join(GENERATED_DIR, stem + ".dds")
            manifest_path = os.path.join(GENERATED_DIR, stem + ".manifest.json")
            # A DDS that is already valid is working, so it is never re-baked.
            # This also stops prototype.jpg clobbering the prototype.png bake.
            if valid_dds(output, OUT_SIZE, OUT_SIZE, "DXT5"):
                progress_state["completed"] += 1
                write_status(progress_message("RUNNING", "{} already baked".format(filename)))
                print("[SA-PY] skipping already-baked", filename)
                continue
            write_manifest(manifest_path, source_manifest(source))
            source_data = read_source(source)
            write_status(progress_message("WORKING", "{} static DDS".format(filename)))
            print("[SA-PY] processing {}/{} {}".format(source_number, len(sources), filename))
            generate(source_data, output, static_map, static_covered)
            progress_state["completed"] += 1
            write_status(progress_message("RUNNING", "{} static DDS complete".format(filename)))

        done_message = "DONE DDS {}/{} done; 0 remaining | {} static DDS".format(
            total, total, len(sources),
        )
        write_status(done_message)
        write_result(done_message)
    except Exception as exc:
        message = "ERROR {}".format(exc)
        write_status(message)
        write_result(message)
        raise
    finally:
        lock_handle.close()
        sys.stdout, sys.stderr = original_stdout, original_stderr
        if log_handle:
            log_handle.close()


if __name__ == "__main__":
    main()
