# ============================================================
# IMPORTADOR M3U8 -> JELLYFIN
#
# Asian.m3u8 -> Asian - M3U Import
#
# IMPORTANTE:
# - No modifica la playlist "Asian"
# - No modifica XML
# - No modifica la base de datos
# - Mantiene exactamente el orden del M3U
# - Usa el índice de Jellyfin para evitar 1 consulta por canción
# ============================================================

$M3UFile = ".\Asian.m3u8"
$JellyfinUrl = "http://192.168.1.17:8096"

$PlaylistName = "Asian - M3U Import"

$UserId = "a92e46152a7a48b2a6483fc80fde91cc"

# Cantidad de elementos que pedimos por consulta a Jellyfin
$Limit = 1000

# ============================================================
# INICIO
# ============================================================

Clear-Host

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " IMPORTADOR M3U8 -> JELLYFIN"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "M3U       : $M3UFile"
Write-Host "Playlist  : $PlaylistName"
Write-Host "Jellyfin  : $JellyfinUrl"
Write-Host ""

# ============================================================
# API KEY
# ============================================================

$ApiKey = Read-Host "Introduce tu API Key"

$headers = @{
    "Authorization" = "MediaBrowser Token=`"$($ApiKey.Trim())`""
    "Accept"        = "application/json"
}

# ============================================================
# COMPROBAR JELLYFIN
# ============================================================

try {

    $serverInfo = Invoke-RestMethod `
        -Uri "$JellyfinUrl/System/Info" `
        -Headers $headers `
        -Method Get

    Write-Host "Jellyfin conectado correctamente." -ForegroundColor Green
    Write-Host "Servidor : $($serverInfo.ServerName)"
    Write-Host "Version  : $($serverInfo.Version)"
    Write-Host ""

}
catch {

    Write-Host "ERROR conectando con Jellyfin." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit
}

# ============================================================
# LEER M3U
# ============================================================

if (-not (Test-Path $M3UFile)) {

    Write-Host "ERROR: No existe el archivo:" -ForegroundColor Red
    Write-Host $M3UFile
    exit
}

$lines = Get-Content $M3UFile -Encoding UTF8

$entries = [System.Collections.Generic.List[object]]::new()

