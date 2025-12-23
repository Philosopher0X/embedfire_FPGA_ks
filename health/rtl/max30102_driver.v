module max30102_driver#(
    parameter P_SYS_CLK = 50_000_000 
) (
    input           clk,            // 50MHz
    input           rst_n,          // 复位，低有效
    
    // I2C 物理接口 (对接 iic_drive)
    output          iic_scl,
    inout           iic_sda,

    // 用户接口
    input           max_int,        // 来自传感器的中断信号 (Active Low)
    output [17:0]   o_red_data,     // 解析后的红光数据
    output [17:0]   o_ir_data,      // 解析后的红外数据
    output          o_data_valid,   // 数据有效脉冲
    
    // 调试/状态接口 (可选，便于仿真观察)
    output          o_ready         // 驱动处于空闲状态，配置完成
);
    // IIC 驱动控制信号
    reg         iic_start;
    wire        iic_ready;
    reg         iic_rw_flag;        // 0:写, 1:读
    reg  [3:0]  iic_byte_num;       // 动态长度：配置用1，读数据用6
    reg  [7:0]  iic_word_addr;      // 寄存器地址
    reg  [47:0] iic_wdata;          // 写数据 (最大6字节，初始化时只用最高8位)
    wire [47:0] iic_rdata;          // 读回的数据
    wire        iic_rdata_valid;
    wire        iic_ack_error;

    // 状态机信号
    localparam CNT_WAIT_MAX = P_SYS_CLK / 100; // 上电等待 10ms
    reg [19:0] cnt_wait; 
    
    // 中断去抖
    reg        max_int_d0, max_int_d1;
    wire       max_int_fall;
	 
    reg [3:0] retry_cnt;            // 重试计数器
    localparam MAX_RETRY_NUM = 4'd10; // 最大重试10次

    iic_drive #(
        .P_SYS_CLK           (P_SYS_CLK),
        .P_IIC_SCL           (28'd400_000),    // 400kHz
        .P_DEVICE_ADDR       (7'h57),          // 0xAE >> 1 = 0x57
        .P_ADDR_BYTE_NUM     (1),              // 寄存器地址 1字节
        .P_MAX_DATA_BYTE_NUM (6)               // 最大数据位宽 6字节
    ) u_iic_drive (
        .iic_clk             (clk),
        .iic_rst             (~rst_n),         // iic_drive 是高电平复位
        .iic_start           (iic_start),
        .iic_ready           (iic_ready),
        .iic_rw_flag         (iic_rw_flag),
        .iic_byte_num        (iic_byte_num),   // 动态长度连接
        .iic_word_addr       (iic_word_addr),
        .iic_wdata           (iic_wdata),      // MSB对齐
        .iic_rdata           (iic_rdata),
        .iic_rdata_valid     (iic_rdata_valid),
        .iic_ack_error       (iic_ack_error),
        .iic_scl             (iic_scl),
        .iic_sda             (iic_sda)
    );
    reg [3:0] cmd_index; // 当前执行到第几条命令
    reg [7:0] lut_reg_addr;
    reg [7:0] lut_write_data;
    
    // 共有多少条配置命令？根据你的描述是 10 条
    localparam CMD_TOTAL_NUM = 4'd11; 

    always @(*) begin
        case(cmd_index)
            // 格式：寄存器地址, 写入值
            4'd0: begin lut_reg_addr = 8'h09; lut_write_data = 8'h40; end // 复位
            4'd1: begin lut_reg_addr = 8'h02; lut_write_data = 8'hC0; end // 中断使能 A_FULL + PPG_RDY
            4'd2: begin lut_reg_addr = 8'h03; lut_write_data = 8'h00; end // 中断使能2
            4'd3: begin lut_reg_addr = 8'h04; lut_write_data = 8'h00; end // FIFO写指针清零
            4'd4: begin lut_reg_addr = 8'h05; lut_write_data = 8'h00; end // FIFO溢出计数清零
            4'd5: begin lut_reg_addr = 8'h06; lut_write_data = 8'h00; end // FIFO读指针清零
            4'd6: begin lut_reg_addr = 8'h08; lut_write_data = 8'h4F; end // FIFO配置: 4均值
            4'd7: begin lut_reg_addr = 8'h09; lut_write_data = 8'h03; end // 模式配置: SpO2
            // TODO: 请确认下面两条命令是否符合你的 SpO2参数 (0x0A) 和 LED配置
            4'd8: begin lut_reg_addr = 8'h0A; lut_write_data = 8'h27; end // SpO2配置
            4'd9: begin lut_reg_addr = 8'h0C; lut_write_data = 8'h24; end // LED1 Pulse Amplitude
            4'd10: begin lut_reg_addr = 8'h0D; lut_write_data = 8'h24; end // LED2 Pulse Amplitude
            default: begin lut_reg_addr = 8'h00; lut_write_data = 8'h00; end
        endcase
    end
    localparam S_POWER_UP  = 5'b00001; // 上电等待
    localparam S_CONFIG    = 5'b00010; // 写入配置
    localparam S_WAIT_IIC  = 5'b00100; // 等待IIC传输完成
    localparam S_IDLE      = 5'b01000; // 空闲，等中断
    localparam S_READ_FIFO = 5'b10000; // 读取数据

    reg [4:0] state, next_state; // 当前状态，保存的状态(用于从Wait返回)

    // 中断下降沿检测
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            max_int_d0 <= 1'b1;
            max_int_d1 <= 1'b1;
        end else begin
            max_int_d0 <= max_int;
            max_int_d1 <= max_int_d0;
        end
    end
    assign max_int_fall = max_int_d1 & (~max_int_d0);

    // 状态机
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state <= S_POWER_UP;
            cmd_index <= 0;
            iic_start <= 0;
            cnt_wait <= 0;
            iic_byte_num <= 0;
				retry_cnt <= 0;
        end else begin
            case(state)
                S_POWER_UP: begin
                    if(cnt_wait >= CNT_WAIT_MAX) begin
                        state <= S_CONFIG;
                        cnt_wait <= 0;
                        cmd_index <= 0;
                    end else begin
                        cnt_wait <= cnt_wait + 1'b1;
                    end
                end

                S_CONFIG: begin
                    // 准备配置数据
                    if(iic_ready) begin
                        iic_rw_flag   <= 1'b0;          // 写操作
                        iic_byte_num  <= 4'd1;          // 写1字节
                        iic_word_addr <= lut_reg_addr;  // 查表得地址
                        // MSB对齐：数据放在最高字节 [47:40]
                        iic_wdata     <= {lut_write_data, 40'd0}; 
                        
                        iic_start     <= 1'b1;          // 触发传输
                        state         <= S_WAIT_IIC;    // 等待完成
                        next_state    <= S_CONFIG;      // 完成后回来这里
                    end
                end

                S_WAIT_IIC: begin
                    iic_start <= 1'b0; // 及时清除Start信号
                    
                    if(iic_ack_error) begin
                        if(retry_cnt < MAX_RETRY_NUM) begin
                            retry_cnt <= retry_cnt + 1'b1; // 计数加1
                            state     <= next_state;       // 跳回发起命令的状态(S_CONFIG 或 S_READ_FIFO)
                        end else begin
                            // 超过重试次数，彻底放弃
                            state     <= S_IDLE; 
                            retry_cnt <= 0;                // 清空计数器
                        end
                    end
                    else if(iic_ready) begin // 驱动变回空闲，说明传输结束
						      retry_cnt <= 0;
                        if(next_state == S_CONFIG) begin
                            // 如果是配置状态回来的，判断是否配完了
                            if(cmd_index == CMD_TOTAL_NUM - 1) begin
                                state <= S_IDLE;
                            end else begin
                                cmd_index <= cmd_index + 1'b1; // 下一条命令
                                state <= S_CONFIG;
                            end
                        end
                        else if(next_state == S_READ_FIFO) begin
                            // 如果是读数据回来的，回空闲
                            state <= S_IDLE;
                        end
                    end
                end

                S_IDLE: begin
                    if(max_int_fall) begin
                        state <= S_READ_FIFO;
                    end
                end

                S_READ_FIFO: begin
                    if(iic_ready) begin
                        iic_rw_flag   <= 1'b1;          // 读操作
                        iic_byte_num  <= 4'd6;          // 读6字节
                        iic_word_addr <= 8'h07;         // FIFO 数据寄存器
                        iic_wdata     <= 48'd0;         // 读操作写数据无效
                        
                        iic_start     <= 1'b1;
                        state         <= S_WAIT_IIC;
                        next_state    <= S_READ_FIFO;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

    assign o_ready = (state == S_IDLE);
    
    // 当 IIC 读操作完成，且数据有效时，更新输出
    // IIC Drive 保证了 iic_rdata_valid 只有在读操作完成且校验通过时才拉高
    assign o_data_valid = iic_rdata_valid;

    // 数据解析：
    // Byte1(R_H), Byte2(R_M), Byte3(R_L), Byte4(IR_H)...
    // iic_rdata 是 MSB 对齐的 48位数据: [47:40][39:32][31:24][23:16][15:8][7:0]
    // Red = Byte1,2,3 -> [47:24]
    // IR  = Byte4,5,6 -> [23:0]
    // MAX30102 的数据是左对齐在这三个字节里的，有效位是18位
    
    // 取高18位：即 Byte1 全取，Byte2 全取，Byte3 取高2位
    // [47:24] 的最高18位是 [47:30]
    assign o_red_data = iic_rdata[47:30];
    assign o_ir_data  = iic_rdata[23:6];

endmodule