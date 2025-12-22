import PyPDF2
import re
import sys

# 设置输出编码
sys.stdout.reconfigure(encoding='utf-8')

# 打开PDF文件
pdf_path = r'征途Pro《FPGA Verilog开发实战指南——基于Altera EP4CE10》2021.7.10（上）.pdf'
pdf_file = open(pdf_path, 'rb')
reader = PyPDF2.PdfReader(pdf_file)

print(f'总页数: {len(reader.pages)}\n')

# 搜索第36章
chapter_36_start = -1
for i in range(len(reader.pages)):
    text = reader.pages[i].extract_text()
    if re.search(r'第\s*36\s*章|第三十六章|Chapter\s*36', text, re.IGNORECASE):
        print(f'找到第36章，起始页: {i+1}')
        chapter_36_start = i
        break

if chapter_36_start >= 0:
    # 读取第36章内容（假设章节约10-20页）
    print('\n' + '='*80)
    print('第36章内容：')
    print('='*80 + '\n')
    
    for page_num in range(chapter_36_start, min(chapter_36_start + 20, len(reader.pages))):
        text = reader.pages[page_num].extract_text()
        print(f'\n--- 第 {page_num+1} 页 ---\n')
        # 过滤非法字符
        text = text.encode('utf-8', errors='ignore').decode('utf-8')
        print(text)
        
        # 检查是否到达下一章
        if page_num > chapter_36_start and re.search(r'第\s*37\s*章|第三十七章|Chapter\s*37', text, re.IGNORECASE):
            print('\n[已到达第37章，停止]')
            break
else:
    print('未找到第36章，显示目录：')
    for i in range(min(30, len(reader.pages))):
        text = reader.pages[i].extract_text()
        if '目录' in text or 'Contents' in text.upper():
            print(f'\n第{i+1}页（目录）：\n{text[:1000]}')

pdf_file.close()
