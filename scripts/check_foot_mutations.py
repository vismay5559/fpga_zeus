#!/usr/bin/env python3
"""Run the foot-switch specification against scratch RTL faults outside rtl/."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
work = ROOT / 'build' / 'foot_mutations'
work.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'rtl/gpio/foot_switches.v').read_text()
mutations = {
    'reference': source,
    'late_make': source.replace('parameter integer MAKE_TICKS = 3',
                                'parameter integer MAKE_TICKS = 4'),
    'early_break': source.replace('parameter integer BREAK_TICKS = 8',
                                  'parameter integer BREAK_TICKS = 7'),
    'bad_foot_or': source.replace('switches[1] | switches[0]',
                                  'switches[1] & switches[0]'),
}
if len(set(mutations.values())) != len(mutations):
    raise SystemExit('A mutation did not change the source')
try:
    for name, content in mutations.items():
        path = work / (name + '.v')
        path.write_text(content)
        with (work / (name + '.log')).open('w') as log:
            result = subprocess.run(
                ['make', 'TOP=foot_switches', 'VERILOG_SOURCES=' + str(path),
                 'SIM_BUILD=sim_build/foot_mutation_' + name],
                cwd=ROOT / 'sim', stdout=log, stderr=subprocess.STDOUT)
        if (result.returncode == 0) != (name == 'reference'):
            raise SystemExit('Unexpected mutation result: ' + name)
        print(name, 'PASS' if name == 'reference' else 'DETECTED', flush=True)
finally:
    for name in mutations:
        (work / (name + '.v')).unlink(missing_ok=True)
