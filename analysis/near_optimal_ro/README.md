# Epsilon-optimal RO-capacity audit

This directory preserves the source modification, runner, and results for the 25-condition RO-capacity audit. Each formulation was re-solved to obtain a tighter baseline optimum, followed by minimum-RO and maximum-RO solves constrained to remain within 0.01% of the corresponding economic optimum.

The audit contains 150 annual MILP solves: 25 conditions x 2 formulations x 3 modes (`BASE`, `MINRO`, `MAXRO`). All 150 returned `Optimal`. The tighter optimum selected a lower RO capacity in all 25 conditions. The 0.01% RO-capacity ranges were separated in 3 conditions and overlapping in 22.

For the selected 50% freshwater-demand, 8,000 kg-H2/day condition, the fully coupled range is 52.750129-56.588868 m3/h and the feedwater-omitting benchmark range is 47.693211-51.712898 m3/h.

`EXECUTED_RUNNER_PACKAGE_v1.zip` is the standalone package used for the reported audit. `SANITIZED_EXECUTED_RESULT_ARCHIVE.zip` preserves the complete result archive with only the local Windows user-profile path redacted from text logs, while the two aggregate CSV files are exposed in `results/` for direct inspection.
