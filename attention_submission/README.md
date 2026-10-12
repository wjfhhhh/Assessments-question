# 数字组考核：定点 Attention RTL 项目

GitHub：wjfhhhh/Assessments-question。固定规模为一个四维 Q 向量、八组四维 K/V 向量，输入和输出均为 8 位有符号整数。实现基础功能、A 因果 Mask 和 B 并行优化；E、G 以调研报告提交。

本目录是从 `D:/VivadoProject/attention_demo` 整理出的提交材料。基础版、A、AB、并行点积版分别保留，现场演示与自动自检使用不同 TB。

## 1. 从哪里开始看

| 内容 | 位置 |
|---|---|
| 完整基础 RTL | `demo/rtl/attention_ip.v`、`exp_lut.v`、`round_div_signed.v` |
| A / AB / 并行点积 RTL | `demo/rtl/attention_ip_causal_mask.v`、`attention_ip_parallel.v`、`attention_ip_parallel_dot.v` |
| 四个现场 TB 与入口 | `demo/tb/`、`demo/01_base.tcl` 至 `04_dot.tcl` |
| 四版独立自检、模型和脚本 | `tests/base/`、`tests/mask/`、`tests/ab/`、`tests/dot/` |
| 六页基础设计报告 | [基础设计报告 PDF](reports/基础设计报告.pdf)，[可编辑 Markdown](reports/基础设计报告.md) |
| 最新优化、验证与资源汇总 | [提交说明与优化结果](reports/提交说明与优化结果.md) |
| E、G 调研 | [E_G调研报告](reports/E_G调研报告.md) |
| 5～8 分钟汇报材料 | [答辩汇报 PPT：111.pptx](slides/111.pptx) |
| 仿真波形 | `evidence/demo_waves/*.wdb`、`evidence/base/current_regression_trace.vcd` |
| 波形图、结果截图 | `evidence/base/demo_waveform.png`、`results_screenshot.png` |
| 资源与时序原始报告 | `evidence/synthesis/`；既有进阶结果另在 `tests/*/evidence/` |
| 测试统计与源码校验 | `evidence/submission_validation.json`、`manifest_sha256.json` |

原始版本报告放在 `reports/原始版本报告/`，其中本地运行路径与历史记录按产生时保留。整理后的运行命令以本 README 为准。基础 PDF 是基础版设计报告，最新 A/B 改动和本轮复测结果由单独的优化报告补充。

## 2. 算法与数值约定

```text
Score[j] = Σ Q[k] × K[j][k]
x_max = 合法 Key 中的最大 Score
Weight_raw[j] = round(16 × exp(Score[j] − x_max))
L_raw = Σ Weight_raw[j]
ACC_raw[c] = Σ Weight_raw[j] × V[j][c]
O[c] = round(ACC_raw[c] / L_raw)
```

按新版题目使用原始点积，不额外除以 sqrt(d)。权重保留 4 位二进制小数，整数编码 16 表示 1.0。非正整数差值 0、−1、−2、−3 对应编码 16、6、2、1，更小差值量化为 0。最终采用最近整数舍入，半整数向远离零方向舍入。

开启 Mask 时只有 `j <= query_index` 的 Key 合法；被屏蔽项不参与最大值，权重为零。参数在接受 start 时锁存。

## 3. 工具与运行条件

- Windows，Vivado/XSim 2022.2。
- 自动自检另使用 Python 3 和 Icarus Verilog 13.0；模型只依赖 Python 标准库。
- 新版统一综合参考器件为 `xc7z010iclg225-1L`，模块级 out-of-context，目标时钟周期 10 ns。
- 建议将仓库放在较短的英文目录。仿真输入必须使用 8 位补码，两位十六进制。

仓库不含 Vivado/Icarus 安装包、DLL、工程缓存或崩溃转储。已有的本机隔离运行库是可选环境修复措施，不属于 RTL 的依赖。

## 4. 在 Vivado 运行四个版本

无需手动新建工程。打开 Vivado，在 Tcl Console 中执行下列命令之一，将路径改为本机克隆位置：

```tcl
source -encoding utf-8 D:/Assessments-question/attention_submission/demo/01_base.tcl
source -encoding utf-8 D:/Assessments-question/attention_submission/demo/02_mask.tcl
source -encoding utf-8 D:/Assessments-question/attention_submission/demo/03_ab.tcl
source -encoding utf-8 D:/Assessments-question/attention_submission/demo/04_dot.tcl
```

每次只执行所需的一条。入口自动创建或打开 `demo/project/attention_four_versions.xpr`，选择对应仿真顶层、编译、运行并生成波形。换版本时执行另一条入口即可。已有本机兼容逻辑统一工具及链接库目录，调用结束后恢复环境。

