# SteamImporter - aggiunge app non-Steam (UWP/Xbox/Game Pass e .exe) a Steam con icone
# Uso: doppio click su "Avvia SteamImporter.bat", oppure:
#   powershell -ExecutionPolicy Bypass -File SteamImporter.ps1 [-SelfTest]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- CRC32
$script:Crc32Table = New-Object 'uint32[]' 256
for ($i = 0; $i -lt 256; $i++) {
    $c = [uint32]$i
    for ($k = 0; $k -lt 8; $k++) {
        if ($c -band 1) { $c = 0xEDB88320 -bxor ($c -shr 1) } else { $c = $c -shr 1 }
    }
    $script:Crc32Table[$i] = $c
}
function Get-Crc32([byte[]]$Bytes) {
    $crc = [uint32]::MaxValue
    foreach ($b in $Bytes) {
        $crc = $script:Crc32Table[($crc -bxor $b) -band 0xFF] -bxor ($crc -shr 8)
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}
# AppID che Steam assegna alle shortcut non-Steam (usato per i file artwork in grid\)
function Get-ShortcutAppId([string]$Exe, [string]$AppName) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Exe + $AppName)
    return [uint32]((Get-Crc32 $bytes) -bor 0x80000000)
}

# ---------------------------------------------------------------- VDF binario (shortcuts.vdf)
function Read-VdfCString([System.IO.BinaryReader]$br) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $br.ReadByte()
        if ($b -eq 0) { break }
        $bytes.Add($b)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}
function Read-VdfMap([System.IO.BinaryReader]$br) {
    $map = [ordered]@{}
    while ($true) {
        $type = $br.ReadByte()
        if ($type -eq 8) { return $map }
        $name = Read-VdfCString $br
        switch ($type) {
            0 { $map[$name] = Read-VdfMap $br }
            1 { $map[$name] = Read-VdfCString $br }
            2 { $map[$name] = $br.ReadUInt32() }
            default { throw "Tipo VDF sconosciuto: $type" }
        }
    }
}
function Read-ShortcutsVdf([string]$Path) {
    if (-not (Test-Path $Path)) { return [ordered]@{} }
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 3) { return [ordered]@{} }
        $br = New-Object System.IO.BinaryReader($fs)
        $type = $br.ReadByte()   # 0x00
        $null = Read-VdfCString $br  # "shortcuts"
        if ($type -ne 0) { throw "Formato shortcuts.vdf inatteso" }
        return Read-VdfMap $br
    } finally { $fs.Dispose() }
}
function Write-VdfString([System.IO.BinaryWriter]$bw, [string]$s) {
    $bw.Write([System.Text.Encoding]::UTF8.GetBytes($s))
    $bw.Write([byte]0)
}
function Write-VdfMap([System.IO.BinaryWriter]$bw, $map) {
    foreach ($key in $map.Keys) {
        $val = $map[$key]
        if ($val -is [System.Collections.IDictionary]) {
            $bw.Write([byte]0); Write-VdfString $bw $key; Write-VdfMap $bw $val
        } elseif ($val -is [uint32] -or $val -is [int]) {
            $bw.Write([byte]2); Write-VdfString $bw $key; $bw.Write([uint32]$val)
        } else {
            $bw.Write([byte]1); Write-VdfString $bw $key; Write-VdfString $bw ([string]$val)
        }
    }
    $bw.Write([byte]8)
}
function Write-ShortcutsVdf([string]$Path, $Shortcuts) {
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([byte]0); Write-VdfString $bw 'shortcuts'
    Write-VdfMap $bw $Shortcuts
    $bw.Write([byte]8)   # chiusura mappa radice
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
}
function New-ShortcutEntry([string]$AppName, [string]$Exe, [string]$StartDir, [string]$LaunchOptions, [string]$Icon) {
    $appid = Get-ShortcutAppId $Exe $AppName
    return [ordered]@{
        'appid'               = [uint32]$appid
        'AppName'             = $AppName
        'Exe'                 = $Exe
        'StartDir'            = $StartDir
        'icon'                = $Icon
        'ShortcutPath'        = ''
        'LaunchOptions'       = $LaunchOptions
        'IsHidden'            = [uint32]0
        'AllowDesktopConfig'  = [uint32]1
        'AllowOverlay'        = [uint32]1
        'OpenVR'              = [uint32]0
        'Devkit'              = [uint32]0
        'DevkitGameID'        = ''
        'DevkitOverrideAppID' = [uint32]0
        'LastPlayTime'        = [uint32]0
        'FlatpakAppID'        = ''
        'tags'                = [ordered]@{}
    }
}

# ---------------------------------------------------------------- Steam
function Get-SteamPath {
    $reg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($reg -and $reg.SteamPath) { return ($reg.SteamPath -replace '/', '\') }
    return $null
}
function Get-SteamAccounts([string]$SteamPath) {
    $userdata = Join-Path $SteamPath 'userdata'
    if (-not (Test-Path $userdata)) { return @() }
    # mappa accountid -> nome utente da loginusers.vdf
    $names = @{}
    $lu = Join-Path $SteamPath 'config\loginusers.vdf'
    if (Test-Path $lu) {
        $cur = $null; $login = $null
        foreach ($line in (Get-Content $lu)) {
            if ($line -match '"(\d{17})"') { $cur = ([uint64]$Matches[1] - 76561197960265728).ToString(); $login = $null }
            if ($line -match '"AccountName"\s+"([^"]+)"') { $login = $Matches[1] }
            if ($line -match '"PersonaName"\s+"([^"]+)"' -and $cur) {
                $names[$cur] = if ($login) { "$($Matches[1]) [$login]" } else { $Matches[1] }
            }
        }
    }
    Get-ChildItem $userdata -Directory | Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $n = if ($names[$_.Name]) { $names[$_.Name] } else { '?' }
            [pscustomobject]@{ Id = $_.Name; Name = $n; Path = $_.FullName; LastUsed = $_.LastWriteTime }
        }
}

# ---------------------------------------------------------------- App UWP
function Get-UwpApps {
    $apps = @()
    $packages = @{}
    Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $packages[$_.PackageFamilyName] = $_ }
    foreach ($sa in (Get-StartApps | Where-Object { $_.AppID -match '!' })) {
        $pfn = ($sa.AppID -split '!')[0]
        $pkg = $packages[$pfn]
        $apps += [pscustomobject]@{
            Name       = $sa.Name
            Aumid      = $sa.AppID
            Pfn        = $pfn
            InstallDir = if ($pkg) { $pkg.InstallLocation } else { $null }
        }
    }
    return $apps | Sort-Object Name
}
function Get-UwpIcon($App, [string]$CacheDir) {
    # Estrae il logo migliore dal pacchetto e lo copia nella cache; ritorna il path o $null
    if (-not $App.InstallDir -or -not (Test-Path $App.InstallDir)) { return $null }
    $safe = ($App.Aumid -replace '[^\w\.\-]', '_')
    $cached = Join-Path $CacheDir "$safe.png"
    if (Test-Path $cached) { return $cached }
    try {
        $manifestPath = Join-Path $App.InstallDir 'AppxManifest.xml'
        if (-not (Test-Path $manifestPath)) { return $null }
        [xml]$manifest = Get-Content $manifestPath -Raw
        $appId = ($App.Aumid -split '!')[1]
        $application = $manifest.Package.Applications.Application | Where-Object { $_.Id -eq $appId } | Select-Object -First 1
        if (-not $application) { $application = $manifest.Package.Applications.Application | Select-Object -First 1 }
        $ve = $application.VisualElements
        if (-not $ve) { return $null }
        $logoRel = $ve.Square150x150Logo
        if (-not $logoRel) { $logoRel = $ve.Square44x44Logo }
        if (-not $logoRel) { $logoRel = $ve.Logo }
        if (-not $logoRel) { return $null }
        $logoRel = $logoRel -replace '/', '\'
        $base = Join-Path $App.InstallDir $logoRel
        $dir = Split-Path $base -Parent
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($base)
        $ext = [System.IO.Path]::GetExtension($base)
        # I pacchetti usano qualificatori tipo Logo.scale-200.png: prendo il file piu' grande
        $candidates = @()
        if (Test-Path $base) { $candidates += Get-Item $base }
        if (Test-Path $dir) {
            $candidates += Get-ChildItem $dir -Filter "$leaf.scale-*$ext" -ErrorAction SilentlyContinue
            $candidates += Get-ChildItem $dir -Filter "$leaf.targetsize-*$ext" -ErrorAction SilentlyContinue
        }
        $best = $candidates | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $best) { return $null }
        Copy-Item $best.FullName $cached -Force
        return $cached
    } catch { return $null }
}

# ---------------------------------------------------------------- Scanner launcher esterni
# Ogni scanner ritorna oggetti con: Name, Kind, Detail, Exe (quotato), StartDir (quotato),
# LaunchOptions, Icon (path exe/png per icona), piu' campi vuoti per compatibilita'.
function New-AppItem($Name, $Kind, $Detail, $Exe, $StartDir, $LaunchOptions, $Icon) {
    [pscustomobject]@{
        Name = $Name; Kind = $Kind; Detail = $Detail
        Exe = $Exe; StartDir = $StartDir; LaunchOptions = $LaunchOptions; Icon = $Icon
        Aumid = $null; Pfn = $null; InstallDir = $null; ExePath = $null
    }
}

function Get-BattleNetGames {
    $res = @()
    $bnExe = @('C:\Program Files (x86)\Battle.net\Battle.net.exe', 'C:\Program Files\Battle.net\Battle.net.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    $cfg = "$env:APPDATA\Battle.net\Battle.net.config"
    if (-not $bnExe -or -not (Test-Path $cfg)) { return $res }
    $uidNames = @{
        wow = 'World of Warcraft'; d3 = 'Diablo III'; fenris = 'Diablo IV'; pro = 'Overwatch 2'
        s2 = 'StarCraft II'; s1 = 'StarCraft Remastered'; hs_beta = 'Hearthstone'; heroes = 'Heroes of the Storm'
        w3 = 'Warcraft III Reforged'; rtro = 'Blizzard Arcade Collection'; anbs = 'Diablo Immortal'
        gryphon = 'Warcraft Rumble'; auks = 'Call of Duty'; lazr = 'Call of Duty: Modern Warfare II'
        odin = 'Call of Duty: Modern Warfare'; zeus = 'Call of Duty: Black Ops Cold War'
        wlby = 'Crash Bandicoot 4'; osi = 'Diablo II: Resurrected'
    }
    try { $games = (Get-Content $cfg -Raw | ConvertFrom-Json).Games } catch { return $res }
    $unins = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue
    foreach ($prop in $games.PSObject.Properties) {
        $uid = $prop.Name
        if ($uid -eq 'battle_net') { continue }
        $name = if ($uidNames[$uid]) { $uidNames[$uid] } else { $uid.ToUpper() }
        $installDir = $null; $iconExe = $null
        $u = $unins | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1
        if ($u) {
            $installDir = $u.InstallLocation
            if ($u.DisplayIcon) { $iconExe = ($u.DisplayIcon -split ',')[0].Trim('"') }
        }
        # I giochi Battle.net moderni RIFIUTANO l'avvio diretto: il gioco pretende
        # il token di sessione che solo il client passa quando premi "Gioca".
        # Provati e falliti: bootstrapper (errore BLZBNTBGS7FFFFF01 "Avvia sempre
        # il gioco utilizzando l'app Battle.net"), --exec="launch <uid>",
        # battlenet://<uid> e --game=<uid> (non avviano proprio nulla).
        # L'unica strada che funziona e' aprire il client e premere Gioca.
        $exe = '"' + $bnExe + '"'
        $sd = '"' + (Split-Path $bnExe -Parent) + '"'
        $lo = ''
        $how = T 'apre Battle.net, poi premi Gioca'
        $icon = if ($iconExe -and (Test-Path $iconExe)) { $iconExe } else { '' }
        $res += New-AppItem $name 'Battle.net' "uid=$uid - $how" $exe $sd $lo $icon
    }
    return $res
}

function Get-EpicGames {
    $res = @()
    $mdir = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path $mdir)) { return $res }
    foreach ($f in Get-ChildItem $mdir -Filter '*.item' -ErrorAction SilentlyContinue) {
        try { $m = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $m.DisplayName -or -not $m.InstallLocation -or -not (Test-Path $m.InstallLocation)) { continue }
        if ($m.bIsIncompleteInstall) { continue }
        $gameExe = $null
        if ($m.LaunchExecutable) {
            $p = Join-Path $m.InstallLocation $m.LaunchExecutable
            if (Test-Path $p) { $gameExe = $p }
        }
        $uri = "com.epicgames.launcher://apps/$($m.AppName)?action=launch&silent=true"
        $res += New-AppItem $m.DisplayName 'Epic' $m.InstallLocation '"C:\WINDOWS\explorer.exe"' '"C:\WINDOWS"' $uri $(if ($gameExe) { $gameExe } else { '' })
    }
    return $res
}

