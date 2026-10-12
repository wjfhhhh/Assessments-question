`timescale 1ns/1ps
// 有符号整数除法：取最近整数，恰好半整数时向远离零的方向舍入。
// 使用组合除法实现基础版本；综合后的资源和时序代价需要另行评估。
module round_div_signed (
    input wire signed [14:0] numerator,
    input wire [7:0] denominator,
    output wire signed [15:0] result
);
    // 先扩展再取绝对值，确保最小负数负一万六千三百八十四也能正确处理。
    wire signed [15:0] numerator_ext = {numerator[14], numerator};
    wire [15:0] magnitude = numerator_ext[15] ? -numerator_ext : numerator_ext;
    wire [15:0] half_denominator = {8'd0, denominator} >> 1;
    wire [15:0] adjusted = magnitude + half_denominator;
    // 分母为零时防御性输出零；完整模块通过至少一个权重为十六保证分母非零。
    wire [15:0] quotient = (denominator != 0) ? adjusted / {8'd0, denominator} : 16'd0;
    assign result = numerator_ext[15] ? -$signed(quotient) : $signed(quotient);
endmodule
