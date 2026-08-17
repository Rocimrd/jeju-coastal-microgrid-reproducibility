from pathlib import Path
import csv
import hashlib
import sys

ROOT = Path(__file__).resolve().parents[1]


def read_csv(path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def close(a, b, tolerance=1e-10):
    return abs(a - b) <= tolerance


def verify_checksums():
    failures = []
    for row in read_csv(ROOT / "FILE_CHECKSUMS.csv"):
        path = ROOT / row["relative_path"]
        if not path.is_file():
            failures.append(row["relative_path"])
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != row["checksum"]:
            failures.append(row["relative_path"])
    return failures


def verify_hourly_input():
    rows = read_csv(ROOT / "data" / "hourly_input.csv")
    checks = [("hour_count", len(rows) == 8760, len(rows))]

    import_errors = []
    export_errors = []
    for row in rows:
        smp = float(row["smp_KRW_per_kWh"])
        buy = float(row["grid_import_price_USD_per_kWh"])
        sell = float(row["grid_export_price_USD_per_kWh"])
        import_errors.append(abs(buy - smp / 1422.0))
        export_errors.append(abs(sell - 0.8 * smp / 1422.0))

    checks.append(("import_price_relation", max(import_errors) < 1e-12, max(import_errors)))
    checks.append(("export_price_relation", max(export_errors) < 1e-12, max(export_errors)))

    electric = [float(row["electric_load_MW"]) for row in rows]
    water = [float(row["freshwater_demand_m3_h"]) for row in rows]
    hydrogen = [float(row["hydrogen_service_kg_h"]) for row in rows]

    checks.append(("electric_load_mean_MW", close(sum(electric) / len(electric), 2.65, 1e-9), sum(electric) / len(electric)))
    checks.append(("electric_load_peak_MW", close(max(electric), 5.0, 1e-9), max(electric)))
    checks.append(("freshwater_mean_m3_day", close(sum(water) / len(water) * 24.0, 2000.0, 1e-8), sum(water) / len(water) * 24.0))
    checks.append(("hydrogen_mean_kg_day", close(sum(hydrogen) / len(hydrogen) * 24.0, 1000.0, 1e-8), sum(hydrogen) / len(hydrogen) * 24.0))
    return checks


def verify_result_counts():
    expected = {
        "base_case_summary.csv": 1,
        "coupling_grid.csv": 25,
        "absolute_penalty_scaling.csv": 16,
        "proportional_restoration.csv": 4,
        "independent_restoration.csv": 2,
        "feedwater_sensitivity.csv": 6,
        "hydrogen_profile_sensitivity.csv": 6,
        "pcc_carbon_grid.csv": 25,
    }
    checks = []
    for name, count in expected.items():
        actual = len(read_csv(ROOT / "results" / name))
        checks.append((name, actual == count, actual))
    return checks


def main():
    failures = [f"checksum:{name}" for name in verify_checksums()]

    for name, passed, value in verify_hourly_input() + verify_result_counts():
        print(f"{name}: {'PASS' if passed else 'FAIL'} ({value})")
        if not passed:
            failures.append(name)

    if failures:
        print("Validation failed:")
        for item in failures:
            print(f" - {item}")
        return 1

    print("Validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
