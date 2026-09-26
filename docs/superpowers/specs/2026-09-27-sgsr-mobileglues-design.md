# SGSR V1 sobre MobileGlues: análisis y diseño

**Estado: SOLO PLANIFICACIÓN. Implementación no autorizada todavía.**
Fecha: 2026-09-27, Europe/Madrid.
Repositorio: https://github.com/vairacing-tech/superresolution
Rama: integration/sgsr-mobileglues-20260927
Base: 2414ece02206f6970718af06e2958f80e0104982.
Esta base coincide con main, dev y real-lsfg-2026.09.25 al hacer la auditoría.

## 1. Objetivo y límites

Adaptar el mod existente para usar SGSR V1 con MobileGlues directo, Minecraft Java 26.2 Fabric, Iris y Distant Horizons en Android ARM64. El dispositivo de referencia es Odin 2 Portal / Adreno 740 / Android 13. El éxito exige imagen correcta y estabilidad; una mejora de rendimiento solo se declarará después de medirla.

Este trabajo sustituye el objetivo de actualizar Zink. La rama del launcher integration/zink-legacy-modern-20260926 queda descartada para integración y su prototipo no se importa. Zink 23 continúa siendo una referencia de regresión, no una dependencia que haya que actualizar.

La petición actual autoriza únicamente análisis, rama y documentos versionados. No autoriza implementar las tareas, compilar, instalar, cambiar opciones del dispositivo ni publicar releases. El artefacto futuro principal será un JAR Fabric del mod; no hace falta un APK nuevo salvo que se demuestre un cambio necesario en el launcher.

Fuera de alcance: REAL-LSFG/FG sobre MobileGlues, ANGLE, Vulkan nativo de Minecraft, SGSR2 temporal, Freedreno, port de Mesa, otros cargadores y adaptación universal de shaderpacks. No retirar REAL-LSFG del mod ni romper su funcionamiento con Zink.

## 2. Bases reproducibles

| Componente | Base verificada / condición |
|---|---|
| SuperResolution | Commit 2414ece02206f6970718af06e2958f80e0104982 |
| Minecraft / construcción | configs/26.2.json: Java 25, Minecraft 26.2, LWJGL 3.4.1 |
| Fabric de compilación | Loader 0.19.3, Fabric API 0.152.2+26.2 |
| Iris / Sodium de compilación | Iris 1.11.2+26.2-fabric; Sodium 0.9.1+mc26.2 |
| Gradle | Wrapper 9.4.0; usar el wrapper del mod, no el del launcher |
| Launcher de referencia | Amethyst Plus 1.0.3, main 72ca7eeda17013b45e86f3458b6d6c93462c4c91 |
| MobileGlues auditado | MobileGL-Dev/MobileGlues@fbc4e412e353302607ba36489b2dd573b5becb25 + parche de nombres dispersos de textura ya integrado |
| AAR MobileGlues integrado | SHA-256 44465b14d0ff226e2ece8ecf382337fb8969cd0832201ecc2d2b20cb2a699393 |
| Biblioteca ARM64 integrada | SHA-256 15cf1a1a9c40551c167c3ddef1e0deeabee5038a20fb1765f3dcdaf774b2221a |
| Distant Horizons | Objetivo de la sesión: 3.3.2 con corrección Android ARM64. El JAR instalado y su hash se capturan antes de ejecutar; no se ha inspeccionado ese binario en esta auditoría |
| Shaderpack | Complementary Reimagined r5.9.3 con la corrección MobileGlues ya validada; inventariar ZIP y hash reales antes de ejecutar |

Los números de compilación no certifican la versión instalada. Si la instancia usa otras versiones de Iris, Sodium, DH, Fabric o shaderpack, registrar la diferencia y comprobar compatibilidad antes de modificar el mod. No actualizarlas a la vez para hacer encajar la prueba.

La configuración NeoForge contiene una dependencia compileOnly antigua de DH 2.4.5 para 1.21.11. Esto NO demuestra compatibilidad del objetivo Fabric con DH 3.3.2. La integración Fabric mezcla clases internas de Iris; debe comprobarse contra el JAR realmente utilizado.

No se encontró AGENTS.md en el árbol del mod auditado. Volver a comprobar instrucciones al retomar, por si se añaden después.

## 3. Auditoría del código y riesgos concretos

Prefijo de la mayor parte del código Java: common/src/main/java/io/homo/superresolution/.

