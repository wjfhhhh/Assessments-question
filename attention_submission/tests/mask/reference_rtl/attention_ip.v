`timescale 1ns/1ps
// 基础注意力计算模块：依次完成装载、点积、最大值、指数、累加、归一化和输出。
module attention_ip (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire signed [7:0] q_in, k_in, v_in,
    input wire q_valid, kv_valid,
    output wire data_ready,
    output reg signed [7:0] out_data,
    output reg out_valid,
    output reg done
);
    // 下列中间信号供仿真观察，不增加题目规定的外部接口。
    reg signed [17:0] score_data;
    reg [2:0] score_index;
    reg score_valid;
    reg signed [17:0] x_max, delta_data;
    reg [4:0] weight_data;
    reg [2:0] weight_index;
    reg weight_valid;
    // 状态编码按处理流程排列，便于阅读代码和观察波形。
    localparam IDLE    = 4'd0,
               LOAD_Q  = 4'd1,
               LOAD_KV = 4'd2,
               DOT     = 4'd3,
               MAX     = 4'd4,
               EXP     = 4'd5,
               UPDATE  = 4'd6,
               NORM    = 4'd7,
               OUTPUT  = 4'd8,
               FINISH  = 4'd9;
    reg [3:0] state;
    reg [1:0] elem_index;
    reg [2:0] token_index;
    reg signed [7:0] q_mem [0:3];
    reg signed [7:0] k_mem [0:31];
    reg signed [7:0] v_mem [0:31];
    reg signed [17:0] score_mem [0:7];
    reg [4:0] weight_mem [0:7];
    reg signed [17:0] acc;
    reg [7:0] l_raw;
    reg signed [14:0] acc_raw [0:3];
    reg signed [7:0] output_mem [0:3];
    integer reset_index;
    wire [4:0] address = {token_index, elem_index};
    wire signed [15:0] product = q_mem[elem_index] * k_mem[address];
    wire signed [17:0] product_ext = {{2{product[15]}}, product};
    wire signed [17:0] sum_next = acc + product_ext;
    // 先完成最大值扫描，再用十八位有符号数做差，防止负数被当成无符号数。
    wire signed [17:0] delta = score_mem[token_index] - x_max;
    wire [4:0] lut_weight;
    exp_lut u_exp_lut (.delta(delta), .weight_raw(lut_weight));
    // 权重本来无符号，先补零转成正的有符号数，再与有符号的值元素相乘。
    wire signed [13:0] weighted_product = $signed({1'b0, weight_mem[token_index]}) * v_mem[address];
    wire signed [14:0] weighted_product_ext = {weighted_product[13], weighted_product};
    wire signed [15:0] normalized;
    round_div_signed u_normalize (
        .numerator(acc_raw[elem_index]), .denominator(l_raw), .result(normalized)
    );
    assign data_ready = rst_n && ((state == LOAD_Q) || (state == LOAD_KV));

    // 输入存储在读取前会完整重写，分数也逐项覆盖，因此无需复位清零数组。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            elem_index <= 0;
            token_index <= 0;
            acc <= 0;
            score_data <= 0;
            score_index <= 0;
            score_valid <= 0;
            done <= 0;
            x_max <= 0;
            delta_data <= 0;
            weight_data <= 0;
            weight_index <= 0;
            weight_valid <= 0;
            out_valid <= 0;
            out_data <= 0;
            l_raw <= 0;
            for (reset_index=0; reset_index<4; reset_index=reset_index+1) begin
                acc_raw[reset_index] <= 0;
                output_mem[reset_index] <= 0;
            end
        end else begin
            score_valid <= 0;
            done <= 0;
            weight_valid <= 0;
            out_valid <= 0;
            case (state)
                IDLE: if (start) begin
                    // 每个任务都要清空分母和四路累加器，不依赖任务之间再次复位。
                    l_raw <= 0;
                    for (reset_index=0; reset_index<4; reset_index=reset_index+1)
                        acc_raw[reset_index] <= 0;
                    elem_index <= 0;
                    token_index <= 0;
                    acc <= 0;
                    state <= LOAD_Q;
                end
                LOAD_Q: if (q_valid && data_ready) begin
                    q_mem[elem_index] <= q_in;
                    if (elem_index == 3) begin
                        elem_index <= 0;
                        state <= LOAD_KV;
                    end else elem_index <= elem_index + 1'b1;
                end
                LOAD_KV: if (kv_valid && data_ready) begin
                    k_mem[address] <= k_in;
                    v_mem[address] <= v_in;
                    if (elem_index == 3) begin
                        elem_index <= 0;
                        if (token_index == 7) begin
                            token_index <= 0;
                            acc <= 0;
                            state <= DOT;
                        end else token_index <= token_index + 1'b1;
                    end else elem_index <= elem_index + 1'b1;
                end
                DOT: begin
                    if (elem_index == 3) begin
                        // 保存包含本拍乘积的总和；只保存旧累加器会漏掉第四项。
                        score_mem[token_index] <= sum_next;
                        score_data <= sum_next;
                        score_index <= token_index;
                        score_valid <= 1;
                        elem_index <= 0;
                        acc <= 0;
                        if (token_index == 7) begin
                            token_index <= 0;
                            state <= MAX;
                        end
                        else token_index <= token_index + 1'b1;
                    end else begin
                        acc <= sum_next;
                        elem_index <= elem_index + 1'b1;
                    end
                end
                MAX: begin
                    // 第一项直接作为最大值初值，确保全负数输入也能正确处理。
                    if (token_index == 0 || score_mem[token_index] > x_max)
                        x_max <= score_mem[token_index];
                    if (token_index == 7) begin
                        token_index <= 0;
                        state <= EXP;
                    end else token_index <= token_index + 1'b1;
                end
                EXP: begin
                    // 此时最大值已完成更新，每拍计算并保存一个权重原始整数。
                    weight_mem[token_index] <= lut_weight;
                    weight_data <= lut_weight;
                    weight_index <= token_index;
                    delta_data <= delta;
                    weight_valid <= 1;
                    if (token_index == 7) begin
                        token_index <= 0;
                        elem_index <= 0;
                        state <= UPDATE;
                    end
                    else token_index <= token_index + 1'b1;
                end
                UPDATE: begin
                    // 每组权重只计入分母一次；四个分量分别更新各自的加权累加器。
                    if (elem_index == 0)
                        l_raw <= l_raw + {3'd0, weight_mem[token_index]};
                    acc_raw[elem_index] <= acc_raw[elem_index] + weighted_product_ext;
                    if (elem_index == 3) begin
                        elem_index <= 0;
                        if (token_index == 7) state <= NORM;
                        else token_index <= token_index + 1'b1;
                    end else elem_index <= elem_index + 1'b1;
                end
                NORM: begin
                    // 分子和分母都有十六倍比例，相除时抵消，不再额外右移四位。
                    // 非负权重形成的加权平均不超出输入范围，因此结果可保存为八位。
                    output_mem[elem_index] <= normalized[7:0];
                    if (elem_index == 3) begin
                        elem_index <= 0;
                        state <= OUTPUT;
                    end else elem_index <= elem_index + 1'b1;
                end
                OUTPUT: begin
                    out_data <= output_mem[elem_index];
                    out_valid <= 1;
                    if (elem_index == 3) state <= FINISH;
                    else elem_index <= elem_index + 1'b1;
                end
                FINISH: begin
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
