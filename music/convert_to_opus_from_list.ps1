# ============================================================
# convert_to_opus_from_list.ps1
#
# Convierte canciones de una playlist M3U/M3U8 a OPUS.
#
# Soporta:
#   MP3 / WAV / FLAC / M4A
#
# CARACTERÍSTICAS
# ------------------------------------------------------------
# - Lee la playlist como UTF-8
# - Soporta rutas con japonés, chino, ñ, tildes, etc.
# - Ignora #EXTM3U, #EXTINF y comentarios
# - Soporta rutas absolutas y relativas
# - Guarda el OPUS en la misma carpeta del original
# - NO usa archivos .tmp.opus
# - Valida los OPUS existentes antes de saltarlos
# - Detecta OPUS incompletos/corruptos
# - Conserva metadatos
# - Conserva UTF-8 correctamente
# - Conserva carátulas
# - M4A: normaliza carátulas JPEG problemáticas
# - Usa METADATA_BLOCK_PICTURE
# - Conserva CreationTime y LastWriteTime
# - Si una fecha no puede obtenerse, usa fecha actual
# - Genera log de archivos faltantes y errores
# - Diseñado para playlists grandes
#
# USO
# ------------------------------------------------------------
#
# .\convert_to_opus_from_list.ps1 ".\Asian.m3u8"
#
# También:
#
# .\convert_to_opus_from_list.ps1 `
#     ".\Asian.m3u8" `
#     -Bitrate "128k"
#
# ============================================================

param (
    [Parameter(
        Mandatory = $true,
        Position = 0
    )]
    [string]$PlaylistPath,

    [string]$Bitrate = "128k"
)

# ============================================================
# CONFIGURACIÓN
# ============================================================

$ErrorActionPreference = "Continue"

$Utf8NoBom =
    New-Object System.Text.UTF8Encoding($false)

# Esta advertencia de JPEG/MJPEG puede aparecer en algunas
# carátulas. No se considera un error si FFmpeg logra continuar.
$IgnoreMjpegWarning = @(
    'unable to decode APP fields:\s*Invalid data found when processing input'
)

# ============================================================
# FUNCIÓN: EJECUTAR FFMPEG
# ============================================================

function Invoke-FFmpeg {

    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string[]]$IgnoreErrorPatterns = @()
    )

    $output = @(
        & ffmpeg @Arguments 2>&1 |
            ForEach-Object {
                $_.ToString()
            }
    )

    $exitCode = $LASTEXITCODE

    # --------------------------------------------------------
    # Filtrar solamente mensajes conocidos
    # --------------------------------------------------------

    $visibleOutput = @(
        $output | Where-Object {

            $line = $_
            $ignore = $false

            foreach ($pattern in $IgnoreErrorPatterns) {

                if ($line -match $pattern) {
                    $ignore = $true
                    break
                }
            }

            -not $ignore
        }
    )

    return [PSCustomObject]@{
        ExitCode     = $exitCode
        Output       = $visibleOutput
        AllOutput    = $output
    }
}

# ============================================================
# FUNCIÓN: EJECUTAR FFPROBE
# ============================================================

function Invoke-FFprobe {

    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(
        & ffprobe @Arguments 2>&1 |
            ForEach-Object {
                $_.ToString()
            }
    )

    $exitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
        Text     = ($output -join "`r`n")
    }
}

# ============================================================
# FUNCIÓN: OBTENER INFORMACIÓN DE CARÁTULA
# ============================================================

