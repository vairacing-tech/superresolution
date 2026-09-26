# SGSR1 + MobileGlues — primer candidato

**Estado:** primer candidato construido; validación en GPU pendiente.
**Rama:** `integration/sgsr-mobileglues-20260927`.
**Objetivo:** obtener un JAR Fabric 26.2 para instalar desde Codex en la instancia de prueba.
**Commit construido:** `d29bba6d38720bc2475a419c1bb149d793cb34cf`.
**CI:** Android Build, run `36278344799` — tests, `assemble`, checksum y carga del artefacto completados correctamente.
**JAR:** `super_resolution-android-sgsr1-mobileglues-mc26.2-candidate.jar`, 28,632,671 bytes.
**SHA-256:** `1470a4fc54d059ab6e91ea103258613b53ef234ccc583fcd9f2e5b2b6ceb83ef`.

## Cambios incluidos

- Política pura `auto|compat|off`: `auto` identifica `GL_MG_mobileglues` o el texto MobileGlues en un contexto Android; Zink no activa el perfil y ANGLE se rechaza. `compat` permite una prueba explícita Android con identidad no confirmada.
- Captura de renderer en el hilo de render después de crear el contexto OpenGL. Las opciones con efectos externos esperan a que el renderer esté identificado.
- En el perfil MobileGlues se bloquean los probes LSFG y las escrituras de `lsfg_factor.cfg`; las preferencias guardadas no se borran.
- Los fallos de enlace de shaders ahora interrumpen la creación del programa en vez de marcarlo compilado.
- La conexión de profundidad DH consulta cada framebuffer por separado, conecta solo los attachments que cambiaron y restaura read/draw FBO con `finally`.
- CI empaqueta el JAR con un nombre inequívoco junto a `SHA256SUMS.txt`.

## Verificación ejecutada en este entorno

- Compilación con `javac` de las dos políticas puras: correcta (JDK 25.0.4.1).
- Smoke checks Java para MobileGlues, Zink, ANGLE, bloqueo LSFG y reconexión independiente de terreno/agua DH: correctos.
- `git diff --check`: correcto.
- CI ejecutó `:common:test --rerun-tasks` y `assemble` con Java 25/Gradle 9.4.0: ambos pasos terminaron correctamente. El JAR y su manifiesto se validaron y descargaron; SHA-256 coincide.
- La ejecución Gradle local sigue limitada por `NoClassDefFoundError: org/jetbrains/kotlin/buildtools/api/KotlinToolchains`; no afecta al build remoto completado.

## Pendiente de la prueba en la Odin

No hay APK, instancia, JAR DH, shaderpack ni dispositivo conectado a este entorno. Por ello este documento no afirma que MobileGlues compile los shaders, que las copias compute RGBA8/R32F funcionen, que Iris/DH rendericen juntos, ni que SGSR mejore el rendimiento. El candidato conserva la ruta compute existente y necesita esa sesión para decidir si hace falta un fallback raster acotado.

En la sesión, registrar el nombre y SHA-256 de MobileGlues/launcher, Iris, Sodium, DH y shaderpack; iniciar con salida 100%, FSR/ANGLE/FG desactivados y probar SGSR en 100%, ratio 1.5 y 50%, primero sin shaderpack y DH y luego con ambos. Adjuntar `latest.log`, defectos visuales reproducibles y tiempos como CPU o GPU etiquetados según su método.
