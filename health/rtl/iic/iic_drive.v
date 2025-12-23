/*  IIC多字节读写 底层驱动模块
    一.模块功能：
    1.支持操作数据寄存器地址长度可变（支持不发送器件地址） 
    2.支持传输数据字节数长度可变    
    3.支持突发页读，写操作

    二.模块说明：
    1.写、读操作数据传输的顺序 高字节->低字节 高位->低位
    2.参数定义的IIC_SCL速率 用户可按照IIC器件数据手册声明
    3.突发页读、写操作时 参数定义的DATA_BYTE_NUM 不可超过器件的页字节数

    三.其他附录：
    1.IIC协议速率规定：
        标准模式 100kb/s
        快速模式 400kb/s
        增强模式 1Mb/s
        高速模式 3.4Mb/s
        极速模式 5Mb/s
    2.AT24C02 是 2Kbit（256 字节）的 EEPROM，内部划分为 32 页，每页 8 字节
    3.EEPROM(电可擦除可编程只读存储器)在写入前需要进行擦写 (AT24C02 的写入操作无需用户主动擦除)
*/

module iic_drive
#(
    parameter                                P_SYS_CLK         = 28'd50_000_000 ,  //系统时钟频率
    parameter                                P_IIC_SCL         = 28'd400_000    ,  //IIC SCL时钟频率 
    parameter                                P_DEVICE_ADDR     = 7 'b1010_100   ,  //IIC从设备 器件地址(电位器器件地址:1010_100)
    parameter                                P_ADDR_BYTE_NUM   = 8 'd1          ,  //IIC从设备 数据地址字节数
    parameter                                P_MAX_DATA_BYTE_NUM = 8'd6              //总线最大位宽
)
(
    input                                    iic_clk                            ,
    input                                    iic_rst                            ,
//IIC传输启动
    input                                    iic_start                          ,   //读写操作开始信号     0:     1:开始
    output reg                               iic_ready                          ,   //设备忙、闲指示信号   0:繁忙  1:空闲
    input                                    iic_rw_flag                        ,   //读写标志信号         0:写    1：读 
	 input                             [3:0]  iic_byte_num,      // 本次传输的字节数 (1 ~ P_MAX_DATA_BYTE_NUM)
//IIC写数据 
    input         [P_ADDR_BYTE_NUM*8 -1 :0]  iic_word_addr                      ,   //读写的数据地址       
    input         [P_MAX_DATA_BYTE_NUM*8 -1 :0]  iic_wdata                          ,   //写的数据 (先写高字节数据的高位)   
//IIC读数据 
    output reg    [P_MAX_DATA_BYTE_NUM*8 -1 :0]  iic_rdata                          ,   //读的数据 (先读高字节数据的高位) 
    output reg                               iic_rdata_valid                    ,   //读数据有效信号       0:无效    1:有效
//IIC操作失败   
    output reg                               iic_ack_error                      ,   //应答失败信号         0:应答正常 1:应答失败
//IIC物理IO 
    output reg                               iic_scl                            ,   //IIC SCL 
    inout                                    iic_sda                                //IIC SDA
);

/**********************激活，忙碌空闲信号***************************/
wire                                active                       ; //传输激活信号
/*******************读写控制、数据地址、写入数据 寄存****************/
reg                                 iic_rw_flag_reg              ; //读写控制位 寄存
reg [P_ADDR_BYTE_NUM*8 -1 :0]       word_addr_reg                ; //数据地址   寄存
reg [P_MAX_DATA_BYTE_NUM*8 -1 :0]       wdata_reg                    ; //写的数据   寄存
/*****************状态机编码  状态机跳转条件组合逻辑 ****************/
reg                [   6: 0]        iic_state                    ; //状态机状态
//状态机状态编码（独热码）
localparam IDLE                 =   7'b0000_001                  ; //空闲
localparam START_DEVICE_ADDR    =   7'b0000_010                  ; //起始位 器件地址 写标志
localparam W_WORD_ADDR          =   7'b0000_100                  ; //写数据地址  
localparam W_DATA               =   7'b0001_000                  ; //写数据
localparam R_START_DEVICE_ADDR  =   7'b0010_000                  ; //起始位 器件地址 读标志
localparam R_DATA               =   7'b0100_000                  ; //读数据
localparam STOP                 =   7'b1000_000                  ; //结束
/**************辅助SCL时钟生成 & 辅助SDA数据更新与读写 的重要计数器，标志信号 ************(和SCL时钟相关)**********/
localparam SCL_CNT_MAX          =   P_SYS_CLK / P_IIC_SCL  - 1'b1; //计算计数器cnt_scl的最大值
reg                [  11: 0]        cnt_scl                      ; //分频计数器 用于生成 IIC_SCL信号

