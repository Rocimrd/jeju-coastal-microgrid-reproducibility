#!/usr/bin/env python3
from pathlib import Path
import csv
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "software" / "model_input_full.csv"
OUTPUT_DIR = ROOT / "profile_inputs"

H2_COLUMNS = [
    "H2_load_base_kg_h",
    "H2_load_adj_kg_h",
    "H2_load_base_kg_h_v21_2_final",
    "H2_load_adj_kg_h_v21_2_final",
]
FRACTION_COLUMN = "H2_daily_profile_fraction"


def read_rows():
    with SOURCE.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        return reader.fieldnames, list(reader)


def group_by_day(rows):
    groups = []
    current = []
    current_date = None

    for row in rows:
        date = row["date"]
        if current_date is not None and date != current_date:
            if len(current) != 24:
                raise RuntimeError(f"Day {current_date} has {len(current)} rows; expected 24")
            groups.append(current)
            current = []
        current.append(row)
        current_date = date

    if current:
        if len(current) != 24:
            raise RuntimeError(f"Day {current_date} has {len(current)} rows; expected 24")
        groups.append(current)

    if len(groups) != 365:
        raise RuntimeError(f"Expected 365 days; found {len(groups)}")
    return groups


def write_variant(filename, mode, fields, source_rows):
    rows = [dict(row) for row in source_rows]

    for day in group_by_day(rows):
        base = [float(row["H2_load_adj_kg_h"]) for row in day]
        total = sum(base)

        if mode == "flat":
            values = [total / 24.0] * 24
        elif mode == "shift12":
            values = base[-12:] + base[:-12]
        else:
            raise ValueError(mode)

        for row, value in zip(day, values):
            for column in H2_COLUMNS:
                if column in row:
                    row[column] = format(value, ".15g")
            if FRACTION_COLUMN in row:
                row[FRACTION_COLUMN] = format(value / total if total else 0.0, ".15g")

    OUTPUT_DIR.mkdir(exist_ok=True)
    path = OUTPUT_DIR / filename
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return path


def verify(path, baseline_rows):
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))

    if len(rows) != 8760:
        raise RuntimeError(f"{path.name}: found {len(rows)} rows; expected 8760")

    baseline_days = group_by_day(baseline_rows)
    variant_days = group_by_day(rows)
    max_daily_error = 0.0

    for baseline, variant in zip(baseline_days, variant_days):
        baseline_total = sum(float(row["H2_load_adj_kg_h"]) for row in baseline)
        variant_total = sum(float(row["H2_load_adj_kg_h"]) for row in variant)
        max_daily_error = max(max_daily_error, abs(baseline_total - variant_total))

    annual = sum(float(row["H2_load_adj_kg_h"]) for row in rows)
    baseline_annual = sum(float(row["H2_load_adj_kg_h"]) for row in baseline_rows)
    if abs(annual - baseline_annual) > 1e-8:
        raise RuntimeError(f"{path.name}: annual H2 total changed")

    return annual, max_daily_error


def main():
    fields, rows = read_rows()
    files = [
        write_variant("model_input_H2_FLAT24.csv", "flat", fields, rows),
        write_variant("model_input_H2_SHIFT12.csv", "shift12", fields, rows),
    ]

    lines = []
    for path in files:
        annual, max_error = verify(path, rows)
        line = f"{path.name}: annual={annual:.12f} kg, max daily error={max_error:.3e} kg"
        print(line)
        lines.append(line)

    report = ROOT / "validation" / "h2_profile_input_check.txt"
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