function Get-CoverInfo {

    param (
        [string]$FilePath
    )

    $result =
        Invoke-FFprobe `
            -Arguments @(
                "-v"
                "error"
                "-select_streams"
                "v"
                "-show_entries"
                "stream=index,codec_name,width,height,pix_fmt:stream_disposition=attached_pic"
                "-of"
                "json"
                $FilePath
            )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    try {

        $data =
            $result.Text |
            ConvertFrom-Json
    }
    catch {

        return $null
    }

    if (-not $data.streams) {
        return $null
    }

    $streams = @(
        $data.streams
    )

    $covers = @(
        $streams | Where-Object {

            $_.disposition -and
            $_.disposition.attached_pic -eq 1
        }
    )

    if ($covers.Count -eq 0) {
        return $null
    }

    return (
        $covers |
        Sort-Object @{
            Expression = {

                switch (
                    $_.codec_name.ToLower()
                ) {

                    "mjpeg" { 0 }
                    "jpeg"  { 0 }
                    "png"   { 1 }
                    "webp"  { 2 }

                    default {
                        3
                    }
                }
            }
        } |
        Select-Object -First 1
    )
}

# ============================================================
# FUNCIÓN: MIME
# ============================================================

function Get-MimeType {

    param (
        [string]$Codec
    )

    switch ($Codec.ToLower()) {

        "mjpeg" {
            return "image/jpeg"
        }

        "jpeg" {
            return "image/jpeg"
        }

        "png" {
            return "image/png"
        }

        "webp" {
            return "image/webp"
        }

        "bmp" {
            return "image/bmp"
        }

        "tiff" {
            return "image/tiff"
        }

        default {
            return "application/octet-stream"
        }
    }
}

# ============================================================
# FUNCIÓN: EXTENSIÓN DE CARÁTULA
# ============================================================

function Get-CoverExtension {

    param (
        [string]$Codec
    )

    switch ($Codec.ToLower()) {

        "mjpeg" {
            return ".jpg"
        }

        "jpeg" {
            return ".jpg"
        }

        "png" {
            return ".png"
        }

        "webp" {
            return ".webp"
        }

        "bmp" {
            return ".bmp"
        }

        "tiff" {
            return ".tiff"
        }

        default {
            return ".img"
        }
    }
}

# ============================================================
# FUNCIÓN: ESCRIBIR UINT32 BIG-ENDIAN
# ============================================================

function Write-UInt32BE {

    param (
        [System.IO.Stream]$Stream,
        [UInt32]$Value
    )

    $bytes =
        [BitConverter]::GetBytes($Value)

    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }

    $Stream.Write(
        $bytes,
        0,
        4
    )
}

# ============================================================
# FUNCIÓN:
# CREAR METADATA_BLOCK_PICTURE
# ============================================================

function New-MetadataBlockPicture {

    param (
        [string]$ImagePath,

        [string]$MimeType,

        [UInt32]$Width,

        [UInt32]$Height,

        [UInt32]$Depth = 24
    )

    # 3 = Cover (front)
    $pictureType = [UInt32]3

    $mimeBytes =
        [System.Text.Encoding]::ASCII.GetBytes(
            $MimeType
        )

    $descriptionBytes =
        [byte[]]@()

    $imageBytes =
        [System.IO.File]::ReadAllBytes(
            $ImagePath
        )

    $memory =
        New-Object System.IO.MemoryStream

    try {

        # Picture type
        Write-UInt32BE `
            $memory `
            $pictureType

        # MIME length
        Write-UInt32BE `
            $memory `
            ([UInt32]$mimeBytes.Length)

        # MIME
        if ($mimeBytes.Length -gt 0) {

            $memory.Write(
                $mimeBytes,
                0,
                $mimeBytes.Length
            )
        }

        # Description length
        Write-UInt32BE `
            $memory `
            ([UInt32]$descriptionBytes.Length)

        # Description
        if ($descriptionBytes.Length -gt 0) {

            $memory.Write(
                $descriptionBytes,
                0,
                $descriptionBytes.Length
            )
        }

        # Width
        Write-UInt32BE `
            $memory `
            $Width

        # Height
        Write-UInt32BE `
            $memory `
            $Height

        # Bits per pixel
        Write-UInt32BE `
            $memory `
            $Depth

        # Indexed colors
        Write-UInt32BE `
            $memory `
            0

        # Image size
        Write-UInt32BE `
            $memory `
            ([UInt32]$imageBytes.Length)

        # Image
        if ($imageBytes.Length -gt 0) {

            $memory.Write(
                $imageBytes,
                0,
                $imageBytes.Length
            )
        }

        $rawBlock =
            $memory.ToArray()

        return [Convert]::ToBase64String(
            $rawBlock
        )
    }
    finally {

        $memory.Dispose()
    }
}

# ============================================================
# FUNCIÓN:
# VALIDAR OPUS
# ============================================================

function Test-OpusFile {

    param (
        [string]$FilePath
    )

    # --------------------------------------------------------
    # Comprobar existencia
    # --------------------------------------------------------

    if (
        -not (
            Test-Path `
                -LiteralPath $FilePath `
                -PathType Leaf
        )
    ) {

        return $false
    }

    # --------------------------------------------------------
    # Comprobar tamaño
    # --------------------------------------------------------

    try {

        $file =
            Get-Item `
                -LiteralPath $FilePath `
                -ErrorAction Stop

        if ($file.Length -le 0) {
            return $false
        }
    }
    catch {

        return $false
    }

    # --------------------------------------------------------
    # FFprobe
    # --------------------------------------------------------

    $result =
        Invoke-FFprobe `
            -Arguments @(
                "-v"
                "error"
                "-select_streams"
                "a:0"
                "-show_entries"
                "stream=codec_name,duration"
                "-of"
                "json"
                $FilePath
            )

    if ($result.ExitCode -ne 0) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $false
    }

    try {

        $data =
            $result.Text |
            ConvertFrom-Json
    }
    catch {

        return $false
    }

    if (-not $data.streams) {
        return $false
    }

    $streams = @(
        $data.streams
    )

    if ($streams.Count -eq 0) {
        return $false
    }

    if ($streams[0].codec_name -ne "opus") {
        return $false
    }

    $duration =
        $streams[0].duration

    if (
        [string]::IsNullOrWhiteSpace(
            "$duration"
        )
    ) {

        return $false
    }

    if (
        "$duration" -eq "N/A"
    ) {

        return $false
    }

    try {

        $durationValue =
            [double]$duration

        if ($durationValue -le 0) {
            return $false
        }
    }
    catch {

        return $false
    }

    return $true
}