function Get-GogGames {
    $res = @()
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games') {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
            $g = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if (-not $g.gameName -or -not $g.exe -or -not (Test-Path $g.exe)) { continue }
            $wd = if ($g.workingDir -and (Test-Path $g.workingDir)) { $g.workingDir }
                  elseif ($g.path -and (Test-Path $g.path)) { $g.path }
                  else { Split-Path $g.exe -Parent }
            $res += New-AppItem $g.gameName 'GOG' $g.exe ('"' + $g.exe + '"') ('"' + $wd + '"') '' $g.exe
        }
    }
    return $res
}

function Get-UbisoftGames {
    $res = @()
    $root = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs'
    if (-not (Test-Path $root)) { return $res }
    $unins = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Uplay Install *' -ErrorAction SilentlyContinue
    foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        $id = $k.PSChildName
        $g = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $g.InstallDir -or -not (Test-Path $g.InstallDir)) { continue }
        $u = $unins | Where-Object { $_.PSChildName -eq "Uplay Install $id" } | Select-Object -First 1
        $name = if ($u -and $u.DisplayName) { $u.DisplayName } else { Split-Path $g.InstallDir.TrimEnd('/\') -Leaf }
        $iconExe = if ($u -and $u.DisplayIcon) { ($u.DisplayIcon -split ',')[0].Trim('"') } else { $null }
        $icon = if ($iconExe -and (Test-Path $iconExe)) { $iconExe } else { '' }
        $res += New-AppItem $name 'Ubisoft' "id=$id" '"C:\WINDOWS\explorer.exe"' '"C:\WINDOWS"' "uplay://launch/$id/0" $icon
    }
    return $res
}

function Get-StartMenuPrograms {
    # Programmi win32 dal menu Start (.lnk) - per giochi/app installati fuori dai launcher
    $res = @()
    $sh = New-Object -ComObject WScript.Shell
    $seen = @{}
    # parole intere, per non scartare app legittime tipo "Updater Pro" o "HelpDesk"
    $junk = '(^|[\W_])(uninstall|uninstaller|unins\d*|setup|repair|readme|manual|help|guida|documentation|website|sito|update|updates)([\W_]|$)'
    foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") {
        if (-not (Test-Path $dir)) { continue }
        foreach ($lnk in Get-ChildItem $dir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue) {
            if ($lnk.BaseName -match $junk) { continue }
            try { $s = $sh.CreateShortcut($lnk.FullName) } catch { continue }
            $target = $s.TargetPath
            if (-not $target -or $target -notlike '*.exe' -or -not (Test-Path $target)) { continue }
            if ($target -like "$env:WINDIR*") { continue }
            if ((Split-Path $target -Leaf) -match $junk) { continue }
            $key = $target.ToLower()
            if ($seen[$key]) { continue }
            $seen[$key] = $true
            $wd = if ($s.WorkingDirectory -and (Test-Path $s.WorkingDirectory)) { $s.WorkingDirectory } else { Split-Path $target -Parent }
            $lo = if ($s.Arguments) { $s.Arguments } else { '' }
            $res += New-AppItem $lnk.BaseName 'App' $target ('"' + $target + '"') ('"' + $wd + '"') $lo $target
        }
    }
    return $res
}

# ---------------------------------------------------------------- Lingua
# Le frasi italiane fanno da chiave: T restituisce la traduzione quando la
# lingua e' l'inglese, altrimenti la frase stessa.
$script:Lang = 'it'
$script:TradEN = @{
    # --- finestra principale ---
    'SteamImporter - aggiungi app non-Steam a Steam' = 'SteamImporter - add non-Steam apps to Steam'
    'Account Steam:'                                 = 'Steam account:'
    'cerca...'                                       = 'search...'
    'Mostra anche app di sistema'                    = 'Show system apps too'
    'Nome (doppio click per rinominare)'             = 'Name (double-click to rename)'
    'Tipo'                                           = 'Type'
    'In Steam'                                       = 'In Steam'
    'Dettaglio'                                      = 'Details'
    'Aggiungi .exe...'                               = 'Add .exe...'
    'Ricarica'                                       = 'Refresh'
    'Artwork / Copertine...'                         = 'Artwork / Covers...'
    'Annulla modifiche'                              = 'Undo changes'
    'Rimuovi...'                                     = 'Remove...'
    'Riavvia Steam'                                  = 'Restart Steam'
    'API key SteamGridDB (clicca qui per ottenerla gratis):' = 'SteamGridDB API key (click here to get one free):'
    'Salva'                                          = 'Save'
    'Aggiungi a Steam'                               = 'Add to Steam'
    'Pronto.'                                        = 'Ready.'
    'English'                                        = 'Italiano'
    # --- messaggi di stato ---
    'Scansione app installate (UWP, Battle.net, Epic, GOG, Ubisoft, menu Start)...' = 'Scanning installed apps (UWP, Battle.net, Epic, GOG, Ubisoft, Start menu)...'
    '{0} app in elenco - {1} gia'' in Steam (in viola).' = '{0} apps listed - {1} already in Steam (in purple).'
    '  Scansione fallita per: {0}'                   = '  Scan failed for: {0}'
    'Estrazione icone...'                            = 'Extracting icons...'
    'Scrittura shortcuts.vdf'                        = 'Writing shortcuts.vdf'
    ' e download artwork...'                         = ' and downloading artwork...'
    'Errore: {0}'                                    = 'Error: {0}'
    'Chiusura di Steam in corso...'                  = 'Closing Steam...'
    'Steam riavviato: le modifiche alla libreria sono ora visibili.' = 'Steam restarted: your library changes are now visible.'
    'Steam non si e'' chiuso del tutto: controlla e riprova.' = 'Steam did not close completely: check and try again.'
    'Ripristinato lo stato del {0} - passi indietro rimasti: {1}' = 'Restored the state from {0} - steps back left: {1}'
    'Aggiunte: {0}  -  Gia'' presenti (saltate): {1}' = 'Added: {0}  -  Already there (skipped): {1}'
    '  -  Artwork scaricati: {0}'                    = '  -  Artwork downloaded: {0}'
    'Cambio lingua...'                               = 'Switching language...'
    # --- riquadri di messaggio ---
    'Steam non trovato su questo PC.'                = 'Steam was not found on this PC.'
    'Seleziona almeno una app (spunta la casella).'  = 'Select at least one app (tick its checkbox).'
    'Nessun account Steam trovato in userdata.'      = 'No Steam account found in userdata.'
    'Nessun backup trovato per questo account.'      = 'No backup found for this account.'
    'Fatto. Riavvia Steam per vedere la libreria come prima.' = 'Done. Restart Steam to see the library as it was.'
    'Torno indietro di un passo, allo stato del {0}?{1}{1}Passi indietro ancora disponibili dopo questo: {2}' = 'Go back one step, to the state from {0}?{1}{1}Steps back still available after this one: {2}'
    '{0}{1}{1}E'' stato creato un backup di shortcuts.vdf.{1}Riavvia Steam per vedere le nuove app nella libreria.' = '{0}{1}{1}A backup of shortcuts.vdf was created.{1}Restart Steam to see the new apps in your library.'
    'Errore durante l''export:{0}{1}'                = 'Error during export:{0}{1}'
    'Risulta un gioco avviato da Steam ancora in esecuzione: riavviando Steam adesso rischi di perdere i progressi non salvati.{0}{0}Riavvio lo stesso?' = 'A game started from Steam seems to be still running: restarting Steam now risks losing unsaved progress.{0}{0}Restart anyway?'
    'Steam e'' aperto e va chiuso per modificare la libreria, altrimenti sovrascrive le modifiche quando esce.{0}{1}{1}Chiudo Steam adesso?' = 'Steam is open and must be closed to change the library, otherwise it overwrites the changes when it exits.{0}{1}{1}Close Steam now?'
    '{0}{0}ATTENZIONE: risulta un gioco avviato da Steam ancora in esecuzione. Chiudendo Steam adesso rischi di perdere i progressi non salvati.' = '{0}{0}WARNING: a game started from Steam seems to be still running. Closing Steam now risks losing unsaved progress.'
    'Non sono riuscito a chiudere Steam. Chiudilo a mano e riprova.' = 'I could not close Steam. Close it by hand and try again.'
    'Scegli il programma da aggiungere a Steam'      = 'Choose the program to add to Steam'
    'Programmi (*.exe)|*.exe'                        = 'Programs (*.exe)|*.exe'
    # --- Artwork Manager ---
    'Artwork Manager - scegli le immagini da SteamGridDB' = 'Artwork Manager - pick images from SteamGridDB'
    'Artwork Manager'                                = 'Artwork Manager'
    'Shortcut:'                                      = 'Shortcut:'
    'Gioco su SteamGridDB:'                          = 'Game on SteamGridDB:'
    'Cerca'                                          = 'Search'
    'cerca un altro nome...'                         = 'search another name...'
    'Applica selezionate'                            = 'Apply selected'
    '<  Indietro'                                    = '<  Back'
    'Scegli una shortcut a sinistra.'                = 'Pick a shortcut on the left.'
    'Copertina'                                      = 'Cover'
    'Banner'                                         = 'Banner'
    'Hero'                                           = 'Hero'
    'Logo'                                           = 'Logo'
    'Icona'                                          = 'Icon'
    'Carico anteprime ''{0}''...'                    = 'Loading ''{0}'' previews...'
    'Selezionata immagine per ''{0}''.'              = 'Image selected for ''{0}''.'
    'Cerco ''{0}'' su SteamGridDB...'                = 'Searching ''{0}'' on SteamGridDB...'
    'Nessun risultato per ''{0}''. Prova a scrivere un altro nome qui a destra e premi Cerca.' = 'No results for ''{0}''. Try another name on the right and press Search.'
    '{0} anteprime caricate. Clicca per selezionare, poi ''Applica''.' = '{0} previews loaded. Click to select, then ''Apply''.'
    'Nessuna immagine trovata per ''{0}''.'          = 'No image found for ''{0}''.'
    'Scarico le immagini scelte...'                  = 'Downloading the chosen images...'
    'Errore download {0}: {1}'                       = 'Download error {0}: {1}'
    'Applicate {0} immagini. Riavvia Steam per vederle.' = 'Applied {0} images. Restart Steam to see them.'
    'Applicate {0} immagini per ''{1}''.{2}Riavvia Steam per vederle in libreria.' = 'Applied {0} images to ''{1}''.{2}Restart Steam to see them in your library.'
    'Per scegliere gli artwork serve una API key di SteamGridDB (gratuita).{0}Creala su steamgriddb.com -> Profilo -> Preferences -> API e incollala nel campo in basso nella finestra principale.' = 'Picking artwork needs a SteamGridDB API key (free).{0}Create one at steamgriddb.com -> Profile -> Preferences -> API and paste it into the field at the bottom of the main window.'
    'Nessuna shortcut non-Steam trovata per questo account. Aggiungi prima le app.' = 'No non-Steam shortcut found for this account. Add some apps first.'
    'Seleziona prima almeno una immagine nelle schede.' = 'Select at least one image in the tabs first.'
    # --- finestra Rimuovi ---
    'Rimuovi app aggiunte a Steam'                   = 'Remove apps added to Steam'
    'Rimuovi App'                                    = 'Remove Apps'
    'Spunta le app da togliere dalla libreria Steam (account {0}):' = 'Tick the apps to remove from your Steam library (account {0}):'
    'Nome'                                           = 'Name'
    'Comando'                                        = 'Command'
    'Rimuovi selezionate'                            = 'Remove selected'
    'Nessuna shortcut non-Steam su questo account.'  = 'No non-Steam shortcut on this account.'
    'Spunta almeno una app da rimuovere.'            = 'Tick at least one app to remove.'
    'Tolgo dalla libreria Steam queste app?{0}{0}{1}{0}{0}Verranno rimossi anche i loro artwork. Viene creato un backup, puoi annullare con ''Annulla modifiche''.' = 'Remove these apps from your Steam library?{0}{0}{1}{0}{0}Their artwork will be removed too. A backup is created, you can undo with ''Undo changes''.'
    'Rimosse {0} app. Riavvia Steam per aggiornare la libreria.' = 'Removed {0} apps. Restart Steam to refresh your library.'
    # --- scanner ---
    'apre Battle.net, poi premi Gioca'               = 'opens Battle.net, then press Play'
}
function T([string]$Testo) {
    if ($script:Lang -eq 'en' -and $script:TradEN.ContainsKey($Testo)) { return $script:TradEN[$Testo] }
    return $Testo
}

