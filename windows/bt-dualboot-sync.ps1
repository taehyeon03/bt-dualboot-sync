<#
.SYNOPSIS
  Windows side of bt-dualboot-sync: imports Bluetooth pairing keys that Linux exported.

.DESCRIPTION
  The Linux tool writes keys for devices you re-paired in Linux to
  <EFI partition>\bt-dualboot-sync\bluez-keys.json. This script copies those keys into
  the Windows registry (HKLM\SYSTEM\...\BTHPORT\Parameters\Keys), so the device works in
  Windows without pairing again.

  That registry key is only writable by the SYSTEM account, so the script runs its work
  through a temporary scheduled task as SYSTEM. It asks for administrator rights itself.

.EXAMPLE
  .\bt-dualboot-sync.ps1                      # import now
.EXAMPLE
  .\bt-dualboot-sync.ps1 -DryRun              # show what would change
.EXAMPLE
  .\bt-dualboot-sync.ps1 -List                # show devices paired in Windows
.EXAMPLE
  .\bt-dualboot-sync.ps1 -Install             # import automatically at every Windows start
.EXAMPLE
  .\bt-dualboot-sync.ps1 -DisableFastStartup  # recommended for dual boot
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$DryRun,
    [switch]$List,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DisableFastStartup,
    # internal
    [switch]$AsSystem,
    [switch]$Auto,
    [string]$LogFile,
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$AppDir     = Join-Path $env:ProgramData 'bt-dualboot-sync'
$KeysRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys'
$DevsRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices'
$TaskName   = 'bt-dualboot-sync'
$ExportRel  = 'bt-dualboot-sync\bluez-keys.json'
$EndMarker  = '##BT-DUALBOOT-SYNC-END##'

function Write-Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 }
    else { Write-Host $line }
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-Hex([byte[]]$Bytes) {
    if ($null -eq $Bytes) { return '' }
    return (($Bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function ConvertFrom-Hex([string]$Hex) {
    $Hex = $Hex.Trim()
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16)
    }
    return ,$bytes
}

function Get-DeviceName([string]$Mac) {
    try {
        $raw = (Get-ItemProperty -LiteralPath (Join-Path $DevsRoot $Mac) -Name Name -ErrorAction Stop).Name
        if ($raw -is [byte[]]) { return ([Text.Encoding]::UTF8.GetString($raw)).Trim([char]0).Trim() }
        return "$raw"
    } catch { return '' }
}

# ---------------------------------------------------------------- EFI partition
function Mount-Esp {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    $letter = [char[]](90..71) | Where-Object { $used -notcontains "$_" } | Select-Object -First 1
    if (-not $letter) { throw 'no free drive letter to mount the EFI partition' }
    $out = & mountvol.exe "$($letter):" /S 2>&1
    if ($LASTEXITCODE -ne 0) { throw "mountvol could not mount the EFI partition: $out" }
    return "$($letter):"
}

function Dismount-Esp([string]$Drive) {
    if ($Drive) { & mountvol.exe $Drive /D 2>&1 | Out-Null }
}

# ---------------------------------------------------------------- SYSTEM-side work
function Show-Devices {
    if (-not (Test-Path -LiteralPath $KeysRoot)) { Write-Log 'No Bluetooth pairing keys in this Windows.'; return }
    foreach ($ad in Get-ChildItem -LiteralPath $KeysRoot) {
        Write-Log "Adapter $($ad.PSChildName)"
        $props = Get-ItemProperty -LiteralPath $ad.PSPath
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -match '^[0-9a-f]{12}$') {
                Write-Log ("  BR/EDR {0}  {1}" -f $p.Name, (Get-DeviceName $p.Name))
            }
        }
        foreach ($dev in Get-ChildItem -LiteralPath $ad.PSPath) {
            if ($dev.PSChildName -match '^[0-9a-f]{12}$') {
                Write-Log ("  LE     {0}  {1}" -f $dev.PSChildName, (Get-DeviceName $dev.PSChildName))
            }
        }
    }
}

