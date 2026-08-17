Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$SourceDir = Join-Path $Root "source"
$InputCsv = Join-Path $Root "input\model_input_full.csv"
$ParamJson = Join-Path $Root "input\parameters.json"
$BuildBat = Join-Path $SourceDir "build_release_x64.bat"
$Exe = Join-Path $SourceDir "x64\Release\JejuFullCoupled24h.exe"
$ResultsRoot = Join-Path $Root "results"

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $ResultsRoot ("hard_service_run_" + $stamp)
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
$RunLog = Join-Path $RunDir "RUN_LOG.txt"
$ResultTxt = Join-Path $RunDir "HARD_SERVICE_RESULT.txt"
$ResultCsv = Join-Path $RunDir "HARD_SERVICE_RESULT.csv"

$GlobalStart = Get-Date
$StageTotal = 5

function Write-RunLog {
    param([string]$Text = "")
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Text
    Write-Host $line
    Add-Content -Path $RunLog -Value $line -Encoding UTF8
}

function Write-Stage {
    param([int]$Index, [string]$Name)
    Write-RunLog ""
    Write-RunLog ("[STAGE {0}/{1}] {2}" -f $Index, $StageTotal, $Name)
}

function Format-Duration {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) {
        return ("{0:0} h {1:00} min {2:00} s" -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
    }
    return ("{0:0} min {1:00} s" -f [math]::Floor($Span.TotalMinutes), $Span.Seconds)
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

function Read-MetricFile {
    param([string]$Path)
    Assert-File $Path "summary file"
    $map = @{}
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $map[[string]$row.metric] = [string]$row.value
    }
    return $map
}

function Metric-Double {
    param($Map, [string]$Name)
    if (-not $Map.ContainsKey($Name)) { throw "Missing metric '$Name'." }
    $v = [string]$Map[$Name]
    $out = 0.0
    if (-not [double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$out)) {
        throw "Metric '$Name' is not numeric: $v"
    }
    return $out
}

function Read-CapacityFile {
    param([string]$Path)
    Assert-File $Path "capacity file"
    $map = @{}
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $val = 0.0
        if (-not [double]::TryParse([string]$row.value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
            throw "Non-numeric capacity value in $Path"
        }
        $map[[string]$row.capacity] = $val
    }
    return $map
}

function Append-ProcessOutput {
    param([string]$StdoutPath, [string]$StderrPath, [string]$Label)
    Write-RunLog ("--- {0} stdout ---" -f $Label)
    if (Test-Path -LiteralPath $StdoutPath) {
        foreach ($line in Get-Content -LiteralPath $StdoutPath -Encoding UTF8) {
            Write-Host $line
            Add-Content -Path $RunLog -Value $line -Encoding UTF8
        }
    }
    Write-RunLog ("--- {0} stderr ---" -f $Label)
    if (Test-Path -LiteralPath $StderrPath) {
        foreach ($line in Get-Content -LiteralPath $StderrPath -Encoding UTF8) {
            Write-Host $line
            Add-Content -Path $RunLog -Value $line -Encoding UTF8
        }
    }
}

function Invoke-NativeWithHeartbeat {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$Label,
        [int]$HeartbeatSeconds = 15,
        [int]$MaxMinutesForMessage = 60
    )

    $safe = ($Label -replace '[^A-Za-z0-9_-]', '_')
    $stdout = Join-Path $RunDir ($safe + "_stdout.txt")
    $stderr = Join-Path $RunDir ($safe + "_stderr.txt")
    if (Test-Path $stdout) { Remove-Item $stdout -Force }
    if (Test-Path $stderr) { Remove-Item $stderr -Force }

    $start = Get-Date
    Write-RunLog ("START {0}" -f $Label)
    Write-RunLog ("Start time: {0}" -f $start.ToString("yyyy-MM-dd HH:mm:ss"))

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds $HeartbeatSeconds
        $proc.Refresh()
        $elapsed = (Get-Date) - $start
        Write-RunLog ("RUNNING {0} | elapsed {1} | solver time limit per case is 60 min" -f $Label, (Format-Duration $elapsed))
    }
    $proc.WaitForExit()
    $end = Get-Date
    $elapsedFinal = $end - $start
    Append-ProcessOutput -StdoutPath $stdout -StderrPath $stderr -Label $Label
    Write-RunLog ("END {0} | exit code={1} | elapsed {2}" -f $Label, $proc.ExitCode, (Format-Duration $elapsedFinal))
    return [int]$proc.ExitCode
}

