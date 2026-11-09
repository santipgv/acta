# Acta

Mac app for writing meeting notes in md files, Apple Intelligence or Claude.

App de barra de menús para macOS que transcribe tus llamadas y genera un acta en `.md`.
El audio nunca toca el disco: solo queda el `.md`.

## Requisitos
- Mac con Apple Silicon y macOS 26 (Tahoe)
- Xcode 26 o sus Command Line Tools (`xcode-select --install`)
- Para notas locales: Apple Intelligence activado

## Instalar
```bash
cd Acta
chmod +x build.sh
./build.sh
cp -R build/Acta.app /Applications/
open /Applications/Acta.app
```

La primera vez macOS te pedirá dos permisos: **Micrófono** y **Grabación de audio del sistema**.
Si descarga el modelo de transcripción en español, tarda un momento solo esa vez.

> Cada recompilación cambia la firma, así que macOS puede volver a pedirte los permisos.

## Uso
1. Pulsa el icono de onda en la barra de menús.
2. Escribe un título (opcional) y pulsa **Empezar a grabar** (o Enter).
3. Al terminar, pulsa **Parar y generar notas**.
4. La nota aparece en `~/Documents/Reuniones/` y se abre sola.

## Ajustes
- **Motor de notas**: Apple Intelligence (por defecto), Claude con API key o Claude con tu suscripción vía Claude Code.
- Idioma, carpeta de salida, incluir o no la transcripción completa, captura del audio del sistema.

## Para usar tu suscripción de Claude
```bash
curl -fsSL https://claude.ai/install.sh | bash
claude   # haz login con tu cuenta una vez y sal
```
Después, en Ajustes elige "Claude con mi suscripción".

## Arquitectura
| Pieza | Tecnología |
|---|---|
| Micrófono ("Yo") | AVAudioEngine |
| Audio de la llamada ("Ellos") | Core Audio Process Tap + dispositivo agregado privado |
| Transcripción | SpeechAnalyzer / SpeechTranscriber (local, streaming) |
| Sin auriculares | EchoFilter: descarta frases de "Yo" que repiten lo que dijo "Ellos" en esos segundos |
| Notas | FoundationModels (local, por bloques) o Claude |
| Salida | Un único `.md`, escrito en vivo y reescrito al final |
