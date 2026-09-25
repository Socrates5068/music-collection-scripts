# ============================================================
# delete_music_originals.ps1
#
# Elimina recursivamente archivos originales de música:
#   MP3 / WAV / FLAC / M4A / OGG
#
# POR SEGURIDAD:
# - Por defecto SOLO elimina un original si existe el
#   .opus correspondiente y FFprobe lo reconoce como Opus.
# - NO modifica archivos .opus.
# - Soporta subcarpetas.
# - Soporta nombres con tildes, ñ, japonés, etc.
# - Genera un log de eliminados y omitidos.
#
# USO:
#   Vista previa (no borra nada):
#   .\delete_music_originals.ps1 "E:\\Music" -WhatIf
#
#   Borrar realmente:
#   .\delete_music_originals.ps1 "E:\\Music"
#
#   Borrar sin exigir OPUS válido (NO recomendado):
#   .\delete_music_originals.ps1 "E:\\Music" -DeleteWithoutOpus
#
# ============================================================

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$RootPath = '.',

    [switch]$DeleteWithoutOpus
)

$ErrorActionPreference = 'Continue'

# Si no se especifica una ruta, usar la carpeta actual.
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = '.'
}

# ============================================================
# VERIFICAR FFPROBE
# ============================================================

$ffprobeAvailable = $null -ne (Get-Command ffprobe.exe -ErrorAction SilentlyContinue)

if (-not $ffprobeAvailable -and -not $DeleteWithoutOpus) {
    Write-Host 'ERROR: No se encontró ffprobe.exe.' -ForegroundColor Red
    Write-Host 'Instala/añade FFmpeg al PATH o usa -DeleteWithoutOpus.' -ForegroundColor Yellow
    exit 1
}

# ============================================================
# VERIFICAR DIRECTORIO
# ============================================================

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    Write-Host "ERROR: El directorio no existe: $RootPath" -ForegroundColor Red
    exit 1
}

$RootPath = (Resolve-Path -LiteralPath $RootPath).Path

# ============================================================
# LOG
# ============================================================

$LogFile = Join-Path $RootPath 'delete_music_originals.log'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

[System.IO.File]::WriteAllText($LogFile, '', $Utf8NoBom)

# ============================================================
# FUNCIÓN: VALIDAR OPUS
# ============================================================