| 入口 | 仿真顶层 | 正式 DUT | 无停顿 start→done | 最后 K/V→done |
|---|---|---|---:|---:|
| 01_base | tb_demo_base | attention_ip | 125 | 89 |
| 02_mask | tb_demo_mask | attention_ip_causal_mask | 125 | 89 |
| 03_ab | tb_demo_ab | attention_ip_parallel | 93 | 57 |
| 04_dot | tb_demo_dot | attention_ip_parallel_dot | 69 | 33 |

单次现场演示读取一组完整任务，包含一个 Q 和八组 K/V，打印 Score、权重、L、ACC 和四个输出。现场 TB 不读取标准答案。正常完成标记为 `FOUR_DEMO_COMPLETED: 对应版本`。

基础版默认输入便于手算，后三版默认开启 Mask、查询位置二，包含未来位置高分的例子。默认输出都为 `[1,3,-1,6]`，但基础版与后三版的输入不同。公平比较数值时应使用同一套 Q/K/V，并关闭后三版 Mask；比较三个进阶版本时应保持输入和 Mask 配置一致。

## 5. 现场更换输入

编辑 `demo/input/` 中相应前缀的 HEX，保存后重新 source 对应入口。无需修改 RTL、TB、Tcl 或预期答案。

| 版本 | Q | K | V | Mask 配置 |
|---|---|---|---|---|
| 基础 | base_q.hex | base_k.hex | base_v.hex | 无 |
| A | mask_q.hex | mask_k.hex | mask_v.hex | mask_control.hex |
| AB | ab_q.hex | ab_k.hex | ab_v.hex | ab_control.hex |
| 并行点积 | dot_q.hex | dot_k.hex | dot_v.hex | dot_control.hex |

Q 共 4 个字节，K/V 各 32 个字节，按 Key 编号和四个分量的次序排列。负数用 8 位补码，例如 −1 写 `ff`、−128 写 `80`。控制文件依次为开关 `00/01` 和查询位置 `00`～`07`。不要只点击 Restart 来换输入，以免使用旧的仿真目录副本。

## 6. 重跑独立自检

在 PowerShell 中进入 `attention_submission`。如果本机没有 Icarus，可使用附带的安装辅助脚本，或通过 `-IcarusBin` 指定现有安装的 bin 目录：

```powershell
& ./tests/base/scripts/setup_iverilog.ps1
```

分别运行四版测试：

```powershell
& ./tests/base/scripts/run_iverilog.ps1 -Python python
& ./tests/mask/scripts/run_tests.ps1 -Python python
& ./tests/ab/scripts/run_tests.ps1 -Python python
& ./tests/dot/scripts/run_tests.ps1 -Python python
```

若 Python 未加入 PATH，将 `python` 换成解释器完整路径。各版可增加 `-IcarusBin '本机 Icarus 的 bin 目录'`。运行时重新生成预期向量，结果在各自 `build/` 中；提交时的复测快照保存在 `results/`。AB 和并行点积版还执行快速连续任务模式，两遍使用相同案例，不将其算成两倍不同输入。

本轮提交包复测：基础版 1218 组、A 版 1065 组、AB 版 1071 组、并行点积版 1076 组，均通过，Icarus 退出码为 0。每个 Key 的 Score/权重、L/ACC、中间时序和输出均有对应检查；另检查极值、随机输入、Mask、暂停、忙碌 start、复位和连续任务等。

另已在整理后的目录中重新运行四个 Vivado 现场入口，实际日志为 `evidence/demo/submission_demo.log`，每版波形数据库也由本轮运行更新。截图是早期基础案例的 VCD 导出和结果展示页截图，来源在优化报告中说明。

## 7. 综合与资源报告

在 Vivado Tcl Console 执行以下脚本，可在同一器件、同一时钟约束下综合四版。建议先结束当前仿真并关闭当前工程。脚本以 in-memory 工程运行，结果写入 `evidence/synthesis/`：

```tcl
source -encoding utf-8 D:/Assessments-question/attention_submission/scripts/synthesize_all.tcl
```

也可从本机 Vivado 命令环境运行批处理，追加 `-tclargs 器件型号 时钟周期ns` 改变条件。该脚本完成后会退出 Vivado，因此不应在有未保存工程操作时运行。

资源看 `utilization.rpt` 的 Slice LUTs、Slice Registers、DSPs 和 Block RAM Tile；时序看 `timing.rpt` 与 `critical_paths.rpt`。仿真拍数与综合时序是不同指标，行为仿真中的 10 ns 时钟不能证明上板达到 100 MHz。

## 8. 已验证范围与限制

已完成基础计算、因果 Mask、四路加权累加、点积同步最大值和四路并行点积。E/G 为文献调研，未实现替代指数电路、Online Softmax 或 FlashAttention，不申报 C/D/F 功能。

已有综合结果的 WNS 为负；没有布局布线、上板或真实功耗结果。自检通过不代表通过主办方未提供的隐藏样例。本机 Vivado 有退出阶段访问异常，日志与状态分别记录功能完成、报告生成和进程退出码。

代码、模型、测试和文档编写过程中使用了 AI 辅助。项目理解及现场代码解释、答辩由提交者完成。
