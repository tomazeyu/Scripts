#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Migra il formato internazionale (data/ora, numeri) di UN utente,
    copiando i valori da un profilo di riferimento.

.DESCRIPTION
    Copia l'intera chiave HKU\<utente>\Control Panel\International (più la
    sottochiave Geo) dal profilo di riferimento:
      - predefinito: profilo modello C:\Users\Default (dopo Set-DefaultUserItalianFormat.ps1);
      - in alternativa: un utente indicato con -ReferenceUser.
    Prima di scrivere esporta un backup .reg della chiave dell'utente.
    Se l'utente ha una sessione attiva, la modifica è effettiva al prossimo logon.

.PARAMETER UserName
    Utente da migrare: 'SACROCUORE\nome' oppure solo 'nome' (viene usato il dominio corrente).

.PARAMETER ReferenceUser
    Utente da cui copiare i valori. Se omesso si usa il profilo modello Default.

.PARAMETER ExpectedLocale
    LocaleName che il riferimento deve avere, altrimenti lo script si ferma. Predefinito: it-IT.

.PARAMETER BackupDir
    Cartella per i backup .reg. Predefinito: C:\Temp\IntlBackup.

.PARAMETER Force
    Riscrive i valori anche se l'utente ha già il LocaleName del riferimento.

.EXAMPLE
    .\Set-UserItalianFormat.ps1 -UserName f_armucoim -WhatIf
    .\Set-UserItalianFormat.ps1 -UserName SACROCUORE\f_armucoim
    .\Set-UserItalianFormat.ps1 -UserName f_armucoim -ReferenceUser emmaggi

.NOTES
    Ripristino da backup:
      - utente con sessione attiva:   reg import <file.reg>
      - utente non connesso: il .reg punta a HKEY_USERS\TMP_IntlTarget, quindi
          reg load   HKU\TMP_IntlTarget C:\Users\<utente>\NTUSER.DAT
          reg import <file.reg>
          reg unload HKU\TMP_IntlTarget
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$UserName,
    [string]$ReferenceUser,
    [string]$ExpectedLocale = 'it-IT',
    [string]$BackupDir = 'C:\Temp\IntlBackup',
    [switch]$Force
)

$IntlPath = 'Control Panel\International'
$HKU = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Default)

function Resolve-Sid([string]$Name) {
    if ($Name -notmatch '\\') { $Name = "$env:USERDOMAIN\$Name" }
    try {
        ([Security.Principal.NTAccount]$Name).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Utente '$Name' non risolvibile in un SID."
    }
}

function Get-ProfileBySid([string]$Sid, [string]$Label) {
    $p = Get-CimInstance Win32_UserProfile -Filter "SID='$Sid'"
    if (-not $p) { throw "Profilo di '$Label' non presente su questo server." }
    $p
}

function Mount-Hive([string]$Sid, [string]$NtUserPath, [string]$TempName) {
    if ($Sid -and ($HKU.GetSubKeyNames() -contains $Sid)) {
        return [pscustomobject]@{ Name = $Sid; Temp = $false; Active = $true }
    }
    if (-not (Test-Path -LiteralPath $NtUserPath)) { throw "File non trovato: $NtUserPath" }
    $out = & reg.exe load "HKU\$TempName" "$NtUserPath" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg load fallito per $NtUserPath : $out" }
    [pscustomobject]@{ Name = $TempName; Temp = $true; Active = $false }
}

function Dismount-Hive($Hive) {
    if (-not $Hive -or -not $Hive.Temp) { return }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    for ($i = 0; $i -lt 3; $i++) {
        $null = & reg.exe unload "HKU\$($Hive.Name)" 2>&1
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
        [GC]::Collect()
    }
    Write-Warning "Impossibile scaricare HKU\$($Hive.Name): eseguire a mano 'reg unload HKU\$($Hive.Name)'."
}