# ---------------------------------------------------------------- Config persistente
$script:ConfigPath = Join-Path $env:APPDATA 'SteamImporter\config.json'
function Get-SIConfig {
    $cfg = $null
    if (Test-Path $script:ConfigPath) {
        try { $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json } catch {}
    }
    if (-not $cfg) { $cfg = [pscustomobject]@{} }
    # garantisco che le chiavi ci siano sempre, anche con file vecchi
    foreach ($k in @('SgdbApiKey', 'Lang')) {
        if (-not $cfg.PSObject.Properties[$k]) {
            $val = if ($k -eq 'Lang') { 'it' } else { '' }
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $val
        }
    }
    return $cfg
}
function Save-SIConfig($Config) {
    New-Item -ItemType Directory -Force (Split-Path $script:ConfigPath -Parent) | Out-Null
    $Config | ConvertTo-Json | Out-File $script:ConfigPath -Encoding utf8
}

# ---------------------------------------------------------------- SteamGridDB (opzionale)
function Save-SgdbFile([hashtable]$Headers, [string]$Uri, [string]$DestNoExt) {
    try {
        $r = Invoke-RestMethod -Uri $Uri -Headers $Headers -TimeoutSec 20
        if ($r.success -and $r.data.Count -gt 0) {
            $url = $r.data[0].url
            $ext = [System.IO.Path]::GetExtension(([uri]$url).AbsolutePath)
            if ($ext -notin '.png', '.jpg', '.jpeg', '.webp') { $ext = '.png' }
            Invoke-WebRequest -Uri $url -OutFile "$DestNoExt$ext" -TimeoutSec 30 | Out-Null
            return $true
        }
    } catch {}
    return $false
}
function Get-SgdbArtwork([string]$ApiKey, [string]$Name, [uint32]$AppId, [string]$GridDir) {
    $headers = @{ Authorization = "Bearer $ApiKey" }
    $found = 0
    try {
        $q = [uri]::EscapeDataString($Name)
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$q" -Headers $headers -TimeoutSec 20
        if (-not $r.success -or $r.data.Count -eq 0) { return 0 }
        $gid = $r.data[0].id
        if (Save-SgdbFile $headers "https://www.steamgriddb.com/api/v2/grids/game/$gid?dimensions=600x900" (Join-Path $GridDir ("{0}p" -f $AppId))) { $found++ }
        if (Save-SgdbFile $headers "https://www.steamgriddb.com/api/v2/grids/game/$gid?dimensions=460x215,920x430" (Join-Path $GridDir ("{0}" -f $AppId))) { $found++ }
        if (Save-SgdbFile $headers "https://www.steamgriddb.com/api/v2/heroes/game/$gid" (Join-Path $GridDir ("{0}_hero" -f $AppId))) { $found++ }
        if (Save-SgdbFile $headers "https://www.steamgriddb.com/api/v2/logos/game/$gid" (Join-Path $GridDir ("{0}_logo" -f $AppId))) { $found++ }
    } catch {}
    return $found
}

function Get-SgdbSearchResults([string]$ApiKey, [string]$Name) {
    $headers = @{ Authorization = "Bearer $ApiKey" }
    try {
        $q = [uri]::EscapeDataString($Name)
        $r = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$q" -Headers $headers -TimeoutSec 20
        if ($r.success) { return @($r.data | Select-Object -First 10) }
    } catch {}
    return @()
}
function Get-SgdbImageList([string]$ApiKey, [string]$Endpoint, [int]$GameId, [string]$Query) {
    # Endpoint: grids | heroes | logos | icons. Ritorna gli oggetti immagine (url, thumb, ...)
    $headers = @{ Authorization = "Bearer $ApiKey" }
    try {
        $uri = "https://www.steamgriddb.com/api/v2/$Endpoint/game/$GameId"
        if ($Query) { $uri += "?$Query" }
        $r = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 20
        if ($r.success) { return @($r.data | Select-Object -First 12) }
    } catch {}
    return @()
}
function Get-UrlExtension([string]$Url) {
    $ext = [System.IO.Path]::GetExtension(([uri]$Url).AbsolutePath)
    if ($ext -notin '.png', '.jpg', '.jpeg', '.webp', '.ico') { $ext = '.png' }
    return $ext
}

