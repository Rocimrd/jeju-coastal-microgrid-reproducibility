# Reproduction scope

This release distinguishes direct source execution from machine-readable evidence preservation.

## Directly rerunnable from the repository

- The existing root reproduction check builds the reconstructed core C++ project and reruns the central base formulations under IBM ILOG CPLEX Optimization Studio 22.1.2.
- The exact standalone packages used for the hard-service diagnostic and epsilon-optimal RO audit are preserved under `analysis/`. Each contains its modified source, full solver input, and single top-level launcher.

## Machine-readable evidence provided

- Data S1-S11 and Tables S1-S4 aligned with the revised manuscript and Supplementary Material.
- Core 25-condition coupling results.
- Complete 150-solve epsilon-optimal audit records and 25-condition RO-capacity ranges.
- Selected hard-service solver evidence.
- Feedwater-use, H2-service timing, absolute penalty-scaling, PCC-carbon, and water-side augmentation results.
- Selected hourly dispatch files used for chronological diagnosis.

## Not claimed

This release does not claim that one root command regenerates every optimization case behind every figure and table. The central base source/project check, the hard-service diagnostic, and the epsilon-optimal audit have dedicated execution paths. Other analysis families are distributed as checked machine-readable outputs.
