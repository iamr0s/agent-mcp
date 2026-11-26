#!/usr/bin/env python3
"""
Agent MCP — Master Full-Surface Brand Icon & Vector Synchronizer (Prism Edition)
Generates the Concentric Refracted Prism icon across ALL 24 desktop, mobile,
tray, installer, and web surfaces in lockstep so no surface ever drifts:
  1. apps/agent_mcp_app/assets/app_icon.png (1024x1024)
  2. apps/agent_mcp_app/assets/app_icon.ico (16, 24, 32, 48, 64, 128, 256)
  3. apps/agent_mcp_app/windows/runner/resources/app_icon.ico
  4. apps/agent_mcp_app/web/favicon.png (64x64)
  5. apps/agent_mcp_app/web/icons/Icon-{192,512}.png & Icon-maskable-{192,512}.png
  6. apps/agent_mcp_app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png
  7. apps/agent_mcp_app/android/app/src/main/res/mipmap-{mdpi..xxxhdpi}/ic_launcher.png
  8. apps/agent_mcp_app/android/app/src/main/res/drawable/ic_launcher_{background,foreground,monochrome}.xml & ic_stat_mcp.xml
"""

from __future__ import annotations

import base64
import math
import re
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent


def superellipse_alpha(
    x: np.ndarray,
    y: np.ndarray,
    half_w: float,
    half_h: float,
    n: float,
    aa_px: float,
) -> np.ndarray:
    """Analytical sub-pixel anti-aliased Lamé superellipse mask in [0, 1]."""
    ax = np.abs(x) / max(half_w, 1e-6)
    ay = np.abs(y) / max(half_h, 1e-6)
    # Approximate Euclidean signed distance from |x/a|^n + |y/b|^n = 1
    f = np.power(np.maximum(ax, 1e-8), n) + np.power(np.maximum(ay, 1e-8), n)
    r_norm = np.power(f, 1.0 / n)
    # Distance in normalized coordinates -> convert to pixel units
    approx_scale = 0.5 * (half_w + half_h)
    signed_dist = (r_norm - 1.0) * approx_scale
    return np.clip(0.5 - signed_dist / max(aa_px, 1e-5), 0.0, 1.0)


def blend_over(dst: np.ndarray, src_rgb: np.ndarray, src_a: np.ndarray) -> np.ndarray:
    """Premultiplied-accurate Porter-Duff source-over compositing on float32 RGBA."""
    sa = src_a[..., None]
    da = dst[..., 3:4]
    out_a = sa + da * (1.0 - sa)
    safe_a = np.where(out_a > 1e-6, out_a, 1.0)
    out_rgb = (src_rgb * sa + dst[..., :3] * da * (1.0 - sa)) / safe_a
    out_rgb = np.where(out_a > 1e-6, out_rgb, 0.0)
    return np.concatenate([out_rgb, out_a], axis=-1)


