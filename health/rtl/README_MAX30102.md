# MAX30102心率血氧检测模块FPGA驱动说明

## 项目概述

本项目为MAX30102心率血氧检测模块的FPGA驱动实现，基于Altera Cyclone IV FPGA（EP4CE10F17C8）。

## 模块架构

### 1. i2c_master.v - I2C主控制器
- **功能**：实现标准I2C通信协议
- **支持命令**：
  - 写一个字节（CMD_WRITE）
  - 读一个字节（CMD_READ）
  - 读多个字节（CMD_READ_N）
- **时钟频率**：100kHz SCL
- **特性**：
  - 自动ACK/NACK检测
  - 支持双向IO控制
  - 错误检测和报告

### 2. max30102_driver.v - MAX30102驱动控制器
- **功能**：MAX30102传感器初始化和数据采集
- **工作模式**：SpO2模式（同时采集RED和IR通道）
- **配置参数**：
  - ADC范围：4096 nA
  - 采样率：100 Hz
  - LED脉宽：411μs（18位ADC分辨率）
  - LED电流：7.6 mA（RED和IR）
  - FIFO配置：4倍采样平均
- **输出数据**：
  - red_data[17:0]：RED通道18位数据
  - ir_data[17:0]：IR通道18位数据
  - data_valid：数据有效标志

### 3. top_max30102.v - 顶层模块
- **功能**：系统集成和心率计算
- **特性**：
  - 实时数据采集和缓冲
  - 简单峰值检测算法
  - 心率计算（BPM）
  - 数码管显示输出
  - LED状态指示

## 硬件连接

### MAX30102模块接口
| FPGA引脚 | 功能 | MAX30102引脚 | 说明 |
|---------|------|-------------|------|
| PIN_P15 | max_scl | SCL | I2C时钟线（板载I2C1_SCL，已有上拉）|
| PIN_N14 | max_sda | SDA | I2C数据线（板载I2C1_SDA，已有上拉）|
| PIN_L13 | max_int | INT | 中断信号（低电平有效，使用CAM_D7）|
| 3.3V | VCC | 3V3 | 电源 |
| GND | GND | GND | 地 |

### 数码管接口（已配置）
| FPGA引脚 | 功能 | 说明 |
|---------|------|------|
| PIN_B1 | shcp | 74HC595移位时钟 |
| PIN_K9 | stcp | 74HC595存储时钟 |
| PIN_R1 | ds | 74HC595串行数据 |
| PIN_L11 | oe | 74HC595输出使能 |

### LED指示灯
| LED编号 | 功能 | 说明 |
|--------|------|------|
| LED0 | init_done | 初始化完成 |
| LED1 | error | 错误指示 |
| LED2 | data_valid | 数据采集中 |
| LED3 | hr_valid | 心率计算完成 |

## 使用步骤

### 1. 硬件准备
- 连接MAX30102模块到FPGA开发板
- 使用板载I2C接口（PIN_P15/PIN_N14），已有上拉电阻
- INT信号连接到PIN_L13（CAM_D7）
- 连接数码管显示模块（如已有）

### 2. 引脚分配
引脚已配置好，无需修改：
```tcl
# MAX30102接口（使用板载I2C）
set_location_assignment PIN_P15 -to max_scl
set_location_assignment PIN_N14 -to max_sda
set_location_assignment PIN_L13 -to max_int
```

### 3. 编译项目
1. 打开Quartus II
2. 打开项目文件 `health.qpf`
3. 在 `.qsf` 文件中更新顶层实体：
   ```tcl
   set_global_assignment -name TOP_LEVEL_ENTITY top_max30102
   ```
4. 添加新的Verilog文件：
   ```tcl
   set_global_assignment -name VERILOG_FILE rtl/i2c_master.v
   set_global_assignment -name VERILOG_FILE rtl/max30102_driver.v
   set_global_assignment -name VERILOG_FILE rtl/top_max30102.v
   ```
5. 编译项目

### 4. 下载到FPGA
1. 连接下载器
2. 下载 `.sof` 文件到FPGA

### 5. 测试
1. 上电后等待LED0点亮（初始化完成）
2. 将手指放在MAX30102传感器上
3. 保持静止10秒
4. 数码管将显示心率值（BPM）

## 数据格式

### FIFO数据格式（SpO2模式）
每个样本6字节：
```
Byte 0-2: RED通道数据（18位，左对齐）
  [Byte0][Byte1][Byte2]
  [D17-D12][D11-D4][D3-D0,0000]

Byte 3-5: IR通道数据（18位，左对齐）
  [Byte3][Byte4][Byte5]
  [D17-D12][D11-D4][D3-D0,0000]
```

### 心率计算
- 采样率：100 Hz
- 计算周期：10秒（1000个样本）
- 算法：峰值检测
- 公式：心率 = (10秒内峰值数 × 6) BPM

## 寄存器配置说明

| 寄存器地址 | 名称 | 配置值 | 说明 |
|----------|------|--------|------|
| 0x08 | FIFO_CONFIG | 0x4F | 4倍平均，接近满中断 |
| 0x09 | MODE_CONFIG | 0x03 | SpO2模式 |
| 0x0A | SPO2_CONFIG | 0x27 | ADC=4096, 100Hz, 411μs |
| 0x0C | LED1_PA | 0x24 | RED LED 7.6mA |
| 0x0D | LED2_PA | 0x24 | IR LED 7.6mA |
| 0x02 | INTR_ENABLE_1 | 0xC0 | 使能FIFO中断 |

## 调试建议

### SignalTap II调试
建议监测以下信号：
- I2C状态机：state
- I2C时序：scl, sda
- 数据有效：data_valid
- 采样数据：red_data, ir_data
- 心率值：heart_rate

### 常见问题
1. **I2C通信失败**：
   - 板载I2C已有上拉电阻，检查连线是否正确
   - 确认MAX30102供电正常（3.3V）
   - 检查是否有其他设备占用板载I2C
   
2. **无数据输出**：确认INT信号连接和中断配置
3. **心率值异常**：
   - 手指接触不良
   - LED电流设置不当
   - 环境光干扰

## 改进方向

1. **算法优化**：
   - 实现更精确的峰值检测算法
   - 添加滤波器（移动平均、带通滤波）
   - 实现血氧饱和度计算

2. **功能扩展**：
   - 添加UART接口输出数据
   - 实现数据存储（FIFO/SDRAM）
   - 添加LCD显示

3. **性能提升**：
   - 优化I2C时序（提升到400kHz）
   - 实现多样本批量读取
   - 添加自适应LED电流控制

## 参考资料

- MAX30102数据手册
- 野火小智心率血氧检测模块规格手册
- I2C总线规范
- FPGA Verilog开发实战指南

## 版本历史

- V1.0 (2025-12-22)：初始版本
  - 实现I2C主控制器
  - 实现MAX30102驱动
  - 实现简单心率检测算法

---
**作者**：Fire  
**日期**：2025-12-22
