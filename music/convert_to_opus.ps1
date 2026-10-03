# ============================================================
# convert_to_opus.ps1
#
# Convierte archivos MP3, WAV, FLAC, M4A y OGG a OPUS de forma recursiva.
#
# Caracteristicas:
# - Busca .mp3, .wav, .flac, .m4a y .ogg en la carpeta raiz y subcarpetas
# - Guarda el .opus en la misma carpeta del archivo original
# - Conserva metadatos
# - Conserva correctamente UTF-8 (tildes, ñ, japones, etc.)
# - Conserva caratulas embebidas
# - Normaliza las caratulas a JPEG limpio
# - Usa METADATA_BLOCK_PICTURE para el artwork
# - Si el archivo de origen ya contiene Opus, copia el audio sin recodificar
# - Conserva CreationTime y LastWriteTime
# - Si una fecha no esta disponible, usa fecha/hora actual
# - Si el OPUS ya existe y es valido, lo salta
# - Si el OPUS existente no es valido, lo regenera
# - No usa archivos temporales de audio
# - Genera un log de errores
#
# Uso:
#   .\convert_to_opus.ps1
#
# La carpeta actual es la raiz por defecto.
#
# Para otra carpeta, editar:
#   $RootPath = "D:\Musica"
#
# Para cambiar bitrate:
#   $Bitrate = "128k"
# ============================================================

$Bitrate = "128k"
$RootPath = "."

$ErrorActionPreference = "Continue"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ============================================================
# EJECUTAR FFmpeg SIN GENERAR NativeCommandError FALSOS
# ============================================================

function Invoke-FFmpeg {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string[]]$IgnoreErrorPatterns = @()
    )

    $output = @(
        & ffmpeg @Arguments 2>&1 |
            ForEach-Object { $_.ToString() }
    )

    $exitCode = $LASTEXITCODE

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
        ExitCode  = $exitCode
        Output    = $visibleOutput
        AllOutput = $output
    }
}

# ============================================================
# EJECUTAR FFprobe
# ============================================================

function Invoke-FFprobe {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(
        & ffprobe @Arguments 2>&1 |
            ForEach-Object { $_.ToString() }
    )

    $exitCode = $LASTEXITCODE

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
        Text     = ($output -join "`r`n")
    }
}

# ============================================================
# ADVERTENCIA JPEG CONOCIDA
# ============================================================

$IgnoreMjpegWarning = @(
    'unable to decode APP fields:\s*Invalid data found when processing input'
)

# ============================================================
# OBTENER INFORMACION DE LA CARATULA
# ============================================================

function Get-CoverInfo {
    param (
        [string]$FilePath
    )

    $result = Invoke-FFprobe -Arguments @(
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
        $data = $result.Text | ConvertFrom-Json
    }
    catch {
        return $null
    }

    if (-not $data.streams) {
        return $null
    }

    $covers = @(
        @($data.streams) | Where-Object {
            $_.disposition -and $_.disposition.attached_pic -eq 1
        }
    )

    if ($covers.Count -eq 0) {
        return $null
    }

    return (
        $covers |
        Sort-Object @{
            Expression = {
                switch ($_.codec_name.ToLower()) {
                    "mjpeg" { 0 }
                    "jpeg"  { 0 }
                    "png"   { 1 }
                    "webp"  { 2 }
                    default { 3 }
                }
            }
        } |
        Select-Object -First 1
    )
}

# ============================================================
# OBTENER CODEC DE AUDIO
# ============================================================

function Get-AudioCodec {
    param (
        [string]$FilePath
    )

    $result = Invoke-FFprobe -Arguments @(
        "-v"
        "error"
        "-select_streams"
        "a:0"
        "-show_entries"
        "stream=codec_name"
        "-of"
        "default=nw=1:nk=1"
        $FilePath
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    return $result.Text.Trim()
}

# ============================================================
# CREAR METADATA_BLOCK_PICTURE
# ============================================================

function Write-UInt32BE {
    param (
        [System.IO.Stream]$Stream,
        [UInt32]$Value
    )

    $bytes = [BitConverter]::GetBytes($Value)

    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($bytes)
    }

    $Stream.Write($bytes, 0, 4)
}

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

    $mimeBytes = [System.Text.Encoding]::ASCII.GetBytes($MimeType)
    $descriptionBytes = [byte[]]@()
    $imageBytes = [System.IO.File]::ReadAllBytes($ImagePath)

    $memory = New-Object System.IO.MemoryStream

    try {
        Write-UInt32BE $memory $pictureType

        Write-UInt32BE $memory ([UInt32]$mimeBytes.Length)
        if ($mimeBytes.Length -gt 0) {
            $memory.Write($mimeBytes, 0, $mimeBytes.Length)
        }

        Write-UInt32BE $memory ([UInt32]$descriptionBytes.Length)
        if ($descriptionBytes.Length -gt 0) {
            $memory.Write($descriptionBytes, 0, $descriptionBytes.Length)
        }

        Write-UInt32BE $memory $Width
        Write-UInt32BE $memory $Height
        Write-UInt32BE $memory $Depth

        # Indexed colors
        Write-UInt32BE $memory 0

        # Image size
        Write-UInt32BE $memory ([UInt32]$imageBytes.Length)

        if ($imageBytes.Length -gt 0) {
            $memory.Write($imageBytes, 0, $imageBytes.Length)
        }

        return [Convert]::ToBase64String($memory.ToArray())
    }
    finally {
        $memory.Dispose()
    }
}

