module top_seg_test(
    input wire sys_clk,
    input wire sys_rst_n,
    
    output wire shcp,
    output wire stcp,
    output wire ds,
    output wire oe
);

    seg_dynamic u_seg_dynamic(
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .shcp(shcp),
        .stcp(stcp),
        .ds(ds),
        .oe(oe)
    );

endmodule
