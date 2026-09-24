# ============================================================
# delete_mp3_from_list.ps1
#
# Elimina SOLO los archivos .mp3 indicados en una playlist
# M3U/M3U8.
#
# Por seguridad:
# - Lee la playlist como UTF-8
# - Ignora #EXTM3U / #EXTINF / comentarios
# - Solo procesa entradas .mp3
# - Verifica que el .mp3 exista
# - Verifica que exista el .opus correspondiente
# - Por defecto NO elimina un MP3 si no encuentra su OPUS
# - Genera un log de eliminados, faltantes y protegidos
# - Soporta rutas con japones, ñ, tildes, etc.
# - Mantiene intactos .ogg, .m4a, .wav, .flac y otros formatos
#
# USO NORMAL:
#   .\delete_mp3_from_list.ps1 ".\Asian.m3u8"
#
# PRUEBA SIN BORRAR:
#   .\delete_mp3_from_list.ps1 ".\Asian.m3u8" -WhatIf
#
# Para eliminar aunque no exista el OPUS:
#   .\delete_mp3_from_list.ps1 ".\Asian.m3u8" -DeleteWithoutOpus
#
# ============================================================

param (
    [Parameter(
        Mandatory = $true,
        Position = 0
    )]
    [string]$PlaylistPath,

    [switch]$WhatIf,

    [switch]$DeleteWithoutOpus
)

$ErrorActionPreference = "Continue"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ============================================================
# VERIFICAR FFPROBE
# ============================================================

