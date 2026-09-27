#!/usr/bin/env python3
"""Run all interface tests sequentially (cocotb shares sim/results.xml)."""
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]
TOPS = ['tick_gen','cycle_timer','uart_tx','uart_rx','fifo_sync','uart_rx_fifo',
        'shtp_uart_deframer','bno085_uart_rx','sh2_report_parser','bno085_imu_rx',
        'bno085_uart_packet_tx','bno085_startup_controller','bno085_imu',
        'pi_snapshot','pi_link']
subprocess.run([sys.executable,'-m','unittest','discover','-s','tests','-v'],cwd=ROOT,check=True)
logs=ROOT/'build'/'regression';logs.mkdir(parents=True,exist_ok=True)
for top in TOPS + ['test-uart-bno085','test-bno-tx-gaps']:
    args=['make',top] if top.startswith('test-') else ['make','TOP='+top]
    with (logs/(top+'.log')).open('w') as out:
        result=subprocess.run(args,cwd=ROOT/'sim',stdout=out,stderr=subprocess.STDOUT)
    if result.returncode:
        print((logs/(top+'.log')).read_text());sys.exit(result.returncode)
    tree=ET.parse(ROOT/'sim'/'results.xml')
    if tree.findall('.//failure') or tree.findall('.//error'):
        raise SystemExit('Failed test in '+top)
    print('PASS',top,flush=True)
print('All suites passed. Logs:',logs)
