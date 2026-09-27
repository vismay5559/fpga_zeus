#!/usr/bin/env python3
"""Verify packet tests against scratch copies outside rtl; never mutate real RTL."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
work=ROOT/'build'/'pi_mutations';work.mkdir(parents=True,exist_ok=True)
source=(ROOT/'rtl/pi_link/pi_snapshot.v').read_text()
cases={
    'reference': source,
    'bad_crc': source.replace("16'h1021", "16'h1020"),
    'ignore_stall': source.replace('else if (out_ready) begin','else if (1\'b1) begin'),
    'ignore_rewind': source.replace('if (rewind) index <= 0;',"if (1'b0) index <= 0;"),
}
try:
    for name, content in cases.items():
        ref=work/(name+'.v');ref.write_text(content)
        with (work/(name+'.log')).open('w') as log:
            r=subprocess.run(['make','TOP=pi_snapshot','VERILOG_SOURCES='+str(ref),
                              'SIM_BUILD=sim_build/pi_mutation_'+name],
                             cwd=ROOT/'sim',stdout=log,stderr=subprocess.STDOUT)
        if (r.returncode==0) != (name=='reference'):
            raise SystemExit('Unexpected mutation result: '+name)
        print(name, 'PASS' if name=='reference' else 'DETECTED',flush=True)
finally:
    # Keep evidence logs, remove temporary reference implementations.
    for name in cases: (work/(name+'.v')).unlink(missing_ok=True)
