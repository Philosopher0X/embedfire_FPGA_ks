# FPGA项目开发文档

## 项目概述

这是一个基于Cyclone IV E EP4CE10F17C8 FPGA的嵌入式系统项目，主要实现温度测量、心率监测和数据显示功能。项目使用Verilog HDL开发，包含DS18B20温度传感器、MAX30102心率传感器和SSD1306 OLED显示屏。

## 硬件平台

- **FPGA芯片**: Cyclone IV E EP4CE10F17C8
- **开发板**: 正点原子ZhengTu Pro
- **时钟频率**: 50MHz
- **温度传感器**: DS18B20 (单总线协议)
- **心率传感器**: MAX30102 (I2C协议)
- **显示屏**: SSD1306 OLED (128x64, I2C协议)

## 现有功能

项目初始版本包含：
- DS18B20温度传感器驱动
- 6位7段数码管显示 (通过74HC595驱动)
- 温度数据采集和显示

## 新增功能需求

在保持原有DS18B20功能的基础上，添加：
1. OLED显示屏支持 (显示温度和心率数据)
2. MAX30102心率传感器支持 (心率和血氧饱和度测量)
3. I2C总线控制器 (支持多设备通信)

## 开发过程

### 阶段1: 模块创建
1. 创建I2C主控制器 (`i2c_master.v`)
   - 支持400kHz快速模式
   - 实现标准I2C协议时序
   - 添加`no_stop`信号支持连续字节传输

2. 创建OLED控制器 (`oled_ctrl_simple.v`)
   - SSD1306初始化序列 (27条命令)
   - I2C通信接口
   - 简化版本专注于显示初始化

3. 创建MAX30102控制器 (`max30102_ctrl.v`)
   - SpO2模式配置
   - FIFO数据读取
   - 心率和血氧计算

### 阶段2: 集成调试
1. 在顶层模块 (`top_seg_test.v`) 中集成各模块
2. 配置I2C引脚 (尝试了N14/N16, F1/F2, L10/K10)
3. 解决编译错误：
   - 多驱动问题 (reg信号在组合和时序逻辑中赋值)
   - 锁存器推断 (信号未在所有分支赋值)
   - 语法错误 (缺失end关键字等)

### 阶段3: 协议调试
1. 发现I2C协议问题：OLED需要连续3字节传输 (地址+控制+命令)
2. 参考CSDN文章修改I2C主控制器：
   - 添加WAIT_DATA状态
   - 支持不发送STOP信号的连续传输
3. 重写OLED控制器状态机：
   - SEND_CTRL: 发送控制字节 (0x00) + no_stop
   - SEND_CMD: 发送命令字节 + 生成STOP

### 阶段4: 问题排查
- OLED始终不亮，经多次尝试后决定回退
- 可能原因：硬件连接、I2C上拉电阻、OLED地址配置等
- 回退到测试版本 (commit 47a0b8c)

## 代码模块设计

### 1. I2C主控制器 (i2c_master.v)

```verilog
module i2c_master(
    input clk,           // 系统时钟
    input rst_n,         // 复位信号
    input start,         // 启动信号
    input [6:0] addr,    // 设备地址
    input rw,            // 读写控制 (0:写, 1:读)
    input [7:0] data,    // 数据字节
    input no_stop,       // 不发送STOP信号 (用于连续传输)
    output reg ready,    // 准备好信号
    output reg ack,      // 应答信号
    output reg scl,      // I2C时钟线
    inout sda            // I2C数据线
);
```

**状态机设计**:
- IDLE: 空闲状态
- START_BIT: 发送START条件
- ADDR_BYTE: 发送地址字节
- ACK_ADDR: 等待地址应答
- DATA_BYTE: 发送/接收数据字节
- ACK_DATA: 等待数据应答
- WAIT_DATA: 等待下一个数据字节 (新增状态)
- STOP_BIT: 发送STOP条件

**关键特性**:
- 支持连续字节传输 (通过no_stop信号控制)
- 400kHz时钟频率
- 自动处理START/STOP条件

### 2. OLED控制器 (oled_ctrl_simple.v)