# ---------------------------------------------------------------- Backup e controllo di Steam
$script:MaxBackups = 10
function Backup-Vdf([string]$VdfPath) {
    # Copia di sicurezza prima di ogni scrittura, tenendo solo gli ultimi $MaxBackups file
    if (-not (Test-Path $VdfPath)) { return $null }
    $bak = "$VdfPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss-fff)"
    Copy-Item $VdfPath $bak -Force
    $dir = Split-Path $VdfPath -Parent
    $leaf = Split-Path $VdfPath -Leaf
    $old = @(Get-ChildItem $dir -Filter "$leaf.bak-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip $script:MaxBackups)
    foreach ($o in $old) { Remove-Item $o.FullName -Force -ErrorAction SilentlyContinue }
    return $bak
}
function Test-SteamGameRunning {
    # RunningAppID e' diverso da 0 mentre un gioco lanciato da Steam e' in esecuzione
    $k = Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    return ($k -and $k.RunningAppID -and $k.RunningAppID -ne 0)
}
function Stop-SteamGracefully([string]$SteamPath, [int]$TimeoutSec = 20) {
    # Chiede a Steam di chiudersi come farebbe l'utente e ASPETTA che esca davvero,
    # invece di ucciderlo e sperare che abbia finito di scrivere i suoi file.
    if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { return $true }
    $exe = Join-Path $SteamPath 'steam.exe'
    if (Test-Path $exe) {
        try { Start-Process $exe -ArgumentList '-shutdown' -ErrorAction Stop | Out-Null } catch {}
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (-not (Get-Process steam -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 800   # lascia finire la scrittura dei file di configurazione
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    # non si e' chiuso da solo: chiusura forzata come ultima spiaggia
    Stop-Process -Name steam -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    return (-not (Get-Process steam -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------- Rilevamento app gia' aggiunte
function Get-AppSignature($App) {
    # firma exe|launch identica a quella usata in export, per capire se un'app e' gia' in Steam
    if ($App.Kind -eq 'UWP') {
        $exe = '"C:\WINDOWS\explorer.exe"'; $launch = "shell:AppsFolder\$($App.Aumid)"
    } elseif ($App.Exe) {
        $exe = $App.Exe; $launch = $App.LaunchOptions
    } elseif ($App.ExePath) {
        $exe = '"' + $App.ExePath + '"'; $launch = ''
    } else { return $null }
    return "$exe|$launch".ToLower()
}
function Get-ExistingShortcutMap([string]$SteamPath, [string]$AccountId) {
    # mappa firma -> { Key; Name } delle shortcut non-Steam gia' presenti
    $map = @{}
    $vdf = Join-Path $SteamPath "userdata\$AccountId\config\shortcuts.vdf"
    $sc = Read-ShortcutsVdf $vdf
    foreach ($k in $sc.Keys) {
        $e = $sc[$k]
        $map[("$($e['Exe'])|$($e['LaunchOptions'])").ToLower()] = @{ Key = $k; Name = [string]$e['AppName'] }
    }
    return $map
}

# ---------------------------------------------------------------- Export
function Export-ToSteam {
    param(
        [string]$SteamPath, [string]$AccountId,
        [object[]]$Items,          # oggetti con: Name, Kind ('UWP'|'EXE'), Aumid/ExePath, Icon
        [string]$SgdbApiKey
    )
    $configDir = Join-Path $SteamPath "userdata\$AccountId\config"
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Force $configDir | Out-Null }
    $vdfPath = Join-Path $configDir 'shortcuts.vdf'
    $gridDir = Join-Path $configDir 'grid'
    if (-not (Test-Path $gridDir)) { New-Item -ItemType Directory -Force $gridDir | Out-Null }

    $shortcuts = Read-ShortcutsVdf $vdfPath
    [void](Backup-Vdf $vdfPath)

    # Indice anti-duplicati basato sul comando di lancio (exe+opzioni), la stessa
    # firma usata da Get-AppSignature: se la lista mostra "gia' in Steam" allora
    # l'app viene saltata, anche quando in libreria ha un nome diverso.
    $existing = @{}
    foreach ($k in $shortcuts.Keys) {
        $e = $shortcuts[$k]
        $existing[("$($e['Exe'])|$($e['LaunchOptions'])").ToLower()] = $true
    }

    $added = 0; $skipped = 0; $artCount = 0
    $nextIndex = ($shortcuts.Keys | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
    if ($null -eq $nextIndex) { $nextIndex = -1 }

    foreach ($item in $Items) {
        if ($item.Kind -eq 'UWP') {
            $exe = '"C:\WINDOWS\explorer.exe"'
            $startDir = '"C:\WINDOWS"'
            $launch = "shell:AppsFolder\$($item.Aumid)"
        } elseif ($item.Exe) {
            # scanner launcher: comando gia' pronto
            $exe = $item.Exe
            $startDir = $item.StartDir
            $launch = $item.LaunchOptions
        } else {
            $exe = '"' + $item.ExePath + '"'
            $startDir = '"' + (Split-Path $item.ExePath -Parent) + '"'
            $launch = ''
        }
        $key = "$exe|$launch".ToLower()
        if ($existing[$key]) { $skipped++; continue }

        $icon = if ($item.Icon) { $item.Icon } else { '' }
        $entry = New-ShortcutEntry -AppName $item.Name -Exe $exe -StartDir $startDir -LaunchOptions $launch -Icon $icon
        $nextIndex++
        $shortcuts["$nextIndex"] = $entry
        $existing[$key] = $true
        $added++

        # per le UWP uso il logo del pacchetto anche come copertina se non c'e' artwork
        $appid = $entry['appid']
        if ($SgdbApiKey) {
            $artCount += Get-SgdbArtwork -ApiKey $SgdbApiKey -Name $item.Name -AppId $appid -GridDir $gridDir
        }
        if ($item.Icon -and ([System.IO.Path]::GetExtension($item.Icon) -in '.png', '.jpg', '.jpeg') -and
            -not (Test-Path (Join-Path $gridDir "$($appid)p.png"))) {
            Copy-Item $item.Icon (Join-Path $gridDir "$($appid)p.png") -Force -ErrorAction SilentlyContinue
        }
    }

    Write-ShortcutsVdf $vdfPath $shortcuts
    return [pscustomobject]@{ Added = $added; Skipped = $skipped; Artwork = $artCount; VdfPath = $vdfPath }
}

function Remove-ShortcutEntries([string]$VdfPath, [string]$GridDir, [string[]]$Keys, [string]$IconDir) {
    # Rimuove le entry con le chiavi indicate, rinumera, fa backup e pulisce gli artwork
    $shortcuts = Read-ShortcutsVdf $VdfPath
    [void](Backup-Vdf $VdfPath)
    $keep = [ordered]@{}
    $removed = 0
    $i = 0
    foreach ($k in $shortcuts.Keys) {
        if ($Keys -contains $k) {
            $removed++
            $e = $shortcuts[$k]
            $appid = if ($e.Contains('appid')) { [uint32]$e['appid'] } else { Get-ShortcutAppId $e['Exe'] $e['AppName'] }
            if ($GridDir -and (Test-Path $GridDir)) {
                foreach ($base in "$appid", "$($appid)p", "$($appid)_hero", "$($appid)_logo") {
                    Get-ChildItem $GridDir -Filter "$base.*" -ErrorAction SilentlyContinue |
                        Where-Object { $_.BaseName -eq $base } | Remove-Item -Force -ErrorAction SilentlyContinue
                }
            }
            # l'icona scelta con l'Artwork Manager sta nella cache, non in grid\
            if ($IconDir -and (Test-Path $IconDir)) {
                Get-ChildItem $IconDir -Filter "$($appid)_icon.*" -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
            continue
        }
        $keep["$i"] = $shortcuts[$k]; $i++
    }
    Write-ShortcutsVdf $VdfPath $keep
    return $removed
}

# ---------------------------------------------------------------- Tema scuro
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Palette stile Cherax: nero, viola, bianco
$script:Th = @{
    Bg          = [System.Drawing.Color]::FromArgb(15, 15, 17)
    Panel       = [System.Drawing.Color]::FromArgb(28, 28, 32)
    Input       = [System.Drawing.Color]::FromArgb(38, 38, 44)
    Text        = [System.Drawing.Color]::FromArgb(242, 242, 246)
    Sub         = [System.Drawing.Color]::FromArgb(155, 155, 165)
    Accent      = [System.Drawing.Color]::FromArgb(124, 58, 237)
    AccentHover = [System.Drawing.Color]::FromArgb(148, 92, 246)
    BtnBg       = [System.Drawing.Color]::FromArgb(44, 44, 52)
    BtnHover    = [System.Drawing.Color]::FromArgb(62, 58, 80)
    Header      = [System.Drawing.Color]::FromArgb(9, 9, 11)
}
function New-RoundPath([System.Drawing.Rectangle]$R, [int]$Rad) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Rad * 2
    $p.AddArc($R.X, $R.Y, $d, $d, 180, 90)
    $p.AddArc($R.Right - $d, $R.Y, $d, $d, 270, 90)
    $p.AddArc($R.Right - $d, $R.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($R.X, $R.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class SIDwm {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string sub, string id);
    public static void Dark(IntPtr h) {
        int on = 1;
        if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) { DwmSetWindowAttribute(h, 19, ref on, 4); }
    }
}
'@
function Set-DarkTitleBar([System.Windows.Forms.Form]$Form) {
    # barra del titolo scura come il resto della finestra (Windows 10/11)
    try { [SIDwm]::Dark($Form.Handle) } catch {}
}
function Update-LastColumn([System.Windows.Forms.ListView]$Lv) {
    # l'ultima colonna occupa lo spazio che avanza, cosi' non resta
    # una fascia vuota chiara in fondo all'intestazione
    if ($Lv.Columns.Count -eq 0) { return }
    $used = 0
    for ($i = 0; $i -lt $Lv.Columns.Count - 1; $i++) { $used += $Lv.Columns[$i].Width }
    # ClientSize esclude gia' la barra di scorrimento quando c'e'
    $w = $Lv.ClientSize.Width - $used - 4
    $last = $Lv.Columns[$Lv.Columns.Count - 1]
    if ($w -gt 60 -and $last.Width -ne $w) { $last.Width = $w }
}
function Hide-ComboArrow([System.Windows.Forms.ComboBox]$Cmb) {
    # Windows disegna il pulsante della tendina sempre chiaro: ci metto sopra
    # una freccia in tinta, che passa il clic alla tendina stessa.
    $w = [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
    $mask = New-Object System.Windows.Forms.Label
    $mask.Size = New-Object System.Drawing.Size($w, ($Cmb.Height - 2))
    $mask.Location = New-Object System.Drawing.Point(($Cmb.Left + $Cmb.Width - $w - 1), ($Cmb.Top + 1))
    $mask.BackColor = $script:Th.Input
    $mask.ForeColor = $script:Th.Sub
    $mask.Text = [string][char]0x25BC
    $mask.TextAlign = 'MiddleCenter'
    $mask.Font = New-Object System.Drawing.Font('Segoe UI', 7)
    $mask.Cursor = [System.Windows.Forms.Cursors]::Hand
    $mask.Anchor = $Cmb.Anchor
    $mask.Add_Click({ $Cmb.DroppedDown = $true }.GetNewClosure())
    $Cmb.Parent.Controls.Add($mask)
    $mask.BringToFront()
}
function Set-DarkListHeader([System.Windows.Forms.ListView]$Lv) {
    # l'intestazione delle colonne non segue i colori del controllo: la disegno io
    $Lv.OwnerDraw = $true
    $Lv.Add_DrawColumnHeader({
        param($s, $e)
        $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(22, 22, 26))
        $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(46, 46, 56))
        $e.Graphics.DrawLine($pen, $e.Bounds.Left, ($e.Bounds.Bottom - 1), $e.Bounds.Right, ($e.Bounds.Bottom - 1))
        $e.Graphics.DrawLine($pen, ($e.Bounds.Right - 1), ($e.Bounds.Top + 5), ($e.Bounds.Right - 1), ($e.Bounds.Bottom - 6))
        $pen.Dispose()
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 8), $e.Bounds.Y, ($e.Bounds.Width - 10), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $r,
            $script:Th.Sub, ([System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                             [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
    })
    # righe e celle restano quelle standard (con i colori gia' impostati)
    $Lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $Lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
}
function New-CheckImage([bool]$Checked) {
    # casella di spunta disegnata a mano, al posto di quella bianca di sistema
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $rect = New-Object System.Drawing.Rectangle(2, 2, 12, 12)
    $path = New-RoundPath $rect 3
    $fill = if ($Checked) { $script:Th.Accent } else { $script:Th.Input }
    $brd = if ($Checked) { $script:Th.AccentHover } else { [System.Drawing.Color]::FromArgb(92, 92, 108) }
    $br = New-Object System.Drawing.SolidBrush($fill); $g.FillPath($br, $path); $br.Dispose()
    $pen = New-Object System.Drawing.Pen($brd, 1); $g.DrawPath($pen, $path); $pen.Dispose()
    $path.Dispose()
    if ($Checked) {
        $wp = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2)
        $g.DrawLines($wp, @(
            (New-Object System.Drawing.Point(5, 8)),
            (New-Object System.Drawing.Point(7, 11)),
            (New-Object System.Drawing.Point(11, 5))))
        $wp.Dispose()
    }
    $g.Dispose()
    return $bmp
}
function Set-RoundButton([System.Windows.Forms.Button]$B) {
    # bottone disegnato a mano: angoli arrotondati, contorno, hover morbido
    $B.FlatStyle = 'Flat'
    $B.FlatAppearance.BorderSize = 0
    $B.FlatAppearance.MouseOverBackColor = $script:Th.Bg
    $B.FlatAppearance.MouseDownBackColor = $script:Th.Bg
    $B.BackColor = $script:Th.Bg
    $B.Cursor = [System.Windows.Forms.Cursors]::Hand
    $B.Tag = @{
        RFill = $script:Th.BtnBg; RHover = $script:Th.BtnHover
        RBorder = [System.Drawing.Color]::FromArgb(88, 88, 106)
        RText = $script:Th.Text; Hover = $false; Radius = 9; RImage = $null
    }
    $B.Add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
    $B.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    $B.Add_Paint({
        param($s, $e)
        $b = $s; $t = $b.Tag; $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($b.Parent.BackColor)
        $rect = New-Object System.Drawing.Rectangle(0, 0, ($b.Width - 1), ($b.Height - 1))
        $path = New-RoundPath $rect $t.Radius
        $fill = if ($t.Hover) { $t.RHover } else { $t.RFill }
        $br = New-Object System.Drawing.SolidBrush($fill)
        $g.FillPath($br, $path); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($t.RBorder, 1)
        $g.DrawPath($pen, $path); $pen.Dispose()
        $path.Dispose()
        $txtRect = $rect
        if ($t.RImage) {
            $ih = $t.RImage.Height
            $g.DrawImage($t.RImage, 9, [int](($b.Height - $ih) / 2), $t.RImage.Width, $ih)
            $off = 9 + $t.RImage.Width
            $txtRect = New-Object System.Drawing.Rectangle($off, 0, ($b.Width - $off - 1), ($b.Height - 1))
        }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $b.Text, $b.Font, $txtRect, $t.RText,
            ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
    })
}
function Apply-Theme([System.Windows.Forms.Control]$Root) {
    $Root.BackColor = $script:Th.Bg
    $Root.ForeColor = $script:Th.Text
    $Root.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $stack = New-Object System.Collections.Stack
    foreach ($c in $Root.Controls) { $stack.Push($c) }
    while ($stack.Count -gt 0) {
        $c = $stack.Pop()
        foreach ($ch in $c.Controls) { $stack.Push($ch) }
        switch ($c.GetType().Name) {
            'Button' { Set-RoundButton $c }
            'TextBox'  { $c.BackColor = $script:Th.Input; $c.ForeColor = $script:Th.Text; $c.BorderStyle = 'FixedSingle' }
            'ComboBox' { $c.BackColor = $script:Th.Input; $c.ForeColor = $script:Th.Text; $c.FlatStyle = 'Flat' }
            'ListView' { $c.BackColor = $script:Th.Panel; $c.ForeColor = $script:Th.Text; $c.BorderStyle = 'FixedSingle' }
            'ListBox'  { $c.BackColor = $script:Th.Panel; $c.ForeColor = $script:Th.Text; $c.BorderStyle = 'FixedSingle' }
            'LinkLabel' { $c.LinkColor = $script:Th.AccentHover; $c.ActiveLinkColor = $script:Th.Text; $c.BackColor = $script:Th.Bg }
            'Label'    { $c.BackColor = $script:Th.Bg }
            'CheckBox' { $c.BackColor = $script:Th.Bg }
            'FlowLayoutPanel' { $c.BackColor = $script:Th.Panel }
            'TabPage'  { $c.BackColor = $script:Th.Panel }
        }
    }
}
function Style-PrimaryButton([System.Windows.Forms.Button]$Btn) {
    # da chiamare dopo Apply-Theme: colora di viola il bottone arrotondato
    if ($Btn.Tag -is [hashtable]) {
        $Btn.Tag.RFill = $script:Th.Accent
        $Btn.Tag.RHover = $script:Th.AccentHover
        $Btn.Tag.RBorder = $script:Th.AccentHover
        $Btn.Tag.RText = [System.Drawing.Color]::White
        $Btn.Invalidate()
    }
}
function Add-CheraxHeader([System.Windows.Forms.Form]$Form, [string]$Title) {
    # barra del titolo in alto stile Cherax: nero, titolo bianco centrato, riga viola
    $h = 44
    if ($Form.MinimumSize.Height -gt 0) {
        $Form.MinimumSize = New-Object System.Drawing.Size($Form.MinimumSize.Width, ($Form.MinimumSize.Height + $h))
    }
    $Form.Height += $h
    foreach ($c in @($Form.Controls)) {
        $hasTop = [bool]($c.Anchor -band [System.Windows.Forms.AnchorStyles]::Top)
        $hasBottom = [bool]($c.Anchor -band [System.Windows.Forms.AnchorStyles]::Bottom)
        if ($hasTop) {
            $c.Top += $h
            if ($hasBottom) { $c.Height -= $h }
        }
    }
    $hdr = New-Object System.Windows.Forms.Panel
    $hdr.Location = New-Object System.Drawing.Point(0, 0)
    $hdr.Size = New-Object System.Drawing.Size($Form.ClientSize.Width, $h)
    $hdr.Anchor = 'Top,Left,Right'
    $hdr.BackColor = $script:Th.Header
    $hdr.Add_Paint({
        param($s, $e)
        $r = $s.ClientRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { return }
        $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $r, $script:Th.Header, [System.Drawing.Color]::FromArgb(30, 20, 46), 0.0)
        $e.Graphics.FillRectangle($b, $r); $b.Dispose()
    })
    $line = New-Object System.Windows.Forms.Panel
    $line.Dock = 'Bottom'; $line.Height = 2
    $line.Add_Paint({
        param($s, $e)
        $r = $s.ClientRectangle
        if ($r.Width -le 0 -or $r.Height -le 0) { return }
        $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            $r, $script:Th.Accent, [System.Drawing.Color]::FromArgb(56, 30, 120), 0.0)
        $e.Graphics.FillRectangle($b, $r); $b.Dispose()
    })
    $lblT = New-Object System.Windows.Forms.Label
    $lblT.Text = $Title.ToUpper()
    $lblT.Dock = 'Fill'
    $lblT.TextAlign = 'MiddleCenter'
    $lblT.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblT.ForeColor = [System.Drawing.Color]::White
    $lblT.BackColor = [System.Drawing.Color]::Transparent
    $icoPath = Join-Path $PSScriptRoot 'app.ico'
    if (Test-Path $icoPath) {
        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Size = New-Object System.Drawing.Size(26, 26)
        $pb.Location = New-Object System.Drawing.Point(14, 8)
        $pb.SizeMode = 'Zoom'
        $pb.BackColor = [System.Drawing.Color]::Transparent
        try { $pb.Image = (New-Object System.Drawing.Icon($icoPath, 32, 32)).ToBitmap() } catch {}
        $hdr.Controls.Add($pb)
    }
    $hdr.Controls.Add($lblT)
    $hdr.Controls.Add($line)
    $Form.Controls.Add($hdr)
    $script:HeaderLabel = $lblT
    $script:HeaderPanel = $hdr
}
function Confirm-CloseSteam([string]$SteamPath, [string]$Title) {
    # Chiede il permesso e chiude Steam in modo pulito. Ritorna $true se si puo' procedere.
    if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { return $true }
    $extra = ''
    if (Test-SteamGameRunning) {
        $extra = (T '{0}{0}ATTENZIONE: risulta un gioco avviato da Steam ancora in esecuzione. Chiudendo Steam adesso rischi di perdere i progressi non salvati.') -f "`n"
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        ((T 'Steam e'' aperto e va chiuso per modificare la libreria, altrimenti sovrascrive le modifiche quando esce.{0}{1}{1}Chiudo Steam adesso?') -f $extra, "`n"),
        $Title, 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return $false }
    if (-not (Stop-SteamGracefully $SteamPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            (T 'Non sono riuscito a chiudere Steam. Chiudilo a mano e riprova.'), $Title) | Out-Null
        return $false
    }
    return $true
}
function Set-AppIcon([System.Windows.Forms.Form]$Form) {
    $p = Join-Path $PSScriptRoot 'app.ico'
    if (Test-Path $p) {
        try { $Form.Icon = New-Object System.Drawing.Icon($p) } catch {}
    }
}

# ---------------------------------------------------------------- Artwork Manager
function Show-ArtworkManager([string]$SteamPath, [string]$AccountId, [string]$ApiKey) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not $ApiKey) {
        [System.Windows.Forms.MessageBox]::Show(
            ((T 'Per scegliere gli artwork serve una API key di SteamGridDB (gratuita).{0}Creala su steamgriddb.com -> Profilo -> Preferences -> API e incollala nel campo in basso nella finestra principale.') -f "`n"),
            (T 'Artwork Manager')) | Out-Null
        return
    }
    $configDir = Join-Path $SteamPath "userdata\$AccountId\config"
    $vdfPath = Join-Path $configDir 'shortcuts.vdf'
    $gridDir = Join-Path $configDir 'grid'
    New-Item -ItemType Directory -Force $gridDir | Out-Null
    $shortcuts = Read-ShortcutsVdf $vdfPath
    if ($shortcuts.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show((T 'Nessuna shortcut non-Steam trovata per questo account. Aggiungi prima le app.'), (T 'Artwork Manager')) | Out-Null
        return
    }
    $iconDir = Join-Path $env:APPDATA 'SteamImporter\icons'
    New-Item -ItemType Directory -Force $iconDir | Out-Null

    $cats = @(
        @{ Title = (T 'Copertina'); Endpoint = 'grids';  Query = 'dimensions=600x900&mimes=image/png,image/jpeg'; Suffix = 'p' },
        @{ Title = (T 'Banner');    Endpoint = 'grids';  Query = 'dimensions=460x215,920x430&mimes=image/png,image/jpeg'; Suffix = '' },
        @{ Title = (T 'Hero');      Endpoint = 'heroes'; Query = 'mimes=image/png,image/jpeg'; Suffix = '_hero' },
        @{ Title = (T 'Logo');      Endpoint = 'logos';  Query = 'mimes=image/png,image/jpeg'; Suffix = '_logo' },
        @{ Title = (T 'Icona');     Endpoint = 'icons';  Query = ''; Suffix = 'ICON' }
    )

    $f = New-Object System.Windows.Forms.Form
    $f.Text = T 'Artwork Manager - scegli le immagini da SteamGridDB'
    $f.Size = New-Object System.Drawing.Size(1000, 720)
    $f.StartPosition = 'CenterScreen'

    $lblSc = New-Object System.Windows.Forms.Label
    $lblSc.Text = T 'Shortcut:'; $lblSc.Location = '12,14'; $lblSc.AutoSize = $true
    $lstSc = New-Object System.Windows.Forms.ListBox
    $lstSc.Location = '12,36'; $lstSc.Size = '220,560'; $lstSc.Anchor = 'Top,Bottom,Left'
    foreach ($k in $shortcuts.Keys) { [void]$lstSc.Items.Add($shortcuts[$k]['AppName']) }

    $lblGame = New-Object System.Windows.Forms.Label
    $lblGame.Text = T 'Gioco su SteamGridDB:'; $lblGame.Location = '245,14'; $lblGame.AutoSize = $true
    $cmbGame = New-Object System.Windows.Forms.ComboBox
    $cmbGame.DropDownStyle = 'DropDownList'; $cmbGame.Location = '378,10'; $cmbGame.Width = 262
    $cmbGame.Anchor = 'Top,Left,Right'

    # ricerca manuale: utile quando il nome della shortcut non trova nulla
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = '650,10'; $txtSearch.Width = 208
    $txtSearch.Anchor = 'Top,Right'
    $btnSearch = New-Object System.Windows.Forms.Button
    $btnSearch.Text = T 'Cerca'
    $btnSearch.Location = '864,9'; $btnSearch.Size = '100,26'
    $btnSearch.Anchor = 'Top,Right'

    $tabHost = New-Object System.Windows.Forms.Panel
    $tabHost.Location = '245,42'
    $tabHost.Size = New-Object System.Drawing.Size(725, 554)
    $tabHost.Anchor = 'Top,Bottom,Left,Right'
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(-2, -1)
    $tabs.Size = New-Object System.Drawing.Size(729, 556)
    $tabs.Anchor = 'Top,Bottom,Left,Right'
    $tabHost.Controls.Add($tabs)
    # linguette disegnate a mano: quelle di sistema restano chiare
    $tabs.SizeMode = 'Fixed'
    $tabs.ItemSize = New-Object System.Drawing.Size(143, 30)
    $tabs.DrawMode = 'OwnerDrawFixed'
    $tabs.Add_DrawItem({
        param($s, $e)
        $sel = ($e.Index -eq $s.SelectedIndex)
        $bg = if ($sel) { $script:Th.Accent } else { [System.Drawing.Color]::FromArgb(30, 30, 36) }
        $br = New-Object System.Drawing.SolidBrush($bg)
        $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $fc = if ($sel) { [System.Drawing.Color]::White } else { $script:Th.Sub }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.TabPages[$e.Index].Text, $s.Font,
            $e.Bounds, $fc, ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
                             [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
    })
    foreach ($cat in $cats) {
        $tp = New-Object System.Windows.Forms.TabPage
        $tp.Text = $cat.Title
        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.Dock = 'Fill'; $flow.AutoScroll = $true
        $tp.Controls.Add($flow)
        [void]$tabs.TabPages.Add($tp)
    }

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = T 'Applica selezionate'
    $btnApply.Location = '760,615'; $btnApply.Size = '210,34'; $btnApply.Anchor = 'Bottom,Right'
    $btnApply.Font = New-Object System.Drawing.Font($btnApply.Font, [System.Drawing.FontStyle]::Bold)

    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = T '<  Indietro'
    $btnBack.Location = '648,615'; $btnBack.Size = '104,34'; $btnBack.Anchor = 'Bottom,Right'
    $btnBack.Add_Click({ $f.Close() })

    $st = New-Object System.Windows.Forms.Label
    $st.Location = '12,620'; $st.Size = '730,28'; $st.Anchor = 'Bottom,Left'
    $st.Text = T 'Scegli una shortcut a sinistra.'

    $script:amSel = @{}      # indice tab -> oggetto immagine selezionato
    $script:amLoaded = @{}   # indice tab -> $true se gia' caricato
    $script:amGames = @()

    function Clear-AmTabs {
        $script:amSel = @{}; $script:amLoaded = @{}
        foreach ($tp in $tabs.TabPages) {
            $flow = $tp.Controls[0]
            foreach ($c in @($flow.Controls)) {
                if ($c.Image) { $c.Image.Dispose(); $c.Image = $null }   # niente handle grafici lasciati indietro
                $c.Dispose()
            }
            $flow.Controls.Clear()
        }
    }
    function Load-AmTab([int]$idx) {
        if ($script:amLoaded[$idx] -or $cmbGame.SelectedIndex -lt 0) { return }
        $cat = $cats[$idx]
        $game = $script:amGames[$cmbGame.SelectedIndex]
        $flow = $tabs.TabPages[$idx].Controls[0]
        $flow.Controls.Clear()
        $st.Text = (T 'Carico anteprime ''{0}''...') -f $cat.Title
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $f.Refresh()
        $imgs = Get-SgdbImageList -ApiKey $ApiKey -Endpoint $cat.Endpoint -GameId $game.id -Query $cat.Query
        $wc = New-Object System.Net.WebClient
        $n = 0
        foreach ($im in $imgs) {
            try {
                $bytes = $wc.DownloadData($im.thumb)
                $ms = New-Object System.IO.MemoryStream(, $bytes)
                $pic = New-Object System.Windows.Forms.PictureBox
                $pic.Image = [System.Drawing.Image]::FromStream($ms)
                $pic.SizeMode = 'Zoom'
                $pic.Size = New-Object System.Drawing.Size(160, 160)
                $pic.Margin = New-Object System.Windows.Forms.Padding(6)
                $pic.BackColor = [System.Drawing.Color]::Transparent
                $pic.Cursor = [System.Windows.Forms.Cursors]::Hand
                $pic.Tag = @{ Data = $im; TabIndex = $idx }
                $pic.Add_Click({
                    param($sender, $e)
                    $info = $sender.Tag
                    foreach ($c in $sender.Parent.Controls) { $c.BackColor = [System.Drawing.Color]::Transparent }
                    $sender.BackColor = [System.Drawing.Color]::DodgerBlue
                    $script:amSel[$info.TabIndex] = $info.Data
                    $st.Text = (T 'Selezionata immagine per ''{0}''.') -f $cats[$info.TabIndex].Title
                })
                $flow.Controls.Add($pic)
                $n++
            } catch {}
        }
        $wc.Dispose()
        $f.Cursor = [System.Windows.Forms.Cursors]::Default
        $script:amLoaded[$idx] = $true
        $st.Text = if ($n -gt 0) { (T '{0} anteprime caricate. Clicca per selezionare, poi ''Applica''.') -f $n } else { (T 'Nessuna immagine trovata per ''{0}''.') -f $cat.Title }
    }

    function Search-Sgdb([string]$Name) {
        $Name = $Name.Trim()
        if (-not $Name) { return }
        Clear-AmTabs
        $cmbGame.Items.Clear()
        $st.Text = (T 'Cerco ''{0}'' su SteamGridDB...') -f $Name
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $f.Refresh()
        $script:amGames = @(Get-SgdbSearchResults -ApiKey $ApiKey -Name $Name)
        $f.Cursor = [System.Windows.Forms.Cursors]::Default
        foreach ($g in $script:amGames) { [void]$cmbGame.Items.Add($g.name) }
        if ($cmbGame.Items.Count -gt 0) {
            $cmbGame.SelectedIndex = 0
        } else {
            $st.Text = (T 'Nessun risultato per ''{0}''. Prova a scrivere un altro nome qui a destra e premi Cerca.') -f $Name
        }
    }

    $lstSc.Add_SelectedIndexChanged({
        if ($lstSc.SelectedIndex -lt 0) { return }
        $name = [string]$lstSc.SelectedItem
        $txtSearch.Text = $name          # cosi' si vede cosa e' stato cercato e si puo' correggere
        Search-Sgdb $name
    })
    $btnSearch.Add_Click({ Search-Sgdb $txtSearch.Text })
    $txtSearch.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true   # niente suono di sistema
            Search-Sgdb $txtSearch.Text
        }
    })
    $cmbGame.Add_SelectedIndexChanged({ Clear-AmTabs; Load-AmTab $tabs.SelectedIndex })
    $tabs.Add_SelectedIndexChanged({ Load-AmTab $tabs.SelectedIndex })

    $btnApply.Add_Click({
        if ($lstSc.SelectedIndex -lt 0 -or $script:amSel.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show((T 'Seleziona prima almeno una immagine nelle schede.'), (T 'Artwork Manager')) | Out-Null
            return
        }
        $key = @($shortcuts.Keys)[$lstSc.SelectedIndex]
        $entry = $shortcuts[$key]
        $appid = if ($entry.Contains('appid')) { [uint32]$entry['appid'] } else { Get-ShortcutAppId $entry['Exe'] $entry['AppName'] }
        $wc = New-Object System.Net.WebClient
        $done = 0
        $needVdf = $false
        $newIcon = $null
        $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $st.Text = T 'Scarico le immagini scelte...'
        $f.Refresh()
        foreach ($idx in $script:amSel.Keys) {
            $cat = $cats[$idx]; $img = $script:amSel[$idx]
            $ext = Get-UrlExtension $img.url
            try {
                if ($cat.Suffix -eq 'ICON') {
                    $dest = Join-Path $iconDir "$($appid)_icon$ext"
                    $wc.DownloadFile($img.url, $dest)
                    $newIcon = $dest
                    $needVdf = $true
                } else {
                    $base = "$appid$($cat.Suffix)"
                    Get-ChildItem $gridDir -Filter "$base.*" -ErrorAction SilentlyContinue |
                        Where-Object { $_.BaseName -eq $base } | Remove-Item -Force
                    $wc.DownloadFile($img.url, (Join-Path $gridDir "$base$ext"))
                }
                $done++
            } catch { $st.Text = (T 'Errore download {0}: {1}') -f $cat.Title, $_ }
        }
        $wc.Dispose()
        $f.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($needVdf) {
            if (Confirm-CloseSteam $SteamPath (T 'Artwork Manager')) {
                [void](Backup-Vdf $vdfPath)
                # rileggo dal file e modifico l'entry giusta cercandola per appid,
                # cosi' non sovrascrivo eventuali cambiamenti avvenuti nel frattempo
                $fresh = Read-ShortcutsVdf $vdfPath
                foreach ($fk in $fresh.Keys) {
                    $fe = $fresh[$fk]
                    $fid = if ($fe.Contains('appid')) { [uint32]$fe['appid'] } else { Get-ShortcutAppId $fe['Exe'] $fe['AppName'] }
                    if ($fid -eq $appid) { $fe['icon'] = $newIcon; break }
                }
                Write-ShortcutsVdf $vdfPath $fresh
            } else {
                $done--   # icona scaricata ma non applicata
            }
        }
        $st.Text = (T 'Applicate {0} immagini. Riavvia Steam per vederle.') -f $done
        [System.Windows.Forms.MessageBox]::Show(((T 'Applicate {0} immagini per ''{1}''.{2}Riavvia Steam per vederle in libreria.') -f $done, $entry['AppName'], "`n"), (T 'Artwork Manager')) | Out-Null
    })

    $f.Controls.AddRange(@($lblSc, $lstSc, $lblGame, $cmbGame, $txtSearch, $btnSearch, $tabHost, $btnBack, $btnApply, $st))
    Apply-Theme $f
    Style-PrimaryButton $btnApply
    # la riga in alto viene disposta ORA, quando l'etichetta ha il suo font
    # definitivo: con posizioni fisse il testo finiva sopra la tendina
    $cmbGame.Left = $lblGame.Right + 10
    $btnSearch.Left = $f.ClientSize.Width - 16 - $btnSearch.Width
    $txtSearch.Left = $btnSearch.Left - 10 - $txtSearch.Width
    $cmbGame.Width = $txtSearch.Left - 12 - $cmbGame.Left
    Hide-ComboArrow $cmbGame
    Add-CheraxHeader $f 'Artwork Manager'
    Set-AppIcon $f
    Set-DarkTitleBar $f
    $f.Add_Shown({
        Set-DarkTitleBar $f
        try { [SINative]::SendMessage($txtSearch.Handle, 0x1501, [IntPtr]1, (T 'cerca un altro nome...')) | Out-Null } catch {}
    })
    [void]$f.ShowDialog()
}

# ---------------------------------------------------------------- Rimozione shortcut
function Show-RemoveManager([string]$SteamPath, [string]$AccountId, [string[]]$PreselectKeys = @()) {
    $configDir = Join-Path $SteamPath "userdata\$AccountId\config"
    $vdfPath = Join-Path $configDir 'shortcuts.vdf'
    $gridDir = Join-Path $configDir 'grid'
    $iconDir = Join-Path $env:APPDATA 'SteamImporter\icons'
    if ((Read-ShortcutsVdf $vdfPath).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show((T 'Nessuna shortcut non-Steam su questo account.'), (T 'Rimuovi App')) | Out-Null
        return
    }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = T 'Rimuovi app aggiunte a Steam'
    $f.Size = New-Object System.Drawing.Size(640, 520)
    $f.StartPosition = 'CenterScreen'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = (T 'Spunta le app da togliere dalla libreria Steam (account {0}):') -f $AccountId
    $lbl.Location = '12,12'; $lbl.AutoSize = $true

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
    $lv.Location = '12,36'; $lv.Size = New-Object System.Drawing.Size(600, 380)
    $lv.Anchor = 'Top,Bottom,Left,Right'
    [void]$lv.Columns.Add((T 'Nome'), 240)
    [void]$lv.Columns.Add((T 'Comando'), 340)
    $rowH2 = New-Object System.Windows.Forms.ImageList
    $rowH2.ImageSize = New-Object System.Drawing.Size(1, 22)
    $lv.SmallImageList = $rowH2

    # La lista va SEMPRE ricostruita dal file: dopo una rimozione le entry vengono
    # rinumerate, quindi le chiavi memorizzate prima non valgono piu'.
    function Fill-RemoveList([string[]]$Preselect = @()) {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $sc = Read-ShortcutsVdf $vdfPath
        foreach ($k in $sc.Keys) {
            $e = $sc[$k]
            $item = New-Object System.Windows.Forms.ListViewItem([string]$e['AppName'])
            [void]$item.SubItems.Add(("$($e['Exe']) $($e['LaunchOptions'])").Trim())
            $item.Tag = $k
            if ($Preselect -contains $k) { $item.Checked = $true }
            [void]$lv.Items.Add($item)
        }
        $lv.EndUpdate()
        Update-LastColumn $lv
    }
    Fill-RemoveList $PreselectKeys

    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = T '<  Indietro'
    $btnBack.Location = '12,432'; $btnBack.Size = '100,32'; $btnBack.Anchor = 'Bottom,Left'
    $btnBack.Add_Click({ $f.Close() })

    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text = T 'Rimuovi selezionate'
    $btnDel.Location = '442,432'; $btnDel.Size = '170,32'; $btnDel.Anchor = 'Bottom,Right'
    $btnDel.Font = New-Object System.Drawing.Font($btnDel.Font, [System.Drawing.FontStyle]::Bold)

    $btnDel.Add_Click({
        $checked = @($lv.Items | Where-Object { $_.Checked })
        if ($checked.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show((T 'Spunta almeno una app da rimuovere.'), (T 'Rimuovi App')) | Out-Null
            return
        }
        $names = ($checked | ForEach-Object { $_.Text }) -join "`n"
        $r = [System.Windows.Forms.MessageBox]::Show(
            ((T 'Tolgo dalla libreria Steam queste app?{0}{0}{1}{0}{0}Verranno rimossi anche i loro artwork. Viene creato un backup, puoi annullare con ''Annulla modifiche''.') -f "`n", $names),
            (T 'Rimuovi App'), 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        if (-not (Confirm-CloseSteam $SteamPath (T 'Rimuovi App'))) { return }
        $keys = @($checked | ForEach-Object { [string]$_.Tag })
        $n = Remove-ShortcutEntries -VdfPath $vdfPath -GridDir $gridDir -Keys $keys -IconDir $iconDir
        Fill-RemoveList   # rilegge dal file: le chiavi sono cambiate
        [System.Windows.Forms.MessageBox]::Show(((T 'Rimosse {0} app. Riavvia Steam per aggiornare la libreria.') -f $n), (T 'Rimuovi App')) | Out-Null
        if ($lv.Items.Count -eq 0) { $f.Close() }
    })

    $f.Controls.AddRange(@($lbl, $lv, $btnBack, $btnDel))
    Apply-Theme $f
    Add-CheraxHeader $f (T 'Rimuovi App')
    Set-AppIcon $f
    Set-DarkTitleBar $f
    Set-DarkListHeader $lv
    $f.Add_Shown({ Set-DarkTitleBar $f; Update-LastColumn $lv })
    if ($btnDel.Tag -is [hashtable]) {
        $btnDel.Tag.RFill = [System.Drawing.Color]::FromArgb(178, 58, 58)
        $btnDel.Tag.RHover = [System.Drawing.Color]::FromArgb(210, 76, 76)
        $btnDel.Tag.RBorder = [System.Drawing.Color]::FromArgb(226, 100, 100)
        $btnDel.Tag.RText = [System.Drawing.Color]::White
        $btnDel.Invalidate()
    }
    [void]$f.ShowDialog()
}

# ---------------------------------------------------------------- Self test
if ($SelfTest) {
    Write-Host '--- SelfTest ---'
    # CRC32 valore noto
    $crc = Get-Crc32 ([System.Text.Encoding]::ASCII.GetBytes('123456789'))
    if ($crc.ToString('X8') -ne 'CBF43926') { throw "CRC32 errato: $($crc.ToString('X8'))" }
    Write-Host "CRC32 ok (CBF43926)"

    # roundtrip VDF
    $tmp = Join-Path $env:TEMP "si-selftest-$(Get-Random).vdf"
    $sc = [ordered]@{}
    $sc['0'] = New-ShortcutEntry -AppName 'Prova App' -Exe '"C:\WINDOWS\explorer.exe"' -StartDir '"C:\WINDOWS"' -LaunchOptions 'shell:AppsFolder\Test!App' -Icon ''
    $sc['1'] = New-ShortcutEntry -AppName 'Àccénti ✓' -Exe '"C:\x\y.exe"' -StartDir '"C:\x"' -LaunchOptions '' -Icon 'C:\i.png'
    Write-ShortcutsVdf $tmp $sc
    $back = Read-ShortcutsVdf $tmp
    if ($back.Count -ne 2) { throw "Roundtrip: attese 2 entry, trovate $($back.Count)" }
    if ($back['0']['AppName'] -ne 'Prova App') { throw 'Roundtrip: AppName errato' }
    if ($back['1']['AppName'] -ne 'Àccénti ✓') { throw 'Roundtrip: UTF8 errato' }
    if ($back['0']['appid'] -ne (Get-ShortcutAppId '"C:\WINDOWS\explorer.exe"' 'Prova App')) { throw 'Roundtrip: appid errato' }
    Remove-Item $tmp -Force
    Write-Host 'Roundtrip VDF ok'

    # parsing di uno shortcuts.vdf reale (sola lettura)
    $steamPath = Get-SteamPath
    if ($steamPath) {
        foreach ($acc in (Get-SteamAccounts $steamPath)) {
            $p = Join-Path $acc.Path 'config\shortcuts.vdf'
            if (Test-Path $p) {
                $real = Read-ShortcutsVdf $p
                # riscrivo in temp e confronto i byte per garantire fedelta'
                $tmp2 = Join-Path $env:TEMP "si-real-$(Get-Random).vdf"
                Write-ShortcutsVdf $tmp2 $real
                $a = [System.IO.File]::ReadAllBytes($p)
                $b = [System.IO.File]::ReadAllBytes($tmp2)
                $same = ($a.Length -eq $b.Length) -and (@(Compare-Object $a $b -SyncWindow 0).Count -eq 0)
                Remove-Item $tmp2 -Force
                Write-Host "Account $($acc.Id): $($real.Count) shortcut esistenti - riscrittura identica byte-per-byte: $same"
            }
        }
    }

    # scanner launcher
    foreach ($scanner in 'Get-BattleNetGames', 'Get-EpicGames', 'Get-GogGames', 'Get-UbisoftGames', 'Get-StartMenuPrograms') {
        $found = @(& $scanner)
        Write-Host "$scanner : $($found.Count)"
        $found | Select-Object -First 3 | ForEach-Object { Write-Host "   - $($_.Name) [$($_.Kind)] Exe=$($_.Exe) Opts=$($_.LaunchOptions)" }
    }
    # account con nomi
    $steamPath2 = Get-SteamPath
    if ($steamPath2) {
        Get-SteamAccounts $steamPath2 | ForEach-Object { Write-Host "Account: $($_.Id) -> $($_.Name)" }
    }

    # enumerazione UWP + estrazione icona di esempio
    $uwp = Get-UwpApps
    Write-Host "App UWP trovate: $($uwp.Count)"
    $cache = Join-Path $env:TEMP 'si-icons'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $sample = $uwp | Where-Object { $_.InstallDir } | Select-Object -First 3
    foreach ($s in $sample) {
        $ico = Get-UwpIcon $s $cache
        Write-Host ("Icona {0}: {1}" -f $s.Name, $(if ($ico) { Split-Path $ico -Leaf } else { 'NON TROVATA' }))
    }
    Write-Host '--- SelfTest completato ---'
    return
}

# ---------------------------------------------------------------- GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Lang = (Get-SIConfig).Lang
$iconCache = Join-Path $env:APPDATA 'SteamImporter\icons'
New-Item -ItemType Directory -Force $iconCache | Out-Null

$steamPath = Get-SteamPath
if (-not $steamPath) {
    [System.Windows.Forms.MessageBox]::Show((T 'Steam non trovato su questo PC.'), 'SteamImporter') | Out-Null
    return
}
$accounts = @(Get-SteamAccounts $steamPath)

$form = New-Object System.Windows.Forms.Form
$form.Text = T 'SteamImporter - aggiungi app non-Steam a Steam'
$form.Size = New-Object System.Drawing.Size(820, 620)
$form.MinimumSize = $form.Size
$form.StartPosition = 'CenterScreen'

$lblAcc = New-Object System.Windows.Forms.Label
$lblAcc.Text = T 'Account Steam:'
$lblAcc.Location = '12,14'; $lblAcc.AutoSize = $true

$cmbAcc = New-Object System.Windows.Forms.ComboBox
$cmbAcc.DropDownStyle = 'DropDownList'
$cmbAcc.Location = '110,10'; $cmbAcc.Width = 260
foreach ($a in $accounts) { [void]$cmbAcc.Items.Add("$($a.Name)  -  $($a.Id)  (ultimo uso: $($a.LastUsed.ToString('dd/MM/yyyy')))") }
if ($cmbAcc.Items.Count -gt 0) { $cmbAcc.SelectedIndex = 0 }

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Location = '380,10'; $txtFilter.Width = 180

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class SINative {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
}
'@


$chkAll = New-Object System.Windows.Forms.CheckBox
$chkAll.Text = T 'Mostra anche app di sistema'
$chkAll.Location = '570,11'; $chkAll.AutoSize = $true

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.CheckBoxes = $true; $list.FullRowSelect = $true
$list.LabelEdit = $true
$list.Location = '12,42'
$list.Size = New-Object System.Drawing.Size(780, 420)
$list.Anchor = 'Top,Bottom,Left,Right'
[void]$list.Columns.Add((T 'Nome (doppio click per rinominare)'), 260)
[void]$list.Columns.Add((T 'Tipo'), 75)
[void]$list.Columns.Add((T 'In Steam'), 70)
[void]$list.Columns.Add((T 'Dettaglio'), 295)
# icona di ogni app nella prima colonna (l'altezza delle righe segue l'immagine)
$script:imgList = New-Object System.Windows.Forms.ImageList
$script:imgList.ImageSize = New-Object System.Drawing.Size(20, 20)
$script:imgList.ColorDepth = 'Depth32Bit'
$list.SmallImageList = $script:imgList
$script:iconIndex = @{}
# caselle di spunta scure al posto di quelle bianche di sistema
$stateImgs = New-Object System.Windows.Forms.ImageList
$stateImgs.ImageSize = New-Object System.Drawing.Size(16, 16)
$stateImgs.ColorDepth = 'Depth32Bit'
$stateImgs.Images.Add((New-CheckImage $false))
$stateImgs.Images.Add((New-CheckImage $true))
$list.StateImageList = $stateImgs

# colore della colonna "Tipo", uno per fonte
$script:KindColor = @{
    'Battle.net' = [System.Drawing.Color]::FromArgb(88, 165, 235)
    'Epic'       = [System.Drawing.Color]::FromArgb(215, 215, 225)
    'GOG'        = [System.Drawing.Color]::FromArgb(190, 130, 245)
    'Ubisoft'    = [System.Drawing.Color]::FromArgb(120, 195, 255)
    'UWP'        = [System.Drawing.Color]::FromArgb(140, 175, 230)
    'App'        = [System.Drawing.Color]::FromArgb(150, 150, 162)
    'EXE'        = [System.Drawing.Color]::FromArgb(150, 150, 162)
}
function Get-AppIconIndex($App) {
    # ogni icona viene estratta una volta sola e poi riusata
    $key = if ($App.Aumid) { $App.Aumid } elseif ($App.ExePath) { $App.ExePath } else { "$($App.Exe)|$($App.LaunchOptions)" }
    if ($null -ne $script:iconIndex[$key]) { return $script:iconIndex[$key] }
    $img = $null
    try {
        $src = $null
        if ($App.Kind -eq 'UWP') { $src = Get-UwpIcon $App $iconCache }
        elseif ($App.Icon) { $src = $App.Icon }
        elseif ($App.ExePath) { $src = $App.ExePath }
        if ($src -and (Test-Path $src)) {
            if ($src -like '*.exe' -or $src -like '*.ico') {
                $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($src)
                if ($ic) { $img = $ic.ToBitmap() }
            } else {
                # carico i byte per non tenere bloccato il file
                $ms = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes($src))
                $img = [System.Drawing.Image]::FromStream($ms)
            }
        }
    } catch { $img = $null }
    if (-not $img) { $script:iconIndex[$key] = -1; return -1 }
    $script:imgList.Images.Add($img)
    $img.Dispose()
    $idx = $script:imgList.Images.Count - 1
    $script:iconIndex[$key] = $idx
    return $idx
}

# I pulsanti stanno in un pannello che li dispone da solo: per aggiungerne uno
# basta crearlo e metterlo nel pannello, senza ricalcolare le coordinate a mano.
$pnlBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlBtns.Location = '12,468'
$pnlBtns.Size = New-Object System.Drawing.Size(780, 34)
$pnlBtns.Anchor = 'Bottom,Left,Right'
$pnlBtns.FlowDirection = 'LeftToRight'
$pnlBtns.WrapContents = $false

function New-BarButton([string]$Text, [int]$Width) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($Width, 28)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
    [void]$pnlBtns.Controls.Add($b)
    return $b
}
$btnExe     = New-BarButton (T 'Aggiungi .exe...') 110
$btnRefresh = New-BarButton (T 'Ricarica') 80
$btnArt     = New-BarButton (T 'Artwork / Copertine...') 150
$btnUndo    = New-BarButton (T 'Annulla modifiche') 130
$btnRemove  = New-BarButton (T 'Rimuovi...') 90
$btnSteam   = New-BarButton (T 'Riavvia Steam') 122

$lblKey = New-Object System.Windows.Forms.LinkLabel
$lblKey.Text = T 'API key SteamGridDB (clicca qui per ottenerla gratis):'
$lblKey.LinkArea = New-Object System.Windows.Forms.LinkArea(21, 10)
$lblKey.Location = '12,510'; $lblKey.AutoSize = $true; $lblKey.Anchor = 'Bottom,Left'
$lblKey.Add_LinkClicked({ Start-Process 'https://www.steamgriddb.com/profile/preferences/api' })

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Location = '320,507'; $txtKey.Width = 180; $txtKey.Anchor = 'Bottom,Left'
$txtKey.UseSystemPasswordChar = $true
$txtKey.Text = (Get-SIConfig).SgdbApiKey

$chkSaveKey = New-Object System.Windows.Forms.CheckBox
$chkSaveKey.Text = T 'Salva'
$chkSaveKey.Location = '508,509'; $chkSaveKey.AutoSize = $true; $chkSaveKey.Anchor = 'Bottom,Left'
$chkSaveKey.Checked = [bool](Get-SIConfig).SgdbApiKey

function Save-ApiKeyIfWanted {
    $cfg = Get-SIConfig
    if ($chkSaveKey.Checked) { $cfg.SgdbApiKey = $txtKey.Text.Trim() } else { $cfg.SgdbApiKey = '' }
    Save-SIConfig $cfg
}

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = T 'Aggiungi a Steam'
$btnExport.Location = '648,500'; $btnExport.Size = '144,34'; $btnExport.Anchor = 'Bottom,Right'
$btnExport.Font = New-Object System.Drawing.Font($btnExport.Font, [System.Drawing.FontStyle]::Bold)

$sep = New-Object System.Windows.Forms.Panel
$sep.Location = '12,458'; $sep.Size = '780,1'; $sep.Anchor = 'Bottom,Left,Right'

$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Dock = 'Bottom'; $pnlStatus.Height = 30
$status = New-Object System.Windows.Forms.Label
$status.Dock = 'Fill'; $status.TextAlign = 'MiddleLeft'
$status.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
$status.Text = T 'Pronto.'
$pnlStatus.Controls.Add($status)

$script:allApps = @()
$script:inSteam = @{}
$script:scanErrors = @()
function Refresh-ExistingMap {
    $script:inSteam = @{}
    if ($cmbAcc.SelectedIndex -ge 0) {
        try { $script:inSteam = Get-ExistingShortcutMap -SteamPath $steamPath -AccountId $accounts[$cmbAcc.SelectedIndex].Id } catch {}
    }
}
function Update-List {
    $list.BeginUpdate()
    $list.Items.Clear()
    $f = $txtFilter.Text.Trim()
    $added = 0
    foreach ($app in $script:allApps) {
        if (-not $chkAll.Checked -and $app.Kind -eq 'UWP' -and ($app.Pfn -like 'Microsoft.*' -or $app.Pfn -like 'MicrosoftWindows.*' -or $app.Pfn -like 'MicrosoftCorporationII.*' -or $app.Pfn -like 'windows.*')) { continue }
        if ($f -and $app.Name -notlike "*$f*") { continue }
        $sig = Get-AppSignature $app
        $ex = if ($sig -and $script:inSteam[$sig]) { $script:inSteam[$sig] } else { $null }
        $app | Add-Member -NotePropertyName VdfKey -NotePropertyValue $(if ($ex) { [string]$ex.Key } else { $null }) -Force
        $item = New-Object System.Windows.Forms.ListViewItem($app.Name)
        $item.UseItemStyleForSubItems = $false      # ogni colonna col suo colore
        $item.ImageIndex = Get-AppIconIndex $app
        $item.ForeColor = if ($ex) { [System.Drawing.Color]::FromArgb(196, 160, 255) } else { $script:Th.Text }
        $sKind = $item.SubItems.Add($app.Kind)
        $sKind.ForeColor = if ($script:KindColor[$app.Kind]) { $script:KindColor[$app.Kind] } else { $script:Th.Sub }
        $sChk = $item.SubItems.Add($(if ($ex) { [string][char]0x2713 } else { '' }))
        $sChk.ForeColor = [System.Drawing.Color]::FromArgb(110, 205, 140)
        $sDet = $item.SubItems.Add([string]$app.Detail)
        $sDet.ForeColor = $script:Th.Sub
        if ($ex) { $added++ }
        $item.Tag = $app
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()
    Update-LastColumn $list
    $msg = (T '{0} app in elenco - {1} gia'' in Steam (in viola).') -f $list.Items.Count, $added
    if ($script:scanErrors.Count -gt 0) { $msg += (T '  Scansione fallita per: {0}') -f ($script:scanErrors -join '; ') }
    $status.Text = $msg
}
function Reload-Apps {
    $status.Text = T 'Scansione app installate (UWP, Battle.net, Epic, GOG, Ubisoft, menu Start)...'
    $form.Refresh()
    $apps = @()
    $apps += @(Get-UwpApps | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Kind = 'UWP'; Detail = $_.Aumid; Aumid = $_.Aumid; Pfn = $_.Pfn; InstallDir = $_.InstallDir; ExePath = $null; Exe = $null; StartDir = $null; LaunchOptions = $null; Icon = $null }
    })
    $script:scanErrors = @()
    foreach ($scanner in 'Get-BattleNetGames', 'Get-EpicGames', 'Get-GogGames', 'Get-UbisoftGames', 'Get-StartMenuPrograms') {
        try { $apps += @(& $scanner) }
        catch { $script:scanErrors += "$($scanner -replace '^Get-|Games$|Programs$', '') ($($_.Exception.Message))" }
    }
    # i giochi dei launcher prima, poi UWP e app generiche, in ordine alfabetico
    $order = @{ 'Battle.net' = 0; 'Epic' = 0; 'GOG' = 0; 'Ubisoft' = 0; 'UWP' = 1; 'App' = 2; 'EXE' = 2 }
    $script:allApps = @($apps | Sort-Object { $order[$_.Kind] }, Name)
    Refresh-ExistingMap
    Update-List
}