for ($i = 0; $i -lt $lines.Count; $i++) {

    if ($lines[$i] -like "#EXTINF:*") {

        if (($i + 1) -ge $lines.Count) {
            continue
        }

        $windowsPath = $lines[$i + 1].Trim()

        # Aceptar rutas:
        # E:\Music\...
        # D:\Music\...
        # etc.

        if ($windowsPath -match '^[A-Za-z]:\\Music\\') {

            # Quitar exactamente:
            # E:\Music\
            $relativePath = $windowsPath -replace '^[A-Za-z]:\\Music\\', ''

            # Windows -> Linux
            $relativePath = $relativePath -replace '\\', '/'

            # Ruta que Jellyfin conoce
            $jellyfinPath = "/media/music/$relativePath"

            # Título del EXTINF
            $title = $lines[$i].Trim() -replace '^#EXTINF:-?\d+,', ''

            $entries.Add(
                [PSCustomObject]@{
                    Index        = $entries.Count + 1
                    Title        = $title
                    WindowsPath  = $windowsPath
                    JellyfinPath = $jellyfinPath
                    ItemId       = $null
                }
            )
        }
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " M3U ANALIZADO"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Lineas totales : $($lines.Count)"
Write-Host "Entradas M3U   : $($entries.Count)"
Write-Host ""

if ($entries.Count -eq 0) {

    Write-Host "ERROR: No se encontraron canciones." -ForegroundColor Red
    exit
}

# ============================================================
# OBTENER TODOS LOS AUDIOS DE JELLYFIN
# ============================================================

Write-Host "Obteniendo biblioteca de audio de Jellyfin..." -ForegroundColor Yellow
Write-Host ""

$audioIndex = @{}

$startIndex = 0
$totalJellyfin = 0

while ($true) {

    $url = "$JellyfinUrl/Items?Recursive=true&IncludeItemTypes=Audio&Fields=Path&StartIndex=$startIndex&Limit=$Limit"

    try {

        $result = Invoke-RestMethod `
            -Uri $url `
            -Headers $headers `
            -Method Get
    }
    catch {

        Write-Host ""
        Write-Host "ERROR obteniendo biblioteca de Jellyfin." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit
    }

    $items = @($result.Items)

    if ($items.Count -eq 0) {
        break
    }

    foreach ($item in $items) {

        if (-not [string]::IsNullOrWhiteSpace($item.Path)) {

            $audioIndex[$item.Path] = $item.Id
            $totalJellyfin++
        }
    }

    $startIndex += $items.Count

    Write-Progress `
        -Activity "Indexando biblioteca de Jellyfin" `
        -Status "Audios indexados: $totalJellyfin" `
        -PercentComplete 0

    if ($items.Count -lt $Limit) {
        break
    }
}

Write-Progress -Activity "Indexando biblioteca de Jellyfin" -Completed

Write-Host ""
Write-Host "Audios indexados en Jellyfin: $totalJellyfin" -ForegroundColor Green
Write-Host ""

# ============================================================
# RESOLVER LAS 3764 ENTRADAS EN MEMORIA
# ============================================================

Write-Host "Resolviendo entradas del M3U..." -ForegroundColor Yellow
Write-Host ""

$found = 0
$notFound = 0

$missing = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $entries) {

    if ($audioIndex.ContainsKey($entry.JellyfinPath)) {

        $entry.ItemId = $audioIndex[$entry.JellyfinPath]

        $found++
    }
    else {

        $notFound++

        $missing.Add($entry)
    }
}

# ============================================================
# RESULTADO DE RESOLUCION
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " RESULTADO DE RESOLUCION"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Entradas M3U       : $($entries.Count)"
Write-Host "Encontradas        : $found" -ForegroundColor Green
Write-Host "No encontradas     : $notFound" -ForegroundColor Yellow
Write-Host ""

# ============================================================
# GUARDAR REPORTE SI HAY FALTANTES
# ============================================================

if ($notFound -gt 0) {

    $reportFile = ".\Asian_import_no_encontrados.txt"

    $report = [System.Collections.Generic.List[string]]::new()

    $report.Add("REPORTE DE IMPORTACION M3U -> JELLYFIN")
    $report.Add("Fecha: $(Get-Date)")
    $report.Add("")
    $report.Add("Entradas M3U   : $($entries.Count)")
    $report.Add("Encontradas    : $found")
    $report.Add("No encontradas : $notFound")
    $report.Add("")
    $report.Add("============================================================")
    $report.Add("CANCIONES NO ENCONTRADAS")
    $report.Add("============================================================")

    foreach ($entry in $missing) {

        $report.Add("")
        $report.Add("Indice : $($entry.Index)")
        $report.Add("Titulo : $($entry.Title)")
        $report.Add("M3U    : $($entry.WindowsPath)")
        $report.Add("Jellyfin: $($entry.JellyfinPath)")
    }

    $report | Set-Content $reportFile -Encoding UTF8

    Write-Host "Se genero el reporte:" -ForegroundColor Yellow
    Write-Host $reportFile
    Write-Host ""

    Write-Host "IMPORTACION CANCELADA." -ForegroundColor Red
    Write-Host "No se creo ninguna playlist."
    Write-Host ""

    exit
}

# ============================================================
# TODAS ENCONTRADAS
# ============================================================

Write-Host "TODAS LAS CANCIONES FUERON ENCONTRADAS." -ForegroundColor Green
Write-Host ""

# ============================================================
# MOSTRAR PRIMERAS Y ULTIMAS ENTRADAS
# ============================================================

Write-Host "Primeras 3 canciones:" -ForegroundColor Cyan
Write-Host ""

$entries | Select-Object -First 3 | ForEach-Object {

    Write-Host "$($_.Index). $($_.Title)"
    Write-Host "   $($_.JellyfinPath)"
    Write-Host "   ID: $($_.ItemId)"
    Write-Host ""
}

Write-Host "Ultimas 3 canciones:" -ForegroundColor Cyan
Write-Host ""

$entries | Select-Object -Last 3 | ForEach-Object {

    Write-Host "$($_.Index). $($_.Title)"
    Write-Host "   $($_.JellyfinPath)"
    Write-Host "   ID: $($_.ItemId)"
    Write-Host ""
}

# ============================================================
# CONFIRMACION
# ============================================================

Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " LISTO PARA CREAR PLAYLIST"
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""

Write-Host "Playlist : $PlaylistName"
Write-Host "Canciones: $found"
Write-Host ""
Write-Host "La playlist original 'Asian' NO sera modificada."
Write-Host ""
Write-Host "Escribe CREAR para continuar."
Write-Host ""

$confirmation = Read-Host "Confirmacion"

if ($confirmation -ne "CREAR") {

    Write-Host ""
    Write-Host "Importacion cancelada." -ForegroundColor Yellow
    exit
}

# ============================================================
# CREAR PLAYLIST CON TODOS LOS IDS
# ============================================================

Write-Host ""
Write-Host "Creando playlist..." -ForegroundColor Yellow
Write-Host ""

# Obtener los IDs en el orden exacto del M3U
$itemIds = @(
    $entries | ForEach-Object {
        $_.ItemId
    }
)

# Crear playlist directamente con los IDs.
# Jellyfin permite enviar los IDs al crear la playlist.
$body = @{
    Name      = $PlaylistName
    UserId    = $UserId
    MediaType = "Audio"
    Ids       = $itemIds
} | ConvertTo-Json -Depth 5

try {

    $playlist = Invoke-RestMethod `
        -Uri "$JellyfinUrl/Playlists" `
        -Headers $headers `
        -Method Post `
        -ContentType "application/json" `
        -Body $body

}
catch {

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host " ERROR CREANDO PLAYLIST"
    Write-Host "============================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""

    exit
}

$playlistId = $playlist.Id

# ============================================================
# RESULTADO
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " IMPORTACION COMPLETADA"
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Playlist       : $PlaylistName"
Write-Host "Playlist ID    : $playlistId"
Write-Host "Canciones M3U  : $($entries.Count)"
Write-Host "Canciones       : $found"
Write-Host ""

Write-Host "Orden utilizado: ORDEN ORIGINAL DEL M3U" -ForegroundColor Green
Write-Host ""

Write-Host "La playlist original 'Asian' NO fue modificada." -ForegroundColor Green
Write-Host ""

Write-Host "============================================================"
