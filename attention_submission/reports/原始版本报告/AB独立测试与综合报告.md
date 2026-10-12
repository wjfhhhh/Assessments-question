# AB 优化版：并行累加与点积同步最大值

验证日期：2026-10-12。当前完整无停顿任务为 **93 拍**；原 101 拍版本已保存至现场目录的 `history/before_dot_max_20261012`，旧报告不代表本版。

## 改动及实现要点

保留 A 的因果 Mask，包含两项 B 优化：四路 ACC 同拍更新，使 UPDATE 从 32 拍降至 8 拍；在完整 Score 产生的时钟沿更新合法最大值，删除独立 MAX 状态，再省 8 拍。公共分母 L 每个 Key 仍只加一次。

仅在第四个乘积产生时比较 `sum_next = acc + product_ext`，不能使用旧 acc 或同拍刚安排写入的 score_mem。第零个 Key 在当前因果 Mask 下必然合法，用其完整 Score 直接覆盖旧 x_max，兼容全负分数和无复位连续任务。后续只允许合法 Key 更新 x_max。

最后一个 Score 完成时同时更新最大值并进入 EXP；下一时钟沿保存首个权重时，最终最大值已经可用。仍保存全部 Score，并等全部 Score 完成后才计算指数，没有实现在线 Softmax。

接口、精度、指数 LUT、除法舍入及输出顺序保持不变。基础版 defense_demo 与 A 版 defense_mask 的原有文件未修改。

状态编码现为 IDLE=0、LOAD_Q=1、LOAD_KV=2、DOT=3、EXP=4、UPDATE=5、NORM=6、OUTPUT=7、FINISH=8。演示 testbench 已同步删除 MAX 状态名。

## 实测周期

以最后一对 K/V 接收时刻为第零拍：

| 阶段/指标 | A | 原 AB | 当前 AB |
|---|---:|---:|---:|
| DOT | 1～32 | 1～32 | 1～32，含最大值比较 |
| MAX | 33～40 | 33～40 | 无独立阶段 |
| EXP | 41～48 | 41～48 | 33～40 |
| UPDATE | 49～80 | 49～56 | 41～48 |
| NORM | 81～84 | 57～60 | 49～52 |
| OUTPUT | 85～88 | 61～64 | 53～56 |
| done | 89 | 65 | 57 |
| 无停顿 start→done | 125 | 101 | 93 |

相较原 AB 再省 8 拍，完整任务周期减少约 7.92%；相较 A 共省 32 拍，减少 25.6%。这是相同时钟周期下的延迟比较，不是频率或板卡吞吐实测。

## 独立仿真

从现场 independent_tests 目录实际重跑，Icarus Verilog 13.0 两种模式均正常退出，状态及源码哈希在 build/validation.json。

```text
PASS: 1071 cases, 8568 scores, 8568 weights, 4284 outputs, 2074793 division inputs
CYCLES: A=89 B=57 after final KV; savings=32; A/B results matched for all cases
```

第二遍以 `+FAST_RESTART` 运行同一组案例，B 完成后不等待较慢的 A，继续后续任务，仍对照独立数学模型。日志末尾为 `FAST_RESTART: completed without waiting for the serial reference`。两遍不能计为 2142 个不同案例。

此外遍历了 130561 个指数 LUT 整数差值。原有覆盖包括全部查询位置、Mask 开关、随机/极值输入、全负分数、未来数据扰动、配置锁存、输入暂停、忙碌 start、中途复位、无复位连续任务。

本次新增六组定向案例：第四项是唯一贡献、全负且首项最大、第四项改变大小关系、被屏蔽未来项最大、最后合法项最大、只允许第零项且为负。逐拍检查合法前缀最大值及其保持行为，并核对权重、L、四路 ACC、输出和 done 的新时序。案例名称和序号见 coverage.json。

已通过的测试不能替代尚未提供的隐藏测试或上板验收。

## 同条件综合

Vivado 2022.2，器件 xc7z010iclg225-1L，综合前加载 10 ns 时钟约束，以 out-of-context 模式运行。当前 A 与 AB 已重新综合，原 AB 数据来自同条件历史报告。

| 指标 | A | 原 AB | 当前 AB |
|---|---:|---:|---:|
| Slice LUTs | 738 | 858 | 853 |
| Slice Registers | 883 | 879 | 879 |
| DSP | 0 | 0 | 0 |
| Block RAM Tile | 0 | 0 | 0 |
| 锁存器 | 0 | 0 | 0 |
| 综合后 WNS | −20.020 ns | −21.344 ns | −21.344 ns |

本次比原 AB 少 5 个 LUT，FF 不变，最差裕量未改变。相较 A 增加 115 个 LUT，约 15.6%，换取更少周期。乘法映射到 LUT，不能说成新增四个 DSP。

两版仍未满足 10 ns 时序约束。当前 AB 最差路径从 acc_raw_reg[1][14] 到 output_mem_reg[0][7]，经过未优化的组合归一化除法，数据路径延迟 31.322 ns。此次合并最大值没有消除这个瓶颈。

原始报告见 evidence/synthesis_A 和 evidence/synthesis_B；未进行布局布线、完整板级接口约束或上板，不能宣称达到 100 MHz 或提高最高频率。

本机 Vivado 在两套报告生成后仍出现退出访问异常；evidence/synthesis_status.json 记录 reports_completed=true、退出码 −1073741819。脚本据此报错，没有把异常退出当作正常退出。

## Vivado 演示

演示只读取输入，不读取标准答案。实际重新编译 RTL，依次运行开启位置二、关闭 Mask、开启位置零、恢复开启位置二，输出分别为：

```text
[1,3,-1,6]
[100,20,-100,-20]
[1,2,-1,4]
[1,3,-1,6]
```

四次均打印 `start_to_done=93 final_kv_to_done=57`。每个 Score 还打印 RUNNING_MAX，方便讲解。最新记录为 results/vivado_parallel.log 和 results/vivado_status.json。

运行使用既有隔离运行库，未更改安装目录。计算及波形保存后仍有 Vivado 退出异常，不声称运行环境已修复。

## 独立测试文件与重跑

本报告副本位于 `D:\VivadoProject\attention_demo\defense_parallel\independent_tests`，build、results、evidence 均相对此目录。rtl 为当前实现，reference_rtl 为未改动的 A，model 为数学参考，tb 为自检平台，scripts 为仿真/综合入口；build 为最新生成的向量、源码快照及日志，results 为本次结果快照，evidence 为综合与源码保护记录。

PowerShell 重跑：

```powershell
& 'D:\VivadoProject\attention_demo\defense_parallel\independent_tests\scripts\run_tests.ps1' -Python 'C:\Users\admin\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
```

换电脑需安装 Python、Icarus，使用 -Python、-IcarusBin 指定位置。综合入口为 scripts/run_synthesis.ps1，可指定 -VivadoBin 和本机隔离库 -RuntimeRoot。

现场仍运行 defense_parallel 根目录的 run_demo.tcl，独立自检材料不加入工程。详细原理见根目录 点积同步最大值_学习说明.md，另附 docs 下中文详细注释 RTL。
