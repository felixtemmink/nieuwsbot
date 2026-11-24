# Nieuwsbot - leest beursnieuws, schat in of het positief of negatief klinkt,
# laat zien hoeveel de koers al bewogen is, en houdt op papier bij hoe de
# meldingen uitpakken. Plaatst NOOIT zelf orders. Geen beleggingsadvies.
#
# Gebruik:  start-nieuwsbot.bat   (blijft draaien)
#           rapport.bat           (papier-resultaten bekijken)

param(
    [switch]$EenKeer,   # een ronde draaien en stoppen (om te testen)
    [switch]$Rapport,   # alleen het papier-rapport tonen
    [switch]$Stil,      # geen meldingen (om te testen)
    [switch]$TestPush   # een testmelding naar je telefoon sturen
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Map          = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstFile     = Join-Path $Map 'instellingen.txt'
$GezienFile   = Join-Path $Map 'gezien.txt'
$SignaalFile  = Join-Path $Map 'signalen.csv'
$LogFile      = Join-Path $Map 'logboek.txt'
$Headers      = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
$Inv          = [Globalization.CultureInfo]::InvariantCulture

# ------------------------------------------------------------------ hulp
function Write-Log([string]$tekst) {
    $regel = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $tekst
    Add-Content -Path $LogFile -Value $regel -Encoding UTF8
}

function Read-Instellingen {
    $aandelen = [ordered]@{}
    $regels = @{ ControleerElkeMinuten = 5; TeLaatVanafProcent = 3; MaxLeeftijdUren = 3; GeschatteKostenProcent = 0.3 }
    $telefoon = @{ NtfyOnderwerp = '' }
    $sectie = ''
    foreach ($r in (Get-Content -Path $InstFile -Encoding UTF8)) {
        $r = $r.Trim()
        if ($r -eq '' -or $r.StartsWith('#')) { continue }
        if ($r -match '^\[(.+)\]$') { $sectie = $Matches[1].ToLower(); continue }
        if ($r -notmatch '^([^=]+)=(.*)$') { continue }
        $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
        if ($sectie -eq 'aandelen') {
            $namen = @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $aandelen[$k.ToUpper()] = $namen
        } elseif ($sectie -eq 'regels') {
            $regels[$k] = [double]::Parse($v.Replace(',', '.'), $Inv)
        } elseif ($sectie -eq 'telefoon') {
            $telefoon[$k] = $v
        }
    }
    return @{ Aandelen = $aandelen; Regels = $regels; Telefoon = $telefoon }
}

function Get-Unix([DateTimeOffset]$d) { return $d.ToUnixTimeSeconds() }
function Get-Nu { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Format-Tijd([long]$unix) { return [DateTimeOffset]::FromUnixTimeSeconds($unix).ToLocalTime().ToString('dd-MM HH:mm') }
function Format-Pct([double]$p) { return ('{0}{1}%' -f $(if ($p -ge 0) { '+' } else { '' }), $p.ToString('0.0', $Inv)) }

# ------------------------------------------------------------------ data ophalen
function Get-Nieuws([string]$ticker) {
    $url = "https://feeds.finance.yahoo.com/rss/2.0/headline?s=$ticker&region=US&lang=en-US"
    $resp = Invoke-WebRequest -UseBasicParsing -Headers $Headers -Uri $url -TimeoutSec 20
    $xml = [xml]([Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()))
    $uit = @()
    foreach ($item in @($xml.rss.channel.item)) {
        if (-not $item) { continue }
        try { $t = [DateTimeOffset]::Parse([string]$item.pubDate, $Inv) } catch { continue }
        $uit += [pscustomobject]@{ Kop = [string]$item.title; Link = [string]$item.link; Tijd = (Get-Unix $t) }
    }
    return $uit
}

# Koersen: lijst van @{T = unixtijd; P = slotkoers}
$script:KoersCache = @{}
function Get-Koersen([string]$ticker, [string]$interval, [string]$bereik) {
    $sleutel = "$ticker|$interval|$bereik"
    if ($script:KoersCache.ContainsKey($sleutel)) { return $script:KoersCache[$sleutel] }
    $url = "https://query1.finance.yahoo.com/v8/finance/chart/$ticker`?interval=$interval&range=$bereik"
    $c = Invoke-RestMethod -Headers $Headers -Uri $url -TimeoutSec 20
    $res = $c.chart.result[0]
    $ts = @($res.timestamp); $cl = @($res.indicators.quote[0].close)
    $lijst = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $ts.Count; $i++) {
        if ($null -ne $cl[$i]) { $lijst.Add(@{ T = [long]$ts[$i]; P = [double]$cl[$i] }) }
    }
    $uit = @{ Lijst = $lijst; Nu = [double]$res.meta.regularMarketPrice; Munt = [string]$res.meta.currency }
    $script:KoersCache[$sleutel] = $uit
    return $uit
}

function Get-KoersOp($koersen, [long]$tijd) {
    # laatste koers op of voor dat tijdstip
    $p = $null
    foreach ($b in $koersen.Lijst) { if ($b.T -le $tijd) { $p = $b.P } else { break } }
    return $p
}

function Get-KoersNa($koersen, [long]$tijd) {
    # eerste koers op of na dat tijdstip
    foreach ($b in $koersen.Lijst) { if ($b.T -ge $tijd) { return $b.P } }
    return $null
}

# ------------------------------------------------------------------ toon inschatten
# Ruwe inschatting op trefwoorden in Engelstalige koppen. Geen voorspelling.
$PosWoorden = @('beat','beats','tops','surge','surges','soar','soars','jump','jumps','rally','rallies',
    'record','upgrade','upgrades','upgraded','raises guidance','raises outlook','raises forecast','strong',
    'buyback','approval','approved','wins','outperform','bullish','boost','boosts','gain','gains',
    'rebound','rebounds','higher','exceeds','tops estimates','partnership','climbs','rises','rise')
$NegWoorden = @('miss','misses','plunge','plunges','tumble','tumbles','slump','slumps','sink','sinks',
    'drop','drops','fall','falls','slide','slides','downgrade','downgrades','downgraded','cuts','cut',
    'lowers','weak','weaker','lawsuit','sues','probe','investigation','recall','ban','bans','restrictions',
    'warns','warning','bearish','layoffs','fraud','fined','decline','declines','loss','losses','selloff',
    'sell-off','pressure','retreat','concern','concerns','fears','lower','slashes','crash',
    'fades','fade','fading','doubts','stalls','don t chase','dont chase','bubble','overvalued')

function Get-Toon([string]$kop) {
    $k = ' ' + (($kop.ToLower() -replace '[^a-z0-9\- ]', ' ') -replace '\s+', ' ') + ' '
    $pos = 0; $neg = 0
    foreach ($w in $PosWoorden) { if ($k.Contains(" $w ")) { $pos++ } }
    foreach ($w in $NegWoorden) { if ($k.Contains(" $w ")) { $neg++ } }
    $score = $pos - $neg
    $label = if ($score -gt 0) { 'Positief' } elseif ($score -lt 0) { 'Negatief' } else { 'Neutraal' }
    return @{ Score = $score; Label = $label }
}

# ------------------------------------------------------------------ melding
function Show-Melding([string]$titel, [string]$tekst) {
    if ($Stil -or $env:GITHUB_ACTIONS) { return }
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t1 = [Security.SecurityElement]::Escape($titel); $t2 = [Security.SecurityElement]::Escape($tekst)
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t1</text><text>$t2</text></binding></visual></toast>")
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $n = New-Object System.Windows.Forms.NotifyIcon
            $n.Icon = [System.Drawing.SystemIcons]::Information
            $n.Visible = $true
            $n.ShowBalloonTip(10000, $titel, $tekst, 'Info')
            Start-Sleep -Seconds 1
        } catch { }
    }
}

