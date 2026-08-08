from pathlib import Path
import csv

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "results" / "article_key_results.csv"


def read_rows(name):
    path = ROOT / "results" / name
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def add_row(rows, group, scenario, metric, value, unit):
    rows.append(
        {
            "group": group,
            "scenario": scenario,
            "metric": metric,
            "value": value,
            "unit": unit,
        }
    )


def main():
    rows = []

    base = read_rows("base_case_summary.csv")[0]
    scenario = "H2=1000 kg/day, water=100%"
    for metric, column, unit in [
        ("Full-coupled objective", "objective_full_USD", "USD/yr"),
        ("Decoupled objective", "objective_decoupled_USD", "USD/yr"),
        ("Re-evaluated objective", "objective_reevaluated_USD", "USD/yr"),
        ("Net difference", "reevaluated_minus_full_percent", "%"),
        ("RO deviation", "K_RO_deviation_percent", "%"),
    ]:
        add_row(rows, "Base comparison", scenario, metric, base[column], unit)

    coupling = read_rows("coupling_grid.csv")
    worst = max(coupling, key=lambda row: float(row["freshwater_shortage_reevaluated_m3"]))
    scenario = f'H2={worst["H2_demand_kg_day"]} kg/day, water={worst["water_scale_percent"]}%'
    add_row(rows, "Coupling grid", scenario, "Freshwater shortage", worst["freshwater_shortage_reevaluated_m3"], "m3/yr")
    add_row(rows, "Coupling grid", scenario, "RO deviation", worst["K_RO_deviation_percent"], "%")
    add_row(rows, "Coupling grid", scenario, "Net penalty", worst["reevaluated_minus_full_percent"], "%")

    for row in read_rows("proportional_restoration.csv"):
        scenario = f'H2={row["H2_demand_kg_day"]} kg/day, water=100%'
        add_row(rows, "Proportional restoration", scenario, "RO-only restoration", row["RO_only_restoration_percent"], "%")
        add_row(rows, "Proportional restoration", scenario, "Coordinated restoration", row["joint_restoration_percent"], "%")

    for row in read_rows("independent_restoration.csv"):
        scenario = f'H2={row["H2_demand_kg_day"]} kg/day, water=100%'
        add_row(rows, "Independent restoration", scenario, "RO factor", row["independent_RO_factor"], "-")
        add_row(rows, "Independent restoration", scenario, "Water-tank factor", row["independent_tank_factor"], "-")
        add_row(
            rows,
            "Independent restoration",
            scenario,
            "Investment saving vs RO-only",
            row["investment_saving_vs_RO_only_percent"],
            "%",
        )

    fields = ["group", "scenario", "metric", "value", "unit"]
    with OUTPUT.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
