//****************************************Copyright (c)***********************************//
// File name: i2c_master.v
// Description: I2C主控制器，支持写一个字节、读一个字节、读多个字节
// Created by: Fire
// Created date: 2025-12-22
// Version: V1.0
//****************************************************************************************//

module i2c_master(
    input   wire            clk         ,   // 系统时钟 50MHz
    input   wire            rst_n       ,   // 复位信号，低电平有效
    
    // I2C接口
    input   wire            scl_in      ,   // SCL输入（用于检测）
    output  reg             scl_out     ,   // SCL输出
    output  reg             scl_oe      ,   // SCL输出使能，0=输入，1=输出
    input   wire            sda_in      ,   // SDA输入
    output  reg             sda_out     ,   // SDA输出
    output  reg             sda_oe      ,   // SDA输出使能，0=输入，1=输出
    
    // 控制接口
    input   wire            start       ,   // 启动信号
    input   wire    [1:0]   cmd         ,   // 命令: 00=写字节, 01=读字节, 10=读多字节
    input   wire    [6:0]   slave_addr  ,   // 从机地址（7位）
    input   wire    [7:0]   reg_addr    ,   // 寄存器地址
    input   wire    [7:0]   wr_data     ,   // 写入数据
    input   wire    [7:0]   rd_num      ,   // 读取字节数（用于读多字节）
    
    output  reg     [7:0]   rd_data     ,   // 读取的数据
    output  reg             rd_valid    ,   // 读数据有效
    output  reg             busy        ,   // 忙标志
    output  reg             done        ,   // 完成标志
    output  reg             ack_error       // ACK错误标志
);

// I2C时序参数（100kHz SCL，50MHz系统时钟）
parameter   CLK_DIV = 250;  // 50MHz / 250 = 200kHz, SCL翻转频率为100kHz

// 命令定义
localparam  CMD_WRITE   = 2'b00;
localparam  CMD_READ    = 2'b01;
localparam  CMD_READ_N  = 2'b10;

// 状态机定义
localparam  IDLE        = 5'd0 ;
localparam  START       = 5'd1 ;
localparam  ADDR_WR     = 5'd2 ;
localparam  ACK1        = 5'd3 ;
localparam  REG_ADDR    = 5'd4 ;
localparam  ACK2        = 5'd5 ;
localparam  WR_DATA     = 5'd6 ;
localparam  ACK3        = 5'd7 ;
localparam  RESTART     = 5'd8 ;
localparam  ADDR_RD     = 5'd9 ;
localparam  ACK4        = 5'd10;
localparam  RD_DATA     = 5'd11;
localparam  MACK        = 5'd12;
localparam  MNACK       = 5'd13;
localparam  STOP        = 5'd14;

reg     [4:0]   state       ;
reg     [4:0]   next_state  ;
reg     [8:0]   clk_cnt     ;
reg             clk_en      ;
reg     [3:0]   bit_cnt     ;
reg     [7:0]   rd_buf      ;
reg     [7:0]   rd_cnt      ;
reg     [1:0]   cmd_reg     ;
reg     [7:0]   rd_num_reg  ;
reg     [7:0]   addr_wr_byte;   // 写地址字节
reg     [7:0]   addr_rd_byte;   // 读地址字节

// 时钟分频计数器
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        clk_cnt <= 9'd0;
    else if (state == IDLE)
        clk_cnt <= 9'd0;
    else if (clk_cnt == CLK_DIV - 1)
        clk_cnt <= 9'd0;
    else
        clk_cnt <= clk_cnt + 1'b1;
end

// 时钟使能信号
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        clk_en <= 1'b0;
    else if (clk_cnt == CLK_DIV/4 - 1 || clk_cnt == CLK_DIV*3/4 - 1)
        clk_en <= 1'b1;
    else
        clk_en <= 1'b0;
end

// 状态机 - 第一段：状态跳转
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