| ID | Hallazgo comprobado | Implicación / resolución prevista |
|---|---|---|
| A1 | common/upscale/algo/legacy/sgsr/v1/Sgsr1.java crea un GlGraphicsPipeline con vértices y fragmentos, UBO y sampler. El shader usa GLSL 410 y textureGather | El núcleo SGSR1 no exige Vulkan ni compute. Verificar traducción, precisión y resultado en GLES; no reescribir el algoritmo |
| A2 | common/src/shared/java/.../Platform.java activa Java-only en Android; core/RenderSystems.java evita initVulkan en ese modo | Reutilizar esta ruta. Verificar detección Android y ausencia de arranque de Vulkan/compilador nativo |
| A3 | MinecraftRenderHandler.onRenderWorldEnd copia color y profundidad con GlTextureCopier; este elige compute si el formato destino tiene cualificador GLSL | El mod completo sí puede necesitar compute aunque SGSR1 no lo necesite. RGBA8 y R32F usan copy.comp.glsl GLSL 430, imágenes y barreras |
| A4 | Gl.isLegacy y Gl.isSupportDSA deciden por versión OpenGL, no por una prueba de operaciones; el mod global pide 4.1 y SGSR1 declara 4.0 | No confundir versión anunciada por la capa con operaciones comprobadas. Evitar falsear la versión o habilitar funciones indiscriminadamente |
| A5 | GlShaderProgram registra el fallo de enlace pero tiene comentado el lanzamiento de excepción y continúa | Convertirlo en fallo controlado en la ruta candidata; nunca aceptar una pantalla negra como inicialización correcta |
| A6 | Preprocesado mueve directivas de extensión; ShaderSource añade SR_GL41_COMPAT por Gl.isLegacy. MobileGlues elimina layout(binding) al traducir | Probar la fuente final y enlaces explícitos de UBO/samplers. No asumir que definir SR_GL41_COMPAT resuelve todo |
| A7 | DHCompatInternalMixin comprueba dhTerrainFramebuffer pero consulta dhWaterFramebuffer en la primera condición | Hay un acceso potencial a null y una comparación del objeto equivocado. Cubrir terrain-only, water-only, ambos, ninguno y depth sustituida |
| A8 | UpscaleGpuMetrics decide soporte de timer queries por OpenGL33 | En MobileGlues el temporizador es una opción y depende del backend. No convertir medidas ausentes, disjoint o inválidas en tiempos GPU válidos |
| A9 | SuperResolutionConfig.applyFrameGenerationToNative escribe lsfg_factor.cfg antes de comprobar si hay bridge cargado; preInit puede inicializar probes LSFG por propiedades | FG OFF en una pantalla no basta como aislamiento. En MobileGlues no cargar bridge, no escribir factor y no alterar preferencias guardadas de Zink |
| A10 | El fallback raster de GlTextureCopier mantiene un framebuffer cacheado, claves basadas en mapeo de canales, crea un quad por copia y usa alphaBlend | No redirigir todas las copias a esa ruta sin corregir destinos, vida útil, formato y alpha. Una alternativa raster requiere pruebas propias |
| A11 | SGSR1 consume color; el handler prepara además profundidad R32F y movimiento RG16F. SGSR1.resize destruye/recrea recursos | No eliminar esas copias globalmente sin auditar eventos/otros consumidores. Vigilar memoria, aliases, FBOs y cachés al cambiar escala |
| A12 | HackSRWorkModeProvider está disponible en Android Java-only; ShaderCompatSRWorkModeProvider puede activar una ruta HDR con RGBA16F | Registrar el proveedor elegido. Primera compatibilidad: ruta hack existente, entrada SDR RGBA8. No degradar silenciosamente HDR ni cambiar el orden de proveedores para todos |
| A13 | MobileGlues getter.cpp devuelve GL_NO_ERROR incluso cuando registra errores reales | glGetError()==0 no prueba éxito. Usar estado de compilación/enlace/FBO, resultados de un patrón y logs de MobileGlues |
| A14 | Los tests SGSR existentes incluyen cálculos aislados y comprobaciones de estructura/reflexión | Que pasen no prueba ejecución GPU, mixins aplicados ni compatibilidad Iris/DH. Añadir pruebas de comportamiento donde se cambie lógica |

La lectura de A3 corrige la valoración inicial, demasiado centrada en el shader SGSR. No hay un bloqueo fundamental demostrado, pero tampoco está validada aún la ruta completa con MobileGlues.

### Fuentes primarias

