# doi-kereso.ps1
#
# Megkeresi a publikacios lista tetelezeihez tartozo DOI azonositokat
# az OpenAlex es a Crossref adatbazisban, majd elkesziti a frissitett fajlt.
#
# Hasznalat PowerShell ablakban, a fajl mappajabol:
#
#   .\doi-kereso.ps1 -Limit 10        proba, csak az elso 10 talalat nelkuli tetelen
#   .\doi-kereso.ps1                  teljes futas
#   .\doi-kereso.ps1 -Feltoltes       teljes futas, a vegen felajanlja a feltoltest
#
# A szkript nem tarol kulcsot. Ha feltoltesre keri, a kulcsot csak az adott
# futas idejere kerdezi be.

param(
  [int]$Limit = 0,
  [switch]$Feltoltes,
  [string]$Owner  = 'strategicmate',
  [string]$Repo   = 'publikaciok',
  [string]$Path   = 'besenyojanos/index.html',
  [string]$Branch = 'main',
  [string]$Mail   = 'attilamate.kovacs@gmail.com'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- segedek

function Norm([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne
        [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
  }
  return ((($sb.ToString().ToLower()) -replace '[^a-z0-9]+', ' ').Trim())
}

function TitleMatch([string]$a, [string]$b) {
  $x = Norm $a; $y = Norm $b
  if (-not $x -or -not $y) { return $false }
  if ($x -eq $y) { return $true }

  if ($x.Length -ge $y.Length) { $long = $x; $short = $y } else { $long = $y; $short = $x }
  if ($long.StartsWith($short) -and ($short.Length / $long.Length) -ge 0.7) { return $true }

  $A = @($x -split ' ' | Where-Object { $_.Length -gt 3 } | Select-Object -Unique)
  $B = @($y -split ' ' | Where-Object { $_.Length -gt 3 } | Select-Object -Unique)
  if ($A.Count -lt 3 -or $B.Count -lt 3) { return $false }
  $hit = @($A | Where-Object { $B -contains $_ }).Count
  return (($hit / [Math]::Min($A.Count, $B.Count)) -ge 0.85)
}

function EvSzam($a, $b) {
  if (-not $a -or -not $b) { return $true }
  return ([Math]::Abs([int]$a - [int]$b) -le 1)
}

$script:UA  = 'doi-kereso/1.1 (mailto:' + $Mail + ')'
$script:Naplo = New-Object System.Collections.ArrayList

function Kerdez([string]$url, [string]$forras) {
  $varakozas = 800
  for ($p = 1; $p -le 3; $p++) {
    try {
      return Invoke-RestMethod -Uri $url -TimeoutSec 30 -UserAgent $script:UA `
               -Headers @{ 'Accept' = 'application/json' }
    } catch {
      $kod = 0
      if ($_.Exception.Response) { $kod = [int]$_.Exception.Response.StatusCode }
      $uz = "$forras" + $(if ($kod) { " HTTP $kod" }) + ': ' + $_.Exception.Message
      # forgalomkorlat vagy atmeneti szerverhiba: varunk es ujraprobaljuk
      if (($kod -eq 429 -or $kod -eq 500 -or $kod -eq 502 -or $kod -eq 503 -or $kod -eq 0) -and $p -lt 3) {
        [void]$script:Naplo.Add("$uz  [ujraprobalas $p]")
        Start-Sleep -Milliseconds $varakozas
        $varakozas = $varakozas * 3
        continue
      }
      [void]$script:Naplo.Add($uz)
      throw
    }
  }
}

function FromOpenAlex($rec) {
  $t = $rec.title
  if ($t.Length -gt 250) { $t = $t.Substring(0, 250) }
  $u = 'https://api.openalex.org/works?per-page=3&select=doi,title,publication_year' +
       '&mailto=' + $Mail + '&search=' + [Uri]::EscapeDataString($t)
  $j = Kerdez $u 'OpenAlex'
  foreach ($it in $j.results) {
    if (-not $it.doi) { continue }
    if (-not (TitleMatch $rec.title $it.title)) { continue }
    if (-not (EvSzam $rec.year $it.publication_year)) { continue }
    return [pscustomobject]@{
      doi     = ($it.doi -replace '^https?://(dx\.)?doi\.org/', '')
      matched = $it.title
      year    = $it.publication_year
      src     = 'OpenAlex'
    }
  }
  return $null
}

function FromCrossref($rec) {
  $t = $rec.title
  if ($t.Length -gt 250) { $t = $t.Substring(0, 250) }
  $u = 'https://api.crossref.org/works?rows=3&select=DOI,title,issued' +
       '&mailto=' + $Mail + '&query.bibliographic=' + [Uri]::EscapeDataString($t)
  $j = Kerdez $u 'Crossref'
  foreach ($it in $j.message.items) {
    $ct = $it.title | Select-Object -First 1
    if (-not $ct) { continue }
    if (-not (TitleMatch $rec.title $ct)) { continue }
    $cy = $null
    if ($it.issued.'date-parts') { $cy = $it.issued.'date-parts'[0][0] }
    if (-not (EvSzam $rec.year $cy)) { continue }
    return [pscustomobject]@{ doi = $it.DOI; matched = $ct; year = $cy; src = 'Crossref' }
  }
  return $null
}

# ---------------------------------------------------------------- beolvasas

Write-Host 'doi-kereso 1.2'
$raw = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/$Path"
Write-Host "Fajl letoltese: $raw"

$wc = New-Object System.Net.WebClient
$wc.Encoding = [System.Text.Encoding]::UTF8
$wc.Headers.Add('Cache-Control', 'no-cache')
$html = $wc.DownloadString($raw)

$m = [regex]::Match($html, '(?s)<script type="application/json" id="db">(.*?)</script>')
if (-not $m.Success) { throw 'Nem talalom az adatblokkot a fajlban.' }

$db = $m.Groups[1].Value | ConvertFrom-Json
Write-Host ("Betoltve: {0} tetel" -f $db.Count)

$todo = @($db | Where-Object { -not $_.doi -and -not $_.hidden -and $_.title })
if ($Limit -gt 0 -and $todo.Count -gt $Limit) { $todo = $todo[0..($Limit - 1)] }
Write-Host ("Kereses indul {0} tetelhez" -f $todo.Count)
Write-Host ''

# ---------------------------------------------------------------- kereses

$talalatok = New-Object System.Collections.ArrayList
$i = 0; $hibaOA = 0; $hibaCR = 0

foreach ($rec in $todo) {
  $i++
  Write-Progress -Activity 'DOI kereses' -Status "$i / $($todo.Count)" `
                 -PercentComplete ([int](100 * $i / $todo.Count))

  $hit = $null
  try { $hit = FromOpenAlex $rec } catch { $hibaOA++ }
  if (-not $hit) {
    Start-Sleep -Milliseconds 120
    try { $hit = FromCrossref $rec } catch { $hibaCR++ }
  }

  if ($hit) {
    $rec.doi = $hit.doi
    if ($rec.PSObject.Properties.Name -contains 'doi_source') { $rec.doi_source = $hit.src }
    else { $rec | Add-Member -NotePropertyName doi_source -NotePropertyValue $hit.src -Force }

    [void]$talalatok.Add([pscustomobject]@{
      MTMT        = $rec.mtmt_id
      Ev          = $rec.year
      Cim         = $rec.title
      TalaltCim   = $hit.matched
      TalaltEv    = $hit.year
      DOI         = $hit.doi
      Forras      = $hit.src
      Link        = "https://doi.org/$($hit.doi)"
    })
    Write-Host ("  [{0,3}] {1}  <-  {2}" -f $i, $hit.doi, $rec.title.Substring(0, [Math]::Min(60, $rec.title.Length)))
  }

  Start-Sleep -Milliseconds 150
}

Write-Progress -Activity 'DOI kereses' -Completed
Write-Host ''
$oa = @($talalatok | Where-Object { $_.Forras -eq 'OpenAlex' }).Count
$cr = @($talalatok | Where-Object { $_.Forras -eq 'Crossref' }).Count
Write-Host ("Kesz. {0} talalat {1} tetelbol." -f $talalatok.Count, $todo.Count)
Write-Host ("  OpenAlex: {0} talalat, {1} hiba" -f $oa, $hibaOA)
Write-Host ("  Crossref: {0} talalat, {1} hiba" -f $cr, $hibaCR)

if ($script:Naplo.Count -gt 0) {
  Write-Host ''
  Write-Host 'Hibauzenetek (elteroek, legfeljebb 5):'
  $script:Naplo | Select-Object -Unique | Select-Object -First 5 | ForEach-Object {
    Write-Host ('  ' + $_)
  }
}

if ($talalatok.Count -eq 0) { Write-Host 'Nincs mit menteni.'; return }

# ---------------------------------------------------------------- kiiras

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$csv   = Join-Path $PSScriptRoot "doi-jelentes-$stamp.csv"
$talalatok | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host "Jelentes: $csv"

$json = $db | ConvertTo-Json -Depth 12
$ev = [System.Text.RegularExpressions.MatchEvaluator] {
  param($mm) [string][char][int]('0x' + $mm.Groups[1].Value)
}
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', $ev)
$json = $json -replace '</', '<\/'

$uj = $html.Substring(0, $m.Index) +
      '<script type="application/json" id="db">' + $json + '</script>' +
      $html.Substring($m.Index + $m.Length)

$out = Join-Path $PSScriptRoot "index-$stamp.html"
[System.IO.File]::WriteAllText($out, $uj, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Frissitett fajl: $out"

# ---------------------------------------------------------------- feltoltes

if (-not $Feltoltes) {
  Write-Host ''
  Write-Host 'A feltoltes kimaradt. Nezd at a jelentest, es ha jo, futtasd ujra a -Feltoltes kapcsoloval,'
  Write-Host 'vagy toltsd fel kezzel a fenti fajlt a GitHubra.'
  return
}

Write-Host ''
Write-Host 'Nezd at a jelentest, mielott feltoltod.'
$valasz = Read-Host 'Feltoltsem a GitHubra? (i/n)'
if ($valasz -ne 'i') { Write-Host 'Feltoltes kihagyva.'; return }

$sec   = Read-Host 'Illeszd be a GitHub kulcsot' -AsSecureString
$token = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
           [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))

$api = "https://api.github.com/repos/$Owner/$Repo/contents/$Path"
$hdr = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json';
          'User-Agent'  = 'doi-kereso' }

$meta = Invoke-RestMethod -Uri "$api`?ref=$Branch" -Headers $hdr -TimeoutSec 30
$body = @{
  message = "DOI azonositok kiegeszitese ($($talalatok.Count) tetel)"
  content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($uj))
  sha     = $meta.sha
  branch  = $Branch
} | ConvertTo-Json -Depth 5

$r = Invoke-RestMethod -Uri $api -Method Put -Headers $hdr -Body $body `
       -ContentType 'application/json' -TimeoutSec 60

Write-Host ''
Write-Host "Feltoltve. Commit: $($r.commit.sha.Substring(0,7))"
Write-Host "Az elo oldal 1-2 percen belul frissul."
