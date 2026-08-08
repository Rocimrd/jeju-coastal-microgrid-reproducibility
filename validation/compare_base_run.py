#!/usr/bin/env python3
from pathlib import Path
import csv
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = json.loads((ROOT / "validation" / "reference_base.json").read_text(encoding="utf-8"))

CASES = [
    {
        "key": "full_coupled_planning",
        "label": "Full-coupled planning",
        "internal_id": "C1",
        "prefix": "full_coupled_C1",
    },
    {
        "key": "feedwater_omitting_sizing_benchmark",
        "label": "Feedwater-omitting sizing benchmark",
        "internal_id": "C2",
        "prefix": "decoupled_C2",
    },
    {
        "key": "fixed_capacity_full_coupled_re_evaluation",
        "label": "Fixed-capacity full-coupled re-evaluation",
        "internal_id": "C3",
        "prefix": "expost_C3",
    },
]


def read_metrics(path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return {row["metric"]: row["value"] for row in csv.DictReader(handle)}


def read_capacity(path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        row = next(csv.DictReader(handle))
    return {key: float(value) for key, value in row.items()}


def relative_error(value, reference):
    return abs(value - reference) / max(1.0, abs(reference))


def main():
    if len(sys.argv) != 2:
        print("Usage: compare_base_run.py OUTPUT_DIR")
        return 2

    output_dir = Path(sys.argv[1])
    tag = REFERENCE["case_tag"]
    tolerances = REFERENCE["tolerances"]
    failures = []
    report = []

    for case in CASES:
        key = case["key"]
        label = case["label"]
        case_id = f'{case["internal_id"]}_{tag}'
        prefix = case["prefix"]
        summary = read_metrics(output_dir / f"summary_{prefix}_{case_id}.csv")
        capacity = read_capacity(output_dir / f"capacity_{prefix}_{case_id}.csv")

        objective = float(summary["objective_USD"])
        reference = REFERENCE["objective_USD"][key]
        error = relative_error(objective, reference)
        passed = error <= tolerances["objective_relative"]
        report.append(
            f"{label} objective: value={objective:.12g} reference={reference:.12g} "
            f"relative_error={error:.3e} {'PASS' if passed else 'FAIL'}"
        )
        if not passed:
            failures.append(f"{key}:objective")

        for name, reference in REFERENCE.get("capacities", {}).get(key, {}).items():
            value = capacity[name]
            allowed = max(
                tolerances["capacity_absolute"],
                tolerances["capacity_relative"] * max(1.0, abs(reference)),
            )
            passed = abs(value - reference) <= allowed
            report.append(
                f"{label} {name}: value={value:.12g} reference={reference:.12g} "
                f"difference={value-reference:.3e} tolerance={allowed:.3e} "
                f"{'PASS' if passed else 'FAIL'}"
            )
            if not passed:
                failures.append(f"{key}:{name}")

        if key == "fixed_capacity_full_coupled_re_evaluation":
            water_shortage = float(summary["total_freshwater_shortage_m3"])
            h2_shortage = float(summary["total_H2_shortage_kg"])

            passed = abs(water_shortage) <= tolerances["base_freshwater_shortage_m3"]
            report.append(
                f"{label} freshwater shortage={water_shortage:.6g} "
                f"{'PASS' if passed else 'FAIL'}"
            )
            if not passed:
                failures.append(f"{key}:freshwater_shortage")

            passed = abs(h2_shortage) <= tolerances["base_h2_shortage_kg"]
            report.append(
                f"{label} H2 shortage={h2_shortage:.6g} "
                f"{'PASS' if passed else 'FAIL'}"
            )
            if not passed:
                failures.append(f"{key}:H2_shortage")

    report.append("")
    report.append(f"BASE FORMULATION REPRODUCTION: {'PASS' if not failures else 'FAIL'}")

    report_path = output_dir / "BASE_FORMULATION_REPRODUCTION.txt"
    report_path.write_text("\n".join(report) + "\n", encoding="utf-8")
    print(report_path.read_text(encoding="utf-8"), end="")

    if failures:
        print("Failures: " + ", ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
