# SGSR1: protocolo físico mínimo de la primera tanda

Estado: preparado, **no ejecutado en dispositivo**. El entorno de revisión no
tiene Odin conectado ni `adb`. No se atribuye una mejora de FPS a los tests.

## Identidad y retorno a la versión anterior

Candidato ya construido y verificado, sin recompilar para esta guía:

- Código: `19cc83059c464472a1bf4509ab5ac1424c509ee1`.
- CI: <https://github.com/vairacing-tech/superresolution/actions/runs/36925647881>.
- JAR: `super_resolution-android-sgsr1-mobileglues-mc26.2-candidate.jar`.
- Tamaño: 28,654,010 bytes.
- SHA-256: `ea80a3a23cde9d4259cd6eb6171751bffbe903176544e2747a4e34fefac42cc7`.
- Versión interna: `0.9.1-alpha.2+dev.19cc830.opengl`.

Incluye el fallback CPU cuando falla el inicio del timer GPU, además de la
primera tanda de `11b9861b`. El JAR anterior de esa tanda sigue conservado por
separado; no se ha sustituido ni recompilado. CI pasó tests, los seis contratos
y `assemble`; se verificó el SHA-256 contra el checksum original del artefacto.

Conservar fuera de `mods` el JAR anterior y una copia de la configuración antes
de instalar el candidato en una instancia de prueba. No cargar dos versiones
del mod a la vez. Si aparece corrupción, cierre o fallo reproducible, guardar
el log y volver al JAR/configuración conservados. El historial del dispositivo
aceptó SGSR1 con MobileGlues y Zink; esto no valida aún este candidato.

Registrar launcher/APK, renderer/driver, Java, Minecraft, Iris, Sodium, DH,
shaderpack y mod con versión y hash cuando esté disponible; dispositivo/GPU,
resoluciones interna/salida, modo de captura, formato interno, distancia de
renderizado, límite FPS, VSync, alimentación y estado térmico. Mantenerlos
constantes entre A y B. FG permanece OFF. No cambiar shaders ni drivers a mitad
de una comparación. Usar el mismo mundo, posición, cámara y recorrido repetible;
esperar a que termine la carga de chunks y se estabilice la temperatura.

## Comprobación funcional antes de medir

Empezar con el renderer y shaderpack ya utilizados en la instancia del usuario.
Comprobar en cámara fija y movimiento agua, transparencias, bordes, HUD y mano.
Alternar SGSR1 → None/Bilinear → SGSR1, OFF → ON, tamaño/escala A → B → A, salir
al menú y volver al mundo. Comparar capturas y repetir el recorrido. No continuar
con rendimiento si hay corrupción, tamaño incorrecto, parpadeo nuevo o crashes.

Repetir el smoke con Iris/shaderpack y DH activos si forman parte de la instancia,
y después con el otro renderer ya instalado (MobileGlues o Zink). Es una segunda
serie: no mezclar sus muestras. Anotar cualquier fallback como resultado; no
forzar la ruta rápida para obtener un número favorable. Buscar errores GL nuevos
y distinguir los seis `glBindTextureUnit(non-gen name)` históricos de Zink,
cuyo origen previo no está resuelto.

## A/B con el mismo candidato

Los tres toggles están en la configuración especial SGSR1. Cambiar solo los
valores de la fila; las rutas de configuración son `special/sgsr1/` seguidas de
`reduced_gl_state`, `skip_auxiliary_inputs` y `direct_color_input`.

| Fila | Estado reducido | Omitir auxiliares | Color directo | Máscara solicitada |
| --- | --- | --- | --- | --- |
| A: referencia conservadora | OFF | OFF | OFF | 0 |
| B: optimizaciones solicitadas | ON | ON | ON | 7 |
| Diagnóstico opcional | ON | OFF | OFF | 1 |
| Diagnóstico opcional | OFF | ON | OFF | 2 |
| Diagnóstico opcional | OFF | OFF | ON | 4 |

Usar A → B → B → A y repetir al menos tres veces, con 30 segundos por tramo
estable como mínimo. Los cambios de opciones reinician el warmup. Esperar sus
30 consultas GPU válidas y obtener una ventana de 240 muestras válidas antes
de comparar; son muestras completadas, no simplemente 270 frames dibujados.
Mantener F3 en el mismo estado en ambos tramos. Reservar las grabaciones de vídeo
para la prueba visual, porque pueden alterar los tiempos.

No activar `enableDebug`, ImGui, captura interna de frames ni FG durante la
medición: son consumidores auxiliares y pueden desactivar optimizaciones. Los
consumidores externos, incompatibilidad del color y ciertas rutas de captura
también limitan la máscara efectiva. Confirmar `[SGSR1-INPUTS]` y
`[SR-METRICS] SGSR1 options requested=... effective=...`; B solicitado=7 no
demuestra B efectivo=7. Agrupar solo ventanas con la misma máscara efectiva.

El log `[SR-METRICS-SUMMARY]` se emite al cambiar configuración/ruta cuando hay
muestras válidas. Cerrar cada tramo con un cambio de toggle y conservar el
resumen de la configuración **anterior**, antes del reinicio. Para B → B, pasar
brevemente por A entre tramos y esperar de nuevo warmup/ventana completa.
También puede obtenerse una instantánea con el botón de estado de la pantalla
Android de SR (`[SR-STATUS]` y `[SR-METRICS]`); registrar que se abrió un menú y
no confundir esa instantánea con una medición continua de toda la partida.

Conservar `latest.log` completo en privado y extraer para comparar:

```bash
rg 'SR-METRICS|SGSR1-INPUTS|SGSR1-LIFECYCLE|SR-STATUS' latest.log
```

Por tramo, anotar hora, fila, máscaras, resoluciones, samples, gpuAvgMs,
gpuP50Ms, gpuP95Ms, cpuSubmitAvgMs y observaciones térmicas/visuales. La ventana
es móvil: el resumen contiene las últimas 240 muestras, no todo el tramo. No
promediar percentiles como si fueran un percentil global ni tratar resúmenes
solapados como repeticiones independientes.

## Interpretación y criterio para continuar

El intervalo CPU nuevo incluye captura/restauración de `GlState`; el GPU abarca
el trabajo interior de copias, dispatch y composición. Ninguno equivale al
frametime total. No comparar CPU nuevo con CPU de la release anterior, ni
convertir milisegundos de upscale a FPS del juego. Esta comparación de toggles
no aísla la caché UBO: está activa en todas las filas del candidato.

Si aparece `gpuTimerSupported=false` o `GPU timer unsupported`, el dato CPU es
la **última muestra**, no media ni percentil. No completar columnas GPU con cero.
Sin un timer GPU funcional, o sin ventanas estables, el resultado de rendimiento
es inconcluso; conservar la validación funcional por separado. Sin GPU real,
los contratos locales solo prueban lógica de métricas y caché.

Continuar a una propuesta de integración únicamente si los ciclos funcionales
pasan, no hay errores nuevos atribuibles al candidato y cualquier diferencia
de rendimiento se repite por encima de la variación entre tramos. Una diferencia
pequeña o contradictoria es inconclusa. Adjuntar tabla por repetición, logs y
capturas comparables; mantener la rama sin fusionar hasta revisar esa evidencia.
