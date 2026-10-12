`timescale 1ns/1ps
// 独立波形记录模块，不改变被测设计或原有测试平台。
module trace_capture;
    initial begin
        $dumpfile("attention_demo.vcd");
        $dumpvars(0, tb_attention_ip.dut);
        // 前二十微秒覆盖复位测试和首个完整任务，随后停止记录以控制文件大小。
        #20000;
        $dumpoff;
    end
endmodule
