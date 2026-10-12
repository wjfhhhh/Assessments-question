"""生成完整注意力测试向量，包含最终值和每一拍的加权累加期望值。"""
import argparse
import json
import random
from pathlib import Path
from attention_model import attention
from generate_weight_vectors import generate as generate_weight_vectors


def generate(output, input_path=None):
    generate_weight_vectors(output)
    cases = json.loads((output / "vectors.json").read_text(encoding="utf-8"))["inputs"]
    # 全相同分数对应均匀权重，直接构造极值、正负半整数和零输出。
    for values in (
        [[127,-128,1 if j<4 else 0,-1 if j<4 else 0] for j in range(8)],
        [[1 if j<4 else 2,-1 if j<4 else -2,1 if j<3 else 0,-1 if j<3 else 0] for j in range(8)],
        [[0,0,0,0] for _ in range(8)],
    ):
        cases.append({"Q":[0]*4,"K":[[0]*4 for _ in range(8)],"V":values})
    # 权重为十六和一，其余为零，使分母为十七，覆盖奇数分母舍入。
    cases.append({"Q":[1,0,0,0],"K":[[s,0,0,0] for s in [0,-3,-4,-5,-6,-7,-8,-9]],
                  "V":[[-128,127,-8,8],[127,-128,0,0]]+[[0]*4 for _ in range(6)]})
    rng = random.Random(20261002)
    for limit in (3,128):
        for _ in range(500):
            cases.append({"Q":[rng.randrange(-limit,limit) for _ in range(4)],
                          "K":[[rng.randrange(-limit,limit) for _ in range(4)] for _ in range(8)],
                          "V":[[rng.randrange(-128,128) for _ in range(4)] for _ in range(8)]})
    # 现场演示时只输出指定输入，仍使用相同的期望生成与逐拍检查规则。
    if input_path is not None:
        cases = [json.loads(input_path.read_text(encoding="utf-8-sig"))]
    widths = {"q":8,"k":8,"v":8,"score":18,"xmax":18,"delta":18,"weight":5,
              "l":8,"acc":15,"out":8,"partial_l":8,"partial_acc":15}
    streams = {name:[] for name in widths}
    results = []
    for case in cases:
        result = attention(case["Q"],case["K"],case["V"])
        results.append(result)
        streams["q"].extend(case["Q"])
        for name in ("k","v"):
            streams[name].extend(x for row in case[name.upper()] for x in row)
        for name in ("score","delta"):
            streams[name].extend(result[name])
        streams["xmax"].append(result["x_max"])
        streams["weight"].extend(result["weight_raw"])
        streams["l"].append(result["L_raw"])
        streams["acc"].extend(result["ACC_raw"])
        streams["out"].extend(result["output"])
        # 用数学求和表达式独立计算每个时间点已完成的项，而不是复制寄存器更新代码。
        for step in range(32):
            j, component = divmod(step,4)
            streams["partial_l"].append(sum(result["weight_raw"][:j+1]))
            for c in range(4):
                count = j+1 if c<=component else j
                streams["partial_acc"].append(sum(result["weight_raw"][i]*case["V"][i][c] for i in range(count)))
    for name, values in streams.items():
        bits = widths[name]
        (output / (name+".hex")).write_text("".join(f"{x & ((1<<bits)-1):0{(bits+3)//4}x}\n" for x in values),encoding="ascii")
    (output / "cases.vh").write_text(f"`define TEST_CASES {len(cases)}\n",encoding="ascii")
    (output / "vectors.json").write_text(json.dumps({"inputs":cases,"results":results},indent=2),encoding="utf-8")
    print(f"Generated {len(cases)} complete Attention cases")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output",type=Path)
    parser.add_argument("--input",type=Path)
    args = parser.parse_args()
    generate(args.output, args.input)
