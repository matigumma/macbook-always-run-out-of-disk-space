# macbook-always-run-out-of-disk-space

[![PyPI](https://img.shields.io/pypi/v/diskclean-mcp?label=mcp%20server)](https://pypi.org/project/diskclean-mcp/)
[![License](https://img.shields.io/github/license/matigumma/macbook-always-run-out-of-disk-space)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-89e051)](diskclean.sh)
[![macOS](https://img.shields.io/badge/macOS-Catalina%2B-lightgrey)](#requisitos)

> Limpieza interactiva de disco para macOS. Te dice qué se puede borrar, cuánto pesa, y qué tan riesgoso es — antes de tocar nada.

Si sos developer en una Mac, ya sabés cómo termina la historia: `DerivedData` come 40 GB, `node_modules` esparcidos por todos lados, simuladores de iOS que no usás desde hace meses, modelos de LLM que descargaste "para probar". Este script escanea todo eso, lo agrupa por riesgo, y te deja elegir qué borrar — con red de seguridad (papelera + doble confirmación).

Hecho en Bash puro, sin dependencias, sin instalación. Un solo archivo.

> 🤖 **¿Usás Claude Code o Claude Desktop?** Hay un MCP server publicado en PyPI: [`diskclean-mcp`](https://pypi.org/project/diskclean-mcp/). Tu agent puede escanear y limpiar el disco con tools nativas. Ver [`mcp/README.md`](mcp/README.md).

---

## Demo

```
  ╔══════════════════════════════════════════════════════════════╗
  ║              🧹  Mac Disk Cleanup Tool                       ║
  ╚══════════════════════════════════════════════════════════════╝

  Estado del disco:
    Total: 500G  |  Usado: 487G  |  Libre: 13G
    Espacio recuperable encontrado: 87.4 GB

  🟢 SEGURO     — Caches y temporales. Se regeneran solos. Sin riesgo.
  🟡 MODERADO   — Se puede recuperar, pero puede requerir reconfiguración.
  🔴 RIESGOSO   — Datos que podrían perderse. Doble confirmación requerida.

  ━━━ 🟢 SEGURO ━━━  (Total: 41.2 GB)

  [ 1] Xcode DerivedData                              28.4 GB  [🗑️ papelera disponible]
       Datos de compilación de Xcode. Se regeneran al compilar.
       📁 ~/Library/Developer/Xcode/DerivedData

  [ 2] Homebrew cache                                  6.1 GB
       Descargas y versiones viejas de Homebrew.
       📁 ~/Library/Caches/Homebrew

  [ 3] Caches de usuario (~/Library/Caches)            4.8 GB  [🗑️ papelera disponible]
       Caches de aplicaciones. Se regeneran automáticamente.
       ...
```

---

## Qué lo hace distinto

- **Clasificación por riesgo** — Cada item se etiqueta como 🟢 seguro / 🟡 moderado / 🔴 riesgoso. No es lo mismo borrar `~/Library/Caches` que tu carpeta de `Downloads`.
- **Papelera, no `rm -rf`** — Para los paths que se pueden mover, te da la opción de mandar a la Papelera (recuperable) en vez de borrado definitivo.
- **Doble confirmación en items riesgosos** — Nada se elimina por accidente.
- **Comandos nativos donde corresponde** — Para gestores como `brew`, `npm`, `pnpm`, `pip`, `go`, `docker`, usa el comando oficial de limpieza (no rompe state interno).
- **Tres modos de limpieza** — Auto (solo seguros), auto + moderados, o selección manual por número.
- **Solo Bash** — Sin Python, sin Node, sin instaladores. Funciona en una Mac recién formateada.

---

## Qué escanea

Cubre ~40 fuentes comunes de "disco lleno" en una Mac de desarrollo:

| Categoría | Incluye |
|---|---|
| **Sistema** | Caches de usuario y sistema, logs (`~/Library/Logs`, `/Library/Logs`, `/var/log`), updates de macOS, Apple Media Analysis |
| **Desarrollo Apple** | Xcode DerivedData, Archives, simuladores iOS no disponibles |
| **Android** | Android SDK completo, emuladores AVD, caches |
| **Contenedores** | Docker Desktop, OrbStack |
| **Package managers** | npm, pnpm, Homebrew, pip, Go modules, Cargo/Rust |
| **Runtimes** | nvm, pyenv, rustup, Reflex |
| **Editores / IDEs** | VS Code, Cursor, Windsurf, Codeium, TabNine, Azure Data Studio |
| **AI local** | LM Studio (modelos), Open Interpreter |
| **Apps comunes** | Claude Desktop, Discord, Brave, Arc, Warp, Telegram, WhatsApp, Gradle |
| **Otros** | Papelera, Downloads, venvs globales |

Items menores a 10 MB se ignoran para no ensuciar la lista.

---

## Uso

```bash
git clone https://github.com/matigumma/macbook-always-run-out-of-disk-space.git
cd macbook-always-run-out-of-disk-space
chmod +x diskclean.sh
./diskclean.sh
```

O en una línea, sin clonar:

```bash
curl -fsSL https://raw.githubusercontent.com/matigumma/macbook-always-run-out-of-disk-space/main/diskclean.sh -o diskclean.sh && chmod +x diskclean.sh && ./diskclean.sh
```

> **Nota:** algunos items requieren `sudo` (caches y logs de sistema). El script te lo va a pedir solo cuando hace falta.

---

## Modelo de seguridad

| Nivel | Qué hace | Ejemplo |
|---|---|---|
| 🟢 **Seguro** | Borra directo (o ofrece papelera). Son caches regenerables. | `~/Library/Caches`, DerivedData, Homebrew cache |
| 🟡 **Moderado** | Borra con confirmación simple. Puede requerir reconfigurar algo. | Simuladores iOS, datos de VS Code, Apple Media Analysis |
| 🔴 **Riesgoso** | **Doble** confirmación obligatoria. Datos no recuperables si no tenés backup. | Android SDK, WhatsApp data, Downloads, Arc/Brave data |

Para apps con state delicado (browsers, mensajería, Docker), el script **no borra directo** — te dice cómo limpiar desde la app y por qué.

---

## Requisitos

- macOS (testeado en Sonoma+, debería funcionar desde Catalina)
- Bash 3.2+ (el que viene de fábrica)
- `bc` y `du` (vienen de fábrica)
- Opcional: `brew`, `npm`, `pnpm`, `pip`, `go`, `docker`, `xcrun` — si los tenés, los usa; si no, los saltea.

---

## Contribuir

PRs bienvenidos. Si conocés alguna otra fuente típica de "disco lleno" en Mac, agregá un `scan_*()` siguiendo el patrón existente:

```bash
register_item \
    "<nombre visible>" \
    "<size en bytes>" \
    "<safe|moderate|risky>" \
    "<path>" \
    "<comando de limpieza>" \
    "<descripción>" \
    "<yes|no>"   # ¿se puede mover a la papelera?
```

Ideas pendientes: JetBrains IDEs, Adobe caches, Spotify cache, Steam, soporte para limpieza no-interactiva (`--auto-safe` para cron).

---

## Licencia

MIT.
