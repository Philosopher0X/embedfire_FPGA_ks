module seg_dynamic(
    input wire clk,
    input wire rst_n,
    input wire [23:0] seg_data_6,    // 6位BCD码，每位4bit
    input wire [5:0] point,           // 小数点控制
    input wire seg_en,                // 数码管使能
    
    output wire shcp,
    output wire stcp,
    output wire ds,
    output wire oe
);

    // 1ms scan period (50MHz / 50000 = 1kHz)
    parameter CNT_1MS = 16'd50000;
    
    reg [15:0] cnt_1ms;
    reg [2:0] cnt_sel;
    reg [3:0] num;
    reg [7:0] seg_code;
    reg [7:0] sel_code;
    wire [15:0] data_595;
    
    // Counter for 1ms
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt_1ms <= 16'd0;
        else if (cnt_1ms == CNT_1MS - 1'b1)
            cnt_1ms <= 16'd0;
        else
            cnt_1ms <= cnt_1ms + 1'b1;
    end
    
    // Digit selector (0-5)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt_sel <= 3'd0;
        else if (cnt_1ms == CNT_1MS - 1'b1) begin
            if (cnt_sel == 3'd5)
                cnt_sel <= 3'd0;
            else
                cnt_sel <= cnt_sel + 1'b1;
        end
    end
    
    // Number to display from seg_data_6 (6位BCD码)
    // seg_data_6[23:20] = 第6位 (最左边)
    // seg_data_6[19:16] = 第5位
    // seg_data_6[15:12] = 第4位 
    // seg_data_6[11:8]  = 第3位
    // seg_data_6[7:4]   = 第2位
    // seg_data_6[3:0]   = 第1位 (最右边)
    always @(*) begin
        case (cnt_sel)
            3'd0: num = seg_data_6[23:20];  // 第6位
            3'd1: num = seg_data_6[19:16];  // 第5位
            3'd2: num = seg_data_6[15:12];  // 第4位
            3'd3: num = seg_data_6[11:8];   // 第3位
            3'd4: num = seg_data_6[7:4];    // 第2位
            3'd5: num = seg_data_6[3:0];    // 第1位
            default: num = 4'd0;
        endcase
    end
    
    // Segment decoder (Common Anode: 0=ON)
    // Segments: DP G F E D C B A
    // 添加小数点支持
    reg [7:0] seg_code_base;
    
    always @(*) begin
        case (num)
            4'd0: seg_code_base = 8'hC0; // 0
            4'd1: seg_code_base = 8'hF9; // 1
            4'd2: seg_code_base = 8'hA4; // 2
            4'd3: seg_code_base = 8'hB0; // 3
            4'd4: seg_code_base = 8'h99; // 4
            4'd5: seg_code_base = 8'h92; // 5
            4'd6: seg_code_base = 8'h82; // 6
            4'd7: seg_code_base = 8'hF8; // 7
            4'd8: seg_code_base = 8'h80; // 8
            4'd9: seg_code_base = 8'h90; // 9
            4'd10: seg_code_base = 8'hBF; // - (中划线)
            default: seg_code_base = 8'hFF;
        endcase
    end
    
    // 小数点控制 (DP位是bit 7，0=点亮)
    always @(*) begin
        if (seg_en && point[cnt_sel])
            seg_code = seg_code_base & 8'h7F;  // 清除DP位，点亮小数点
        else
            seg_code = seg_code_base;          // 保持原样
    end
    
    // Digit selector (Active High) - use low 6 bits
    // 使用seg_en控制是否显示
    always @(*) begin
        if (seg_en) begin
            case (cnt_sel)
                3'd0: sel_code = 8'b0000_0001;
                3'd1: sel_code = 8'b0000_0010;
                3'd2: sel_code = 8'b0000_0100;
                3'd3: sel_code = 8'b0000_1000;
                3'd4: sel_code = 8'b0001_0000;
                3'd5: sel_code = 8'b0010_0000;
                default: sel_code = 8'b0000_0000;
            endcase
        end else begin
            sel_code = 8'b0000_0000;  // 禁用所有数码管
        end
    end
    
    // Data to 74HC595: SEL[7:0], SEG[7:0]
    assign data_595 = {sel_code, seg_code};
    
    // Output enable (Active Low)
    assign oe = 1'b0;
    
    // Instantiate HC595 driver
    hc595_driver u_hc595_driver(
        .sys_clk(clk),
        .sys_rst_n(rst_n),
        .data(data_595),
        .shcp(shcp),
        .stcp(stcp),
        .ds(ds)
    );

endmodule