```verilog
module oled_ctrl_simple(
    input clk,              // 系统时钟
    input rst_n,            // 复位信号
    output reg i2c_start,   // I2C启动信号
    output reg [6:0] i2c_addr, // I2C设备地址 (0x3C)
    output reg i2c_rw,      // I2C读写控制
    output reg [7:0] i2c_data, // I2C数据
    output reg i2c_no_stop, // I2C连续传输控制
    output reg done         // 初始化完成信号
);
```

**初始化序列** (27条命令):
1. 0xAE - 显示关闭
2. 0x00 - 设置列地址低4位
3. 0x10 - 设置列地址高4位
4. ... (更多配置命令)
27. 0xAF - 显示开启

**状态机设计**:
- IDLE: 等待初始化开始
- SEND_CTRL: 发送控制字节 (0x00)
- WAIT_CTRL: 等待控制字节发送完成
- SEND_CMD: 发送命令字节
- WAIT_CMD: 等待命令字节发送完成
- NEXT_CMD: 准备下一条命令
- DONE: 初始化完成

### 3. MAX30102控制器 (max30102_ctrl.v)

```verilog
module max30102_ctrl(
    input clk,              // 系统时钟
    input rst_n,            // 复位信号
    output reg i2c_start,   // I2C启动信号
    output reg [6:0] i2c_addr, // I2C设备地址 (0x57)
    output reg i2c_rw,      // I2C读写控制
    output reg [7:0] i2c_data, // I2C数据
    output reg [7:0] heart_rate, // 心率值
    output reg [7:0] spo2      // 血氧饱和度
);
```

**配置参数**:
- 采样率: 100Hz
- ADC分辨率: 18位
- 工作模式: SpO2模式
- LED电流: 自动调节

### 4. 顶层模块 (top_seg_test.v)

```verilog
module top_seg_test(
    input clk,           // 系统时钟
    input rst_n,         // 复位信号
    // DS18B20接口
    input dq,            // 单总线数据
    // I2C接口
    output i2c_scl,      // I2C时钟
    output i2c_sda,      // I2C数据
    // 数码管接口
    output [5:0] seg_sel, // 位选
    output [7:0] seg_led  // 段选
);
```

**模块连接**:
- DS18B20直接连接到顶层
- I2C总线连接OLED和MAX30102控制器
- 仲裁逻辑：优先OLED，MAX30102暂时禁用

## 问题解决记录

### 编译错误修复
1. **多驱动错误**: 将reg信号改为wire，使用assign语句
2. **锁存器推断**: 在case语句前添加default赋值
3. **语法错误**: 检查always块的begin/end匹配

### I2C协议优化
1. **初始问题**: 每个字节单独传输，地址重复发送
2. **解决方案**: 添加WAIT_DATA状态，支持连续字节传输
3. **协议格式**: START + 地址 + 数据1 + 数据2 + STOP

### 硬件调试
1. **引脚配置**: 尝试3组不同引脚 (N14/N16, F1/F2, L10/K10)
2. **OLED不亮**: 可能原因包括：
   - I2C上拉电阻缺失
   - OLED地址错误 (0x3C vs 0x3D)
   - 硬件连接问题
   - 电源供应不足

## 最终状态

- **当前版本**: commit 47a0b8c (测试版本)
- **功能状态**: DS18B20温度测量正常
- **OLED/MAX30102**: 已移除，等待重新实现
- **代码质量**: 编译通过，无语法错误

## 总结与展望

本次开发过程中成功创建了完整的I2C通信框架和传感器驱动模块，虽然OLED显示遇到硬件层面的问题，但为后续开发奠定了良好的基础。

**经验教训**:
1. 硬件调试优先于软件优化
2. I2C协议细节对通信成功至关重要
3. 模块化设计有利于问题隔离
4. 及时回退有助于保持代码整洁

**后续计划**:
1. 验证硬件连接和I2C上拉电阻
2. 使用I2C扫描工具确认设备地址
3. 重新实现OLED驱动，使用更简单的测试程序
4. 逐步添加MAX30102功能
5. 集成所有传感器数据到OLED显示

---

*文档生成时间: 2025年12月22日*
*项目状态: 开发中，回退到测试版本*