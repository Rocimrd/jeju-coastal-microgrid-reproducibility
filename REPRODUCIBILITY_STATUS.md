# Reproducibility status

| Item | Status | Evidence |
|---|---|---|
| Final 8,760-h input and parameter files | Provided | `data/`, `software/` |
| Core C++ source/project and build files | Provided with reconstruction note | `source/` |
| Base formulation reproduction check | Provided | `RUN_REPRODUCTION_CHECK.bat`, `validation/` |
| Core 25-condition result table | Provided | `results/coupling_grid.csv`, Data S3 |
| Hard-service diagnostic | Executed | `analysis/hard_service/results/` |
| Hard-service zero-shortage status | Infeasible | hard-service summary CSV and CPLEX output |
| 0.01% epsilon-optimal RO audit | 150/150 Optimal | `analysis/near_optimal_ro/results/` |
| Near-optimal range relation | 3 separated, 22 overlapping | Table S1 |
| Revised SI machine-readable numbering | Complete | Data S1-S11, Tables S1-S4 |
| One-command regeneration of every paper scenario | Not claimed | `FULL_REPRODUCTION_SCOPE.md` |
