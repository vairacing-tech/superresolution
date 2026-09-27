# SGSR V1 + MobileGlues — Plan de implementación

> **Para quien lo ejecute:** usar superpowers:executing-plans, tarea por tarea, después de que el usuario autorice la ejecución. No iniciar implementación al leer este documento. Las casillas describen trabajo futuro.

**Objetivo:** disponer de un JAR Fabric 26.2 de SGSR V1 que funcione con MobileGlues directo, Iris, shaderpack compatible y Distant Horizons en Android ARM64.

**Arquitectura:** reutilizar el modo Android Java/OpenGL, el pase SGSR y la integración Iris/DH. Añadir comprobaciones y ajustes acotados a MobileGlues; conservar Zink. Resolver primero la cadena completa de copias y formatos, después medir rendimiento.

**Tecnologías:** Java 25, Gradle wrapper 9.4.0, Fabric, LWJGL/OpenGL, GLSL→ESSL mediante MobileGlues.

**Especificación y análisis:** [2026-09-27-sgsr-mobileglues-design.md](../specs/2026-09-27-sgsr-mobileglues-design.md).

**Repositorio/rama:** vairacing-tech/superresolution / integration/sgsr-mobileglues-20260927.

**Base reproducible:** 2414ece02206f6970718af06e2958f80e0104982, común a main/dev/release al planificar.

**Estado:** EJECUCIÓN AUTORIZADA hasta obtener el primer JAR candidato, por instrucción del usuario del 2026-09-27. Tareas y casillas aún no ejecutadas no implican que el código exista. No incluye instalación ni validación física.

**Hito de esta ejecución:** primer JAR de diagnóstico construido en CI y listo para prueba manual. La cualificación física de las tareas 2, 4, 5 y 8 queda pendiente porque este entorno no aporta dispositivo/contexto GPU; no se presenta el candidato como compatibilidad o mejora de rendimiento demostrada. Evidencia y SHA-256: [registro del candidato](../validation/2026-09-27-sgsr-mobileglues.md).

## Restricciones globales

- Minecraft 26.2 Fabric; Java 25; wrapper 9.4.0; Iris de compilación 1.11.2+26.2-fabric; Sodium 0.9.1+mc26.2.
- MobileGlues directo fijado en la especificación; sin ANGLE, sin FSR, sin FG.
- Primera cualificación: Odin 2 Portal / Adreno 740 / Android 13; no extrapolar a todas las Adreno.
- SGSR V1, proveedor hack/SDR RGBA8. Detectar HDR/proveedor diferente y no sustituir formatos silenciosamente.
- No importar commits de la rama descartada de Zink, ni actualizar launcher/Mesa/Turnip.
- No ampliar automáticamente a SGSR2, HDR, REAL-LSFG, otros dispositivos o shaderpacks.
- Reutilizar la configuración existente. El perfil de renderer afecta a capacidades efectivas, sin borrar preferencias de otros renderers.
- Sin glFinish, readback continuo, ocultación de errores de programa ni buffers nuevos por fotograma estable.
- Los documentos en este commit son el único cambio autorizado actualmente. La futura instalación se hará desde Codex en la máquina con el dispositivo.

## Puntos prioritarios de revisión

1. Copias compute de color/profundidad aunque SGSR1 sea raster: tareas 2 y 4.
2. Programa que no enlaza y errores que MobileGlues oculta: tareas 2 y 3.
3. DH con solo uno de sus framebuffers y profundidad sustituida tras resize: tarea 5.
4. Configuración heredada FG=true, probes activos o factor de Zink: tarea 1.
5. Timer ausente, resultado inválido, cambio de escala y recursos cacheados: tareas 4, 5 y 6.

## Mapa de archivos y límites

Se usa el prefijo J = common/src/main/java/io/homo/superresolution/ y T = common/src/test/java/io/homo/superresolution/test/. Estas abreviaturas solo ahorran repetición; las carpetas reales son las indicadas.

