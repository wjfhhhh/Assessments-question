`timescale 1ns/1ps
`include "cases.vh"
module tb_attention_parallel;
    localparam CASES=`TEST_CASES;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, start=0, q_valid=0, kv_valid=0;
    reg signed [7:0] q_in=0, k_in=0, v_in=0;
    wire data_ready, score_valid, done;
    wire signed [17:0] score_data;
    wire [2:0] score_index;
    wire signed [17:0] x_max, delta_data;
    wire [4:0] weight_data;
    wire [2:0] weight_index;
    wire weight_valid;
    wire signed [7:0] out_data;
    wire out_valid;
    reg mask_enable = 0;
    reg [2:0] query_index = 0;
    reg enable_vectors [0:CASES-1];
    reg [2:0] position_vectors [0:CASES-1];
    attention_ip_parallel dut(.*);
    // 使用未优化的因果屏蔽版作对照，等待其较晚输出后逐项核对。
    wire signed [7:0] base_out_data;
    wire base_out_valid, base_done, base_ready;
    reg signed [7:0] captured_output [0:3];
    attention_ip_causal_mask baseline (
        .mask_enable(mask_enable),.query_index(query_index),
        .clk(clk),.rst_n(rst_n),.start(start),.q_in(q_in),.k_in(k_in),.v_in(v_in),
        .q_valid(q_valid),.kv_valid(kv_valid),.data_ready(base_ready),
        .out_data(base_out_data),.out_valid(base_out_valid),.done(base_done)
    );
    assign score_data=dut.score_data;
    assign score_index=dut.score_index;
    assign score_valid=dut.score_valid;
    assign x_max=dut.x_max;
    assign delta_data=dut.delta_data;
    assign weight_data=dut.weight_data;
    assign weight_index=dut.weight_index;
    assign weight_valid=dut.weight_valid;
    reg [7:0] expected_l [0:CASES-1];
    reg [14:0] expected_acc [0:CASES*4-1];
    reg [7:0] expected_out [0:CASES*4-1];
    reg [7:0] partial_l [0:CASES*32-1];
    reg [14:0] partial_acc [0:CASES*128-1];
    integer component, outputs_checked=0;
    reg signed [14:0] norm_numerator=0;
    reg [7:0] norm_denominator=0;
    wire signed [15:0] norm_result;
    reg norm_finished=0;
    integer den, num, abs_num, reference_magnitude, reference_result, norm_checked=0;
    round_div_signed standalone_normalize(
        .numerator(norm_numerator),.denominator(norm_denominator),.result(norm_result)
    );
    // 独立参考采用商和余数判断舍入，与被测模块加半个分母的写法不同。
    // 穷举所有合法分母，以及该分母下加权平均允许的整个分子范围。
    initial begin
        #1;
        if(norm_result !== 0) $fatal(1,"Zero denominator guard failed");
        for(den=16;den<=128;den=den+1) begin
            norm_denominator=den;
            for(num=-128*den;num<=127*den;num=num+1) begin
                norm_numerator=num;
                abs_num=(num<0)?-num:num;
                reference_magnitude=abs_num/den;
                if(2*(abs_num%den)>=den) reference_magnitude=reference_magnitude+1;
                reference_result=(num<0)?-reference_magnitude:reference_magnitude;
                #1;
                if($signed(norm_result) !== reference_result)
                    $fatal(1,"Normalize mismatch numerator=%0d denominator=%0d got=%0d expected=%0d",
                           num,den,norm_result,reference_result);
                norm_checked=norm_checked+1;
            end
        end
        norm_finished=1;
    end
    reg [17:0] expected_max [0:CASES-1];
    reg [17:0] expected_delta [0:CASES*8-1];
    reg [4:0] expected_weight [0:CASES*8-1];
    reg [4:0] expected_lut [0:130560];
    reg signed [17:0] lut_delta=0;
    wire [4:0] lut_result;
    reg lut_finished=0;
    integer lut_i;
    exp_lut standalone_lut(.delta(lut_delta), .weight_raw(lut_result));
    // 穷举整个保守差值范围，与经过数学指数交叉验证的参考模型逐点比较。
    initial begin
        $readmemh("lut.hex",expected_lut);
        // 先留出时间让组合过程进入等待，再改变输入，避免仿真器的零时刻调度差异。
        lut_delta = -1;
        #1;
        for(lut_i=0;lut_i<=130560;lut_i=lut_i+1) begin
            lut_delta=-lut_i;
            #1;
            if(lut_result !== expected_lut[lut_i])
                $fatal(1,"LUT mismatch delta=%0d",lut_delta);
        end
        lut_finished=1;
    end
    reg [7:0] q_vectors [0:CASES*4-1];
    reg [7:0] k_vectors [0:CASES*32-1];
    reg [7:0] v_vectors [0:CASES*32-1];
    reg [17:0] expected [0:CASES*8-1];
    integer c, n, tick, checked=0, weights_checked=0;
    integer running_max;

    task reset_dut;
        begin
            @(negedge clk);
            rst_n=0; start=0; q_valid=0; kv_valid=0;
            #1;
            if (data_ready !== 0 || score_valid !== 0 || weight_valid !== 0 || out_valid !== 0 || done !== 0)
                $fatal(1,"Reset did not clear control outputs");
            repeat(2) @(negedge clk);
            rst_n=1;
        end
    endtask

    task launch;
        begin
            @(negedge clk);
            mask_enable=enable_vectors[c]; query_index=position_vectors[c]; start=1;
            @(posedge clk); #1;
            if (data_ready !== 1) $fatal(1,"Not ready after start");
            @(negedge clk); start=0;
            // 故意改变外部配置，检验模块确实使用启动时锁存的值。
            mask_enable=~enable_vectors[c]; query_index=~position_vectors[c];
        end
    endtask

    task load_inputs(input integer case_id, input integer stalls);
        integer a,b;
        begin
            for(a=0;a<4;a=a+1) begin
                for(b=0;b<((a+case_id)%3)*stalls;b=b+1) begin
                    @(negedge clk); q_valid=0; kv_valid=1; q_in=99;
                    @(posedge clk); #1;
                    if(score_valid || weight_valid || out_valid || done) $fatal(1,"Output during Q stall");
                end
                @(negedge clk);
                q_valid=1; kv_valid=0; q_in=q_vectors[case_id*4+a];
                start=(a==1); // 故意在忙碌时启动，检查模块是否忽略该请求。
                if(data_ready !== 1) $fatal(1,"Q not ready");
                @(posedge clk); #1;
                if(score_valid || weight_valid || out_valid || done) $fatal(1,"Premature Q output");
            end
            @(negedge clk); q_valid=0; start=0;
            for(a=0;a<32;a=a+1) begin
                for(b=0;b<((a+case_id)%3)*stalls;b=b+1) begin
                    @(negedge clk); kv_valid=0; q_valid=1; k_in=99; v_in=-99;
                    @(posedge clk); #1;
                    if(score_valid || weight_valid || out_valid || done) $fatal(1,"Output during KV stall");
                end
                @(negedge clk);
                q_valid=0; kv_valid=1;
                k_in=k_vectors[case_id*32+a]; v_in=v_vectors[case_id*32+a];
                start=(a==7);
                if(data_ready !== 1) $fatal(1,"KV not ready");
                @(posedge clk); #1;
                if(score_valid || weight_valid || out_valid || done) $fatal(1,"Premature KV output");
            end
            for(a=0;a<4;a=a+1)
                if(dut.q_mem[a] !== q_vectors[case_id*4+a]) $fatal(1,"Q storage mismatch");
            for(a=0;a<32;a=a+1) begin
                if(dut.k_mem[a] !== k_vectors[case_id*32+a]) $fatal(1,"K storage mismatch");
                if(dut.v_mem[a] !== v_vectors[case_id*32+a]) $fatal(1,"V storage mismatch");
            end
            @(negedge clk); q_valid=0; kv_valid=0; start=0;
        end
    endtask

    initial begin
        // 设置总超时，避免状态异常或结束信号缺失导致仿真一直运行。
        #30000000; $fatal(1,"Global simulation timeout");
    end

    initial begin
        $readmemh("enable.hex",enable_vectors);
        $readmemh("position.hex",position_vectors);
        c=0;
        $readmemh("q.hex",q_vectors);
        $readmemh("k.hex",k_vectors);
        $readmemh("v.hex",v_vectors);
        $readmemh("score.hex",expected);
        $readmemh("xmax.hex",expected_max);
        $readmemh("delta.hex",expected_delta);
        $readmemh("weight.hex",expected_weight);
        $readmemh("l.hex",expected_l);
        $readmemh("acc.hex",expected_acc);
        $readmemh("out.hex",expected_out);
        $readmemh("partial_l.hex",partial_l);
        $readmemh("partial_acc.hex",partial_acc);
        reset_dut();
        // 在查询向量装载期间复位，检查任务能否被中断。
        launch();
        @(negedge clk); q_valid=1; q_in=42;
        @(posedge clk); #1;
        reset_dut();
        // 在键和值向量装载期间复位，检查任务能否被中断。
        launch();
        repeat(4) begin
            @(negedge clk); q_valid=1; q_in=1;
            @(posedge clk); #1;
        end
        @(negedge clk); q_valid=0; kv_valid=1; k_in=42; v_in=-42;
        @(posedge clk); #1;
        reset_dut();
        // 点积已经累加了部分乘积时复位，检查旧累加值是否被清除。
        launch(); load_inputs(0,0);
        repeat(2) @(posedge clk);
        reset_dut();

        // 已经得到多个前缀最大值时复位，检查下一任务不会沿用旧最大值。
        launch(); load_inputs(0,0);
        repeat(18) @(posedge clk);
        reset_dut();
        // 已经输出部分权重时复位，检查有效信号和剩余任务被清除。
        launch(); load_inputs(0,0);
        repeat(34) @(posedge clk);
        reset_dut();

        // 分别在累加、归一化和输出中途复位，随后重新装载任务。
        launch(); load_inputs(0,0); repeat(44) @(posedge clk); reset_dut();
        launch(); load_inputs(0,0); repeat(50) @(posedge clk); reset_dut();
        launch(); load_inputs(0,0); repeat(54) @(posedge clk); reset_dut();

        for(c=0;c<CASES;c=c+1) begin
            launch();
            load_inputs(c,c%2);
            n=0;
            for(tick=1;tick<=57;tick=tick+1) begin
                // 计算期间故意改变输入并发出启动请求，检查模块是否忽略它们。
                start=(tick==2 || tick==18 || tick==35 || tick==44 || tick==50 || tick==54); q_valid=1; kv_valid=1; q_in=99; k_in=99; v_in=99;
                @(posedge clk); #1;
                if(dut.mask_enable_reg !== enable_vectors[c] || dut.query_index_reg !== position_vectors[c])
                    $fatal(1,"Latched mask configuration changed case=%0d",c);
                if(data_ready !== 0) $fatal(1,"Ready asserted while computing");
                if(tick<=32 && tick%4==0) begin
                    if(score_valid !== 1 || score_index !== n[2:0])
                        $fatal(1,"Score timing/index mismatch case=%0d tick=%0d",c,tick);
                    if(score_data !== expected[c*8+n])
                        $fatal(1,"Score mismatch case=%0d index=%0d got=%0d expected=%0d",
                               c,n,score_data,$signed(expected[c*8+n]));
                    if(dut.score_mem[n] !== expected[c*8+n]) $fatal(1,"Score buffer mismatch");
                    if(c==0) $display("DEMO score[%0d] = %0d",n,score_data);
                    // 从独立参考分数求合法前缀最大值，逐次检查点积完成当拍的更新。
                    if (n == 0) running_max = $signed(expected[c*8+n]);
                    else if ((!enable_vectors[c] || n <= position_vectors[c]) &&
                             $signed(expected[c*8+n]) > running_max)
                        running_max = $signed(expected[c*8+n]);
                    n=n+1; checked=checked+1;
                end else if(score_valid !== 0) $fatal(1,"Unexpected score_valid");
                if (tick>=4 && $signed(x_max) !== running_max)
                    $fatal(1,"Running maximum mismatch case=%0d tick=%0d got=%0d expected=%0d",c,tick,x_max,running_max);
                if(tick>=32 && x_max !== expected_max[c])
                    $fatal(1,"Maximum mismatch case=%0d got=%0d expected=%0d",c,x_max,$signed(expected_max[c]));
                if(tick>=33 && tick<=40) begin
                    if(weight_valid !== 1 || weight_index !== (tick-33))
                        $fatal(1,"Weight timing/index mismatch case=%0d tick=%0d",c,tick);
                    if(delta_data !== expected_delta[c*8+tick-33] || delta_data > 0)
                        $fatal(1,"Delta mismatch case=%0d index=%0d",c,tick-33);
                    if(dut.weight_masked !== (enable_vectors[c] && (tick-33)>position_vectors[c]))
                        $fatal(1,"Mask flag mismatch case=%0d",c);
                    if(weight_data !== expected_weight[c*8+tick-33])
                        $fatal(1,"Weight mismatch case=%0d index=%0d got=%0d",c,tick-33,weight_data);
                    if(dut.weight_mem[tick-33] !== expected_weight[c*8+tick-33])
                        $fatal(1,"Weight storage mismatch");
                    if(c==0) $display("DEMO weight[%0d]: delta=%0d raw=%0d",tick-33,delta_data,weight_data);
                    weights_checked=weights_checked+1;
                end else if(weight_valid !== 0) $fatal(1,"Unexpected weight_valid");
                if(tick>=41 && tick<=48) begin
                    if(dut.l_raw !== partial_l[c*32+(tick-41)*4+3])
                        $fatal(1,"Partial L mismatch case=%0d tick=%0d",c,tick);
                    for(component=0;component<4;component=component+1)
                        if(dut.acc_raw[component] !== partial_acc[c*128+((tick-41)*4+3)*4+component])
                            $fatal(1,"Partial ACC mismatch case=%0d tick=%0d component=%0d",c,tick,component);
                end
                if(tick>=48) begin
                    if(dut.l_raw !== expected_l[c] || dut.l_raw==0)
                        $fatal(1,"Final L mismatch case=%0d",c);
                    for(component=0;component<4;component=component+1)
                        if(dut.acc_raw[component] !== expected_acc[c*4+component])
                            $fatal(1,"Final ACC mismatch case=%0d component=%0d",c,component);
                end
                if(c==0 && tick==48)
                    $display("DEMO L_raw=%0d ACC_raw=[%0d,%0d,%0d,%0d]",dut.l_raw,
                             dut.acc_raw[0],dut.acc_raw[1],dut.acc_raw[2],dut.acc_raw[3]);
                if(tick>=53 && tick<=56) begin
                    if(out_valid !== 1 || out_data !== expected_out[c*4+tick-53])
                        $fatal(1,"Output mismatch case=%0d component=%0d got=%0d expected=%0d",c,tick-53,
                               out_data,$signed(expected_out[c*4+tick-53]));
                    if(c==0) $display("DEMO output[%0d]=%0d",tick-53,out_data);
                    captured_output[tick-53]=out_data;
                    outputs_checked=outputs_checked+1;
                end else if(out_valid !== 0) $fatal(1,"Unexpected out_valid");
                if(done !== (tick==57)) $fatal(1,"Incorrect done timing");
                @(negedge clk);
            end
            start=0; q_valid=0; kv_valid=0;
            // 原版第八十五至八十八拍才输出；优化版已提前三十二拍完成。
            // 快速重启模式不等待较慢的对照模块，验证缩短后的任务可以连续开始。
            if (!$test$plusargs("FAST_RESTART")) for(tick=58;tick<=89;tick=tick+1) begin
                @(posedge clk); #1;
                if(out_valid !== 0 || done !== 0) $fatal(1,"Optimized outputs not idle");
                if(tick>=85 && tick<=88) begin
                    if(base_out_valid !== 1 || base_out_data !== captured_output[tick-85])
                        $fatal(1,"A/B output equivalence failed case=%0d component=%0d",c,tick-85);
                end else if(base_out_valid !== 0) $fatal(1,"Reference output timing failed");
                if(base_done !== (tick==89)) $fatal(1,"Reference done timing failed");
                @(negedge clk);
            end
            // 完整任务之间不复位；等待对照模块结束后启动下一组。
        end
        repeat(3) begin
            @(posedge clk); #1;
            if(done !== 0 || score_valid !== 0 || weight_valid !== 0 || out_valid !== 0 || data_ready !== 0)
                $fatal(1,"Outputs not idle after completion");
        end
        wait(lut_finished && norm_finished);
        $display("PASS: %0d cases, %0d scores, %0d weights, %0d outputs, %0d division inputs",CASES,checked,weights_checked,outputs_checked,norm_checked);
        if ($test$plusargs("FAST_RESTART"))
            $display("FAST_RESTART: completed without waiting for the serial reference");
        else
            $display("CYCLES: A=89 B=57 after final KV; savings=32; A/B results matched for all cases");
        $finish;
    end
endmodule
