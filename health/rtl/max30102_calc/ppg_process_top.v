module ppg_process_top
#(
    parameter DATA_WIDTH = 18
)
(
    input                       clk,
    input                       rst_n,
    
    // 输入接口
    input                       i_data_valid,   // 原始数据有效
    input      [DATA_WIDTH-1:0] i_red_data,     // 原始红光
    input      [DATA_WIDTH-1:0] i_ir_data,      // 原始红外 (预留给SpO2)
    
    // 输出接口
    output                      o_beat_pulse,   // 心跳脉冲 (用于LED指示)
    output     [7:0]            o_heart_rate,   // 心率值 (BPM) 
    output     [7:0]            o_spo2,         // 血氧值 (%) 
    output                      o_result_valid  // 结果更新有效
);

    wire signed [DATA_WIDTH-1:0] red_ac_data;
    wire signed [DATA_WIDTH-1:0] ir_ac_data;
    wire [DATA_WIDTH-1:0] red_dc_data; 
    wire [DATA_WIDTH-1:0] ir_dc_data; 
    wire                         red_filter_valid;
    wire                         ir_filter_valid;
    
    // 通道 1: 红光 (用于心率 + SpO2)
    ppg_filter #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_filter_red (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_data_valid (i_data_valid),
        .i_data       (i_red_data),
        .o_data_valid (red_filter_valid),
        .o_data       (red_ac_data),
        .o_dc_data(red_dc_data)
    );

    // 通道 2: 红外 (用于 SpO2)
    ppg_filter #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_filter_ir (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_data_valid (i_data_valid),
        .i_data       (i_ir_data),
        .o_data_valid (ir_filter_valid),
        .o_data       (ir_ac_data),
        .o_dc_data(ir_dc_data)
    );

    heart_rate_calc #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_hr_calc (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_data_valid (red_filter_valid), // 使用滤波后的 valid
        .i_ac_data    (red_ac_data),      // 使用滤波后的 AC 数据
        .o_beat_pulse (o_beat_pulse),
        .o_bpm        (o_heart_rate)      
    );

spo2_calc #(
    .DATA_WIDTH(DATA_WIDTH)
) u_spo2_calc (
    .clk          (clk),
    .rst_n        (rst_n),
    .i_data_valid (red_filter_valid),
    .i_red_ac     (red_ac_data),
    .i_red_dc     (red_dc_data),
    .i_ir_ac      (ir_ac_data),
    .i_ir_dc      (ir_dc_data),
    .i_beat_pulse (o_beat_pulse), // 使用心跳作为同步信号
    .o_spo2       (o_spo2)
);
    
    assign o_result_valid = red_filter_valid;

endmodule