# ============================================================
# VALIDAR OPUS
# ============================================================

function Test-OpusFile {
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

    $result = Invoke-FFprobe -Arguments @(
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

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $false
    }

    try {
        $data = $result.Text | ConvertFrom-Json
    }
    catch {
        return $false
    }

    $streams = @($data.streams)

    if ($streams.Count -eq 0) {
        return $false
    }

    if ($streams[0].codec_name -ne "opus") {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace("$($streams[0].duration)")) {
        return $false
    }

    if ("$($streams[0].duration)" -eq "N/A") {
        return $false
    }

    try {
        if ([double]$streams[0].duration -le 0) {
            return $false
        }
    }
    catch {
        return $false
    }

    return $true
}

# ============================================================
# VALIDAR CARATULA DEL OPUS
# ============================================================

function Test-OpusCover {
    param (
        [string]$FilePath
    )

    $result = Invoke-FFprobe -Arguments @(
        "-v"
        "error"
        "-select_streams"
        "v"
        "-show_entries"
        "stream=codec_name,width,height:stream_disposition=attached_pic"
        "-of"
        "json"
        $FilePath
    )

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $false
    }

    try {
        $data = $result.Text | ConvertFrom-Json
    }
    catch {
        return $false
    }

    if (-not $data.streams) {
        return $false
    }

    return @(
        @($data.streams) | Where-Object {
            $_.disposition -and $_.disposition.attached_pic -eq 1
        }
    ).Count -gt 0
}

# ============================================================
# VERIFICAR FFMPEG / FFPROBE
# ============================================================

if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no se encontro ffmpeg.exe." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command ffprobe.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no se encontro ffprobe.exe." -ForegroundColor Red
    exit 1
}

# ============================================================
# VERIFICAR CARPETA
# ============================================================

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    Write-Host "ERROR: la carpeta no existe: $RootPath" -ForegroundColor Red
    exit 1
}

$root = (Resolve-Path -LiteralPath $RootPath).Path

# ============================================================
# LOG
# ============================================================

$logFile = Join-Path $root "convert_to_opus_errors.log"

[System.IO.File]::WriteAllText(
    $logFile,
    "",
    $Utf8NoBom
)

# ============================================================
# BUSCAR ARCHIVOS DE AUDIO RECURSIVAMENTE
# ============================================================

$files = @(
    Get-ChildItem `
        -LiteralPath $root `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -match '^\.(mp3|wav|flac|m4a|ogg)$'
        }
)

$totalFiles = $files.Count
$currentFile = 0
$converted = 0
$skipped = 0
$errors = 0

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "CONVERSOR MP3/WAV/FLAC/M4A/OGG -> OPUS" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Carpeta raiz: $root" -ForegroundColor White
Write-Host "Archivos de audio: $totalFiles" -ForegroundColor Yellow
Write-Host "Bitrate: $Bitrate" -ForegroundColor Yellow
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# PROCESAR
# ============================================================

