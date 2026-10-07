# Manual de uso

Este repositorio reúne scripts para convertir y administrar archivos de música, crear una playlist en Jellyfin, descargar imágenes de artistas y mantener reglas de traducción de etiquetas para Calibre. Los comandos de PowerShell están pensados para Windows.

## Antes de empezar

- Ejecuta PowerShell desde la carpeta de música adecuada. Algunos scripts usan rutas relativas al directorio actual, no a la ubicación del propio script.
- Para convertir audio y para las operaciones de borrado protegidas, instala FFmpeg y asegúrate de que `ffmpeg.exe` y `ffprobe.exe` estén disponibles en `PATH`.
- Para descargar imágenes de artistas, instala Python y la dependencia `requests`:

  ```powershell
  py -m pip install requests
  ```

- La playlist `Asian.m3u8` que aparece en algunos ejemplos es un archivo local de trabajo; está excluida del repositorio por `.gitignore`. Sustituye su ruta por una playlist disponible en tu equipo.

## Scripts

| Archivo | Para qué sirve |
| --- | --- |
| [`music/convert_to_opus.ps1`](music/convert_to_opus.ps1) | Convierte recursivamente archivos de audio en una carpeta. |
| [`music/convert_to_opus_from_list.ps1`](music/convert_to_opus_from_list.ps1) | Convierte a partir de una playlist M3U/M3U8. |
| [`music/delete_mp3_from_list.ps1`](music/delete_mp3_from_list.ps1) | Elimina, con protecciones, los originales enumerados en una playlist. |
| [`music/delete_music_originals.ps1`](music/delete_music_originals.ps1) | Elimina recursivamente originales que tengan un OPUS válido. |
| [`music/convert_m3u_to_jellyfin.ps1`](music/convert_m3u_to_jellyfin.ps1) | Importa una playlist M3U a Jellyfin creando otra playlist. |
| [`music/cover_artist_download.py`](music/cover_artist_download.py) | Busca y descarga una imagen por cada carpeta de artista. |
| [`Calibre/tag-map-rules.json`](Calibre/tag-map-rules.json) | Reglas de reemplazo de etiquetas en inglés por etiquetas en español. |

## Convertir música a OPUS

### Carpeta completa

[`convert_to_opus.ps1`](music/convert_to_opus.ps1) busca recursivamente archivos `.mp3`, `.wav`, `.flac`, `.m4a` y `.ogg`; guarda cada `.opus` en la misma carpeta que el original. Conserva metadatos, carátulas y fechas de archivo. Un OPUS existente y válido se omite; uno que no pase la validación se vuelve a generar.

La carpeta raíz predeterminada es el directorio actual (`.`) y el bitrate predeterminado es `128k`. Edita `$RootPath` y `$Bitrate` al principio del script si necesitas otros valores. Ejemplo:

```powershell
Set-Location "D:\Music"
& "C:\ruta\al\repositorio\music\convert_to_opus.ps1"
```

El script requiere `ffmpeg.exe` y `ffprobe.exe`. Escribe los errores en `convert_to_opus_errors.log` dentro de la carpeta raíz; el archivo de log se reinicia en cada ejecución.

### Solo las canciones de una playlist

[`convert_to_opus_from_list.ps1`](music/convert_to_opus_from_list.ps1) admite `.mp3`, `.wav`, `.flac` y `.m4a`. Lee rutas absolutas y relativas (las relativas se resuelven desde la carpeta de la playlist), omite comentarios M3U y guarda el resultado junto al original. Permite especificar el bitrate:

```powershell
& "C:\ruta\al\repositorio\music\convert_to_opus_from_list.ps1" `
  "D:\Music\Asian.m3u8" `
  -Bitrate "128k"
```

El bitrate es opcional y su valor predeterminado es `128k`. También requiere FFmpeg y FFprobe. El log `convert_to_opus_errors.log` se crea junto a la playlist y registra, entre otros casos, rutas faltantes y errores; se reinicia al comenzar.

## Eliminar originales

> **Precaución:** estas operaciones pueden borrar archivos sin enviarlos a la papelera. Ejecuta primero la vista previa, comprueba sus resultados y conserva una copia de seguridad.

### Desde una playlist

[`delete_mp3_from_list.ps1`](music/delete_mp3_from_list.ps1) lee rutas de audio de una playlist M3U/M3U8. La primera ejecución debe ser de prueba:

```powershell
& "C:\ruta\al\repositorio\music\delete_mp3_from_list.ps1" `
  "D:\Music\Asian.m3u8" `
  -WhatIf
```

Si el resultado es correcto, repite el comando sin `-WhatIf` para borrar. El script admite `.mp3`, `.wav`, `.flac`, `.m4a` y `.ogg`; por defecto solo borra el original si encuentra junto a él un `.opus` que FFprobe valide como audio Opus con duración positiva. Las rutas relativas se interpretan desde la carpeta de la playlist.

