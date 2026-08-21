WITH base_data AS (
    SELECT
        -- =============================================================
        -- IDENTIFICACIÓN Y DIMENSIÓN ESPACIAL
        -- =============================================================

        indicativo,
        nombre,
        provincia,

        TRY_CAST(altitud AS INTEGER) AS altitud,

        -- =============================================================
        -- DIMENSIÓN TEMPORAL
        -- =============================================================

        TRY_CAST(fecha AS DATE) AS fecha,

        -- =============================================================
        -- TEMPERATURA
        -- =============================================================

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

        -- =============================================================
        -- PRECIPITACIÓN
        -- =============================================================

        TRY_CAST(
            REPLACE(
                REPLACE(CAST(prec AS VARCHAR), ',', '.'),
                'Ip',
                '0.0'
            )
            AS DOUBLE
        ) AS precipitacion,

        -- =============================================================
        -- DIRECCIÓN DE LA RACHA MÁXIMA
        --
        -- AEMET:
        --   88 = sin dato
        --   99 = dirección variable
        --
        -- El valor normal se expresa en decenas de grados.
        -- Lo convertimos a grados.
        -- =============================================================

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

        -- =============================================================
        -- VIENTO
        -- =============================================================

        TRY_CAST(
            REPLACE(CAST(velmedia AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS viento_velocidad,

        TRY_CAST(
            REPLACE(CAST(racha AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS viento_racha,

        -- =============================================================
        -- PRESIÓN
        -- =============================================================

        TRY_CAST(
            REPLACE(CAST(presMax AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS presion_max,

        TRY_CAST(
            REPLACE(CAST(presMin AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS presion_min,

        -- =============================================================
        -- HUMEDAD
        -- =============================================================

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

        -- =============================================================
        -- INSOLACIÓN
        -- =============================================================

        TRY_CAST(
            REPLACE(CAST(sol AS VARCHAR), ',', '.')
            AS DOUBLE
        ) AS insolacion

    FROM aemet_raw
),


-- =============================================================================
-- UNPIVOT
--
-- Una fila por:
--
--   estación + fecha + variable
--
-- Aquí TODAVÍA conservamos los NULL.
-- =============================================================================

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
),


-- =============================================================================
-- RANGO TEMPORAL POR ESTACIÓN
--
-- Cada estación obtiene su propio rango.
--
-- No inventamos datos antes de que la estación exista ni después
-- de su último registro.
-- =============================================================================

station_ranges AS (
    SELECT
        indicativo,
        MIN(fecha) AS fecha_min,
        MAX(fecha) AS fecha_max

    FROM base_data

    WHERE fecha IS NOT NULL

    GROUP BY indicativo
),


-- =============================================================================
-- CALENDARIO COMPLETO POR ESTACIÓN
-- =============================================================================

calendar AS (
    SELECT
        r.indicativo,
        CAST(gs.dia AS DATE) AS fecha

    FROM station_ranges r

    CROSS JOIN generate_series(
        r.fecha_min,
        r.fecha_max,
        INTERVAL 1 DAY
    ) AS gs(dia)
),


-- =============================================================================
-- VARIABLES DEFINIDAS EN SEED
-- =============================================================================

variables AS (
    SELECT DISTINCT
        variable_meteo

    FROM seed_meteo
),


-- =============================================================================
-- GRID COMPLETO
--
-- estación × fecha × variable
-- =============================================================================

complete_grid AS (
    SELECT
        c.indicativo,
        c.fecha,
        v.variable_meteo

    FROM calendar c

    CROSS JOIN variables v
),


-- =============================================================================
-- NORMALIZED FINAL
--
-- Si existe dato AEMET:
--
--     uom_value = valor
--
-- Si no existe dato:
--
--     uom_value = NULL
--
-- =============================================================================

normalized AS (
    SELECT
        g.indicativo AS estacion_id,
        g.fecha,
        g.variable_meteo,
        dim.uom,
        m.valor AS uom_value

    FROM complete_grid g

    LEFT JOIN unpivoted_measures m
        ON  g.indicativo = m.indicativo
        AND g.fecha = m.fecha
        AND g.variable_meteo = m.variable_meteo

    LEFT JOIN seed_meteo dim
        ON g.variable_meteo = dim.variable_meteo
)


SELECT
    estacion_id,
    fecha,
    variable_meteo,
    uom,
    uom_value

FROM normalized;