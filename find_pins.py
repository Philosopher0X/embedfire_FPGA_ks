import pandas as pd
import os

# Use the directory where this script is located to find the Excel file
script_dir = os.path.dirname(os.path.abspath(__file__))
file_path = os.path.join(script_dir, "征途引脚绑定映射表.xlsx")

try:
    df = pd.read_excel(file_path)
    # Print rows that might contain GPIO or expansion header info
    # Usually these are labeled as J1, J2, GPIO, or have generic names
    print(df.to_string()) 
except Exception as e:
    print(f"Error: {e}")
