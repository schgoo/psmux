# psmux Issue #122 — Backslash escape in parse_command_line
#
# Tests that \\ inside double-quoted strings produces a single literal
# backslash, while preserving existing behaviour: bare backslashes
# (Windows paths) stay literal and \" still produces a double-quote.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue122_backslash_escape.ps1

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsSkipped = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Skip { param($msg) Write-Host "[SKIP] $msg" -ForegroundColor Yellow; $script:TestsSkipped++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "[TEST] $msg" -ForegroundColor White }

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) { Write-Error "psmux binary not found. Build first: cargo build --release"; exit 1 }
Write-Info "Using: $PSMUX"

# Clean slate
Write-Info "Cleaning up existing sessions..."
& $PSMUX kill-server 2>$null
Start-Sleep -Seconds 3
Remove-Item "$env:USERPROFILE\.psmux\*.port" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.psmux\*.key" -Force -ErrorAction SilentlyContinue

$SESSION = "test_122"

function Wait-ForSession {
    param($name, $timeout = 10)
    for ($i = 0; $i -lt ($timeout * 2); $i++) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Cleanup-Session {
    param($name)
    & $PSMUX kill-session -t $name 2>$null
    Start-Sleep -Milliseconds 500
}

# Start a session for all tests
Start-Process -FilePath $PSMUX -ArgumentList "new-session -d -s $SESSION" -WindowStyle Hidden
if (-not (Wait-ForSession $SESSION)) {
    Write-Host "FATAL: Cannot create test session" -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 2

# ══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host ("=" * 60)
Write-Host "ISSUE #122: Backslash escape in parse_command_line"
Write-Host ("=" * 60)
# ══════════════════════════════════════════════════════════════════════

$configDir = Join-Path $env:TEMP "psmux_test_122_config_$(Get-Random)"
New-Item -Path $configDir -ItemType Directory -Force | Out-Null

try {
    # --- Test 1: Windows path with bare backslashes preserved ---
    Write-Test "1: Windows path backslashes preserved in double quotes"
    $cfg = Join-Path $configDir "test1.conf"
    Set-Content -Path $cfg -Value 'set -g default-shell "C:\Program Files\Git\bin\bash.exe"'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $opts = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
    if ($opts -match 'default-shell.*C:\\Program Files\\Git\\bin\\bash\.exe') {
        Write-Pass "1: Windows path preserved with backslashes"
    } else {
        Write-Fail "1: Windows path not preserved. Got:`n$opts"
    }

    # --- Test 2: Escaped backslash \\ produces single backslash ---
    Write-Test '2: Escaped backslash \\ in double quotes produces single \'
    $cfg = Join-Path $configDir "test2.conf"
    # The config line: set -g status-left "prefix \\"
    # parse_command_line should yield: ["set", "-g", "status-left", "prefix \"]
    Set-Content -Path $cfg -Value 'set -g status-left "prefix \\"'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $opts = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
    if ($opts -match 'status-left.*prefix \\') {
        Write-Pass '2: \\ collapsed to single backslash'
    } else {
        Write-Fail "2: Expected 'prefix \' in status-left. Got:`n$opts"
    }

    # --- Test 3: Escaped double-quote \" still works ---
    Write-Test '3: Escaped double-quote \" produces literal quote'
    $cfg = Join-Path $configDir "test3.conf"
    Set-Content -Path $cfg -Value 'set -g status-right "hello \"world\""'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $opts = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
    if ($opts -match 'status-right.*hello "world"') {
        Write-Pass '3: \" produced literal double-quote'
    } else {
        Write-Fail "3: Expected 'hello `"world`"' in status-right. Got:`n$opts"
    }

    # --- Test 4: bind-key with \\ in command string ---
    Write-Test '4: bind-key command containing \\ parses correctly'
    $cfg = Join-Path $configDir "test4.conf"
    Set-Content -Path $cfg -Value 'bind-key B send-keys "\\"'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
    if ($keys -match 'B\s' -and $keys -match 'send-keys') {
        Write-Pass '4: bind-key with \\ in argument registered'
    } else {
        Write-Fail "4: bind-key with \\ not found in list-keys. Got:`n$keys"
    }

    # --- Test 5: Multiple escaped backslashes \\\\ → \\ ---
    Write-Test '5: Multiple escaped backslashes \\\\ produce \\'
    $cfg = Join-Path $configDir "test5.conf"
    # Four backslashes in source → two \\ escapes → two literal backslashes
    Set-Content -Path $cfg -Value 'set -g @test-bs "a\\\\b"'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $opts = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
    if ($opts -match '@test-bs.*a\\\\b') {
        Write-Pass '5: \\\\ collapsed to \\'
    } else {
        Write-Fail "5: Expected 'a\\b' in @test-bs. Got:`n$opts"
    }

    # --- Test 6: Mixed backslash and quote escapes ---
    Write-Test '6: Mixed \\ and \" in same string'
    $cfg = Join-Path $configDir "test6.conf"
    Set-Content -Path $cfg -Value 'set -g @test-mixed "path\\\"quoted\""'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $opts = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
    if ($opts -match '@test-mixed.*path\\"quoted"') {
        Write-Pass '6: Mixed \\ and \" handled correctly'
    } else {
        Write-Fail "6: Mixed escapes incorrect. Got:`n$opts"
    }

    # --- Test 7: Bare backslash before non-special char stays literal ---
    Write-Test '7: Bare backslash before normal char stays literal'
    $cfg = Join-Path $configDir "test7.conf"
    Set-Content -Path $cfg -Value 'set -g @test-bare "hello\nworld"'
    & $PSMUX source-file -t $SESSION $cfg 2>&1 | Out-Null
    $opts = & $PSMUX show-options -g -t $SESSION 2>&1 | Out-String
    if ($opts -match '@test-bare.*hello\\nworld') {
        Write-Pass '7: Backslash before n kept literal (not newline)'
    } else {
        Write-Fail "7: Expected literal \n. Got:`n$opts"
    }

} finally {
    Remove-Item $configDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ══════════════════════════════════════════════════════════════════════
# Cleanup & summary
# ══════════════════════════════════════════════════════════════════════
Cleanup-Session $SESSION
& $PSMUX kill-server 2>$null

Write-Host ""
Write-Host ("=" * 60)
$total = $script:TestsPassed + $script:TestsFailed
Write-Host "RESULTS: $($script:TestsPassed) passed, $($script:TestsFailed) failed, $($script:TestsSkipped) skipped (of $total run)" -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 60)

exit $script:TestsFailed
