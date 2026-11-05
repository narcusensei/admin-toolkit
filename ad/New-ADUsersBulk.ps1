<#
.SYNOPSIS
    Création en masse de comptes Active Directory depuis un fichier CSV.

.DESCRIPTION
    Le script uniformise les attributs des comptes créés :
      - Nom affiché    : "Prenom Nom"
      - SamAccountName : prenom.nom (sans accents, max 20 caractères, dédoublonné)
      - UPN            : prenom.nom@suffixe
      - Description    : "Créé en masse le AAAA-MM-JJ - Département - Fonction"

    Chaque compte reçoit un mot de passe temporaire (colonne du CSV, paramètre
    -TempPassword, ou généré aléatoirement) et l'option "L'utilisateur doit changer
    de mot de passe à la prochaine ouverture de session" est activée par défaut.

    Un rapport CSV récapitulatif est produit en fin d'exécution. ATTENTION : il
    contient les mots de passe temporaires, à transmettre par un canal sûr puis
    à supprimer.

.PARAMETER CsvPath
    Fichier CSV d'entrée. Colonnes reconnues (FR ou EN, casse indifférente) :
      Prenom/FirstName, Nom/LastName, SamAccountName (optionnel),
      Departement/Department, Fonction/Title, OU (optionnel),
      Email (optionnel), MotDePasse/Password (optionnel)
    Séparateur ',' ou ';' détecté automatiquement. Encodage UTF-8 recommandé.

.EXAMPLE
    .\New-ADUsersBulk.ps1 -CsvPath .\nouveaux.csv -TargetOu "OU=Utilisateurs,DC=boite,DC=local" -Company "Boite SARL"

.EXAMPLE
    .\New-ADUsersBulk.ps1 -CsvPath .\nouveaux.csv -WhatIf

.NOTES
    Codes retour : 0 = OK (éventuellement des ignorés) · 2 = au moins un échec
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    # OU cible par défaut (ex: "OU=Utilisateurs,DC=boite,DC=local"). Sinon : conteneur Users du domaine.
    [string]$TargetOu,

    # Suffixe UPN (ex: "boite.local"). Sinon : racine DNS du domaine.
    [string]$UpnSuffix,

    # Attribut Société appliqué à tous les comptes.
    [string]$Company,

    # Mot de passe temporaire commun à tous les comptes (sinon : colonne CSV ou généré).
    [string]$TempPassword,

    # Longueur des mots de passe générés.
    [ValidateRange(8, 64)]
    [int]$PasswordLength = 14,

    # Désactive le forçage du changement de mot de passe à la première ouverture.
    [switch]$NoChangeAtLogon,

    # Chemin du rapport CSV (défaut : rapport-creation-<date>.csv à côté du script).
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pré-requis : module ActiveDirectory + domaine joignable
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host 'ERREUR : le module ActiveDirectory est absent (outils RSAT).' -ForegroundColor Red
    Write-Host 'Installez-le depuis une console administrateur :' -ForegroundColor Red
    Write-Host "  Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'" -ForegroundColor Yellow
    exit 1
}
Import-Module ActiveDirectory

