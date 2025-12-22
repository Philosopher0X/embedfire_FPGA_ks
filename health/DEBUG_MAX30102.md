# MAX30102调试指南

## 问题现象
- MAX30102不亮（LED不工作）
- 温度不显示
- 数码管显示：0.0.0.0.0（所有位都是0）

## 问题分析

### 1. LED状态指示（查看板上LED灯状态）
- **LED[0]** - 初始化完成标志 (init_done)
  - 如果不亮：MAX30102初始化失败
  - 如果亮：初始化成功
  
- **LED[1]** - 错误标志 (error)  
  - 如果亮：I2C通信错误或器件错误
  - 如果不亮：无通信错误
  
- **LED[2]** - 数据有效标志 (data_valid)
  - 如果闪烁：正在接收FIFO数据（正常）
  - 如果不亮：未接收到数据（异常）
  
- **LED[3]** - 心率计算完成标志 (hr_valid)
  - 每10秒亮一次：心率计算完成（正常）
  - 一直不亮：未收集到足够数据

### 2. 数码管显示分析
显示格式：`[温度2位] [空] [心率3位]`
- 位置：654 321
- 当前显示：0.0.0.0.0

**可能原因：**
1. `temp_display` = 0 → 温度数据未更新
2. `heart_rate` = 0 → 心率数据未计算
3. 第4位显示"0"而非空白 → 显示逻辑正确，但数据全为0

### 3. 硬件连接检查清单

#### I2C连接（最重要）
```
MAX30102模块    →    FPGA开发板
----------------    ----------------
VCC (3.3V)      →    3.3V电源
GND             →    GND
SCL             →    PIN_P15 (I2C1_SCL)
SDA             →    PIN_N14 (I2C1_SDA) 
INT             →    PIN_L13 (CAM_D7)
```

**注意事项：**
- ✅ 板载I2C有上拉电阻（4.7kΩ），不需要额外上拉
- ⚠️ 确认MAX30102模块供电为3.3V（不是5V！）
- ⚠️ 检查SCL/SDA是否接反
- ⚠️ INT引脚必须连接，低电平有效

#### 数码管连接
```
74HC595接口     →    FPGA开发板
--------------  →    --------------
SHCP            →    根据原理图
STCP            →    根据原理图
DS              →    根据原理图
OE              →    根据原理图
```

### 4. 常见问题排查

#### 问题1：LED[0]不亮（初始化失败）
**原因：**
- I2C通信失败
- MAX30102无应答（ACK错误）
- SCL/SDA接线错误或接触不良

**解决方案：**
1. 用万用表测量MAX30102的VCC引脚是否有3.3V
2. 用示波器/逻辑分析仪查看SCL是否有100kHz波形
3. 检查SDA上是否有数据传输
4. 尝试更换MAX30102模块

#### 问题2：LED[1]亮（错误标志）
**原因：**
- I2C通信时接收到NACK
- 从机地址错误
- 寄存器地址不支持

**解决方案：**
1. 确认MAX30102 I2C地址为0x57（7位地址）
2. 检查I2C时序是否正确（100kHz）
3. 检查上拉电阻是否存在

#### 问题3：LED[0]亮但LED[2]不闪烁（无数据）
**原因：**
- FIFO配置错误
- LED驱动电流设置过低
- 传感器被遮挡或未接触皮肤

**解决方案：**
1. 检查FIFO配置寄存器（0x08）
2. 检查LED电流设置（0x0C, 0x0D）
3. 确保手指按压在传感器上
4. LED电流建议值：50-100（约12.5-25mA）

#### 问题4：温度显示为0
**原因：**
- 温度读取未触发
- 温度转换未完成
- temp_valid信号未产生

**检查代码：**
```verilog
// top_max30102.v中的温度更新逻辑
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n)
        temp_display <= 8'd25;  // 默认25度
    else if (temp_valid)
        temp_display <= temp_int;
end
```

**解决方案：**
1. 检查max30102_driver.v中温度读取状态机
2. 确认温度读取定时器（1秒一次）
3. 添加调试信号监测temp_valid

### 5. 修改建议

#### 修改1：第4位显示空白而非"0"
将seg_data_6中的第4位改为显示码"10"（横杠）：

```verilog
// top_max30102.v 第174行
assign seg_data_6 = {
    temp_bcd_ten,   // 第6位：温度十位
    temp_bcd_one,   // 第5位：温度个位
    4'd10,          // 第4位：横杠分隔符（而非4'd0）
    hr_bcd_hun,     // 第3位：心率百位
    hr_bcd_ten,     // 第2位：心率十位
    hr_bcd_one      // 第1位：心率个位
};
```

