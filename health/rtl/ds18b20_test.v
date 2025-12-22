// DS18B20温度传感器驱动模块
module ds18b20_ctrl(
    input  wire        sys_clk,
    input  wire        sys_rst_n,
    inout  wire        dht11_data,
    
    output reg  [7:0]  temp_int,
    output reg  [7:0]  temp_deci,
    output reg  [15:0] temp_raw_debug  // 调试：原始温度数据
);

// 状态机定义
localparam IDLE        = 4'd0;
localparam INIT_START  = 4'd1;   // 初始化：拉低500us
localparam INIT_WAIT   = 4'd2;   // 等待60us
localparam INIT_CHECK  = 4'd3;   // 检测存在脉冲
localparam INIT_END    = 4'd4;   // 等待初始化结束
localparam WRITE_BYTE  = 4'd5;   // 写字节
localparam WAIT_CONV   = 4'd6;   // 等待温度转换750ms
localparam READ_BYTE   = 4'd7;   // 读字节
localparam DONE        = 4'd8;

// 命令
localparam CMD_SKIP_ROM  = 8'hCC;
localparam CMD_CONVERT   = 8'h44;
localparam CMD_READ_SPAD = 8'hBE;

// 1us时钟
reg [4:0]  clk_cnt;
reg        clk_1us;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        clk_cnt <= 5'd0;
        clk_1us <= 1'b0;
    end
    else if (clk_cnt == 5'd24) begin
        clk_cnt <= 5'd0;
        clk_1us <= ~clk_1us;
    end
    else
        clk_cnt <= clk_cnt + 1'b1;
end

// 信号
reg [3:0]  state;
reg [20:0] cnt_us;
reg [3:0]  bit_idx;
reg [3:0]  byte_idx;
reg [7:0]  wr_byte;
reg [7:0]  rd_byte;
reg [15:0] temp_raw;
reg        dq_out, dq_en;
reg [2:0]  phase;  // 0=跳过ROM, 1=转换, 2=读数据

assign dht11_data = dq_en ? dq_out : 1'bz;

always @(posedge clk_1us or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        state <= IDLE;
        cnt_us <= 21'd0;
        bit_idx <= 4'd0;
        byte_idx <= 4'd0;
        dq_out <= 1'b1;
        dq_en <= 1'b0;
        phase <= 3'd0;
        temp_int <= 8'd0;
        temp_deci <= 8'd0;
        temp_raw <= 16'd0;
        temp_raw_debug <= 16'd0;
        wr_byte <= 8'd0;
        rd_byte <= 8'd0;
    end
    else begin
        case (state)
            IDLE: begin
                // 调试：在IDLE显示88表示正在等待
                temp_int <= 8'd88;
                // 显示cnt_us的高位来确认计数器在工作（0-9变化）
                temp_deci <= cnt_us[16:13];
                
                if (cnt_us >= 21'd10000) begin  // 改为10ms测试
                    cnt_us <= 21'd0;
                    phase <= 3'd0;
                    state <= INIT_START;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            INIT_START: begin  // 拉低500us
                // 调试：根据phase显示不同值
                if (phase == 3'd0) begin
                    temp_int <= 8'd24;  // 第1次初始化
                    temp_deci <= 8'd0;
                end
                else if (phase == 3'd2) begin
                    temp_int <= 8'd29;  // 第2次初始化（转换后）
                    temp_deci <= 8'd9;  // 29.9表示第2次初始化
                end
                
                dq_en <= 1'b1;
                dq_out <= 1'b0;
                if (cnt_us >= 21'd500) begin
                    cnt_us <= 21'd0;
                    dq_en <= 1'b0;
                    state <= INIT_WAIT;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            INIT_WAIT: begin  // 等待20us后开始检测（DS18B20在15-60us之间响应）
                if (cnt_us >= 21'd20) begin
                    cnt_us <= 21'd0;
                    state <= INIT_CHECK;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            INIT_CHECK: begin  // 检测存在脉冲（60-240us低电平）
                if (dht11_data == 1'b0) begin
                    cnt_us <= 21'd0;
                    state <= INIT_END;
                    // 测试：检测到存在脉冲，显示25°C
                    temp_int <= 8'd25;
                    temp_deci <= 8'd0;
                end
                else if (cnt_us >= 21'd100) begin  // 超时
                    state <= IDLE;
                    cnt_us <= 21'd0;
                    // 测试：超时失败，显示99°C
                    temp_int <= 8'd99;
                    temp_deci <= 8'd9;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            INIT_END: begin  // 等待存在脉冲结束
                if (dht11_data == 1'b1) begin
                    cnt_us <= 21'd0;
                    bit_idx <= 4'd0;
                    // 测试：存在脉冲结束，显示26°C表示进入写命令阶段
                    temp_int <= 8'd26;
                    temp_deci <= 8'd0;
                    if (phase == 3'd0) begin
                        wr_byte <= CMD_SKIP_ROM;
                        state <= WRITE_BYTE;
                    end
                    else if (phase == 3'd1) begin
                        wr_byte <= CMD_CONVERT;
                        state <= WRITE_BYTE;
                    end
                    else begin
                        wr_byte <= CMD_READ_SPAD;
                        state <= WRITE_BYTE;
                    end
                end
                else if (cnt_us >= 21'd300) begin
                    state <= IDLE;
                    cnt_us <= 21'd0;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            WRITE_BYTE: begin
                if (cnt_us == 21'd0) begin
                    // 拉低1us开始写时隙
                    dq_en <= 1'b1;
                    dq_out <= 1'b0;
                    cnt_us <= 21'd1;
                end
                else if (cnt_us == 21'd1) begin
                    // 写0保持低，写1释放
                    if (wr_byte[0])
                        dq_en <= 1'b0;
                    cnt_us <= 21'd2;
                end
                else if (cnt_us >= 21'd65) begin
                    // 时隙结束
                    dq_en <= 1'b0;
                    cnt_us <= 21'd0;
                    wr_byte <= {1'b0, wr_byte[7:1]};
                    
                    if (bit_idx == 4'd7) begin
                        bit_idx <= 4'd0;
                        if (phase == 3'd0) begin
                            // 写完0xCC (Skip ROM)，继续写0x44 (Convert)
                            phase <= 3'd1;
                            cnt_us <= 21'd0;
                            state <= WRITE_BYTE;  // 不重新初始化！
                            // 测试：写完Skip ROM
                            temp_int <= 8'd27;
                            temp_deci <= 8'd0;
                        end
                        else if (phase == 3'd1) begin
                            // 写完0x44 (Convert)，等待750ms转换
                            phase <= 3'd2;
                            state <= WAIT_CONV;
                            // 测试：写完Convert T
                            temp_int <= 8'd28;
                            temp_deci <= 8'd0;
                        end
                        else begin
                            // 写完0xBE (Read Scratchpad)，开始读数据
                            byte_idx <= 4'd0;
                            state <= READ_BYTE;
                            // 测试：开始读取数据
                            temp_int <= 8'd30;
                            temp_deci <= 8'd0;
                        end
                    end
                    else
                        bit_idx <= bit_idx + 1'b1;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            WAIT_CONV: begin  // 等待转换（测试用1ms，正常应该750ms）
                // 在等待期间保持显示28，防止被其他地方清零
                temp_int <= 8'd28;
                temp_deci <= 8'd0;
                
                if (cnt_us >= 21'd1000) begin  // 1ms测试
                    cnt_us <= 21'd0;
                    state <= INIT_START;
                    // 测试：转换完成，准备重新初始化读取
                    temp_int <= 8'd29;
                    temp_deci <= 8'd5;  // 29.5以区别于INIT_START的29
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            READ_BYTE: begin
                if (cnt_us == 21'd0) begin
                    // 拉低1us开始读时隙
                    dq_en <= 1'b1;
                    dq_out <= 1'b0;
                    cnt_us <= 21'd1;
                end
                else if (cnt_us == 21'd1) begin
                    // 释放总线
                    dq_en <= 1'b0;
                    cnt_us <= 21'd2;
                end
                else if (cnt_us == 21'd10) begin
                    // 10us采样（LSB first：先采样的bit移到低位）
                    rd_byte <= {dht11_data, rd_byte[7:1]};
                    cnt_us <= 21'd11;
                end
                else if (cnt_us >= 21'd65) begin
                    // 时隙结束
                    cnt_us <= 21'd0;
                    
                    if (bit_idx == 4'd7) begin
                        bit_idx <= 4'd0;
                        // 保存字节（LSB先，所以byte0=低字节，byte1=高字节）
                        if (byte_idx == 4'd0)
                            temp_raw[7:0] <= rd_byte;  // 温度低字节
                        else if (byte_idx == 4'd1)
                            temp_raw[15:8] <= rd_byte; // 温度高字节
                        
                        if (byte_idx >= 4'd1) begin
                            // 读完温度（2字节），保存并返回IDLE
                            temp_raw_debug <= {rd_byte, temp_raw[7:0]};
                            
                            // 处理温度：bit[15]=符号，bit[10:4]=整数，bit[3:0]=小数×0.0625
                            if (rd_byte[7] == 1'b0) begin  // 正温度
                                temp_int <= temp_raw[10:4];  // 整数部分7位
                                // 小数部分：temp_raw[3:0] × 0.0625
                                case (temp_raw[3:0])
                                    4'd0:  temp_deci <= 8'd0;
                                    4'd1:  temp_deci <= 8'd1;   
                                    4'd2:  temp_deci <= 8'd1;   
                                    4'd3:  temp_deci <= 8'd2;   
                                    4'd4:  temp_deci <= 8'd3;   
                                    4'd5:  temp_deci <= 8'd3;   
                                    4'd6:  temp_deci <= 8'd4;   
                                    4'd7:  temp_deci <= 8'd4;   
                                    4'd8:  temp_deci <= 8'd5;   
                                    4'd9:  temp_deci <= 8'd6;   
                                    4'd10: temp_deci <= 8'd6;   
                                    4'd11: temp_deci <= 8'd7;   
                                    4'd12: temp_deci <= 8'd8;   
                                    4'd13: temp_deci <= 8'd8;   
                                    4'd14: temp_deci <= 8'd9;   
                                    4'd15: temp_deci <= 8'd9;   
                                endcase
                            end
                            else begin  // 负温度
                                temp_int <= 8'd0;  // 暂不处理负温度
                                temp_deci <= 8'd0;
                            end
                            
                            state <= IDLE;
                            byte_idx <= 4'd0;
                            cnt_us <= 21'd0;
                        end
                        else begin
                            byte_idx <= byte_idx + 1'b1;
                        end
                    end
                    else
                        bit_idx <= bit_idx + 1'b1;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
