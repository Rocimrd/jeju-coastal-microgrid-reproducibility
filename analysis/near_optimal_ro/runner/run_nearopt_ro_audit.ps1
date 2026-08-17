Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$SourceDir = Join-Path $Root "source"
$InputCsv = Join-Path $Root "input\model_input_full.csv"
$ParamJson = Join-Path $Root "input\parameters.json"
$BuildBat = Join-Path $SourceDir "build_release_x64.bat"
$Exe = Join-Path $SourceDir "x64\Release\JejuFullCoupled24h.exe"
$ResultsRoot = Join-Path $Root "results"

$Epsilon = 1.0e-4
$TightMipGap = 1.0e-6
$AuditMipGap = 1.0e-6
$TimeLimitSec = 3600.0

$WaterScales = @(50, 75, 100, 125, 150)
$H2Services = @(1000, 3000, 5000, 8000, 10000)
$Formulations = @("C1", "C2")
$Modes = @("BASE", "MINRO", "MAXRO")
$TotalPlannedSolves = $WaterScales.Count * $H2Services.Count * $Formulations.Count * $Modes.Count

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $ResultsRoot ("nearopt_ro_audit_" + $stamp)
$SolverOutDir = Join-Path $RunDir "solver_outputs"
$LogDir = Join-Path $RunDir "logs"
New-Item -ItemType Directory -Path $SolverOutDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$RunLog = Join-Path $RunDir "RUN_LOG.txt"
$AllRunsCsv = Join-Path $RunDir "RO_AUDIT_ALL_RUNS.csv"
$PairwiseCsv = Join-Path $RunDir "RO_AUDIT_PAIRWISE_RANGES.csv"
$SummaryTxt = Join-Path $RunDir "RO_AUDIT_SUMMARY.txt"
$HashTxt = Join-Path $RunDir "FILE_HASHES.txt"
$ConfigTxt = Join-Path $RunDir "AUDIT_CONFIGURATION_USED.txt"

$GlobalStart = Get-Date
$CompletedAttempts = 0
$RunRows = New-Object System.Collections.Generic.List[object]
$PairRows = New-Object System.Collections.Generic.List[object]
$RangeStore = @{}
$AnyFailure = $false

$Invariant = [Globalization.CultureInfo]::InvariantCulture

function Write-RunLog {
    param([string]$Text = "")
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    Write-Host $line
    Add-Content -LiteralPath $RunLog -Value $line -Encoding UTF8
}

function Assert-File {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ("Missing {0}: {1}" -f $Label, $Path)
    }
}

function Assert-Near {
    param([double]$Actual, [double]$Expected, [double]$Tolerance, [string]$Label)
    if ([double]::IsNaN($Actual) -or [math]::Abs($Actual - $Expected) -gt $Tolerance) {
        throw ("{0} mismatch: actual={1:R}, expected={2:R}, tolerance={3:R}" -f $Label, $Actual, $Expected, $Tolerance)
    }
}

function Parse-DoubleInvariant {
    param([string]$Text, [string]$Label)
    $v = 0.0
    if (-not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, $Invariant, [ref]$v)) {
        throw ("Cannot parse {0} as double: {1}" -f $Label, $Text)
    }
    return $v
}

function Read-MetricFile {
    param([string]$Path)
    Assert-File $Path "summary file"
    $map = @{}
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $map[[string]$row.metric] = [string]$row.value
    }
    return $map
}

function Metric-String {
    param($Map, [string]$Name)
    if (-not $Map.ContainsKey($Name)) { throw ("Missing metric: {0}" -f $Name) }
    return [string]$Map[$Name]
}

function Metric-Double {
    param($Map, [string]$Name)
    $raw = Metric-String $Map $Name
    return (Parse-DoubleInvariant $raw $Name)
}

function Read-CapacityFile {
    param([string]$Path)
    Assert-File $Path "capacity file"
    $map = @{}
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $map[[string]$row.capacity] = Parse-DoubleInvariant ([string]$row.value) ([string]$row.capacity)
    }
    return $map
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1.0) {
        return ("{0:0} h {1:00} min {2:00} s" -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
    }
    return ("{0:0} min {1:00} s" -f [math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Write-ProgressEstimate {
    if ($CompletedAttempts -le 0) { return }
    $elapsed = (Get-Date) - $GlobalStart
    $avgSec = $elapsed.TotalSeconds / [double]$CompletedAttempts
    $remaining = [math]::Max(0, $TotalPlannedSolves - $CompletedAttempts)
    $etaSpan = [TimeSpan]::FromSeconds($avgSec * $remaining)
    $finish = (Get-Date).Add($etaSpan)
    Write-RunLog ("Progress {0}/{1} | average {2:0.0} s/solve | ETA {3} | estimated finish {4}" -f `
        $CompletedAttempts, $TotalPlannedSolves, $avgSec, (Format-Duration $etaSpan), $finish.ToString("yyyy-MM-dd HH:mm:ss"))
}

function Quote-Arg {
    param([string]$s)
    return ('"' + $s.Replace('"','\"') + '"')
}

function Invoke-AuditSolve {
    param(
        [int]$WaterScale,
        [int]$H2Service,
        [string]$Formulation,
        [string]$Mode,
        [double]$EconomicUB
    )

    $global:CompletedAttempts += 1
    $caseId = "{0}_EPS{1}_WATER{2}_H2D{3}_GRIDCAP1.5_TAX150" -f $Formulation, $Mode, $WaterScale, $H2Service

    $prefix = if ($Formulation -eq "C2") { "decoupled_C2" } else { "full_coupled_C1" }
    $summaryPath = Join-Path $SolverOutDir ("summary_{0}_{1}.csv" -f $prefix, $caseId)
    $capacityPath = Join-Path $SolverOutDir ("capacity_{0}_{1}.csv" -f $prefix, $caseId)

    $safe = ($caseId -replace '[^A-Za-z0-9_.-]', '_')
    $stdoutPath = Join-Path $LogDir ($safe + "_stdout.txt")
    $stderrPath = Join-Path $LogDir ($safe + "_stderr.txt")

    $mipGap = if ($Mode -eq "BASE") { $TightMipGap } else { $AuditMipGap }
    $ubText = $EconomicUB.ToString("R", $Invariant)
    $gapText = $mipGap.ToString("R", $Invariant)
    $timeText = $TimeLimitSec.ToString("R", $Invariant)

    Write-RunLog ""
    Write-RunLog ("[SOLVE {0}/{1}] Water={2}% | H2={3} kg-H2/day | {4} | {5}" -f `
        $CompletedAttempts, $TotalPlannedSolves, $WaterScale, $H2Service, $Formulation, $Mode)

    $args = @(
        "--audit",
        (Quote-Arg $InputCsv),
        (Quote-Arg $ParamJson),
        (Quote-Arg $SolverOutDir),
        $caseId,
        $Mode,
        $ubText,
        $gapText,
        $timeText
    )

    $start = Get-Date
    $proc = Start-Process -FilePath $Exe -ArgumentList $args -WorkingDirectory $Root `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -NoNewWindow

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 30
        $proc.Refresh()
        $elapsed = (Get-Date) - $start
        Write-RunLog ("RUNNING | elapsed {0} | solver time limit {1:0} s" -f (Format-Duration $elapsed), $TimeLimitSec)
    }
    $proc.WaitForExit()
    $proc.Refresh()

    $exitCode = [int]$proc.ExitCode
    $elapsedFinal = (Get-Date) - $start

    if (Test-Path -LiteralPath $stdoutPath) {
        $tail = Get-Content -LiteralPath $stdoutPath -Tail 12 -Encoding UTF8
        foreach ($line in $tail) { Write-RunLog ("solver: " + $line) }
    }
    if (Test-Path -LiteralPath $stderrPath) {
        $errLines = Get-Content -LiteralPath $stderrPath -Encoding UTF8
        foreach ($line in $errLines) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-RunLog ("solver stderr: " + $line) }
        }
    }

    $status = "MISSING"
    $econObj = [double]::NaN
    $auditObj = [double]::NaN
    $bestBound = [double]::NaN
    $gap = [double]::NaN
    $wall = [double]::NaN
    $waterShort = [double]::NaN
    $h2Short = [double]::NaN
    $kro = [double]::NaN

    if (Test-Path -LiteralPath $summaryPath) {
        try {
            $m = Read-MetricFile $summaryPath
            $status = Metric-String $m "status"
            if ($m.ContainsKey("economic_objective_USD") -and $m["economic_objective_USD"] -ne "NaN") {
                $econObj = Metric-Double $m "economic_objective_USD"
            }
            if ($m.ContainsKey("audit_objective_value") -and $m["audit_objective_value"] -ne "NaN") {
                $auditObj = Metric-Double $m "audit_objective_value"
            }
            if ($m.ContainsKey("best_bound") -and $m["best_bound"] -ne "NaN") {
                $bestBound = Metric-Double $m "best_bound"
            }
            if ($m.ContainsKey("achieved_relative_mip_gap") -and $m["achieved_relative_mip_gap"] -ne "NaN") {
                $gap = Metric-Double $m "achieved_relative_mip_gap"
            }
            if ($m.ContainsKey("solve_wall_time_s")) { $wall = Metric-Double $m "solve_wall_time_s" }
            if ($m.ContainsKey("total_freshwater_shortage_m3")) { $waterShort = Metric-Double $m "total_freshwater_shortage_m3" }
            if ($m.ContainsKey("total_H2_shortage_kg")) { $h2Short = Metric-Double $m "total_H2_shortage_kg" }
        } catch {
            Write-RunLog ("Summary parsing error: " + $_.Exception.Message)
            $global:AnyFailure = $true
        }
    }

    if (Test-Path -LiteralPath $capacityPath) {
        try {
            $c = Read-CapacityFile $capacityPath
            if ($c.ContainsKey("K_RO")) { $kro = [double]$c["K_RO"] }
        } catch {
            Write-RunLog ("Capacity parsing error: " + $_.Exception.Message)
            $global:AnyFailure = $true
        }
    }

    $ok = ($exitCode -eq 0 -and $status -eq "Optimal" -and -not [double]::IsNaN($kro) -and -not [double]::IsNaN($econObj))
    if ($Mode -ne "BASE" -and $ok) {
        $tol = [math]::Max(0.05, [math]::Abs($EconomicUB) * 2.0e-8)
        if ($econObj -gt $EconomicUB + $tol) {
            Write-RunLog ("FAIL: near-optimal economic objective exceeds bound. objective={0:R}, bound={1:R}" -f $econObj, $EconomicUB)
            $ok = $false
        }
    }
    if (-not $ok) { $global:AnyFailure = $true }

    $row = [pscustomobject][ordered]@{
        water_scale_percent = $WaterScale
        H2_service_kg_day = $H2Service
        formulation = $Formulation
        audit_mode = $Mode
        cplex_status = $status
        process_exit_code = $exitCode
        economic_objective_USD = $econObj
        economic_objective_upper_bound_USD = $(if ($Mode -eq "BASE") { [double]::NaN } else { $EconomicUB })
        K_RO_m3_h = $kro
        audit_objective_value = $auditObj
        best_bound = $bestBound
        achieved_relative_mip_gap = $gap
        solve_wall_time_s = $wall
        freshwater_shortage_m3_yr = $waterShort
        H2_shortage_kg_yr = $h2Short
        summary_file = [IO.Path]::GetFileName($summaryPath)
        capacity_file = [IO.Path]::GetFileName($capacityPath)
        successful = $(if ($ok) { 1 } else { 0 })
    }
    $RunRows.Add($row)
    $RunRows | Export-Csv -LiteralPath $AllRunsCsv -NoTypeInformation -Encoding UTF8

    Write-RunLog ("END | exit={0} | status={1} | K_RO={2} | econObj={3} | elapsed {4}" -f `
        $exitCode, $status, $kro, $econObj, (Format-Duration $elapsedFinal))
    Write-ProgressEstimate

    return $row
}

function Save-RangeRecord {
    param([int]$WaterScale, [int]$H2Service, [string]$Formulation, $BaseRow, $MinRow, $MaxRow)

    $key = "{0}_{1}_{2}" -f $WaterScale, $H2Service, $Formulation
    if ($null -eq $BaseRow -or $null -eq $MinRow -or $null -eq $MaxRow) {
        $RangeStore[$key] = $null
        return
    }
    if ($BaseRow.successful -ne 1 -or $MinRow.successful -ne 1 -or $MaxRow.successful -ne 1) {
        $RangeStore[$key] = $null
        return
    }

    $baseK = [double]$BaseRow.K_RO_m3_h
    $minK = [double]$MinRow.K_RO_m3_h
    $maxK = [double]$MaxRow.K_RO_m3_h
    $tol = 1.0e-4
    if ($minK -gt $baseK + $tol -or $maxK -lt $baseK - $tol -or $minK -gt $maxK + $tol) {
        Write-RunLog ("FAIL: RO interval consistency check failed for {0}" -f $key)
        $global:AnyFailure = $true
    }

    $RangeStore[$key] = [pscustomobject]@{
        baseline_objective_USD = [double]$BaseRow.economic_objective_USD
        objective_upper_bound_USD = [double]$MinRow.economic_objective_upper_bound_USD
        baseline_K_RO_m3_h = $baseK
        min_K_RO_m3_h = $minK
        max_K_RO_m3_h = $maxK
        min_shortage_m3 = [double]$MinRow.freshwater_shortage_m3_yr
        max_shortage_m3 = [double]$MaxRow.freshwater_shortage_m3_yr
        min_H2_shortage_kg = [double]$MinRow.H2_shortage_kg_yr
        max_H2_shortage_kg = [double]$MaxRow.H2_shortage_kg_yr
    }
}

function Build-PairwiseTable {
    $PairRows.Clear()
    foreach ($w in $WaterScales) {
        foreach ($h in $H2Services) {
            $refKey = "{0}_{1}_C1" -f $w, $h
            $omitKey = "{0}_{1}_C2" -f $w, $h
            $ref = if ($RangeStore.ContainsKey($refKey)) { $RangeStore[$refKey] } else { $null }
            $omit = if ($RangeStore.ContainsKey($omitKey)) { $RangeStore[$omitKey] } else { $null }

            if ($null -eq $ref -or $null -eq $omit) {
                $PairRows.Add([pscustomobject][ordered]@{
                    water_scale_percent = $w
                    H2_service_kg_day = $h
                    reference_opt_K_RO = [double]::NaN
                    benchmark_opt_K_RO = [double]::NaN
                    optimum_deviation_percent = [double]::NaN
                    reference_min_K_RO = [double]::NaN
                    reference_max_K_RO = [double]::NaN
                    benchmark_min_K_RO = [double]::NaN
                    benchmark_max_K_RO = [double]::NaN
                    separation_margin_m3_h = [double]::NaN
                    range_relation = "INCOMPLETE"
                })
                continue
            }

            $dev = 100.0 * ($omit.baseline_K_RO_m3_h - $ref.baseline_K_RO_m3_h) / $ref.baseline_K_RO_m3_h
            $margin = $ref.min_K_RO_m3_h - $omit.max_K_RO_m3_h
            $relation = if ($margin -gt 1.0e-4) { "STRICT_SEPARATION" } else { "OVERLAP_OR_TOUCH" }

            $PairRows.Add([pscustomobject][ordered]@{
                water_scale_percent = $w
                H2_service_kg_day = $h
                reference_opt_K_RO = $ref.baseline_K_RO_m3_h
                benchmark_opt_K_RO = $omit.baseline_K_RO_m3_h
                optimum_deviation_percent = $dev
                reference_min_K_RO = $ref.min_K_RO_m3_h
                reference_max_K_RO = $ref.max_K_RO_m3_h
                benchmark_min_K_RO = $omit.min_K_RO_m3_h
                benchmark_max_K_RO = $omit.max_K_RO_m3_h
                separation_margin_m3_h = $margin
                range_relation = $relation
            })
        }
    }
    $PairRows | Export-Csv -LiteralPath $PairwiseCsv -NoTypeInformation -Encoding UTF8
}

function Write-FinalSummary {
    Build-PairwiseTable

    $complete = @($PairRows | Where-Object { $_.range_relation -ne "INCOMPLETE" }).Count
    $strict = @($PairRows | Where-Object { $_.range_relation -eq "STRICT_SEPARATION" }).Count
    $overlap = @($PairRows | Where-Object { $_.range_relation -eq "OVERLAP_OR_TOUCH" }).Count
    $optimumLower = @($PairRows | Where-Object { $_.range_relation -ne "INCOMPLETE" -and $_.benchmark_opt_K_RO -lt $_.reference_opt_K_RO }).Count

    $status = if ($AnyFailure -or $complete -ne 25) { "INCOMPLETE" } else { "COMPLETE" }
    $elapsed = (Get-Date) - $GlobalStart

    $lines = @(
        "Near-optimal RO-capacity robustness audit",
        "",
        ("STATUS = {0}" -f $status),
        ("Completed condition pairs = {0}/25" -f $complete),
        ("Optimum benchmark K_RO lower than reference = {0}/{1}" -f $optimumLower, $complete),
        ("Strictly separated epsilon-optimal RO ranges = {0}/{1}" -f $strict, $complete),
        ("Overlapping/touching epsilon-optimal RO ranges = {0}/{1}" -f $overlap, $complete),
        ("epsilon = {0:R}" -f $Epsilon),
        ("baseline MIP-gap target = {0:R}" -f $TightMipGap),
        ("range-solve MIP-gap target = {0:R}" -f $AuditMipGap),
        ("time limit per annual MILP = {0:R} s" -f $TimeLimitSec),
        ("elapsed = {0}" -f (Format-Duration $elapsed)),
        "",
        "Interpretation rule",
        "STRICT_SEPARATION means benchmark max K_RO < reference min K_RO within the defined epsilon-optimal economic sets.",
        "OVERLAP_OR_TOUCH means the two epsilon-optimal RO-capacity intervals are not strictly separated.",
        "This file reports the numerical audit only. Manuscript wording should be decided after reviewing the complete result table."
    )
    Set-Content -LiteralPath $SummaryTxt -Value $lines -Encoding UTF8
}

function Make-UploadZip {
    $zip = Join-Path $ResultsRoot ("UPLOAD_NEAROPT_RO_AUDIT_RESULT_" + $stamp + ".zip")
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $RunDir "*") -DestinationPath $zip -CompressionLevel Optimal
    Write-RunLog ("Upload ZIP: {0}" -f $zip)
    return $zip
}

try {
    Write-RunLog "Near-optimal RO-capacity audit started."
    Write-RunLog ("Planned annual MILPs: {0}" -f $TotalPlannedSolves)
    Write-RunLog ("epsilon={0:R}, baseline gap={1:R}, range gap={2:R}, time limit={3:R} s" -f `
        $Epsilon, $TightMipGap, $AuditMipGap, $TimeLimitSec)

    # Preflight
    Assert-File $InputCsv "annual input"
    Assert-File $ParamJson "parameter file"
    Assert-File (Join-Path $SourceDir "Source.cpp") "model source"
    Assert-File (Join-Path $SourceDir "JejuFullCoupled24h.vcxproj") "Visual Studio project"
    Assert-File $BuildBat "build script"

    $lineCount = (Get-Content -LiteralPath $InputCsv -ReadCount 5000 | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    if ($lineCount -ne 8761) {
        throw ("Annual input line count mismatch: {0}; expected 8761 including header." -f $lineCount)
    }

    $inputHash = (Get-FileHash -LiteralPath $InputCsv -Algorithm SHA256).Hash.ToLowerInvariant()
    $paramHash = (Get-FileHash -LiteralPath $ParamJson -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($inputHash -ne "d687bf311e879ab548d68d873c21856dc451f8ac6d639c34f36fb433c6bc7fbf") {
        throw ("Annual input SHA256 mismatch: {0}" -f $inputHash)
    }
    if ($paramHash -ne "31ccda915f3a5a184e09d43ec838d93af37c67c15f35f94690659bf51cbbc74b") {
        throw ("Parameter SHA256 mismatch: {0}" -f $paramHash)
    }

    $p = Get-Content -LiteralPath $ParamJson -Raw | ConvertFrom-Json
    Assert-Near ([double]$p.electrolyzer.rho_EL_m3_per_kgH2) 0.013 1e-12 "EL feedwater coefficient"
    Assert-Near ([double]$p.electrolyzer.kappa_EL_kWh_per_kgH2) 49.9 1e-12 "EL electricity coefficient"
    Assert-Near ([double]$p.ro.SEC_kWh_per_m3) 2.864 1e-12 "RO SEC"
    Assert-Near ([double]$p.shortage_and_policy.freshwater_shortage_penalty_USD_per_m3) 100.0 1e-12 "Freshwater shortage coefficient"
    Assert-Near ([double]$p.shortage_and_policy.hydrogen_shortage_penalty_USD_per_kg) 2500.0 1e-12 "H2 shortage coefficient"

    $src = Get-Content -LiteralPath (Join-Path $SourceDir "Source.cpp") -Raw
    foreach ($marker in @(
        "enum class AuditMode",
        "economicObj <= nearOptEconomicUB",
        "IloMinimize(env, K_RO)",
        "IloMaximize(env, K_RO)",
        "getBestObjValue",
        "getMIPRelativeGap"
    )) {
        if ($src -notlike ("*" + $marker + "*")) { throw ("Source audit marker missing: {0}" -f $marker) }
    }

    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $SourceDir "Source.cpp") -Algorithm SHA256).Hash.ToLowerInvariant()
    @(
        ("input/model_input_full.csv SHA256 = {0}" -f $inputHash),
        ("input/parameters.json SHA256 = {0}" -f $paramHash),
        ("source/Source.cpp SHA256 = {0}" -f $sourceHash)
    ) | Set-Content -LiteralPath $HashTxt -Encoding UTF8

    @(
        "water scales = 50,75,100,125,150 percent",
        "H2 service = 1000,3000,5000,8000,10000 kg-H2/day",
        "formulations = C1 fully coupled reference; C2 feedwater-omitting benchmark",
        ("epsilon = {0:R}" -f $Epsilon),
        ("baseline MIP gap = {0:R}" -f $TightMipGap),
        ("range MIP gap = {0:R}" -f $AuditMipGap),
        ("time limit = {0:R} s" -f $TimeLimitSec),
        "objective cap = (1 + epsilon) times the feasible economic objective from the tighter baseline solve"
    ) | Set-Content -LiteralPath $ConfigTxt -Encoding UTF8

    Write-RunLog "PASS: locked inputs, parameters, and audit source markers."

    # Build
    Write-RunLog ""
    Write-RunLog "[BUILD] Release x64"
    if (Test-Path -LiteralPath $Exe) { Remove-Item -LiteralPath $Exe -Force }
    $buildStdout = Join-Path $LogDir "build_stdout.txt"
    $buildStderr = Join-Path $LogDir "build_stderr.txt"
    $buildStart = Get-Date
    $buildArgs = @("/d", "/s", "/c", "call build_release_x64.bat")
    $bp = Start-Process -FilePath "cmd.exe" -ArgumentList $buildArgs -WorkingDirectory $SourceDir `
        -RedirectStandardOutput $buildStdout -RedirectStandardError $buildStderr -PassThru -NoNewWindow
    $bp.WaitForExit()
    $bp.Refresh()

    if (Test-Path -LiteralPath $buildStdout) {
        foreach ($line in (Get-Content -LiteralPath $buildStdout -Tail 30 -Encoding UTF8)) { Write-RunLog ("build: " + $line) }
    }
    if (Test-Path -LiteralPath $buildStderr) {
        foreach ($line in (Get-Content -LiteralPath $buildStderr -Encoding UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-RunLog ("build stderr: " + $line) }
        }
    }

    $exeExists = Test-Path -LiteralPath $Exe -PathType Leaf
    $exeFresh = $false
    if ($exeExists) {
        $exeFresh = ((Get-Item -LiteralPath $Exe).LastWriteTime -ge $buildStart.AddSeconds(-2))
    }
    $buildMarker = $false
    if (Test-Path -LiteralPath $buildStdout) {
        $buildMarker = [bool](Select-String -LiteralPath $buildStdout -SimpleMatch '[OK] Built x64\Release\JejuFullCoupled24h.exe' -Quiet)
    }
    if (-not ($exeFresh -and $buildMarker)) {
        throw ("Release x64 build gate failed. process exit={0}, exeFresh={1}, successMarker={2}" -f $bp.ExitCode, $exeFresh, $buildMarker)
    }
    Write-RunLog "PASS: fresh Release x64 executable built."

    # 25-condition audit
    foreach ($w in $WaterScales) {
        foreach ($h in $H2Services) {
            Write-RunLog ""
            Write-RunLog ("========== CONDITION: water={0}%, H2={1} kg-H2/day ==========" -f $w, $h)

            foreach ($form in $Formulations) {
                $baseRow = Invoke-AuditSolve -WaterScale $w -H2Service $h -Formulation $form -Mode "BASE" -EconomicUB 0.0

                if ($baseRow.successful -ne 1) {
                    Write-RunLog ("Skipping MINRO/MAXRO for {0}, water={1}, H2={2} because BASE did not complete optimally." -f $form, $w, $h)
                    $global:AnyFailure = $true
                    Save-RangeRecord -WaterScale $w -H2Service $h -Formulation $form -BaseRow $baseRow -MinRow $null -MaxRow $null
                    $global:CompletedAttempts += 2
                    Write-RunLog ("Two dependent range solves marked skipped. Progress index advanced to {0}/{1}." -f $CompletedAttempts, $TotalPlannedSolves)
                    continue
                }

                $jstar = [double]$baseRow.economic_objective_USD
                $ub = $jstar * (1.0 + $Epsilon)

                $minRow = Invoke-AuditSolve -WaterScale $w -H2Service $h -Formulation $form -Mode "MINRO" -EconomicUB $ub
                $maxRow = Invoke-AuditSolve -WaterScale $w -H2Service $h -Formulation $form -Mode "MAXRO" -EconomicUB $ub

                Save-RangeRecord -WaterScale $w -H2Service $h -Formulation $form -BaseRow $baseRow -MinRow $minRow -MaxRow $maxRow
            }
        }
    }

    Write-FinalSummary
    $zip = Make-UploadZip

    $finalComplete = -not $AnyFailure
    if ($finalComplete) {
        Write-RunLog "AUDIT COMPLETE."
        Write-RunLog ("Upload this file: {0}" -f $zip)
        exit 0
    } else {
        Write-RunLog "AUDIT INCOMPLETE: one or more solves or consistency gates did not pass."
        Write-RunLog ("Upload the partial result file for diagnosis: {0}" -f $zip)
        exit 2
    }
}
catch {
    $global:AnyFailure = $true
    Write-RunLog ("FATAL: " + $_.Exception.Message)
    try { Write-FinalSummary } catch { Write-RunLog ("Could not build final summary: " + $_.Exception.Message) }
    try {
        $zip = Make-UploadZip
        Write-RunLog ("Partial result ZIP created: {0}" -f $zip)
    } catch {
        Write-RunLog ("Could not create partial result ZIP: " + $_.Exception.Message)
    }
    exit 3
}
