#!/usr/bin/env python3
import os, sys, unittest, tempfile, shutil
import numpy as np

# Add directory to sys.path
sys.path.insert(0, os.path.dirname(__file__))
from verify_b2a_readback import verify_and_compare

class TestVerifyB2AReadback(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.width = 64
        self.height = 64
        self.total_pixels = self.width * self.height

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_exact_inversion(self):
        h_arr = np.random.randint(0, 256, (self.height, self.width, 4), dtype=np.uint8)
        g_arr = np.empty_like(h_arr)
        g_arr[:, :, :3] = 255 - h_arr[:, :, :3]
        g_arr[:, :, 3] = h_arr[:, :, 3]

        h_path = os.path.join(self.test_dir, "test_h.raw")
        g_path = os.path.join(self.test_dir, "test_g.raw")

        with open(h_path, "wb") as f:
            f.write(h_arr.tobytes())
        with open(g_path, "wb") as f:
            f.write(g_arr.tobytes())

        res = verify_and_compare(h_path, g_path, self.width, self.height, out_dir=self.test_dir)
        self.assertEqual(res["exact_rgb_matches"], self.total_pixels)
        self.assertEqual(res["exact_rgb_percentage"], 100.0)
        self.assertEqual(res["max_abs_rgb_error"], 0)
        self.assertEqual(res["mean_abs_rgb_error"], 0.0)
        self.assertEqual(res["alpha_matches"], self.total_pixels)
        self.assertEqual(res["alpha_percentage"], 100.0)
        self.assertTrue(os.path.exists(os.path.join(self.test_dir, "b2a_H.png")))
        self.assertTrue(os.path.exists(os.path.join(self.test_dir, "b2a_G.png")))
        self.assertTrue(os.path.exists(os.path.join(self.test_dir, "b2a_expected_inverted_H.png")))

    def test_controlled_1_lsb_error(self):
        h_arr = np.full((self.height, self.width, 4), 100, dtype=np.uint8)
        # exact inverted is 155, let's make G be 156 (error = 1)
        g_arr = np.full((self.height, self.width, 4), 156, dtype=np.uint8)
        g_arr[:, :, 3] = 100 # alpha matches

        h_path = os.path.join(self.test_dir, "test_h_1lsb.raw")
        g_path = os.path.join(self.test_dir, "test_g_1lsb.raw")

        with open(h_path, "wb") as f:
            f.write(h_arr.tobytes())
        with open(g_path, "wb") as f:
            f.write(g_arr.tobytes())

        res = verify_and_compare(h_path, g_path, self.width, self.height)
        self.assertEqual(res["exact_rgb_matches"], 0)
        self.assertEqual(res["within_1_lsb_matches"], self.total_pixels)
        self.assertEqual(res["within_1_lsb_percentage"], 100.0)
        self.assertEqual(res["max_abs_rgb_error"], 1)
        self.assertAlmostEqual(res["mean_abs_rgb_error"], 1.0)

    def test_size_mismatch(self):
        h_path = os.path.join(self.test_dir, "test_h_bad.raw")
        g_path = os.path.join(self.test_dir, "test_g_bad.raw")

        with open(h_path, "wb") as f:
            f.write(b"123")
        with open(g_path, "wb") as f:
            f.write(b"123")

        with self.assertRaises(ValueError):
            verify_and_compare(h_path, g_path, self.width, self.height)

if __name__ == "__main__":
    unittest.main()