reg                                 scl_nedge_flag               ; //SCL下降沿
reg                                 scl_pedge_flag               ; //SCL上升沿
reg                                 w_sda_flag                   ; //SDA写标志 
reg                                 r_sda_flag                   ; //SDA读标志

/************************发送数据位计数器 & 更新每个状态下数据位的最大值***********（和SDA数据相关）**************/
reg                [   3: 0]        bit_cnt                      ; //传输的bit计数器 
reg                [   3: 0]        bit_cnt_num                  ; //传输的bit计数器 最大值
wire                                end_bit_flag                 ; //传输最后一位完成指示信号
//最后一位传输完成 指示
assign          end_bit_flag  = (bit_cnt == bit_cnt_num - 1) && (cnt_scl == SCL_CNT_MAX); 
                                
/*************************发送字节计数器 & 更新每个状态下字节数最大值************（用于解决 数据地址，读写传输数据，字节数可变的问题）************/
reg                [   7: 0]        byte_cnt                     ; //传输的byte计数器
reg                [   7: 0]        byte_cnt_num                 ; //传输的byte计数器 最大值
wire                                add_byte_flag                ; //多字节传输状态 字节加 指示信号
wire                                end_byte_flag                ; //多字节传输状态 数据传输完成 指示信号

//多字节传输状态 字节加 指示
assign          add_byte_flag = ((iic_state == W_WORD_ADDR)||(iic_state == W_DATA )||(iic_state == R_DATA))&& (end_bit_flag);
//多字节传输状态 数据传输完成 指示
assign          end_byte_flag = (add_byte_flag) && (byte_cnt == byte_cnt_num - 1'b1) ; 
/**************************************IIC-SDA数据的切换与采集 ***********************************/
wire               [   8: 0]        start_divice_write           ; // 起始位 器件地址 写位
wire               [   8: 0]        start_divice_read            ; // 起始位 器件地址 读位
//
assign                              start_divice_write         = {1'b0,P_DEVICE_ADDR,1'b0}; //用于 开始 器件地址 写传输
assign                              start_divice_read          = {1'b0,P_DEVICE_ADDR,1'b1}; //用于 开始 器件地址 读传输
/***********************************SDA输出，输入模式 切换****************************************/
reg                                 sda_ctrl                     ; //三态门 控制端口 1输出 0输入
reg                                 sda_out                      ; //三态门 输出
wire                                sda_in                       ; //三态门 输入
//SDA端口 三态门实现
assign sda_in            = !sda_ctrl ?  iic_sda : 1'b1           ; //三态门输入
assign iic_sda           =  sda_ctrl ?  sda_out : 1'bz           ; //三态门输出
/****************************************主机接收从机数据**************************************/
reg [P_MAX_DATA_BYTE_NUM*8 -1 :0]       rdata_reg                    ; //读的数据
reg                                 rdata_valid_reg              ; //读数据有效信号 高电平有效

/**********************激活，忙碌空闲信号******************************/
assign  active = iic_start && iic_ready;   //外部输入开始 && 设备空闲 激活开始传输操作

//iic_ready 模块空闲忙碌指示信号
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        iic_ready <= 1'b1;      //复位 空闲
    else if(active)             //接收到 激活信号 忙碌
        iic_ready <= 1'b0;
    else if(iic_state == IDLE)  //回到空闲状态
        iic_ready <= 1'b1;
    else 
        iic_ready <= iic_ready;
end

/*******************读写控制、数据地址、写入数据 寄存********************/

reg                     [3:0]       current_byte_num_reg;
//开始信号有效时，寄存输入端口的数据
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)begin
        iic_rw_flag_reg     <= 'd0;
        word_addr_reg       <= 'd0;
        wdata_reg           <= 'd0;
		  current_byte_num_reg<= 'd0;
    end
    else if(active)begin
        iic_rw_flag_reg     <= iic_rw_flag   ;   //读写控制位 寄存
        word_addr_reg       <= iic_word_addr ;   //数据地址   寄存
        wdata_reg           <= iic_wdata     ;   //写的数据   寄存  
        current_byte_num_reg <= iic_byte_num;         
    end
    else begin
        iic_rw_flag_reg     <= iic_rw_flag_reg ;
        word_addr_reg       <= word_addr_reg   ;
        wdata_reg           <= wdata_reg       ;
    end
end

/**************** 状态机编码  状态机跳转条件组合逻辑 ********************/

