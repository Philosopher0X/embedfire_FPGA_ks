//****************************************Copyright (c)***********************************//
// File name: max30102_driver.v
// Description: MAX30102心率血氧传感器驱动
// Created by: Fire
// Created date: 2025-12-22
// Version: V1.0
//****************************************************************************************//

module max30102_driver(
    input   wire            clk         ,   // 系统时钟 50MHz
    input   wire            rst_n       ,   // 复位信号，低电平有效
    
    // I2C接口（双向）
    inout   wire            scl         ,   // I2C时钟线
    inout   wire            sda         ,   // I2C数据线
    input   wire            int_n       ,   // 中断信号，低电平有效
    
    // 数据输出
    output  reg     [17:0]  red_data    ,   // RED通道数据（18位）
    output  reg     [17:0]  ir_data     ,   // IR通道数据（18位）
    output  reg             data_valid  ,   // 数据有效标志
    output  reg     [7:0]   temp_int    ,   // 温度整数部分
    output  reg     [3:0]   temp_frac   ,   // 温度小数部分
    output  reg             temp_valid  ,   // 温度数据有效
    
    // 状态输出
    output  reg             init_done   ,   // 初始化完成
    output  reg             error           // 错误标志
);

// MAX30102 I2C从机地址
parameter   SLAVE_ADDR = 7'h57;

// MAX30102 寄存器地址
localparam  REG_INTR_STATUS_1   = 8'h00;    // 中断状态1
localparam  REG_INTR_STATUS_2   = 8'h01;    // 中断状态2
localparam  REG_INTR_ENABLE_1   = 8'h02;    // 中断使能1
localparam  REG_INTR_ENABLE_2   = 8'h03;    // 中断使能2
localparam  REG_FIFO_WR_PTR     = 8'h04;    // FIFO写指针
localparam  REG_FIFO_OVF_CNT    = 8'h05;    // FIFO溢出计数
localparam  REG_FIFO_RD_PTR     = 8'h06;    // FIFO读指针
localparam  REG_FIFO_DATA       = 8'h07;    // FIFO数据寄存器
localparam  REG_FIFO_CONFIG     = 8'h08;    // FIFO配置
localparam  REG_MODE_CONFIG     = 8'h09;    // 模式配置
localparam  REG_SPO2_CONFIG     = 8'h0A;    // SpO2配置
localparam  REG_LED1_PA         = 8'h0C;    // LED1(RED)电流
localparam  REG_LED2_PA         = 8'h0D;    // LED2(IR)电流
localparam  REG_TEMP_INT        = 8'h1F;    // 温度整数部分
localparam  REG_TEMP_FRAC       = 8'h20;    // 温度小数部分
localparam  REG_DIE_TEMP_CONFIG = 8'h21;    // 温度测量触发
localparam  REG_REVISION_ID     = 8'hFE;    // 版本ID
localparam  REG_PART_ID         = 8'hFF;    // 器件ID

// I2C主控制器信号
wire            scl_in      ;
wire            scl_out     ;
wire            scl_oe      ;
wire            sda_in      ;
wire            sda_out     ;
wire            sda_oe      ;

reg             i2c_start   ;
reg     [1:0]   i2c_cmd     ;
reg     [6:0]   i2c_slave   ;
reg     [7:0]   i2c_reg_addr;
reg     [7:0]   i2c_wr_data ;
reg     [7:0]   i2c_rd_num  ;
wire    [7:0]   i2c_rd_data ;
wire            i2c_rd_valid;
wire            i2c_busy    ;
wire            i2c_done    ;
wire            i2c_ack_err ;

// 双向IO控制 - 开漏模式
// I2C开漏总线：
// - 当需要输出0时（sda_oe=1, sda_out=0）：主动拉低
// - 当需要输出1时（sda_oe=1, sda_out=1）：释放（高阻态）让上拉拉高
// - 当需要读取时（sda_oe=0）：释放（高阻态）读取从机数据
// SCL也是一样的逻辑
assign scl = (scl_oe && !scl_out) ? 1'b0 : 1'bz;
assign sda = (sda_oe && !sda_out) ? 1'b0 : 1'bz;
assign scl_in = scl;
assign sda_in = sda;

