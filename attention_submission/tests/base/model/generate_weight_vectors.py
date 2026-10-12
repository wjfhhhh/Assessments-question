"""生成第二阶段测试向量，所有期望结果来自现有定点参考模型。"""
import argparse
import json
import random
from pathlib import Path
from attention_model import attention, demo_inputs


def generate(output):
    rng = random.Random(20261001)
    cases = [demo_inputs()]
    # 最大分数遍历八个位置，而且全部为负数，防止最大值被错误初始化为零。
    for position in range(8):
        scores = [-5] * 8
        scores[position] = -1
        cases.append({"Q": [1, 0, 0, 0],
                      "K": [[s, 0, 0, 0] for s in scores],
                      "V": [[-128, 127, j, -j] for j in range(8)]})
    # 相同分数、正分数整体平移及负分数覆盖所有查表边界和并列最大值。
    for scores in ([-2]*8, [5,4,3,2,1,5,4,3], [-1,-2,-3,-4,-5,-1,-2,-3]):
        cases.append({"Q": [1,0,0,0], "K": [[s,0,0,0] for s in scores],
                      "V": [[j,-j,127,-128] for j in range(8)]})
    # 相减范围达到保守极限，检验十八位有符号减法和比较。
    for q_value in (-128, 127):
        cases.append({"Q": [q_value]*4,
                      "K": [[-128]*4, [127]*4, [0]*4, [1,-1,1,-1]]*2,
                      "V": [[127,-128,0,1] for _ in range(8)]})
    # 大范围输入覆盖极端差值，小范围输入使非零的中间权重更常出现。
    for limit in (128, 2):
        for _ in range(100):
            cases.append({"Q": [rng.randrange(-limit,limit) for _ in range(4)],
                          "K": [[rng.randrange(-limit,limit) for _ in range(4)] for _ in range(8)],
                          "V": [[rng.randrange(-128,128) for _ in range(4)] for _ in range(8)]})
    output.mkdir(parents=True, exist_ok=True)
    widths = {"q":8, "k":8, "v":8, "score":18, "xmax":18, "delta":18, "weight":5}
    streams = {name: [] for name in widths}
    results = []
    for case in cases:
        result = attention(case["Q"],case["K"],case["V"])
        results.append(result)
        streams["q"].extend(case["Q"])
        for name in ("k", "v"):
            streams[name].extend(x for row in case[name.upper()] for x in row)
        for name in ("score", "delta"):
            streams[name].extend(result[name])
        streams["xmax"].append(result["x_max"])
        streams["weight"].extend(result["weight_raw"])
    for name, values in streams.items():
        bits = widths[name]
        (output / (name + ".hex")).write_text("".join(f"{x & ((1<<bits)-1):0{(bits+3)//4}x}\n" for x in values), encoding="ascii")
    # 为独立查表测试提供整个合法差值区间的期望值，而非在测试平台里复制查表逻辑。
    from attention_model import exp_lut
    (output / "lut.hex").write_text("".join(f"{exp_lut(-i):02x}\n" for i in range(130561)), encoding="ascii")
    (output / "cases.vh").write_text(f"`define TEST_CASES {len(cases)}\n", encoding="ascii")
    (output / "vectors.json").write_text(json.dumps({"inputs":cases,"results":results}, indent=2), encoding="utf-8")
    print(f"Generated {len(cases)} cases and 130561 LUT expectations")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    generate(parser.parse_args().output)
