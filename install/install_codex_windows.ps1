<#
.SYNOPSIS
    Codex connector installer for vivado-mcp-socket on Windows.

.DESCRIPTION
    - Creates or reuses .venv inside the project.
    - Installs the Python package in editable mode.
    - Creates a stable .cmd wrapper in %USERPROFILE%\.codex\memories\.
    - Registers the MCP server in %USERPROFILE%\.codex\config.toml.

.PARAMETER ServerName
    MCP server name inside Codex. Default: vivado-mcp.

.PARAMETER Host
    Host of the TCL plugin running inside Vivado. Default: 127.0.0.1.

.PARAMETER Port
    Port of the TCL plugin running inside Vivado. Default: 7654.

.EXAMPLE
    .\install\install_codex_windows.ps1
    .\install\install_codex_windows.ps1 -ServerName vivado-mcp -Port 7654
#>

[CmdletBinding()]
param(
    [string] $ServerName = "vivado-mcp",
    [string] $Host = "127.0.0.1",
    [int] $Port = 7654
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$VenvDir = Join-Path $ProjectRoot ".venv"
$PythonExe = Join-Path $VenvDir "Scripts\python.exe"
$CodexDir = Join-Path $env:USERPROFILE ".codex"
$MemoriesDir = Join-Path $CodexDir "memories"
$WrapperPath = Join-Path $MemoriesDir "$ServerName.cmd"
$ConfigPath = Join-Path $CodexDir "config.toml"

Write-Host "=== vivado-mcp-socket Codex installer (Windows) ===" -ForegroundColor Cyan
Write-Host "Project root : $ProjectRoot"
Write-Host "Python venv  : $VenvDir"
Write-Host "Wrapper      : $WrapperPath"
Write-Host "Codex config : $ConfigPath"
Write-Host ""

if (-not (Test-Path (Join-Path $ProjectRoot "pyproject.toml"))) {
    Write-Error "Could not find pyproject.toml in $ProjectRoot. Run the script from the repo root or from install/."
    exit 1
}

if (-not (Test-Path $VenvDir)) {
    Write-Host "[1/4] Creating Python environment..." -ForegroundColor Yellow
    python -m venv $VenvDir
} else {
    Write-Host "[1/4] Python environment already exists." -ForegroundColor Yellow
}

if (-not (Test-Path $PythonExe)) {
    Write-Error "Could not find $PythonExe."
    exit 1
}

Write-Host "[2/4] Installing Python package in editable mode..." -ForegroundColor Yellow
& $PythonExe -m pip install --upgrade pip
& $PythonExe -m pip install -e $ProjectRoot

Write-Host "[3/4] Creating .cmd wrapper..." -ForegroundColor Yellow
if (-not (Test-Path $MemoriesDir)) {
    New-Item -ItemType Directory -Path $MemoriesDir -Force | Out-Null
}

$wrapper = @"
@echo off
set VMCP_HOST=$Host
set VMCP_PORT=$Port
set VMCP_LOGLEVEL=INFO
cd /d "$ProjectRoot"
"$PythonExe" -m vivado_mcp_server
"@
Set-Content -LiteralPath $WrapperPath -Value $wrapper -Encoding ASCII

Write-Host "[4/4] Registering MCP server in Codex..." -ForegroundColor Yellow
if (-not (Test-Path $CodexDir)) {
    New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null
}
if (-not (Test-Path $ConfigPath)) {
    New-Item -ItemType File -Path $ConfigPath -Force | Out-Null
}

$config = Get-Content -LiteralPath $ConfigPath -Raw
$escapedServerName = [regex]::Escape($ServerName)
$blockPattern = "(?ms)^\[mcp_servers\.$escapedServerName\]\r?\n.*?(?=^\[|\z)"
$envPattern = "(?ms)^\[mcp_servers\.$escapedServerName\.env\]\r?\n.*?(?=^\[|\z)"

$mcpBlock = @"
[mcp_servers.$ServerName]
command = "$($WrapperPath.Replace("\", "\\"))"
args = []
enabled = true

"@

$envBlock = @"
[mcp_servers.$ServerName.env]
VMCP_HOST = "$Host"
VMCP_PORT = "$Port"
VMCP_LOGLEVEL = "INFO"

"@

$config = [regex]::Replace($config, $envPattern, "")
$config = [regex]::Replace($config, $blockPattern, "")
$config = $config.TrimEnd() + "`r`n`r`n" + $mcpBlock + "`r`n" + $envBlock
Set-Content -LiteralPath $ConfigPath -Value $config -Encoding UTF8

Write-Host ""
Write-Host "=== Codex installation complete ===" -ForegroundColor Cyan
Write-Host "Restart Codex or open a new thread to load the MCP server."
Write-Host "Verify with:"
Write-Host "  codex mcp list"
Write-Host ""
Write-Host "Before using tools, open Vivado and verify in the TCL console:"
Write-Host "  [vmcp] server listening on 127.0.0.1:$Port"
