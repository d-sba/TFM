WITH base_data AS (
    SELECT
        -- Identificación y dimensión espacial
        indicativo,
        nombre,
        provincia,

        TRY_CAST(altitud AS INTEGER) AS altitud,

        -- Dimensión temporal
        TRY_CAST(fecha AS DATE) AS fecha,

        -- Temperatura
        TRY_CAST(
            REPLACE(CAST(tmed AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS temp_media,

        TRY_CAST(
            REPLACE(CAST(tmin AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS temp_min,

        TRY_CAST(
            REPLACE(CAST(tmax AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS temp_max,

        -- Precipitación
        TRY_CAST(
            REPLACE(
                REPLACE(CAST(prec AS VARCHAR), ',', '.'),
                'Ip',
                '0.0'
            )
            AS DOUBLE
        ) AS precipitacion,

        -- Dirección de la racha máxima
        -- AEMET proporciona el valor en decenas de grados.
        -- 88 = sin dato
        -- 99 = dirección variable
        CASE
            WHEN TRY_CAST(
                REPLACE(CAST(dir AS VARCHAR), ',', '.')
                AS DOUBLE
            ) IN (88, 99)
                THEN NULL

            ELSE TRY_CAST(
                REPLACE(CAST(dir AS VARCHAR), ',', '.')
                AS DOUBLE
            ) * 10
        END AS direccion_racha_max,

        -- Viento
        TRY_CAST(
            REPLACE(CAST(velmedia AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS viento_velocidad,

        TRY_CAST(
            REPLACE(CAST(racha AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS viento_racha,

        -- Presión
        TRY_CAST(
            REPLACE(CAST(presMax AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS presion_max,

        TRY_CAST(
            REPLACE(CAST(presMin AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS presion_min,

        -- Humedad
        TRY_CAST(
            REPLACE(CAST(hrMedia AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS humedad_media,

        TRY_CAST(
            REPLACE(CAST(hrMax AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS humedad_max,

        TRY_CAST(
            REPLACE(CAST(hrMin AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS humedad_min,

        -- Insolación
        TRY_CAST(
            REPLACE(CAST(sol AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS insolacion

    FROM aemet_raw
),

unpivoted_measures AS (

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'temp_media' AS variable_meteo,
        temp_media AS valor
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'temp_min',
        temp_min
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'temp_max',
        temp_max
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'precipitacion',
        precipitacion
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'direccion_racha_max',
        direccion_racha_max
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'viento_velocidad',
        viento_velocidad
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'viento_racha',
        viento_racha
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'presion_max',
        presion_max
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'presion_min',
        presion_min
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'humedad_media',
        humedad_media
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'humedad_max',
        humedad_max
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'humedad_min',
        humedad_min
    FROM base_data

    UNION ALL

    SELECT
        indicativo,
        nombre,
        provincia,
        altitud,
        fecha,
        'insolacion',
        insolacion
    FROM base_data
)

SELECT
    m.indicativo AS estacion_id,
    m.fecha,
    m.variable_meteo,
    dim.uom,
    m.valor AS uom_value

FROM unpivoted_measures AS m

LEFT JOIN seed_meteo AS dim
    ON m.variable_meteo = dim.variable_meteo

WHERE m.valor IS NOT NULL;