try {
    $domain = Get-ADDomain -ErrorAction Stop
}
catch {
    Write-Host "ERREUR : impossible d'interroger le domaine Active Directory : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $UpnSuffix) { $UpnSuffix = $domain.DNSRoot }
$defaultOu = if ($TargetOu) { $TargetOu } else { $domain.UsersContainer }

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------
function Remove-Diacritics {
    param([string]$Text)
    if (-not $Text) { return '' }
    $normalized = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalized.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($cat -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

function Get-RowValue {
    # Renvoie la première colonne renseignée parmi les noms proposés (casse indifférente)
    param($Row, [string[]]$Names)
    foreach ($name in $Names) {
        $prop = $Row.PSObject.Properties |
            Where-Object { $_.Name.Trim() -ieq $name } |
            Select-Object -First 1
        if ($prop -and "$($prop.Value)".Trim()) { return "$($prop.Value)".Trim() }
    }
    return ''
}

function New-TempPassword {
    # Mot de passe aléatoire respectant la complexité AD (4 familles garanties),
    # sans caractères ambigus (I, O, l, o, 0, 1) ni guillemets.
    param([int]$Length = 14)
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $lower  = 'abcdefghijkmnpqrstuvwxyz'.ToCharArray()
    $digits = '23456789'.ToCharArray()
    $spec   = '!#$%&*+-=?@'.ToCharArray()
    $all    = $upper + $lower + $digits + $spec
    $chars = @(
        (Get-Random -InputObject $upper)
        (Get-Random -InputObject $lower)
        (Get-Random -InputObject $digits)
        (Get-Random -InputObject $spec)
    )
    while ($chars.Count -lt $Length) { $chars += (Get-Random -InputObject $all) }
    -join ($chars | Get-Random -Count $chars.Count)
}

function ConvertTo-SamName {
    # prenom.nom : premier prénom + nom, sans accents ni caractères spéciaux, 20 car. max
    param([string]$First, [string]$Last)
    $f = ((Remove-Diacritics $First) -split '[^a-zA-Z]' | Where-Object { $_ } | Select-Object -First 1)
    $l = (Remove-Diacritics $Last) -replace '[^a-zA-Z]', ''
    $sam = ('{0}.{1}' -f "$f".ToLower(), $l.ToLower()).Trim('.')
    if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20).Trim('.') }
    return $sam
}

function Test-AdUserExists {
    param([string]$Sam)
    try {
        Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction Stop | Select-Object -First 1
    }
    catch { $null }
}

# ---------------------------------------------------------------------------
# Lecture du CSV (séparateur ',' ou ';' détecté automatiquement)
# ---------------------------------------------------------------------------
$firstLine = Get-Content -LiteralPath $CsvPath -TotalCount 1
if (-not $firstLine) {
    Write-Host 'ERREUR : le fichier CSV est vide.' -ForegroundColor Red
    exit 1
}
$delimiter = if ((($firstLine -split ';').Count) -gt (($firstLine -split ',').Count)) { ';' } else { ',' }

try {
    $rows = @(Import-Csv -LiteralPath $CsvPath -Delimiter $delimiter -Encoding UTF8)
}
catch {
    Write-Host "ERREUR : lecture du CSV impossible : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if ($rows.Count -eq 0) {
    Write-Host 'ERREUR : aucune ligne de données dans le CSV.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== Création en masse de comptes Active Directory ===' -ForegroundColor Cyan
Write-Host "  Fichier       : $CsvPath ($($rows.Count) lignes, séparateur '$delimiter')"
Write-Host "  Domaine       : $($domain.DNSRoot)"
Write-Host "  Suffixe UPN   : $UpnSuffix"
Write-Host "  OU par défaut : $defaultOu"
if ($Company) { Write-Host "  Société       : $Company" }
Write-Host ''

# ---------------------------------------------------------------------------
# Traitement
# ---------------------------------------------------------------------------
$results  = @()
$usedSams = @{}
$created = 0; $skipped = 0; $failed = 0; $simulated = 0

foreach ($row in $rows) {
    $first = Get-RowValue $row @('Prenom', 'FirstName', 'GivenName')
    $last  = Get-RowValue $row @('Nom', 'LastName', 'Surname')
    $display = (("$first $last" -replace '\s+', ' ')).Trim()

    # Ligne vide -> ignorée silencieusement ; ligne incomplète -> échec documenté
    if (-not $first -or -not $last) {
        if ($display) {
            $failed++
            $results += [PSCustomObject]@{
                Statut = 'Échec'; SamAccountName = ''; NomAffiche = $display; UPN = ''
                OU = ''; MotDePasseTemporaire = ''; Erreur = 'Prenom et/ou Nom manquant dans le CSV'
            }
            Write-Host "  [ÉCHEC ] $display - Prenom et/ou Nom manquant" -ForegroundColor Red
        }
        continue
    }

    $dept     = Get-RowValue $row @('Departement', 'Department')
    $title    = Get-RowValue $row @('Fonction', 'Title', 'Poste')
    $rowOu    = Get-RowValue $row @('OU', 'OrganizationalUnit')
    $email    = Get-RowValue $row @('Email', 'Mail', 'EmailAddress')
    $csvPwd   = Get-RowValue $row @('MotDePasse', 'Password')
    $rowSam   = Get-RowValue $row @('SamAccountName', 'Sam', 'Login')

    # --- SamAccountName : fourni ou généré, dédoublonné dans le lot ---
    if ($rowSam) {
        $sam = ((Remove-Diacritics $rowSam) -replace '[^a-zA-Z0-9._-]', '').ToLower()
    }
    else {
        $sam = ConvertTo-SamName $first $last
    }
    $baseSam = $sam; $i = 2
    while ($usedSams.ContainsKey($sam)) { $sam = "${baseSam}$i"; $i++ }
    $usedSams[$sam] = $true

    $upn = "$sam@$UpnSuffix"
    $ouPath = if ($rowOu) { $rowOu } else { $defaultOu }

    # --- Doublon déjà présent dans l'AD ---
    if (Test-AdUserExists $sam) {
        $skipped++
        $results += [PSCustomObject]@{
            Statut = 'Ignoré'; SamAccountName = $sam; NomAffiche = $display; UPN = $upn
            OU = $ouPath; MotDePasseTemporaire = ''; Erreur = 'Compte déjà présent dans Active Directory'
        }
        Write-Host "  [IGNORÉ] $display -> $sam (existe déjà)" -ForegroundColor Yellow
        continue
    }

    # --- Mot de passe temporaire : CSV > paramètre > généré ---
    $plainPwd = if ($csvPwd) { $csvPwd } elseif ($TempPassword) { $TempPassword } else { New-TempPassword $PasswordLength }

    # --- Description uniformisée ---
    $descParts = @($dept, $title) | Where-Object { $_ }
    $desc = if ($descParts) { $descParts -join ' - ' } else { 'Compte standard' }
    $desc = "Créé en masse le $(Get-Date -Format 'yyyy-MM-dd') - $desc"

    $params = @{
        Name                  = $display
        DisplayName           = $display
        GivenName             = $first
        Surname               = $last
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        Path                  = $ouPath
        AccountPassword       = (ConvertTo-SecureString $plainPwd -AsPlainText -Force)
        Enabled               = $true
        ChangePasswordAtLogon = (-not $NoChangeAtLogon)
        Description           = $desc
        ErrorAction           = 'Stop'
    }
    if ($dept)    { $params.Department  = $dept }
    if ($title)   { $params.Title       = $title }
    if ($email)   { $params.EmailAddress = $email }
    if ($Company) { $params.Company     = $Company }

    if ($PSCmdlet.ShouldProcess($upn, "Créer le compte AD")) {
        try {
            New-ADUser @params
            $created++
            $results += [PSCustomObject]@{
                Statut = 'Créé'; SamAccountName = $sam; NomAffiche = $display; UPN = $upn
                OU = $ouPath; MotDePasseTemporaire = $plainPwd; Erreur = ''
            }
            Write-Host "  [CRÉÉ  ] $display -> $sam" -ForegroundColor Green
        }
        catch {
            $failed++
            $results += [PSCustomObject]@{
                Statut = 'Échec'; SamAccountName = $sam; NomAffiche = $display; UPN = $upn
                OU = $ouPath; MotDePasseTemporaire = $plainPwd; Erreur = $_.Exception.Message
            }
            Write-Host "  [ÉCHEC ] $display -> $sam : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        $simulated++
        $results += [PSCustomObject]@{
            Statut = 'Simulé'; SamAccountName = $sam; NomAffiche = $display; UPN = $upn
            OU = $ouPath; MotDePasseTemporaire = $plainPwd; Erreur = '(-WhatIf)'
        }
        Write-Host "  [SIMULÉ] $display -> $sam" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# Rapport + résumé
# ---------------------------------------------------------------------------
if (-not $ReportPath) {
    $ReportPath = Join-Path $PSScriptRoot ('rapport-creation-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
}
$results | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'

Write-Host ''
Write-Host '=== Résumé ===' -ForegroundColor Cyan
Write-Host ("  Créés   : {0}" -f $created) -ForegroundColor Green
if ($simulated) { Write-Host ("  Simulés : {0} (-WhatIf)" -f $simulated) -ForegroundColor DarkYellow }
Write-Host ("  Ignorés : {0} (déjà existants)" -f $skipped) -ForegroundColor Yellow
Write-Host ("  Échecs  : {0}" -f $failed) -ForegroundColor $(if ($failed) { 'Red' } else { 'DarkGray' })
Write-Host ("  Rapport : {0}" -f $ReportPath)
Write-Host ''
Write-Host 'ATTENTION : le rapport contient les mots de passe temporaires.' -ForegroundColor Yellow
Write-Host 'Transmettez-les par un canal sûr, puis supprimez le fichier.' -ForegroundColor Yellow
Write-Host ''

if ($failed -gt 0) { exit 2 } else { exit 0 }
