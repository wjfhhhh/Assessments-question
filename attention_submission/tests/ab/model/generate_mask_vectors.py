"""独立的因果屏蔽参考计算与测试向量生成，使用数学指数而非硬件查表。"""
import argparse
import copy
import json
import math
import random
from pathlib import Path


def reference(case):
    """只对合法键归一化；被屏蔽差值输出零作观察占位。"""
    enabled, pos = case['enable'], case['position']
    score = [sum(a*b for a, b in zip(case['Q'], row)) for row in case['K']]
    allowed = [not enabled or j <= pos for j in range(8)]
    maximum = max(s for s, ok in zip(score, allowed) if ok)
    delta = [s-maximum if ok else 0 for s, ok in zip(score, allowed)]
    weight = [math.floor(16*math.exp(d)+0.5) if ok else 0 for d, ok in zip(delta, allowed)]
    denominator = sum(weight)
    acc = [sum(weight[j]*case['V'][j][c] for j in range(8)) for c in range(4)]
    result = []
    for value in acc:
        quotient, remainder = divmod(abs(value), denominator)
        rounded = quotient + (2*remainder >= denominator)
        result.append(-rounded if value < 0 else rounded)
    return dict(score=score, xmax=[maximum], delta=delta, weight=weight,
                l=[denominator], acc=acc, out=result)


def make_cases():
    rng = random.Random(20261011)
    cases = []
    demo = dict(Q=[1,1,1,1], K=[[1,1,1,0],[1,1,0,0],[1,0,0,0],[1,-1,0,0],
                               [-1,0,0,0],[2,1,0,0],[2,0,0,0],[0,1,0,0]],
                V=[[1,2,-1,4],[2,4,-2,8],[3,6,-3,12],[4,8,-4,16],
                   [9,18,-9,36],[1,2,-1,4],[2,4,-2,8],[3,6,-3,12]])
    # 首例方便手算；合法的前缀只有前三项。
    cases.append(dict(copy.deepcopy(demo), enable=1, position=2))
    for pos in range(8):
        for enabled in (0,1):
            cases.append(dict(copy.deepcopy(demo), enable=enabled, position=pos))
            for scores in ([0]*8, [-8+j for j in range(8)], [3]*8,
                           [-4 if j<=pos else 127 for j in range(8)]):
                cases.append(dict(Q=[1,0,0,0], K=[[s,0,0,0] for s in scores],
                                  V=[[127,-128,1 if j<4 else 2,-1 if j<4 else -2] for j in range(8)],
                                  enable=enabled, position=pos))
            # 包含较小随机值和八位输入极限附近的大范围值。
            for limit in (3,128):
                for _ in range(30):
                    cases.append(dict(Q=[rng.randrange(-limit,limit) for _ in range(4)],
                                      K=[[rng.randrange(-limit,limit) for _ in range(4)] for _ in range(8)],
                                      V=[[rng.randrange(-128,128) for _ in range(4)] for _ in range(8)],
                                      enable=enabled, position=pos))
        # 成对测试：合法前缀相同，任意改变未来 K/V，输出和合法权重应完全不变。
        first = dict(copy.deepcopy(demo), enable=1, position=pos)
        second = copy.deepcopy(first)
        for j in range(pos+1,8):
            second['K'][j]=[127]*4
            second['V'][j]=[-128,127,-128,127]
        a,b=reference(first),reference(second)
        assert a['weight']==b['weight'] and a['out']==b['out'] and a['acc']==b['acc']
        cases.extend((first,second))
    # 点积的正负边界；屏蔽位置可能包含比分数最大值更大的值。
    for pos in range(8):
        cases.append(dict(Q=[-128]*4, K=[[-128]*4 if j%2 else [127]*4 for j in range(8)],
                          V=[[127,-128,127,-128] for _ in range(8)], enable=1,position=pos))
    # 定向检查第四项决定分数、首项全负初始化、末项最大值以及屏蔽未来最大值。
    # 连续排列正分数与负分数任务，可发现错误沿用上个任务最大值的问题。
    directed = [
        ('last_product_only', [0,0,0,1], [[0,0,0,s] for s in [4,3,2,1,0,-1,-2,5]], 0, 7),
        ('negative_first_is_max', [0,0,0,1], [[0,0,0,s] for s in [-1,-2,-3,-4,-5,-6,-7,-8]], 0, 7),
        ('fourth_product_reorders', [1,1,1,1], [[9,0,0,-12],[-9,0,0,8]] + [[0,0,0,-4] for _ in range(6)], 0, 7),
        ('masked_future_largest', [0,0,0,1], [[0,0,0,s] for s in [-5,-2,-3,127,126,125,124,123]], 1, 2),
        ('last_legal_is_max', [0,0,0,1], [[0,0,0,s] for s in [-8,-7,-6,-5,-4,-3,-2,-1]], 1, 7),
        ('only_first_negative', [0,0,0,1], [[0,0,0,s] for s in [-7,127,126,125,124,123,122,121]], 1, 0),
    ]
    for name, q, k, enabled, pos in directed:
        cases.append(dict(Q=q, K=k, V=[[j+1,2*j-7,-j-1,127 if j%2 else -128] for j in range(8)],
                          enable=enabled, position=pos, tag=name))
    return cases


def generate(output):
    output.mkdir(parents=True,exist_ok=True)
    widths=dict(q=8,k=8,v=8,enable=1,position=3,score=18,xmax=18,delta=18,weight=5,
                l=8,acc=15,out=8,partial_l=8,partial_acc=15)
    streams={name:[] for name in widths}
    cases=make_cases()
    for case in cases:
        result=reference(case)
        if case['enable'] and case['position']==0:
            assert result['out']==case['V'][0]
        assert 16 <= result['l'][0] <= 128
        for name in ('q','k','v'):
            values=case[name.upper()]
            streams[name].extend(values if name=='q' else [x for row in values for x in row])
        streams['enable'].append(case['enable'])
        streams['position'].append(case['position'])
        for name,values in result.items():
            streams[name].extend(values)
        for step in range(32):
            j,c=divmod(step,4)
            streams['partial_l'].append(sum(result['weight'][:j+1]))
            for column in range(4):
                end=j+1 if column<=c else j
                streams['partial_acc'].append(sum(result['weight'][n]*case['V'][n][column] for n in range(end)))
    for name,values in streams.items():
        bits=widths[name]
        (output/(name+'.hex')).write_text(''.join(f'{x&((1<<bits)-1):0{(bits+3)//4}x}\n' for x in values),encoding='ascii')
    (output/'lut.hex').write_text(''.join(f'{math.floor(16*math.exp(-i)+0.5):02x}\n' for i in range(130561)),encoding='ascii')
    (output/'cases.vh').write_text(f'`define TEST_CASES {len(cases)}\n',encoding='ascii')
    (output/'coverage.json').write_text(json.dumps(dict(cases=len(cases), positions=list(range(8)),
        mask_modes=[0,1], future_change_pairs=8, reference_equivalence='A vs optimized AB, all configurations',
        directed_cases=[dict(index=i, tag=c['tag']) for i,c in enumerate(cases) if 'tag' in c],
        first_case=cases[0], first_result=reference(cases[0])),indent=2),encoding='utf-8')
    print(f'Generated {len(cases)} causal-mask cases')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output',type=Path)
    generate(parser.parse_args().output)
