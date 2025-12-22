import sys
import os

def install_package(package):
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", package])

def read_pdf(file_path):
    print(f"\nReading PDF: {file_path}")
    try:
        import PyPDF2
    except ImportError:
        print("PyPDF2 not found. Installing...")
        install_package("PyPDF2")
        import PyPDF2

    try:
        with open(file_path, 'rb') as f:
            reader = PyPDF2.PdfReader(f)
            print(f"Total Pages: {len(reader.pages)}")
            # Read first 2 pages as a sample
            for i in range(min(2, len(reader.pages))):
                print(f"\n--- Page {i+1} ---")
                print(reader.pages[i].extract_text())
    except Exception as e:
        print(f"Failed to read PDF: {e}")

def read_excel(file_path):
    print(f"\nReading Excel: {file_path}")
    try:
        import pandas as pd
        import openpyxl
    except ImportError:
        print("pandas or openpyxl not found. Installing...")
        install_package("pandas")
        install_package("openpyxl")
        import pandas as pd

    try:
        xls = pd.ExcelFile(file_path)
        print(f"Sheet names: {xls.sheet_names}")
        
        # Read first sheet as sample
        if xls.sheet_names:
            sheet1 = xls.sheet_names[0]
            print(f"\n--- Content of Sheet '{sheet1}' (First 10 rows) ---")
            df = pd.read_excel(xls, sheet_name=sheet1, nrows=10)
            print(df.to_string())
    except Exception as e:
        print(f"Failed to read Excel: {e}")

if __name__ == "__main__":
    base_path = r"x:\FPGA\Project\embedfire_FPGA_ks"
    pdf_file = os.path.join(base_path, "[野火]征途Pro_开发板规格书.pdf")
    xlsx_file = os.path.join(base_path, "征途引脚绑定映射表.xlsx")

    if os.path.exists(pdf_file):
        read_pdf(pdf_file)
    else:
        print(f"File not found: {pdf_file}")

    if os.path.exists(xlsx_file):
        read_excel(xlsx_file)
    else:
        print(f"File not found: {xlsx_file}")
