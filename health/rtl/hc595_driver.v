module hc595_driver(
    input wire sys_clk,
    input wire sys_rst_n,
    input wire [15:0] data,
    
    output reg shcp,
    output reg stcp,
    output reg ds
);

    parameter CNT_MAX = 5'd16;
    
    reg [4:0] cnt_bit;
    reg [15:0] data_reg;
    reg [1:0] state;
    
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            shcp <= 1'b0;
            stcp <= 1'b0;
            ds <= 1'b0;
            cnt_bit <= 5'd0;
            data_reg <= 16'd0;
            state <= 2'd0;
        end else begin
            case (state)
                2'd0: begin  // Load data
                    data_reg <= data;
                    cnt_bit <= 5'd0;
                    stcp <= 1'b0;
                    state <= 2'd1;
                end
                
                2'd1: begin  // Shift data
                    if (cnt_bit < CNT_MAX) begin
                        shcp <= 1'b0;
                        ds <= data_reg[CNT_MAX - 1 - cnt_bit];
                        state <= 2'd2;
                    end else begin
                        state <= 2'd3;
                    end
                end
                
                2'd2: begin  // Clock high
                    shcp <= 1'b1;
                    cnt_bit <= cnt_bit + 1'b1;
                    state <= 2'd1;
                end
                
                2'd3: begin  // Latch
                    shcp <= 1'b0;
                    stcp <= 1'b1;
                    state <= 2'd0;
                end
            endcase
        end
    end

endmodule
