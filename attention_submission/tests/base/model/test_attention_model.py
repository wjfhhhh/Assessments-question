"""手算、边界与独立浮点指数公式交叉验证。"""
import math
import random
import unittest

from attention_model import attention, demo_inputs, exp_lut, round_div_signed


class AttentionTests(unittest.TestCase):
    def test_demo_hand_calculation(self):
        x = demo_inputs()
        r = attention(x["Q"], x["K"], x["V"])
        self.assertEqual(r["weight_raw"], [16, 6, 2, 1, 0, 16, 6, 2])
        self.assertEqual(r["L_raw"], 49)
        self.assertEqual(r["ACC_raw"], [112, 120, -2, 72])
        self.assertEqual(r["output"], [2, 2, 0, 1])

    def test_lut_against_exponential(self):
        for delta in range(-130560, 1):
            self.assertEqual(exp_lut(delta), math.floor(math.exp(delta) * 16 + 0.5))

    def test_negative_and_positive_ties(self):
        for n, expected in [(1, 1), (-1, -1), (3, 2), (-3, -2), (0, 0)]:
            self.assertEqual(round_div_signed(n, 2), expected)

    def test_equal_scores_mean_and_extremes(self):
        v = [[127, -128, 1 if j < 4 else 0, -1 if j < 4 else 0] for j in range(8)]
        r = attention([0] * 4, [[127] * 4 for _ in range(8)], v)
        self.assertEqual(r["L_raw"], 128)
        self.assertEqual(r["output"], [127, -128, 1, -1])

    def test_maximum_score_and_zeroed_weights(self):
        k = [[-128] * 4] + [[127] * 4 for _ in range(7)]
        v = [[-128, 127, 2, -3]] + [[0] * 4 for _ in range(7)]
        r = attention([-128] * 4, k, v)
        self.assertEqual(r["score"], [65536] + [-65024] * 7)
        self.assertEqual(r["delta"], [0] + [-130560] * 7)
        self.assertEqual(r["output"], v[0])

    def test_random_against_independent_formula(self):
        rng = random.Random(20260929)
        for limit in (2, 128):
            for _ in range(500):
                q = [rng.randrange(-limit, limit) for _ in range(4)]
                k = [[rng.randrange(-limit, limit) for _ in range(4)] for _ in range(8)]
                v = [[rng.randrange(-128, 128) for _ in range(4)] for _ in range(8)]
                scores = [sum(a * b for a, b in zip(q, row)) for row in k]
                weights = [math.floor(16 * math.exp(s - max(scores)) + 0.5) for s in scores]
                acc = [sum(w * row[c] for w, row in zip(weights, v)) for c in range(4)]
                expected = []
                for a in acc:
                    value = a / sum(weights)
                    expected.append(math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5))
                result = attention(q, k, v)
                self.assertEqual(result["score"], scores)
                self.assertEqual(result["weight_raw"], weights)
                self.assertEqual(result["ACC_raw"], acc)
                self.assertEqual(result["output"], expected)

    def test_invalid_inputs(self):
        x = demo_inputs()
        for bad_q in ([1, 2], [128, 0, 0, 0], [True, 0, 0, 0], [0.5, 0, 0, 0]):
            with self.assertRaises(ValueError):
                attention(bad_q, x["K"], x["V"])


if __name__ == "__main__":
    unittest.main()
