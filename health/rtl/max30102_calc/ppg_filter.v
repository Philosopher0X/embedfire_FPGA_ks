module ppg_filter
#(
    parameter DATA_WIDTH = 18
)
(
    input                       clk,
    input                       rst_n,
    
    // 输入接口 (来自 Driver)
    input                       i_data_valid,
    input      [DATA_WIDTH-1:0] i_data,      // 原始数据 (无符号)
    
    // 输出接口 (去噪后的 AC 数据)
    output reg                  o_data_valid,
    output reg signed [DATA_WIDTH-1:0] o_data,       // AC 数据 (有符号，以 0 为中心)
    output reg [DATA_WIDTH-1:0] o_dc_data           // DC 数据
);

    // 算法：y[n] = (x[n] + x[n-1] + x[n-2] + x[n-3]) / 4
    // 除以 4 等于右移 2 位
    
    reg [DATA_WIDTH-1:0] x0, x1, x2, x3; // 移位寄存器
    reg [DATA_WIDTH+1:0] sum_lpf;        // 和 (多2位防溢出)
    reg [DATA_WIDTH-1:0] lpf_data;       // 滤波后数据

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            x0 <= 0; x1 <= 0; x2 <= 0; x3 <= 0;
            lpf_data <= 0;
        end else if(i_data_valid) begin
            // 移位流水线
            x0 <= i_data;
            x1 <= x0;
            x2 <= x1;
            x3 <= x2;
        
            lpf_data <= (x0 + x1 + x2 + x3) >> 2; 
        end
    end

    // 算法：一阶 IIR 滤波器
    // dc_reg = dc_reg * (31/32) + input * (1/32)
    
    reg [DATA_WIDTH+8:0] dc_accumulator; // 累加器，增加了小数位(比如9位)
    wire [DATA_WIDTH-1:0] dc_val;
    
    // 取出整数部分作为当前的 DC 值
    assign dc_val = dc_accumulator[DATA_WIDTH+8 : 9]; 

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            dc_accumulator <= 0;
        end else if(i_data_valid) begin
            // 核心滤波公式
            dc_accumulator <= dc_accumulator - (dc_accumulator >> 5) + {lpf_data, 9'd0};
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            o_data <= 0;
            o_data_valid <= 0;
            o_dc_data <= 0; 
        end else if(i_data_valid) begin
            o_data_valid <= 1'b1;
            o_data <= $signed({1'b0, lpf_data}) - $signed({1'b0, dc_val});
            o_dc_data <= dc_val;
        end else begin
            o_data_valid <= 1'b0;
        end
    end

endmodule