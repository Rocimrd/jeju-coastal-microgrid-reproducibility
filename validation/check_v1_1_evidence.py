#!/usr/bin/env python3
from pathlib import Path
import csv, sys, math
ROOT=Path(__file__).resolve().parents[1]
def rows(rel):
    with (ROOT/rel).open(newline='',encoding='utf-8-sig') as f: return list(csv.DictReader(f))
def metric(rel):
    with (ROOT/rel).open(newline='',encoding='utf-8-sig') as f: return {r['metric']:r['value'] for r in csv.DictReader(f)}
checks=[]
def add(name,ok,detail=''): checks.append((name,bool(ok),detail))
core=rows('results/coupling_grid.csv')
add('core_25_conditions',len(core)==25,len(core))
add('core_all_optimum_RO_deviations_negative',len(core)==25 and all(float(r['K_RO_deviation_percent'])<0 for r in core))
allruns=rows('analysis/near_optimal_ro/results/RO_AUDIT_ALL_RUNS.csv')
add('nearopt_150_solves',len(allruns)==150,len(allruns))
add('nearopt_all_optimal',all(r['cplex_status']=='Optimal' and r['successful']=='1' for r in allruns))
add('nearopt_all_shortages_zero',all(abs(float(r['freshwater_shortage_m3_yr']))<1e-8 and abs(float(r['H2_shortage_kg_yr']))<1e-8 for r in allruns))
pair=rows('analysis/near_optimal_ro/results/RO_AUDIT_PAIRWISE_RANGES.csv')
add('nearopt_25_pair_rows',len(pair)==25,len(pair))
sep=sum(r['range_relation']=='STRICT_SEPARATION' for r in pair)
ovl=sum(r['range_relation']=='OVERLAP_OR_TOUCH' for r in pair)
add('nearopt_3_separated',sep==3,sep); add('nearopt_22_overlapping',ovl==22,ovl)
add('nearopt_all_optimum_lower_RO',all(float(r['benchmark_opt_K_RO'])<float(r['reference_opt_K_RO']) for r in pair))
sel=[r for r in pair if float(r['water_scale_percent'])==50 and float(r['H2_service_kg_day'])==8000]
add('nearopt_selected_unique',len(sel)==1,len(sel))
if sel:
 r=sel[0]
 add('nearopt_selected_separated',r['range_relation']=='STRICT_SEPARATION')
 add('nearopt_selected_margin',abs(float(r['separation_margin_m3_h'])-1.03723115074)<1e-9,r['separation_margin_m3_h'])
ordm=metric('analysis/hard_service/results/summary_expost_C3_C3_HARDCHECK_WATER50_H2D8000_GRIDCAP1.5_TAX150.csv')
hard=metric('analysis/hard_service/results/summary_expost_C3_C3_HARDSERVICE_WATER50_H2D8000_GRIDCAP1.5_TAX150.csv')
add('hard_ordinary_optimal',ordm.get('status')=='Optimal',ordm.get('status'))
add('hard_ordinary_shortage_5918',abs(float(ordm['total_freshwater_shortage_m3'])-5918.31013331)<1e-6,ordm['total_freshwater_shortage_m3'])
add('hard_H2_shortage_numerical_zero',abs(float(ordm['total_H2_shortage_kg']))<1e-9,ordm['total_H2_shortage_kg'])
add('hard_service_infeasible',hard.get('status')=='Infeasible',hard.get('status'))
add('paper_table_S1_25_rows',len(rows('paper_data/Table_S1_NearOptimal_RO_Ranges.csv'))==25)
add('paper_table_S4_4_rows',len(rows('paper_data/Table_S4_Absolute_Shortage_Penalty_Scaling.csv'))==4)
add('absolute_penalty_scaling_16_rows',len(rows('results/absolute_penalty_scaling.csv'))==16)
for n,ok,d in checks: print(f"{n}: {'PASS' if ok else 'FAIL'}"+(f" ({d})" if d!='' else ''))
passed=all(ok for _,ok,_ in checks)
print('\nV1.1 EVIDENCE CHECK: '+('PASS' if passed else 'FAIL'))
sys.exit(0 if passed else 1)
