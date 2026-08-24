WITH pivot_temperaturas AS (
    SELECT
        fecha,
        estacion_id,
        MAX(CASE WHEN variable = 'temp_min' THEN uom_value END) AS temp_min,
        MAX(CASE WHEN variable = 'temp_media' THEN uom_value END) AS temp_media,
        MAX(CASE WHEN variable = 'temp_max' THEN uom_value END) AS temp_max
    FROM result
    GROUP BY
        fecha,
        estacion_id
),

filas_invalidas AS (
    SELECT
        fecha,
        estacion_id,
        'temperatura_incoherente' AS motivo
    FROM pivot_temperaturas
    WHERE temp_min > temp_media
       OR temp_media > temp_max

    UNION ALL

    SELECT
        fecha,
        estacion_id,
        'rango_fisico_invalido' AS motivo
    FROM result
    WHERE (variable IN ('humedad_media', 'humedad_min', 'humedad_max')
           AND (uom_value < 0 OR uom_value > 100))
       OR (variable = 'precipitacion' AND uom_value < 0)
       OR (variable IN ('viento_velocidad', 'viento_racha') AND uom_value < 0)
       OR (variable = 'direccion_racha_max'
           AND (uom_value < 0 OR uom_value > 360))
)

SELECT *
FROM filas_invalidas;
