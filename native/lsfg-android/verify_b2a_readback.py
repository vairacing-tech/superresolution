#!/usr/bin/env python3
"""
Standalone Verifier for LSFG B2A GPU Readback Proof.
Compares H (captured Minecraft frame) and G (compute-generated frame) to verify:
G.rgb == 255 - H.rgb (RGB Inversion) and G.a == H.a
"""

import os, sys, argparse, struct
import numpy as np
from PIL import Image

def verify_and_compare(h_raw_path, g_raw_path, width, height, out_dir=None):
    expected_size = width * height * 4
    if not os.path.exists(h_raw_path):
        raise FileNotFoundError(f"H raw file not found: {h_raw_path}")
    if not os.path.exists(g_raw_path):
        raise FileNotFoundError(f"G raw file not found: {g_raw_path}")

    h_size = os.path.getsize(h_raw_path)
    g_size = os.path.getsize(g_raw_path)

    if h_size != expected_size:
        raise ValueError(f"H file size mismatch: expected {expected_size} bytes ({width}x{height}x4), got {h_size}")
    if g_size != expected_size:
        raise ValueError(f"G file size mismatch: expected {expected_size} bytes ({width}x{height}x4), got {g_size}")

    with open(h_raw_path, "rb") as f:
        h_bytes = f.read()
    with open(g_raw_path, "rb") as f:
        g_bytes = f.read()

    h_arr = np.frombuffer(h_bytes, dtype=np.uint8).reshape((height, width, 4))
    g_arr = np.frombuffer(g_bytes, dtype=np.uint8).reshape((height, width, 4))

    # Save PNGs if out_dir specified
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        img_h = Image.fromarray(h_arr, 'RGBA')
        img_g = Image.fromarray(g_arr, 'RGBA')
        img_h.save(os.path.join(out_dir, "b2a_H.png"))
        img_g.save(os.path.join(out_dir, "b2a_G.png"))

        # Expected inverted H
        expected_arr = np.empty_like(h_arr)
        expected_arr[:, :, :3] = 255 - h_arr[:, :, :3]
        expected_arr[:, :, 3] = h_arr[:, :, 3]
        img_exp = Image.fromarray(expected_arr, 'RGBA')
        img_exp.save(os.path.join(out_dir, "b2a_expected_inverted_H.png"))

    # Numerical Comparison
    total_pixels = width * height
    h_rgb = h_arr[:, :, :3].astype(np.int32)
    g_rgb = g_arr[:, :, :3].astype(np.int32)
    h_alpha = h_arr[:, :, 3]
    g_alpha = g_arr[:, :, 3]

    expected_rgb = 255 - h_rgb
    rgb_diff = np.abs(g_rgb - expected_rgb) # shape (H, W, 3)
    max_rgb_diff_per_pixel = np.max(rgb_diff, axis=2) # shape (H, W)

    exact_matches = int(np.sum(max_rgb_diff_per_pixel == 0))
    exact_percentage = (exact_matches / total_pixels) * 100.0

    within_1_lsb = int(np.sum(max_rgb_diff_per_pixel <= 1))
    within_1_lsb_percentage = (within_1_lsb / total_pixels) * 100.0

    max_abs_error = int(np.max(rgb_diff))
    mean_abs_error = float(np.mean(rgb_diff))

    alpha_matches = int(np.sum(h_alpha == g_alpha))
    alpha_percentage = (alpha_matches / total_pixels) * 100.0

    results = {
        "width": width,
        "height": height,
        "total_pixels": total_pixels,
        "exact_rgb_matches": exact_matches,
        "exact_rgb_percentage": exact_percentage,
        "within_1_lsb_matches": within_1_lsb,
        "within_1_lsb_percentage": within_1_lsb_percentage,
        "max_abs_rgb_error": max_abs_error,
        "mean_abs_rgb_error": mean_abs_error,
        "alpha_matches": alpha_matches,
        "alpha_percentage": alpha_percentage,
    }

    return results

def main():
    parser = argparse.ArgumentParser(description="Verify LSFG B2A GPU Readback Proof")
    parser.add_argument("--h-raw", required=True, help="Path to b2a_H_rgba8.raw")
    parser.add_argument("--g-raw", required=True, help="Path to b2a_G_rgba8.raw")
    parser.add_argument("--width", type=int, default=1920, help="Image width (default: 1920)")
    parser.add_argument("--height", type=int, default=1080, help="Image height (default: 1080)")
    parser.add_argument("--out-dir", default=None, help="Directory to save output PNG files")

    args = parser.parse_args()
    results = verify_and_compare(args.h_raw, args.g_raw, args.width, args.height, args.out_dir)

    print("==================================================")
    print("LSFG B2A GPU READBACK PROOF VERIFICATION RESULTS")
    print("==================================================")
    print(f"Dimensions:               {results['width']} x {results['height']} ({results['total_pixels']:,} pixels)")
    print(f"Exact RGB Matches:        {results['exact_rgb_matches']:,} / {results['total_pixels']:,} ({results['exact_rgb_percentage']:.2f}%)")
    print(f"Within \u00b11 LSB:            {results['within_1_lsb_matches']:,} / {results['total_pixels']:,} ({results['within_1_lsb_percentage']:.2f}%)")
    print(f"Max Absolute RGB Error:   {results['max_abs_rgb_error']}")
    print(f"Mean Absolute RGB Error:  {results['mean_abs_rgb_error']:.4f}")
    print(f"Alpha Exact Matches:      {results['alpha_matches']:,} / {results['total_pixels']:,} ({results['alpha_percentage']:.2f}%)")
    print("==================================================")

if __name__ == "__main__":
    main()
