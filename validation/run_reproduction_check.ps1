param()
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$SourceDir = Join-Path $RepositoryRoot 'source'
$InputFile = Join-Path $RepositoryRoot 'software\model_input_full.csv'
$ParameterFile = Join-Path $RepositoryRoot 'software\parameters.json'
$ResultDir = Join-Path $RepositoryRoot 'validation_work'
$CaseTag = 'REPOSITORY_BASE_WATER100_TAX150_H2D1000_GRIDCAP1.5_SELL80_H2UB100000_ELUB80_FCUB40_PVUB120_WTUB150'

if ($env:PUBLIC -and (Test-Path -LiteralPath $env:PUBLIC)) {
    $BaseDir = $env:PUBLIC
} elseif ($env:TEMP) {
    $BaseDir = $env:TEMP
} else {
    throw 'No temporary directory is available.'
}

$WorkDir = Join-Path $BaseDir 'JCMR_REPRO'
$RunInputDir = Join-Path $WorkDir 'in'
$RunSourceDir = Join-Path $WorkDir 'src'
$RunOutputDir = Join-Path $WorkDir 'out'
$RunInputFile = Join-Path $RunInputDir 'input.csv'
$RunParameterFile = Join-Path $RunInputDir 'params.json'
$CurrentStep = 'start'

function Get-PythonExe {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { return $python.Source }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) { return $py.Source }

    throw 'Python 3 was not found in PATH.'
}

function Find-Cplex2212 {
    $roots = @()
    if ($env:CPLEX_ROOT) { $roots += $env:CPLEX_ROOT }
    if ($env:CPLEX_STUDIO_DIR2212) { $roots += $env:CPLEX_STUDIO_DIR2212 }
    $roots += 'C:\Program Files\IBM\ILOG\CPLEX_Studio2212'
    $roots += 'C:\IBM\ILOG\CPLEX_Studio2212'

    foreach ($root in $roots) {
        if ($root -and (Test-Path -LiteralPath (Join-Path $root 'cplex\bin\x64_win64\cplex2212.dll'))) {
            return $root
        }
    }

    throw 'IBM ILOG CPLEX Optimization Studio 22.1.2 was not found. Set CPLEX_ROOT and run again.'
}

function Prepare-WorkDirectory {
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $WorkDir, $RunInputDir, $RunSourceDir | Out-Null
    Copy-Item -LiteralPath $InputFile -Destination $RunInputFile -Force
    Copy-Item -LiteralPath $ParameterFile -Destination $RunParameterFile -Force

    $sourceFiles = @(
        'Source.cpp',
        'JejuFullCoupled24h.vcxproj',
        'build_release_x64.bat',
        'configure_cplex_paths.bat',
        'CPLEX2212_x64_release.props'
    )

    foreach ($name in $sourceFiles) {
        $path = Join-Path $SourceDir $name
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required source file is missing: $path"
        }
        Copy-Item -LiteralPath $path -Destination (Join-Path $RunSourceDir $name) -Force
    }
}

function Read-Status([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 'Missing' }
    $row = Import-Csv -LiteralPath $Path | Where-Object { $_.metric -eq 'status' } | Select-Object -First 1
    if ($null -eq $row) { return 'Unknown' }
    return [string]$row.value
}