| Componente | Archivos existentes / nuevos previstos |
|---|---|
| Detección y política | Nuevo J/core/graphics/opengl/compat/MobileGluesProfile.java; nuevo MobileGluesRuntime.java en la misma carpeta |
| Arranque y aislamiento | J/common/SuperResolution.java; J/core/RenderSystems.java; J/common/config/SuperResolutionConfig.java; J/common/gui/AndroidConfigScreen.java; common/src/main/java/com/lsfg/minecraft/LsfgPlatform.java |
| Capacidades | J/core/graphics/GraphicsCapabilities.java; J/core/graphics/opengl/Gl.java; J/core/graphics/opengl/dsa/CompatDirectStateAccessImpl.java |
| Prueba GPU acotada | Nuevo J/core/graphics/opengl/compat/MobileGluesSgsrProbe.java, separado de la política pura |
| Shaders | J/core/graphics/opengl/shader/GlShaderProgram.java; J/core/graphics/impl/shader/ShaderSource.java; J/core/graphics/opengl/pipeline/GlPipelineDescriptorSet.java; common/src/main/resources/shader/sgsr/v1/ y shader/copy.*.glsl |
| Copias y recursos | J/core/graphics/opengl/utils/GlTextureCopier.java; J/core/graphics/opengl/command/GlCommandDecoder.java; J/core/graphics/opengl/texture/GlTextureView.java; J/core/graphics/opengl/GlState.java |
| Integración mundo | common/src/hack/java/io/homo/superresolution/common/minecraft/handler/MinecraftRenderHandler.java; J/common/minecraft/handler/RenderHandlerManager.java |
| Iris/DH | fabric/src/main/java/io/homo/superresolution/fabric/mixin/compat/iris/DHCompatInternalMixin.java; J/common/compat/iris/IrisFramebufferUtils.java e IrisCompatHelper.java |
| Métricas | J/common/metrics/UpscaleGpuMetrics.java |
| Empaquetado | common/build.gradle.kts, fabric/build.gradle.kts, configs/26.2.json: referencias de construcción; no cambiarlos sin necesidad probada |
| Evidencia futura | docs/validation/2026-09-27-sgsr-mobileglues.md, con manifiesto de archivos, resultados y límites |

No modificar cada archivo de la tabla por obligación. Los puntos condicionales se cierran como NO NECESARIO si las pruebas confirman el comportamiento de la base. No crear una infraestructura genérica de renderers para resolver este objetivo.

## Task 0: Preparar una base aislada e inventario

**Salida:** código reproducible, dependencias y fixture real identificados. No se necesitan modificaciones del launcher.

- [ ] En Codex, leer instrucciones del repositorio y ambos documentos; comprobar si ya hay worktree aislado. Conservar cambios ajenos.
- [ ] Traer origin y usar integration/sgsr-mobileglues-20260927; verificar que la base 2414ece0 es antecesora. No usar una rama feature antigua.
- [ ] Registrar git rev-parse HEAD y git status --short. Inicializar submódulos fijados si el build los necesita; no actualizarlos a latest.
- [ ] Inventariar en una copia de la instancia: APK/paquete, MobileGlues ARM64, SGSR, Iris, Sodium, DH Android 3.3.2, shader ZIP y opciones. Registrar SHA-256 y versiones; no copiar mundos privados al repo.
- [ ] Si difieren de la especificación, anotar la diferencia y verificar firmas de mixins / interoperabilidad de versiones antes de continuar. No cambiar varias dependencias simultáneamente.
- [ ] Confirmar que el shaderpack corregido y DH funcionan en MobileGlues SIN SGSR. Si no, parar el diagnóstico del mod hasta tener una referencia válida.
- [ ] Registrar Java 25 y wrapper 9.4.0. Ejecutar la base una vez:

~~~bash
java -version
./gradlew --version
./gradlew :common:test -Pminecraft_version_config=26.2
./gradlew assemble -Pminecraft_version_config=26.2
~~~

En Windows, usar gradlew.bat con los mismos argumentos. Estos comandos reproducen las tareas del workflow existente. No reutilizar el JDK/Gradle del launcher. Salida esperada: BUILD SUCCESSFUL, XML JUnit sin fallos, JAR Fabric/OpenGL real en fabric/build/libs. Si falta la red/dependencia, registrar el bloqueo; no inventar validación.

