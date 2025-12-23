module spo2_calc
#(
    parameter DATA_WIDTH = 18
)
(
    input                       clk,
    input                       rst_n,
    
    input                       i_data_valid,
    input  signed [DATA_WIDTH-1:0] i_red_ac,    // 红光 AC
    input  [DATA_WIDTH-1:0]        i_red_dc,    // 红光 DC
    input  signed [DATA_WIDTH-1:0] i_ir_ac,     // 红外 AC
    input  [DATA_WIDTH-1:0]        i_ir_dc,     // 红外 DC
    
    input                       i_beat_pulse,   // 心跳脉冲 (作为计算触发信号)
    
    output reg [7:0]            o_spo2
);


    // 在两个心跳脉冲之间，找到 AC 信号的 Max 和 Min
    
    reg signed [DATA_WIDTH-1:0] red_max, red_min;
    reg signed [DATA_WIDTH-1:0] ir_max, ir_min;
    
    // 锁存用于计算的最终幅度
    reg [DATA_WIDTH-1:0] red_ac_amp;
    reg [DATA_WIDTH-1:0] ir_ac_amp;
    reg [DATA_WIDTH-1:0] red_dc_latch;
    reg [DATA_WIDTH-1:0] ir_dc_latch;
    
    reg calc_start; // 触发计算标志

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            red_max <= -10000; red_min <= 10000;
            ir_max  <= -10000; ir_min  <= 10000;
            calc_start <= 0;
        end else if(i_data_valid) begin
            calc_start <= 0;
            
            if(i_beat_pulse) begin
                // AC Amp = Max - Min
                red_ac_amp <= red_max - red_min;
                ir_ac_amp  <= ir_max - ir_min;
                
                // 锁存当前的 DC 值
                red_dc_latch <= i_red_dc;
                ir_dc_latch  <= i_ir_dc;
                
                // 触发后续计算
                calc_start <= 1;
                
                // 重置峰谷值，准备下一轮
                red_max <= -10000; red_min <= 10000;
                ir_max  <= -10000; ir_min  <= 10000;
            end else begin
                // 寻找极值
                if(i_red_ac > red_max) red_max <= i_red_ac;
                if(i_red_ac < red_min) red_min <= i_red_ac;
                
                if(i_ir_ac > ir_max) ir_max <= i_ir_ac;
                if(i_ir_ac < ir_min) ir_min <= i_ir_ac;
            end
        end
    end
    
    reg [2:0] state;
    localparam S_IDLE = 0, S_MULT = 1, S_DIV = 2, S_DONE = 3;
    
    reg [47:0] numerator;   // 分子 (大一点防溢出)
    reg [47:0] denominator; // 分母
    reg [15:0] r_val;       // 计算出的 R 值 (定点数，8位小数)

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state <= S_IDLE;
            o_spo2 <= 0;
        end else begin
            case(state)
                S_IDLE: begin
                    if(calc_start) begin
                        state <= S_MULT;
                    end
                end
                
                S_MULT: begin
                    // 乘法运算 
                    numerator   <= red_ac_amp * ir_dc_latch * 128; 
                    denominator <= ir_ac_amp  * red_dc_latch;
                    state <= S_DIV;
                end
                
                S_DIV: begin
                    // 除法运算 
                    if(denominator > 0)
                        r_val <= numerator / denominator;
                    else
                        r_val <= 0;
                    
                    state <= S_DONE;
                end
                
                S_DONE: begin
                    // 线性拟合 SpO2 = 110 - 25 * R
                    // 这里的 r_val 是放大了 128 倍的。
                    // 真正的 R = r_val / 128
                    // SpO2 = 110 - 25 * (r_val / 128)
                    if(r_val > 100) o_spo2 <= 85;      // R很大，含氧量低
                    else if(r_val < 40) o_spo2 <= 100; // R很小，异常
                    else begin
                        // 线性插值: SpO2 = 110 - (r_val / 4)
                        o_spo2 <= 110 - (r_val[7:0] >> 2); 
                    end
                    
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule