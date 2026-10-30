#Requires -Version 7.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Steam Client Desktop Icon Audit and Recovery Utility.

.DESCRIPTION
    Dynamically identifies the Steam Client installation, enumerates all configured
    Steam library folders, and audits installed games against desktop icons stored
    in the Steam\steam\games folder. Resolves authoritative 40-character SHA-1 icon
    hashes directly from Steam's local binary cache (appcache\appinfo.vdf) using
    Valve's native dictionary token index parser and downloads any missing .ico
    files directly from Valve's official content delivery network (CDN).

.NOTES
    Required Permissions: Administrator privileges (Run as Administrator).
    PowerShell Version  : 7.0 or higher.
    Standard Style      : Standard Interactive PowerShell Style (English-UK).
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest

# ==============================================================================
# CONFIGURATION
# ==============================================================================

$Script:Config = [ordered]@{
    SteamPath             = $null
    IconSubdirectory      = 'steam\games'
    CdnBaseUrl            = 'https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps'
    ExcludedAppIds        = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('228980', '250820', '1070560'), # Common runtimes, SteamVR, Proton
        [System.StringComparer]::OrdinalIgnoreCase
    )
    HttpRequestTimeoutSec = 10
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    switch ($Level) {
        'Success' { Write-Host "[+] $Message" -ForegroundColor Green }
        'Error'   { Write-Host "[-] $Message" -ForegroundColor Red }
        'Warning' { Write-Host "[*] $Message" -ForegroundColor Yellow }
        'Info'    { Write-Host "[*] $Message" -ForegroundColor Cyan }
    }
}

function Wait-ForKeypress {
    [CmdletBinding()]
    param(
        [string]$PromptMessage = 'Press any key to return to the menu...'
    )
    Write-Host "`n$PromptMessage" -ForegroundColor DarkGray
    [void][System.Console]::ReadKey($true)
}

function Get-SteamInstallationPath {
    [CmdletBinding()]
    param()

    $RegistryLocations = @(
        @{ Path = 'HKCU:\Software\Valve\Steam'; Property = 'SteamPath' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Property = 'InstallPath' },
        @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Property = 'InstallPath' }
    )

    foreach ($Entry in $RegistryLocations) {
        if (Test-Path -LiteralPath $Entry.Path) {
            $Detected = (Get-ItemProperty -Path $Entry.Path -ErrorAction SilentlyContinue).($Entry.Property)
            if ($Detected -and (Test-Path -LiteralPath $Detected)) {
                return ($Detected -replace '/', '\').TrimEnd('\')
            }
        }
    }

    return $null
}

function Get-SteamLibraryFolders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SteamRoot
    )

    $Libraries = [System.Collections.Generic.List[string]]::new()
    $Libraries.Add($SteamRoot)

    $LibraryVdf = Join-Path -Path $SteamRoot -ChildPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $LibraryVdf) {
        $Content = [System.IO.File]::ReadAllText($LibraryVdf)
        $Matches = [regex]::Matches($Content, '"path"\s+"([^"]+)"')
        foreach ($Match in $Matches) {
            $CleanPath = ($Match.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
            if ((Test-Path -LiteralPath $CleanPath) -and (-not $Libraries.Contains($CleanPath))) {
                $Libraries.Add($CleanPath)
            }
        }
    }

    return $Libraries
}

function Get-InstalledSteamGames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$LibraryPaths,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$ExcludedAppIds
    )

    $GameCatalogue = [System.Collections.Generic.List[PSCustomObject]]::new()
    $DiscoveredAppIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Lib in $LibraryPaths) {
        $ManifestDir = Join-Path -Path $Lib -ChildPath 'steamapps'
        if (-not (Test-Path -LiteralPath $ManifestDir)) { continue }

        Get-ChildItem -LiteralPath $ManifestDir -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $Text = [System.IO.File]::ReadAllText($_.FullName)
            $AppId = if ($Text -match '"appid"\s+"(\d+)"') { $Matches[1] } else { $null }
            $Name  = if ($Text -match '"name"\s+"([^"]+)"')  { $Matches[1] } else { $null }

            if ($AppId -and $Name -and (-not $ExcludedAppIds.Contains($AppId)) -and (-not $DiscoveredAppIds.Contains($AppId))) {
                [void]$DiscoveredAppIds.Add($AppId)
                $GameCatalogue.Add([PSCustomObject]@{
                    AppId       = $AppId
                    Name        = $Name
                    LibraryPath = $Lib
                })
            }
        }
    }

    return $GameCatalogue
}

function Get-SteamIconDatabase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppInfoPath
    )

    if (-not (Test-Path -LiteralPath $AppInfoPath)) {
        throw "Steam appinfo cache not found at '$AppInfoPath'."
    }

    $Stream = [System.IO.File]::OpenRead($AppInfoPath)
    $Reader = [System.IO.BinaryReader]::new($Stream)
    $IconMap = @{}

    try {
        # 1. Read String Table pointer at byte 8 (uint64)
        $Stream.Position = 8
        $StringPoolOffset = $Reader.ReadInt64()

        # 2. Parse String Dictionary
        $Stream.Position = $StringPoolOffset
        $StringCount = $Reader.ReadUInt32()
        $Dictionary = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $StringCount; $i++) {
            $Chars = [System.Collections.Generic.List[char]]::new()
            while ($true) {
                $b = $Reader.ReadByte()
                if ($b -eq 0) { break }
                $Chars.Add([char]$b)
            }
            $Dictionary.Add([string]::new($Chars.ToArray()))
        }

        # Locate clienticon token index (only clienticon represents a Windows .ico file)
        $ClientIconIdx = $Dictionary.IndexOf('clienticon')
        if ($ClientIconIdx -lt 0) {
            throw "Unable to find 'clienticon' token in Steam string pool."
        }

        # Construct binary token signature (0x01 + uint32 token index)
        $TokenClientIcon = [byte[]]@(0x01) + [System.BitConverter]::GetBytes([uint32]$ClientIconIdx)
        $TokenClientIconStr = [System.Text.Encoding]::Latin1.GetString($TokenClientIcon)

        # 3. Read App Records sequentially from byte 16
        $Stream.Position = 16

        while ($Stream.Position -lt $StringPoolOffset) {
            $AppId = $Reader.ReadUInt32()
            if ($AppId -eq 0) { break }
            $Size = $Reader.ReadUInt32()

            if ($Size -gt 60) {
                # Step over 60-byte fixed binary header
                $Stream.Seek(60, [System.IO.SeekOrigin]::Current) | Out-Null
                $PayloadBytes = $Reader.ReadBytes($Size - 60)
                $PayloadText  = [System.Text.Encoding]::Latin1.GetString($PayloadBytes)

                # Match clienticon dictionary token
                $Idx = $PayloadText.IndexOf($TokenClientIconStr, [System.StringComparison]::Ordinal)
                if ($Idx -ge 0 -and ($Idx + $TokenClientIconStr.Length + 40 -le $PayloadText.Length)) {
                    $Candidate = $PayloadText.Substring($Idx + $TokenClientIconStr.Length, 40)
                    if ($Candidate -match '^[a-f0-9]{40}$') {
                        $IconMap[$AppId] = $Candidate
                    }
                }
            } elseif ($Size -gt 0) {
                $Stream.Seek($Size, [System.IO.SeekOrigin]::Current) | Out-Null
            }
        }
    } finally {
        $Reader.Dispose()
        $Stream.Dispose()
    }

    return $IconMap
}