- [ ] Inventariar el JAR resultante: nombre, hash, metadatos, mixins y recursos GLSL. Asegurar un único mod super_resolution en la instancia.
- [ ] Abrir el documento de validación futura y hacer commit del inventario técnico no privado.

## Task 1: Aislar MobileGlues y FG antes de probar la GPU

**Archivos:** MobileGluesProfile.java y MobileGluesRuntime.java nuevos; puntos de arranque/configuración/UI de la tabla.
**Pruebas:** T/MobileGluesProfileTest.java y T/MobileGluesFgIsolationTest.java.

**Interfaces previstas:**
- enum MobileGluesProfile.Mode { AUTO, COMPAT, OFF }.
- static Mode parseMode(String value): valores auto/compat/off; valor desconocido registra advertencia y usa AUTO.
- record Identity(boolean android, boolean mgExtension, String glVersion, String backendRenderer).
- record Decision(boolean active, boolean supportedBackend, boolean allowLsfg, String reason).
- static Decision evaluate(Mode mode, Identity identity): función pura, sin tocar OpenGL/archivos.
- MobileGluesRuntime.initialize(Identity identity, Mode mode) y decision(): captura una sola vez por contexto; antes de identificarlo no debe inicializar nada por sí misma.

La identidad procede del contexto vivo en el hilo de render. PreInit aún sin contexto solo usa señales tempranas fiables del launcher para aplazar probes; no realiza llamadas GL. Si no hay identidad fiable y se solicita el perfil COMPAT, aplazar FG hasta identificar el contexto.

- [ ] Escribir tests de la política: Android+ext MG activa; cadena de versión MG activa; Zink no activa en AUTO; OFF conserva ruta previa; COMPAT se registra como override; ANGLE detectado no queda cualificado como backend directo.
- [ ] Test de configuración heredada FG=true/factor3: en perfil activo no se carga bridge ni se escribe factor; se conservan valores guardados para cuando vuelva Zink.
- [ ] Test de probes activados por propiedades antiguas: perfil MG tiene precedencia y no inicializa el manager LSFG.
- [ ] Ejecutar estos tests y confirmar fallo antes de implementar la política.
- [ ] Integrar la decisión en arranque, applyFrameGenerationToNative, escritura de factor y controles Android. Mostrar que FG no está disponible en este renderer; no fingir que lo está.
- [ ] Cubrir también el caso “bridge ya cargado por el launcher”: reportarlo como fixture incorrecto y pedir reiniciar en MobileGlues directo; el mod no puede descargar de forma segura un interposer ya inyectado.
- [ ] Ejecutar tests focalizados y los de Android/LSFG existentes que afecten al cambio. Commit: feat: isolate SGSR MobileGlues runtime from LSFG.

Propiedad propuesta: -Dsuperresolution.mobileglues.mode=auto|compat|off. No introducirla como requisito para Zink ni forzar siempre Java-only en escritorio.

## Task 2: Diagnóstico GPU acotado y primera sesión física

**Archivos:** MobileGluesSgsrProbe.java, capacidades, registros de validación.
**Salida:** una decisión verificable sobre la cadena real; aún no hay una afirmación de rendimiento.

**Interfaces previstas:**
- record ProbeResult(boolean sgsrLinked, boolean rgba8CopyVerified, boolean r32fCopyVerified, boolean framebufferVerified, boolean samplerBindingsVerified, String failure).
- static ProbeResult runOnce(): solo hilo de render, opt-in, recursos propios, restauración completa en finally.
- Activación propuesta: -Dsuperresolution.mobileglues.probe=true. Por defecto desactivada. Resultado guardado una vez, sin sondeo continuo.

