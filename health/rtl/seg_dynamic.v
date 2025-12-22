module seg_dynamic(
    input wire sys_clk,
    input wire sys_rst_n,
    
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
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            cnt_1ms <= 16'd0;
        else if (cnt_1ms == CNT_1MS - 1'b1)
            cnt_1ms <= 16'd0;
        else
            cnt_1ms <= cnt_1ms + 1'b1;
    end
    
    // Digit selector (0-5)
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            cnt_sel <= 3'd0;
        else if (cnt_1ms == CNT_1MS - 1'b1) begin
            if (cnt_sel == 3'd5)
                cnt_sel <= 3'd0;
            else
                cnt_sel <= cnt_sel + 1'b1;
        end
    end
    
    // Number to display (test pattern: 123456)
    always @(*) begin
        case (cnt_sel)
            3'd0: num = 4'd1;
            3'd1: num = 4'd2;
            3'd2: num = 4'd3;
            3'd3: num = 4'd4;
            3'd4: num = 4'd5;
            3'd5: num = 4'd6;
            default: num = 4'd0;
        endcase
    end
    
    // Segment decoder (Common Anode: 0=ON)
    // Segments: DP G F E D C B A
    always @(*) begin
        case (num)
            4'd0: seg_code = 8'hC0; // 0
            4'd1: seg_code = 8'hF9; // 1
            4'd2: seg_code = 8'hA4; // 2
            4'd3: seg_code = 8'hB0; // 3
            4'd4: seg_code = 8'h99; // 4
            4'd5: seg_code = 8'h92; // 5
            4'd6: seg_code = 8'h82; // 6
            4'd7: seg_code = 8'hF8; // 7
            4'd8: seg_code = 8'h80; // 8
            4'd9: seg_code = 8'h90; // 9
            default: seg_code = 8'hFF;
        endcase
    end
    
    // Digit selector (Active High) - use low 6 bits
    always @(*) begin
        case (cnt_sel)
            3'd0: sel_code = 8'b0000_0001;
            3'd1: sel_code = 8'b0000_0010;
            3'd2: sel_code = 8'b0000_0100;
            3'd3: sel_code = 8'b0000_1000;
            3'd4: sel_code = 8'b0001_0000;
            3'd5: sel_code = 8'b0010_0000;
            default: sel_code = 8'b0000_0000;
        endcase
    end
    
    // Data to 74HC595: SEL[7:0], SEG[7:0]
    assign data_595 = {sel_code, seg_code};
    
    // Output enable (Active Low)
    assign oe = 1'b0;
    
    // Instantiate HC595 driver
    hc595_driver u_hc595_driver(
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .data(data_595),
        .shcp(shcp),
        .stcp(stcp),
        .ds(ds)
    );

endmodule