// 状态机 - 第二段：状态转移条件
always @(*) begin
    case (state)
        IDLE: begin
            if (start)
                next_state = START;
            else
                next_state = IDLE;
        end
        
        START: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = ADDR_WR;
            else
                next_state = START;
        end
        
        ADDR_WR: begin
            if (clk_en && bit_cnt == 4'd8)
                next_state = ACK1;
            else
                next_state = ADDR_WR;
        end
        
        ACK1: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = REG_ADDR;
            else
                next_state = ACK1;
        end
        
        REG_ADDR: begin
            if (clk_en && bit_cnt == 4'd8)
                next_state = ACK2;
            else
                next_state = REG_ADDR;
        end
        
        ACK2: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1) begin
                if (cmd_reg == CMD_WRITE)
                    next_state = WR_DATA;
                else
                    next_state = RESTART;
            end
            else
                next_state = ACK2;
        end
        
        WR_DATA: begin
            if (clk_en && bit_cnt == 4'd8)
                next_state = ACK3;
            else
                next_state = WR_DATA;
        end
        
        ACK3: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = STOP;
            else
                next_state = ACK3;
        end
        
        RESTART: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = ADDR_RD;
            else
                next_state = RESTART;
        end
        
        ADDR_RD: begin
            if (clk_en && bit_cnt == 4'd8)
                next_state = ACK4;
            else
                next_state = ADDR_RD;
        end
        
        ACK4: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = RD_DATA;
            else
                next_state = ACK4;
        end
        
        RD_DATA: begin
            if (clk_en && bit_cnt == 4'd8) begin
                if (cmd_reg == CMD_READ_N && rd_cnt < rd_num_reg - 1)
                    next_state = MACK;
                else
                    next_state = MNACK;
            end
            else
                next_state = RD_DATA;
        end
        
        MACK: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = RD_DATA;
            else
                next_state = MACK;
        end
        
        MNACK: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = STOP;
            else
                next_state = MNACK;
        end
        
        STOP: begin
            if (clk_en && clk_cnt == CLK_DIV*3/4 - 1)
                next_state = IDLE;
            else
                next_state = STOP;
        end
        
        default: next_state = IDLE;
    endcase
end

// 状态机 - 第三段：输出控制
// SCL控制
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scl_out <= 1'b1;
        scl_oe <= 1'b0;
    end
    else begin
        case (state)
            IDLE: begin
                scl_out <= 1'b1;
                scl_oe <= 1'b0;
            end
            
            START: begin
                scl_oe <= 1'b1;
                if (clk_cnt < CLK_DIV/2)
                    scl_out <= 1'b1;
                else
                    scl_out <= 1'b0;
            end
            
            STOP: begin
                scl_oe <= 1'b1;
                if (clk_cnt < CLK_DIV/2)
                    scl_out <= 1'b0;
                else
                    scl_out <= 1'b1;
            end
            
            default: begin
                scl_oe <= 1'b1;
                if (clk_cnt < CLK_DIV/2)
                    scl_out <= 1'b0;
                else
                    scl_out <= 1'b1;
            end
        endcase
    end
end

// SDA控制
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sda_out <= 1'b1;
        sda_oe <= 1'b0;
        bit_cnt <= 4'd0;
        rd_buf <= 8'd0;
        rd_cnt <= 8'd0;
        addr_wr_byte <= 8'd0;
        addr_rd_byte <= 8'd0;
    end
    else begin
        // 预先计算地址字节
        addr_wr_byte <= {slave_addr, 1'b0};
        addr_rd_byte <= {slave_addr, 1'b1};
        
        case (state)
            IDLE: begin
                sda_out <= 1'b1;
                sda_oe <= 1'b0;
                bit_cnt <= 4'd0;
                rd_cnt <= 8'd0;
            end
            
            START: begin
                sda_oe <= 1'b1;
                if (clk_cnt < CLK_DIV/4)
                    sda_out <= 1'b1;
                else
                    sda_out <= 1'b0;
                bit_cnt <= 4'd0;
            end
            
            ADDR_WR: begin
                sda_oe <= 1'b1;
                if (clk_en && clk_cnt == CLK_DIV/4 - 1) begin
                    sda_out <= addr_wr_byte[7 - bit_cnt];
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
            
            ACK1, ACK2, ACK3, ACK4: begin
                sda_oe <= 1'b0;  // 释放SDA，读取ACK
                bit_cnt <= 4'd0;
            end
            
            REG_ADDR: begin
                sda_oe <= 1'b1;
                if (clk_en && clk_cnt == CLK_DIV/4 - 1) begin
                    sda_out <= reg_addr[7 - bit_cnt];
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
            
            WR_DATA: begin
                sda_oe <= 1'b1;
                if (clk_en && clk_cnt == CLK_DIV/4 - 1) begin
                    sda_out <= wr_data[7 - bit_cnt];
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
            
            RESTART: begin
                sda_oe <= 1'b1;
                if (clk_cnt < CLK_DIV/4)
                    sda_out <= 1'b1;
                else
                    sda_out <= 1'b0;
                bit_cnt <= 4'd0;
            end
            
            ADDR_RD: begin
                sda_oe <= 1'b1;
                if (clk_en && clk_cnt == CLK_DIV/4 - 1) begin
                    sda_out <= addr_rd_byte[7 - bit_cnt];
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
            
            RD_DATA: begin
                sda_oe <= 1'b0;  // 释放SDA，读取数据
                if (clk_en && clk_cnt == CLK_DIV*3/4 - 1) begin
                    rd_buf <= {rd_buf[6:0], sda_in};
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
            
            MACK: begin
                sda_oe <= 1'b1;
                sda_out <= 1'b0;  // 主机应答
                bit_cnt <= 4'd0;
                rd_cnt <= rd_cnt + 1'b1;
            end
            
            MNACK: begin
                sda_oe <= 1'b1;
                sda_out <= 1'b1;  // 主机不应答
                bit_cnt <= 4'd0;
            end
            
            STOP: begin
                sda_oe <= 1'b1;
                if (clk_cnt < CLK_DIV/2)
                    sda_out <= 1'b0;
                else
                    sda_out <= 1'b1;
            end
            
            default: begin
                sda_oe <= 1'b0;
            end
        endcase
    end
end

// busy信号
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        busy <= 1'b0;
    else if (start && state == IDLE)
        busy <= 1'b1;
    else if (state == STOP && next_state == IDLE)
        busy <= 1'b0;
end

// done信号
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        done <= 1'b0;
    else if (state == STOP && next_state == IDLE)
        done <= 1'b1;
    else
        done <= 1'b0;
end

// 读数据输出
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_data <= 8'd0;
        rd_valid <= 1'b0;
    end
    else if (state == RD_DATA && next_state == MACK) begin
        rd_data <= rd_buf;
        rd_valid <= 1'b1;
    end
    else if (state == RD_DATA && next_state == MNACK) begin
        rd_data <= rd_buf;
        rd_valid <= 1'b1;
    end
    else begin
        rd_valid <= 1'b0;
    end
end

// ACK错误检测
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        ack_error <= 1'b0;
    else if (state == IDLE)
        ack_error <= 1'b0;
    else if ((state == ACK1 || state == ACK2 || state == ACK3 || state == ACK4) 
             && clk_cnt == CLK_DIV*3/4 - 1 && sda_in == 1'b1)
        ack_error <= 1'b1;
end

// 保存命令和读取字节数
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cmd_reg <= 2'd0;
        rd_num_reg <= 8'd0;
    end
    else if (start && state == IDLE) begin
        cmd_reg <= cmd;
        rd_num_reg <= rd_num;
    end
end

endmodule