- [ ] Implementar un registro de GL/GLSL, backend GLES, proveedor hack/shader_compat, formato, entrada/salida, capacidades LWJGL y opciones MG; excluir rutas personales y credenciales.
- [ ] Comprobar entradas para UBO, VAO, samplers, FBO/blit y textura; para copias compute, dispatch, imágenes y barreras. No habilitar por una cadena “OpenGL 4.x” sin comprobar operaciones.
- [ ] Compilar/enlazar las fuentes reales SGSR y copias con los mismos defines del juego. Usar un patrón 17x19 (no múltiplo de 16) con colores y alpha distintos y una rampa de profundidad representable.
- [ ] Verificar RGBA8, R32F, profundidad usada por el juego, formato RG16F si se crea y salida 34x38. Leer una muestra/imagen pequeña una sola vez: copia RGBA con tolerancia de 1/255; R32F con tolerancia absoluta 1e-6 para el patrón diagnóstico.
- [ ] Para SGSR, validar preservación de alpha, ausencia de NaN/inf y salida no vacía; el resultado de color completo se contrasta con Zink, sin exigir igualdad bit a bit entre compiladores.
- [ ] Verificar estados GL_COMPILE_STATUS, GL_LINK_STATUS y GL_FRAMEBUFFER_COMPLETE; recoger logs MG. GL_NO_ERROR no es una aceptación.
- [ ] Garantizar borrado de texturas/FBO/VAO/queries/programas del probe y restauración de viewport, read/draw FBO, programa, buffers, sampler, textura activa, máscaras y enables.
- [ ] Compilar un único candidato de diagnóstico y hacer la primera sesión en la copia de instancia. Launcher 100%, ANGLE OFF, FSR OFF, FG OFF, sin overrides de resolución Android.
- [ ] Capturar opciones MG compute/DSA/timer. Si compute no está expuesto, activar únicamente la opción existente de compute en esa copia y repetir el probe; no activar todas las extensiones a ciegas.
- [ ] Clasificar: PASA cadena actual → tarea 3 solo corrige robustez y tarea 4 sin cambiar algoritmo de copia; falla fuente/enlace → tarea 3; falla copia → tarea 4; falla shader/DH sin SGSR → bloqueo de base.
- [ ] Guardar el resultado con hashes. No repetir toda la matriz mientras haya un bloqueo temprano.

## Task 3: Hacer fiable compilación, enlace y selección de capacidades

**Archivos:** GlShaderProgram.java, ShaderSource.java, GlPipelineDescriptorSet.java, Gl.java y compat DSA únicamente si el probe lo exige.
**Pruebas:** T/MobileGluesShaderBindingTest.java; ampliar DirectGLSLShaderPreprocessingTest.java con código de producción.

- [ ] Añadir test que simula GL_LINK_STATUS=false: la inicialización candidata falla con el info-log, libera recursos y no publica un programa válido. No silenciar el fallo.
- [ ] Test de fuente SGSR con y sin layout(binding): UBO sgsr1_data enlazado a 0 y sampler ps0 a 1. La ruta compute enlaza tex/outImage a sus puntos explícitos.
- [ ] Test del preprocesado real: orden de #version/defines/extensiones válido y conservación de condiciones; evitar mover una extensión fuera de su guardia sin intención.
- [ ] Ejecutar tests focalizados; aplicar la corrección mínima. Mantener el shader SGSR y coeficientes; una variante para MG solo si hay error reproducible.
- [ ] Si hace falta fallback DSA, seleccionarlo para el perfil a partir de operaciones disponibles/probadas. No alterar globalmente Gl.isLegacy para engañar al resto de sistemas.
- [ ] Revisar en los métodos realmente utilizados las consultas de bindings y restauración; no tocar métodos no alcanzados solo porque parecen mejorables.
- [ ] En error, desactivar SGSR durante el proceso y restaurar el target del juego con motivo visible; conservar la posibilidad de reintento controlado tras cambiar configuración.
- [ ] Tests y commit: fix: validate SGSR shader programs and MobileGlues bindings.

No usar capturas de texto del fuente como único test: ejercitar el preprocesador/política real y una fachada GL mínima con registro de llamadas donde sea necesario. El enlace GPU se valida físicamente, no en JUnit sin contexto.

## Task 4: Resolver copias, recursos y ruta compute/raster

**Archivos:** GlTextureCopier.java, MinecraftRenderHandler.java, shaders copy.* y cachés/estado que el diagnóstico señale.
**Pruebas:** T/MobileGluesTextureCopyLifecycleTest.java.
**Dependencia:** ProbeResult de tarea 2.