// 实例化I2C主控制器
i2c_master u_i2c_master(
    .clk            (clk            ),
    .rst_n          (rst_n          ),
    .scl_in         (scl_in         ),
    .scl_out        (scl_out        ),
    .scl_oe         (scl_oe         ),
    .sda_in         (sda_in         ),
    .sda_out        (sda_out        ),
    .sda_oe         (sda_oe         ),
    .start          (i2c_start      ),
    .cmd            (i2c_cmd        ),
    .slave_addr     (i2c_slave      ),
    .reg_addr       (i2c_reg_addr   ),
    .wr_data        (i2c_wr_data    ),
    .rd_num         (i2c_rd_num     ),
    .rd_data        (i2c_rd_data    ),
    .rd_valid       (i2c_rd_valid   ),
    .busy           (i2c_busy       ),
    .done           (i2c_done       ),
    .ack_error      (i2c_ack_err    )
);

// 状态机定义
localparam  IDLE            = 6'd0 ;
localparam  DELAY_INIT      = 6'd1 ;
localparam  INIT_RESET      = 6'd2 ;    // 软复位
localparam  WAIT_RESET      = 6'd3 ;
localparam  INIT_FIFO_CFG   = 6'd4 ;    // 配置FIFO
localparam  INIT_MODE       = 6'd5 ;    // 配置模式
localparam  INIT_SPO2       = 6'd6 ;    // 配置SpO2
localparam  INIT_LED1       = 6'd7 ;    // 配置LED1电流
localparam  INIT_LED2       = 6'd8 ;    // 配置LED2电流
localparam  INIT_INT_EN     = 6'd9 ;    // 使能中断
localparam  INIT_COMPLETE   = 6'd10;    // 初始化完成
localparam  WAIT_INT        = 6'd11;    // 等待中断
localparam  TEMP_TRIGGER    = 6'd12;    // 触发温度测量
localparam  WAIT_TEMP       = 6'd20;    // 等待温度转换
localparam  READ_TEMP_INT   = 6'd13;    // 读温度整数
localparam  READ_TEMP_FRAC  = 6'd14;    // 读温度小数
localparam  READ_FIFO_PTR   = 6'd15;    // 读FIFO指针
localparam  CALC_SAMPLES    = 6'd16;    // 计算样本数
localparam  READ_FIFO       = 6'd17;    // 读FIFO数据
localparam  PROCESS_DATA    = 6'd18;    // 处理数据
localparam  WAIT_DONE       = 6'd19;    // 等待I2C完成
localparam  ERROR_STATE     = 6'd63;    // 错误状态

reg     [5:0]   state       ;
reg     [5:0]   next_state  ;
reg     [31:0]  delay_cnt   ;
reg     [31:0]  temp_timer  ;           // 温度读取计时器
reg     [7:0]   fifo_wr_ptr ;
reg     [7:0]   fifo_rd_ptr ;
reg     [7:0]   samples     ;
reg     [7:0]   byte_cnt    ;
reg     [7:0]   fifo_buf[5:0];
reg     [7:0]   temp_int_buf;           // 温度整数缓存
reg     [7:0]   temp_frac_buf;          // 温度小数缓存
reg             int_flag    ;
reg             int_n_d0    ;
reg             int_n_d1    ;

// 中断信号边沿检测
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        int_n_d0 <= 1'b1;
        int_n_d1 <= 1'b1;
    end
    else begin
        int_n_d0 <= int_n;
        int_n_d1 <= int_n_d0;
    end
end

// 中断下降沿检测
wire int_neg = int_n_d1 & ~int_n_d0;

// 中断标志
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        int_flag <= 1'b0;
    else if (int_neg)
        int_flag <= 1'b1;
    else if (state == READ_FIFO_PTR)
        int_flag <= 1'b0;
end

// 延时计数器
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        delay_cnt <= 32'd0;
        temp_timer <= 32'd0;
    end
    else if (state == DELAY_INIT || state == WAIT_RESET || state == WAIT_TEMP || state == ERROR_STATE)
        delay_cnt <= delay_cnt + 1'b1;
    else begin
        delay_cnt <= 32'd0;
        // 温度读取计时器：每秒读取一次（50MHz）
        if (temp_timer >= 50_000_000)
            temp_timer <= 32'd0;
        else
            temp_timer <= temp_timer + 1'b1;
    end
end

// 状态机 - 第一段
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