function Invoke-SolverCase {
    param(
        [int]$CaseIndex,
        [string]$Label,
        [string]$CaseId,
        [string]$CapacityFix = ""
    )

    Write-RunLog ""
    Write-RunLog ("[CASE {0}/3] {1}" -f $CaseIndex, $Label)
    Write-RunLog "Scenario: freshwater scale=50%, external H2 service=8000 kg-H2/day, carbon price=150 USD/tCO2-eq, PCC=1.5 MW"
    Write-RunLog ("Internal case ID: {0}" -f $CaseId)

    $args = @(
        "--single",
        ('"' + $InputCsv + '"'),
        ('"' + $ParamJson + '"'),
        ('"' + $RunDir + '"'),
        $CaseId
    )
    if ($CapacityFix -ne "") {
        $args += ('"' + $CapacityFix + '"')
    }

    return Invoke-NativeWithHeartbeat -FilePath $Exe -ArgumentList $args -WorkingDirectory $Root -Label ("case{0}_{1}" -f $CaseIndex, $Label) -HeartbeatSeconds 15
}

function Save-Result {
    param(
        [string]$DiagnosticStatus,
        [string]$SolverStatus,
        [string]$Interpretation,
        [string]$HardSummaryPath,
        [int]$ExitCode
    )

    $elapsed = (Get-Date) - $GlobalStart
    $lines = @(
        "Hard-service feasibility check",
        "",
        "Scenario: freshwater scale = 50%",
        "External H2 service = 8000 kg-H2/day",
        "Carbon price = 150 USD/tCO2-eq",
        "PCC import/export limit = 1.5 MW",
        "Capacities = feedwater-omitting benchmark capacities",
        "Restored model = full coupled water balance",
        "Hard service constraints = freshwater shortage 0 and H2 shortage 0 in every hour",
        "",
        ("DIAGNOSTIC_STATUS = {0}" -f $DiagnosticStatus),
        ("CPLEX_STATUS = {0}" -f $SolverStatus),
        ("RUNNER_EXIT_CODE = {0}" -f $ExitCode),
        ("ELAPSED = {0}" -f (Format-Duration $elapsed)),
        "",
        "INTERPRETATION",
        $Interpretation,
        "",
        ("Hard-service summary file: {0}" -f $HardSummaryPath)
    )
    Set-Content -Path $ResultTxt -Value $lines -Encoding UTF8

    $obj = [ordered]@{
        diagnostic_status = $DiagnosticStatus
        cplex_status = $SolverStatus
        runner_exit_code = $ExitCode
        water_scale_percent = 50
        H2_service_kg_day = 8000
        carbon_price_USD_per_tCO2eq = 150
        PCC_limit_MW = 1.5
        freshwater_shortage_forced_zero = 1
        H2_shortage_forced_zero = 1
        interpretation = $Interpretation
    }
    [pscustomobject]$obj | Export-Csv -Path $ResultCsv -NoTypeInformation -Encoding UTF8
}

function Make-UploadZip {
    $zip = Join-Path $ResultsRoot ("UPLOAD_HARD_SERVICE_RESULT_" + $stamp + ".zip")
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $RunDir "*") -DestinationPath $zip -CompressionLevel Optimal
    Write-RunLog ("Result upload ZIP: {0}" -f $zip)
    return $zip
}

