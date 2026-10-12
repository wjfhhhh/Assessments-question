"""新版数字组 A 题定点参考模型。只使用 Python 标准库。

约定：不缩放点积；权重用最近值量化到 1/16；输出半整数向远离零方向舍入。
这些是本实现明确选择的量化规则，需与主办方后续样例核对。
"""

import argparse
import json
from pathlib import Path

S = 8
D = 4
SCALE = 16
# round(exp(x) * 16)，x <= 0 为整数。x <= -4 时小于半个量化单位。
EXP_LUT = {0: 16, -1: 6, -2: 2, -3: 1}


def round_div_signed(numerator, denominator):
    """整数除法，最近值舍入，恰好一半时向远离零的方向舍入。"""
    if denominator <= 0:
        raise ValueError("denominator must be positive")
    magnitude = (2 * abs(numerator) + denominator) // (2 * denominator)
    return -magnitude if numerator < 0 else magnitude


def exp_lut(delta):
    """输出无符号定点权重的原始整数；实际值 = 原始整数 / 16。"""
    if type(delta) is not int or delta > 0:
        raise ValueError("delta must be an integer <= 0")
    return EXP_LUT.get(delta, 0)


def validate_vector(vector, length, name):
    if not isinstance(vector, list) or len(vector) != length:
        raise ValueError(f"{name} must be a list of length {length}")
    if any(type(x) is not int or not -128 <= x <= 127 for x in vector):
        raise ValueError(f"{name} elements must be signed 8-bit integers")


def attention(q, k, v):
    """计算固定规模 S=8、d=4 的 Attention，返回所有关键中间结果。"""
    validate_vector(q, D, "Q")
    for name, matrix in (("K", k), ("V", v)):
        if not isinstance(matrix, list) or len(matrix) != S:
            raise ValueError(f"{name} must contain {S} rows")
        for j, row in enumerate(matrix):
            validate_vector(row, D, f"{name}[{j}]")

    # Python 整数不溢出，用于检查将来的 RTL 位宽是否足够。
    score = [sum(q[c] * k[j][c] for c in range(D)) for j in range(S)]
    x_max = max(score)
    delta = [x - x_max for x in score]
    weight_raw = [exp_lut(x) for x in delta]
    l_raw = sum(weight_raw)
    acc_raw = [sum(weight_raw[j] * v[j][c] for j in range(S)) for c in range(D)]
    # ACC 和 L 都含有相同的 16 倍比例，因此相除时抵消。
    output = [round_div_signed(a, l_raw) for a in acc_raw]
    assert l_raw > 0  # 至少一个最大分数的权重为 16。
    assert all(-128 <= x <= 127 for x in output)
    return {
        "score": score,
        "x_max": x_max,
        "delta": delta,
        "weight_raw": weight_raw,
        "weight": [w / SCALE for w in weight_raw],
        "L_raw": l_raw,
        "L": l_raw / SCALE,
        "ACC_raw": acc_raw,
        "ACC": [a / SCALE for a in acc_raw],
        "before_round": [a / l_raw for a in acc_raw],
        "output": output,
    }


def demo_inputs():
    """刻意包含不同分数、重复最大值、负数和量化成零的权重。"""
    return {
        "Q": [1, 0, 0, 0],
        "K": [[x, 0, 0, 0] for x in [0, -1, -2, -3, -4, 0, -1, -2]],
        "V": [[4, 2, 0, -2], [1, 6, -4, 3], [-2, 0, 8, 1],
              [6, -4, 2, -8], [127, -128, 5, 5], [0, 4, -2, 6],
              [8, -2, 4, 0], [-4, 2, 6, -2]],
    }


def print_trace(inputs, result):
    print("Fixed-point Attention: S=8, d=4, weight scale=16")
    print("Q =", inputs["Q"])
    print("K =", inputs["K"])
    print("V =", inputs["V"])
    print("\nScore =", result["score"])
    print("x_max =", result["x_max"])
    print("Score - x_max =", result["delta"])
    print("Weight raw =", result["weight_raw"])
    print("Weight     =", result["weight"])
    print("L raw =", result["L_raw"], "  L =", result["L"])
    print("ACC raw =", result["ACC_raw"])
    print("ACC     =", result["ACC"])
    print("ACC / L =", result["before_round"])
    print("Output  =", result["output"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="JSON file containing Q, K, V")
    parser.add_argument("--output", type=Path, help="Write inputs and results as JSON")
    args = parser.parse_args()
    inputs = json.loads(args.input.read_text(encoding="utf-8-sig")) if args.input else demo_inputs()
    result = attention(inputs["Q"], inputs["K"], inputs["V"])
    print_trace(inputs, result)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({"inputs": inputs, "result": result}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
