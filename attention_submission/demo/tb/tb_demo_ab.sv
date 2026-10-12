`timescale 1ns/1ps
// 答辩专用激励：只读取输入、驱动接口、记录实际结果，不读取或计算预期答案。
module tb_demo_ab;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, start = 0, q_valid = 0, kv_valid = 0;
    reg signed [7:0] q_in = 0, k_in = 0, v_in = 0;
    wire data_ready, out_valid, done;
    wire signed [7:0] out_data;
    reg mask_enable = 0;
    reg [2:0] query_index = 0;
    reg [7:0] control_input [0:1];
    wire weight_masked = dut.weight_masked;
    wire mask_enable_latched = dut.mask_enable_reg;
    wire [2:0] query_index_latched = dut.query_index_reg;
    attention_ip_parallel dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .mask_enable(mask_enable), .query_index(query_index),
        .q_in(q_in), .k_in(k_in), .v_in(v_in),
        .q_valid(q_valid), .kv_valid(kv_valid), .data_ready(data_ready),
        .out_data(out_data), .out_valid(out_valid), .done(done)
    );

    reg [7:0] q_input [0:3];
    reg [7:0] k_input [0:31];
    reg [7:0] v_input [0:31];
    integer i, output_count = 0;
    time start_time, final_kv_time;
    // 打印接受启动及最后输入到完成的真实时间间隔，十纳秒为一个仿真时钟周期。
    // 下列信号仅把内部结果引到顶层，方便添加波形；没有重新实现计算。
    wire [3:0] state = dut.state;
    wire [2:0] token_index = dut.token_index;
    wire [1:0] elem_index = dut.elem_index;
    wire score_valid = dut.score_valid;
    wire [2:0] score_index = dut.score_index;
    wire signed [17:0] score_data = dut.score_data;
    wire signed [17:0] x_max = dut.x_max;
    wire signed [17:0] delta_data = dut.delta_data;
    wire weight_valid = dut.weight_valid;
    wire [2:0] weight_index = dut.weight_index;
    wire [4:0] weight_raw = dut.weight_data;
    wire [7:0] l_raw = dut.l_raw;
    wire signed [14:0] acc0_raw = dut.acc_raw[0];
    wire signed [14:0] acc1_raw = dut.acc_raw[1];
    wire signed [14:0] acc2_raw = dut.acc_raw[2];
    wire signed [14:0] acc3_raw = dut.acc_raw[3];
    reg signed [7:0] result0 = 0, result1 = 0, result2 = 0, result3 = 0;
    reg [63:0] state_name;
    // 直接使用计算模块的状态常量，避免修改编码后字符名称与实际状态不一致。
    always @* begin
        case (state)
            dut.IDLE: state_name = "IDLE";
            dut.LOAD_Q: state_name = "LOAD_Q";
            dut.LOAD_KV: state_name = "LOAD_KV";
            dut.DOT: state_name = "DOT";
            dut.EXP: state_name = "EXP";
            dut.UPDATE: state_name = "UPDATE";
            dut.NORM: state_name = "NORM";
            dut.OUTPUT: state_name = "OUTPUT";
            dut.FINISH: state_name = "FINISH";
            default: state_name = "UNKNOWN";
        endcase
    end

    initial begin
        $display("VERSION: ab");
        // 三个文件均为输入；由工程脚本从输入目录复制到仿真工作目录。
        $readmemh("ab_control.hex", control_input);
        mask_enable = control_input[0][0];
        query_index = control_input[1][2:0];
        $display("MASK enable=%0d query_index=%0d", mask_enable, query_index);
        $readmemh("ab_q.hex", q_input);
        $readmemh("ab_k.hex", k_input);
        $readmemh("ab_v.hex", v_input);
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk); start = 1;
        start_time = $time + 5;
        @(negedge clk); start = 0;
        // 在下降沿准备数据，上升沿由计算模块接收，避免仿真竞争。
        for (i = 0; i < 4; i = i + 1) begin
            q_in = q_input[i]; q_valid = 1;
            @(posedge clk);
            while (!data_ready) @(posedge clk);
            @(negedge clk);
        end
        q_valid = 0;
        for (i = 0; i < 32; i = i + 1) begin
            k_in = k_input[i]; v_in = v_input[i]; kv_valid = 1;
            @(posedge clk);
            while (!data_ready) @(posedge clk);
            @(negedge clk);
        end
        final_kv_time = $time - 5;
        kv_valid = 0;
        wait (done === 1'b1);
        $display("CYCLES: start_to_done=%0d final_kv_to_done=%0d", ($time-start_time)/10, ($time-final_kv_time)/10);
        repeat (3) @(negedge clk);
        $display("ACTUAL RESULT = [%0d, %0d, %0d, %0d]", result0, result1, result2, result3);
        $display("DEMO FINISHED: actual RTL values only; no expected-answer comparison.");
        $finish;
    end

    // 延后一纳秒观察非阻塞赋值更新后的真实输出。
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if (score_valid)
                $display("SCORE[%0d] = %0d RUNNING_MAX = %0d", score_index, score_data, x_max);
            if (weight_valid)
                $display("WEIGHT[%0d]: x_max=%0d delta=%0d raw=%0d masked=%0d", weight_index, x_max, delta_data, weight_raw, weight_masked);
            if (out_valid) begin
                case (output_count)
                    0: result0 = out_data;
                    1: result1 = out_data;
                    2: result2 = out_data;
                    3: result3 = out_data;
                endcase
                $display("OUTPUT[%0d] = %0d", output_count, out_data);
                output_count = output_count + 1;
            end
            if (done)
                $display("L_raw=%0d ACC_raw=[%0d,%0d,%0d,%0d]", l_raw, acc0_raw, acc1_raw, acc2_raw, acc3_raw);
        end
    end

    // 超时只用于防止演示挂住，不检查数学答案。
    initial begin
        #10000;
        $fatal(1, "DEMO TIMEOUT: inspect input handshake and state.");
    end
endmodule
