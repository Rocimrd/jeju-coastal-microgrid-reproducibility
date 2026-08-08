# Jeju coastal microgrid reproducibility materials

This repository contains the data, model input files, C++ source code, selected hourly outputs, and checking scripts for the study on electrolyzer feedwater coupling in a renewable coastal microgrid.

## Model formulations

The repository uses the same three formulation names as the manuscript:

- **Full-coupled planning**: electrolyzer feedwater is included in the water balance during sizing and operation.
- **Feedwater-omitting sizing benchmark**: electrolyzer feedwater is omitted from the water balance during sizing.
- **Fixed-capacity full-coupled re-evaluation**: capacities from the feedwater-omitting benchmark are fixed and operation is re-solved with the complete water balance.

Short internal case IDs are retained only where needed for compatibility with archived solver output names. Their mapping to the manuscript terms is stated at the beginning of `source/Source.cpp`.

## Data

- `data/hourly_input.csv` contains the compact 8,760-hour input series.
- `software/model_input_full.csv` contains the full solver input used by the C++ model.
- `data/parameters.json` and `software/parameters.json` contain the model parameters.
- `results/` contains summary results and selected 8,760-hour dispatch files.
- `paper_data/` contains Data S1-S9, Tables S1-S3, and the public workbook used with the manuscript.
- `profile_inputs/` contains the flat 24-hour and 12-hour-shift hydrogen service profiles used in the timing sensitivity analysis.

The signed 2025 Jeju SMP is retained for both grid purchase and sale prices. The export price is 0.8 times the signed import-price basis.

## Source code

`source/Source.cpp` contains the annual MILP model. The project targets Windows x64, C++17, and IBM ILOG CPLEX Optimization Studio 22.1.2.

The final source file from the reported run was not retained. The source supplied here was reconstructed from the last archived project using the two confirmed source changes listed in `source/SOURCE_PATCH.diff`. A Release x64 build reproduced the three base reference results recorded in `validation/validated_base_result.txt`.

## Reproduction check

On a Windows computer with CPLEX 22.1.2 and a compatible Visual Studio C++ toolset, run:

```text
RUN_REPRODUCTION_CHECK.bat
```

The script checks the input files and model settings, builds the C++ project, runs the three base formulations, and compares the results with `validation/reference_base.json`.

The reproduction check covers the three base formulations. Machine-readable results for the other analyses reported in the manuscript are provided in `results/` and `paper_data/`.

## Hydrogen timing profiles

The alternative hydrogen service profiles can be recreated from the full solver input with:

```text
python code/create_h2_profile_inputs.py
```

Each alternative preserves the daily hydrogen requirement and the annual total.

## File integrity

`FILE_CHECKSUMS.csv` contains optional file checksums for checking whether repository files have changed after transfer or archiving. `code/verify_archive.py` checks these values together with the main input and result-table dimensions.

## Main directories

- `data/`: processed inputs and scenario definitions
- `paper_data/`: manuscript data files and public workbook
- `results/`: result summaries and selected hourly dispatch files
- `software/`: full solver input and parameter file
- `source/`: C++ source, Visual Studio project, and build files
- `validation/`: reference values and checking scripts
- `code/`: data and archive utilities
- `provenance/`: source-data register

## Software requirement

IBM ILOG CPLEX Optimization Studio 22.1.2 is required to build and run the optimization model. CPLEX libraries and license files are not distributed in this repository.

## Citation and license

This is release `v1.0.0`. Citation metadata are provided in `CITATION.cff`. The repository DOI and article DOI can be added after archival deposition and publication.

The source code, build files, and checking scripts are released under the MIT License in `LICENSE`. The research data and analysis outputs are released under CC BY 4.0 as described in `DATA_LICENSE.txt`. Third-party source data remain subject to the terms of their original providers.