# ============================================================
# FUNCIÓN:
# COMPROBAR CARÁTULA DEL OPUS
# ============================================================

function Test-OpusCover {

    param (
        [string]$FilePath
    )

    # ========================================================
    # La portada de un Ogg/Opus puede aparecer como un stream
    # de imagen con DISPOSITION:attached_pic=1.
    #
    # No debemos buscar únicamente:
    #     format_tags=METADATA_BLOCK_PICTURE
    #
    # porque FFmpeg puede materializar METADATA_BLOCK_PICTURE
    # como un stream attached_pic.
    # ========================================================

    $result =
        Invoke-FFprobe `
            -Arguments @(
                "-v"
                "error"
                "-select_streams"
                "v"
                "-show_entries"
                "stream=index,codec_name,width,height:stream_disposition=attached_pic"
                "-of"
                "json"
                $FilePath
            )

    if ($result.ExitCode -ne 0) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return $false
    }

    try {

        $data =
            $result.Text |
            ConvertFrom-Json
    }
    catch {

        return $false
    }

    if (-not $data.streams) {
        return $false
    }

    $streams = @(
        $data.streams
    )

    # Buscar una imagen marcada como attached_pic
    $coverStreams = @(
        $streams | Where-Object {

            $_.disposition -and
            $_.disposition.attached_pic -eq 1
        }
    )

    if ($coverStreams.Count -gt 0) {
        return $true
    }

    return $false
}

# ============================================================
# VERIFICAR FFMPEG
# ============================================================

if (-not (
    Get-Command `
        ffmpeg.exe `
        -ErrorAction SilentlyContinue
)) {

    Write-Host `
        "ERROR: No se encontró ffmpeg.exe." `
        -ForegroundColor Red

    exit 1
}

# ============================================================
# VERIFICAR FFPROBE
# ============================================================

if (-not (
    Get-Command `
        ffprobe.exe `
        -ErrorAction SilentlyContinue
)) {

    Write-Host `
        "ERROR: No se encontró ffprobe.exe." `
        -ForegroundColor Red

    exit 1
}

# ============================================================
# VERIFICAR PLAYLIST
# ============================================================

if (-not (
    Test-Path `
        -LiteralPath $PlaylistPath `
        -PathType Leaf
)) {

    Write-Host `
        "ERROR: No existe la playlist:" `
        -ForegroundColor Red

    Write-Host `
        $PlaylistPath `
        -ForegroundColor Red

    exit 1
}

$playlistFullPath =
    (
        Resolve-Path `
            -LiteralPath $PlaylistPath
    ).Path

$playlistDirectory =
    Split-Path `
        -Parent `
        $playlistFullPath

# ============================================================
# LOG
# ============================================================

$logFile =
    Join-Path `
        $playlistDirectory `
        "convert_to_opus_errors.log"

[System.IO.File]::WriteAllText(
    $logFile,
    "",
    $Utf8NoBom
)

# ============================================================
# LEER PLAYLIST COMO UTF-8
# ============================================================

