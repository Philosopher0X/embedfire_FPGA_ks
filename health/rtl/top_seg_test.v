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
    wire [7:0] humi_int;
    wire [7:0] humi_deci;
    wire dht11_valid;

    // DHT11温湿度传感器控制模块
    dht11_ctrl u_dht11_ctrl(
        .sys_clk(sys_clk),
        .sys_rst_n(sys_rst_n),
        .dht11_data(dht11_data),
        .temp_int(temp_int),
        .temp_deci(temp_deci),
        .humi_int(humi_int),
        .humi_deci(humi_deci),
        .dht11_valid(dht11_valid)
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