function Test-OpusFile {
    param (
        [Parameter(Mandatory = $true)]
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

    $output = @(
        & ffprobe.exe `
            -v error `
            -select_streams a:0 `
            -show_entries stream=codec_name,duration `
            -of json `
            -- "$FilePath" 2>&1 |
            ForEach-Object { $_.ToString() }
    )

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $text = $output -join "`r`n"

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    try {
        $data = $text | ConvertFrom-Json
    }
    catch {
        return $false
    }

    if (-not $data.streams) {
        return $false
    }

    $streams = @($data.streams)

    if ($streams.Count -eq 0) {
        return $false
    }

    if ($streams[0].codec_name -ne 'opus') {
        return $false
    }

    $duration = $streams[0].duration

    if ([string]::IsNullOrWhiteSpace("$duration")) {
        return $false
    }

    if ("$duration" -eq 'N/A') {
        return $false
    }

    try {
        if ([double]$duration -le 0) {
            return $false
        }
    }
    catch {
        return $false
    }

    return $true
}

# ============================================================
# BUSCAR ARCHIVOS
# ============================================================

$extensions = @('.mp3', '.wav', '.flac', '.m4a', '.ogg')

$files = @(
    Get-ChildItem `
        -LiteralPath $RootPath `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $extensions -contains $_.Extension.ToLowerInvariant()
        }
)

$total = $files.Count
$checked = 0
$deleted = 0
$skipped = 0
$missingOpus = 0
$invalidOpus = 0
$deleteErrors = 0

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host 'ELIMINAR ORIGINALES DE MUSICA' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host "Directorio: $RootPath" -ForegroundColor White
Write-Host ''
Write-Host 'Formatos a eliminar: MP3 / WAV / FLAC / M4A / OGG' -ForegroundColor Yellow
Write-Host "Archivos encontrados: $total" -ForegroundColor Yellow
Write-Host ''

if ($DeleteWithoutOpus) {
    Write-Host 'ADVERTENCIA: -DeleteWithoutOpus está activo.' -ForegroundColor Red
    Write-Host 'Los originales podrán eliminarse aunque no exista un OPUS válido.' -ForegroundColor Red
    Write-Host ''
}
else {
    Write-Host 'Protección activa: solo se eliminará un original si su OPUS es válido.' -ForegroundColor Green
    Write-Host ''
}

# ============================================================
# PROCESAR
# ============================================================

foreach ($sourceFile in $files) {

    $checked++

    Write-Progress `
        -Activity 'Revisando archivos' `
        -Status "$checked / $total" `
        -PercentComplete ([int](($checked / [Math]::Max($total, 1)) * 100))

    $sourcePath = $sourceFile.FullName
    $directory = $sourceFile.DirectoryName
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourcePath)
    $opusPath = Join-Path $directory "$baseName.opus"

    # ========================================================
    # CASO: ELIMINACIÓN SIN COMPROBAR OPUS
    # ========================================================

    if ($DeleteWithoutOpus) {

        if ($PSCmdlet.ShouldProcess($sourcePath, 'Eliminar archivo original')) {
            try {
                Remove-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
                $deleted++

                [System.IO.File]::AppendAllText(
                    $LogFile,
                    "[DELETED] $sourcePath`r`n",
                    $Utf8NoBom
                )

                Write-Host "ELIMINADO: $sourcePath" -ForegroundColor Green
            }
            catch {
                $deleteErrors++

                $msg = $_.Exception.Message
                [System.IO.File]::AppendAllText(
                    $LogFile,
                    "[DELETE_ERROR] $sourcePath :: $msg`r`n",
                    $Utf8NoBom
                )

                Write-Host "ERROR AL ELIMINAR: $sourcePath" -ForegroundColor Red
                Write-Host "  $msg" -ForegroundColor Red
            }
        }

        continue
    }

    # ========================================================
    # PROTECCIÓN: OPUS DEBE EXISTIR
    # ========================================================

    if (-not (Test-Path -LiteralPath $opusPath -PathType Leaf)) {

        $missingOpus++
        $skipped++

        [System.IO.File]::AppendAllText(
            $LogFile,
            "[NO_OPUS] $sourcePath :: esperado $opusPath`r`n",
            $Utf8NoBom
        )

        Write-Host "NO SE BORRA (falta OPUS): $sourcePath" -ForegroundColor Yellow
        continue
    }

    # ========================================================
    # PROTECCIÓN: OPUS DEBE SER VÁLIDO
    # ========================================================

    Write-Host "Verificando OPUS: $opusPath" -ForegroundColor DarkGray

    if (-not (Test-OpusFile -FilePath $opusPath)) {

        $invalidOpus++
        $skipped++

        [System.IO.File]::AppendAllText(
            $LogFile,
            "[INVALID_OPUS] $sourcePath :: $opusPath`r`n",
            $Utf8NoBom
        )

        Write-Host "NO SE BORRA (OPUS inválido): $sourcePath" -ForegroundColor Red
        continue
    }

    # ========================================================
    # BORRAR ORIGINAL
    # ========================================================

    if ($PSCmdlet.ShouldProcess($sourcePath, "Eliminar original; OPUS válido: $opusPath")) {

        try {
            Remove-Item -LiteralPath $sourcePath -Force -ErrorAction Stop
            $deleted++

            [System.IO.File]::AppendAllText(
                $LogFile,
                "[DELETED] $sourcePath :: OPUS OK -> $opusPath`r`n",
                $Utf8NoBom
            )

            Write-Host "ELIMINADO: $sourcePath" -ForegroundColor Green
        }
        catch {
            $deleteErrors++

            $msg = $_.Exception.Message

            [System.IO.File]::AppendAllText(
                $LogFile,
                "[DELETE_ERROR] $sourcePath :: $msg`r`n",
                $Utf8NoBom
            )

            Write-Host "ERROR AL ELIMINAR: $sourcePath" -ForegroundColor Red
            Write-Host "  $msg" -ForegroundColor Red
        }
    }
}

Write-Progress -Activity 'Revisando archivos' -Completed

# ============================================================
# RESUMEN
# ============================================================

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host 'PROCESO FINALIZADO' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host "Directorio       : $RootPath" -ForegroundColor White
Write-Host "Encontrados      : $total" -ForegroundColor White
Write-Host "Eliminados       : $deleted" -ForegroundColor Green
Write-Host "No eliminados    : $skipped" -ForegroundColor Yellow
Write-Host "Sin OPUS         : $missingOpus" -ForegroundColor Yellow
Write-Host "OPUS inválido    : $invalidOpus" -ForegroundColor Red
Write-Host "Errores borrando : $deleteErrors" -ForegroundColor Red
Write-Host ''
Write-Host "Log: $LogFile" -ForegroundColor White
Write-Host ''

if ($DeleteWithoutOpus) {
    Write-Host 'Se ejecutó con -DeleteWithoutOpus.' -ForegroundColor Yellow
}
else {
    Write-Host 'La protección de OPUS válido estuvo activa.' -ForegroundColor Green
}
