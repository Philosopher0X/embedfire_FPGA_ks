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
    
    // DS18B20接口
    inout   wire            ds18b20_dq  ,   // DS18B20数据线

    // 数码管显示接口（可选，用于显示心率数据）
    output  wire            shcp        ,   // 74HC595移位时钟
    output  wire            stcp        ,   // 74HC595存储时钟
    output  wire            ds          ,   // 74HC595串行数据
    output  wire            oe          ,   // 74HC595输出使能
    //oled接口
	 output		   OLED_SCL,
	 inout			OLED_SDA,
    // 调试LED（可选）
    output  reg     [3:0]   led             // LED指示灯
);

// 内部信号
wire    [7:0]   temp_int    ;
wire    [3:0]   temp_frac   ;
wire            temp_valid  ;
wire            init_done   ;
wire            error       ;

//oled信号
wire ds18b20_done;
wire[7:0]  tempH;
wire[7:0]  tempL;

// 温度显示寄存器
reg     [7:0]   temp_display;   // 温度显示值（整数部分）

// DS18B20信号
wire    [7:0]   ds18_temp_int;
wire    [7:0]   ds18_temp_deci;

// max30102信号
wire        drv_ready;
wire        data_valid;
wire [17:0] red_data;
wire [17:0] ir_data;
// 算子层信号
wire        beat_pulse;     // 心跳脉冲
wire [7:0]  heart_rate_bpm; // 计算出的心率 (如 75)
wire [7:0]  spo2_val;       // 计算出的血氧 (如 98)
wire        result_valid;

    // 1. 实例化驱动
    max30102_driver #(
        .P_SYS_CLK(50_000_000)     // 请修改为你板子的实际时钟频率
    ) u_driver (
        .clk            (sys_clk),
        .rst_n          (sys_rst_n),
        .iic_scl        (max_scl),
        .iic_sda        (max_sda),
        .max_int        (max_int),
        .o_red_data     (red_data),
        .o_ir_data      (ir_data),
        .o_data_valid   (data_valid),
        .o_ready        (drv_ready)
    );
    ppg_process_top #(
        .DATA_WIDTH(18)
    ) u_dsp_core (
        .clk            (sys_clk),
        .rst_n          (sys_rst_n),
        .i_data_valid   (data_valid),
        .i_red_data     (red_data),
        .i_ir_data      (ir_data),
        
        .o_beat_pulse   (beat_pulse),
        .o_heart_rate   (heart_rate_bpm),
        .o_spo2         (spo2_val),
        .o_result_valid (result_valid)
    );
// 实例化DS18B20驱动
ds18b20_ctrl u_ds18b20_ctrl(
    .sys_clk    (sys_clk    ),
    .sys_rst_n  (sys_rst_n  ),
    .dq         (ds18b20_dq ),
    .temp_int   (ds18_temp_int),
    .temp_deci  (ds18_temp_deci),
	 .temp_done  (ds18b20_done)
);

OLED_Top OLED_Topds(

	.sys_clk		(sys_clk),
	.rst_n		(sys_rst_n),
	
	.sensor_done		(ds18b20_done),
	.temp_int			(ds18_temp_int),			//温度数据整数
	.temp_deci			(ds18_temp_deci),			//温度数据小数
	
	//OLED IIC
	.OLED_SCL	(OLED_SCL),
	.OLED_SDA	(OLED_SDA)
	
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
    else
        temp_display <= ds18_temp_int; // 使用DS18B20温度
end

// BCD转换（心率 - 用于数码管中2位显示）
wire    [3:0]   hr_bcd_ten ;   // 十位
wire    [3:0]   hr_bcd_one ;   // 个位

bin_to_bcd u_bin_to_bcd_hr(
    .bin        (sim_hr        ),  // 使用模拟心率数据
    .bcd_hun    (              ),  // 不使用百位
    .bcd_ten    (hr_bcd_ten    ),
    .bcd_one    (hr_bcd_one    )
);

// BCD转换（SpO2 - 用于数码管后2位显示）
wire    [3:0]   spo2_bcd_ten ;   // 十位
wire    [3:0]   spo2_bcd_one ;   // 个位

bin_to_bcd u_bin_to_bcd_spo2(
    .bin        (sim_spo2      ),  // 使用模拟血氧数据
    .bcd_hun    (              ),  // 不使用百位
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
