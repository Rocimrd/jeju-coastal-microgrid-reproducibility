# Build environment

The project is configured for Windows x64, C++17, and IBM ILOG CPLEX Optimization Studio 22.1.2. The Release configuration uses the MSVC dynamic runtime (`/MD`) and links `ilocplex.lib`, `concert.lib`, and `cplex2212.lib`.

The project file uses toolset `v145`. If this toolset is not installed, the build script accepts another compatible toolset through `REPRO_TOOLSET`.

Example for Visual Studio 2022 toolset `v143`:

```bat
set REPRO_TOOLSET=v143
source\build_release_x64.bat
```

The scripts search for CPLEX 22.1.2 through `CPLEX_ROOT`, `CPLEX_STUDIO_DIR2212`, and common Windows installation paths.