try {

    $playlistText =
        [System.IO.File]::ReadAllText(
            $playlistFullPath,
            $Utf8NoBom
        )
}
catch {

    Write-Host `
        "ERROR: No se pudo leer la playlist." `
        -ForegroundColor Red

    Write-Host `
        $_.Exception.Message `
        -ForegroundColor Red

    exit 1
}

# ============================================================
# EXTRAER RUTAS
# ============================================================

$playlistLines =
    $playlistText -split "`r?`n"

$tracks =
    New-Object `
        System.Collections.Generic.List[string]

foreach ($lineRaw in $playlistLines) {

    $line =
        $lineRaw.Trim()

    # Vacía
    if (
        [string]::IsNullOrWhiteSpace(
            $line
        )
    ) {

        continue
    }

    # #EXTM3U / #EXTINF / etc.
    if (
        $line.StartsWith("#")
    ) {

        continue
    }

    # Quitar comillas externas
    if (
        $line.Length -ge 2 -and
        $line.StartsWith('"') -and
        $line.EndsWith('"')
    ) {

        $line =
            $line.Substring(
                1,
                $line.Length - 2
            )
    }

    if (
        [string]::IsNullOrWhiteSpace(
            $line
        )
    ) {

        continue
    }

    [void]$tracks.Add($line)
}

# ============================================================
# CONTADORES
# ============================================================

$totalTracks =
    $tracks.Count

$currentTrack = 0

$converted = 0
$skipped   = 0
$missing   = 0
$repaired  = 0
$errors    = 0

# ============================================================
# ENCABEZADO
# ============================================================

Write-Host ""
Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "CONVERSION DESDE PLAYLIST" `
    -ForegroundColor Cyan

Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "Playlist:" `
    -ForegroundColor Yellow

Write-Host `
    $playlistFullPath `
    -ForegroundColor White

Write-Host ""

Write-Host `
    "Canciones encontradas: $totalTracks" `
    -ForegroundColor Yellow

Write-Host `
    "Bitrate: $Bitrate" `
    -ForegroundColor Yellow

Write-Host ""

# ============================================================
# PROCESAR
# ============================================================

foreach ($playlistEntry in $tracks) {

    $currentTrack++

    # --------------------------------------------------------
    # PROGRESS
    # --------------------------------------------------------

    Write-Progress `
        -Activity "Convirtiendo canciones" `
        -Status "$currentTrack / $totalTracks" `
        -PercentComplete (
            [int](
                (
                    $currentTrack /
                    $totalTracks
                ) * 100
            )
        )

    # ========================================================
    # RESOLVER RUTA
    # ========================================================

    $sourcePath =
        $playlistEntry

    # file:///
    if (
        $sourcePath.StartsWith(
            "file:///",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {

        try {

            $uri =
                [System.Uri]$sourcePath

            $sourcePath =
                $uri.LocalPath
        }
        catch {
        }
    }

    # Absoluta / relativa
    if (
        [System.IO.Path]::IsPathRooted(
            $sourcePath
        )
    ) {

        $resolvedSource =
            $sourcePath
    }
    else {

        $resolvedSource =
            Join-Path `
                $playlistDirectory `
                $sourcePath
    }

    # ========================================================
    # RESOLVER ARCHIVO
    # ========================================================

    try {

        $resolvedSource =
            (
                Resolve-Path `
                    -LiteralPath $resolvedSource `
                    -ErrorAction Stop
            ).Path
    }
    catch {

        $missing++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[MISSING] $sourcePath`r`n",
            $Utf8NoBom
        )

        Write-Host ""
        Write-Host `
            "NO ENCONTRADO:" `
            -ForegroundColor Red

        Write-Host `
            $sourcePath `
            -ForegroundColor Red

        continue
    }

    # ========================================================
    # EXTENSION
    # ========================================================

    $extension =
        [System.IO.Path]::GetExtension(
            $resolvedSource
        ).ToLowerInvariant()

    if (
        $extension -notin @(
            ".mp3",
            ".wav",
            ".flac",
            ".m4a"
        )
    ) {

        $errors++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[UNSUPPORTED] $resolvedSource`r`n",
            $Utf8NoBom
        )

        continue
    }

    # ========================================================
    # OUTPUT
    # ========================================================

    $sourceDirectory =
        Split-Path `
            -Parent `
            $resolvedSource

    $sourceBaseName =
        [System.IO.Path]::GetFileNameWithoutExtension(
            $resolvedSource
        )

    $outputName =
        Join-Path `
            $sourceDirectory `
            "$sourceBaseName.opus"

    # ========================================================
    # OPUS YA EXISTENTE
    # ========================================================

    if (
        Test-Path `
            -LiteralPath $outputName `
            -PathType Leaf
    ) {

        Write-Host ""
        Write-Host `
            "[$currentTrack/$totalTracks] OPUS existente, verificando..." `
            -ForegroundColor Gray

        # ----------------------------------------------------
        # NO confiar solo en que exista.
        # ----------------------------------------------------

        if (
            Test-OpusFile `
                $outputName
        ) {

            # Verificar carátula solamente si el original
            # tiene una.
            $existingCoverInfo =
                Get-CoverInfo `
                    $resolvedSource

            if (
                $null -eq $existingCoverInfo
            ) {

                Write-Host `
                    "   OK - Opus válido" `
                    -ForegroundColor DarkGreen

                $skipped++

                continue
            }

            if (
                Test-OpusCover `
                    $outputName
            ) {

                Write-Host `
                    "   OK - Opus y carátula válidos" `
                    -ForegroundColor DarkGreen

                $skipped++

                continue
            }

            Write-Host `
                "   El Opus existe pero no tiene carátula. Se regenerará." `
                -ForegroundColor Yellow
        }
        else {

            Write-Host `
                "   El Opus existente no es válido. Se regenerará." `
                -ForegroundColor Yellow
        }

        # ----------------------------------------------------
        # Borrar salida inválida
        # ----------------------------------------------------

        try {

            Remove-Item `
                -LiteralPath $outputName `
                -Force `
                -ErrorAction Stop

            $repaired++
        }
        catch {

            $errors++

            [System.IO.File]::AppendAllText(
                $logFile,
                "[DELETE_FAILED] $outputName :: $($_.Exception.Message)`r`n",
                $Utf8NoBom
            )

            continue
        }
    }

    # ========================================================
    # FECHAS
    # ========================================================

    $fallbackDate =
        Get-Date

    try {

        $sourceFile =
            Get-Item `
                -LiteralPath $resolvedSource `
                -ErrorAction Stop
    }
    catch {

        $errors++

        [System.IO.File]::AppendAllText(
            $logFile,
            "[FILEINFO_ERROR] $resolvedSource :: $($_.Exception.Message)`r`n",
            $Utf8NoBom
        )

        continue
    }

    try {

        $originalCreation =
            $sourceFile.CreationTime

        if ($null -eq $originalCreation) {
            throw
        }
    }
    catch {

        $originalCreation =
            $fallbackDate

        Write-Host `
            "   CreationTime no disponible -> fecha actual" `
            -ForegroundColor Yellow
    }

    try {

        $originalWrite =
            $sourceFile.LastWriteTime

        if ($null -eq $originalWrite) {
            throw
        }
    }
    catch {

        $originalWrite =
            $fallbackDate

        Write-Host `
            "   LastWriteTime no disponible -> fecha actual" `
            -ForegroundColor Yellow
    }

    # ========================================================
    # ARCHIVOS TEMPORALES
    # ========================================================
    #
    # SOLO para:
    # - ffmetadata
    # - carátula
    #
    # NO existe ningún .tmp.opus.
    #
    # ========================================================

    $tempId =
        [Guid]::NewGuid().ToString()

    $tempMetadata =
        Join-Path `
            $env:TEMP `
            "opus_$tempId.ffmeta"

    $tempCover =
        Join-Path `
            $env:TEMP `
            "opus_$tempId.jpg"

    # ========================================================
    # ENCABEZADO DE CANCIÓN
    # ========================================================

    Write-Host ""
    Write-Host "==============================================" `
        -ForegroundColor DarkGray

    Write-Host `
        "[$currentTrack/$totalTracks]" `
        -ForegroundColor Cyan

    Write-Host `
        $resolvedSource `
        -ForegroundColor White

    Write-Host "==============================================" `
        -ForegroundColor DarkGray

    try {

        # ====================================================
        # DETECTAR CARÁTULA
        # ====================================================

        $coverInfo =
            Get-CoverInfo `
                $resolvedSource

        $hasCover =
            $null -ne $coverInfo

        # ====================================================
        # CASO A:
        # SIN CARÁTULA
        # ====================================================

        if (-not $hasCover) {

            Write-Host `
                "Sin carátula embebida." `
                -ForegroundColor DarkGray

            Write-Host `
                "Metadatos: copia directa." `
                -ForegroundColor DarkGray

            Write-Host `
                "Convirtiendo a Opus $Bitrate..." `
                -ForegroundColor Cyan

            # ------------------------------------------------
            # IMPORTANTE:
            # Escribimos DIRECTAMENTE al output definitivo.
            # ------------------------------------------------

            $conversionResult =
                Invoke-FFmpeg `
                    -Arguments @(
                        "-hide_banner"
                        "-loglevel"
                        "error"
                        "-nostdin"
                        "-y"

                        "-i"
                        $resolvedSource

                        "-map"
                        "0:a:0"

                        "-map_metadata"
                        "0"

                        "-map_chapters"
                        "0"

                        "-c:a"
                        "libopus"

                        "-b:a"
                        $Bitrate

                        "-f"
                        "opus"

                        $outputName
                    ) `
                    -IgnoreErrorPatterns $IgnoreMjpegWarning
        }

        # ====================================================
        # CASO B:
        # CON CARÁTULA
        # ====================================================

        else {

            Write-Host `
                "Carátula encontrada." `
                -ForegroundColor Yellow

            Write-Host `
                "  Codec: $($coverInfo.codec_name)" `
                -ForegroundColor DarkYellow

            Write-Host `
                "  Tamaño: $($coverInfo.width)x$($coverInfo.height)" `
                -ForegroundColor DarkYellow

            # =================================================
            # EXTRAER METADATOS
            # =================================================

            Write-Host `
                "Leyendo metadatos..." `
                -ForegroundColor Yellow

            $metadataResult =
                Invoke-FFmpeg `
                    -Arguments @(
                        "-hide_banner"
                        "-loglevel"
                        "error"
                        "-nostdin"
                        "-y"

                        "-i"
                        $resolvedSource

                        "-map_metadata"
                        "0"

                        "-f"
                        "ffmetadata"

                        $tempMetadata
                    ) `
                    -IgnoreErrorPatterns $IgnoreMjpegWarning

            if (
                $metadataResult.ExitCode -ne 0 -or
                -not (
                    Test-Path `
                        -LiteralPath $tempMetadata `
                        -PathType Leaf
                )
            ) {

                $detail =
                    (
                        $metadataResult.AllOutput -join "`r`n"
                    ).Trim()

                if (
                    [string]::IsNullOrWhiteSpace(
                        $detail
                    )
                ) {

                    $detail =
                        "No se obtuvo detalle de FFmpeg."
                }

                throw `
                    "No se pudieron extraer los metadatos. $detail"
            }

            # =================================================
            # NORMALIZAR CARÁTULA
            # =================================================

            Write-Host `
                "Procesando carátula..." `
                -ForegroundColor Yellow

            # Para M4A:
            # siempre limpiar/normalizar la portada.
            #
            # Para otros formatos:
            # también usamos JPEG limpio para evitar problemas
            # con JPEG/MJPEG dañados.
            #

            $coverResult =
                Invoke-FFmpeg `
                    -Arguments @(
                        "-hide_banner"
                        "-loglevel"
                        "error"
                        "-nostdin"
                        "-y"

                        "-i"
                        $resolvedSource

                        "-map"
                        "0:$($coverInfo.index)"

                        "-frames:v"
                        "1"

                        "-c:v"
                        "mjpeg"

                        "-q:v"
                        "2"

                        $tempCover
                    ) `
                    -IgnoreErrorPatterns $IgnoreMjpegWarning

            if (
                $coverResult.ExitCode -ne 0 -or
                -not (
                    Test-Path `
                        -LiteralPath $tempCover `
                        -PathType Leaf
                )
            ) {

                $detail =
                    (
                        $coverResult.AllOutput -join "`r`n"
                    ).Trim()

                if (
                    [string]::IsNullOrWhiteSpace(
                        $detail
                    )
                ) {

                    $detail =
                        "No se obtuvo detalle de FFmpeg."
                }

                throw `
                    "No se pudo procesar la carátula. $detail"
            }

            # =================================================
            # OBTENER DIMENSIONES
            # =================================================

            $coverProbe =
                Invoke-FFprobe `
                    -Arguments @(
                        "-v"
                        "error"
                        "-select_streams"
                        "v:0"
                        "-show_entries"
                        "stream=width,height"
                        "-of"
                        "json"
                        $tempCover
                    )

            if (
                $coverProbe.ExitCode -ne 0
            ) {

                throw `
                    "No se pudo analizar la carátula."
            }

            try {

                $coverData =
                    $coverProbe.Text |
                    ConvertFrom-Json
            }
            catch {

                throw `
                    "No se pudo interpretar la carátula."
            }

            $coverStreams = @(
                $coverData.streams
            )

            if (
                $coverStreams.Count -eq 0
            ) {

                throw `
                    "La carátula no contiene una imagen válida."
            }

            $coverStream =
                $coverStreams[0]

            $coverWidth =
                [UInt32]$coverStream.width

            $coverHeight =
                [UInt32]$coverStream.height

            # =================================================
            # CREAR METADATA_BLOCK_PICTURE
            # =================================================

            Write-Host `
                "Creando METADATA_BLOCK_PICTURE..." `
                -ForegroundColor Yellow

            $pictureBase64 =
                New-MetadataBlockPicture `
                    -ImagePath $tempCover `
                    -MimeType "image/jpeg" `
                    -Width $coverWidth `
                    -Height $coverHeight `
                    -Depth ([UInt32]24)

            # "=" es especial dentro de FFMETADATA.
            $pictureBase64Escaped =
                $pictureBase64.Replace(
                    "=",
                    "\="
                )

            # =================================================
            # LEER FFMETADATA COMO UTF-8
            # =================================================

            $metadataText =
                [System.IO.File]::ReadAllText(
                    $tempMetadata,
                    $Utf8NoBom
                )

            $metadataLines =
                $metadataText -split "`r?`n"

            # Eliminar cualquier picture anterior
            $filteredLines = @(
                $metadataLines |
                    Where-Object {
                        $_ -notmatch '^METADATA_BLOCK_PICTURE='
                    }
            )

            # Agregar portada
            $filteredLines +=
                "METADATA_BLOCK_PICTURE=$pictureBase64Escaped"

            # =================================================
            # ESCRIBIR UTF-8 SIN BOM
            # =================================================

            [System.IO.File]::WriteAllText(
                $tempMetadata,
                (
                    $filteredLines -join "`r`n"
                ) + "`r`n",
                $Utf8NoBom
            )

            Write-Host `
                "Carátula preparada." `
                -ForegroundColor Green

            # =================================================
            # CONVERTIR DIRECTAMENTE AL OUTPUT DEFINITIVO
            # =================================================

            Write-Host `
                "Convirtiendo a Opus $Bitrate..." `
                -ForegroundColor Cyan

            $conversionResult =
                Invoke-FFmpeg `
                    -Arguments @(
                        "-hide_banner"
                        "-loglevel"
                        "error"
                        "-nostdin"
                        "-y"

                        "-i"
                        $resolvedSource

                        "-i"
                        $tempMetadata

                        "-map"
                        "0:a:0"

                        "-map_metadata"
                        "1"

                        "-map_chapters"
                        "0"

                        "-c:a"
                        "libopus"

                        "-b:a"
                        $Bitrate

                        "-f"
                        "opus"

                        $outputName
                    ) `
                    -IgnoreErrorPatterns $IgnoreMjpegWarning
        }

        # ====================================================
        # COMPROBAR EXIT CODE
        # ====================================================

        if (
            $null -eq $conversionResult
        ) {

            throw `
                "FFmpeg no devolvió ningún resultado."
        }

        if (
            $conversionResult.ExitCode -ne 0
        ) {

            $detail =
                (
                    $conversionResult.AllOutput -join "`r`n"
                ).Trim()

            if (
                [string]::IsNullOrWhiteSpace(
                    $detail
                )
            ) {

                $detail =
                    "FFmpeg terminó con código $($conversionResult.ExitCode)."
            }

            throw `
                "FFmpeg falló. $detail"
        }

        # ====================================================
        # VALIDAR OUTPUT
        # ====================================================
        #
        # Aquí está la diferencia importante:
        #
        # NO buscamos un archivo temporal.
        #
        # Validamos directamente:
        #
        #     archivo.opus
        #
        # ====================================================

        Write-Host `
            "Validando OPUS..." `
            -ForegroundColor Yellow

        if (
            -not (
                Test-OpusFile `
                    $outputName
            )
        ) {

            throw `
                "FFmpeg terminó, pero el OPUS generado no pasó la validación."
        }

        # ====================================================
        # VALIDAR CARÁTULA
        # ====================================================

        if ($hasCover) {

            if (
                -not (
                    Test-OpusCover `
                        $outputName
                )
            ) {

                throw `
                    "El OPUS fue creado correctamente, pero no contiene METADATA_BLOCK_PICTURE."
            }

            Write-Host `
                "Carátula: OK" `
                -ForegroundColor Green
        }

        # ====================================================
        # RESTAURAR CREATION TIME
        # ====================================================

        $newFile =
            Get-Item `
                -LiteralPath $outputName `
                -ErrorAction Stop

        try {

            $newFile.CreationTime =
                $originalCreation

            Write-Host `
                "CreationTime: conservada" `
                -ForegroundColor DarkGreen
        }
        catch {

            Write-Host `
                "CreationTime no pudo conservarse -> usando fecha actual." `
                -ForegroundColor Yellow

            try {

                $newFile.CreationTime =
                    $fallbackDate
            }
            catch {
            }
        }

        # ====================================================
        # RESTAURAR LAST WRITE TIME
        # ====================================================

        try {

            $newFile.LastWriteTime =
                $originalWrite

            Write-Host `
                "LastWriteTime: conservada" `
                -ForegroundColor DarkGreen
        }
        catch {

            Write-Host `
                "LastWriteTime no pudo conservarse -> usando fecha actual." `
                -ForegroundColor Yellow

            try {

                $newFile.LastWriteTime =
                    $fallbackDate
            }
            catch {
            }
        }

        # ====================================================
        # RESULTADO
        # ====================================================

        Write-Host ""
        Write-Host `
            "COMPLETADO" `
            -ForegroundColor Green

        Write-Host `
            $outputName `
            -ForegroundColor Green

        Write-Host `
            "Metadatos UTF-8: OK" `
            -ForegroundColor Green

        Write-Host `
            "Bitrate: $Bitrate" `
            -ForegroundColor Green

        $converted++
    }
    catch {

        $errors++

        Write-Host ""
        Write-Host `
            "ERROR" `
            -ForegroundColor Red

        Write-Host `
            $resolvedSource `
            -ForegroundColor Red

        Write-Host `
            $_.Exception.Message `
            -ForegroundColor Red

        # ====================================================
        # LOG
        # ====================================================

        [System.IO.File]::AppendAllText(
            $logFile,
            "[ERROR] $resolvedSource :: $($_.Exception.Message)`r`n",
            $Utf8NoBom
        )

        # ====================================================
        # IMPORTANTE:
        # Si el OPUS definitivo quedó inválido,
        # eliminarlo.
        # ====================================================

        if (
            Test-Path `
                -LiteralPath $outputName `
                -PathType Leaf
        ) {

            if (
                -not (
                    Test-OpusFile `
                        $outputName
                )
            ) {

                Remove-Item `
                    -LiteralPath $outputName `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    finally {

        # ====================================================
        # LIMPIAR SOLO TEMPORALES AUXILIARES
        # ====================================================

        @(
            $tempMetadata
            $tempCover
        ) |
        ForEach-Object {

            if (
                $_ -and
                (
                    Test-Path `
                        -LiteralPath $_
                )
            ) {

                Remove-Item `
                    -LiteralPath $_ `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}

# ============================================================
# FINALIZAR PROGRESS
# ============================================================

Write-Progress `
    -Activity "Convirtiendo canciones" `
    -Completed

# ============================================================
# RESUMEN
# ============================================================

Write-Host ""
Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "PROCESO FINALIZADO" `
    -ForegroundColor Cyan

Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "Playlist       : $playlistFullPath" `
    -ForegroundColor White

Write-Host `
    "Canciones      : $totalTracks" `
    -ForegroundColor White

Write-Host `
    "Convertidos    : $converted" `
    -ForegroundColor Green

Write-Host `
    "Ya existentes  : $skipped" `
    -ForegroundColor Yellow

Write-Host `
    "Reparados      : $repaired" `
    -ForegroundColor Yellow

Write-Host `
    "No encontrados : $missing" `
    -ForegroundColor Yellow

Write-Host `
    "Errores        : $errors" `
    -ForegroundColor Red

Write-Host ""

if (
    $errors -eq 0 -and
    $missing -eq 0
) {

    Write-Host `
        "Todas las canciones se procesaron correctamente." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Hay elementos que requieren revisión." `
        -ForegroundColor Yellow

    Write-Host `
        "Log: $logFile" `
        -ForegroundColor White
}

Write-Host ""