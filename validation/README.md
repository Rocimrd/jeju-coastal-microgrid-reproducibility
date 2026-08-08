# Reproduction checks

`validate_static.py` checks the main source settings, model parameters, hourly input relations, Data S1 alignment, result-table sizes, and selected numerical results.

`compare_base_run.py` compares the three base formulations with `reference_base.json`.

`run_reproduction_check.ps1` is called by the root `RUN_REPRODUCTION_CHECK.bat`. It builds the source and runs the three base formulations on Windows with CPLEX 22.1.2.

`validated_base_result.txt` records the values reproduced by a Release x64 build on 7 August 2026. Other scenario results are provided in `results/` and `paper_data/`.