- [ ] Si las copias compute funcionan, conservarlas; comprobar imágenes RGBA8/R32F, barreras, bindings y límites de 17x19. Registrar como NO NECESARIO el cambio a raster.
- [ ] Si fallan, aislar el caso mínimo y descartar primero problema de configuración/exposición, fuente GLSL o formato. No exigir actualizar Mesa.
- [ ] Solo si el fallo queda limitado a las copias, implementar una ruta raster para MobileGlues con destino FBO explícito y programa de copia por formato/mapeo. Mantener la ruta original para otros perfiles.
- [ ] Firma prevista si se necesita contingencia: copyRaster(CopyOperation operation), privada en GlTextureCopier; conserva copy(CopyOperation) como entrada pública. Selección calculada al inicializar, no adivinada por frame.
- [ ] Corregir la gestión del fallback: enlazar el destino de cada operación; invalidar caché al recrear texturas; clave incluye formato destino además de canales; blending OFF para copia; viewport destino; quad persistente y liberado al finalizar.
- [ ] Tests de dos destinos consecutivos con idéntico mapeo, RGBA8 frente a otro formato, resize, textura eliminada, alpha 0/0.5/1 y read/draw FBO separados.
- [ ] Probar profundidad de origen → R32F. Si R32F no es renderizable en la ruta propuesta, parar: no sustituir profundidad por un formato de precisión inferior sin otro diseño.
- [ ] Evitar aliases entrada/salida y feedback mientras se dibuja; registrar número de recursos vivos antes/después de 20 cambios de escala, sin crecimiento por ciclo.
- [ ] No eliminar copias de profundidad/movimiento globalmente. Optimizar una ruta solo-color de SGSR sería una tarea posterior con análisis de eventos/consumidores, no un atajo para aprobar este plan.
- [ ] Repetir únicamente el probe afectado; tests y commit si hubo cambios: fix: make SGSR resource copies reliable on MobileGlues.

Parada: si exige cambiar sustancialmente MobileGlues, nuevos formatos generales, readback continuo o rediseño de recursos compartidos, documentar y solicitar un nuevo alcance. No empezar un port del driver.

## Task 5: Estabilizar Iris/DH y cambios de resolución

**Archivos:** mixin Fabric DH, IrisFramebufferUtils, handler de render/resize.
**Pruebas:** T/DhDepthReconnectPolicyTest.java y mejoras de IrisResizeLifecycleTest.java.

Para evitar tests que solo repiten una condición, extraer una política mínima si es necesaria en J/common/compat/iris/DhDepthReconnectPolicy.java:
- record Reconnect(boolean terrain, boolean water).
- static Reconnect evaluate(Integer terrainDepth, Integer waterDepth, int requestedDepth).
- null significa framebuffer ausente; la función solo indica qué attachment existente necesita cambiar.

- [ ] Tests: ambos ausentes → ninguno; solo terreno con depth distinta → terreno; solo agua distinta → agua; ambos iguales → ninguno; ambos distintos → ambos; uno distinto → solo ese.
- [ ] Corregir la primera condición del mixin para consultar terreno, no agua. Enlazar únicamente los framebuffers presentes que lo necesiten.
- [ ] Proteger restauración de read/draw FBO con finally si falla la consulta/conexión.
- [ ] Comprobar mediante el JAR Iris real que reconnectDHTextures y los campos/métodos usados siguen existiendo; confirmar aplicación de mixin en el log. Si las firmas difieren, adaptar de forma versionada o bloquear esa combinación, sin ignore silencioso.
- [ ] Ejercitar el código real de cálculo/resize: 100%, ratio1.5 (~67%), 50% y un tamaño impar; entrada/output/HUD correctos. No escribir un test que solo recalcule la fórmula por separado.
- [ ] Test de mismas dimensiones → sin recreación; cambio de dimensiones → cachés actualizadas, recursos antiguos liberados y attachments reconectados.
- [ ] Confirmar proveedor hack/SDR; si entra shader_compat/HDR, no degradarlo a RGBA8: informar que ese caso no está cualificado en esta fase.
- [ ] Tests y commit: fix: keep Iris DH depth and SGSR targets consistent.

