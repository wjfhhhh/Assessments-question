# 数字组考核提交 — wjfhhhh

本仓库 fork 自 [puxinmao/Assessments-question](https://github.com/puxinmao/Assessments-question)，原始考题资料保留在 `大二考核/`。

我的定点 Attention 项目提交位于 **[attention_submission](attention_submission/README.md)**。

- 基础 RTL、因果 Mask、并行累加、点积同步最大值与四路并行点积。
- 四个独立 Vivado 演示入口，可修改输入 HEX 后重新运行。
- Python 参考模型与四版独立自检，实际复测通过 1218 / 1065 / 1071 / 1076 组案例。
- 六页基础设计报告、最新优化与验证报告、E/G 文献调研和答辩 PPT。
- 实际仿真波形、结果截图、资源与时序报告、源码校验清单。

建议从 [项目 README](attention_submission/README.md)、[提交说明与优化结果](attention_submission/reports/提交说明与优化结果.md) 和 [E/G 调研报告](attention_submission/reports/E_G调研报告.md) 开始阅读。

复测日期：2026-10-12。工具：Vivado/XSim 2022.2、Icarus Verilog 13.0、Python 3。项目已完成本地功能验证和模块级综合，未进行布局布线或上板；综合后未满足 10 ns 时序目标，工具退出异常与计算完成状态分别记录。
