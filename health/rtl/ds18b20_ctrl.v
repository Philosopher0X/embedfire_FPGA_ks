// DS18B20温度传感器驱动模块 - 参考第36章文档
module ds18b20_ctrl(
    input  wire        sys_clk,      // 50MHz系统时钟
    input  wire        sys_rst_n,    // 复位信号
    inout  wire        dq,           // DS18B20数据线
    
    output reg  [7:0]  temp_int,     // 温度整数部分
    output reg  [7:0]  temp_deci     // 温度小数部分(一位)
);

// 状态机定义
localparam IDLE         = 4'd0;
localparam INIT_LOW     = 4'd1;   // 初始化：拉低480us
localparam INIT_WAIT    = 4'd2;   // 等待DS18B20响应
localparam INIT_RELEASE = 4'd3;   // 等待DS18B20释放总线
localparam WRITE_CMD1   = 4'd4;   // 写Skip ROM
localparam WRITE_CMD2   = 4'd5;   // 写Convert/Read命令
localparam WAIT_CONV    = 4'd6;   // 等待温度转换
localparam READ_DATA    = 4'd7;   // 读数据

// DS18B20命令
localparam CMD_SKIP_ROM = 8'hCC;
localparam CMD_CONVERT  = 8'h44;
localparam CMD_READ     = 8'hBE;