`-DeleteWithoutOpus` desactiva esa protección y permite borrar aunque falte un OPUS válido. Úsalo solo si aceptas ese riesgo y, aun así, empieza con `-WhatIf`:

```powershell
& "C:\ruta\al\repositorio\music\delete_mp3_from_list.ps1" `
  "D:\Music\Asian.m3u8" `
  -DeleteWithoutOpus `
  -WhatIf
```

Este script requiere `ffprobe.exe` incluso si se usa `-DeleteWithoutOpus`. Escribe `delete_mp3_from_list.log` junto a la playlist y lo reinicia en cada ejecución.

### En una carpeta completa

[`delete_music_originals.ps1`](music/delete_music_originals.ps1) recorre la carpeta y sus subcarpetas buscando `.mp3`, `.wav`, `.flac`, `.m4a` y `.ogg`. La forma recomendada es revisar primero con `-WhatIf`:

```powershell
& "C:\ruta\al\repositorio\music\delete_music_originals.ps1" `
  "D:\Music" `
  -WhatIf
```

Al quitar `-WhatIf`, PowerShell podrá solicitar confirmación antes de borrar. De forma predeterminada, solo elimina un original cuando encuentra en la misma carpeta un archivo con el mismo nombre base y extensión `.opus`, y FFprobe confirma que es válido. No elimina archivos `.opus`.

La opción `-DeleteWithoutOpus` permite borrar los originales sin comprobar que exista un OPUS válido; no se recomienda. En este modo no se requiere FFprobe. El log `delete_music_originals.log` se guarda dentro de la carpeta analizada y se reinicia en cada ejecución.

## Crear una playlist en Jellyfin

[`convert_m3u_to_jellyfin`](music/convert_m3u_to_jellyfin) analiza una playlist y crea una **playlist nueva** en Jellyfin, manteniendo el orden del M3U. No modifica la playlist original. Para usarlo:

1. Edita al principio del script `$M3UFile`, `$JellyfinUrl`, `$PlaylistName` y `$UserId` para que correspondan a tu servidor, usuario y playlist.
2. Comprueba que las entradas del M3U sean rutas Windows bajo `X:\Music\...`. El script las convierte a rutas Jellyfin con el prefijo `/media/music/`; esa ruta debe corresponder a la configuración de la biblioteca de tu servidor.
3. Ejecuta el script desde la carpeta donde se resuelve `$M3UFile` y proporciona una API key válida cuando la solicite:

   ```powershell
   Set-Location "C:\ruta\al\repositorio\music"
   & ".\convert_m3u_to_jellyfin.ps1"
   ```

4. Si falta alguna canción en Jellyfin, la importación se cancela y se genera `Asian_import_no_encontrados.txt` en el directorio actual. Corrige las rutas o la biblioteca y vuelve a ejecutarlo.
5. Si todas están disponibles, revisa el resumen y escribe exactamente `CREAR` para confirmar la creación.

El script crea la playlist indicada en `$PlaylistName`; no actualiza ni reemplaza una playlist existente. La API key se pide en tiempo de ejecución, no la guardes en el repositorio.

## Descargar imágenes de artistas

[`cover_artist_download.py`](music/cover_artist_download.py) revisa las subcarpetas del directorio actual, interpreta cada nombre de carpeta como una búsqueda de artista en Deezer y guarda la imagen de mayor resolución disponible como `artist.jpg`. Si ya existe `artist.jpg` o `artist.png`, omite esa carpeta. Usa el primer resultado de la búsqueda y espera medio segundo entre carpetas.

Ejecuta el script desde la raíz de la biblioteca que contiene las carpetas de artistas:

```powershell
Set-Location "D:\Music"
py "C:\ruta\al\repositorio\music\cover_artist_download.py"
```

Necesita conexión a Internet y el paquete `requests`. Revisa las imágenes descargadas para confirmar que el primer resultado de Deezer corresponde al artista correcto.

## Reglas de etiquetas de Calibre

`Calibre/tag-map-rules.json` contiene 204 reglas de tipo `replace` con coincidencia `one_of`; cada regla cambia un nombre de etiqueta en inglés (`query`) por su equivalente en español (`replace`). Es un archivo de datos, no un script: este repositorio no incluye un programa que lo aplique automáticamente. Edita el JSON conservando la estructura si tu flujo de trabajo de Calibre consume este formato.

## Logs y archivos locales

Los logs de los scripts terminan en `.log` y se sobrescriben al iniciar una ejecución. `.gitignore` excluye los logs, los archivos `.m3u8`, `.env` y `__pycache__`; por tanto, las playlists y los resultados locales no se incluyen en el control de versiones.
