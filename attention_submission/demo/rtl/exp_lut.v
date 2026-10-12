`timescale 1ns/1ps
// 指数查找表：输入为整数差值，输出为实际权重乘以十六后的无符号整数。
// 按最近值量化：零对应十六，负一对应六，负二对应二，负三对应一。
// 合法输入不大于零；小于等于负四时量化为零。正输入不属于模块使用约定。
module exp_lut (
    input wire signed [17:0] delta,
    output reg [4:0] weight_raw
);
    always @* begin
        case (delta)
             18'sd0: weight_raw = 5'd16;
            -18'sd1: weight_raw = 5'd6;
            -18'sd2: weight_raw = 5'd2;
            -18'sd3: weight_raw = 5'd1;
            default: weight_raw = 5'd0;
        endcase
    end
endmodule
