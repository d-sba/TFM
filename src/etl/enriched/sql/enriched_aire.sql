-- ============================================================
-- IMPUTACIÓN ESPACIAL MEDIANTE IDW
-- ============================================================
--
-- Madrid:
--   provincia = 28
--   municipio = 79
--
-- Contaminantes:
--   8  -> NO SE IMPUTA
--   9  -> k=7, p=1
--   10 -> k=7, p=1.5
--   14 -> k=7, p=1
--
-- IMPORTANTE:
-- Solo se imputan contaminantes que la estación realmente mide.
-- Una estación que nunca mide un contaminante NO genera filas
-- artificiales para ese contaminante.
-- ============================================================


WITH
-- ============================================================
-- 0. UOM cte
-- ============================================================
uom_por_magnitud AS (
    SELECT
        magnitud,
        MAX(uom) AS uom
    FROM aire_normalized
    WHERE uom IS NOT NULL
    GROUP BY magnitud
),


-- ============================================================
-- 1. CONFIGURACIÓN IDW
-- ============================================================

idw_config AS (
    SELECT *
    FROM (
        VALUES
            (8,  6, 1.0),
            (9,  7, 1.0),
            (10, 7, 1.5),
            (14, 7, 1.0)
    ) AS t(magnitud, k, p)
),


-- ============================================================
-- 2. DATOS RAW FILTRADOS
-- ============================================================

filtered_raw AS (
    SELECT
        provincia,
        municipio,
        estacion,
        magnitud,
        punto_muestreo,
        fecha::DATE AS fecha,
        uom,
        uom_value

    FROM aire_normalized AS an

    WHERE an.provincia = 28
      AND an.municipio = 79

      AND an.magnitud IN (8, 9, 10, 14)

      -- No permitimos concentraciones negativas.
      AND an.uom_value >= 0

      AND an.estacion NOT IN (4, 11)
),


-- ============================================================
-- 3. AGREGACIÓN DIARIA
-- ============================================================

aggregated_data AS (
    SELECT
        provincia,
        municipio,
        estacion,
        magnitud,
        punto_muestreo,
        fecha,
        uom,
        AVG(uom_value) AS uom_value

    FROM filtered_raw

    GROUP BY ALL
),


-- ============================================================
-- 4. ESTACIONES QUE REALMENTE MIDEN CADA CONTAMINANTE
-- ============================================================
--
-- Esto es MUY IMPORTANTE.
--
-- Si una estación ha medido históricamente un contaminante,
-- consideramos que ese contaminante forma parte de su conjunto
-- de medición.
--
-- Si nunca lo ha medido:
--     NO se genera una fila
--     NO se imputa.
-- ============================================================

estacion_contaminante AS (
    SELECT DISTINCT
        estacion,
        magnitud

    FROM aire_normalized

    WHERE provincia = 28
      AND municipio = 79
      AND magnitud IN (8, 9, 10, 14)
      AND estacion NOT IN (4, 11)
),


-- ============================================================
-- 5. METADATA DE ESTACIONES
-- ============================================================

stations AS (
    SELECT DISTINCT
        ESTACION AS estacion,
        LATITUD_G AS latitud,
        LONGITUD_G AS longitud,
        ALTITUD AS altitud

    FROM metadata_estaciones_aire

    WHERE LATITUD_G IS NOT NULL
      AND LONGITUD_G IS NOT NULL
),


-- ============================================================
-- 6. FECHAS
-- ============================================================

dates AS (
    SELECT DISTINCT
        fecha

    FROM aggregated_data
),


-- ============================================================
-- 7. COMBINACIONES ESPERADAS
-- ============================================================
--
-- SOLO:
--
--     fecha × estación × contaminante
--
-- cuando la estación realmente mide ese contaminante.
--
-- Esto evita el problema que teníamos antes con el CROSS JOIN
-- de todas las estaciones contra todos los contaminantes.
-- ============================================================

expected_combinations AS (
    SELECT
        d.fecha,
        s.estacion,
        ec.magnitud,

        28 AS provincia,
        79 AS municipio,

        s.latitud,
        s.longitud,
        s.altitud

    FROM dates d

    CROSS JOIN stations s

    INNER JOIN estacion_contaminante ec
        ON s.estacion = ec.estacion
),


