#!/usr/bin/env python3
from pathlib import Path
import csv
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "validation" / "static_validation_report.txt"
CHECKS = []


def add(name, passed, detail=""):
    CHECKS.append((name, bool(passed), str(detail)))


def read_rows(path):
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def close(a, b, tolerance=1e-12):
    return abs(a - b) <= tolerance


source = (ROOT / "source" / "Source.cpp").read_text(encoding="utf-8")
project_path = ROOT / "source" / "JejuFullCoupled24h.vcxproj"
params = json.loads((ROOT / "software" / "parameters.json").read_text(encoding="utf-8"))
full = read_rows(ROOT / "software" / "model_input_full.csv")
paper = read_rows(ROOT / "paper_data" / "Data_S1_Final_Annual_Profiles.csv")
compact = read_rows(ROOT / "data" / "hourly_input.csv")

add(
    "source_gridcap_symmetric",
    "p.P_grid_export_max_MW = explicitGridCap;" in source
    and "std::min(p.P_grid_export_max_MW, explicitGridCap)" not in source,
)
add(
    "source_signed_sell_policy",
    "r.price_grid_out_usd_kwh = sellMultiplier * r.price_grid_in_usd_kwh;" in source
    and "std::max(0.0, sellMultiplier * r.price_grid_in_usd_kwh)" not in source,
)

for name, token in {
    "source_full_water_balance": "== (WRO[t] - (Wload - Wsh[t]) - WEL[t]) * dt",
    "source_decoupled_water_balance": "== (WRO[t] - (Wload - Wsh[t])) * dt",
    "source_h2_balance": "== (HEL[t] - HFC[t] - Hserv[t]) * dt",
    "source_power_balance": "== Pload + PBch[t] + PRO[t] + PEL[t] + Pgout[t]",
    "source_fixed_capacity_re_evaluation": "pv_lb = pv_ub = fix.K_PV;",
    "source_mip_gap": "MIPGap, 1e-4",
    "source_time_limit": "TimeLimit, 3600",
}.items():
    add(name, token in source)

project = project_path.read_text(encoding="utf-8")
add("project_x64_release", "Release|x64" in project)
add("project_cpp17", "stdcpp17" in project)
add("project_release_MD", "<RuntimeLibrary>MultiThreadedDLL</RuntimeLibrary>" in project)
add("project_cplex_2212", "cplex2212.lib" in project and "ilocplex.lib" in project and "concert.lib" in project)
add("project_source_cpp", '<ClCompile Include="Source.cpp"' in project)
add("project_toolset_v145", "<PlatformToolset>v145</PlatformToolset>" in project)

expected_parameters = [
    ("rho_EL", params["electrolyzer"]["rho_EL_m3_per_kgH2"], 0.013),
    ("kappa_EL", params["electrolyzer"]["kappa_EL_kWh_per_kgH2"], 49.9),
    ("RO_SEC", params["ro"]["SEC_kWh_per_m3"], 2.864),
    ("water_shortage_penalty", params["shortage_and_policy"]["freshwater_shortage_penalty_USD_per_m3"], 100.0),
    ("H2_shortage_penalty", params["shortage_and_policy"]["hydrogen_shortage_penalty_USD_per_kg"], 2500.0),
    ("carbon_tax", params["shortage_and_policy"]["principal_result_carbon_tax_USD_per_tCO2"], 150.0),
    ("grid_import_cap", params["capacity_bounds"]["P_grid_import_max_MW"], 1.5),
    ("grid_export_cap", params["capacity_bounds"]["P_grid_export_max_MW"], 1.5),
    ("diesel_cost", params["diesel"]["variable_cost_USD_per_kWh"], 0.306302879981247),
    ("diesel_EF", params["diesel"]["emission_factor_tCO2_per_MWh"], 0.708543971022556),
    ("FX", params["metadata"]["exchange_rate_KRW_per_USD"], 1422.0),
]
for name, value, reference in expected_parameters:
    add(f"param_{name}", close(float(value), reference, 1e-12), value)

add(
    "solver_version_metadata",
    params["metadata"]["solver"] == "IBM ILOG CPLEX Optimization Studio 22.1.2",
    params["metadata"]["solver"],
)
add(
    "electrolyzer_variable_om_zero",
    close(float(params["electrolyzer"]["variable_om_USD_per_MWh"]), 0.0),
    params["electrolyzer"]["variable_om_USD_per_MWh"],
)

add("full_input_8760", len(full) == 8760, len(full))
required_columns = [
    "datetime",
    "delta_t_h",
    "omega",
    "P_load_MG_MW",
    "W_load_adj_m3_h",
    "H2_load_adj_kg_h",
    "phi_pv",
    "phi_wt",
    "SMP_KRW_kWh",
    "price_grid_in_USD_kWh",
    "price_grid_out_USD_kWh",
    "gamma_grid_tCO2eq_MWh",
]
add("full_input_required_columns", all(column in full[0] for column in required_columns))
add("full_input_dt_1", max(abs(float(row["delta_t_h"]) - 1) for row in full) < 1e-12)
add("full_input_omega_1", max(abs(float(row["omega"]) - 1) for row in full) < 1e-12)
add("grid_EF_constant_04173", max(abs(float(row["gamma_grid_tCO2eq_MWh"]) - 0.4173) for row in full) < 1e-12)