foreach ($inputFile in $files) {

    $currentFile++

    Write-Progress `
        -Activity "Convirtiendo a OPUS" `
        -Status "$currentFile / $totalFiles" `
        -PercentComplete ([int](($currentFile / [math]::Max($totalFiles, 1)) * 100))

    $outputName = Join-Path `
        $inputFile.DirectoryName `
        "$($inputFile.BaseName).opus"

    Write-Host ""
    Write-Host "==============================================" -ForegroundColor DarkGray
    Write-Host "[$currentFile/$totalFiles]" -ForegroundColor Cyan
    Write-Host $inputFile.FullName -ForegroundColor White
    Write-Host "==============================================" -ForegroundColor DarkGray

    # ========================================================
    # SI YA EXISTE, VALIDAR ANTES DE SALTAR
    # ========================================================

    if (Test-Path -LiteralPath $outputName -PathType Leaf) {

        if (Test-OpusFile $outputName) {

            Write-Host "OPUS existente y valido. Saltando." -ForegroundColor Gray
            $skipped++
            continue
        }

        Write-Host "OPUS existente pero invalido. Se regenerara." -ForegroundColor Yellow

        Remove-Item `
            -LiteralPath $outputName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    # ========================================================
    # FECHAS
    # ========================================================

    $fallbackDate = Get-Date

    try {
        $originalCreation = $inputFile.CreationTime
        if ($null -eq $originalCreation) {
            throw "CreationTime no disponible"
        }
    }
    catch {
        $originalCreation = $fallbackDate
        Write-Host "CreationTime no disponible -> se usara fecha actual." -ForegroundColor Yellow
    }

    try {
        $originalWrite = $inputFile.LastWriteTime
        if ($null -eq $originalWrite) {
            throw "LastWriteTime no disponible"
        }
    }
    catch {
        $originalWrite = $fallbackDate
        Write-Host "LastWriteTime no disponible -> se usara fecha actual." -ForegroundColor Yellow
    }

    # ========================================================
    # TEMPORALES SOLO PARA METADATA Y CARATULA
    # ========================================================

    $tempId = [Guid]::NewGuid().ToString()

    $tempMetadata = Join-Path `
        $env:TEMP `
        "ogg_$tempId.ffmeta"

    $tempCover = Join-Path `
        $env:TEMP `
        "ogg_$tempId.jpg"

    $conversionResult = $null
    $hasCover = $false

    try {

        # ====================================================
        # DETECTAR CODEC DE AUDIO
        # ====================================================

        $audioCodec = Get-AudioCodec $inputFile.FullName

        if ([string]::IsNullOrWhiteSpace($audioCodec)) {
            throw "No se pudo detectar el codec de audio."
        }

        Write-Host "Codec de audio: $audioCodec" -ForegroundColor DarkGray

        # ====================================================
        # DETECTAR CARATULA
        # ====================================================

        $coverInfo = Get-CoverInfo $inputFile.FullName
        $hasCover = $null -ne $coverInfo

        if ($hasCover) {

            Write-Host "Caratula encontrada." -ForegroundColor Yellow
            Write-Host "  Codec: $($coverInfo.codec_name)" -ForegroundColor DarkYellow
            Write-Host "  Tamano: $($coverInfo.width)x$($coverInfo.height)" -ForegroundColor DarkYellow

            # =================================================
            # EXTRAER METADATOS COMO FFMETADATA UTF-8
            # =================================================

            Write-Host "Leyendo metadatos..." -ForegroundColor Yellow

            $metadataResult = Invoke-FFmpeg -Arguments @(
                "-hide_banner"
                "-loglevel"
                "error"
                "-nostdin"
                "-y"
                "-i"
                $inputFile.FullName
                "-map_metadata"
                "0"
                "-f"
                "ffmetadata"
                $tempMetadata
            ) -IgnoreErrorPatterns $IgnoreMjpegWarning

            if (
                $metadataResult.ExitCode -ne 0 -or
                -not (Test-Path -LiteralPath $tempMetadata -PathType Leaf)
            ) {
                throw "No se pudieron extraer los metadatos."
            }

            # =================================================
            # NORMALIZAR CARATULA
            # =================================================

            Write-Host "Procesando caratula..." -ForegroundColor Yellow

            $coverResult = Invoke-FFmpeg -Arguments @(
                "-hide_banner"
                "-loglevel"
                "error"
                "-nostdin"
                "-y"
                "-i"
                $inputFile.FullName
                "-map"
                "0:$($coverInfo.index)"
                "-frames:v"
                "1"
                "-c:v"
                "mjpeg"
                "-q:v"
                "2"
                $tempCover
            ) -IgnoreErrorPatterns $IgnoreMjpegWarning

            if (
                $coverResult.ExitCode -ne 0 -or
                -not (Test-Path -LiteralPath $tempCover -PathType Leaf)
            ) {
                throw "No se pudo extraer/normalizar la caratula."
            }

            # =================================================
            # OBTENER DIMENSIONES DE LA CARATULA LIMPIA
            # =================================================

            $normalizedResult = Invoke-FFprobe -Arguments @(
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

            if ($normalizedResult.ExitCode -ne 0) {
                throw "No se pudo analizar la caratula normalizada."
            }

            try {
                $normalizedInfo = $normalizedResult.Text | ConvertFrom-Json
            }
            catch {
                throw "No se pudo interpretar la caratula normalizada."
            }

            $normalizedStreams = @($normalizedInfo.streams)

            if ($normalizedStreams.Count -eq 0) {
                throw "La caratula normalizada no contiene una imagen valida."
            }

            $coverWidth = [UInt32]$normalizedStreams[0].width
            $coverHeight = [UInt32]$normalizedStreams[0].height

            # =================================================
            # CREAR METADATA_BLOCK_PICTURE
            # =================================================

            Write-Host "Creando METADATA_BLOCK_PICTURE..." -ForegroundColor Yellow

            $pictureBase64 = New-MetadataBlockPicture `
                -ImagePath $tempCover `
                -MimeType "image/jpeg" `
                -Width $coverWidth `
                -Height $coverHeight `
                -Depth ([UInt32]24)

            # '=' debe escaparse dentro de FFMETADATA
            $pictureBase64Escaped = $pictureBase64.Replace("=", "\=")

            # =================================================
            # MODIFICAR METADATA EN UTF-8
            # =================================================

            $metadataText = [System.IO.File]::ReadAllText(
                $tempMetadata,
                $Utf8NoBom
            )

            $metadataLines = $metadataText -split "`r?`n"

            $filteredLines = @(
                $metadataLines |
                    Where-Object {
                        $_ -notmatch '^METADATA_BLOCK_PICTURE='
                    }
            )

            $filteredLines += "METADATA_BLOCK_PICTURE=$pictureBase64Escaped"

            [System.IO.File]::WriteAllText(
                $tempMetadata,
                (($filteredLines -join "`r`n") + "`r`n"),
                $Utf8NoBom
            )

            Write-Host "Caratula preparada." -ForegroundColor Green

            # =================================================
            # CONVERSION CON CARATULA
            # =================================================

            if ($audioCodec -eq "opus") {

                Write-Host "Audio ya es Opus: copiando sin recodificar." -ForegroundColor Cyan

                $conversionResult = Invoke-FFmpeg -Arguments @(
                    "-hide_banner"
                    "-loglevel"
                    "error"
                    "-nostdin"
                    "-y"
                    "-i"
                    $inputFile.FullName
                    "-i"
                    $tempMetadata
                    "-map"
                    "0:a:0"
                    "-map_metadata"
                    "1"
                    "-map_chapters"
                    "0"
                    "-c:a"
                    "copy"
                    "-f"
                    "opus"
                    $outputName
                ) -IgnoreErrorPatterns $IgnoreMjpegWarning
            }
            else {

                Write-Host "Convirtiendo a Opus $Bitrate..." -ForegroundColor Cyan

                $conversionResult = Invoke-FFmpeg -Arguments @(
                    "-hide_banner"
                    "-loglevel"
                    "error"
                    "-nostdin"
                    "-y"
                    "-i"
                    $inputFile.FullName
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
                ) -IgnoreErrorPatterns $IgnoreMjpegWarning
            }
        }
        else {

            Write-Host "Sin caratula embebida." -ForegroundColor DarkGray

            # =================================================
            # SIN CARATULA: COPIA DIRECTA DE METADATOS
            # =================================================

            if ($audioCodec -eq "opus") {

                Write-Host "Audio ya es Opus: copiando sin recodificar." -ForegroundColor Cyan

                $conversionResult = Invoke-FFmpeg -Arguments @(
                    "-hide_banner"
                    "-loglevel"
                    "error"
                    "-nostdin"
                    "-y"
                    "-i"
                    $inputFile.FullName
                    "-map"
                    "0:a:0"
                    "-map_metadata"
                    "0"
                    "-map_chapters"
                    "0"
                    "-c:a"
                    "copy"
                    "-f"
                    "opus"
                    $outputName
                ) -IgnoreErrorPatterns $IgnoreMjpegWarning
            }
            else {

                Write-Host "Convirtiendo a Opus $Bitrate..." -ForegroundColor Cyan

                $conversionResult = Invoke-FFmpeg -Arguments @(
                    "-hide_banner"
                    "-loglevel"
                    "error"
                    "-nostdin"
                    "-y"
                    "-i"
                    $inputFile.FullName
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
                ) -IgnoreErrorPatterns $IgnoreMjpegWarning
            }
        }

        # ====================================================
        # COMPROBAR RESULTADO DE FFMPEG
        # ====================================================

        if ($null -eq $conversionResult) {
            throw "FFmpeg no devolvio ningun resultado."
        }

        if ($conversionResult.ExitCode -ne 0) {

            $detail = (
                $conversionResult.AllOutput -join "`r`n"
            ).Trim()

            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = "FFmpeg termino con codigo $($conversionResult.ExitCode)."
            }

            throw "FFmpeg fallo: $detail"
        }

        # ====================================================
        # VALIDAR OPUS
        # ====================================================

        Write-Host "Validando OPUS..." -ForegroundColor Yellow

        if (-not (Test-OpusFile $outputName)) {
            throw "El OPUS generado no paso la validacion."
        }

        # ====================================================
        # VALIDAR CARATULA
        # ====================================================

        if ($hasCover) {

            if (-not (Test-OpusCover $outputName)) {
                throw "El OPUS fue creado pero no contiene una caratula valida."
            }

            Write-Host "Caratula: OK" -ForegroundColor Green
        }

        # ====================================================
        # RESTAURAR FECHAS
        # ====================================================

        $newFile = Get-Item `
            -LiteralPath $outputName `
            -ErrorAction Stop

        try {
            $newFile.CreationTime = $originalCreation
            Write-Host "CreationTime: conservada" -ForegroundColor DarkGreen
        }
        catch {
            Write-Host "No se pudo conservar CreationTime -> usando fecha actual." -ForegroundColor Yellow

            try {
                $newFile.CreationTime = $fallbackDate
            }
            catch {
            }
        }

        try {
            $newFile.LastWriteTime = $originalWrite
            Write-Host "LastWriteTime: conservada" -ForegroundColor DarkGreen
        }
        catch {
            Write-Host "No se pudo conservar LastWriteTime -> usando fecha actual." -ForegroundColor Yellow

            try {
                $newFile.LastWriteTime = $fallbackDate
            }
            catch {
            }
        }

        # ====================================================
        # RESULTADO
        # ====================================================

        Write-Host "" 
        Write-Host "COMPLETADO:" -ForegroundColor Green
        Write-Host "  $outputName" -ForegroundColor Green

        if ($hasCover) {
            Write-Host "  Caratula: OK" -ForegroundColor Green
        }
        else {
            Write-Host "  Caratula: no existia" -ForegroundColor DarkGray
        }

        Write-Host "  Metadatos UTF-8: OK" -ForegroundColor Green

        if ($audioCodec -eq "opus") {
            Write-Host "  Audio: copia directa (ya era Opus)" -ForegroundColor Green
        }
        else {
            Write-Host "  Audio: Opus $Bitrate" -ForegroundColor Green
        }

        $converted++
    }
    catch {

        $errors++

        Write-Host "" 
        Write-Host "ERROR:" -ForegroundColor Red
        Write-Host "  $($inputFile.FullName)" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red

        $logLine =
            "[ERROR] $($inputFile.FullName) :: $($_.Exception.Message)"

        [System.IO.File]::AppendAllText(
            $logFile,
            $logLine + "`r`n",
            $Utf8NoBom
        )

        # Eliminar OPUS incompleto/incorrecto
        if (Test-Path -LiteralPath $outputName -PathType Leaf) {

            Remove-Item `
                -LiteralPath $outputName `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    finally {

        # ====================================================
        # LIMPIAR TEMPORALES
        # ====================================================

        @(
            $tempMetadata
            $tempCover
        ) |
        ForEach-Object {

            if (
                $_ -and
                (Test-Path -LiteralPath $_)
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
# TERMINAR PROGRESS
# ============================================================

Write-Progress `
    -Activity "Convirtiendo a OPUS" `
    -Completed

# ============================================================
# RESUMEN
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "PROCESO FINALIZADO" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Carpeta raiz : $root" -ForegroundColor White
Write-Host "Encontrados  : $totalFiles" -ForegroundColor White
Write-Host "Convertidos  : $converted" -ForegroundColor Green
Write-Host "Saltados     : $skipped" -ForegroundColor Yellow
Write-Host "Errores      : $errors" -ForegroundColor Red
Write-Host ""

if ($errors -eq 0) {
    Write-Host "Todas las conversiones terminaron correctamente." -ForegroundColor Green
}
else {
    Write-Host "Hay archivos con errores. Revisa:" -ForegroundColor Yellow
    Write-Host $logFile -ForegroundColor White
}

Write-Host ""