function Read-Values([Microsoft.Win32.RegistryKey]$Key) {
    foreach ($n in $Key.GetValueNames()) {
        [pscustomobject]@{
            Name  = $n
            Kind  = $Key.GetValueKind($n)
            Value = $Key.GetValue($n, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
}

# --- 1. Lettura del riferimento -------------------------------------------------
if ($ReferenceUser) {
    $refSid   = Resolve-Sid $ReferenceUser
    $refProf  = Get-ProfileBySid $refSid $ReferenceUser
    $refLabel = $ReferenceUser
    $refNt    = Join-Path $refProf.LocalPath 'NTUSER.DAT'
} else {
    $refSid   = $null
    $refLabel = 'profilo modello Default'
    $refNt    = 'C:\Users\Default\NTUSER.DAT'
}

$refValues = @(); $refGeo = @()
$refHive = Mount-Hive $refSid $refNt 'TMP_IntlRef'
try {
    $k = $HKU.OpenSubKey("$($refHive.Name)\$IntlPath")
    if (-not $k) { throw "Chiave International assente nel riferimento ($refLabel)." }
    try {
        $refValues = @(Read-Values $k)
        $g = $k.OpenSubKey('Geo')
        if ($g) { try { $refGeo = @(Read-Values $g) } finally { $g.Dispose() } }
    } finally { $k.Dispose() }
} finally { Dismount-Hive $refHive }

$refLocale = ($refValues | Where-Object Name -eq 'LocaleName').Value
if ($refLocale -ne $ExpectedLocale) {
    throw "Il riferimento ($refLabel) ha LocaleName '$refLocale', atteso '$ExpectedLocale'. Esegui prima Set-DefaultUserItalianFormat.ps1 oppure indica -ReferenceUser."
}

# --- 2. Migrazione dell'utente ----------------------------------------------------
$sid = Resolve-Sid $UserName
if ($sid -eq $refSid) { throw 'Utente da migrare e riferimento coincidono.' }
$prof = Get-ProfileBySid $sid $UserName

$hive = Mount-Hive $sid (Join-Path $prof.LocalPath 'NTUSER.DAT') 'TMP_IntlTarget'
try {
    $k = $HKU.OpenSubKey("$($hive.Name)\$IntlPath", $true)
    if (-not $k) { $k = $HKU.CreateSubKey("$($hive.Name)\$IntlPath") }
    try {
        $prima = $k.GetValue('LocaleName')
        if (-not $prima) { $prima = '(assente)' }
        Write-Host "Utente: $UserName | locale attuale: $prima | riferimento: $refLabel ($refLocale)"

        if ($prima -eq $refLocale -and -not $Force) {
            Write-Host 'Già allineato, nessuna modifica (usa -Force per riscrivere i valori).'
            return
        }

        if ($PSCmdlet.ShouldProcess($UserName, "Imposta formato $refLocale copiando da $refLabel")) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
            $file = Join-Path $BackupDir ('{0}_{1}.reg' -f ($UserName -replace '[\\/:*?"<>|]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
            $out = & reg.exe export "HKU\$($hive.Name)\$IntlPath" "$file" /y 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Backup fallito, nessuna modifica eseguita: $out" }
            Write-Host "Backup: $file"

            foreach ($v in $refValues) { $k.SetValue($v.Name, $v.Value, $v.Kind) }
            if ($refGeo.Count) {
                $g = $k.CreateSubKey('Geo')
                try { foreach ($v in $refGeo) { $g.SetValue($v.Name, $v.Value, $v.Kind) } } finally { $g.Dispose() }
            }

            [pscustomobject]@{
                Utente      = $UserName
                LocalePrima = $prima
                LocaleDopo  = $k.GetValue('LocaleName')
                DataBreve   = $k.GetValue('sShortDate')
                OraBreve    = $k.GetValue('sShortTime')
                SepDecimale = "'$($k.GetValue('sDecimal'))'"
                SepMigliaia = "'$($k.GetValue('sThousand'))'"
            } | Format-List

            if ($hive.Active) {
                Write-Warning "$UserName ha una sessione attiva: il nuovo formato sarà effettivo al prossimo logon."
            }
        }
    } finally { $k.Dispose() }
} finally { Dismount-Hive $hive }