-- ============================================================
-- 8. OBSERVACIONES REALES
-- ============================================================
--
-- Estas son las observaciones originales agregadas a nivel
-- diario.
--
-- NO contienen imputaciones.
-- ============================================================

observations AS (
    SELECT
        fecha,
        estacion,
        magnitud,
        uom_value,
        provincia,
        municipio,
        punto_muestreo,
        uom

    FROM aggregated_data
),


-- ============================================================
-- 9. BASE
-- ============================================================
--
-- Determinamos si existe observación real para cada combinación
-- esperada.
-- ============================================================

base AS (
    SELECT
        ec.fecha,
        ec.estacion,
        ec.magnitud,

        -- Madrid hardcodeado porque todo el análisis está
        -- limitado a provincia 28 / municipio 79.
        28 AS provincia,
        79 AS municipio,

        ec.latitud,
        ec.longitud,
        ec.altitud,

        o.uom_value,
        o.punto_muestreo,
        o.uom,

        CASE
            WHEN o.uom_value IS NULL
            THEN TRUE
            ELSE FALSE
        END AS necesita_imputacion

    FROM expected_combinations ec

    LEFT JOIN observations o
        ON ec.fecha = o.fecha
       AND ec.estacion = o.estacion
       AND ec.magnitud = o.magnitud
),


-- ============================================================
-- 10. CANDIDATOS PARA IDW
-- ============================================================
--
-- Para cada hueco buscamos:
--
--   misma fecha
--   mismo contaminante
--   otra estación
--   dato REAL disponible
--
-- Nunca utilizamos valores imputados como donantes.
-- ============================================================

idw_candidates AS (
    SELECT

        b.fecha,

        b.estacion AS estacion_objetivo,

        b.magnitud,

        o.estacion AS estacion_donante,

        o.uom_value AS valor_donante,

        b.latitud AS lat_objetivo,
        b.longitud AS lon_objetivo,

        sd.latitud AS lat_donante,
        sd.longitud AS lon_donante,

        cfg.k,
        cfg.p,


        -- ====================================================
        -- DISTANCIA HAVERSINE
        -- ====================================================
        --
        -- Distancia en kilómetros.
        -- Radio terrestre = 6371 km.
        -- ====================================================

        2.0 * 6371.0 * ASIN(
            SQRT(
                POWER(
                    SIN(
                        RADIANS(
                            sd.latitud - b.latitud
                        ) / 2.0
                    ),
                    2
                )
                +
                COS(
                    RADIANS(b.latitud)
                )
                *
                COS(
                    RADIANS(sd.latitud)
                )
                *
                POWER(
                    SIN(
                        RADIANS(
                            sd.longitud - b.longitud
                        ) / 2.0
                    ),
                    2
                )
            )
        ) AS distancia_km

    FROM base b

    -- Solo 9, 10 y 14.
    INNER JOIN idw_config cfg
        ON b.magnitud = cfg.magnitud

    -- Buscamos observaciones reales.
    INNER JOIN observations o
        ON o.fecha = b.fecha
       AND o.magnitud = b.magnitud
       AND o.uom_value IS NOT NULL
       AND o.estacion <> b.estacion

    -- Coordenadas del donante.
    INNER JOIN stations sd
        ON sd.estacion = o.estacion

    WHERE b.necesita_imputacion

      AND b.latitud IS NOT NULL
      AND b.longitud IS NOT NULL

      AND sd.latitud IS NOT NULL
      AND sd.longitud IS NOT NULL
),


-- ============================================================
-- 11. ORDENAR DONANTES POR DISTANCIA
-- ============================================================

ranked_candidates AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY
                fecha,
                estacion_objetivo,
                magnitud

            ORDER BY
                distancia_km,
                estacion_donante
        ) AS rn

    FROM idw_candidates
),


-- ============================================================
-- 12. SELECCIONAR LAS 7 ESTACIONES MÁS CERCANAS
-- ============================================================