import_error = max(
    abs(float(row["price_grid_in_USD_kWh"]) - float(row["SMP_KRW_kWh"]) / 1422.0)
    for row in full
)
export_error = max(
    abs(float(row["price_grid_out_USD_kWh"]) - 0.8 * float(row["price_grid_in_USD_kWh"]))
    for row in full
)
negative_hours = sum(float(row["SMP_KRW_kWh"]) < 0 for row in full)
add("signed_import_relation", import_error < 1e-12, import_error)
add("signed_export_relation", export_error < 1e-12, export_error)
add("negative_SMP_hours_64", negative_hours == 64, negative_hours)

add("paper_DataS1_8760", len(paper) == 8760, len(paper))
add("compact_input_8760", len(compact) == 8760, len(compact))

mappings = [
    ("P_load_MW", "electric_load_MW", "P_load_MG_MW"),
    ("W_load_m3_h", "freshwater_demand_m3_h", "W_load_adj_m3_h"),
    ("H2_load_kg_h", "hydrogen_service_kg_h", "H2_load_adj_kg_h"),
    ("phi_pv", "pv_capacity_factor", "phi_pv"),
    ("phi_wt", "wind_capacity_factor", "phi_wt"),
    ("SMP_KRW_per_kWh", "smp_KRW_per_kWh", "SMP_KRW_kWh"),
    ("grid_import_price_USD_per_kWh", "grid_import_price_USD_per_kWh", "price_grid_in_USD_kWh"),
    ("grid_export_price_USD_per_kWh", "grid_export_price_USD_per_kWh", "price_grid_out_USD_kWh"),
]
for paper_column, compact_column, full_column in mappings:
    compact_error = max(
        abs(float(p[paper_column]) - float(c[compact_column]))
        for p, c in zip(paper, compact)
    )
    full_error = max(
        abs(float(p[paper_column]) - float(f[full_column]))
        for p, f in zip(paper, full)
    )
    add(
        f"input_match_{paper_column}",
        compact_error < 1e-10 and full_error < 1e-10,
        f"paper-compact={compact_error:.3e}, paper-full={full_error:.3e}",
    )

add(
    "datetime_match",
    all(p["datetime"] == c["datetime"] == f["datetime"] for p, c, f in zip(paper, compact, full)),
)

expected_counts = {
    "base_case_summary.csv": 1,
    "coupling_grid.csv": 25,
    "service_priority_sensitivity.csv": 16,
    "proportional_restoration.csv": 4,
    "independent_restoration.csv": 2,
    "feedwater_sensitivity.csv": 6,
    "hydrogen_profile_sensitivity.csv": 6,
    "pcc_carbon_grid.csv": 25,
}
for name, count in expected_counts.items():
    actual = len(read_rows(ROOT / "results" / name))
    add(f"result_count_{name}", actual == count, actual)

base = read_rows(ROOT / "results" / "base_case_summary.csv")[0]
add("base_objective_full", abs(float(base["objective_full_USD"]) - 4684826.40262) < 1e-5, base["objective_full_USD"])
add("base_objective_decoupled", abs(float(base["objective_decoupled_USD"]) - 4680307.74272) < 1e-5, base["objective_decoupled_USD"])
add("base_objective_reevaluated", abs(float(base["objective_reevaluated_USD"]) - 4685310.04714) < 1e-5, base["objective_reevaluated_USD"])

core = read_rows(ROOT / "results" / "coupling_grid.csv")
high_case = [
    row
    for row in core
    if float(row["water_scale_percent"]) == 50
    and float(row["H2_demand_kg_day"]) == 8000
]
add("high_case_unique", len(high_case) == 1, len(high_case))
if high_case:
    row = high_case[0]
    add(
        "high_case_shortage_5918",
        abs(float(row["freshwater_shortage_reevaluated_m3"]) - 5918.31013332) < 1e-6,
        row["freshwater_shortage_reevaluated_m3"],
    )
    add(
        "high_case_RO_deviation",
        abs(float(row["K_RO_deviation_percent"]) - (-8.58622470218956)) < 1e-9,
        row["K_RO_deviation_percent"],
    )
add(
    "all_25_RO_deviation_negative",
    len(core) == 25 and all(float(row["K_RO_deviation_percent"]) < 0 for row in core),
)

passed = all(result for _, result, _ in CHECKS)
lines = []
for name, result, detail in CHECKS:
    line = f"{name}: {'PASS' if result else 'FAIL'}"
    if detail:
        line += f" ({detail})"
    lines.append(line)
lines.extend(["", f"STATIC VALIDATION: {'PASS' if passed else 'FAIL'}"])
REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(REPORT.read_text(encoding="utf-8"), end="")
sys.exit(0 if passed else 1)