$txtFilter.Add_TextChanged({ Update-List })
$chkAll.Add_CheckedChanged({ Update-List })
$btnRefresh.Add_Click({ Reload-Apps })

$btnUndo.Add_Click({
    if ($cmbAcc.SelectedIndex -lt 0) { return }
    $acc = $accounts[$cmbAcc.SelectedIndex]
    $cfgDir = Join-Path $steamPath "userdata\$($acc.Id)\config"
    $baks = @(Get-ChildItem $cfgDir -Filter 'shortcuts.vdf.bak-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
    if ($baks.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show((T 'Nessun backup trovato per questo account.'), 'SteamImporter') | Out-Null
        return
    }
    $bak = $baks[0]
    $r = [System.Windows.Forms.MessageBox]::Show(
        ((T 'Torno indietro di un passo, allo stato del {0}?{1}{1}Passi indietro ancora disponibili dopo questo: {2}') -f $bak.LastWriteTime.ToString('dd/MM/yyyy HH:mm'), "`n", ($baks.Count - 1)),
        (T 'Annulla modifiche'), 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    if (-not (Confirm-CloseSteam $steamPath (T 'Annulla modifiche'))) { return }
    Copy-Item $bak.FullName (Join-Path $cfgDir 'shortcuts.vdf') -Force
    # il backup viene consumato: cosi' premendo di nuovo si torna ancora piu' indietro
    Remove-Item $bak.FullName -Force -ErrorAction SilentlyContinue
    Refresh-ExistingMap
    Update-List
    $status.Text = (T 'Ripristinato lo stato del {0} - passi indietro rimasti: {1}') -f $bak.LastWriteTime.ToString('dd/MM HH:mm'), ($baks.Count - 1)
    [System.Windows.Forms.MessageBox]::Show((T 'Fatto. Riavvia Steam per vedere la libreria come prima.'), 'SteamImporter') | Out-Null
})

$btnArt.Add_Click({
    if ($cmbAcc.SelectedIndex -lt 0) { return }
    Save-ApiKeyIfWanted
    Show-ArtworkManager -SteamPath $steamPath -AccountId $accounts[$cmbAcc.SelectedIndex].Id -ApiKey $txtKey.Text.Trim()
})

function Apply-Language {
    # rimette tutte le scritte della finestra principale nella lingua scelta
    $form.Text = T 'SteamImporter - aggiungi app non-Steam a Steam'
    $script:HeaderLabel.Text = 'SteamImporter'
    $lblAcc.Text = T 'Account Steam:'
    $chkAll.Text = T 'Mostra anche app di sistema'
    $list.Columns[0].Text = T 'Nome (doppio click per rinominare)'
    $list.Columns[1].Text = T 'Tipo'
    $list.Columns[2].Text = T 'In Steam'
    $list.Columns[3].Text = T 'Dettaglio'
    $btnExe.Text     = T 'Aggiungi .exe...'
    $btnRefresh.Text = T 'Ricarica'
    $btnArt.Text     = T 'Artwork / Copertine...'
    $btnUndo.Text    = T 'Annulla modifiche'
    $btnRemove.Text  = T 'Rimuovi...'
    $btnSteam.Text   = T 'Riavvia Steam'
    $btnExport.Text  = T 'Aggiungi a Steam'
    $lblKey.Text = T 'API key SteamGridDB (clicca qui per ottenerla gratis):'
    # in entrambe le lingue la parte cliccabile sono 10 caratteri dopo i primi 21
    $lblKey.LinkArea = New-Object System.Windows.Forms.LinkArea(21, 10)
    $chkSaveKey.Text = T 'Salva'
    try { [SINative]::SendMessage($txtFilter.Handle, 0x1501, [IntPtr]1, (T 'cerca...')) | Out-Null } catch {}
    # i pulsanti sono disegnati a mano: vanno ridisegnati dopo il cambio testo
    foreach ($b in @($btnExe, $btnRefresh, $btnArt, $btnUndo, $btnRemove, $btnSteam, $btnExport)) { $b.Invalidate() }
    Update-LangSwitch
}
function Update-LangSwitch {
    # evidenzia la lingua attiva nello switch in alto a destra
    if (-not $script:LblIta) { return }
    $script:LblIta.ForeColor = if ($script:Lang -eq 'it') { [System.Drawing.Color]::White } else { $script:Th.Sub }
    $script:LblEng.ForeColor = if ($script:Lang -eq 'en') { [System.Drawing.Color]::White } else { $script:Th.Sub }
}
function Set-Lang([string]$Nuova) {
    if ($script:Lang -eq $Nuova) { return }
    $script:Lang = $Nuova
    $cfg = Get-SIConfig
    $cfg.Lang = $Nuova
    Save-SIConfig $cfg
    Apply-Language
    $status.Text = T 'Cambio lingua...'
    $form.Refresh()
    Reload-Apps      # rilegge anche i dettagli degli scanner nella nuova lingua
}
function Add-LangSwitch([System.Windows.Forms.Form]$Form) {
    # switch ITA | ENG nell'angolo in alto a destra dell'intestazione
    $w = $Form.ClientSize.Width
    $mk = {
        param($testo, $x, $larg, $allinea)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $testo
        $l.Size = New-Object System.Drawing.Size($larg, 20)
        $l.Location = New-Object System.Drawing.Point($x, 12)
        $l.TextAlign = $allinea
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
        $l.Anchor = 'Top,Right'
        $script:HeaderPanel.Controls.Add($l)
        $l.BringToFront()
        return $l
    }
    $script:LblIta = & $mk 'ITA' ($w - 106) 34 'MiddleRight'
    $sep = & $mk '|' ($w - 70) 10 'MiddleCenter'
    $sep.ForeColor = $script:Th.Sub
    $script:LblEng = & $mk 'ENG' ($w - 58) 36 'MiddleLeft'
    $script:LblIta.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:LblEng.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:LblIta.Add_Click({ Set-Lang 'it' })
    $script:LblEng.Add_Click({ Set-Lang 'en' })
    Update-LangSwitch
}

$cmbAcc.Add_SelectedIndexChanged({ Refresh-ExistingMap; Update-List })

$btnSteam.Add_Click({
    if (Test-SteamGameRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            ((T 'Risulta un gioco avviato da Steam ancora in esecuzione: riavviando Steam adesso rischi di perdere i progressi non salvati.{0}{0}Riavvio lo stesso?') -f "`n"),
            (T 'Riavvia Steam'), 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
    }
    $status.Text = T 'Chiusura di Steam in corso...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()
    $ok = Stop-SteamGracefully $steamPath
    Start-Process (Join-Path $steamPath 'steam.exe')
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    $status.Text = if ($ok) { T 'Steam riavviato: le modifiche alla libreria sono ora visibili.' }
                   else { T 'Steam non si e'' chiuso del tutto: controlla e riprova.' }
})

$btnRemove.Add_Click({
    if ($cmbAcc.SelectedIndex -lt 0) { return }
    # le app spuntate che risultano gia' in Steam arrivano gia' selezionate nella finestra di rimozione
    $pre = @($list.Items | Where-Object { $_.Checked -and $_.Tag.VdfKey } | ForEach-Object { [string]$_.Tag.VdfKey })
    Show-RemoveManager -SteamPath $steamPath -AccountId $accounts[$cmbAcc.SelectedIndex].Id -PreselectKeys $pre
    Refresh-ExistingMap
    Update-List
})

$btnExe.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = T 'Programmi (*.exe)|*.exe'
    $dlg.Title = T 'Scegli il programma da aggiungere a Steam'
    if ($dlg.ShowDialog() -eq 'OK') {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
        $script:allApps = @($script:allApps) + [pscustomobject]@{
            Name = $name; Kind = 'EXE'; Detail = $dlg.FileName; Aumid = $null; Pfn = $null; InstallDir = $null; ExePath = $dlg.FileName; Exe = $null; StartDir = $null; LaunchOptions = $null; Icon = $null
        }
        Update-List
        foreach ($it in $list.Items) { if ($it.Tag.ExePath -eq $dlg.FileName) { $it.Checked = $true } }
    }
})