def render_prism_canvas(
    size: int = 1024,
    squircle_half: float = 0.468,
    full_bleed: bool = False,
    symbol_scale: float = 1.0,
) -> Image.Image:
    """
    Renders the Concentric Liquid Prism master icon at `size x size` RGBA.
    - Deep Obsidian-Indigo squircle glass (#13152E -> #090A16) with Starlight Indigo
      (#4F46E5 / #818CF8) optical core bloom and 1px specular glass rim.
    - Interlocking Twin Concentric Rounded-Diamond Prism Rings:
      1) Back Refracted Indigo Liquid Ring (#818CF8 -> #4F46E5)
      2) Front Alabaster-Crystal Ring (#FFFFFF -> #E0E7FF) with soft cast shadow
    """
    # Coordinate grid in [-0.5, 0.5]
    coords = (np.arange(size, dtype=np.float32) + 0.5) / size - 0.5
    xx, yy = np.meshgrid(coords, coords)
    aa = 1.35 / size

    canvas = np.zeros((size, size, 4), dtype=np.float32)

    # 1. Base Squircle (or full-bleed square for Android maskable icons)
    if full_bleed:
        bg_mask = np.ones((size, size), dtype=np.float32)
        rim_mask = np.zeros((size, size), dtype=np.float32)
    else:
        bg_mask = superellipse_alpha(xx, yy, squircle_half, squircle_half, 4.5, aa)
        inner_rim = superellipse_alpha(
            xx,
            yy,
            squircle_half - max(1.6 / size, 0.0085),
            squircle_half - max(1.6 / size, 0.0085),
            4.5,
            aa,
        )
        rim_mask = np.clip(bg_mask - inner_rim, 0.0, 1.0)

    # Diagonal obsidian-indigo architectural gradient (#151735 -> #090A17)
    diag_t = np.clip((xx + yy + 0.9) / 1.8, 0.0, 1.0)[..., None]
    c_top = np.array([0x16, 0x18, 0x38], dtype=np.float32) / 255.0
    c_bot = np.array([0x09, 0x0A, 0x16], dtype=np.float32) / 255.0
    bg_rgb = c_top * (1.0 - diag_t) + c_bot * diag_t

    # Ambient Starlight Indigo (#4F46E5) optical bloom in lower-right + subtle top-left #6366F1 sheen
    d_glow = np.sqrt((xx - 0.15) ** 2 + (yy - 0.17) ** 2)
    glow_w = np.exp(-((d_glow / 0.44) ** 2))[..., None] * 0.48
    c_indigo = np.array([0x4F, 0x46, 0xE5], dtype=np.float32) / 255.0
    bg_rgb = bg_rgb * (1.0 - glow_w) + c_indigo * glow_w

    d_top = np.sqrt((xx + 0.24) ** 2 + (yy + 0.26) ** 2)
    sheen_w = np.exp(-((d_top / 0.42) ** 2))[..., None] * 0.18
    c_periwinkle = np.array([0x81, 0x8C, 0xF8], dtype=np.float32) / 255.0
    bg_rgb = np.clip(bg_rgb + c_periwinkle * sheen_w, 0.0, 1.0)

    canvas = blend_over(canvas, bg_rgb, bg_mask)

    # Specular glass rim (stronger top-left crystal highlight, subtle indigo bottom-right)
    if not full_bleed:
        rim_t = np.clip((xx + yy + 0.85) / 1.7, 0.0, 1.0)[..., None]
        rim_hi = np.array([0xE0, 0xE7, 0xFF], dtype=np.float32) / 255.0
        rim_lo = np.array([0x63, 0x66, 0xF1], dtype=np.float32) / 255.0
        rim_rgb = rim_hi * (1.0 - rim_t) + rim_lo * rim_t
        rim_alpha = rim_mask * (0.36 * (1.0 - rim_t[..., 0]) + 0.15 * rim_t[..., 0])
        canvas = blend_over(canvas, rim_rgb, rim_alpha)

    # Helper for rotated 45-degree concentric rounded-diamond prism ring
    s = symbol_scale
    inv_sqrt2 = 1.0 / math.sqrt(2.0)

    def diamond_ring_mask(cx: float, cy: float, outer_r: float, inner_r: float) -> np.ndarray:
        dx = xx - cx
        dy = yy - cy
        rx = (dx - dy) * inv_sqrt2
        ry = (dx + dy) * inv_sqrt2
        outer = superellipse_alpha(rx, ry, outer_r, outer_r, 2.85, aa)
        inner = superellipse_alpha(rx, ry, inner_r, inner_r, 2.85, aa)
        return np.clip(outer - inner, 0.0, 1.0)

    # 2. Back Refracted Starlight Indigo Prism Ring (shifted lower-right)
    b_cx, b_cy = 0.056 * s, 0.056 * s
    back_ring = diamond_ring_mask(b_cx, b_cy, 0.228 * s, 0.098 * s) * bg_mask
    bt = np.clip(((xx - b_cx) + (yy - b_cy) + 0.32 * s) / (0.64 * s), 0.0, 1.0)[..., None]
    b_col_hi = np.array([0x93, 0x9E, 0xFF], dtype=np.float32) / 255.0  # luminous periwinkle
    b_col_lo = np.array([0x4F, 0x46, 0xE5], dtype=np.float32) / 255.0  # icon Starlight Indigo
    back_rgb = b_col_hi * (1.0 - bt) + b_col_lo * bt
    canvas = blend_over(canvas, back_rgb, back_ring * 0.94)

    # 3. Soft ambient drop shadow cast by Front Crystal Ring onto Back Ring & Base
    f_cx, f_cy = -0.044 * s, -0.044 * s
    sh_mask = diamond_ring_mask(f_cx + 0.016 * s, f_cy + 0.020 * s, 0.242 * s, 0.098 * s)
    sh_img = Image.fromarray(np.uint8(np.clip(sh_mask * 255.0, 0, 255)), mode="L")
    blur_r = max(1.0, size * 0.018)
    sh_img = sh_img.filter(ImageFilter.GaussianBlur(radius=blur_r))
    sh_arr = (np.asarray(sh_img, dtype=np.float32) / 255.0) * bg_mask * 0.46
    canvas = blend_over(canvas, np.zeros((size, size, 3), dtype=np.float32), sh_arr)

    # 4. Front Sculpted Alabaster-Crystal Prism Ring
    front_ring = diamond_ring_mask(f_cx, f_cy, 0.240 * s, 0.104 * s) * bg_mask
    ft = np.clip(((xx - f_cx) * 0.65 + (yy - f_cy) * 0.95 + 0.30 * s) / (0.60 * s), 0.0, 1.0)[
        ..., None
    ]
    f_col_hi = np.array([0xFF, 0xFF, 0xFF], dtype=np.float32) / 255.0
    f_col_lo = np.array([0xDF, 0xE6, 0xFF], dtype=np.float32) / 255.0
    front_rgb = f_col_hi * (1.0 - ft) + f_col_lo * ft
    canvas = blend_over(canvas, front_rgb, front_ring)

    rgba_u8 = np.uint8(np.clip(np.round(canvas * 255.0), 0, 255))
    return Image.fromarray(rgba_u8, mode="RGBA")


