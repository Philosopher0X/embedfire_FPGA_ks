import pandas as pd
import os

file_path = r"x:\FPGA\Project\embedfire_FPGA_ks\征途引脚绑定映射表.xlsx"

try:
    df = pd.read_excel(file_path)
    # Print rows that might contain GPIO or expansion header info
    # Usually these are labeled as J1, J2, GPIO, or have generic names
    print(df.to_string()) 
except Exception as e:
    print(f"Error: {e}")