$btnExport.Add_Click({
    $checked = @($list.Items | Where-Object { $_.Checked })
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show((T 'Seleziona almeno una app (spunta la casella).'), 'SteamImporter') | Out-Null
        return
    }
    if ($cmbAcc.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show((T 'Nessun account Steam trovato in userdata.'), 'SteamImporter') | Out-Null
        return
    }
    if (-not (Confirm-CloseSteam $steamPath 'SteamImporter')) { return }
    $acc = $accounts[$cmbAcc.SelectedIndex]
    $items = @()
    $status.Text = T 'Estrazione icone...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()
    foreach ($it in $checked) {
        $app = $it.Tag
        $icon = if ($app.Kind -eq 'UWP') { Get-UwpIcon $app $iconCache } else { $app.Icon }
        $items += [pscustomobject]@{
            Name = $it.Text; Kind = $app.Kind; Aumid = $app.Aumid; ExePath = $app.ExePath
            Exe = $app.Exe; StartDir = $app.StartDir; LaunchOptions = $app.LaunchOptions; Icon = $icon
        }
    }
    $status.Text = (T 'Scrittura shortcuts.vdf') + $(if ($txtKey.Text) { T ' e download artwork...' } else { '...' })
    $form.Refresh()
    Save-ApiKeyIfWanted
    try {
        $res = Export-ToSteam -SteamPath $steamPath -AccountId $acc.Id -Items $items -SgdbApiKey $txtKey.Text.Trim()
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $msg = (T 'Aggiunte: {0}  -  Gia'' presenti (saltate): {1}') -f $res.Added, $res.Skipped
        if ($txtKey.Text) { $msg += (T '  -  Artwork scaricati: {0}') -f $res.Artwork }
        $status.Text = $msg
        [System.Windows.Forms.MessageBox]::Show(
            ((T '{0}{1}{1}E'' stato creato un backup di shortcuts.vdf.{1}Riavvia Steam per vedere le nuove app nella libreria.') -f $msg, "`n"),
            'SteamImporter', 'OK', 'Information') | Out-Null
        Refresh-ExistingMap
        Update-List
    } catch {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $status.Text = (T 'Errore: {0}') -f $_
        [System.Windows.Forms.MessageBox]::Show(((T 'Errore durante l''export:{0}{1}') -f "`n", $_), 'SteamImporter', 'OK', 'Error') | Out-Null
    }
})

