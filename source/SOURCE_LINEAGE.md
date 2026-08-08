# Source history

The available source history starts from the archived V28.1 C++ project.

Comparison of the archived executable with the executable used for the reported results identified two code changes. The corresponding source edits are listed in `SOURCE_PATCH.diff`.

1. An explicit `GRIDCAP` value is applied to both grid import and grid export limits.
2. The grid export price keeps the sign of the import-price basis when the `SELL` factor is applied.

The source in this repository includes these two changes. The original final `Source.cpp` was not retained, so the distributed source is a reconstruction from the archived project rather than a copy of the original final file.

A Release x64 build with IBM ILOG CPLEX Optimization Studio 22.1.2 reproduced the reference values in `validation/reference_base.json` for full-coupled planning, the feedwater-omitting sizing benchmark, and fixed-capacity full-coupled re-evaluation.

Comments and console text were shortened for the repository. The optimization equations and numerical settings were not changed during that cleanup.