#### 修改2：添加默认显示值（调试用）
在没有有效数据时显示默认值：

```verilog
// 在top_max30102.v中添加
reg [7:0] temp_display_debug;
reg [15:0] heart_rate_debug;

always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        temp_display_debug <= 8'd25;   // 默认25度
        heart_rate_debug <= 16'd72;    // 默认72bpm
    end else begin
        temp_display_debug <= init_done ? temp_display : 8'd88;  // 显示88表示初始化中
        heart_rate_debug <= init_done ? heart_rate : 16'd0;
    end
end

// 使用debug值替代原值
assign seg_data_6 = {
    temp_bcd_ten_debug,
    temp_bcd_one_debug,
    4'd10,  // 横杠
    hr_bcd_hun,
    hr_bcd_ten,
    hr_bcd_one
};
```

#### 修改3：增强I2C调试
在i2c_master.v中添加状态输出：

```verilog
output reg [3:0] debug_state,  // 当前状态机状态
output reg [7:0] debug_byte_cnt // 字节计数
```

### 6. 测试步骤

#### 步骤1：上电自检
1. 连接FPGA板电源
2. 下载.sof文件
3. 观察LED灯状态：
   - 复位后2秒内LED[0]应该点亮（初始化完成）
   - LED[1]应该保持熄灭（无错误）

#### 步骤2：传感器测试
1. 将手指轻轻按压在MAX30102传感器上
2. 观察：
   - 传感器上的红光LED应该亮起
   - FPGA板上LED[2]应该开始闪烁（约100Hz）
   - 数码管前2位应显示温度（约30-37度）

#### 步骤3：心率测试
1. 保持手指稳定按压10秒
2. 观察：
   - LED[3]每10秒闪一次
   - 数码管后3位显示心率值（60-100正常范围）

### 7. 示波器/逻辑分析仪抓取

如果有设备，建议抓取以下信号：

**I2C通信波形：**
```
CH1: SCL (PIN_P15)
CH2: SDA (PIN_N14)  
CH3: INT (PIN_L13)
时基：10us/div
触发：SCL下降沿
```

**正常波形特征：**
- SCL频率：100kHz（周期10us）
- SDA在SCL高电平时稳定
- 每次传输9个时钟（8位数据+1位ACK）
- INT在FIFO有数据时拉低

### 8. 代码检查点

#### 检查点1：max30102_driver.v初始化序列
```verilog
// 检查初始化状态机是否完成以下步骤：
INIT_SOFT_RESET  → 写0x09 = 0x40
INIT_FIFO_CONFIG → 写0x08 = 0x4F  
INIT_MODE_CONFIG → 写0x09 = 0x03 (SpO2模式)
INIT_SPO2_CONFIG → 写0x0A = 0x27 (100Hz, 18bit)
INIT_LED1_PA     → 写0x0C = 0x50 (RED LED电流)
INIT_LED2_PA     → 写0x0D = 0x50 (IR LED电流)
INIT_DONE        → init_done = 1
```

#### 检查点2：温度读取
```verilog
// 每1秒触发一次温度读取
TEMP_TRIGGER → 写0x21 = 0x01
等待50ms
TEMP_READ_INT → 读0x1F (温度整数)
TEMP_READ_FRAC → 读0x20 (温度小数)
```

#### 检查点3：FIFO数据读取
```verilog
// INT拉低时触发
READ_WR_PTR → 读0x04 (写指针)
READ_RD_PTR → 读0x06 (读指针)
计算样本数 = (wr_ptr - rd_ptr) & 0x1F
READ_FIFO → 读0x07，连续读取6字节
```

## 总结

**最可能的问题：**
1. ❌ I2C连接问题（接线错误、接触不良）
2. ❌ MAX30102供电不足或电压错误（需要稳定的3.3V）
3. ❌ 初始化失败（I2C通信未建立）

**立即检查：**
1. ✅ 用万用表测量MAX30102的VCC是否为3.3V
2. ✅ 检查SCL/SDA是否插对引脚（P15/N14）
3. ✅ 观察LED[0]是否点亮（init_done）
4. ✅ 观察LED[1]是否点亮（error标志）

**如果LED[0]不亮：**
→ I2C通信失败，重点检查硬件连接

**如果LED[0]亮但LED[2]不闪：**
→ FIFO无数据，检查手指是否按压传感器

**如果LED都正常但数码管显示0：**
→ 显示逻辑问题，修改seg_data_6第4位为4'd10