$form.Controls.AddRange(@($lblAcc, $cmbAcc, $txtFilter, $chkAll, $list, $sep, $pnlBtns, $lblKey, $txtKey, $chkSaveKey, $btnExport, $pnlStatus))
Apply-Theme $form
$pnlBtns.BackColor = $script:Th.Bg
$sep.BackColor = [System.Drawing.Color]::FromArgb(44, 44, 52)
$pnlStatus.BackColor = $script:Th.Panel
$status.BackColor = $script:Th.Panel
Style-PrimaryButton $btnExport
# tasto Riavvia Steam: blu con il logo di Steam
if ($btnSteam.Tag -is [hashtable]) {
    $btnSteam.Tag.RFill = [System.Drawing.Color]::FromArgb(28, 100, 180)
    $btnSteam.Tag.RHover = [System.Drawing.Color]::FromArgb(46, 128, 220)
    $btnSteam.Tag.RBorder = [System.Drawing.Color]::FromArgb(90, 160, 235)
    $btnSteam.Tag.RText = [System.Drawing.Color]::White
    try {
        $sIco = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $steamPath 'steam.exe')).ToBitmap()
        $small = New-Object System.Drawing.Bitmap(18, 18)
        $gg = [System.Drawing.Graphics]::FromImage($small)
        $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gg.DrawImage($sIco, 0, 0, 18, 18); $gg.Dispose()
        $btnSteam.Tag.RImage = $small
    } catch {}
    $btnSteam.Invalidate()
}
$status.ForeColor = $script:Th.Sub
Hide-ComboArrow $cmbAcc
Add-CheraxHeader $form 'SteamImporter'
Add-LangSwitch $form
Set-AppIcon $form
Set-DarkTitleBar $form
Set-DarkListHeader $list
$form.Add_Shown({ Set-DarkTitleBar $form; Update-LastColumn $list })
$form.Add_ResizeEnd({ Update-LastColumn $list })
$form.Add_Shown({ [SINative]::SendMessage($txtFilter.Handle, 0x1501, [IntPtr]1, (T 'cerca...')) | Out-Null; Reload-Apps })
[void]$form.ShowDialog()