function Invoke-IconAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$AutoDownload
    )

    Clear-Host
    Write-Host "==============================================================================" -ForegroundColor DarkCyan
    Write-Host " EXECUTING STEAM CLIENT ICON AUDIT" -ForegroundColor Cyan
    Write-Host "==============================================================================`n" -ForegroundColor DarkCyan

    $SteamPath = $Script:Config.SteamPath
    $IconFolder = Join-Path -Path $SteamPath -ChildPath $Script:Config.IconSubdirectory

    if (-not (Test-Path -LiteralPath $IconFolder)) {
        Write-LogMessage -Level Warning -Message "Directory '$IconFolder' missing. Initialising folder..."
        [void](New-Item -ItemType Directory -Path $IconFolder -Force)
    }

    Write-LogMessage -Level Info -Message "Discovering Steam libraries..."
    $Libraries = Get-SteamLibraryFolders -SteamRoot $SteamPath
    Write-LogMessage -Level Info -Message "Found $($Libraries.Count) active Steam library folder(s)."

    Write-LogMessage -Level Info -Message "Scanning for installed games..."
    $Games = Get-InstalledSteamGames -LibraryPaths $Libraries -ExcludedAppIds $Script:Config.ExcludedAppIds
    Write-LogMessage -Level Info -Message "Identified $($Games.Count) installed game(s) to audit."

    $AppInfoFile = Join-Path -Path $SteamPath -ChildPath 'appcache\appinfo.vdf'
    Write-LogMessage -Level Info -Message "Parsing Steam binary appinfo cache..."

    $IconMap = try {
        Get-SteamIconDatabase -AppInfoPath $AppInfoFile
    } catch {
        Write-LogMessage -Level Error -Message $_.Exception.Message
        Wait-ForKeypress
        return
    }

    Write-LogMessage -Level Success -Message "Parsed $($IconMap.Count) authoritative icon hashes from local cache."

    Write-Host "`n------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ("{0,-10} {1,-38} {2,-17} {3}" -f "APPID", "GAME TITLE", "STATUS", "ICON FILENAME") -ForegroundColor White
    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkGray

    $Stats = [ordered]@{
        Total      = $Games.Count
        Verified   = 0
        Downloaded = 0
        Missing    = 0
        NoIcon     = 0
    }

    foreach ($Game in $Games) {
        $DisplayTitle = if ($Game.Name.Length -gt 38) { $Game.Name.Substring(0, 35) + '...' } else { $Game.Name }
        $Hash = $IconMap[[uint32]$Game.AppId]

        # Developer never uploaded a desktop .ico file
        if (-not $Hash) {
            $Stats.NoIcon++
            Write-Host ("{0,-10} {1,-38} " -f $Game.AppId, $DisplayTitle) -NoNewline
            Write-Host "[*] NO ICON FILE  " -ForegroundColor Yellow -NoNewline
            Write-Host "(No .ico supplied by developer)" -ForegroundColor DarkGray
            continue
        }

        $IconFilename = "$Hash.ico"
        $LocalIconPath = Join-Path -Path $IconFolder -ChildPath $IconFilename

        if (Test-Path -LiteralPath $LocalIconPath) {
            $Stats.Verified++
            Write-Host ("{0,-10} {1,-38} " -f $Game.AppId, $DisplayTitle) -NoNewline
            Write-Host "[+] VERIFIED      " -ForegroundColor Green -NoNewline
            Write-Host $IconFilename -ForegroundColor Gray
        }
        else {
            if ($AutoDownload) {
                $CdnUrl = "$($Script:Config.CdnBaseUrl)/$($Game.AppId)/$IconFilename"
                try {
                    Invoke-WebRequest -Uri $CdnUrl -OutFile $LocalIconPath -TimeoutSec $Script:Config.HttpRequestTimeoutSec -ErrorAction Stop
                    $Stats.Downloaded++
                    Write-Host ("{0,-10} {1,-38} " -f $Game.AppId, $DisplayTitle) -NoNewline
                    Write-Host "[+] DOWNLOADED    " -ForegroundColor Green -NoNewline
                    Write-Host $IconFilename -ForegroundColor Cyan
                }
                catch {
                    $Stats.Missing++
                    Write-Host ("{0,-10} {1,-38} " -f $Game.AppId, $DisplayTitle) -NoNewline
                    Write-Host "[-] DL FAILED     " -ForegroundColor Red -NoNewline
                    Write-Host $IconFilename -ForegroundColor DarkGray
                }
            }
            else {
                $Stats.Missing++
                Write-Host ("{0,-10} {1,-38} " -f $Game.AppId, $DisplayTitle) -NoNewline
                Write-Host "[-] MISSING       " -ForegroundColor Red -NoNewline
                Write-Host $IconFilename -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "------------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "`nAUDIT SUMMARY:" -ForegroundColor Cyan
    Write-Host "  Total Games Audited : $($Stats.Total)"
    Write-Host "  Icons Verified      : $($Stats.Verified)" -ForegroundColor Green
    if ($AutoDownload) {
        Write-Host "  Icons Downloaded    : $($Stats.Downloaded)" -ForegroundColor Green
    }
    Write-Host "  Icons Missing       : $($Stats.Missing)" -ForegroundColor $(if ($Stats.Missing -gt 0) { 'Red' } else { 'Gray' })
    Write-Host "  No Icon Available   : $($Stats.NoIcon)" -ForegroundColor $(if ($Stats.NoIcon -gt 0) { 'Yellow' } else { 'Gray' })

    Wait-ForKeypress
}

# ==============================================================================
# MAIN INTERACTIVE MENU
# ==============================================================================

function Start-AuditUtility {
    [CmdletBinding()]
    param()

    # Dynamically detect Steam path from registry
    $DetectedSteam = Get-SteamInstallationPath
    if (-not $DetectedSteam) {
        Clear-Host
        Write-LogMessage -Level Error -Message "Unable to automatically detect Steam installation from registry."
        $ManualPath = Read-Host "Please enter the full path to your Steam directory (or press ENTER to exit)"
        if ([string]::IsNullOrWhiteSpace($ManualPath) -or (-not (Test-Path -LiteralPath $ManualPath))) {
            Write-LogMessage -Level Error -Message "Invalid path specified. Exiting..."
            return
        }
        $DetectedSteam = ($ManualPath -replace '/', '\').TrimEnd('\')
    }

    $Script:Config.SteamPath = $DetectedSteam

    while ($true) {
        Clear-Host
        $IconDir = Join-Path -Path $Script:Config.SteamPath -ChildPath $Script:Config.IconSubdirectory
        $ExistingIconCount = if (Test-Path -LiteralPath $IconDir) {
            (Get-ChildItem -LiteralPath $IconDir -Filter *.ico -File -ErrorAction SilentlyContinue).Count
        } else { 0 }

        Write-Host "==============================================================================" -ForegroundColor DarkCyan
        Write-Host " STEAM CLIENT ICON AUDIT & RECOVERY UTILITY" -ForegroundColor Cyan
        Write-Host "==============================================================================" -ForegroundColor DarkCyan
        Write-Host " Detected Steam Path : $($Script:Config.SteamPath)" -ForegroundColor Gray
        Write-Host " Icon Target Folder  : $IconDir" -ForegroundColor Gray
        Write-Host " Existing .ico Files : $ExistingIconCount" -ForegroundColor Gray
        Write-Host "==============================================================================`n" -ForegroundColor DarkCyan

        Write-Host " 1. Audit Installed Games & Icons (Report Only)"
        Write-Host " 2. Audit & Download Missing Game Icons (Auto-Recovery)"
        Write-Host " 3. Re-detect / Customise Steam Directory"
        Write-Host " E. Exit Utility (Default)`n"

        $Selection = (Read-Host " Select an option [1-3, E/ENTER to exit]").Trim()

        switch ($Selection) {
            '1' {
                Invoke-IconAudit -AutoDownload $false
            }
            '2' {
                $Confirm = (Read-Host "`n Download and add missing .ico files to '$IconDir'? [Y/n] (Default: Y)").Trim()
                if ($Confirm -eq '' -or $Confirm -match '^(y|yes)$') {
                    Invoke-IconAudit -AutoDownload $true
                }
            }
            '3' {
                Clear-Host
                $NewPath = Read-Host "Enter new Steam directory path (or press ENTER to re-detect automatically)"
                if ([string]::IsNullOrWhiteSpace($NewPath)) {
                    $Script:Config.SteamPath = Get-SteamInstallationPath
                } elseif (Test-Path -LiteralPath $NewPath) {
                    $Script:Config.SteamPath = ($NewPath -replace '/', '\').TrimEnd('\')
                } else {
                    Write-LogMessage -Level Error -Message "Path does not exist."
                    Wait-ForKeypress
                }
            }
            { $_ -in '', 'e', 'E' } {
                Clear-Host
                Write-LogMessage -Level Info -Message "Exiting utility. Goodbye!"
                return
            }
            default {
                Write-LogMessage -Level Warning -Message "Unrecognised selection. Please choose an item from the menu."
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Entry point
Start-AuditUtility