## Task 6: Métricas opcionales y candidato completo

**Archivos:** UpscaleGpuMetrics.java, helpers de compatibilidad y documento de validación.
**Pruebas:** T/MobileGluesGpuMetricsTest.java.

- [ ] Tests: timer no expuesto → no crear consultas; resultado pendiente → no bloquear; resultado inválido/disjoint → descartar; transición → reset de muestra; fallo de timer → CPU submit / GPU N/D.
- [ ] Comprobar capacidad concreta de timer y entry points. Si MobileGlues no expone una comprobación fiable de disjoint, no certificar sus números GPU; usar frametimes externos/CPU etiquetados.
- [ ] Nunca representar CPU submit como tiempo GPU ni registrar cero como “gratis”.
- [ ] Desactivar probe y diagnóstico detallado por defecto; confirmar que no hay glReadPixels ni glFinish en la ruta estable añadida.
- [ ] Ejecutar una vez la suite completa y construcción del candidato:

~~~bash
./gradlew :common:test --rerun-tasks -Pminecraft_version_config=26.2
./gradlew assemble -Pminecraft_version_config=26.2
~~~

- [ ] Revisar XML de tests y diff de la rama; no afirmar éxito si hay skips relevantes o dependencias sin resolver.
- [ ] Verificar JAR Fabric/OpenGL, mixins, fuentes GLSL y metadatos. Copiarlo con nombre inequívoco: super_resolution-android-sgsr1-mobileglues-mc26.2-candidate.jar, acompañado de SHA256SUMS.txt y commit.
- [ ] Si se usa CI, ejecutar Android Build de la rama (workflow_dispatch) y descargar su artifact; no lanzar Publish Android SGSR1 Release ni clobber de una release existente.
- [ ] El APK actual basta. Si aparece necesidad de cambiar el launcher, parar y documentar el contrato exacto antes de abrir una rama allí.
- [ ] Commit: fix: gate MobileGlues metrics and document validation candidate.

## Task 7: Segunda sesión física: compatibilidad y regresión

Instalar el JAR desde Codex en una instancia copiada, con backup del anterior y de configuración. No desinstalar el launcher, borrar datos, cambiar servidor o duplicar el mismo mod.

| Orden | Caso | Aceptación |
|---|---|---|
| 1 | MG, shaders OFF, DH OFF: SGSR OFF→100%→67%→50%→OFF | Imagen/HUD correctos; salida final constante; no FBO muerto |
| 2 | MG, Iris + shader corregido, DH OFF | Cielo, agua, transparencias, sombras y exposición correctos |
| 3 | MG, mismo shader + DH ON | Terreno cercano/lejano y agua coherentes; sin costuras nuevas de profundidad |
| 4 | Cambio escala repetido, shader OFF/ON y una recarga explícita | Sin acumulación de recursos, escalado doble ni recargas continuas |
| 5 | Salir/entrar al mundo, cambio de dimensión y reanudación de app | Targets válidos tras transición; recuperación sin pantalla negra |
| 6 | Config heredada FG=true/factor3 con MG | FG efectivo OFF, sin bridge/probes/escritura de factor |
| 7 | Mismo JAR con Zink 23 | SGSR mantiene imagen/escalas; configuración FG no borrada |

- [ ] Recorrer una vez el escenario de agua/cielo/sombras durante cinco minutos con calidad fija. Capturar defectos concretos, no solo “abre el mundo”.
- [ ] Repetir 20 cambios de escala y comprobar contadores de recursos estables tras completar la secuencia; RSS/PSS como apoyo, no como único detector de fuga.
- [ ] Conservar logs/métricas privados localmente; publicar solo resultados técnicos y hashes.
- [ ] Si la referencia Zink se ve afectada en FG, ejecutar su smoke test existente OFF/X2 antes de dar el cambio por válido. No volver a certificar X3 completo sin que una modificación lo justifique.
- [ ] Detener la matriz al primer fallo bloqueante. Tras corregirlo repetir el caso afectado y sus dependencias, no todas las pruebas indiscriminadamente.

## Task 8: Medir beneficio real y cerrar con rollback claro