if (-not (Get-Command ffprobe.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no se encontro ffprobe.exe." -ForegroundColor Red
    exit 1
}

# ============================================================
# VALIDAR OPUS
# ============================================================

function Test-ValidOpus {
    param (
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $false
    }

    try {
        $file = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        if ($file.Length -le 0) {
            return $false
        }
    }
    catch {
        return $false
    }

    $result = @(& ffprobe.exe `
        -v error `
        -select_streams a:0 `
        -show_entries stream=codec_name,duration `
        -of json `
        -- "$FilePath" 2>&1 | ForEach-Object { $_.ToString() })

    if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) {
        return $false
    }

    try {
        $info = ($result -join "`r`n") | ConvertFrom-Json
    }
    catch {
        return $false
    }

    $streams = @($info.streams)

    if ($streams.Count -eq 0) {
        return $false
    }

    if ($streams[0].codec_name -ne "opus") {
        return $false
    }

    try {
        return ([double]$streams[0].duration -gt 0)
    }
    catch {
        return $false
    }
}

# ============================================================
# VERIFICAR PLAYLIST
# ============================================================

if (-not (Test-Path -LiteralPath $PlaylistPath -PathType Leaf)) {

    Write-Host "ERROR: no existe la playlist:" -ForegroundColor Red
    Write-Host "  $PlaylistPath" -ForegroundColor Red
    exit 1
}

$playlistFullPath = (
    Resolve-Path -LiteralPath $PlaylistPath
).Path

$playlistDirectory = Split-Path -Parent $playlistFullPath

# ============================================================
# LOG
# ============================================================

$logFile = Join-Path `
    $playlistDirectory `
    "delete_mp3_from_list.log"

[System.IO.File]::WriteAllText(
    $logFile,
    "",
    $Utf8NoBom
)

# ============================================================
# LEER M3U/M3U8 COMO UTF-8
# ============================================================

try {

    $playlistText = [System.IO.File]::ReadAllText(
        $playlistFullPath,
        $Utf8NoBom
    )
}
catch {

    Write-Host "ERROR: no se pudo leer la playlist." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# ============================================================
# EXTRAER RUTAS
# ============================================================

$playlistLines = $playlistText -split "`r?`n"

$tracks = New-Object System.Collections.Generic.List[string]

foreach ($lineRaw in $playlistLines) {

    $line = $lineRaw.Trim()

    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    # #EXTM3U / #EXTINF / etc.
    if ($line.StartsWith("#")) {
        continue
    }

    # Quitar comillas externas si existen
    if (
        $line.Length -ge 2 -and
        $line.StartsWith('"') -and
        $line.EndsWith('"')
    ) {

        $line = $line.Substring(
            1,
            $line.Length - 2
        )
    }

    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    [void]$tracks.Add($line)
}

# ============================================================
# CONTADORES
# ============================================================

$totalEntries = $tracks.Count

$current = 0
$deleted = 0
$missing = 0
$noOpus = 0
$unsupported = 0
$errors = 0
$whatIfCount = 0

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "ELIMINAR MP3 DESDE PLAYLIST" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Playlist: $playlistFullPath" -ForegroundColor White
Write-Host "Entradas: $totalEntries" -ForegroundColor Yellow

if ($WhatIf) {
    Write-Host "MODO PRUEBA: NO se eliminara ningun archivo." -ForegroundColor Yellow
}
else {
    Write-Host "MODO REAL: los MP3 elegibles seran eliminados." -ForegroundColor Red
}

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# PROCESAR
# ============================================================

foreach ($entry in $tracks) {

    $current++

    Write-Progress `
        -Activity "Eliminando MP3" `
        -Status "$current / $totalEntries" `
        -PercentComplete ([int](($current / [math]::Max($totalEntries, 1)) * 100))

    # ========================================================
    # SOPORTE file:///
    # ========================================================

    $sourcePath = $entry

    if (
        $sourcePath.StartsWith(
            "file:///",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {

        try {
            $uri = [System.Uri]$sourcePath
            $sourcePath = $uri.LocalPath
        }
        catch {
        }
    }

    # ========================================================
    # RESOLVER RUTA
    # ========================================================

    if (
        [System.IO.Path]::IsPathRooted(
            $sourcePath
        )
    ) {

        $resolvedSource = $sourcePath
    }
    else {

        $resolvedSource = Join-Path `
            $playlistDirectory `
            $sourcePath
    }

    # ========================================================
    # SOLO MP3
    # ========================================================

    $extension = [System.IO.Path]::GetExtension(
        $resolvedSource
    ).ToLowerInvariant()

    if ($extension -ne ".mp3") {

        $unsupported++
        continue
    }

    # ========================================================
    # VERIFICAR MP3
    # ========================================================

    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {

        $missing++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[MISSING] $resolvedSource`r`n",
            $Utf8NoBom
        )

        Write-Host "NO ENCONTRADO:" -ForegroundColor Yellow
        Write-Host "  $resolvedSource" -ForegroundColor Yellow

        continue
    }

    # ========================================================
    # OPUS CORRESPONDIENTE
    # ========================================================

    $sourceDirectory = Split-Path `
        -Parent `
        $resolvedSource

    $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension(
        $resolvedSource
    )

    $opusPath = Join-Path `
        $sourceDirectory `
        "$sourceBaseName.opus"

    # ========================================================
    # VERIFICAR OPUS
    # ========================================================

    $opusExists = Test-Path `
        -LiteralPath $opusPath `
        -PathType Leaf

    $opusValid = $false

    if ($opusExists) {
        $opusValid = Test-ValidOpus $opusPath
    }

    if (-not $opusValid -and -not $DeleteWithoutOpus) {

        $noOpus++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[PROTECTED_NO_OPUS] $resolvedSource :: OPUS no encontrado o vacio`r`n",
            $Utf8NoBom
        )

        Write-Host "PROTEGIDO: no existe un OPUS valido." -ForegroundColor Yellow
        Write-Host "  MP3 : $resolvedSource" -ForegroundColor Yellow
        Write-Host "  OPUS: $opusPath" -ForegroundColor Yellow

        continue
    }

    # ========================================================
    # ELIMINAR
    # ========================================================

    if ($WhatIf) {

        $whatIfCount++

        Write-Host "[WHATIF] Se eliminaria:" -ForegroundColor Cyan
        Write-Host "  $resolvedSource" -ForegroundColor Cyan

        [System.IO.File]::AppendAllText(
            $logFile,
            "[WHATIF] $resolvedSource`r`n",
            $Utf8NoBom
        )

        continue
    }

    try {

        Remove-Item `
            -LiteralPath $resolvedSource `
            -Force `
            -ErrorAction Stop

        $deleted++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[DELETED] $resolvedSource`r`n",
            $Utf8NoBom
        )

        Write-Host "ELIMINADO:" -ForegroundColor Green
        Write-Host "  $resolvedSource" -ForegroundColor Green
    }
    catch {

        $errors++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[ERROR] $resolvedSource :: $($_.Exception.Message)`r`n",
            $Utf8NoBom
        )

        Write-Host "ERROR AL ELIMINAR:" -ForegroundColor Red
        Write-Host "  $resolvedSource" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Progress `
    -Activity "Eliminando MP3" `
    -Completed

# ============================================================
# RESUMEN
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "PROCESO FINALIZADO" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Entradas de playlist : $totalEntries" -ForegroundColor White
Write-Host "Eliminados           : $deleted" -ForegroundColor Green
Write-Host "No encontrados       : $missing" -ForegroundColor Yellow
Write-Host "Sin OPUS             : $noOpus" -ForegroundColor Yellow
Write-Host "No MP3               : $unsupported" -ForegroundColor DarkGray
Write-Host "Errores              : $errors" -ForegroundColor Red

if ($WhatIf) {
    Write-Host "Marcados para eliminar: $whatIfCount" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Log: $logFile" -ForegroundColor White
Write-Host ""

if ($errors -eq 0) {

    if ($WhatIf) {
        Write-Host "Prueba completada. No se elimino ningun archivo." -ForegroundColor Cyan
    }
    else {
        Write-Host "Eliminacion completada." -ForegroundColor Green
    }
}
else {

    Write-Host "El proceso termino con errores. Revisa el log." -ForegroundColor Yellow
}
