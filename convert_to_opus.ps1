# ============================================================
# CONVERSOR RECURSIVO:
# MP3 / WAV / FLAC / M4A → OPUS
#
# Características:
# - Busca en todas las subcarpetas
# - Conserva metadatos
# - Conserva UTF-8: á é í ó ú ñ ü
# - Conserva carátulas
# - Convierte carátulas APIC/attached_pic a
#   METADATA_BLOCK_PICTURE
# - Normaliza las portadas JPEG problemáticas
# - Evita NativeCommandError de PowerShell
# - Conserva fechas originales
# - Si una fecha no está disponible, usa fecha/hora actual
# - Salta archivos OPUS que ya existen
# - Mantiene la estructura de carpetas
# ============================================================

$Bitrate = "128k"

# ============================================================
# CARPETA RAÍZ
# ============================================================
#
# "." = carpeta donde se ejecuta el script
#
# Ejemplo:
#
# $RootPath = "D:\Musica"
#
# ============================================================

$RootPath = "."

# ============================================================
# EJECUTAR FFmpeg / FFprobe SIN USAR 2>
# ============================================================
#
# Esto evita que PowerShell convierta stderr de aplicaciones
# nativas en NativeCommandError / RemoteException.
#
# ============================================================

function Quote-WindowsArgument {
    param (
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -eq 0) {
        return '""'
    }

    # Si no contiene espacios, tabs ni comillas,
    # no necesita comillas.
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.Append('"')

    $backslashes = 0

    foreach ($char in $Argument.ToCharArray()) {

        if ($char -eq '\') {

            $backslashes++

            continue
        }

        if ($char -eq '"') {

            # Los backslashes antes de una comilla
            # deben duplicarse y agregar uno adicional.
            for ($i = 0; $i -lt ($backslashes * 2 + 1); $i++) {
                [void]$sb.Append('\')
            }

            [void]$sb.Append('"')

            $backslashes = 0

            continue
        }

        # Escribir backslashes acumulados
        for ($i = 0; $i -lt $backslashes; $i++) {
            [void]$sb.Append('\')
        }

        $backslashes = 0

        [void]$sb.Append($char)
    }

    # Los backslashes al final deben duplicarse antes
    # de la comilla final.
    for ($i = 0; $i -lt ($backslashes * 2); $i++) {
        [void]$sb.Append('\')
    }

    [void]$sb.Append('"')

    return $sb.ToString()
}


function Invoke-NativeProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [string[]]$IgnoreErrorPatterns = @()
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName = $FileName

    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    # ========================================================
    # ArgumentList existe en versiones modernas de .NET.
    #
    # Si no existe, usamos Arguments y hacemos el escape
    # manual compatible con Windows.
    # ========================================================

    $argumentListProperty =
        $psi.PSObject.Properties["ArgumentList"]

    if ($null -ne $argumentListProperty) {

        foreach ($argument in $Arguments) {

            [void]$psi.ArgumentList.Add(
                [string]$argument
            )
        }
    }
    else {

        $quotedArguments = @(
            $Arguments | ForEach-Object {
                Quote-WindowsArgument $_
            }
        )

        $psi.Arguments =
            $quotedArguments -join " "
    }

    $process = New-Object System.Diagnostics.Process

    $process.StartInfo = $psi

    try {

        if (-not $process.Start()) {

            throw "No se pudo iniciar $FileName"
        }

        # Leer ambos streams de forma asíncrona para evitar
        # deadlocks si FFmpeg genera bastante salida.
        $stdoutTask =
            $process.StandardOutput.ReadToEndAsync()

        $stderrTask =
            $process.StandardError.ReadToEndAsync()

        $process.WaitForExit()

        $stdout =
            $stdoutTask.Result

        $stderr =
            $stderrTask.Result

        $exitCode =
            $process.ExitCode

        # ====================================================
        # FILTRAR SOLO EL MENSAJE CONOCIDO DEL JPEG
        # ====================================================

        if ($IgnoreErrorPatterns.Count -gt 0) {

            $stderrLines = @(
                $stderr -split "`r?`n"
            )

            $visibleLines = @(
                $stderrLines | Where-Object {

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

            $stderr =
                $visibleLines -join "`r`n"
        }

        # Mostrar cualquier error REAL.
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {

            Write-Host `
                $stderr.Trim() `
                -ForegroundColor Red
        }

        return [PSCustomObject]@{
            ExitCode = $exitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }
    }
    finally {

        $process.Dispose()
    }
}

# ============================================================
# PATRÓN DE LA ADVERTENCIA JPEG QUE QUEREMOS IGNORAR
# ============================================================

$IgnoreMjpegWarning = @(
    'unable to decode APP fields:\s*Invalid data found when processing input'
)

# ============================================================
# OBTENER INFORMACIÓN DE LA CARÁTULA
# ============================================================

function Get-CoverInfo {
    param (
        [string]$FilePath
    )

    $result = Invoke-NativeProcess `
        -FileName "ffprobe.exe" `
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
        ) `
        -IgnoreErrorPatterns $IgnoreMjpegWarning

    if ($result.ExitCode -ne 0) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($result.StdOut)) {
        return $null
    }

    try {

        $data =
            $result.StdOut |
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

    # Buscar attached_pic
    $covers = @(
        $streams | Where-Object {

            $_.disposition -and
            $_.disposition.attached_pic -eq 1
        }
    )

    if ($covers.Count -eq 0) {
        return $null
    }

    # Preferir JPEG
    $cover =
        $covers |
        Sort-Object @{
            Expression = {

                switch (
                    $_.codec_name.ToLower()
                ) {

                    "mjpeg" {
                        0
                    }

                    "jpeg" {
                        0
                    }

                    "png" {
                        1
                    }

                    "webp" {
                        2
                    }

                    default {
                        3
                    }
                }
            }
        } |
        Select-Object -First 1

    return $cover
}

# ============================================================
# CREAR METADATA_BLOCK_PICTURE
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
# VERIFICAR FFMPEG
# ============================================================

if (-not (
    Get-Command `
        ffmpeg.exe `
        -ErrorAction SilentlyContinue
)) {

    Write-Host `
        "❌ No se encontró ffmpeg.exe en el PATH." `
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
        "❌ No se encontró ffprobe.exe en el PATH." `
        -ForegroundColor Red

    exit 1
}

# ============================================================
# VERIFICAR CARPETA
# ============================================================

if (-not (
    Test-Path `
        -LiteralPath $RootPath `
        -PathType Container
)) {

    Write-Host `
        "❌ La carpeta no existe: $RootPath" `
        -ForegroundColor Red

    exit 1
}

$root =
    (
        Resolve-Path `
            -LiteralPath $RootPath
    ).Path

# ============================================================
# ENCABEZADO
# ============================================================

Write-Host ""
Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "🎵 CONVERSOR RECURSIVO A OPUS" `
    -ForegroundColor Cyan

Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "📂 Carpeta raíz:" `
    -ForegroundColor Yellow

Write-Host `
    "   $root" `
    -ForegroundColor White

Write-Host ""

Write-Host `
    "Formatos: MP3 / WAV / FLAC / M4A → OPUS" `
    -ForegroundColor White

Write-Host `
    "Bitrate: $Bitrate" `
    -ForegroundColor Yellow

Write-Host "==============================================" `
    -ForegroundColor Cyan

# ============================================================
# BUSCAR ARCHIVOS RECURSIVAMENTE
# ============================================================

$files = @(
    Get-ChildItem `
        -LiteralPath $root `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {

            $_.Extension -match `
                '^\.(mp3|wav|flac|m4a)$'
        }
)

$totalFiles =
    $files.Count

$currentFile = 0
$converted   = 0
$skipped     = 0
$errors      = 0

Write-Host ""

Write-Host `
    "🎵 Archivos encontrados: $totalFiles" `
    -ForegroundColor Yellow

Write-Host ""

# ============================================================
# PROCESAR ARCHIVOS
# ============================================================

$files | ForEach-Object {

    $currentFile++

    $inputFile = $_

    # --------------------------------------------------------
    # OUTPUT EN LA MISMA CARPETA
    # --------------------------------------------------------

    $outputName =
        Join-Path `
            $inputFile.DirectoryName `
            "$($inputFile.BaseName).opus"

    Write-Host ""
    Write-Host `
        "[$currentFile/$totalFiles]" `
        -ForegroundColor DarkGray

    # --------------------------------------------------------
    # SI YA EXISTE, SALTAR
    # --------------------------------------------------------

    if (
        Test-Path `
            -LiteralPath $outputName
    ) {

        Write-Host `
            "⏭️ Saltando:" `
            -ForegroundColor Gray

        Write-Host `
            "   $($inputFile.FullName)" `
            -ForegroundColor DarkGray

        $skipped++

        return
    }

    # ========================================================
    # FECHAS ORIGINALES
    # ========================================================

    $fallbackDate =
        Get-Date

    try {

        $originalCreation =
            $inputFile.CreationTime

        if ($null -eq $originalCreation) {

            throw "CreationTime no disponible"
        }
    }
    catch {

        $originalCreation =
            $fallbackDate

        Write-Host `
            "⚠️ CreationTime no disponible. Se usará fecha/hora actual." `
            -ForegroundColor Yellow
    }

    try {

        $originalWrite =
            $inputFile.LastWriteTime

        if ($null -eq $originalWrite) {

            throw "LastWriteTime no disponible"
        }
    }
    catch {

        $originalWrite =
            $fallbackDate

        Write-Host `
            "⚠️ LastWriteTime no disponible. Se usará fecha/hora actual." `
            -ForegroundColor Yellow
    }

    # ========================================================
    # TEMPORALES
    # ========================================================

    $tempPrefix =
        Join-Path `
            $env:TEMP `
            (
                "opus_" +
                [Guid]::NewGuid().ToString()
            )

    $metadataFile =
        "$tempPrefix.ffmeta"

    $coverFile =
        "$tempPrefix.jpg"

    $tempOutput =
        "$tempPrefix.opus"

    Write-Host `
        "==============================================" `
        -ForegroundColor DarkGray

    Write-Host `
        "🎵 Procesando:" `
        -ForegroundColor Cyan

    Write-Host `
        "   $($inputFile.FullName)" `
        -ForegroundColor White

    Write-Host `
        "==============================================" `
        -ForegroundColor DarkGray

    try {

        # ====================================================
        # 1. EXTRAER METADATOS
        # ====================================================

        Write-Host `
            "📋 Leyendo metadatos..." `
            -ForegroundColor Yellow

        $result =
            Invoke-NativeProcess `
                -FileName "ffmpeg.exe" `
                -Arguments @(
                    "-hide_banner"
                    "-loglevel"
                    "error"
                    "-y"
                    "-i"
                    $inputFile.FullName
                    "-map_metadata"
                    "0"
                    "-f"
                    "ffmetadata"
                    $metadataFile
                ) `
                -IgnoreErrorPatterns $IgnoreMjpegWarning

        if (
            $result.ExitCode -ne 0 -or
            -not (
                Test-Path `
                    -LiteralPath $metadataFile
            )
        ) {

            throw `
                "No se pudieron extraer los metadatos."
        }

        # ====================================================
        # 2. VERIFICAR STREAM DE AUDIO
        # ====================================================

        $audioResult =
            Invoke-NativeProcess `
                -FileName "ffprobe.exe" `
                -Arguments @(
                    "-v"
                    "error"
                    "-select_streams"
                    "a"
                    "-show_entries"
                    "stream=index,codec_name"
                    "-of"
                    "json"
                    $inputFile.FullName
                ) `
                -IgnoreErrorPatterns $IgnoreMjpegWarning

        if (
            $audioResult.ExitCode -ne 0 -or
            [string]::IsNullOrWhiteSpace(
                $audioResult.StdOut
            )
        ) {

            throw `
                "No se pudo detectar el stream de audio."
        }

        try {

            $audioInfo =
                $audioResult.StdOut |
                ConvertFrom-Json
        }
        catch {

            throw `
                "No se pudo interpretar la información del audio."
        }

        $audioStreams = @(
            $audioInfo.streams
        )

        if ($audioStreams.Count -eq 0) {

            throw `
                "El archivo no contiene un stream de audio válido."
        }

        # ====================================================
        # 3. BUSCAR CARÁTULA
        # ====================================================

        $coverInfo =
            Get-CoverInfo `
                $inputFile.FullName

        $hasCover =
            $null -ne $coverInfo

        if ($hasCover) {

            Write-Host `
                "🖼️ Carátula encontrada" `
                -ForegroundColor Yellow

            Write-Host `
                "   Codec : $($coverInfo.codec_name)" `
                -ForegroundColor DarkYellow

            Write-Host `
                "   Size  : $($coverInfo.width)x$($coverInfo.height)" `
                -ForegroundColor DarkYellow

            # =================================================
            # 4. NORMALIZAR CARÁTULA
            # =================================================

            Write-Host `
                "🧹 Normalizando carátula..." `
                -ForegroundColor Yellow

            $coverResult =
                Invoke-NativeProcess `
                    -FileName "ffmpeg.exe" `
                    -Arguments @(
                        "-hide_banner"
                        "-loglevel"
                        "error"
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
                        $coverFile
                    ) `
                    -IgnoreErrorPatterns $IgnoreMjpegWarning

            if (
                $coverResult.ExitCode -ne 0 -or
                -not (
                    Test-Path `
                        -LiteralPath $coverFile
                )
            ) {

                throw `
                    "No se pudo extraer/normalizar la carátula."
            }

            # =================================================
            # 5. OBTENER DIMENSIONES REALES DE LA JPEG LIMPIA
            # =================================================

            $normalizedResult =
                Invoke-NativeProcess `
                    -FileName "ffprobe.exe" `
                    -Arguments @(
                        "-v"
                        "error"
                        "-select_streams"
                        "v:0"
                        "-show_entries"
                        "stream=width,height,pix_fmt"
                        "-of"
                        "json"
                        $coverFile
                    ) `
                    -IgnoreErrorPatterns $IgnoreMjpegWarning

            if ($normalizedResult.ExitCode -ne 0) {

                throw `
                    "No se pudo analizar la carátula normalizada."
            }

            try {

                $normalizedInfo =
                    $normalizedResult.StdOut |
                    ConvertFrom-Json
            }
            catch {

                throw `
                    "No se pudo interpretar la información de la carátula."
            }

            $normalizedStreams = @(
                $normalizedInfo.streams
            )

            if ($normalizedStreams.Count -eq 0) {

                throw `
                    "La carátula normalizada no contiene una imagen válida."
            }

            $normalizedStream =
                $normalizedStreams[0]

            $coverWidth =
                [UInt32]$normalizedStream.width

            $coverHeight =
                [UInt32]$normalizedStream.height

            $mimeType =
                "image/jpeg"

            $depth =
                [UInt32]24

            Write-Host `
                "✅ Carátula normalizada" `
                -ForegroundColor Green

            # =================================================
            # 6. CREAR METADATA_BLOCK_PICTURE
            # =================================================

            Write-Host `
                "🧩 Creando METADATA_BLOCK_PICTURE..." `
                -ForegroundColor Yellow

            $pictureBase64 =
                New-MetadataBlockPicture `
                    -ImagePath $coverFile `
                    -MimeType $mimeType `
                    -Width $coverWidth `
                    -Height $coverHeight `
                    -Depth $depth

            # FFMETADATA requiere escapar "="
            $pictureBase64Escaped =
                $pictureBase64.Replace(
                    "=",
                    "\="
                )

            # =================================================
            # 7. LEER FFMETADATA COMO UTF-8
            # =================================================

            $utf8 =
                New-Object `
                    System.Text.UTF8Encoding($false)

            $metadataText =
                [System.IO.File]::ReadAllText(
                    $metadataFile,
                    $utf8
                )

            $metadataLines =
                $metadataText -split "`r?`n"

            # Eliminar cualquier picture previo
            $filteredLines = @(
                $metadataLines |
                    Where-Object {
                        $_ -notmatch '^METADATA_BLOCK_PICTURE='
                    }
            )

            # Agregar nuestra portada
            $filteredLines +=
                "METADATA_BLOCK_PICTURE=$pictureBase64Escaped"

            # =================================================
            # ESCRIBIR UTF-8 SIN BOM
            # =================================================

            [System.IO.File]::WriteAllText(
                $metadataFile,
                ($filteredLines -join "`r`n") +
                    "`r`n",
                $utf8
            )

            Write-Host `
                "✅ Carátula preparada" `
                -ForegroundColor Green
        }
        else {

            Write-Host `
                "ℹ️ No se encontró carátula embebida." `
                -ForegroundColor DarkGray
        }

        # ====================================================
        # 8. CONVERTIR AUDIO A OPUS
        # ====================================================

        Write-Host `
            "🔄 Convirtiendo audio a Opus $Bitrate..." `
            -ForegroundColor Cyan

        $conversionResult =
            Invoke-NativeProcess `
                -FileName "ffmpeg.exe" `
                -Arguments @(
                    "-hide_banner"
                    "-loglevel"
                    "error"
                    "-y"
                    "-i"
                    $inputFile.FullName
                    "-i"
                    $metadataFile
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
                    $tempOutput
                ) `
                -IgnoreErrorPatterns $IgnoreMjpegWarning

        if (
            $conversionResult.ExitCode -ne 0 -or
            -not (
                Test-Path `
                    -LiteralPath $tempOutput
            )
        ) {

            throw `
                "Falló la conversión a Opus."
        }

        # ====================================================
        # 9. MOVER AL DESTINO FINAL
        # ====================================================

        Move-Item `
            -LiteralPath $tempOutput `
            -Destination $outputName `
            -Force

        # ====================================================
        # 10. RESTAURAR FECHAS
        # ====================================================

        $newFile =
            Get-Item `
                -LiteralPath $outputName

        # ----------------------------------------------------
        # CreationTime
        # ----------------------------------------------------

        try {

            $newFile.CreationTime =
                $originalCreation

            Write-Host `
                "📅 CreationTime: conservada" `
                -ForegroundColor DarkGreen
        }
        catch {

            Write-Host `
                "⚠️ No se pudo establecer CreationTime. Usando fecha actual." `
                -ForegroundColor Yellow

            try {

                $newFile.CreationTime =
                    $fallbackDate
            }
            catch {

                Write-Host `
                    "⚠️ El sistema de archivos no permite establecer CreationTime." `
                    -ForegroundColor DarkYellow
            }
        }

        # ----------------------------------------------------
        # LastWriteTime
        # ----------------------------------------------------

        try {

            $newFile.LastWriteTime =
                $originalWrite

            Write-Host `
                "📅 LastWriteTime: conservada" `
                -ForegroundColor DarkGreen
        }
        catch {

            Write-Host `
                "⚠️ No se pudo establecer LastWriteTime. Usando fecha actual." `
                -ForegroundColor Yellow

            try {

                $newFile.LastWriteTime =
                    $fallbackDate
            }
            catch {

                Write-Host `
                    "⚠️ El sistema de archivos no permite establecer LastWriteTime." `
                    -ForegroundColor DarkYellow
            }
        }

        # ====================================================
        # 11. RESULTADO
        # ====================================================

        Write-Host ""
        Write-Host `
            "✅ COMPLETADO: $outputName" `
            -ForegroundColor Green

        if ($hasCover) {

            Write-Host `
                "   🖼️ Carátula: OK (normalizada)" `
                -ForegroundColor Green
        }
        else {

            Write-Host `
                "   🖼️ Carátula: NO EXISTÍA" `
                -ForegroundColor DarkGray
        }

        Write-Host `
            "   📋 Metadatos UTF-8: OK" `
            -ForegroundColor Green

        Write-Host `
            "   🎚️ Bitrate: $Bitrate" `
            -ForegroundColor Green

        $converted++
    }
    catch {

        Write-Host ""
        Write-Host `
            "❌ ERROR: $($inputFile.FullName)" `
            -ForegroundColor Red

        Write-Host `
            "   $($_.Exception.Message)" `
            -ForegroundColor Red

        $errors++

        # Eliminar output incompleto
        if (
            Test-Path `
                -LiteralPath $outputName
        ) {

            Remove-Item `
                -LiteralPath $outputName `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
    finally {

        # =================================================
        # LIMPIAR TEMPORALES
        # =================================================

        @(
            $metadataFile
            $coverFile
            $tempOutput
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
# RESUMEN FINAL
# ============================================================

Write-Host ""
Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "📊 RESUMEN DE CONVERSIÓN" `
    -ForegroundColor Cyan

Write-Host "==============================================" `
    -ForegroundColor Cyan

Write-Host `
    "📂 Carpeta raíz : $root" `
    -ForegroundColor White

Write-Host `
    "🎵 Encontrados  : $totalFiles" `
    -ForegroundColor White

Write-Host `
    "✅ Convertidos  : $converted" `
    -ForegroundColor Green

Write-Host `
    "⏭️ Saltados     : $skipped" `
    -ForegroundColor Yellow

Write-Host `
    "❌ Errores      : $errors" `
    -ForegroundColor Red

Write-Host ""

if ($errors -eq 0) {

    Write-Host `
        "🎉 Proceso finalizado sin errores." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "⚠️ El proceso terminó con $errors error(es)." `
        -ForegroundColor Yellow
}