// 状态机 - 第二段
always @(*) begin
    case (state)
        IDLE:           next_state = DELAY_INIT;
        
        DELAY_INIT:     next_state = (delay_cnt >= 50_000_000) ? INIT_RESET : DELAY_INIT;  // 1秒延时
        
        INIT_RESET:     next_state = i2c_busy ? WAIT_DONE : INIT_RESET;
        
        WAIT_RESET:     next_state = (delay_cnt >= 5_000_000) ? INIT_FIFO_CFG : WAIT_RESET;  // 100ms延时
        
        INIT_FIFO_CFG:  next_state = i2c_busy ? WAIT_DONE : INIT_FIFO_CFG;
        
        INIT_MODE:      next_state = i2c_busy ? WAIT_DONE : INIT_MODE;
        
        INIT_SPO2:      next_state = i2c_busy ? WAIT_DONE : INIT_SPO2;
        
        INIT_LED1:      next_state = i2c_busy ? WAIT_DONE : INIT_LED1;
        
        INIT_LED2:      next_state = i2c_busy ? WAIT_DONE : INIT_LED2;
        
        INIT_INT_EN:    next_state = i2c_busy ? WAIT_DONE : INIT_INT_EN;
        
        WAIT_DONE: begin
            if (i2c_done) begin
                case (state)
                    INIT_RESET:     next_state = WAIT_RESET;
                    INIT_FIFO_CFG:  next_state = INIT_MODE;
                    INIT_MODE:      next_state = INIT_SPO2;
                    INIT_SPO2:      next_state = INIT_LED1;
                    INIT_LED1:      next_state = INIT_LED2;
                    INIT_LED2:      next_state = INIT_INT_EN;
                    INIT_INT_EN:    next_state = INIT_COMPLETE;
                    TEMP_TRIGGER:   next_state = WAIT_TEMP;
                    READ_TEMP_INT:  next_state = READ_TEMP_FRAC;
                    READ_TEMP_FRAC: next_state = WAIT_INT;
                    READ_FIFO_PTR:  next_state = CALC_SAMPLES;
                    READ_FIFO:      next_state = (byte_cnt >= 6) ? PROCESS_DATA : READ_FIFO;
                    default:        next_state = IDLE;
                endcase
            end
            else if (i2c_ack_err)
                next_state = ERROR_STATE;
            else
                next_state = WAIT_DONE;
        end
        
        INIT_COMPLETE:  next_state = WAIT_INT;
        
        WAIT_INT: begin
            // 每秒读取一次温度，或者有中断时读取FIFO
            if (int_flag)
                next_state = READ_FIFO_PTR;
            else if (temp_timer == 50_000_000 - 1)
                next_state = TEMP_TRIGGER;
            else
                next_state = WAIT_INT;
        end
        
        TEMP_TRIGGER:   next_state = i2c_busy ? WAIT_DONE : TEMP_TRIGGER;
        
        WAIT_TEMP:      next_state = (delay_cnt >= 2_000_000) ? READ_TEMP_INT : WAIT_TEMP;  // 40ms延时
        
        READ_TEMP_INT:  next_state = i2c_busy ? WAIT_DONE : READ_TEMP_INT;
        
        READ_TEMP_FRAC: next_state = i2c_busy ? WAIT_DONE : READ_TEMP_FRAC;
        
        READ_FIFO_PTR:  next_state = i2c_busy ? WAIT_DONE : READ_FIFO_PTR;
        
        CALC_SAMPLES:   next_state = (samples > 0) ? READ_FIFO : WAIT_INT;
        
        READ_FIFO:      next_state = i2c_busy ? WAIT_DONE : READ_FIFO;
        
        PROCESS_DATA:   next_state = WAIT_INT;
        
        // 错误后延时重试
        ERROR_STATE:    next_state = (delay_cnt >= 50_000_000) ? IDLE : ERROR_STATE;
        
        default:        next_state = IDLE;
    endcase
end

