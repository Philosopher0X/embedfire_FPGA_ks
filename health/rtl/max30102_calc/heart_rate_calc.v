module heart_rate_calc
#(
    parameter DATA_WIDTH = 18,
    parameter P_SYS_CLK  = 50_000_000 
)
(
    input                       clk,
    input                       rst_n,
    
    input                       i_data_valid,
    input  signed [DATA_WIDTH-1:0] i_ac_data,
    
    output reg                  o_beat_pulse,   // 心跳脉冲
    output reg [7:0]            o_bpm           // 最终心率值
);

    // 如果上板发现LED不闪，调整这个阈值
    localparam signed [DATA_WIDTH-1:0] THRESHOLD_HIGH = 100;
    localparam signed [DATA_WIDTH-1:0] THRESHOLD_LOW  = -100;

    reg state_hyst; // 0: 找峰, 1: 找谷
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state_hyst <= 0;
            o_beat_pulse <= 0;
        end else if(i_data_valid) begin
            o_beat_pulse <= 0; 
            case(state_hyst)
                0: begin
                    if(i_ac_data > THRESHOLD_HIGH) begin
                        state_hyst <= 1;
                        o_beat_pulse <= 1; // 产生脉冲
                    end
                end
                1: begin
                    if(i_ac_data < THRESHOLD_LOW) begin
                        state_hyst <= 0;
                    end
                end
            endcase
        end
    end

    // 毫秒定时器
    reg [19:0] cnt_1ms;
    wire       tick_1ms;
    
    // 生成 1ms 脉冲
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) cnt_1ms <= 0;
        else if(cnt_1ms >= P_SYS_CLK / 1000 - 1) cnt_1ms <= 0;
        else cnt_1ms <= cnt_1ms + 1'b1;
    end
    assign tick_1ms = (cnt_1ms == P_SYS_CLK / 1000 - 1);

    // 测量脉冲间隔
    reg [15:0] period_ms_cnt; // 当前累计的毫秒数
    reg [15:0] period_captured; // 捕获到的有效周期
    reg        period_valid;    // 捕获有效标志

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            period_ms_cnt <= 0;
            period_captured <= 0;
            period_valid <= 0;
        end else begin
            period_valid <= 0; // 默认脉冲
            
            if(o_beat_pulse) begin
                // 当检测到心跳时
                // 简单的过滤：人类心跳间隔通常在 300ms(200bpm) 到 2000ms(30bpm) 之间
                if(period_ms_cnt > 300 && period_ms_cnt < 2000) begin
                    period_captured <= period_ms_cnt;
                    period_valid <= 1; // 触发除法器
                end
                period_ms_cnt <= 0; // 清零重新计数
            end 
            else if(tick_1ms) begin
                // 如果没有心跳，就一直计时，直到溢出（防止手指拿开后计数器无限增加）
                if(period_ms_cnt < 2500)
                    period_ms_cnt <= period_ms_cnt + 1'b1;
            end
        end
    end

    // 除法器状态机 (计算 BPM = 60000 / Period)
    reg [2:0]  div_state;
    reg [16:0] dividend; // 被除数 (60000)
    reg [7:0]  bpm_raw;  // 计算出的原始 BPM

    localparam S_IDLE = 0, S_CALC = 1, S_DONE = 2;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            div_state <= S_IDLE;
            bpm_raw <= 0;
            dividend <= 0;
        end else begin
            case(div_state)
                S_IDLE: begin
                    if(period_valid) begin
                        dividend <= 17'd60000;
                        bpm_raw <= 0;
                        div_state <= S_CALC;
                    end
                end
                
                S_CALC: begin
                    // 迭代减法
                    if(dividend >= period_captured) begin
                        dividend <= dividend - period_captured;
                        bpm_raw <= bpm_raw + 1'b1;
                    end else begin
                        // 余数不够减了，计算完成
                        div_state <= S_DONE;
                    end
                end
                
                S_DONE: begin
                    div_state <= S_IDLE;
                end
                default: div_state <= S_IDLE;
            endcase
        end
    end

    reg [7:0] bpm_buf [0:3];
    wire [9:0] bpm_sum;
    
    assign bpm_sum = bpm_buf[0] + bpm_buf[1] + bpm_buf[2] + bpm_buf[3];

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            bpm_buf[0] <= 0; bpm_buf[1] <= 0; bpm_buf[2] <= 0; bpm_buf[3] <= 0;
            o_bpm <= 0;
        end else if(div_state == S_DONE) begin
            // 移位寄存器更新
            bpm_buf[3] <= bpm_buf[2];
            bpm_buf[2] <= bpm_buf[1];
            bpm_buf[1] <= bpm_buf[0];
            bpm_buf[0] <= bpm_raw;
            
            // 输出平均值
            o_bpm <= bpm_sum[9:2]; // 除以4
        end
    end

endmodule