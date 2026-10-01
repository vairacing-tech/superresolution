# SGSR1: ventanas de métricas y datos invariantes

Base: `2cde5de7b70616c553278d29e8a0b7d9987be0ff`, alineación de main/dev con la
release de optimizaciones `4f36a74f8f9e4de3a047f88272ca056499beac6f` y la historia
MobileGlues. Rama de revisión: `codex/sgsr-metrics-uniforms`.

## Cambios observables

| Antes | Ahora |
| --- | --- |
| Los toggles SGSR1 podían mezclar muestras de rutas distintas | Se reinician ventana, warmup y consultas pendientes si cambian las opciones solicitadas o la ruta efectiva |
| CPU submit comenzaba después de capturar GlState y terminaba antes de restaurarlo | CPU submit incluye ambas operaciones; la consulta GPU conserva el intervalo interior de copias, dispatch y composición |
| Un timer no soportado podía mostrar warmup GPU indefinidamente | Se muestra la última duración CPU como tal, sin atribuirle tiempo GPU ni denominarla promedio |
| Consulta explícita del bloque uniforme y enlace duplicado en cada dispatch | La consulta/enlace explícitos se hacen al enlazar el programa en initialize |
| ViewportInfo se rellenaba y subía cada frame | Se actualiza al primer uso, cambio de dimensiones internas o recreación del recurso |

Las opciones de los logs se codifican con bits: estado reducido=1, auxiliares
omitidos=2, color directo=4; -1 indica SGSR1 inactivo. Se registran valores
solicitados y efectivos para distinguir un toggle limitado por un fallback.

No se modifica el shader, la selección de entradas, los formatos ni el blit final.
El binding global del UBO sigue haciéndose cada dispatch. La ruta legacy del
descriptor conserva su enlace de bloque por command buffer y su caché existente
de índices: esta tanda elimina la consulta/enlace **explícitos duplicados**.

La caché queda inválida antes de intentar una actualización: OpenGL ejecuta las
escrituras inmediatamente y un fallo posterior podría haber cambiado ya el UBO.
Solo se valida después de completar el envío. Así, A → B fallido → A vuelve a
subir A. Resize/destroy/initialize invalidan la caché.

## Verificación

```bash
python3 -B scripts/sgsr_metrics_contract.py
./gradlew :common:test --rerun-tasks -Pminecraft_version_config=26.2
./gradlew assemble -Pminecraft_version_config=26.2
```

El contrato local compila las clases de producción con el módulo compilador de
Java 21, sin instalar dependencias. Usa dobles deterministas solo para consultas
GL, configuración y logging; no simula la lógica de métricas/caché que se prueba.
Cubre cinco grupos: transiciones, intervalo CPU, correlación CPU/GPU y saturación,
subidas UBO e invalidaciones de ciclo de vida. Incluye fallos de frame, recreación
durante una medida, fallback CPU, cambios de tamaño y recuperación de una subida
incompleta. Se observaron fallos antes de las correcciones y éxito después.

El workflow Android ejecuta además el contrato y la suite/build completos con
JDK 25. El resultado debe consultarse para el SHA exacto de la rama; pasar el
contrato aislado no demuestra que compile todo el mod.

## Interpretación de rendimiento

Los tiempos CPU nuevos no son directamente comparables con los anteriores: el
intervalo medido es mayor. La métrica GPU mantiene su alcance previo. Sin timer
GPU se informa la última muestra CPU, no una media ni una estimación GPU.

No hay una mejora de FPS medida. Queda pendiente la prueba física A/B con el mismo
JAR, resolución, renderer, shaderpack y configuración, verificando ON/OFF, resize,
reentrada al mundo, Iris/DH, agua, transparencias y movimiento. Las pruebas de
OpenGL real existentes requieren `-Ptest_opengl=true` y un contexto compatible;
los dobles de este contrato no sustituyen esa validación.
