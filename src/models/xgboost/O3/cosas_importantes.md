### Nota sobre data leakage en la imputación meteorológica

La tabla `enriched.meteo_final` contiene datos meteorológicos que han sido previamente
completados mediante procesos de imputación e interpolación.

Algunas de estas imputaciones pueden utilizar información posterior a la fecha que se
está reconstruyendo. Por ejemplo, un valor meteorológico faltante en `t` puede ser
interpolado utilizando observaciones disponibles en `t-1` y `t+1`.

Esto supondría *data leakage* si nuestro objetivo fuera reproducir exactamente qué
información habría estado disponible en el momento `t`.

Sin embargo, en este proyecto utilizamos `meteo_final` como dataset histórico para
entrenar el modelo. El objetivo no es reconstruir retrospectivamente la información
que habría conocido el sistema en cada día histórico, sino disponer de un dataset
completo y consistente para aprender la relación entre meteorología, contaminación y
el valor del día siguiente.

Por tanto, aceptamos el uso de estas imputaciones retrospectivas durante la
construcción del dataset histórico.

Esta decisión debe interpretarse correctamente: la evaluación realizada sobre datos
históricos mide el rendimiento del modelo sobre el dataset enriquecido, pero no
constituye una simulación perfecta del estado de información disponible en tiempo real.

En producción, en cambio, las features utilizadas para predecir `t+1` se construirán
únicamente con información disponible hasta `t`. Nunca se utilizarán datos futuros
para generar una predicción.