# Optimización y comparación de la ruta SGSR1

Descarga de los JAR Fabric y NeoForge para Minecraft 26.2: [release SGSR1 optimizaciones r1](https://github.com/vairacing-tech/superresolution/releases/tag/android-sgsr1-mc26.2-optimizations-r1). La release incluye checksums y procedencia de compilación.

Se implementan los tres cambios de ejecución solicitados: guardar menos estado OpenGL, omitir entradas auxiliares que SGSR1 no utiliza y leer directamente el color renderizado cuando es compatible. La copia final hacia la pantalla se conserva. Estos cambios no modifican el algoritmo de reescalado ni su enfoque.

Las 84 pruebas locales pasan y la comparación de los shaders reales produce los mismos píxeles con copia y con lectura directa en OpenGL de escritorio. La prueba funcional en Odin confirma SGSR1 y las tres rutas activas; quedan pendientes las comparaciones visuales detalladas y las mediciones de rendimiento en G2 y MobileGlues. No se atribuye ninguna ganancia de FPS a estas pruebas.

## Corrección de la base MobileGlues

El primer candidato de esta tanda se compiló desde `2414ece0`, anterior a las correcciones MobileGlues ya validadas. El log real de Odin confirma versión numérica OpenGL ES 3.2, identidad MobileGlues 2 y rechazo de SGSR1 como no soportado. Ese candidato no debe utilizarse en MobileGlues.

El reemplazo `sgsr1-opt-mgfix1` recupera los 18 archivos de código y tests correspondientes a la base validada `140aff87` sin alterar sus contenidos. Conserva la resolución de entry points ES, almacenamiento inmutable, elegibilidad de SGSR1/None, protección de efectos LSFG y compatibilidad Iris/DH. La nueva restauración de image binding 0 usa el entry point disponible; si LWJGL lo omite, utiliza la ruta MobileGlues verificada.

Los JAR corregidos, checksums y fuente exacta están en `artifacts/SGSR1_ODIN_DIAGNOSTICO_20261001/mgfix1/`. Fabric se instaló en Odin con Minecraft cerrado, hash verificado y un único JAR SuperResolution activo. Se conservaron los dos JAR anteriores, 217 archivos de configuración legibles y 65 entradas de otros mods/opciones. No se inició Minecraft automáticamente. El siguiente arranque manual confirma MobileGlues activo, almacenamiento inmutable y pipeline SGSR1 disponibles; SGSR1 se selecciona e inicializa con vertex/fragment compile y program link OK a 1280x720 hacia 1920x1080. La entrada al mundo confirma `reducedState=true auxiliaryInputs=false directColor=true` sin consumidores externos o auxiliares. La captura estática muestra mundo, mano y HUD sin corrupción evidente de pantalla completa. Quedan pendientes las comparaciones de movimiento, agua/transparencias, transición DH, conmutación de opciones y rendimiento A/B.

La pantalla simplificada Android no exponía las opciones especiales del menú completo. El candidato `sgsr1-opt-mgfix2` incorpora el botón **SGSR1 Optimizations...** y una subpantalla con los tres interruptores ON/OFF independientes. Fabric se instaló con el juego cerrado, hash verificado y un único JAR SR activo; se conservaron 217 configuraciones legibles, 65 entradas de otros mods/opciones y el JAR mgfix1. La compilación y las 84 pruebas pasan. Falta comprobar la interfaz en el siguiente arranque manual.

## Interruptores y comparación

En Android, abrir **Mods → Super Resolution → Configuración → SGSR1 Optimizations...**. Pulsar **Reduce OpenGL State Capture**, **Skip Unused Auxiliary Inputs** y **Read Rendered Color Directly** hasta que los tres muestren **OFF** para la referencia; ponerlos en **ON** para activarlos. Volver con **Done** y regresar al mundo. Cada botón guarda inmediatamente y la política se evalúa en el siguiente fotograma.

En la interfaz completa, los tres interruptores están en las opciones especiales de SGSR1 y tienen valor predeterminado `true`. En el TOML existente corresponden a estas claves; no se debe sustituir el resto de la configuración:

```toml
[special.sgsr1]
reduced_gl_state = true
skip_auxiliary_inputs = true
direct_color_input = true
```

La selección se evalúa cada fotograma. Desde la interfaz se pueden aplicar las opciones sin reconstruir el JAR. Para editar el TOML manualmente, cerrar primero el juego.

| Comparación | reduced_gl_state | skip_auxiliary_inputs | direct_color_input |
| --- | --- | --- | --- |
| Ruta de referencia | false | false | false |
| Solo estado OpenGL | true | false | false |
| Solo auxiliares | false | true | false |
| Solo entrada de color | false | false | true |
| Las tres optimizaciones | true | true | true |

Los valores solicitados pueden quedar limitados por la compatibilidad. El marcador `[SGSR1-INPUTS]` indica la ruta efectiva al cambiar: `reducedState`, `auxiliaryInputs`, `directColor`, `externalConsumers` y `auxiliaryConsumer`. `auxiliaryInputs=false` significa que no se prepara profundidad auxiliar ni movimiento vacío. No activar ImGui, depuración o FG durante una comparación de la ruta rápida.

## Condiciones de compatibilidad

La ruta rápida se aplica únicamente a la clase integrada `Sgsr1`. Otros algoritmos conservan sus entradas auxiliares y el guardado completo. También se conserva esa ruta cuando están activos FG, captura Vulkan, depuración o ImGui.

Cualquier registro de consumidores no auditados en el bus público fuerza la ruta completa. Esta protección es conservadora: incluye registros de eventos distintos de los de ejecución y permanece hasta reiniciar, aunque se retire un listener. Los dos consumidores internos auditados mantienen sus eventos: las constantes de FG leen los metadatos de cámara y las capturas siguen disponiendo de auxiliares cuando están inicializadas.

La selección se hace al comienzo del dispatch. Los registros normales durante la inicialización quedan cubiertos; un registro concurrente posterior a esa selección se detecta para el siguiente fotograma. No se añade un protocolo de bloqueo para registros de extensiones durante la ejecución del render.

El guardado reducido cubre las unidades de textura 0 y 1, programas, VAO, VBO, framebuffers, viewport, samplers, UBO indexado 0 y su rango, estado de rasterización y mezcla/máscara de color del destino 0. Si se mantiene alguna copia compute, conserva también todos los parámetros de image binding 0. La composición separada de la mano y las copias que no pueden acotarse usan el guardado completo.

Se corrigió además la restauración de bindings de textura cuyo valor inicial era cero. SGSR1 modifica mezcla y máscara de color únicamente en el destino 0 para preservar los otros destinos. El modo de polígonos se restaura teniendo en cuenta que un contexto core puede devolver un solo valor.

La lectura directa exige un attachment `GlTexture2D` del framebuffer propio, sin subclases/importaciones, con formato RGBA8, RGBA16F o RGBA32F idéntico al configurado y a la salida, dimensiones internas exactas, sampling nearest/clamp y sin mipmaps. Se rechazan handles inválidos y alias con la salida SGSR1 o con el color de la pantalla. Los parámetros corresponden a la creación de esta textura propia; no se mantiene una caché global de estado de Iris ni de otros mods.

El color se toma prestado durante la ejecución de ese fotograma. El handler nunca destruye esa textura como si fuera una copia auxiliar. Ante incompatibilidad se conserva la copia de entrada. Las copias de color, profundidad y movimiento vacío se crean o liberan según la ruta efectiva; resize y destroy aceptan su ausencia. La profundidad del framebuffer de Minecraft permanece intacta.

## Evidencia local

Se ejecutó la suite completa de `common` con un contexto OpenGL real y oculto. Sus pruebas verifican bindings originalmente vacíos, samplers, image binding, rango del UBO indexado y binding genérico diferente, rasterización y estados diferentes en los destinos de color 0 y 1.

La comparación de píxeles compila los archivos reales `copy.comp.glsl` y los shaders SGSR1 con `UseEdgeDirection`. Utiliza una entrada determinista de 31 × 19 con contraste, gradientes y alfa variable, y una salida de 57 × 35. Las salidas coinciden exactamente para RGBA8, RGBA16F y RGBA32F en NVIDIA GeForce RTX 4070 Ti, OpenGL 4.3 core. La prueba aísla los shaders y no sustituye una sesión de Minecraft con Iris, DH o un controlador Android.

Comando de verificación con el JDK 25 instalado, desde la raíz del repositorio:

```powershell
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-25'
.\gradlew.bat :common:test :fabric:assemble :neoforge:assemble -Ptest_opengl=true -Penable_auto_download=false '-Pmod_version=0.9.1-alpha.2-sgsr1-opt-mgfix2' --console=plain
```

Las pruebas OpenGL son optativas con `-Ptest_opengl=true`; sin esa opción se omiten en equipos sin contexto gráfico. El único componente simulado en el test de estado es el emisor de marcadores `GlDebug`, para evitar iniciar la configuración global de Minecraft. El bytecode de `GlState` y todas las llamadas OpenGL probadas son reales.

## Prueba pendiente en G2

Usar el mismo JAR para todas las filas de la tabla. Fijar la ruta de MobileGlues, versión del shader, resolución, configuración y temperatura inicial. El perfil directo de MobileGlues debe usar ANGLE desactivado. Mantener FG apagado y conservar las correcciones de Complementary existentes.

Tras cada cambio, dejar estabilizar los recursos. Repetir un recorrido con terreno cargado y otro explorando. Comprobar agua, transparencias, HUD y transición entre terreno normal y DH, junto con FPS y tiempos de fotograma lentos. Verificar el marcador de ruta efectiva antes de atribuir una diferencia a un interruptor. La instalación de Odin está preparada; el arranque y las pruebas de juego son manuales.

Usar los JAR publicados en la release o el candidato con controles Android de `artifacts/SGSR1_ODIN_DIAGNOSTICO_20261001/mgfix2/`. `mgfix1/` conserva la evidencia funcional anterior al nuevo menú. `artifacts/SGSR1_OPTIMIZACIONES_20261001/` conserva únicamente la evidencia del candidato inicial, incompatible con MobileGlues. Para una comparación funcional completamente anterior a estos cambios, conservar también el JAR previo validado: todos los interruptores apagados restauran las copias y el guardado completo en el nuevo JAR, pero incluyen las correcciones de restauración de estado comunes.
