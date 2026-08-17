#!/usr/bin/env python3
from pathlib import Path
import csv, sys, math
ROOT=Path(__file__).resolve().parent/'results'
def metric(path):
    with path.open(newline='',encoding='utf-8-sig') as f:
        return {r['metric']:r['value'] for r in csv.DictReader(f)}
ordinary=metric(ROOT/'summary_expost_C3_C3_HARDCHECK_WATER50_H2D8000_GRIDCAP1.5_TAX150.csv')
hard=metric(ROOT/'summary_expost_C3_C3_HARDSERVICE_WATER50_H2D8000_GRIDCAP1.5_TAX150.csv')
checks=[
 ('ordinary_status',ordinary.get('status')=='Optimal'),
 ('freshwater_shortage',abs(float(ordinary['total_freshwater_shortage_m3'])-5918.31013331)<1e-6),
 ('H2_shortage_numerical_zero',abs(float(ordinary['total_H2_shortage_kg']))<1e-9),
 ('hard_service_status',hard.get('status')=='Infeasible'),
]
for name,ok in checks: print(f"{name}: {'PASS' if ok else 'FAIL'}")
sys.exit(0 if all(ok for _,ok in checks) else 1)
