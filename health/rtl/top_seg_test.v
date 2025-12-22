module top_seg_test(
    input wire sys_clk,
    input wire sys_rst_n,
    inout wire dht11_data,
    
    output wire shcp,
    output wire stcp,
    output wire ds,
    output wire oe
);

    wire [7:0] temp_int;
    wire [7:0] temp_deci;

    // DS18B20温度传感器控制模块
    ds18b20_ctrl u_dht11_ctrl(
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .dq(dht11_data),
        .temp_int(temp_int),
        .temp_deci(temp_deci)
    );

    // 数码管动态扫描显示模块
    seg_dynamic u_seg_dynamic(
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .temp_int(temp_int),
        .temp_deci(temp_deci),
        .shcp(shcp),
        .stcp(stcp),
        .ds(ds),
        .oe(oe)
    );

endmodule
