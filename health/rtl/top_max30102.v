//****************************************Copyright (c)***********************************//
// File name: top_max30102.v
// Description: MAX30102心率血氧检测顶层模块
// Created by: Fire
// Created date: 2025-12-22
// Version: V1.0
//****************************************************************************************//

module top_max30102(
    input   wire            sys_clk     ,   // 系统时钟 50MHz
    input   wire            sys_rst_n   ,   // 复位信号，低电平有效
    
    // MAX30102接口
    inout   wire            max_scl     ,   // I2C时钟线
    inout   wire            max_sda     ,   // I2C数据线
    input   wire            max_int     ,   // 中断信号
    
    // 数码管显示接口（可选，用于显示心率数据）
    output  wire            shcp        ,   // 74HC595移位时钟
    output  wire            stcp        ,   // 74HC595存储时钟
    output  wire            ds          ,   // 74HC595串行数据
    output  wire            oe          ,   // 74HC595输出使能
    
    // 调试LED（可选）
    output  reg     [3:0]   led             // LED指示灯
);

// 内部信号
wire    [17:0]  red_data    ;
wire    [17:0]  ir_data     ;
wire            data_valid  ;
wire    [7:0]   temp_int    ;
wire    [3:0]   temp_frac   ;
wire            temp_valid  ;
wire            init_done   ;
wire            error       ;

// 心率计算相关信号
reg     [17:0]  ir_buf[31:0];   // IR数据缓冲区，存储32个样本
reg     [17:0]  red_buf[31:0];  // RED数据缓冲区
reg     [4:0]   buf_idx     ;   // 缓冲区索引
reg     [31:0]  sample_cnt  ;   // 样本计数
reg     [15:0]  heart_rate  ;   // 心率值
reg     [7:0]   spo2        ;   // 血氧饱和度
reg             hr_valid    ;   // 心率有效
reg     [17:0]  ir_prev     ;   // 前一个IR值
reg     [17:0]  ir_prev2    ;   // 前前一个IR值
reg     [31:0]  peak_cnt    ;   // 峰值计数
reg     [31:0]  peak_timer  ;   // 峰值计时器
reg             peak_det    ;   // 峰值检测标志

// 温度显示寄存器
reg     [7:0]   temp_display;   // 温度显示值（整数部分）

// 实例化MAX30102驱动
max30102_driver u_max30102_driver(
    .clk            (sys_clk    ),
    .rst_n          (sys_rst_n  ),
    .scl            (max_scl    ),
    .sda            (max_sda    ),
    .int_n          (max_int    ),
    .red_data       (red_data   ),
    .ir_data        (ir_data    ),
    .data_valid     (data_valid ),
    .temp_int       (temp_int   ),
    .temp_frac      (temp_frac  ),
    .temp_valid     (temp_valid ),
    .init_done      (init_done  ),
    .error          (error      )
);

// 调试计数器 - 用于LED闪烁测试
reg [25:0] debug_cnt;
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        debug_cnt <= 26'd0;
    else
        debug_cnt <= debug_cnt + 1'b1;
end

// LED状态指示
// LED0: 闪烁表示FPGA工作正常
// LED1: SCL状态 (亮=低电平/卡死, 灭=高电平)
// LED2: SDA状态 (亮=低电平/卡死, 灭=高电平)
// LED3: 初始化完成 (亮=未完成, 灭=完成)
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        led <= 4'b0000;
    else begin
        led[0] <= debug_cnt[25];     // LED0：闪烁（约1Hz）表示FPGA正常
        led[1] <= max_scl;           // LED1：监控SCL引脚电平
        led[2] <= max_sda;           // LED2：监控SDA引脚电平
        led[3] <= init_done;         // LED3：初始化状态
    end
end

// 温度显示更新
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        temp_display <= 8'd25;  // 默认25度
    else if (temp_valid)
        temp_display <= temp_int;
end