Benchmark principal dentro de MobileGlues, no contra un renderer diferente:

| Caso | Salida launcher | SGSR | Propósito |
|---|---|---|---|
| B0 | 100% | OFF | Referencia nativa sin coste SGSR |
| B1 | 100% | ratio 1.0 / 100% | Coste de la ruta si realmente se ejecuta; comprobar si hay bypass |
| B2 | 100% | ratio 1.5 / ~67% | Candidato equilibrado, 1280x720→1920x1080 |
| B3 | 100% | ratio 2.0 / 50% | Límite de rendimiento/calidad, 960x540→1920x1080 |

- [ ] Fijar mismo mundo, posición/cámara, hora/clima si la copia lo permite, shader/opciones, DH/distancias, caché LOD, RAM y modo de energía/ventilación. No comparar durante generación inicial de chunks.
- [ ] Calentar cada caso al menos 60 s y medir 90 s continuos. Hacer tres repeticiones por caso alternando el orden para reducir deriva térmica.
- [ ] Para capacidad máxima, usar el mismo límite FPS no vinculante en todos los casos; registrar VSync/refresco. Si están clavados al límite, no interpretar FPS iguales como coste igual. Añadir una comprobación al límite de uso habitual solo para el preset elegido.
- [ ] Registrar frametime p50/p95/p99, FPS derivados de intervalos, coste GPU SGSR si fiable, CPU submit, memoria y temperaturas disponibles. No llamar 1% low a una colección de siete capturas F3.
- [ ] Diagnóstico pesado, probe y readbacks OFF durante mediciones. Las métricas deben tener un coste constante conocido.
- [ ] Revisar capturas a resolución final: texto/HUD, vegetación fina, líneas, agua y movimiento. No declarar igualdad de calidad solo por resolución de salida.
- [ ] Si B2/B3 mejora de forma repetida y supera dispersión de las tres pasadas sin defecto visual inaceptable, recomendar el preset con los datos. Si no, dejar “compatible, sin mejora demostrada” y no cambiar el predeterminado.
- [ ] Documentar limitaciones de CPU/LOD/temperatura y resultados separados de Zink; nunca sumar la ventaja histórica de MG y una mejora hipotética de SGSR.
- [ ] Rollback: restaurar JAR/config de la instancia; mode=off desactiva el perfil candidato; volver al renderer previo. No requiere tocar mundos ni APK.
- [ ] Commit final de evidencia resumida y entrega de JAR+hash+commit. No merge/release automático: comunicar estado funcional, rendimiento y pendientes al usuario.

## Coste estimado y decisiones que pueden ampliarlo

Complejidad esperada: media si pasa compute y bastan enlaces, política y lifecycle; media-alta si requiere copia raster correcta o firmas nuevas de Iris/DH. No se asigna una fecha sin la primera sesión física.

Puntos de salida:
- Falta artefacto exacto → completar inventario, no probar otra versión al azar.
- Shaderpack sin SGSR falla → problema de base, no continuar benchmark.
- Fallo aislado de traducción/copia → corrección delimitada y repetición del probe.
- Requiere driver nuevo/HDR general/FG → parar y presentar evidencia.
- Funciona sin ganar rendimiento → entregar esa conclusión, sin mantener una promesa de FPS.

## Handoff para Codex

Al recibir una orden futura de ejecución: leer primero la especificación y este plan en la rama del repositorio superresolution; usar el launcher 1.0.3 como fixture. Empezar en tarea 0 y mantener resultados/checklist con commits pequeños. No reanudar la rama de Zink. El presente documento no es una orden de ejecución ni acredita tests o APK nuevos.

## Autorrevisión del plan

- Auditoría A1–A14 cubierta por tareas 0–8.
- Capacidades reales, copia compute, fallo de enlace, DH null y aislamiento FG tienen pruebas concretas.
- Las incógnitas físicas tienen una salida, evidencia requerida y condición de parada.
- Build y compatibilidad física se informan por separado; la falta de timer no impide SGSR.
- No hay dependencia de actualizar Mesa, portar Kopper, reescribir SGSR o instalar un APK nuevo.
