module dht11_ctrl(
    input  wire        sys_clk,      // 系统时钟 50MHz
    input  wire        sys_rst_n,    // 系统复位
    inout  wire        dht11_data,   // DHT11数据线
    
    output reg  [7:0]  humi_int,     // 湿度整数部分
    output reg  [7:0]  humi_deci,    // 湿度小数部分
    output reg  [7:0]  temp_int,     // 温度整数部分
    output reg  [7:0]  temp_deci,    // 温度小数部分
    output reg         dht11_valid   // 数据有效标志
);

// 状态机状态定义
localparam IDLE      = 4'd0;   // 空闲状态
localparam START_LOW = 4'd1;   // 起始信号-拉低18ms
localparam START_HIGH= 4'd2;   // 起始信号-释放总线20-40us
localparam WAIT_RESP = 4'd3;   // 等待DHT11响应
localparam RESP_LOW  = 4'd4;   // DHT11响应-拉低80us
localparam RESP_HIGH = 4'd5;   // DHT11响应-拉高80us
localparam DATA_START= 4'd6;   // 数据位起始-拉低50us
localparam DATA_BIT  = 4'd7;   // 数据位-高电平持续时间
localparam DATA_END  = 4'd8;   // 数据接收完成
localparam CHECK_SUM = 4'd9;   // 校验和检查

// 时钟计数器
reg  [23:0] cnt;              // 计数器,用于延时
reg  [3:0]  state;            // 状态机
reg  [5:0]  bit_cnt;          // 位计数器(0-39,共40位)
reg  [39:0] data_buf;         // 数据缓冲区
reg         dht11_out;        // 输出数据
reg         dht11_oe;         // 输出使能

// 三态门控制
assign dht11_data = dht11_oe ? dht11_out : 1'bz;

// 时间参数(50MHz时钟)
localparam CNT_18MS  = 24'd900_000;   // 18ms
localparam CNT_30US  = 24'd1_500;     // 30us
localparam CNT_40US  = 24'd2_000;     // 40us (数据位判断阈值)
localparam CNT_100US = 24'd5_000;     // 100us
localparam CNT_60US  = 24'd3_000;     // 60us
localparam CNT_2S    = 24'd100_000_000; // 2s 读取间隔

// 主状态机
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        state <= IDLE;
        cnt <= 24'd0;
        bit_cnt <= 6'd0;
        data_buf <= 40'd0;
        dht11_out <= 1'b1;
        dht11_oe <= 1'b0;
        dht11_valid <= 1'b0;
        humi_int <= 8'd0;
        humi_deci <= 8'd0;
        temp_int <= 8'd0;
        temp_deci <= 8'd0;
    end
    else begin
        case (state)
            IDLE: begin
                dht11_valid <= 1'b0;
                dht11_oe <= 1'b0;
                if (cnt < CNT_2S) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= START_LOW;
                end
            end
            
            START_LOW: begin
                dht11_oe <= 1'b1;
                dht11_out <= 1'b0;
                if (cnt < CNT_18MS) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= START_HIGH;
                end
            end
            
            START_HIGH: begin
                dht11_oe <= 1'b0;    // 释放总线
                if (cnt < CNT_30US) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= WAIT_RESP;
                end
            end
            
            WAIT_RESP: begin
                if (dht11_data == 1'b0) begin
                    cnt <= 24'd0;
                    state <= RESP_LOW;
                end
                else if (cnt < CNT_100US) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= IDLE;  // 超时,返回IDLE
                end
            end
            
            RESP_LOW: begin
                if (dht11_data == 1'b1) begin
                    cnt <= 24'd0;
                    state <= RESP_HIGH;
                end
                else if (cnt < CNT_100US) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= IDLE;
                end
            end
            
            RESP_HIGH: begin
                if (dht11_data == 1'b0) begin
                    cnt <= 24'd0;
                    bit_cnt <= 6'd0;
                    state <= DATA_START;
                end
                else if (cnt < CNT_100US) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= IDLE;
                end
            end
            
            DATA_START: begin
                if (dht11_data == 1'b1) begin
                    cnt <= 24'd0;
                    state <= DATA_BIT;
                end
                else if (cnt < CNT_60US) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= IDLE;
                end
            end
            
            DATA_BIT: begin
                if (dht11_data == 1'b0) begin
                    // 根据高电平持续时间判断数据位
                    // 0: 26-28us, 1: 70us, 阈值40us
                    if (cnt > CNT_40US) begin
                        data_buf <= {data_buf[38:0], 1'b1};
                    end
                    else begin
                        data_buf <= {data_buf[38:0], 1'b0};
                    end
                    
                    cnt <= 24'd0;
                    
                    if (bit_cnt == 6'd39) begin
                        bit_cnt <= 6'd0;
                        state <= CHECK_SUM;
                    end
                    else begin
                        bit_cnt <= bit_cnt + 1'b1;
                        state <= DATA_START;
                    end
                end
                else if (cnt < CNT_100US) begin
                    cnt <= cnt + 1'b1;
                end
                else begin
                    cnt <= 24'd0;
                    state <= IDLE;
                end
            end
            
            CHECK_SUM: begin
                // 校验和检查
                if (data_buf[7:0] == (data_buf[39:32] + data_buf[31:24] + 
                                      data_buf[23:16] + data_buf[15:8])) begin
                    humi_int <= data_buf[39:32];
                    humi_deci <= data_buf[31:24];
                    temp_int <= data_buf[23:16];
                    temp_deci <= data_buf[15:8];
                    dht11_valid <= 1'b1;
                end
                state <= IDLE;
                cnt <= 24'd0;
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