selected_candidates AS (
    SELECT
        *

    FROM ranked_candidates

    WHERE rn <= k
),


-- ============================================================
-- 13. CALCULAR IDW
-- ============================================================
--
-- IDW =
--
--       Σ (valor_i / distancia_i^p)
--       ---------------------------
--       Σ (1 / distancia_i^p)
--
-- Configuración:
--
--   9  -> k=7, p=1
--   10 -> k=7, p=1.5
--   14 -> k=7, p=1
-- ============================================================

idw_values AS (
    SELECT

        fecha,

        estacion_objetivo AS estacion,

        magnitud,

        SUM(
            valor_donante
            / NULLIF(
                POWER(distancia_km, p),
                0
            )
        )
        /
        NULLIF(
            SUM(
                1.0
                / NULLIF(
                    POWER(distancia_km, p),
                    0
                )
            ),
            0
        ) AS uom_value

    FROM selected_candidates

    GROUP BY
        fecha,
        estacion_objetivo,
        magnitud
),


-- ============================================================
-- 14. DATOS FINALES
-- ============================================================
--
-- Si existe dato real:
--     se conserva.
--
-- Si no existe dato real y existe IDW:
--     se utiliza IDW.
--
-- Si no existe dato real y tampoco hay suficientes donantes:
--     queda NULL.
-- ============================================================

final_values AS (
    SELECT

        b.fecha,
        b.estacion,
        b.magnitud,

        28 AS provincia,
        79 AS municipio,

        b.punto_muestreo,
        b.uom,

        COALESCE(
            b.uom_value,
            i.uom_value
        ) AS uom_value,

        CASE
            WHEN b.uom_value IS NULL
             AND i.uom_value IS NOT NULL
            THEN TRUE

            ELSE FALSE
        END AS imputado

    FROM base b

    LEFT JOIN idw_values i
        ON b.fecha = i.fecha
       AND b.estacion = i.estacion
       AND b.magnitud = i.magnitud
),


-- ============================================================
-- 15. CLASIFICACIÓN DE CALIDAD
-- ============================================================

data_classified AS (
    SELECT
        fv.*,

        sr.categoria AS calidad

    FROM final_values fv

    -- Los rangos contienen límites como 20.999999 para expresar un
    -- intervalo entero. Compararlos con promedios DOUBLE produce solapes o
    -- huecos en las fronteras. Elegimos de forma determinista el mayor umbral
    -- inferior aplicable; cada valor no negativo recibe una sola categoría.
    LEFT JOIN LATERAL (
        SELECT
            categoria
        FROM seed_rangos_aire sr
        WHERE sr.variable = fv.magnitud
          AND CASE
                WHEN sr.rango LIKE '[>%'
                    THEN fv.uom_value > REPLACE(
                        REPLACE(sr.rango, '[>', ''),
                        ']',
                        ''
                    )::DOUBLE
                ELSE fv.uom_value >= SPLIT_PART(
                    REPLACE(
                        REPLACE(sr.rango, '[', ''),
                        ']',
                        ''
                    ),
                    ',',
                    1
                )::DOUBLE
            END
        ORDER BY categoria DESC
        LIMIT 1
    ) sr
        ON TRUE
)


-- ============================================================
-- 16. RESULTADO FINAL
-- ============================================================

SELECT

    -- Madrid hardcodeado
    28 AS provincia,
    79 AS municipio,

    p.estacion,
    p.magnitud,
    p.punto_muestreo,
    p.fecha,
    p.uom,
    p.uom_value,
    p.calidad,


    -- ========================================================
    -- DÍA LABORABLE
    -- ========================================================

    CASE
        WHEN EXTRACT(
            ISODOW FROM p.fecha
        ) IN (6, 7)
        THEN FALSE

        WHEN COALESCE(
            f.es_festivo,
            FALSE
        )
        THEN FALSE

        ELSE TRUE
    END AS es_laborable_madrid_ciudad,


    -- ========================================================
    -- JSON DE METADATOS
    -- ========================================================

    json_object(
        'imputado',
        p.imputado
    ) AS extra


FROM data_classified p

LEFT JOIN tabla_festivos f
    ON p.fecha = f.fecha;
