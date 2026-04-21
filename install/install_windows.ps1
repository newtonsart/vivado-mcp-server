<#
.SYNOPSIS
    Installer for the vivado-mcp-socket TCL plugin on Windows.

.DESCRIPTION
    - Copies the `tcl/` tree to %USERPROFILE%\.vivado-mcp\tcl\
    - Appends a `source ...` line to the user's Vivado_init.tcl
      (%APPDATA%\Xilinx\Vivado\<version>\Vivado_init.tcl) without
      deleting existing content. If the line already exists, it does nothing.
    - If the Vivado profile directory for the requested version doesn't
      exist, it creates it.

.PARAMETER VivadoVersion
    Target Vivado version (e.g. "2023.2"). If omitted, the script tries
    to detect all installed versions and prompts the user.

.PARAMETER AllVersions
    If specified, installs for ALL detected Vivado versions.

.EXAMPLE
    .\install_windows.ps1
    .\install_windows.ps1 -VivadoVersion 2023.2
    .\install_windows.ps1 -AllVersions
#>

[CmdletBinding()]
param(
    [string] $VivadoVersion = "",
    [switch] $AllVersions
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------------------
# Path resolution.
# ------------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$TclSource = Join-Path $ProjectRoot "tcl"
$InstallRoot = Join-Path $env:USERPROFILE ".vivado-mcp"
$TclTarget = Join-Path $InstallRoot "tcl"
$XilinxBase = Join-Path $env:APPDATA "Xilinx\Vivado"

Write-Host "=== vivado-mcp-socket installer (Windows) ===" -ForegroundColor Cyan
Write-Host "Project root : $ProjectRoot"
Write-Host "Install root : $InstallRoot"
Write-Host ""

if (-not (Test-Path $TclSource)) {
    Write-Error "Could not find tcl/ folder in $ProjectRoot. Run the script from the repo root."
    exit 1
}

# ------------------------------------------------------------------------------
# 1. Copy the tcl/ tree.
# ------------------------------------------------------------------------------
Write-Host "[1/3] Copying TCL plugin to $TclTarget ..." -ForegroundColor Yellow
if (-not (Test-Path $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot | Out-Null
}
if (Test-Path $TclTarget) {
    Remove-Item -Recurse -Force $TclTarget
}
Copy-Item -Recurse -Force $TclSource $TclTarget
Write-Host "  OK" -ForegroundColor Green

# ------------------------------------------------------------------------------
# 2. Detect installed Vivado versions.
# ------------------------------------------------------------------------------
Write-Host "[2/3] Detecting Vivado versions in $XilinxBase ..." -ForegroundColor Yellow

$versions = @()
if (Test-Path $XilinxBase) {
    $versions = Get-ChildItem -Directory $XilinxBase |
        Where-Object { $_.Name -match '^\d{4}\.\d+' } |
        Select-Object -ExpandProperty Name
}

if ($versions.Count -eq 0) {
    Write-Warning "No Vivado versions detected in $XilinxBase."
    Write-Warning "The plugin has been copied, but you will need to manually add"
    Write-Warning "the 'source ...' line to your Vivado_init.tcl."
    exit 0
}

$targetVersions = @()
if ($AllVersions) {
    $targetVersions = $versions
} elseif ($VivadoVersion) {
    if ($versions -contains $VivadoVersion) {
        $targetVersions = @($VivadoVersion)
    } else {
        Write-Error "Version $VivadoVersion not found. Detected: $($versions -join ', ')"
        exit 1
    }
} else {
    if ($versions.Count -eq 1) {
        $targetVersions = $versions
        Write-Host "  Single version detected: $($versions[0])"
    } else {
        Write-Host "Detected versions:"
        for ($i = 0; $i -lt $versions.Count; $i++) {
            Write-Host "  [$($i+1)] $($versions[$i])"
        }
        Write-Host "  [A] Install for all"
        $choice = Read-Host "Select"
        if ($choice -eq "A" -or $choice -eq "a") {
            $targetVersions = $versions
        } else {
            $idx = [int]$choice - 1
            if ($idx -lt 0 -or $idx -ge $versions.Count) {
                Write-Error "Invalid selection."
                exit 1
            }
            $targetVersions = @($versions[$idx])
        }
    }
}

# ------------------------------------------------------------------------------
# 3. Inject source line into Vivado_init.tcl for each selected version.
# ------------------------------------------------------------------------------
Write-Host "[3/3] Updating Vivado_init.tcl ..." -ForegroundColor Yellow

# Line to add. Uses forward slashes for TCL compatibility on Windows.
$pluginPath = (Join-Path $TclTarget "vivado_server.tcl").Replace("\", "/")
$sourceLine = "source {$pluginPath}"
$marker = "# vivado-mcp-server: TCP server plugin"

foreach ($v in $targetVersions) {
    $initFile = Join-Path $XilinxBase "$v\Vivado_init.tcl"
    $initDir  = Split-Path -Parent $initFile
    if (-not (Test-Path $initDir)) {
        New-Item -ItemType Directory -Path $initDir | Out-Null
    }
    $existingContent = ""
    if (Test-Path $initFile) {
        $existingContent = Get-Content -Raw $initFile
    }

    if ($existingContent -match [regex]::Escape($marker)) {
        Write-Host "  [$v] already installed (marker detected), updating path..." -ForegroundColor DarkYellow
        # Replace the previous marker+source block.
        $pattern = "(?s)$([regex]::Escape($marker)).*?(?=\r?\n|$)\r?\n?source\s+\{[^\}]+\}"
        $replacement = "$marker`r`n$sourceLine"
        $newContent = [regex]::Replace($existingContent, $pattern, $replacement)
        if ($newContent -eq $existingContent) {
            # Fallback: simple append if the regex didn't match (unexpected format).
            $newContent = $existingContent.TrimEnd() + "`r`n`r`n$marker`r`n$sourceLine`r`n"
        }
        Set-Content -Path $initFile -Value $newContent -NoNewline
    } else {
        $append = ""
        if ($existingContent.Length -gt 0 -and -not $existingContent.EndsWith("`n")) {
            $append += "`r`n"
        }
        $append += "`r`n$marker`r`n$sourceLine`r`n"
        Add-Content -Path $initFile -Value $append -NoNewline
        Write-Host "  [$v] line added to $initFile" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "=== Installation complete ===" -ForegroundColor Cyan
Write-Host "Open (or restart) Vivado and you should see in the TCL console:" -ForegroundColor Cyan
Write-Host "  vivado-mcp-socket: plugin loaded..."
Write-Host "  [vmcp] server listening on 127.0.0.1:7654"
Write-Host ""
Write-Host "To connect Claude Desktop, copy the snippet from install/mcp_config_example.json"
Write-Host "to your claude_desktop_config.json (see README)."
