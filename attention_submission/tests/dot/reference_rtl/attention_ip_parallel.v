`timescale 1ns/1ps
// 注意力优化模块：点积同步找最大值，随后完成指数、并行累加、归一化和输出。
module attention_ip_parallel (
    input wire clk,
    input wire rst_n,
    input wire start,
    // 启动时锁存配置：开启屏蔽后，只允许下标不大于查询位置的键参与计算。
    input wire mask_enable,
    input wire [2:0] query_index,
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
               EXP     = 4'd4,
               UPDATE  = 4'd5,
               NORM    = 4'd6,
               OUTPUT  = 4'd7,
               FINISH  = 4'd8;
    reg [3:0] state;
    reg mask_enable_reg;
    reg [2:0] query_index_reg;
    reg weight_masked;
    // 索引从零开始，查询位置零到七均合法，因此第零个键始终可用。
    reg [1:0] elem_index;
    reg [2:0] token_index;
    wire key_allowed = !mask_enable_reg || (token_index <= query_index_reg);
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
    // 点积结束时已得到合法最大值，再用十八位有符号数做差。
    wire signed [17:0] delta = key_allowed ? (score_mem[token_index] - x_max) : 18'sd0;
    // 被屏蔽位置的差值用零作波形占位，权重直接清零，不把正差值送入指数表。
    wire [4:0] lut_weight;
    wire [4:0] masked_weight = key_allowed ? lut_weight : 5'd0;
    exp_lut u_exp_lut (.delta(delta), .weight_raw(lut_weight));
    // 权重本来无符号，先补零转成正的有符号数，再与有符号的值元素相乘。
    // 四个组合乘法器同时读取同一组的四个分量，以资源换取更少周期。
    wire signed [13:0] weighted_product [0:3];
    wire signed [14:0] weighted_product_ext [0:3];
    genvar lane;
    generate
        for (lane=0; lane<4; lane=lane+1) begin: parallel_lanes
            assign weighted_product[lane] = $signed({1'b0, weight_mem[token_index]}) * v_mem[token_index*4+lane];
            assign weighted_product_ext[lane] = {weighted_product[lane][13], weighted_product[lane]};
        end
    endgenerate
    integer update_lane;
    wire signed [15:0] normalized;
    round_div_signed u_normalize (
        .numerator(acc_raw[elem_index]), .denominator(l_raw), .result(normalized)
    );
    assign data_ready = rst_n && ((state == LOAD_Q) || (state == LOAD_KV));

    // 输入存储在读取前会完整重写，分数也逐项覆盖，因此无需复位清零数组。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            mask_enable_reg <= 0;
            query_index_reg <= 0;
            weight_masked <= 0;
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
                    // 配置只在任务开始时采样，计算途中改变外部配置不影响本次任务。
                    mask_enable_reg <= mask_enable;
                    query_index_reg <= query_index;
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
                        // 第零个键始终合法，直接覆盖旧最大值，兼容全负分数和连续任务。
                        // 必须比较完整点积，不能用少了最后一次乘积的旧累加寄存器。
                        if (key_allowed && (token_index == 0 || sum_next > x_max))
                            x_max <= sum_next;
                        score_mem[token_index] <= sum_next;
                        score_data <= sum_next;
                        score_index <= token_index;
                        score_valid <= 1;
                        elem_index <= 0;
                        acc <= 0;
                        if (token_index == 7) begin
                            token_index <= 0;
                            state <= EXP;
                        end
                        else token_index <= token_index + 1'b1;
                    end else begin
                        acc <= sum_next;
                        elem_index <= elem_index + 1'b1;
                    end
                end
                EXP: begin
                    // 此时最大值已完成更新，每拍计算并保存一个权重原始整数。
                    weight_mem[token_index] <= masked_weight;
                    weight_data <= masked_weight;
                    weight_masked <= !key_allowed;
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
                    // 每拍处理一整个键值向量；分母每组只加一次，四路分子同时更新。
                    l_raw <= l_raw + {3'd0, weight_mem[token_index]};
                    for (update_lane=0; update_lane<4; update_lane=update_lane+1)
                        acc_raw[update_lane] <= acc_raw[update_lane] + weighted_product_ext[update_lane];
                    // 常量界限的循环展开为四路硬件，不会逐次消耗四个时钟周期。
                    if (token_index == 7) begin
                        elem_index <= 0;
                        state <= NORM;
                    end else token_index <= token_index + 1'b1;
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