function Run-BaseFormulations([string]$Exe) {
    if (Test-Path -LiteralPath $RunOutputDir) {
        Remove-Item -LiteralPath $RunOutputDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $RunOutputDir | Out-Null

    $fullPlanning = "C1_$CaseTag"
    $feedwaterOmitting = "C2_$CaseTag"
    $fixedCapacityReevaluation = "C3_$CaseTag"

    $cases = @(
        @{ id = $fullPlanning; label = 'Full-coupled planning'; kind = 'full_coupled_C1'; capacity = '' },
        @{ id = $feedwaterOmitting; label = 'Feedwater-omitting sizing benchmark'; kind = 'decoupled_C2'; capacity = '' },
        @{
            id = $fixedCapacityReevaluation
            label = 'Fixed-capacity full-coupled re-evaluation'
            kind = 'expost_C3'
            capacity = Join-Path $RunOutputDir "capacity_decoupled_C2_${feedwaterOmitting}.csv"
        }
    )

    foreach ($case in $cases) {
        Write-Host "[RUN] $($case.label)"
        $args = @('--single', $RunInputFile, $RunParameterFile, $RunOutputDir, $case.id)
        if ($case.capacity) { $args += $case.capacity }

        & $Exe @args
        if ($LASTEXITCODE -ne 0) {
            throw "Solver failed: $($case.label)"
        }

        $summary = Join-Path $RunOutputDir "summary_$($case.kind)_$($case.id).csv"
        if ((Read-Status $summary) -ne 'Optimal') {
            throw "Optimal solution was not found: $($case.label)"
        }
    }
}

function Save-Result([string]$Status, [string]$Detail) {
    New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null
    $resultFile = Join-Path $ResultDir 'REPRODUCTION_CHECK.txt'
    @(
        "STATUS=$Status",
        "STEP=$CurrentStep",
        "DETAIL=$Detail",
        "SOLVER=IBM ILOG CPLEX Optimization Studio 22.1.2",
        "COMPLETED_AT=$(Get-Date -Format o)"
    ) | Set-Content -LiteralPath $resultFile -Encoding UTF8

    $comparison = Join-Path $RunOutputDir 'BASE_FORMULATION_REPRODUCTION.txt'
    if (Test-Path -LiteralPath $comparison) {
        Copy-Item -LiteralPath $comparison -Destination (Join-Path $ResultDir 'BASE_FORMULATION_REPRODUCTION.txt') -Force
    }

    return $resultFile
}

$Python = Get-PythonExe

try {
    $CurrentStep = 'static_validation'
    Write-Host '[1/5] Static validation'
    & $Python (Join-Path $RepositoryRoot 'validation\validate_static.py')
    if ($LASTEXITCODE -ne 0) { throw 'Static validation failed.' }

    $CurrentStep = 'cplex_detection'
    Write-Host '[2/5] CPLEX 22.1.2 detection'
    $CplexRoot = Find-Cplex2212
    $env:CPLEX_ROOT = $CplexRoot
    $env:Path = "$(Join-Path $CplexRoot 'cplex\bin\x64_win64');$env:Path"
    Write-Host "[OK] $CplexRoot"

    $CurrentStep = 'prepare_work_directory'
    Write-Host '[3/5] Prepare work directory'
    Prepare-WorkDirectory
    Write-Host "[OK] $WorkDir"

    $CurrentStep = 'build'
    Write-Host '[4/5] Build source'
    Push-Location $RunSourceDir
    try {
        & (Join-Path $RunSourceDir 'build_release_x64.bat')
        if ($LASTEXITCODE -ne 0) { throw 'Release x64 build failed.' }
    } finally {
        Pop-Location
    }

    $Exe = Join-Path $RunSourceDir 'x64\Release\JejuFullCoupled24h.exe'
    if (-not (Test-Path -LiteralPath $Exe)) { throw 'Built executable was not found.' }

    $CurrentStep = 'base_case_reproduction'
    Write-Host '[5/5] Run and compare the three base formulations'
    Run-BaseFormulations $Exe
    & $Python (Join-Path $RepositoryRoot 'validation\compare_base_run.py') $RunOutputDir
    if ($LASTEXITCODE -ne 0) { throw 'Base-case comparison failed.' }

    $resultFile = Save-Result 'PASS' 'Static checks, build, and base-formulation comparison passed.'
    Write-Host ''
    Write-Host 'REPRODUCTION CHECK: PASS'
    Write-Host "Result: $resultFile"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $resultFile = Save-Result 'FAIL' $message
    Write-Host ''
    Write-Host 'REPRODUCTION CHECK: FAIL' -ForegroundColor Red
    Write-Host "Step: $CurrentStep" -ForegroundColor Red
    Write-Host "Reason: $message" -ForegroundColor Red
    Write-Host "Result: $resultFile"
    exit 1
}
