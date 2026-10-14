#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Imposta il formato internazionale (data/ora, numeri) per i NUOVI utenti
    e per la schermata di benvenuto. Compatibile con Windows Server 2016/2019/2022.

.DESCRIPTION
    Usa un file XML di GlobalizationServices applicato con
    'control.exe intl.cpl,,/f:<file>' (metodo supportato anche su Server 2022).
    L'XML imposta $Culture e $GeoId sull'utente CORRENTE e li copia su
    schermata di benvenuto (CopySettingsToSystemAcct) e profilo modello
    (CopySettingsToDefaultUserAcct). Lo script quindi:
      1. salva le impostazioni internazionali dell'utente che lo esegue (backup .reg);
      2. applica l'XML e attende $WaitSeconds secondi (intl.cpl è asincrono);
      3. ripristina le impostazioni originali dell'utente che lo esegue;
      4. verifica rileggendo HKU\.DEFAULT e C:\Users\Default\NTUSER.DAT.
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
    [switch]$VerifyOnly,
    [int]$WaitSeconds = 15
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

$backup = Join-Path $env:TEMP ("International_{0}_{1}.reg" -f $env:USERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))

if ($PSCmdlet.ShouldProcess('Schermata di benvenuto + profilo modello', "Imposta $Culture / GeoId $GeoId")) {
    $out = & reg.exe export 'HKCU\Control Panel\International' "$backup" /y 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Backup impostazioni utente corrente fallito: $out" }
    Write-Host "Backup impostazioni di $env:USERNAME in $backup"

    try {
        $xmlPath = Join-Path $env:TEMP "GlobalizationServices_$Culture.xml"
        $xml = @"
<gs:GlobalizationServices xmlns:gs="urn:longhornGlobalizationUnattend">
  <gs:UserList>
    <gs:User UserID="Current" CopySettingsToDefaultUserAcct="true" CopySettingsToSystemAcct="true"/>
  </gs:UserList>
  <gs:UserLocale>
    <gs:Locale Name="$Culture" SetAsCurrent="true" ResetAllSettings="true"/>
  </gs:UserLocale>
  <gs:LocationPreferences>
    <gs:GeoID Value="$GeoId"/>
  </gs:LocationPreferences>
</gs:GlobalizationServices>
"@
        Set-Content -Path $xmlPath -Value $xml -Encoding UTF8

        & control.exe "intl.cpl,,/f:`"$xmlPath`""
        Write-Host "XML applicato, attendo $WaitSeconds secondi..."
        Start-Sleep -Seconds $WaitSeconds
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