//二段式状态机 第一段状态跳转 
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)begin
        iic_state <= IDLE;
    end
    else begin
        case(iic_state)
            IDLE :begin
                if(active)                                             //激活信号有效时，跳转到 发送 起始位 + 写器件地址 + 写标志位 状态
                    iic_state <= START_DEVICE_ADDR;
                else 
                    iic_state <= iic_state;
            end
            START_DEVICE_ADDR:begin 
                if( (end_bit_flag)  && (P_ADDR_BYTE_NUM != 0))          //起始位 + 写器件地址 + 写标志位(10bit) 发送完成后，跳转到 写数据地址 状态  
                    iic_state <= W_WORD_ADDR;
                else if((end_bit_flag) && (P_ADDR_BYTE_NUM == 0))
                    iic_state <= W_DATA;
                else 
                    iic_state <= iic_state;
            end
            W_WORD_ADDR:begin
                if( (end_byte_flag) && (iic_rw_flag_reg == 1'b0) )      //数据地址(8bit) 发送完成后 如果是写操作， 跳转到 写数据 状态
                    iic_state <= W_DATA;
                else if( (end_byte_flag) && (iic_rw_flag_reg == 1'b1) ) //数据地址 发送完成后 如果是读操作，跳转到 起始位 + 写器件地址 + 读标志位 状态
                    iic_state <= R_START_DEVICE_ADDR;
                else 
                    iic_state <= iic_state;
            end
            W_DATA:begin
                if( end_byte_flag )                                    //数据 全部发送完成后，跳到停止状态
                    iic_state <= STOP;
                else 
                    iic_state <= iic_state;
            end
            R_START_DEVICE_ADDR:begin
                if( end_bit_flag )                                     //起始位 + 器件地址 + 读指示(共10bit) 写入完成，跳转到 读数据 状态 
                    iic_state <= R_DATA;
                else 
                    iic_state <= iic_state;    
            end
            R_DATA:begin
                if( end_byte_flag )
                    iic_state <= STOP;                                //所有数据读取完成，跳转到 停止 状态
                else 
                    iic_state <= iic_state;
            end
            STOP:begin 
                if(cnt_scl == SCL_CNT_MAX)                            //停止位(1bit) 发送完成后，跳转到 空闲 状态 
                    iic_state <= IDLE;
                else
                    iic_state <= iic_state;
            end
            default:iic_state <= IDLE;
        endcase
    end
end

always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        cnt_scl <= 'd0;
    else if((iic_state == IDLE))    //空闲状态 计数器值为零
        cnt_scl <= 'd0;
    else if(cnt_scl == SCL_CNT_MAX) //不是空闲状态时 计数器计到最大值 清零
        cnt_scl <= 'd0;
    else
        cnt_scl <= cnt_scl + 1'b1;
end


//根据cnt_scl计数器的值 生成各种标志信号
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)begin
        scl_nedge_flag  <= 'd0;
        scl_pedge_flag  <= 'd0;
        w_sda_flag      <= 'd0;
        r_sda_flag      <= 'd0;
    end
    else if (iic_state == IDLE)begin
        scl_nedge_flag  <= 'd0;      //cnt_scl计数到 0  时 SCL拉低
        scl_pedge_flag  <= 'd0;      //cnt_scl计数到一半时 SCL拉高
        w_sda_flag      <= 'd0;      //cnt_scl计数到 1/4 处 SDA 写入数据
        r_sda_flag      <= 'd0;      //cnt_scl计数到 3/4 处 SDA 读取数据
    end
    else begin
        scl_nedge_flag  <= (cnt_scl == 0                       );  //cnt_scl计数到 0  时 SCL拉低
        scl_pedge_flag  <= (cnt_scl == SCL_CNT_MAX / 2         );  //cnt_scl计数到一半时 SCL拉高
        w_sda_flag      <= (cnt_scl == SCL_CNT_MAX / 4         );  //cnt_scl计数到 1/4 处 SDA 写入数据
        r_sda_flag      <= (cnt_scl == SCL_CNT_MAX * 3 / 4     );  //cnt_scl计数到 3/4 处 SDA 读取数据
    end
end


/************************数据位计数器 & 更新每个状态下数据位的最大值***********（和SDA数据相关）********/
//bit_cnt 数据位计数器 ，当分频计数器计数结束时加一
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        bit_cnt <= 'd0;
    else if(iic_state == IDLE)
        bit_cnt <= 'd0;
    else if( (bit_cnt == bit_cnt_num - 1) && (cnt_scl == SCL_CNT_MAX) ) //当前状态下 最后一位传输完成 位计数器清零
        bit_cnt <= 'd0;
    else if(cnt_scl == SCL_CNT_MAX) //当分频计数器计数到最大值时 代表1位传输完成 位计数器加1
        bit_cnt <= bit_cnt + 1'b1;
    else 
        bit_cnt <= bit_cnt;
end

//用于表示每个状态每次发送的数据位数，发送器件地址之前需要发送起始位，在加上应答位，需要 10 个 SCL时钟。
//其余状态每次发送一字节数据后需要发送应答位，所以计数器最大值为9。
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        bit_cnt_num <= 'd9;
    else if((iic_state == START_DEVICE_ADDR) || (iic_state == R_START_DEVICE_ADDR)) //起始位 + 写器件地址 + 读/写位 + 应答位 = 10bit 
        bit_cnt_num <= 'd10;
    else
        bit_cnt_num <= 'd9;      //8位 + 1位应答位 = 9bit
end

/*************************字节计数器 & 更新每个状态下字节数最大值************（用于解决 数据地址，读写传输数据，字节数可变的问题）************/
//byte_cnt 字节计数器，用于计数 数据传输中的 字节数
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        byte_cnt <= 'd0;
    else if(iic_state == IDLE)
        byte_cnt <= 'd0;
    else if( end_byte_flag )
        byte_cnt <= 'd0;
    else if( add_byte_flag)
        byte_cnt <= byte_cnt + 1'b1;
    else 
        byte_cnt <= byte_cnt;
end

//byte_cnt_num 传输字节计数器最大值
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        byte_cnt_num <= 'd0 ;    
    else if(iic_state == W_WORD_ADDR) 
        byte_cnt_num <= P_ADDR_BYTE_NUM ;
    else if((iic_state == W_DATA) || (iic_state == R_DATA))
        byte_cnt_num <= current_byte_num_reg ;
    else 
        byte_cnt_num <= byte_cnt_num;
end

/************************************IIC-SCL时钟的生成******************************************/
//iic_scl 生成串行时钟信号 
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        iic_scl <= 1'b1;                             
    else if(scl_pedge_flag || iic_state == IDLE)    //空闲状态 || 拉高条件有效 SCL=1
        iic_scl <= 1'b1;
    else if( (((iic_state == START_DEVICE_ADDR) && (bit_cnt > 0)) || (iic_state != START_DEVICE_ADDR)) && scl_nedge_flag ) //发送起始位时不拉低 其余情况满足拉低条件都拉低
        iic_scl <= 1'b0; 
    else 
        iic_scl <= iic_scl;
end

/**************************************IIC-SDA数据的切换与采集 ***********************************/
//控制iic_SDA数据输出
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
         sda_out <= 1'b1;
    else begin
        case(iic_state)
            IDLE: sda_out <= 1'b1;
            START_DEVICE_ADDR:begin 
                if( (bit_cnt < 9) && (w_sda_flag) )  //发送9位 起始位(1bit) + 写器件地址(7bit) + 写标志位(1bit) 发送完成后，跳转到 写数据地址 状态 (应答位主机不用发送) 
                    sda_out <= start_divice_write[8 - bit_cnt];
                else 
                    sda_out <= sda_out;
            end
            W_WORD_ADDR:begin
                if( (bit_cnt < 8) && (w_sda_flag) ) //发送8位*N 需要写入的寄存器地址
                    sda_out <= word_addr_reg[P_ADDR_BYTE_NUM*8 -1 - (byte_cnt*8) -  bit_cnt];
                else 
                    sda_out <= sda_out;
            end
            W_DATA:begin  
                if( (bit_cnt < 8) && (w_sda_flag) ) //发送8位*N 输出写入的数据 先输出高字节数据
                    sda_out <= wdata_reg[P_MAX_DATA_BYTE_NUM*8 -1 - (byte_cnt*8) - bit_cnt];
                else 
                    sda_out <= sda_out;
            end
            R_START_DEVICE_ADDR:begin
                if( ((bit_cnt == 0) || (bit_cnt == bit_cnt_num - 2)) && (w_sda_flag) ) //（1.第1位的起始位 便于后面高电平期间拉低 2.倒数第2位的写数据位 便于后面高电平期间正常读取）
                    sda_out <= 1'b1;
                else if(w_sda_flag)  
                    sda_out <= start_divice_read[8 - bit_cnt];  //发送起始位之后 发送中间的7位器件地址位
                else if((r_sda_flag) && (bit_cnt == 0))         //SCL的高电平期间 产生下降沿 再次发送起始位
                    sda_out <= 1'b0;
                else 
                    sda_out <= sda_out;
            end
            R_DATA:begin
                if( (byte_cnt == P_MAX_DATA_BYTE_NUM - 1) && ((bit_cnt == bit_cnt_num - 1) && (w_sda_flag)) )
                    sda_out <= 1'b1;
                else if(((bit_cnt == bit_cnt_num - 1) && (w_sda_flag))) 
                    sda_out <= 1'b0;
                else
                    sda_out <= sda_out;
            end
            STOP:begin 
                if(w_sda_flag)         //在最后一个完整时钟周期内 停止信号 写数据期间 需要先拉低 (让后面SDA可以产生下降沿) 
                    sda_out <= 1'b0; 
                else if(r_sda_flag)    //在最后一个完成时钟周期内 停止信号 读数据器件 需要拉高 （在SCL高电平期间 产生上升沿）
                    sda_out <= 1'b1;
                else 
                    sda_out <= sda_out;
            end
            default:sda_out <= sda_out;
        endcase
    end
end

/***********************************SDA输出，输入模式 切换****************************************/
//sda_ctrl 主机接收从机数据 && 主机对从机进行应答  sda_ctrl= 1'b0 
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        sda_ctrl <= 1'b1;
    else begin
        case(iic_state) 
            START_DEVICE_ADDR,R_START_DEVICE_ADDR,W_WORD_ADDR,W_DATA:begin
                if((w_sda_flag) && (bit_cnt == 0))      //bit计数器为0时，总线拉高，开始写入下一字节数据，主机控制SDA，进行输出
                    sda_ctrl <= 1'b1;  
                else if((w_sda_flag) && (bit_cnt == bit_cnt_num - 1))   //当写入最后一位数据时，从机控制SDA，进行应答输入
                    sda_ctrl <= 1'b0;
            end
            R_DATA:begin
                if((w_sda_flag) && (bit_cnt == 0))      //读取数据阶段，开始接收数据时，从机控制SDA，进行数据输入
                    sda_ctrl <= 1'b0;
                else if((w_sda_flag) && (bit_cnt == bit_cnt_num - 1))   //读取数据阶段 主机控制SDA，进行应答输出
                    sda_ctrl <= 1'b1; 
            end
            STOP:begin  
                if((w_sda_flag) && (bit_cnt == 0))      //停止状态，主机控制SDA，进行数据输出
                    sda_ctrl <= 1'b1; 
                else 
                    sda_ctrl <= sda_ctrl;
            end
            default:sda_ctrl <= sda_ctrl;
        endcase
    end 
end

/****************************************主机接收从机数据**************************************/
//rdata_reg 对从机输入数据寄存
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        rdata_reg <= 'd0;
    else if((iic_state == R_DATA) && (r_sda_flag) && (bit_cnt < 'd8)) 
        rdata_reg[P_MAX_DATA_BYTE_NUM*8 -1 - (byte_cnt*8) - bit_cnt] <= sda_in;
    else 
        rdata_reg <= rdata_reg;
end

//rdata_valid_reg 接收从机数据有效信号
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        rdata_valid_reg <= 'd0;
    else if((iic_state == R_DATA) && (byte_cnt ==  P_MAX_DATA_BYTE_NUM - 1) && (r_sda_flag) && (bit_cnt == bit_cnt_num - 2)) 
        rdata_valid_reg <= 1'b1;
    else 
        rdata_valid_reg <= 1'b0;
end

//将读取的数据取出
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)begin
        iic_rdata        <= 'd0;
        iic_rdata_valid  <= 'd0;
    end
    else begin
        iic_rdata        <= rdata_reg;
        iic_rdata_valid  <= rdata_valid_reg;
    end
end

/**********************************应答失败指示信号****************************/
//ack_error 从机应答错误信号,输出高电平 用于指示从机应答有错误
always@(posedge iic_clk or posedge iic_rst)begin
    if(iic_rst)
        iic_ack_error <= 1'b0;
    else if(active) 
        iic_ack_error <= 1'b0;  
    else if( ((iic_state == START_DEVICE_ADDR)  ||
              (iic_state == W_WORD_ADDR  )  ||
              (iic_state == W_DATA       )  ||
              (iic_state == R_START_DEVICE_ADDR)) && (r_sda_flag) && (bit_cnt == bit_cnt_num - 1'b1)
            )
        iic_ack_error <= sda_in; //在从机应答时间段 将从机应答的信号 引出
    else
        iic_ack_error <= iic_ack_error;
end

endmodule 