function Get-NtfyOnderwerp($inst) {
    # In de cloud (GitHub) staat de naam geheim in NTFY_TOPIC; anders uit instellingen.txt
    if ($env:NTFY_TOPIC) { return $env:NTFY_TOPIC.Trim() }
    return $inst.Telefoon.NtfyOnderwerp
}

function Send-Push([string]$onderwerp, [string]$titel, [string]$tekst, [string]$link, [string]$toon) {
    # Pushmelding naar telefoon via ntfy.sh (gratis app "ntfy").
    if ($Stil -or -not $onderwerp) { return }
    try {
        $asciiTitel = ($titel -replace '[^\x20-\x7E]', '')
        $tags = if ($toon -eq 'Positief') { 'chart_with_upwards_trend' } else { 'chart_with_downwards_trend' }
        $h = @{ 'Title' = $asciiTitel; 'Tags' = $tags; 'Priority' = 'high' }
        if ($link) { $h['Click'] = $link }
        $body = [Text.Encoding]::UTF8.GetBytes($tekst)
        Invoke-RestMethod -Method Post -Uri ("https://ntfy.sh/" + $onderwerp) -Headers $h -Body $body -ContentType 'text/plain; charset=utf-8' -TimeoutSec 15 | Out-Null
    } catch {
        Write-Host "     (pushmelding naar telefoon mislukt: $($_.Exception.Message))" -ForegroundColor DarkYellow
        Write-Log "Push mislukt: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ papier-administratie
function Read-Signalen {
    if (Test-Path $SignaalFile) { return @(Import-Csv -Path $SignaalFile -Encoding UTF8) }
    return @()
}
function Save-Signalen($rijen) {
    if (@($rijen).Count -gt 0) { $rijen | Export-Csv -Path $SignaalFile -NoTypeInformation -Encoding UTF8 }
}

function Update-PapierResultaten($inst) {
    # Vul voor oude meldingen in wat de koers 1 dag later deed.
    $rijen = @(Read-Signalen)
    if ($rijen.Count -eq 0) { return }
    $kosten = $inst.Regels.GeschatteKostenProcent
    $nu = Get-Nu
    $gewijzigd = $false
    foreach ($r in $rijen) {
        if ($r.KoersNa1Dag -ne '' -or $r.KoersBijMelding -eq '') { continue }
        $doel = [long]$r.MeldingUnix + 86400
        if ($doel -gt $nu) { continue }
        try {
            $k = Get-Koersen $r.Aandeel '30m' '1mo'
            $na = Get-KoersNa $k $doel
            if ($null -eq $na) { continue }
            $bij = [double]::Parse($r.KoersBijMelding, $Inv)
            $beweging = ($na / $bij - 1) * 100
            # Positief: alsof je kocht. Negatief: alsof je verkocht / wegbleef.
            $richting = if ($r.Toon -eq 'Positief') { 1 } else { -1 }
            $r.KoersNa1Dag = $na.ToString('0.00', $Inv)
            $r.ResultaatPct = ($richting * $beweging - $kosten).ToString('0.00', $Inv)
            $gewijzigd = $true
        } catch { Write-Log "Kon 1-dag-koers niet ophalen voor $($r.Aandeel): $($_.Exception.Message)" }
    }
    if ($gewijzigd) { Save-Signalen $rijen }
}

function Show-Rapport {
    $inst = Read-Instellingen
    Update-PapierResultaten $inst
    $rijen = @(Read-Signalen)
    Write-Host ''
    Write-Host '=== PAPIER-RAPPORT (geen echt geld) ===' -ForegroundColor Cyan
    Write-Host "Totaal meldingen: $($rijen.Count)"
    $klaar = @($rijen | Where-Object { $_.ResultaatPct -ne '' })
    Write-Host "Waarvan al 1 dag oud (meetbaar): $($klaar.Count)"
    if ($klaar.Count -eq 0) {
        Write-Host ''
        Write-Host 'Nog niets te meten. Laat de bot een paar dagen draaien en kijk dan opnieuw.' -ForegroundColor Yellow
        return
    }
    $groepen = @(
        @{ Naam = 'Alle meetbare meldingen';         Rijen = $klaar },
        @{ Naam = 'Alleen meldingen NIET te laat';    Rijen = @($klaar | Where-Object { $_.TeLaat -eq 'nee' }) },
        @{ Naam = 'Alleen meldingen al TE LAAT';      Rijen = @($klaar | Where-Object { $_.TeLaat -eq 'ja' }) }
    )
    foreach ($g in $groepen) {
        $n = $g.Rijen.Count
        if ($n -eq 0) { continue }
        $res = @($g.Rijen | ForEach-Object { [double]::Parse($_.ResultaatPct, $Inv) })
        $goed = @($res | Where-Object { $_ -gt 0 }).Count
        $gem = ($res | Measure-Object -Average).Average
        $som = ($res | Measure-Object -Sum).Sum
        Write-Host ''
        Write-Host $g.Naam -ForegroundColor White
        Write-Host ('  Aantal: {0}   Winst na kosten: {1} van {0} ({2}%)' -f $n, $goed, [math]::Round(100 * $goed / $n))
        $kleur = if ($gem -ge 0) { 'Green' } else { 'Red' }
        Write-Host ('  Gemiddeld per melding: {0}   Opgeteld: {1}' -f (Format-Pct $gem), (Format-Pct $som)) -ForegroundColor $kleur
    }
    Write-Host ''
    Write-Host 'Lees dit zo: "had ik elke melding 1 dag gevolgd, na geschatte kosten".' -ForegroundColor DarkGray
    Write-Host 'Minder dan zo''n 50 metingen zegt nog weinig; dat kan toeval zijn.' -ForegroundColor DarkGray
    if ($klaar.Count -lt 50) { Write-Host "Je hebt er nu $($klaar.Count). Wacht met conclusies." -ForegroundColor Yellow }
}

# ------------------------------------------------------------------ een ronde
function Invoke-Ronde {
    $inst = Read-Instellingen
    $r = $inst.Regels
    $script:KoersCache = @{}
    $gezien = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path $GezienFile) { foreach ($g in (Get-Content $GezienFile -Encoding UTF8)) { [void]$gezien.Add($g) } }
    $nu = Get-Nu
    $maxLeeftijd = [long]($r.MaxLeeftijdUren * 3600)
    $nieuweSignalen = @()
    $aantalNieuw = 0

    foreach ($ticker in $inst.Aandelen.Keys) {
        $namen = @($inst.Aandelen[$ticker]) + $ticker
        try { $items = Get-Nieuws $ticker }
        catch { Write-Host "  [$ticker] nieuws ophalen mislukt: $($_.Exception.Message)" -ForegroundColor DarkYellow; Write-Log "Nieuws $ticker mislukt: $($_.Exception.Message)"; continue }

        foreach ($it in $items) {
            if ($gezien.Contains($it.Link)) { continue }
            [void]$gezien.Add($it.Link)
            Add-Content -Path $GezienFile -Value $it.Link -Encoding UTF8
            if (($nu - $it.Tijd) -gt $maxLeeftijd) { continue }

            # gaat het bericht echt over dit aandeel?
            $overAandeel = $false
            foreach ($n in $namen) { if ($it.Kop -match ('\b' + [regex]::Escape($n) + '\b')) { $overAandeel = $true; break } }
            if (-not $overAandeel) { continue }

            $aantalNieuw++
            $toon = Get-Toon $it.Kop
            if ($toon.Label -eq 'Neutraal') {
                Write-Host ("  [{0}] neutraal  {1}" -f $ticker, $it.Kop) -ForegroundColor DarkGray
                continue
            }

            # koers bij het bericht en nu
            $koersNieuws = $null; $koersNu = $null; $beweging = $null; $teLaat = 'onbekend'; $munt = ''
            try {
                $k = Get-Koersen $ticker '5m' '5d'
                $munt = $k.Munt
                $koersNu = $k.Nu
                $koersNieuws = Get-KoersOp $k $it.Tijd
                if ($koersNieuws) {
                    $beweging = ($koersNu / $koersNieuws - 1) * 100
                    $inRichting = if ($toon.Label -eq 'Positief') { $beweging } else { -$beweging }
                    $teLaat = if ($inRichting -ge $r.TeLaatVanafProcent) { 'ja' } else { 'nee' }
                }
            } catch { Write-Log "Koers $ticker mislukt: $($_.Exception.Message)" }

            $bewTekst = if ($null -ne $beweging) { Format-Pct $beweging } else { 'onbekend' }
            $kleur = if ($toon.Label -eq 'Positief') { 'Green' } else { 'Red' }
            Write-Host ''
            Write-Host ("  [{0}] {1} NIEUWS ({2})" -f $ticker, $toon.Label.ToUpper(), (Format-Tijd $it.Tijd)) -ForegroundColor $kleur
            Write-Host ("     {0}" -f $it.Kop)
            if ($koersNu) { Write-Host ("     Koers nu {0} {1}   sinds bericht: {2}" -f $koersNu.ToString('0.00', $Inv), $munt, $bewTekst) }
            if ($k -and $k.Lijst.Count -gt 0 -and ($nu - $k.Lijst[$k.Lijst.Count - 1].T) -gt 1800) {
                Write-Host '     (beurs is nu dicht: de echte reactie komt pas bij opening)' -ForegroundColor DarkGray
                $bewTekst += ' (beurs dicht)'
            }
            if ($teLaat -eq 'ja') { Write-Host '     >>> WAARSCHIJNLIJK AL TE LAAT: koers is al flink in die richting bewogen' -ForegroundColor Yellow }
            Write-Host ("     {0}" -f $it.Link) -ForegroundColor DarkGray

            $meldTitel = "$ticker - $($toon.Label.ToLower()) nieuws"
            if ($teLaat -eq 'ja') { $meldTitel += ' (waarschijnlijk al te laat)' }
            $meldTekst = "$($it.Kop)`nKoers sinds bericht: $bewTekst. Ruwe inschatting, geen advies."
            Show-Melding $meldTitel $meldTekst
            Send-Push (Get-NtfyOnderwerp $inst) $meldTitel $meldTekst $it.Link $toon.Label

            $nieuweSignalen += [pscustomobject]@{
                MeldingTijd     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
                MeldingUnix     = $nu
                NieuwsTijd      = (Format-Tijd $it.Tijd)
                Aandeel         = $ticker
                Toon            = $toon.Label
                Score           = $toon.Score
                Kop             = $it.Kop
                KoersBijNieuws  = $(if ($koersNieuws) { $koersNieuws.ToString('0.00', $Inv) } else { '' })
                KoersBijMelding = $(if ($koersNu) { $koersNu.ToString('0.00', $Inv) } else { '' })
                SindsNieuwsPct  = $(if ($null -ne $beweging) { $beweging.ToString('0.00', $Inv) } else { '' })
                TeLaat          = $teLaat
                KoersNa1Dag     = ''
                ResultaatPct    = ''
                Link            = $it.Link
            }
            Write-Log "$ticker $($toon.Label) | sinds nieuws $bewTekst | te laat: $teLaat | $($it.Kop)"
        }
    }

    if ($nieuweSignalen.Count -gt 0) {
        $alle = @(Read-Signalen) + $nieuweSignalen
        Save-Signalen $alle
    }
    Update-PapierResultaten $inst
    Write-Host ("  {0}  ronde klaar: {1} nieuwe berichten over je aandelen, {2} meldingen" -f (Get-Date -Format 'HH:mm'), $aantalNieuw, $nieuweSignalen.Count) -ForegroundColor DarkCyan
}

# ------------------------------------------------------------------ start
if ($Rapport) { Show-Rapport; return }

if ($TestPush) {
    $o = Get-NtfyOnderwerp (Read-Instellingen)
    if (-not $o) { Write-Host 'Geen NtfyOnderwerp ingevuld in instellingen.txt' -ForegroundColor Yellow; return }
    Send-Push $o 'Nieuwsbot test' 'Werkt! Zo ziet een melding van de nieuwsbot eruit.' '' 'Positief'
    Write-Host "Testmelding verstuurd naar ntfy-onderwerp: $o" -ForegroundColor Green
    return
}

Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ' NIEUWSBOT  -  alleen meldingen, plaatst NOOIT zelf orders' -ForegroundColor Cyan
Write-Host ' Toon = ruwe inschatting op trefwoorden. Geen beleggingsadvies.' -ForegroundColor Cyan
Write-Host ' Stoppen: dit venster sluiten of Ctrl+C' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Log 'Bot gestart'

while ($true) {
    try { Invoke-Ronde }
    catch { Write-Host "  Fout in deze ronde: $($_.Exception.Message) (volgende ronde probeert opnieuw)" -ForegroundColor DarkYellow; Write-Log "Fout: $($_.Exception.Message)" }
    if ($EenKeer) { break }
    $min = (Read-Instellingen).Regels.ControleerElkeMinuten
    Start-Sleep -Seconds ([int]($min * 60))
}
