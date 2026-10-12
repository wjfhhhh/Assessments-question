"""生成 RTL 测试向量及 Python 模型期望结果。"""
import argparse
import json
import random
from pathlib import Path
from attention_model import attention, demo_inputs


def generate(output):
    rng = random.Random(20260929)
    cases = [demo_inputs()]
    for value in (-128, 127, 0):
        cases.append({"Q": [value]*4,
                      "K": [[-128]*4, [127]*4, [0]*4, [1,-1,1,-1]]*2,
                      "V": [[-128,127,-1,0] for _ in range(8)]})
    cases.append({"Q": [0,0,0,-128], "K": [[0,0,0,-128] for _ in range(8)],
                  "V": [[1,2,3,4] for _ in range(8)]})
    for _ in range(100):
        cases.append({"Q": [rng.randrange(-128,128) for _ in range(4)],
                      "K": [[rng.randrange(-128,128) for _ in range(4)] for _ in range(8)],
                      "V": [[rng.randrange(-128,128) for _ in range(4)] for _ in range(8)]})
    output.mkdir(parents=True, exist_ok=True)
    streams = {name: [] for name in ("q", "k", "v", "score")}
    for case in cases:
        streams["q"].extend(case["Q"])
        for name in ("k", "v"):
            streams[name].extend(x for row in case[name.upper()] for x in row)
        streams["score"].extend(attention(case["Q"],case["K"],case["V"])["score"])
    for name, values in streams.items():
        bits = 18 if name == "score" else 8
        (output / (name + ".hex")).write_text("".join(f"{x & ((1<<bits)-1):0{(bits+3)//4}x}\n" for x in values), encoding="ascii")
    (output / "vectors.json").write_text(json.dumps(cases, indent=2), encoding="utf-8")
    print(f"Generated {len(cases)} cases, {len(cases)*8} expected scores")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("output", type=Path)
    generate(p.parse_args().output)