// 数据缓冲区管理和心率/SpO2计算
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        buf_idx <= 5'd0;
        sample_cnt <= 32'd0;
        ir_prev <= 18'd0;
        ir_prev2 <= 18'd0;
        peak_det <= 1'b0;
        peak_cnt <= 32'd0;
        peak_timer <= 32'd0;
        heart_rate <= 16'd0;
        spo2 <= 8'd98;  // 默认98%
        hr_valid <= 1'b0;
    end
    else if (data_valid) begin
        // 数据缓冲
        ir_buf[buf_idx] <= ir_data;
        red_buf[buf_idx] <= red_data;
        if (buf_idx == 5'd31)
            buf_idx <= 5'd0;
        else
            buf_idx <= buf_idx + 1'b1;
        
        // 峰值检测
        ir_prev2 <= ir_prev;
        ir_prev <= ir_data;
        
        if (ir_prev > ir_prev2 && ir_data < ir_prev && ir_prev > 18'd10000) begin
            peak_det <= 1'b1;
            peak_cnt <= peak_cnt + 1'b1;
        end
        else
            peak_det <= 1'b0;
        
        // 样本计数和心率计算
        if (sample_cnt >= 32'd1000) begin
            // 心率 = (峰值数 * 60) / 10秒
            heart_rate <= (peak_cnt * 16'd6);
            
            // SpO2计算：简化算法
            // R = (AC_red / DC_red) / (AC_ir / DC_ir)
            // SpO2 = 110 - 25*R (简化公式)
            // 这里使用固定值98%，实际需要复杂计算
            if (ir_data > 18'd50000 && red_data > 18'd50000)
                spo2 <= 8'd98;  // 有效信号
            else
                spo2 <= 8'd0;   // 无效信号
            
            peak_cnt <= 32'd0;
            sample_cnt <= 32'd1;  // 重置为1（包含当前样本）
            hr_valid <= 1'b1;
        end
        else begin
            sample_cnt <= sample_cnt + 1'b1;
            hr_valid <= 1'b0;
        end
        
        peak_timer <= peak_timer + 1'b1;
    end
end

// BCD转换（心率 - 用于数码管中2位显示）
wire    [3:0]   hr_bcd_ten ;   // 十位
wire    [3:0]   hr_bcd_one ;   // 个位

bin_to_bcd u_bin_to_bcd_hr(
    .bin        (heart_rate[7:0]),  // 只取低8位（0-255）
    .bcd_hun    (           ),      // 不使用百位
    .bcd_ten    (hr_bcd_ten    ),
    .bcd_one    (hr_bcd_one    )
);

// BCD转换（SpO2 - 用于数码管后2位显示）
wire    [3:0]   spo2_bcd_ten ;   // 十位
wire    [3:0]   spo2_bcd_one ;   // 个位

bin_to_bcd u_bin_to_bcd_spo2(
    .bin        (spo2          ),
    .bcd_hun    (              ),   // 不使用百位
    .bcd_ten    (spo2_bcd_ten  ),
    .bcd_one    (spo2_bcd_one  )
);

// BCD转换（温度 - 用于数码管前2位显示）
wire    [3:0]   temp_bcd_ten ;   // 十位
wire    [3:0]   temp_bcd_one ;   // 个位

assign temp_bcd_ten = (temp_display >= 8'd100) ? 4'd9 :     // 限制最大99度
                      (temp_display >= 8'd90) ? 4'd9 :
                      (temp_display >= 8'd80) ? 4'd8 :
                      (temp_display >= 8'd70) ? 4'd7 :
                      (temp_display >= 8'd60) ? 4'd6 :
                      (temp_display >= 8'd50) ? 4'd5 :
                      (temp_display >= 8'd40) ? 4'd4 :
                      (temp_display >= 8'd30) ? 4'd3 :
                      (temp_display >= 8'd20) ? 4'd2 :
                      (temp_display >= 8'd10) ? 4'd1 : 4'd0;

assign temp_bcd_one = temp_display - (temp_bcd_ten * 8'd10);

// 数码管动态扫描显示: XX.XX.XX (温度.心率.血氧)
// 格式：[Temp十][Temp个].[HR十][HR个].[SpO2十][SpO2个]
wire    [23:0]  seg_data_6;
wire    [5:0]   point_pos;  // 小数点位置

assign seg_data_6 = {
    temp_bcd_ten,   // 第6位：温度十位
    temp_bcd_one,   // 第5位：温度个位
    hr_bcd_ten,     // 第4位：心率十位
    hr_bcd_one,     // 第3位：心率个位
    spo2_bcd_ten,   // 第2位：SpO2十位
    spo2_bcd_one    // 第1位：SpO2个位
};

// 小数点位置: 第5位和第3位后面
// point[0]=第6位, point[1]=第5位, point[2]=第4位, point[3]=第3位, point[4]=第2位, point[5]=第1位
assign point_pos = 6'b001010;  // 第5位(bit1)和第3位(bit3)后面显示小数点

seg_dynamic u_seg_dynamic(
    .clk            (sys_clk        ),
    .rst_n          (sys_rst_n      ),
    .seg_data_6     (seg_data_6     ),
    .point          (point_pos      ),  // 显示小数点
    .seg_en         (1'b1           ),
    .shcp           (shcp           ),
    .stcp           (stcp           ),
    .ds             (ds             ),
    .oe             (oe             )
);

endmodule

//****************************************Copyright (c)***********************************//
// Module name: bin_to_bcd
// Description: 二进制转BCD码
//****************************************************************************************//
module bin_to_bcd(
    input   wire    [7:0]   bin         ,
    output  reg     [3:0]   bcd_hun     ,
    output  reg     [3:0]   bcd_ten     ,
    output  reg     [3:0]   bcd_one
);

integer i;

always @(*) begin
    bcd_hun = 4'd0;
    bcd_ten = 4'd0;
    bcd_one = 4'd0;
    
    for (i = 7; i >= 0; i = i - 1) begin
        // 加3算法
        if (bcd_hun >= 4'd5) bcd_hun = bcd_hun + 4'd3;
        if (bcd_ten >= 4'd5) bcd_ten = bcd_ten + 4'd3;
        if (bcd_one >= 4'd5) bcd_one = bcd_one + 4'd3;
        
        // 左移
        bcd_hun = {bcd_hun[2:0], bcd_ten[3]};
        bcd_ten = {bcd_ten[2:0], bcd_one[3]};
        bcd_one = {bcd_one[2:0], bin[i]};
    end
end

endmodule
