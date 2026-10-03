import os
import time
import requests

MUSIC_BASE_DIR = '.'

print("Iniciando escaneo de carpetas con la API de Deezer...")

for folder_name in os.listdir(MUSIC_BASE_DIR):
    folder_path = os.path.join(MUSIC_BASE_DIR, folder_name)
    
    # Solo procesar si es un directorio
    if not os.path.isdir(folder_path):
        continue

    artist_img_path = os.path.join(folder_path, 'artist.jpg')
    
    # Si la imagen ya existe, la saltamos
    if os.path.exists(artist_img_path) or os.path.exists(os.path.join(folder_path, 'artist.png')):
        continue

    try:
        # Buscar artista en Deezer (Endpoint público y gratuito)
        url = f"https://api.deezer.com/search/artist?q={folder_name}"
        response = requests.get(url)
        data = response.json()
        
        # Verificar si hay resultados
        if 'data' in data and len(data['data']) > 0:
            # Tomar la imagen de mayor resolución disponible
            image_url = data['data'][0].get('picture_xl') or data['data'][0].get('picture_big')
            
            if image_url:
                img_data = requests.get(image_url).content
                with open(artist_img_path, 'wb') as handler:
                    handler.write(img_data)
                print(f"[OK] Portada guardada para: {folder_name}")
            else:
                print(f"[!] Sin imagen disponible para: {folder_name}")
        else:
            print(f"[!] No se encontró el artista en Deezer: {folder_name}")
            
    except Exception as e:
        print(f"[ERROR] Falló la búsqueda para {folder_name}: {e}")
    
    # Pausa para respetar el límite de peticiones del servidor gratuito
    time.sleep(0.5)

print("Proceso finalizado.")