def render_macos_icon(master_1024: Image.Image, target_size: int) -> Image.Image:
    """macOS Big Sur / Sequoia HIG: 824/1024 squircle body + subtle ambient drop shadow."""
    # Render crisp squircle at 824/1024 (~0.402 half-width) + soft drop shadow
    hi = max(target_size * 2, 256)
    icon_img = render_prism_canvas(size=hi, squircle_half=0.402, full_bleed=False, symbol_scale=0.88)
    # Subtle drop shadow underneath squircle
    alpha = icon_img.getchannel("A")
    shadow = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    sh_alpha = alpha.filter(ImageFilter.GaussianBlur(radius=hi * 0.022))
    sh_arr = np.asarray(sh_alpha, dtype=np.float32) * 0.34
    shadow_rgba = np.zeros((hi, hi, 4), dtype=np.uint8)
    y_shift = max(1, int(round(hi * 0.014)))
    shadow_rgba[y_shift:, :, 3] = np.uint8(np.clip(sh_arr[:-y_shift, :], 0, 255))
    out = Image.alpha_composite(Image.fromarray(shadow_rgba, mode="RGBA"), icon_img)
    if target_size != hi:
        out = out.resize((target_size, target_size), Image.Resampling.LANCZOS)
    return out


def _encode_ico_bmp_dib(rgba_img: Image.Image) -> bytes:
    """Encodes an RGBA image as a Win32/Web-standard 32-bit BGRA BITMAPINFOHEADER DIB + AND mask."""
    import struct

    w, h = rgba_img.size
    arr = np.asarray(rgba_img.convert("RGBA"), dtype=np.uint8)
    # Bottom-up scanlines in BGRA order
    flipped = arr[::-1, :, :]
    bgra = np.empty_like(flipped)
    bgra[..., 0] = flipped[..., 2]
    bgra[..., 1] = flipped[..., 1]
    bgra[..., 2] = flipped[..., 0]
    bgra[..., 3] = flipped[..., 3]
    xor_bytes = bgra.tobytes()

    # 1-bpp AND mask (1 = transparent where alpha == 0), padded to 32-bit (4-byte) row stride
    row_bytes = ((w + 31) // 32) * 4
    and_mask = bytearray(row_bytes * h)
    alpha = flipped[..., 3]
    for y in range(h):
        row_off = y * row_bytes
        for x in range(w):
            if alpha[y, x] == 0:
                and_mask[row_off + (x >> 3)] |= 0x80 >> (x & 7)

    bih = struct.pack(
        "<IiiHHIIiiII",
        40,  # biSize
        w,  # biWidth
        h * 2,  # biHeight (XOR + AND combined height per ICO spec)
        1,  # biPlanes
        32,  # biBitCount
        0,  # biCompression = BI_RGB
        len(xor_bytes) + len(and_mask),  # biSizeImage
        0,
        0,
        0,
        0,
    )
    return bih + xor_bytes + bytes(and_mask)


def save_multi_ico(master: Image.Image, dst: Path) -> None:
    """Writes standard hybrid Windows/Web .ico: 16..128 BGRA32 BMP/DIB + 256 PNG."""
    import io
    import struct

    dst.parent.mkdir(parents=True, exist_ok=True)
    # For tiny sizes (16, 24, 32), render full-canvas squircle (0.482) so tray/favicon fills pixel grid crisply
    tiny_master = render_prism_canvas(size=512, squircle_half=0.482, full_bleed=False, symbol_scale=1.04)
    sizes = (16, 24, 32, 48, 64, 128, 256)
    payloads: list[tuple[int, bytes]] = []
    for sz in sizes:
        src = tiny_master if sz <= 32 else master
        frame = src.resize((sz, sz), Image.Resampling.LANCZOS)
        if sz < 256:
            payloads.append((sz, _encode_ico_bmp_dib(frame)))
        else:
            buf = io.BytesIO()
            frame.save(buf, format="PNG", optimize=True)
            payloads.append((sz, buf.getvalue()))

    header = struct.pack("<HHH", 0, 1, len(payloads))
    dir_entries = bytearray()
    offset = 6 + 16 * len(payloads)
    blobs = bytearray()
    for sz, data in payloads:
        w_byte = 0 if sz >= 256 else sz
        h_byte = 0 if sz >= 256 else sz
        dir_entries += struct.pack(
            "<BBBBHHII",
            w_byte,
            h_byte,
            0,  # bColorCount
            0,  # bReserved
            1,  # wPlanes = 1
            32,  # wBitCount = 32
            len(data),
            offset,
        )
        blobs += data
        offset += len(data)

    dst.write_bytes(header + bytes(dir_entries) + bytes(blobs))


def write_android_vectors() -> None:
    res_dir = ROOT / "apps" / "agent_mcp_app" / "android" / "app" / "src" / "main" / "res" / "drawable"

    bg_xml = """<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:angle="315"
        android:startColor="#17193A"
        android:centerColor="#11132A"
        android:endColor="#090A17"
        android:type="linear" />
</shape>
"""
    # Clean Concentric Interlocking Prism Rings inside 108dp adaptive safe zone (center 54,54)
    fg_xml = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- Subtle Starlight Indigo optical core glow -->
    <path
        android:fillColor="#384F46E5"
        android:pathData="M58,60 m-26,0 a26,26 0 1,0 52,0 a26,26 0 1,0 -52,0" />
    <!-- Back Refracted Starlight Indigo Prism Ring -->
    <path
        android:fillColor="#FF6366F1"
        android:fillType="evenOdd"
        android:pathData="M58.5,36.5 Q61,34 63.5,36.5 L81.5,54.5 Q84,57 81.5,59.5 L63.5,77.5 Q61,80 58.5,77.5 L40.5,59.5 Q38,57 40.5,54.5 Z M59.6,46.6 Q61,45.2 62.4,46.6 L71.4,55.6 Q72.8,57 71.4,58.4 L62.4,67.4 Q61,68.8 59.6,67.4 L50.6,58.4 Q49.2,57 50.6,55.6 Z" />
    <!-- Front Sculpted Alabaster-Crystal Prism Ring -->
    <path
        android:fillColor="#FFF8FAFF"
        android:fillType="evenOdd"
        android:pathData="M46.5,26.5 Q49.2,23.8 51.9,26.5 L71.5,46.1 Q74.2,48.8 71.5,51.5 L51.9,71.1 Q49.2,73.8 46.5,71.1 L26.9,51.5 Q24.2,48.8 26.9,46.1 Z M47.8,37.8 Q49.2,36.4 50.6,37.8 L60.2,47.4 Q61.6,48.8 60.2,50.2 L50.6,59.8 Q49.2,61.2 47.8,59.8 L38.2,50.2 Q36.8,48.8 38.2,47.4 Z" />
</vector>
"""
    mono_xml = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#77FFFFFF"
        android:fillType="evenOdd"
        android:pathData="M58.5,36.5 Q61,34 63.5,36.5 L81.5,54.5 Q84,57 81.5,59.5 L63.5,77.5 Q61,80 58.5,77.5 L40.5,59.5 Q38,57 40.5,54.5 Z M59.6,46.6 Q61,45.2 62.4,46.6 L71.4,55.6 Q72.8,57 71.4,58.4 L62.4,67.4 Q61,68.8 59.6,67.4 L50.6,58.4 Q49.2,57 50.6,55.6 Z" />
    <path
        android:fillColor="#FFFFFFFF"
        android:fillType="evenOdd"
        android:pathData="M46.5,26.5 Q49.2,23.8 51.9,26.5 L71.5,46.1 Q74.2,48.8 71.5,51.5 L51.9,71.1 Q49.2,73.8 46.5,71.1 L26.9,51.5 Q24.2,48.8 26.9,46.1 Z M47.8,37.8 Q49.2,36.4 50.6,37.8 L60.2,47.4 Q61.6,48.8 60.2,50.2 L50.6,59.8 Q49.2,61.2 47.8,59.8 L38.2,50.2 Q36.8,48.8 38.2,47.4 Z" />
</vector>
"""
    stat_xml = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#99FFFFFF"
        android:fillType="evenOdd"
        android:pathData="M13.2,6.8 Q14,6 14.8,6.8 L20.2,12.2 Q21,13 20.2,13.8 L14.8,19.2 Q14,20 13.2,19.2 L7.8,13.8 Q7,13 7.8,12.2 Z M13.5,9.9 Q14,9.4 14.5,9.9 L17.1,12.5 Q17.6,13 17.1,13.5 L14.5,16.1 Q14,16.6 13.5,16.1 L10.9,13.5 Q10.4,13 10.9,12.5 Z" />
    <path
        android:fillColor="#FFFFFFFF"
        android:fillType="evenOdd"
        android:pathData="M9.2,3.8 Q10,3 10.8,3.8 L16.7,9.7 Q17.5,10.5 16.7,11.3 L10.8,17.2 Q10,18 9.2,17.2 L3.3,11.3 Q2.5,10.5 3.3,9.7 Z M9.5,7.1 Q10,6.6 10.5,7.1 L13.4,10.0 Q13.9,10.5 13.4,11.0 L10.5,13.9 Q10,14.4 9.5,13.9 L6.6,11.0 Q6.1,10.5 6.6,10.0 Z" />
</vector>
"""
    (res_dir / "ic_launcher_background.xml").write_text(bg_xml, encoding="utf-8")
    (res_dir / "ic_launcher_foreground.xml").write_text(fg_xml, encoding="utf-8")
    (res_dir / "ic_launcher_monochrome.xml").write_text(mono_xml, encoding="utf-8")
    (res_dir / "ic_stat_mcp.xml").write_text(stat_xml, encoding="utf-8")



def sync_core_version_png(web_dir: Path, macos_set: Path) -> None:
    """Syncs the exact 48x48, 64x64 & 128x128 Concentric Liquid Prism PNG Base64s into `version.dart`."""
    version_dart = ROOT / "packages" / "agent_mcp_core" / "lib" / "src" / "version.dart"
    if not version_dart.exists():
        return
    txt = version_dart.read_text(encoding="utf-8")
    mapping = {
        "appIconPng48Base64": web_dir / "favicon-48x48.png",
        "appIconPng64Base64": web_dir / "favicon.png",
        "appIconPng128Base64": macos_set / "app_icon_128.png",
    }
    for const_name, png_path in mapping.items():
        if png_path.exists() and const_name in txt:
            b64 = base64.b64encode(png_path.read_bytes()).decode("ascii")
            txt = re.sub(
                rf"const String {const_name} =\s*'[^']*';",
                f"const String {const_name} = '{b64}';",
                txt,
            )
    version_dart.write_text(txt, encoding="utf-8")

def main() -> None:
    print("[1/5] Rendering 2048px supersampled Concentric Liquid Prism master...")
    hi_master = render_prism_canvas(size=2048, squircle_half=0.468, full_bleed=False, symbol_scale=1.0)
    master_1024 = hi_master.resize((1024, 1024), Image.Resampling.LANCZOS)

    app_assets = ROOT / "apps" / "agent_mcp_app" / "assets"
    master_1024.save(app_assets / "app_icon.png", format="PNG", optimize=True)

    print("[2/5] Writing multi-resolution Windows .ico assets...")
    save_multi_ico(master_1024, app_assets / "app_icon.ico")
    save_multi_ico(
        master_1024,
        ROOT / "apps" / "agent_mcp_app" / "windows" / "runner" / "resources" / "app_icon.ico",
    )

    print("[3/5] Writing Web PWA & favicon assets...")
    web_dir = ROOT / "apps" / "agent_mcp_app" / "web"
    save_multi_ico(master_1024, web_dir / "favicon.ico")
    tiny_web = render_prism_canvas(size=512, squircle_half=0.482, full_bleed=False, symbol_scale=1.04)
    tiny_web.resize((16, 16), Image.Resampling.LANCZOS).save(web_dir / "favicon-16x16.png", format="PNG", optimize=True)
    tiny_web.resize((32, 32), Image.Resampling.LANCZOS).save(web_dir / "favicon-32x32.png", format="PNG", optimize=True)
    master_1024.resize((48, 48), Image.Resampling.LANCZOS).save(web_dir / "favicon-48x48.png", format="PNG", optimize=True)
    master_1024.resize((64, 64), Image.Resampling.LANCZOS).save(web_dir / "favicon.png", format="PNG", optimize=True)
    master_1024.resize((96, 96), Image.Resampling.LANCZOS).save(web_dir / "favicon-96x96.png", format="PNG", optimize=True)
    master_1024.resize((192, 192), Image.Resampling.LANCZOS).save(web_dir / "icons" / "Icon-192.png", format="PNG", optimize=True)
    master_1024.resize((512, 512), Image.Resampling.LANCZOS).save(web_dir / "icons" / "Icon-512.png", format="PNG", optimize=True)

    maskable_hi = render_prism_canvas(size=1024, full_bleed=True, symbol_scale=0.80)
    maskable_hi.resize((192, 192), Image.Resampling.LANCZOS).save(
        web_dir / "icons" / "Icon-maskable-192.png", format="PNG", optimize=True
    )
    maskable_hi.resize((512, 512), Image.Resampling.LANCZOS).save(
        web_dir / "icons" / "Icon-maskable-512.png", format="PNG", optimize=True
    )

    print("[4/5] Writing macOS AppIcon.appiconset (16..1024 with Big Sur/Sequoia squircle inset)...")
    macos_set = (
        ROOT
        / "apps"
        / "agent_mcp_app"
        / "macos"
        / "Runner"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    macos_master = render_macos_icon(master_1024, 1024)
    for sz in (16, 32, 64, 128, 256, 512, 1024):
        out = macos_master if sz == 1024 else macos_master.resize((sz, sz), Image.Resampling.LANCZOS)
        out.save(macos_set / f"app_icon_{sz}.png", format="PNG", optimize=True)

    print("[5/5] Writing Android legacy mipmaps & Adaptive / Monochrome / Notification XML vectors...")
    android_res = ROOT / "apps" / "agent_mcp_app" / "android" / "app" / "src" / "main" / "res"
    mipmap_sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, sz in mipmap_sizes.items():
        master_1024.resize((sz, sz), Image.Resampling.LANCZOS).save(
            android_res / folder / "ic_launcher.png", format="PNG", optimize=True
        )
    write_android_vectors()
    sync_core_version_png(web_dir, macos_set)
    print("[OK] All 25 brand icon, vector & MCP protocol surfaces synchronized cleanly!")


if __name__ == "__main__":
    main()