try {
    Write-RunLog "Hard-service feasibility diagnostic started."
    Write-RunLog "Only RUN_HARD_SERVICE_CHECK.bat is intended to be launched by the user."
    Write-RunLog "Expected typical runtime: about 5-15 min if infeasibility/feasibility is resolved quickly."
    Write-RunLog "Upper runtime can approach 60 min for the hard-service case because the CPLEX time limit is 3600 s."

    # ----------------------------------------------------------------------
    # Stage 1: preflight
    # ----------------------------------------------------------------------
    Write-Stage 1 "Preflight and locked-input checks"
    Assert-File $InputCsv "annual input"
    Assert-File $ParamJson "parameter file"
    Assert-File (Join-Path $SourceDir "Source.cpp") "model source"
    Assert-File (Join-Path $SourceDir "JejuFullCoupled24h.vcxproj") "Visual Studio project"
    Assert-File $BuildBat "build script"

    $lineCount = (Get-Content -LiteralPath $InputCsv -ReadCount 5000 | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    if ($lineCount -ne 8761) { throw "Annual input line count mismatch: $lineCount (expected 8761 including header)." }

    $p = Get-Content -LiteralPath $ParamJson -Raw | ConvertFrom-Json
    Assert-Near ([double]$p.electrolyzer.rho_EL_m3_per_kgH2) 0.013 1e-12 "Electrolyzer feedwater coefficient"
    Assert-Near ([double]$p.electrolyzer.kappa_EL_kWh_per_kgH2) 49.9 1e-12 "Electrolyzer electricity coefficient"
    Assert-Near ([double]$p.ro.SEC_kWh_per_m3) 2.864 1e-12 "RO SEC"
    Assert-Near ([double]$p.shortage_and_policy.freshwater_shortage_penalty_USD_per_m3) 100.0 1e-12 "Freshwater shortage coefficient"
    Assert-Near ([double]$p.shortage_and_policy.hydrogen_shortage_penalty_USD_per_kg) 2500.0 1e-12 "H2 shortage coefficient"
    Assert-Near ([double]$p.shortage_and_policy.principal_result_carbon_tax_USD_per_tCO2) 150.0 1e-12 "Principal carbon price"
    Assert-Near ([double]$p.shortage_and_policy.principal_symmetric_PCC_limit_MW) 1.5 1e-12 "Principal PCC limit"

    $src = Get-Content -LiteralPath (Join-Path $SourceDir "Source.cpp") -Raw
    if ($src -notmatch 'containsText\(caseId, "HARDSERVICE"\)') { throw "Hard-service mode trigger not found in source." }
    if ($src -notmatch 'model\.add\(Wsh\[t\] == 0\.0\)') { throw "Freshwater hard-service constraint not found in source." }
    if ($src -notmatch 'model\.add\(Hsh\[t\] == 0\.0\)') { throw "H2 hard-service constraint not found in source." }
    Write-RunLog "PASS: annual input, locked parameters, and hard-service source patch."

    # ----------------------------------------------------------------------
    # Stage 2: build
    # ----------------------------------------------------------------------
    Write-Stage 2 "Build Release x64 executable"
    $buildStdout = Join-Path $RunDir "build_stdout.txt"
    $buildStderr = Join-Path $RunDir "build_stderr.txt"
    $buildStart = Get-Date

    # Remove any old executable so the build gate cannot pass on a stale binary.
    if (Test-Path -LiteralPath $Exe) {
        Remove-Item -LiteralPath $Exe -Force
    }

    # Invoke the batch file through CMD. On some Windows/PowerShell combinations,
    # Start-Process can expose a stale or nonzero ExitCode even when MSBuild and the
    # batch file completed successfully. Therefore the authoritative build gate is:
    #   (1) a newly created executable, and
    #   (2) the build script's explicit success marker.
    $buildCommand = 'call build_release_x64.bat'
    $buildArgs = @('/d', '/s', '/c', $buildCommand)
    $bp = Start-Process -FilePath "cmd.exe" -ArgumentList $buildArgs -WorkingDirectory $SourceDir `
        -RedirectStandardOutput $buildStdout -RedirectStandardError $buildStderr -PassThru -NoNewWindow
    $bp.WaitForExit()
    $bp.Refresh()
    Append-ProcessOutput -StdoutPath $buildStdout -StderrPath $buildStderr -Label "build_default"

    $buildExit = [int]$bp.ExitCode
    $exeExists = Test-Path -LiteralPath $Exe -PathType Leaf
    $exeFresh = $false
    if ($exeExists) {
        $exeFresh = ((Get-Item -LiteralPath $Exe).LastWriteTime -ge $buildStart.AddSeconds(-2))
    }
    $buildMarker = $false
    if (Test-Path -LiteralPath $buildStdout) {
        $buildMarker = [bool](Select-String -LiteralPath $buildStdout -SimpleMatch '[OK] Built x64\Release\JejuFullCoupled24h.exe' -Quiet)
    }

    Write-RunLog ("Build gate: process exit code={0}, executable exists={1}, executable fresh={2}, success marker={3}" -f $buildExit, $exeExists, $exeFresh, $buildMarker)

    if (-not ($exeFresh -and $buildMarker)) {
        Write-RunLog "Default toolset build did not produce a verified fresh executable. Retrying with v143 only as a compatibility fallback."
        $env:REPRO_TOOLSET = "v143"
        if (Test-Path -LiteralPath $Exe) { Remove-Item -LiteralPath $Exe -Force }
        $fallbackStart = Get-Date
        $buildStdout2 = Join-Path $RunDir "build_v143_stdout.txt"
        $buildStderr2 = Join-Path $RunDir "build_v143_stderr.txt"
        $bp2 = Start-Process -FilePath "cmd.exe" -ArgumentList $buildArgs -WorkingDirectory $SourceDir `
            -RedirectStandardOutput $buildStdout2 -RedirectStandardError $buildStderr2 -PassThru -NoNewWindow
        $bp2.WaitForExit()
        $bp2.Refresh()
        Append-ProcessOutput -StdoutPath $buildStdout2 -StderrPath $buildStderr2 -Label "build_v143"

        $fallbackExit = [int]$bp2.ExitCode
        $fallbackExeExists = Test-Path -LiteralPath $Exe -PathType Leaf
        $fallbackExeFresh = $false
        if ($fallbackExeExists) {
            $fallbackExeFresh = ((Get-Item -LiteralPath $Exe).LastWriteTime -ge $fallbackStart.AddSeconds(-2))
        }
        $fallbackMarker = $false
        if (Test-Path -LiteralPath $buildStdout2) {
            $fallbackMarker = [bool](Select-String -LiteralPath $buildStdout2 -SimpleMatch '[OK] Built x64\Release\JejuFullCoupled24h.exe' -Quiet)
        }
        Write-RunLog ("Fallback build gate: process exit code={0}, executable exists={1}, executable fresh={2}, success marker={3}" -f $fallbackExit, $fallbackExeExists, $fallbackExeFresh, $fallbackMarker)

        if (-not ($fallbackExeFresh -and $fallbackMarker)) {
            throw "Release x64 build did not produce a verified fresh executable."
        }
    } elseif ($buildExit -ne 0) {
        Write-RunLog "NOTE: the native process reported a nonzero exit code, but MSBuild produced a fresh executable and the build script emitted its explicit success marker. The verified build artifact is used."
    }
    Write-RunLog ("PASS: verified fresh executable built at {0}" -f $Exe)

    # ----------------------------------------------------------------------
    # Stage 3: regenerate benchmark capacity and validate it
    # ----------------------------------------------------------------------
    Write-Stage 3 "Regenerate selected feedwater-omitting benchmark capacity"
    Write-RunLog "ETA: preserved core runs suggest roughly 1-3 min for this sizing solve."
    $CaseC2 = "C2_HARDCHECK_WATER50_H2D8000_GRIDCAP1.5_TAX150"
    $rcC2 = Invoke-SolverCase -CaseIndex 1 -Label "benchmark_sizing" -CaseId $CaseC2
    if ($rcC2 -ne 0) { throw "Benchmark sizing solve failed with exit code $rcC2." }

    $SummaryC2 = Join-Path $RunDir ("summary_decoupled_C2_" + $CaseC2 + ".csv")
    $CapC2 = Join-Path $RunDir ("capacity_decoupled_C2_" + $CaseC2 + ".csv")
    $mC2 = Read-MetricFile $SummaryC2
    if ([string]$mC2["status"] -notmatch "Optimal") { throw "Benchmark sizing status is not Optimal: $($mC2['status'])" }
    $k = Read-CapacityFile $CapC2

    # Gate against the manuscript's reported selected benchmark portfolio.
    Assert-Near ([double]$k["K_PV"]) 74.50 0.03 "Benchmark PV capacity (rounded manuscript gate)"
    Assert-Near ([double]$k["K_WT"]) 27.49 0.03 "Benchmark WT capacity (rounded manuscript gate)"
    Assert-Near ([double]$k["K_BESS_P"]) 1.385 0.003 "Benchmark BESS power capacity (rounded manuscript gate)"
    Assert-Near ([double]$k["K_BESS_E"]) 5.02267179811471 0.003 "Benchmark BESS energy capacity"
    Assert-Near ([double]$k["K_RO"]) 49.8269534027442 0.03 "Benchmark RO capacity"
    Assert-Near ([double]$k["K_Wtank"]) 1174.63189214861 1.5 "Benchmark water-tank capacity"
    Assert-Near ([double]$k["K_EL"]) 44.04 0.03 "Benchmark electrolyzer capacity (rounded manuscript gate)"
    Assert-Near ([double]$k["K_H2"]) 45782.8 0.5 "Benchmark H2-tank capacity (rounded manuscript gate)"
    Assert-Near ([double]$k["K_FC"]) 0.585 0.003 "Benchmark fuel-cell capacity (rounded manuscript gate)"
    Write-RunLog "PASS: regenerated benchmark capacity matches the manuscript portfolio."

    # ----------------------------------------------------------------------
    # Stage 4: reproduce ordinary fixed-capacity re-evaluation
    # ----------------------------------------------------------------------
    Write-Stage 4 "Reproduce ordinary fixed-capacity re-evaluation before hard-service test"
    Write-RunLog "This is a mandatory gate. The hard-service test is skipped if the published selected-case behavior is not reproduced."
    $CaseC3 = "C3_HARDCHECK_WATER50_H2D8000_GRIDCAP1.5_TAX150"
    $rcC3 = Invoke-SolverCase -CaseIndex 2 -Label "ordinary_re_evaluation" -CaseId $CaseC3 -CapacityFix $CapC2
    if ($rcC3 -ne 0) { throw "Ordinary fixed-capacity re-evaluation failed with exit code $rcC3." }

    $SummaryC3 = Join-Path $RunDir ("summary_expost_C3_" + $CaseC3 + ".csv")
    $mC3 = Read-MetricFile $SummaryC3
    if ([string]$mC3["status"] -notmatch "Optimal") { throw "Ordinary re-evaluation status is not Optimal: $($mC3['status'])" }
    Assert-Near (Metric-Double $mC3 "objective_USD") 18718038.2694 2500.0 "Ordinary re-evaluation objective"
    Assert-Near (Metric-Double $mC3 "total_freshwater_shortage_m3") 5918.31013332 5.0 "Ordinary re-evaluation freshwater shortage"
    if ([math]::Abs((Metric-Double $mC3 "total_H2_shortage_kg")) -gt 1e-5) {
        throw "Ordinary re-evaluation H2 shortage is not numerical zero."
    }
    Write-RunLog "PASS: ordinary re-evaluation reproduces the selected-case shortage behavior."

    # ----------------------------------------------------------------------
    # Stage 5: hard-service feasibility check
    # ----------------------------------------------------------------------
    Write-Stage 5 "Hard-service feasibility check with both shortages fixed to zero"
    Write-RunLog "Scientific question: can the inherited benchmark portfolio serve both freshwater and external H2 fully after feedwater coupling is restored?"
    Write-RunLog "ETA: this fixed-capacity solve may finish quickly, but proving infeasibility can require substantially longer; the solver limit is 60 min."
    $CaseHard = "C3_HARDSERVICE_WATER50_H2D8000_GRIDCAP1.5_TAX150"
    $rcHard = Invoke-SolverCase -CaseIndex 3 -Label "hard_service_feasibility" -CaseId $CaseHard -CapacityFix $CapC2
    $SummaryHard = Join-Path $RunDir ("summary_expost_C3_" + $CaseHard + ".csv")

    if (-not (Test-Path -LiteralPath $SummaryHard)) {
        Save-Result -DiagnosticStatus "INCONCLUSIVE" -SolverStatus "NO_SUMMARY" `
            -Interpretation "The solver did not produce a readable hard-service summary. No scientific conclusion should be drawn." `
            -HardSummaryPath $SummaryHard -ExitCode $rcHard
        $zip = Make-UploadZip
        Write-RunLog "INCONCLUSIVE: upload the result ZIP for inspection."
        exit 2
    }

    $mHard = Read-MetricFile $SummaryHard
    $hardStatus = [string]$mHard["status"]

    if ($rcHard -eq 0 -and $hardStatus -match "Optimal|Feasible") {
        $wHard = Metric-Double $mHard "total_freshwater_shortage_m3"
        $hHard = Metric-Double $mHard "total_H2_shortage_kg"
        if ([math]::Abs($wHard) -gt 1e-6 -or [math]::Abs($hHard) -gt 1e-6) {
            Save-Result -DiagnosticStatus "INCONCLUSIVE" -SolverStatus $hardStatus `
                -Interpretation "A feasible solution was returned, but the reported shortage totals are not zero within the diagnostic tolerance. Inspect the run before changing the manuscript." `
                -HardSummaryPath $SummaryHard -ExitCode $rcHard
            $zip = Make-UploadZip
            exit 2
        }

        $interpretation = "FEASIBLE: the benchmark-derived fixed capacities can satisfy both modeled services after feedwater coupling is restored when both shortage variables are prohibited. Therefore, the previously reported 5,918 m3/yr freshwater shortage is not an unavoidable physical infeasibility of the inherited capacity vector; it is an operating/service-allocation outcome under the adopted penalized objective. The manuscript must preserve that qualification."
        Save-Result -DiagnosticStatus "FEASIBLE" -SolverStatus $hardStatus -Interpretation $interpretation -HardSummaryPath $SummaryHard -ExitCode $rcHard
        Write-RunLog "RESULT: FEASIBLE with both service shortages fixed to zero."
        Write-RunLog $interpretation
        $zip = Make-UploadZip
        exit 0
    }

    if ($hardStatus -match "Infeasible") {
        $interpretation = "INFEASIBLE: with the feedwater-omitting benchmark capacities fixed and feedwater coupling restored, no annual operating schedule satisfies both community freshwater demand and external H2 service with zero shortage in every hour. The relative shortage coefficients can affect where a deficit is allocated when shortage variables are allowed, but they do not create the underlying inability of this inherited capacity portfolio to serve both modeled services simultaneously."
        Save-Result -DiagnosticStatus "INFEASIBLE" -SolverStatus $hardStatus -Interpretation $interpretation -HardSummaryPath $SummaryHard -ExitCode $rcHard
        Write-RunLog "RESULT: INFEASIBLE under simultaneous hard freshwater and H2 service constraints."
        Write-RunLog $interpretation
        $zip = Make-UploadZip
        exit 0
    }

    $interpretation = "INCONCLUSIVE: the hard-service case did not return a conclusive feasible or infeasible status. This can occur if the time limit or another solver condition stops the run before feasibility is resolved. Do not alter the manuscript's scientific interpretation from this run."
    Save-Result -DiagnosticStatus "INCONCLUSIVE" -SolverStatus $hardStatus -Interpretation $interpretation -HardSummaryPath $SummaryHard -ExitCode $rcHard
    Write-RunLog "RESULT: INCONCLUSIVE."
    Write-RunLog $interpretation
    $zip = Make-UploadZip
    exit 2
}
catch {
    Write-RunLog ("FAIL: {0}" -f $_.Exception.Message)
    $elapsed = (Get-Date) - $GlobalStart
    $failText = @(
        "Hard-service feasibility check",
        "",
        "DIAGNOSTIC_STATUS = NOT_RUN_OR_FAILED",
        ("ERROR = {0}" -f $_.Exception.Message),
        ("ELAPSED = {0}" -f (Format-Duration $elapsed)),
        "",
        "No scientific conclusion should be drawn from this failed run."
    )
    Set-Content -Path $ResultTxt -Value $failText -Encoding UTF8
    try { $zip = Make-UploadZip } catch { }
    exit 1
}
