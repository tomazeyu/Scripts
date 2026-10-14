#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Imposta il formato internazionale (data/ora, numeri) per i NUOVI utenti
    e per la schermata di benvenuto, su Windows Server 2022 / Windows 11.

.DESCRIPTION
    Copy-UserInternationalSettingsToSystem copia le impostazioni dell'utente
    CORRENTE. Lo script quindi:
      1. salva le impostazioni internazionali dell'utente che lo esegue (backup .reg);
      2. imposta temporaneamente $Culture e la posizione $GeoId;
      3. copia le impostazioni su schermata di benvenuto + profilo modello (C:\Users\Default);
      4. ripristina le impostazioni originali dell'utente che lo esegue;
      5. verifica rileggendo HKU\.DEFAULT e C:\Users\Default\NTUSER.DAT.
    Il locale di sistema (programmi non Unicode) NON viene toccato.

.PARAMETER Culture
    Cultura da applicare. Predefinito: it-IT.

.PARAMETER GeoId
    Posizione geografica. Predefinito: 118 (Italia).

.PARAMETER VerifyOnly
    Esegue solo la verifica, senza modifiche.

.EXAMPLE
    .\Set-DefaultUserItalianFormat.ps1
    .\Set-DefaultUserItalianFormat.ps1 -VerifyOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Culture = 'it-IT',
    [int]$GeoId = 118,
    [switch]$VerifyOnly
)

$campi = 'LocaleName','sShortDate','sLongDate','sShortTime','sTimeFormat','sDecimal','sThousand','sList'

function New-Riga([string]$Profilo, $Valori) {
    $h = [ordered]@{ Profilo = $Profilo }
    foreach ($c in $campi) { $h[$c] = if ($Valori) { $Valori.$c } else { '(chiave assente)' } }
    [pscustomobject]$h
}

function Show-Verifica {
    $righe = @()

    $k = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International'
    $v = if (Test-Path $k) { Get-ItemProperty $k } else { $null }
    $righe += New-Riga '.DEFAULT (benvenuto/sistema)' $v

    $hive = 'TMP_DefaultUser'
    $out = & reg.exe load "HKU\$hive" 'C:\Users\Default\NTUSER.DAT' 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $k = "Registry::HKEY_USERS\$hive\Control Panel\International"
            $v = if (Test-Path $k) { Get-ItemProperty $k } else { $null }
            $righe += New-Riga 'Default (modello nuovi utenti)' $v
        }
        finally {
            $v = $null
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            & reg.exe unload "HKU\$hive" 2>&1 | Out-Null
        }
    }
    else {
        Write-Warning "Impossibile caricare C:\Users\Default\NTUSER.DAT: $out"
    }

    $righe | Format-List
}

if ($VerifyOnly) { Show-Verifica; return }

if (-not (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue)) {
    throw 'Copy-UserInternationalSettingsToSystem non disponibile: serve Windows Server 2022 / Windows 11 o successivi.'
}

$backup = Join-Path $env:TEMP ("International_{0}_{1}.reg" -f $env:USERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))

if ($PSCmdlet.ShouldProcess('Schermata di benvenuto + profilo modello', "Imposta $Culture / GeoId $GeoId")) {
    $out = & reg.exe export 'HKCU\Control Panel\International' "$backup" /y 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Backup impostazioni utente corrente fallito: $out" }
    Write-Host "Backup impostazioni di $env:USERNAME in $backup"

    try {
        Set-Culture -CultureInfo $Culture
        Set-WinHomeLocation -GeoId $GeoId
        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        Write-Host "Impostazioni $Culture copiate su schermata di benvenuto e profilo modello."
    }
    finally {
        $out = & reg.exe import "$backup" 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "Ripristinate le impostazioni originali di $env:USERNAME." }
        else { Write-Warning "Ripristino impostazioni di $env:USERNAME fallito ($out). Backup: $backup" }
    }
}

Show-Verifica
Write-Host "Se i valori non risultano ancora $Culture, riavvia il server e rilancia con -VerifyOnly."
