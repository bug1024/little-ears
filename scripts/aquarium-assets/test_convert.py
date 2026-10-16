import json
from pathlib import Path
import struct
import tempfile
import unittest

from resource_format import Reader, decode_dds, decode_dxt3, mesh_data
from convert_tank import matrix_mul, point, IDENTITY, reef_point, scene_point, scene_motion, build


class ConversionTests(unittest.TestCase):
    def test_truncated_node_is_rejected(self):
        with self.assertRaises(ValueError):
            Reader(b"mesh\x05fish").node()

    def test_unknown_node_is_rejected(self):
        with self.assertRaises(ValueError):
            Reader(b"xxxx\x00none\0\0\0\0").node()

    def test_out_of_range_triangle_is_rejected(self):
        invalid = struct.pack(">H3fH3H", 1, 0, 0, 0, 1, 0, 1, 0)
        with self.assertRaises(ValueError):
            mesh_data(invalid)

    def test_mesh_truncation_is_rejected(self):
        with self.assertRaises(ValueError):
            mesh_data(struct.pack(">H", 500))

    def test_dxt3_known_color_and_alpha(self):
        header = bytearray(128)
        header[:4] = b"DDS "
        struct.pack_into("<II", header, 12, 4, 4)
        header[84:88] = b"DXT3"
        # Red endpoint, palette entry 0; alpha increases in steps of 17.
        alpha = sum(i << (i * 4) for i in range(16))
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "test.dds"
            p.write_bytes(header + struct.pack("<QHHI", alpha, 0xf800, 0x07e0, 0))
            w, h, data = decode_dxt3(p)
        self.assertEqual((w, h), (4, 4))
        for i in range(16):
            self.assertEqual(list(data[i * 4:i * 4 + 4]), [255, 0, 0, i * 17])

    def test_complete_species_catalog_and_animated_bounds(self):
        import math
        source = Path(__file__).resolve().parents[2] / "local-assets/MarineAquarium3"
        if not source.exists():
            self.skipTest("Local exploration assets are not present")
        with tempfile.TemporaryDirectory() as folder:
            build(source, Path(folder))
            data = json.loads((Path(folder) / "tank.json").read_text())
            bubble = data["textures"][data["bubbleTexture"]]
            source_catalog = json.loads((source / "resource-catalog.json").read_text())
            bubble_entry = next(e for e in source_catalog if e["type"] == ".dds" and e["id"] == 419)
            _, _, original_bubbles = decode_dds(source / bubble_entry["local_path"])
            self.assertEqual((Path(folder) / bubble["file"]).read_bytes(), original_bubbles)
            import wave
            sound = Path(folder) / "bubbles.wav"
            self.assertEqual(sound.read_bytes(), (source / "extracted/sounds/128_unnamed.bin").read_bytes())
            with wave.open(str(sound)) as audio:
                self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()), (2, 2, 22050, 167422))
        bubble = data["textures"][data["bubbleTexture"]]
        self.assertEqual((bubble["name"], bubble["width"], bubble["height"]), ("bubbles.DDS", 128, 256))
        self.assertTrue(bubble["transparent"])
        self.assertEqual([a["id"] for a in data["species"]], list(range(300, 328)))
        scenery = {a["id"]: a for a in data["scenery"]}
        self.assertIn(418, scenery)
        self.assertIn(419, scenery)
        self.assertNotIn(-1, scenery)
        star, eel = scenery[299], scenery[438]
        self.assertEqual({p["name"] for p in star["parts"]}, {"arm1", "arm2", "arm3", "arm4", "arm5"})
        self.assertTrue(all(p["motion"][0] == 6 for p in star["parts"]))
        # Arm flex only lifts tips; the lowest rest vertices already clear sand.
        self.assertGreater(star["bounds"][0][1], scenery[418]["bounds"][0][1])
        self.assertLess(star["bounds"][1][1], -1.90)
        self.assertEqual(len(eel["parts"]), 1)  # Mouth target must not be drawn twice.
        self.assertEqual(eel["parts"][0]["motion"][0], 5)
        self.assertTrue(any(sum(x*x for x in v[8:11]) > 0.01 for v in eel["parts"][0]["vertices"]))
        self.assertEqual(len(data["collisionMargins"]), len(data["collisionTriangles"]) // 3)
        for asset in data["species"]:
            self.assertIn("fishbody", {p["name"] for p in asset["parts"]})
            self.assertTrue(any("fin" in p["name"] for p in asset["parts"]))
            for part in asset["parts"]:
                for v in part["vertices"]:
                    self.assertEqual(len(v), 12)
                    self.assertTrue(all(math.isfinite(x) for x in v))
                    # Real rest geometry must fit its conservative collision sphere.
                    self.assertLess(math.sqrt(sum(x*x for x in v[:3])) * asset["spawnScale"], asset["collisionRadius"])

    def test_dxt1_transparent_palette_entry(self):
        header = bytearray(128); header[:4] = b"DDS "
        struct.pack_into("<II", header, 12, 4, 4); header[84:88] = b"DXT1"
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "test.dds"; p.write_bytes(header + struct.pack("<HHI", 0, 0xffff, 0xffffffff))
            _, _, rgba = decode_dds(p)
            self.assertEqual(list(rgba[:4]), [0, 0, 0, 0])

    def test_dxt5_interpolated_alpha(self):
        header = bytearray(128); header[:4] = b"DDS "
        struct.pack_into("<II", header, 12, 4, 4); header[84:88] = b"DXT5"
        alpha_bits = sum(2 << (i * 3) for i in range(16))
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "test.dds"; p.write_bytes(header + bytes([255, 0]) + alpha_bits.to_bytes(6, "little") + struct.pack("<HHI", 0xf800, 0x07e0, 0))
            _, _, rgba = decode_dds(p)
            self.assertEqual(list(rgba[:4]), [255, 0, 0, 218])

    def test_nested_frame_transform_order(self):
        parent = IDENTITY.copy(); parent[12:15] = [10, 20, 30]
        local = IDENTITY.copy(); local[0] = 2; local[12] = 3
        self.assertEqual(point([1, 2, 3], matrix_mul(local, parent)), [15, 22, 33])

    def test_uniform_scene_transform_preserves_authored_spacing(self):
        import math
        self.assertEqual(reef_point([4, 2, 3], 402), reef_point([4, 2, 3], 414))
        base = scene_point([4, 2, 3])
        for offset in [[5, 2, 3], [4, 3, 3], [4, 2, 4]]:
            p = scene_point(offset)
            self.assertAlmostEqual(math.dist(p, base), 0.7)

    def test_soft_coral_has_local_root_and_independent_phase(self):
        points = [[0, -1, 0], [0, 0, 0], [1, 2, 0]]
        pivot, a = scene_motion(431, 'left', points)
        _, b = scene_motion(431, 'right', points)
        self.assertEqual(pivot[:3], [0, -1, 0])
        self.assertEqual(a[0], 1)
        self.assertNotEqual(a[3], b[3])
        self.assertLessEqual(a[1], 0.18)

    def test_clam_shells_have_opposite_hinge_angles_and_shared_clock(self):
        p = [[0, 0, 0], [1, 1, 0]]
        _, near = scene_motion(405, 'Mesh_ClamshellNear', p)
        _, far = scene_motion(405, 'Mesh_ClamshellFar', p)
        self.assertEqual(near[1], -far[1])
        self.assertEqual(near[2:], far[2:])


if __name__ == "__main__":
    unittest.main()
