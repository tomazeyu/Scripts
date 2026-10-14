#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Elenca i profili utente presenti sul PC (locali e di dominio) e, per ciascuno,
    le impostazioni internazionali di data/ora e formato numerico.

.DESCRIPTION
    Le impostazioni sono per-utente in HKU\<SID>\Control Panel\International.
    - Utenti con sessione attiva: hive già caricato, letto direttamente.
    - Utenti non connessi: NTUSER.DAT caricato temporaneamente e poi scaricato.

.PARAMETER CsvPath
    Se indicato, esporta il risultato in CSV (separatore ';').

.PARAMETER IncludeDefault
    Aggiunge la riga .DEFAULT (account di sistema / schermata di logon).

.EXAMPLE
    .\Get-UserRegionalSettings.ps1
    .\Get-UserRegionalSettings.ps1 -IncludeDefault -CsvPath C:\Temp\regional.csv
#>
[CmdletBinding()]
param(
    [string]$CsvPath,
    [switch]$IncludeDefault
)

function Resolve-UserName([string]$Sid, [string]$LocalPath) {
    try {
        ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value
    } catch {
        "(SID non risolto) " + (Split-Path $LocalPath -Leaf)
    }
}

# Rende visibili i separatori (spazio, spazio non separabile, stringa vuota)
function Show-Sep([string]$s) {
    if ($null -eq $s) { return $null }
    $vis = $s -replace ' ', '<spazio>' -replace [char]0x00A0, '<nbsp>' -replace [char]0x202F, '<nnbsp>'
    "'$vis'"
}

function New-Row($Utente, $Sid, $UltimoUso, $Intl, $Note, $CreatoIl = $null) {
    [pscustomobject]@{
        Utente       = $Utente
        SID          = $Sid
        CreatoIl     = $CreatoIl
        UltimoUso    = $UltimoUso
        Locale       = $Intl.LocaleName
        DataBreve    = $Intl.sShortDate
        DataLunga    = $Intl.sLongDate
        OraBreve     = $Intl.sShortTime
        OraLunga     = $Intl.sTimeFormat
        SepDecimale  = Show-Sep $Intl.sDecimal
        SepMigliaia  = Show-Sep $Intl.sThousand
        SepElenco    = Show-Sep $Intl.sList
        SegnoNeg     = $Intl.sNegativeSign
        Note         = $Note
    }
}

function Get-Intl([string]$HiveRoot) {
    $key = "Registry::$HiveRoot\Control Panel\International"
    if (Test-Path $key) { Get-ItemProperty -Path $key -ErrorAction SilentlyContinue }
}

$risultati = New-Object System.Collections.Generic.List[object]

if ($IncludeDefault) {
    $risultati.Add((New-Row '.DEFAULT' 'S-1-5-18 / logon' $null (Get-Intl 'HKEY_USERS\.DEFAULT') 'impostazioni di sistema'))
}

$profili = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | Sort-Object LocalPath

foreach ($p in $profili) {
    $sid      = $p.SID
    $utente   = Resolve-UserName $sid $p.LocalPath
    $hiveRoot = "HKEY_USERS\$sid"
    $tmpName  = $null
    $note     = ''
    $intl     = $null

    if (Test-Path "Registry::$hiveRoot") {
        $note = 'sessione attiva'
    }
    else {
        $ntuser = Join-Path $p.LocalPath 'NTUSER.DAT'
        if (Test-Path -LiteralPath $ntuser) {
            $tmpName = 'TMP_' + ($sid -replace '[^\w]', '_')
            $null = & reg.exe load "HKU\$tmpName" "$ntuser" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $hiveRoot = "HKEY_USERS\$tmpName"
            } else {
                $tmpName = $null
                $note = 'NTUSER.DAT non caricabile (in uso o danneggiato)'
            }
        } else {
            $note = 'NTUSER.DAT assente'
        }
    }

    if (-not $note -or $note -eq 'sessione attiva') {
        $intl = Get-Intl $hiveRoot
        if (-not $intl) { $note = ($note + ' chiave International assente: usa i predefiniti').Trim() }
    }

    # Win32_UserProfile non espone la data di creazione: si usa quella della cartella del profilo
    $creato = $null
    try { $creato = (Get-Item -LiteralPath $p.LocalPath -Force -ErrorAction Stop).CreationTime } catch { }

    $risultati.Add((New-Row $utente $sid $p.LastUseTime $intl $note $creato))

    # Scarica l'hive caricato dallo script (rilascia prima gli handle)
    if ($tmpName) {
        $intl = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        for ($i = 0; $i -lt 3; $i++) {
            $null = & reg.exe unload "HKU\$tmpName" 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Milliseconds 500
            [GC]::Collect()
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Impossibile scaricare HKU\$tmpName ($utente): scaricarlo a mano con 'reg unload HKU\$tmpName'."
        }
    }
}

$risultati | Format-Table Utente, CreatoIl, Locale, DataBreve, DataLunga, OraBreve, OraLunga, SepDecimale, SepMigliaia, SepElenco, Note -AutoSize -Wrap

if ($CsvPath) {
    $risultati | Export-Csv -Path $CsvPath -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Write-Host "Esportato in $CsvPath"
}