// 时钟分频：50MHz -> 1MHz (1us)
reg [5:0]  clk_cnt;
reg        clk_1us;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        clk_cnt <= 6'd0;
        clk_1us <= 1'b0;
    end
    else if (clk_cnt == 6'd24) begin  // 50个周期=1us
        clk_cnt <= 6'd0;
        clk_1us <= ~clk_1us;
    end
    else
        clk_cnt <= clk_cnt + 1'b1;
end

// 信号定义
reg [3:0]  state;
reg [19:0] cnt_us;       // 微秒计数器
reg [3:0]  bit_cnt;      // 位计数
reg [3:0]  byte_cnt;     // 字节计数
reg [7:0]  data_byte;    // 当前字节
reg        phase;        // 阶段：0=启动转换，1=读取温度
reg [15:0] temp_data;    // 温度原始数据
reg        dq_out;
reg        dq_dir;       // 1=输出，0=输入

assign dq = dq_dir ? dq_out : 1'bz;

// 主状态机
always @(posedge clk_1us or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        state <= IDLE;
        cnt_us <= 20'd0;
        bit_cnt <= 4'd0;
        byte_cnt <= 4'd0;
        phase <= 1'b0;
        dq_out <= 1'b1;
        dq_dir <= 1'b0;
        temp_int <= 8'd0;
        temp_deci <= 8'd0;
        temp_data <= 16'd0;
        data_byte <= 8'd0;
    end
    else begin
        case (state)
            // 空闲状态，每隔1秒启动一次读取
            IDLE: begin
                dq_dir <= 1'b0;
                if (cnt_us >= 20'd1000000) begin  // 1秒
                    cnt_us <= 20'd0;
                    phase <= 1'b0;  // 从阶段0开始（启动转换）
                    state <= INIT_LOW;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 初始化：拉低480us以上
            INIT_LOW: begin
                dq_dir <= 1'b1;
                dq_out <= 1'b0;
                if (cnt_us >= 20'd500) begin  // 拉低500us
                    cnt_us <= 20'd0;
                    dq_dir <= 1'b0;  // 释放总线
                    state <= INIT_WAIT;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 等待DS18B20响应（15-60us后拉低）
            INIT_WAIT: begin
                if (dq == 1'b0) begin  // 检测到存在脉冲
                    cnt_us <= 20'd0;
                    state <= INIT_RELEASE;
                end
                else if (cnt_us >= 20'd80) begin  // 超时，返回
                    state <= IDLE;
                    cnt_us <= 20'd0;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 等待DS18B20释放总线
            INIT_RELEASE: begin
                if (dq == 1'b1) begin  // 总线释放
                    cnt_us <= 20'd0;
                    bit_cnt <= 4'd0;
                    data_byte <= CMD_SKIP_ROM;  // 先写Skip ROM
                    state <= WRITE_CMD1;
                end
                else if (cnt_us >= 20'd300) begin  // 超时
                    state <= IDLE;
                    cnt_us <= 20'd0;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 写第1个命令：Skip ROM (0xCC)
            WRITE_CMD1: begin
                if (cnt_us == 20'd0) begin
                    dq_dir <= 1'b1;
                    dq_out <= 1'b0;
                    cnt_us <= 20'd1;
                end
                else if (cnt_us == 20'd1) begin
                    if (data_byte[0])
                        dq_dir <= 1'b0;
                    else
                        dq_out <= 1'b0;
                    cnt_us <= 20'd2;
                end
                else if (cnt_us >= 20'd60) begin
                    dq_dir <= 1'b0;
                    cnt_us <= 20'd0;
                    data_byte <= {1'b0, data_byte[7:1]};
                    
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd0;
                        // 写完Skip ROM，根据phase选择下一个命令
                        if (phase == 1'b0)
                            data_byte <= CMD_CONVERT;  // 阶段0：Convert T
                        else
                            data_byte <= CMD_READ;     // 阶段1：Read
                        state <= WRITE_CMD2;
                    end
                    else
                        bit_cnt <= bit_cnt + 1'b1;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 写第2个命令：Convert T (0x44) 或 Read (0xBE)
            WRITE_CMD2: begin
                if (cnt_us == 20'd0) begin
                    dq_dir <= 1'b1;
                    dq_out <= 1'b0;
                    cnt_us <= 20'd1;
                end
                else if (cnt_us == 20'd1) begin
                    if (data_byte[0])
                        dq_dir <= 1'b0;
                    else
                        dq_out <= 1'b0;
                    cnt_us <= 20'd2;
                end
                else if (cnt_us >= 20'd60) begin
                    dq_dir <= 1'b0;
                    cnt_us <= 20'd0;
                    data_byte <= {1'b0, data_byte[7:1]};
                    
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd0;
                        if (phase == 1'b0) begin
                            // 写完Convert T，等待转换
                            state <= WAIT_CONV;
                        end
                        else begin
                            // 写完Read命令，开始读数据
                            byte_cnt <= 4'd0;
                            state <= READ_DATA;
                        end
                    end
                    else
                        bit_cnt <= bit_cnt + 1'b1;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 等待温度转换（800ms）
            WAIT_CONV: begin
                if (cnt_us >= 20'd800000) begin  // 800ms
                    cnt_us <= 20'd0;
                    phase <= 1'b1;  // 切换到阶段1（读取温度）
                    state <= INIT_LOW;  // 重新初始化读取数据
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            // 读数据（读2个字节：温度低字节和高字节）
            READ_DATA: begin
                if (cnt_us == 20'd0) begin
                    dq_dir <= 1'b1;
                    dq_out <= 1'b0;
                    cnt_us <= 20'd1;
                end
                else if (cnt_us == 20'd1) begin
                    dq_dir <= 1'b0;
                    cnt_us <= 20'd2;
                end
                else if (cnt_us == 20'd15) begin
                    // 15us时采样
                    data_byte <= {dq, data_byte[7:1]};
                    cnt_us <= 20'd16;
                end
                else if (cnt_us >= 20'd60) begin
                    cnt_us <= 20'd0;
                    
                    if (bit_cnt == 4'd7) begin
                        bit_cnt <= 4'd0;
                        if (byte_cnt == 4'd0) begin
                            temp_data[7:0] <= data_byte;
                            byte_cnt <= 4'd1;
                        end
                        else begin
                            temp_data[15:8] <= data_byte;
                            
                            // 处理温度
                            if (data_byte[7] == 1'b0) begin
                                temp_int <= {1'b0, temp_data[10:4]};
                                case (temp_data[3:0])
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
                            
                            byte_cnt <= 4'd0;
                            state <= IDLE;
                        end
                    end
                    else
                        bit_cnt <= bit_cnt + 1'b1;
                end
                else
                    cnt_us <= cnt_us + 1'b1;
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
