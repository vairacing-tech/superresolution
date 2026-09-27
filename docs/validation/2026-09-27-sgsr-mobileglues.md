# SGSR1 + MobileGlues y Zink — validación en Odin

## Resultado del JAR corregido (2026-09-27)

El usuario acepta este JAR para SGSR1 tras las pruebas en Odin2 Portal (Adreno
740), Amethyst Debug, instancia `Sampiland 2 mbl2 prueba`.

- Código construido: `a902b4801c9f8a191331b8ef816f6c466eb0dd02`.
- Versión del mod: `0.9.1-alpha.2+dev.a902b480.opengl`.
- JAR probado: 28,688,093 bytes; SHA-256
  `26b3f26c8af475639d361084532275efc97d8cd25a577577c9c665eeab316a22`.
- Build local: JDK 25, Gradle 9.4, `assemble` correcto; 70 tests sin fallos.
- MobileGlues 2: shaders SGSR1 compilados/enlazados, copia compute nativa con
  cero diferencias en 1,024 bytes, activación y cambios None/Bilinear/SGSR1 sin
  la corrupción inicial. Render interno 960×540 y salida 1920×1080.
- Comparaciones estáticas y recorridos grabados: bordes más definidos que
  Bilinear; no equivalencia con el detalle nativo. El usuario no percibió más
  parpadeo que con Bilinear. No se midió rendimiento.
- Zink: arranque de las 11:23, Mesa 23.0.4 / OpenGL 4.6; perfil MobileGlues
  desactivado, SGSR1 compilado/enlazado y seleccionado al 50 %, sin fallback.
  El usuario confirma imagen correcta. Hay seis mensajes
  `GL_INVALID_OPERATION in glBindTextureUnit(non-gen name)` en `Thread-17`
  durante la entrada al mundo; su origen no está identificado.
- Mismo shader en ambas rutas:
  `ComplementaryReimagined_r5.9.3-MG2-RGBA16F.zip`; FG desactivado.

Las correcciones resuelven almacenamiento inmutable y funciones GLES que la
tabla de capacidades desktop de LWJGL omitía. La resolución directa se limita
a MobileGlues verificado; Zink conserva su ruta OpenGL.

Alcance: candidato funcional aceptado en este dispositivo. No valida partidas
largas, todas las escalas o combinaciones Iris/DH, otras GPU ni frame generation.
En MobileGlues se bloquean los efectos LSFG. Los tests y las capturas no
demuestran ganancias de rendimiento.

Los registros locales están bajo
`artifacts/SGSR_MOBILEGLUES_INSTALL_20260927`: `entrypoints-fix2`,
`quality-comparison`, `motion-comparison` y `zink-check-112451`. No se incluyen
logs completos de juego o del dispositivo en la release pública.

## Registro histórico del primer candidato (reemplazado)

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