// 状态机 - 第三段：输出控制
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        i2c_start <= 1'b0;
        i2c_cmd <= 2'd0;
        i2c_slave <= SLAVE_ADDR;
        i2c_reg_addr <= 8'd0;
        i2c_wr_data <= 8'd0;
        i2c_rd_num <= 8'd0;
        init_done <= 1'b0;
        error <= 1'b0;
        fifo_wr_ptr <= 8'd0;
        fifo_rd_ptr <= 8'd0;
        samples <= 8'd0;
    end
    else begin
        i2c_start <= 1'b0;  // 默认值
        i2c_slave <= SLAVE_ADDR;  // 默认从机地址
        i2c_rd_num <= 8'd0;       // 默认读取数量
        
        case (state)
            INIT_RESET: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;           // 写命令
                    i2c_reg_addr <= REG_MODE_CONFIG;
                    i2c_wr_data <= 8'h40;       // 软复位
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_FIFO_CFG: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;
                    i2c_reg_addr <= REG_FIFO_CONFIG;
                    i2c_wr_data <= 8'h4F;       // 采样平均4，FIFO接近满时产生中断
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_MODE: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;
                    i2c_reg_addr <= REG_MODE_CONFIG;
                    i2c_wr_data <= 8'h03;       // SpO2模式（RED+IR）
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_SPO2: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;
                    i2c_reg_addr <= REG_SPO2_CONFIG;
                    i2c_wr_data <= 8'h27;       // ADC范围=4096, 采样率=100Hz, LED脉宽=411us(18位ADC)
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_LED1: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;
                    i2c_reg_addr <= REG_LED1_PA;
                    i2c_wr_data <= 8'h24;       // RED LED电流 = 7.6mA
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_LED2: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;
                    i2c_reg_addr <= REG_LED2_PA;
                    i2c_wr_data <= 8'h24;       // IR LED电流 = 7.6mA
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_INT_EN: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;
                    i2c_reg_addr <= REG_INTR_ENABLE_1;
                    i2c_wr_data <= 8'hC0;       // 使能FIFO接近满中断
                    i2c_start <= 1'b1;
                end
            end
            
            INIT_COMPLETE: begin
                init_done <= 1'b1;
            end
            
            TEMP_TRIGGER: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b00;           // 写命令
                    i2c_reg_addr <= REG_DIE_TEMP_CONFIG;
                    i2c_wr_data <= 8'h01;       // 触发温度测量
                    i2c_start <= 1'b1;
                end
            end
            
            READ_TEMP_INT: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b01;           // 读命令
                    i2c_reg_addr <= REG_TEMP_INT;
                    i2c_start <= 1'b1;
                end
            end
            
            READ_TEMP_FRAC: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b01;           // 读命令
                    i2c_reg_addr <= REG_TEMP_FRAC;
                    i2c_start <= 1'b1;
                end
            end
            
            READ_FIFO_PTR: begin
                if (!i2c_busy) begin
                    i2c_cmd <= 2'b01;           // 读命令
                    i2c_reg_addr <= REG_FIFO_RD_PTR;
                    i2c_start <= 1'b1;
                end
            end
            
            CALC_SAMPLES: begin
                samples <= 8'd1;  // 读取一个样本（6字节）
            end
            
            READ_FIFO: begin
                if (!i2c_busy && byte_cnt < 6) begin
                    i2c_cmd <= 2'b01;           // 读命令
                    i2c_reg_addr <= REG_FIFO_DATA;
                    i2c_start <= 1'b1;
                end
            end
            
            ERROR_STATE: begin
                error <= 1'b1;
            end
        endcase
    end
end

// 接收FIFO数据和温度数据
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fifo_buf[0] <= 8'd0;
        fifo_buf[1] <= 8'd0;
        fifo_buf[2] <= 8'd0;
        fifo_buf[3] <= 8'd0;
        fifo_buf[4] <= 8'd0;
        fifo_buf[5] <= 8'd0;
        byte_cnt <= 8'd0;
        temp_int_buf <= 8'd0;
        temp_frac_buf <= 8'd0;
    end
    else if (state == CALC_SAMPLES)
        byte_cnt <= 8'd0;
    else if (i2c_rd_valid && state == WAIT_DONE) begin
        case (state)
            READ_TEMP_INT: temp_int_buf <= i2c_rd_data;
            READ_TEMP_FRAC: temp_frac_buf <= i2c_rd_data;
            READ_FIFO: begin
                fifo_buf[byte_cnt] <= i2c_rd_data;
                byte_cnt <= byte_cnt + 1'b1;
            end
        endcase
    end
end

// 数据处理和输出
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        red_data <= 18'd0;
        ir_data <= 18'd0;
        data_valid <= 1'b0;
        temp_int <= 8'd0;
        temp_frac <= 4'd0;
        temp_valid <= 1'b0;
    end
    else if (state == PROCESS_DATA) begin
        // RED通道：前3个字节，18位数据左对齐
        red_data <= {fifo_buf[0][5:0], fifo_buf[1], fifo_buf[2][7:4]};
        // IR通道：后3个字节，18位数据左对齐
        ir_data <= {fifo_buf[3][5:0], fifo_buf[4], fifo_buf[5][7:4]};
        data_valid <= 1'b1;
        temp_valid <= 1'b0;
    end
    else if (state == READ_TEMP_FRAC && i2c_rd_valid) begin
        // 温度数据更新
        temp_int <= temp_int_buf;
        temp_frac <= temp_frac_buf[7:4];  // 只取高4位作为小数部分
        temp_valid <= 1'b1;
        data_valid <= 1'b0;
    end
    else begin
        data_valid <= 1'b0;
        temp_valid <= 1'b0;
    end
end

endmodule