function Set-RegValue([string]$KeyPath, [string]$Name, $Value, [string]$Type) {
    New-ItemProperty -LiteralPath $KeyPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Import-Keys([string]$JsonPath) {
    $doc = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $devices = @($doc.devices)
    Write-Log ("{0} device key(s) in {1} (created {2})" -f $devices.Count, $JsonPath, $doc.created)
    if ($devices.Count -eq 0) { return 0 }

    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
        $backup = Join-Path $AppDir ('backup-{0}.reg' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys' $backup /y | Out-Null
        Write-Log "Registry backup: $backup"
    }

    $changed = 0
    foreach ($d in $devices) {
        $label = "{0} ({1})" -f $d.mac, $d.name
        $adPath = Join-Path $KeysRoot $d.adapter
        if (-not (Test-Path -LiteralPath $adPath)) {
            Write-Log "SKIP $label - adapter $($d.adapter) is not known to Windows"
            continue
        }
        if ($d.kind -eq 'classic') {
            $cur = (Get-ItemProperty -LiteralPath $adPath -ErrorAction SilentlyContinue).($d.mac)
            if ($null -eq $cur) { Write-Log "SKIP $label - never paired in Windows; pair it in Windows once"; continue }
            if ((ConvertTo-Hex $cur) -eq $d.link_key.ToUpper()) { Write-Log "OK   $label already in sync"; continue }
            if (-not $DryRun) { Set-RegValue $adPath $d.mac (ConvertFrom-Hex $d.link_key) 'Binary' }
        } else {
            $devPath = Join-Path $adPath $d.mac
            if (-not (Test-Path -LiteralPath $devPath)) { Write-Log "SKIP $label - never paired in Windows; pair it in Windows once"; continue }
            $curLtk = (Get-ItemProperty -LiteralPath $devPath -ErrorAction SilentlyContinue).LTK
            if ((ConvertTo-Hex $curLtk) -eq $d.ltk.ToUpper()) { Write-Log "OK   $label already in sync"; continue }
            if (-not $DryRun) {
                $erand = [UInt64]::Parse($d.erand, [Globalization.NumberStyles]::HexNumber)
                $erandSigned = [BitConverter]::ToInt64([BitConverter]::GetBytes($erand), 0)
                Set-RegValue $devPath 'LTK' (ConvertFrom-Hex $d.ltk) 'Binary'
                Set-RegValue $devPath 'KeyLength' ([int]$d.key_length) 'DWord'
                Set-RegValue $devPath 'EDIV' ([int]$d.ediv) 'DWord'
                Set-RegValue $devPath 'ERand' $erandSigned 'QWord'
                if ($d.irk) { Set-RegValue $devPath 'IRK' (ConvertFrom-Hex $d.irk) 'Binary' }
            }
        }
        $changed++
        if ($DryRun) { Write-Log "WOULD UPDATE $label" } else { Write-Log "UPDATED $label" }
    }
    return $changed
}

function Invoke-SystemWork {
    if ($List) { Show-Devices; return }

    $esp = $null
    $json = $Path
    try {
        if (-not $json) {
            $esp = Mount-Esp
            $json = Join-Path $esp $ExportRel
        }
        if (-not (Test-Path -LiteralPath $json)) {
            Write-Log "No exported keys found ($json). Nothing to do."
            Write-Log 'Run `sudo bt-dualboot-sync export` in Linux first (or install its boot service).'
            return
        }
        $changed = Import-Keys $json
        if (-not $DryRun) {
            Remove-Item -LiteralPath $json -Force   # consumed; avoid re-importing stale keys later
            if ($changed -gt 0) {
                Write-Log 'Restarting the Bluetooth service...'
                Restart-Service -Name bthserv -Force
                Write-Log "Done: $changed device(s) updated. If a device does not reconnect, turn it off/on or restart Windows."
            } else {
                Write-Log 'Everything was already in sync.'
            }
        }
    } finally {
        Dismount-Esp $esp
    }
}

# ---------------------------------------------------------------- run as SYSTEM via scheduled task
function Invoke-AsSystem([string[]]$ForwardArgs) {
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $scriptCopy = Join-Path $AppDir 'bt-dualboot-sync.ps1'
    if ($PSCommandPath -ne $scriptCopy) { Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force }
    $log = Join-Path $AppDir 'last-run.log'
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue

    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptCopy`" -AsSystem -LogFile `"$log`" " + ($ForwardArgs -join ' ')
    $name = "$TaskName-oneshot"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $name
        $deadline = (Get-Date).AddMinutes(2)
        do {
            Start-Sleep -Milliseconds 400
            $done = (Test-Path -LiteralPath $log) -and ((Get-Content -LiteralPath $log -Raw) -match [regex]::Escape($EndMarker))
        } until ($done -or (Get-Date) -gt $deadline)
        if (-not $done) { Write-Warning 'Timed out waiting for the SYSTEM task.' }
    } finally {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object { $_ -notmatch [regex]::Escape($EndMarker) } | Write-Host
    }
}

# ================================================================ main
if ($AsSystem) {
    try { Invoke-SystemWork }
    catch { Write-Log "ERROR: $($_.Exception.Message)" }
    finally { Write-Log $EndMarker }
    exit 0
}

if (-not (Test-Admin)) {
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-Elevated')
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $fwd += "-$k" } }
        else { $fwd += "-$k"; $fwd += "`"$v`"" }
    }
    Write-Host 'Administrator rights are needed - a new window will open.'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $fwd
    exit 0
}

if ($DisableFastStartup) {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    Write-Host 'Fast Startup disabled. Windows now shuts down fully, so Linux can read its registry safely.'
    if (-not ($Install -or $Uninstall -or $List -or $DryRun -or $Path)) { exit 0 }
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed startup task '$TaskName'. (Backups are kept in $AppDir.)"
    exit 0
}

if ($Install) {
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $scriptCopy = Join-Path $AppDir 'bt-dualboot-sync.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $scriptCopy -Force
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptCopy`" -AsSystem -Auto -LogFile `"$(Join-Path $AppDir 'startup.log')`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Installed startup task '$TaskName'. Keys exported by Linux are now imported at every Windows start."
    Write-Host "Log: $(Join-Path $AppDir 'startup.log')"
    exit 0
}

$forward = @()
if ($DryRun) { $forward += '-DryRun' }
if ($List)   { $forward += '-List' }
if ($Path)   { $forward += '-Path'; $forward += "`"$((Resolve-Path -LiteralPath $Path).Path)`"" }
Invoke-AsSystem $forward