- [Código SGSR auditado](https://github.com/vairacing-tech/superresolution/tree/2414ece02206f6970718af06e2958f80e0104982).
- [Núcleo MobileGlues auditado](https://github.com/MobileGL-Dev/MobileGlues/tree/fbc4e412e353302607ba36489b2dd573b5becb25).
- MobileGlues-cpp/gl/glsl/glsl_for_es.cpp: traducción GLSL/ESSL y eliminación de bindings.
- MobileGlues-cpp/gl/getter.cpp: identificación, extensiones, versión anunciada y ocultación de errores.
- MobileGlues-cpp/gl/ExtWrappers/DSAWrapper.cpp: emulación DSA; existencia de wrappers no equivale a prueba del camino usado.
- [FAQ de Iris](https://irisshaders.dev/): DH necesita un shaderpack que lo soporte expresamente.
- Evidencia del proyecto launcher, accesible para el propietario: docs/upstream/20260925/mobileglues-2-validation.md en el commit de referencia. No incorporar logs privados ni mundos al repositorio público.

## 4. Opciones consideradas y decisión

1. **Reutilizar la ruta Android/OpenGL y adaptar capacidades y fallos concretos — elegida.** Conserva SGSR, shaders y puntos de integración existentes. Primero se verifica la cadena real de copias compute; si funciona no se sustituye por otra solo por preferencia.
2. **Ruta raster específica sin compute — contingencia delimitada.** Solo si las copias compute fallan en la biblioteca fijada y el problema queda aislado. Reutiliza el pase SGSR, pero debe resolver RGBA8, profundidad R32F, alpha, FBOs, viewport y liberación. No prometer que activar el fallback actual basta.
3. **Implementar SGSR dentro de MobileGlues o cambiar su driver — descartada para esta fase.** Implica mantener nativos/APK y otra integración; no resuelve por sí sola la relación entre resolución interna, interfaz e Iris/DH.

Se conserva la API OpenGL del mod y LWJGL. No convertir el mod entero a llamadas GLES, no añadir otro traductor, no convertir todo a Vulkan y no escribir un renderer nuevo.

## 5. Diseño de la adaptación

### 5.1 Identificación y capacidades

Una política pequeña y comprobable decide el comportamiento del proceso. Detectar MobileGlues por la extensión GL_MG_mobileglues y/o el texto de versión; registrar también el backend GLES. Un indicador del launcher solo es evidencia auxiliar hasta verificar el contexto. Si el entorno oculta su identidad, se permite un override explícito de diagnóstico, registrado, sin inventar capacidades.

Propuesta para implementación: propiedad superresolution.mobileglues.mode con auto (predeterminado), compat y off. auto selecciona el perfil solo con MobileGlues identificado; compat permite probarlo explícitamente; off conserva la ruta anterior. Ninguna opción autoriza copiar una capacidad que no existe. ANGLE se registra y se rechaza como objetivo de esta validación.

Capturar una vez, en el hilo de render con contexto vigente: cadenas GL/GLSL/backend, presencia de entradas requeridas, extensiones relevantes, opción compute, DSA y timer, formato del proveedor de trabajo, tamaños y hashes de artefactos por el manifiesto externo. No consultar todo por fotograma.

La ruta candidata debe poder desactivar SGSR con motivo claro y volver al renderizado normal si falla una operación necesaria. No cambiar opciones persistidas de calidad/FG de otro renderer.

### 5.2 Shaders, copias y formato

Mantener SGSR1 y sus coeficientes. Comprobar vertex/fragment SGSR y las variantes de copia RGBA8 y R32F. Enlazar UBO y samplers explícitamente. Si falla la traducción, introducir una variante mínima acotada al perfil MobileGlues; conservar el resultado de referencia Zink.

Primera ruta soportada: hack/SDR RGBA8. La selección de un shaderpack con integración SR HDR específica debe detectarse; no forzar RGBA8 sobre una entrada HDR. Hasta validarlo, informar de combinación no cualificada y no presentar imagen recortada como éxito.

El primer pase de validación mantiene las copias compute. El plan permite habilitar la opción compute ya existente en una instancia de prueba; esto no prueba funcionamiento, solo expone la ruta que se medirá. Si falla, la contingencia raster es una tarea separada, con condición de parada si requiere modificar el driver.

La imagen usada como entrada y la salida de SGSR no pueden referir al mismo almacenamiento activo. Conservar alpha y el espacio de color; verificar cielo, transparencias y brillo. Evitar glFinish, readbacks por fotograma y creación de objetos en el bucle estable. Las lecturas de píxeles se permiten exclusivamente en la prueba diagnóstica acotada.

### 5.3 Iris/DH y ciclo de vida

Verificar que el mundo y DH reciben la misma resolución interna y que los attachments de profundidad coinciden tras cada transición. SGSR produce la resolución final y el HUD conserva su tamaño y nitidez. No reescalar otra vez desde FSR de MobileGlues o desde el launcher.

Corregir la condición defectuosa del mixin de DH y restaurar bindings en finally. Las pruebas deben cubrir carga inicial, agua/terreno por separado, shader OFF/ON, recarga explícita de shaderpack, entrar/salir del mundo, cambio de dimensión y cambios de escala, incluyendo dimensiones impares.

Cambiar escala no debe provocar una recarga completa del shaderpack por cada fotograma. Los handles y cachés deben apuntar a recursos vivos y liberarse al cerrar o reconstruir.

### 5.4 Aislamiento de FG y métricas

En el perfil MobileGlues: Java/OpenGL-only, FG efectivo deshabilitado, probes LSFG inactivos, sin escritura de lsfg_factor.cfg ni carga de bibliotecas LSFG/Vulkan por este mod. Mostrar FG no disponible para este renderer sin borrar la preferencia del usuario para Zink. Un valor FG=true guardado no debe activar nada.

No confundir las bibliotecas Vulkan que puedan estar incluidas en el JAR con una inicialización efectiva de Vulkan. Se comprueba la ejecución, no solo los nombres empaquetados.

Temporización GPU opcional: exigir una capacidad válida y consultas que realmente devuelvan datos; descartar resultados disjoint y no esperar bloqueando. Si no puede verificarse el contador, mostrar N/D y medir frametimes CPU separados. La falta de timer no bloquea SGSR.

## 6. Prueba y aceptación

Se distinguen tres resultados: compilación correcta, compatibilidad física y mejora de rendimiento. Ninguno implica automáticamente el siguiente.

La validación debe usar salida del launcher al 100%, FSR y ANGLE desactivados, FG efectivo OFF y opciones idénticas de shader/DH. Elegir la escala dentro de SGSR. Primera escala útil: preset aproximado 67% (ratio 1.5), equivalente a 1280x720 para salida 1920x1080; no confundirlo con el 67% literal del launcher (1286x722 en las pruebas previas).

Pruebas agrupadas: una sesión diagnóstica temprana para resolver capacidades/cadena gráfica y una sesión final con compatibilidad, transiciones y rendimiento. Si el primer bloqueo impide renderizar, parar y corregirlo antes de repetir el resto de la matriz.

No prometer un porcentaje de mejora. La comparación previa de 51 FPS MobileGlues frente a 35 FPS Zink+SGSR usaba resoluciones y configuraciones de escalado distintas, muestras F3 y variaciones de escena. No es un benchmark de SGSR sobre MobileGlues ni de coste del driver a igual calidad.

Criterios funcionales:
- Compila/enlaza cada programa necesario y FBOs completos con resultados de imagen correctos.
- Iris + shaderpack corregido + DH visibles juntos; agua, cielo, sombras, HUD y transparencias sin defectos nuevos.
- ON/OFF, escala y transiciones no dejan FBOs muertos, mezcla de dimensiones ni crecimiento de recursos por ciclo.
- Sin FG/probes/escrituras LSFG al usar MobileGlues; Zink conserva su comportamiento.
- Sin silenciamiento de errores de programa; fallback explícito y recuperable.

Criterios de rendimiento:
- Coste SGSR medido por separado cuando exista timer fiable; frame pacing medido con serie continua.
- Beneficio declarado solo si supera la variación entre repeticiones y se mantiene la calidad objetivo.
- Si el equipo está limitado por CPU/DH o el coste de SGSR anula el ahorro, clasificarlo como compatible pero sin mejora demostrada. No promocionar un preset por obligación.

## 7. Límites de lo conocido y condiciones de parada

Esta auditoría es estática. No se han ejecutado tests, compilación ni GPU en esta sesión. Permanecen por comprobar el JAR DH concreto, el shaderpack exacto, los entry points de LWJGL sobre esta biblioteca, el enlace GLSL/ESSL, los formatos reales y el coste térmico sostenido.

Parar y documentar antes de ampliar el alcance si se necesita: un port sustancial de MobileGlues/driver, modificar el motor de DH, reescribir el pipeline de Iris, soporte HDR general, FG, copia GPU→CPU→GPU por fotograma o un nuevo APK. Si el shaderpack sin SGSR ya falla, corregir la base en un trabajo independiente; no atribuir ese fallo al mod.

El plan reduce sorpresas haciendo explícitas dependencias y pruebas, pero no puede garantizar compatibilidad física sin acceso al dispositivo.
