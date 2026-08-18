WITH b1_b2_limpieza AS (
    SELECT
        fecha,
        estacion_id,
        variable_meteo,

        CASE
            WHEN estacion_id = '3200'
                 AND variable_meteo IN ('humedad_max', 'humedad_min')
                THEN NULL

            WHEN estacion_id = '3195'
                 AND variable_meteo = 'insolacion'
                THEN NULL

            ELSE uom_value
        END AS valor

    FROM meteo_normalized

    WHERE estacion_id != '3194U'
),

datos_pivotados AS (
    SELECT
        fecha,
        estacion_id,

        MAX(CASE
            WHEN variable_meteo = 'temp_media'
            THEN valor
        END) AS temp_media,

        MAX(CASE
            WHEN variable_meteo = 'temp_min'
            THEN valor
        END) AS temp_min,

        MAX(CASE
            WHEN variable_meteo = 'temp_max'
            THEN valor
        END) AS temp_max,

        MAX(CASE
            WHEN variable_meteo = 'humedad_media'
            THEN valor
        END) AS humedad_media,

        MAX(CASE
            WHEN variable_meteo = 'humedad_min'
            THEN valor
        END) AS humedad_min,

        MAX(CASE
            WHEN variable_meteo = 'humedad_max'
            THEN valor
        END) AS humedad_max,

        MAX(CASE
            WHEN variable_meteo = 'presion_min'
            THEN valor
        END) AS presion_min,

        MAX(CASE
            WHEN variable_meteo = 'presion_max'
            THEN valor
        END) AS presion_max,

        MAX(CASE
            WHEN variable_meteo = 'insolacion'
            THEN valor
        END) AS insolacion,

        MAX(CASE
            WHEN variable_meteo = 'precipitacion'
            THEN valor
        END) AS precipitacion,

        MAX(CASE
            WHEN variable_meteo = 'viento_velocidad'
            THEN valor
        END) AS viento_velocidad,

        MAX(CASE
            WHEN variable_meteo = 'viento_racha'
            THEN valor
        END) AS viento_racha,

        MAX(CASE
            WHEN variable_meteo = 'direccion_racha_max'
            THEN valor
        END) AS direccion_racha_max

    FROM b1_b2_limpieza

    GROUP BY
        fecha,
        estacion_id
),

-- =============================================================================
-- B3
-- Preparación para interpolación lineal.
--
-- Para cada variable:
--   prev_valid_date = último día con dato válido
--   next_valid_date = siguiente día con dato válido
--
-- Solo interpolaremos si entre ambos hay <= 5 días ausentes.
-- =============================================================================
b3_contexto AS (
    SELECT
        *,
        
        MAX(
            CASE
                WHEN valor IS NOT NULL THEN fecha
            END
        ) OVER (
            PARTITION BY estacion_id, variable_meteo
            ORDER BY fecha
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prev_valid_date,

        MIN(
            CASE
                WHEN valor IS NOT NULL THEN fecha
            END
        ) OVER (
            PARTITION BY estacion_id, variable_meteo
            ORDER BY fecha
            ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
        ) AS next_valid_date,

        fill(valor ORDER BY fecha) OVER (
            PARTITION BY estacion_id, variable_meteo
        ) AS valor_interpolado

    FROM (
        SELECT
            fecha,
            estacion_id,
            variable_meteo,
            valor
        FROM b1_b2_limpieza
        WHERE variable_meteo IN (
            'temp_media',
            'temp_min',
            'temp_max',
            'humedad_media',
            'humedad_min',
            'humedad_max',
            'presion_min',
            'presion_max',
            'insolacion',
            'viento_velocidad'
        )
    ) AS long_data
),


-- =============================================================================
-- B3
-- Aplicar interpolación únicamente a huecos <= 5 días.
--
-- La condición:
--
-- date_diff(prev_valid_date, next_valid_date) - 1 <= 5
--
-- representa el número de días faltantes entre ambos valores válidos.
-- =============================================================================
b3_interpolado_largo AS (
    SELECT
        fecha,
        estacion_id,
        variable_meteo,

        CASE
            WHEN valor IS NOT NULL THEN valor

            WHEN prev_valid_date IS NOT NULL
                 AND next_valid_date IS NOT NULL
                 AND date_diff(
                     'day',
                     prev_valid_date,
                     next_valid_date
                 ) - 1 <= 5

                THEN valor_interpolado

            ELSE NULL
        END AS valor,

        CASE
            WHEN valor IS NULL
                 AND prev_valid_date IS NOT NULL
                 AND next_valid_date IS NOT NULL
                 AND date_diff(
                     'day',
                     prev_valid_date,
                     next_valid_date
                 ) - 1 <= 5

                THEN TRUE

            ELSE FALSE
        END AS flag_interp_corta

    FROM b3_contexto
),


-- =============================================================================
-- Volvemos a pivotar las variables después de B3
-- =============================================================================
b3_pivotado AS (
    SELECT
        fecha,
        estacion_id,

        MAX(CASE WHEN variable_meteo = 'temp_media'
            THEN valor END) AS temp_media,

        MAX(CASE WHEN variable_meteo = 'temp_min'
            THEN valor END) AS temp_min,

        MAX(CASE WHEN variable_meteo = 'temp_max'
            THEN valor END) AS temp_max,

        MAX(CASE WHEN variable_meteo = 'humedad_media'
            THEN valor END) AS humedad_media,

        MAX(CASE WHEN variable_meteo = 'humedad_min'
            THEN valor END) AS humedad_min,

        MAX(CASE WHEN variable_meteo = 'humedad_max'
            THEN valor END) AS humedad_max,

        MAX(CASE WHEN variable_meteo = 'presion_min'
            THEN valor END) AS presion_min,

        MAX(CASE WHEN variable_meteo = 'presion_max'
            THEN valor END) AS presion_max,

        MAX(CASE WHEN variable_meteo = 'insolacion'
            THEN valor END) AS insolacion,

        MAX(CASE WHEN variable_meteo = 'viento_velocidad'
            THEN valor END) AS viento_velocidad,

        MAX(CASE WHEN variable_meteo = 'flag_interp_corta'
            THEN CASE WHEN valor THEN 1 ELSE 0 END END) AS _dummy

    FROM b3_interpolado_largo

    GROUP BY
        fecha,
        estacion_id
),


-- =============================================================================
-- Recuperamos variables que NO pasan por B3
-- =============================================================================
b3_final AS (
    SELECT
        p.fecha,
        p.estacion_id,

        p.temp_media,
        p.temp_min,
        p.temp_max,

        p.humedad_media,
        p.humedad_min,
        p.humedad_max,

        p.presion_min,
        p.presion_max,

        p.insolacion,

        original.precipitacion,
        original.viento_racha,
        original.direccion_racha_max,

        p.viento_velocidad,

        -- Flag B3.
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM b3_interpolado_largo i
                WHERE i.fecha = p.fecha
                  AND i.estacion_id = p.estacion_id
                  AND i.flag_interp_corta = TRUE
            )
            THEN TRUE
            ELSE FALSE
        END AS flag_interp_corta

    FROM b3_pivotado p

    LEFT JOIN datos_pivotados original
        ON p.fecha = original.fecha
        AND p.estacion_id = original.estacion_id
),


-- =============================================================================
-- B4
-- Donantes para Retiro.
--
-- Se utilizan:
--   3200 -> Getafe
--   3129 -> Aeropuerto
--   3196 -> Cuatro Vientos
--
-- Para viento mantenemos la lógica que ya tenías.
-- =============================================================================
donantes_viento AS (
    SELECT
        fecha,

        MAX(CASE
            WHEN estacion_id = '3200'
            THEN viento_velocidad
        END) AS v_getafe,

        MAX(CASE
            WHEN estacion_id = '3129'
            THEN viento_velocidad
        END) AS v_aero,

        MAX(CASE
            WHEN estacion_id = '3196'
            THEN viento_velocidad
        END) AS v_cuatro,

        MAX(CASE
            WHEN estacion_id = '3200'
            THEN viento_racha
        END) AS r_getafe,

        MAX(CASE
            WHEN estacion_id = '3129'
            THEN viento_racha
        END) AS r_aero,

        MAX(CASE
            WHEN estacion_id = '3196'
            THEN viento_racha
        END) AS r_cuatro

    FROM b3_final

    GROUP BY fecha
),


-- =============================================================================
-- B4 PRESIÓN
--
-- Construimos las series de presión de los tres donantes.
-- =============================================================================
donantes_presion AS (
    SELECT
        fecha,

        MAX(CASE
            WHEN estacion_id = '3200'
            THEN presion_max
        END) AS pmax_getafe,

        MAX(CASE
            WHEN estacion_id = '3129'
            THEN presion_max
        END) AS pmax_aero,

        MAX(CASE
            WHEN estacion_id = '3196'
            THEN presion_max
        END) AS pmax_cuatro,

        MAX(CASE
            WHEN estacion_id = '3200'
            THEN presion_min
        END) AS pmin_getafe,

        MAX(CASE
            WHEN estacion_id = '3129'
            THEN presion_min
        END) AS pmin_aero,

        MAX(CASE
            WHEN estacion_id = '3196'
            THEN presion_min
        END) AS pmin_cuatro

    FROM b3_final

    GROUP BY fecha
),


-- =============================================================================
-- B4 PRESIÓN
--
-- Datos de entrenamiento para regresión múltiple.
--
-- Importante:
-- No usamos las fechas que están siendo imputadas en Retiro.
-- El modelo se ajusta sobre observaciones donde Retiro y las 3 donantes
-- están disponibles.
-- =============================================================================
training_presion AS (
    SELECT
        r.fecha,

        r.presion_max AS y_max,
        r.presion_min AS y_min,

        d.pmax_getafe AS x1_max,
        d.pmax_aero AS x2_max,
        d.pmax_cuatro AS x3_max,

        d.pmin_getafe AS x1_min,
        d.pmin_aero AS x2_min,
        d.pmin_cuatro AS x3_min

    FROM b3_final r

    INNER JOIN donantes_presion d
        ON r.fecha = d.fecha

    WHERE r.estacion_id = '3195'

      AND r.presion_max IS NOT NULL
      AND r.presion_min IS NOT NULL

      AND d.pmax_getafe IS NOT NULL
      AND d.pmax_aero IS NOT NULL
      AND d.pmax_cuatro IS NOT NULL

      AND d.pmin_getafe IS NOT NULL
      AND d.pmin_aero IS NOT NULL
      AND d.pmin_cuatro IS NOT NULL
),


-- =============================================================================
-- Estadísticos de regresión múltiple
--
-- Se centra X e Y y se resuelve:
--
--     beta = (X'X)^-1 X'Y
--
-- para las tres estaciones donantes.
-- =============================================================================
stats_presion AS (

    -- ============================================================
    -- 1. MEDIAS DE LAS VARIABLES DE ENTRENAMIENTO
    -- ============================================================
    WITH medias AS (
        SELECT
            AVG(y_max) AS ybar_max,
            AVG(x1_max) AS x1bar_max,
            AVG(x2_max) AS x2bar_max,
            AVG(x3_max) AS x3bar_max,

            AVG(y_min) AS ybar_min,
            AVG(x1_min) AS x1bar_min,
            AVG(x2_min) AS x2bar_min,
            AVG(x3_min) AS x3bar_min

        FROM training_presion
    )

    SELECT

        -- ========================================================
        -- MEDIAS
        -- ========================================================

        ANY_VALUE(m.ybar_max) AS ybar_max,
        ANY_VALUE(m.x1bar_max) AS x1bar_max,
        ANY_VALUE(m.x2bar_max) AS x2bar_max,
        ANY_VALUE(m.x3bar_max) AS x3bar_max,

        ANY_VALUE(m.ybar_min) AS ybar_min,
        ANY_VALUE(m.x1bar_min) AS x1bar_min,
        ANY_VALUE(m.x2bar_min) AS x2bar_min,
        ANY_VALUE(m.x3bar_min) AS x3bar_min,

        -- ========================================================
        -- MATRIZ X'X PARA PRESIÓN MAX
        -- ========================================================

        SUM(
            (t.x1_max - m.x1bar_max)
            * (t.x1_max - m.x1bar_max)
        ) AS s11_max,

        SUM(
            (t.x2_max - m.x2bar_max)
            * (t.x2_max - m.x2bar_max)
        ) AS s22_max,

        SUM(
            (t.x3_max - m.x3bar_max)
            * (t.x3_max - m.x3bar_max)
        ) AS s33_max,

        SUM(
            (t.x1_max - m.x1bar_max)
            * (t.x2_max - m.x2bar_max)
        ) AS s12_max,

        SUM(
            (t.x1_max - m.x1bar_max)
            * (t.x3_max - m.x3bar_max)
        ) AS s13_max,

        SUM(
            (t.x2_max - m.x2bar_max)
            * (t.x3_max - m.x3bar_max)
        ) AS s23_max,

        -- ========================================================
        -- MATRIZ X'Y PARA PRESIÓN MAX
        -- ========================================================

        SUM(
            (t.x1_max - m.x1bar_max)
            * (t.y_max - m.ybar_max)
        ) AS sy1_max,

        SUM(
            (t.x2_max - m.x2bar_max)
            * (t.y_max - m.ybar_max)
        ) AS sy2_max,

        SUM(
            (t.x3_max - m.x3bar_max)
            * (t.y_max - m.ybar_max)
        ) AS sy3_max,

        -- ========================================================
        -- MATRIZ X'X PARA PRESIÓN MIN
        -- ========================================================

        SUM(
            (t.x1_min - m.x1bar_min)
            * (t.x1_min - m.x1bar_min)
        ) AS s11_min,

        SUM(
            (t.x2_min - m.x2bar_min)
            * (t.x2_min - m.x2bar_min)
        ) AS s22_min,

        SUM(
            (t.x3_min - m.x3bar_min)
            * (t.x3_min - m.x3bar_min)
        ) AS s33_min,

        SUM(
            (t.x1_min - m.x1bar_min)
            * (t.x2_min - m.x2bar_min)
        ) AS s12_min,

        SUM(
            (t.x1_min - m.x1bar_min)
            * (t.x3_min - m.x3bar_min)
        ) AS s13_min,

        SUM(
            (t.x2_min - m.x2bar_min)
            * (t.x3_min - m.x3bar_min)
        ) AS s23_min,

        -- ========================================================
        -- MATRIZ X'Y PARA PRESIÓN MIN
        -- ========================================================

        SUM(
            (t.x1_min - m.x1bar_min)
            * (t.y_min - m.ybar_min)
        ) AS sy1_min,

        SUM(
            (t.x2_min - m.x2bar_min)
            * (t.y_min - m.ybar_min)
        ) AS sy2_min,

        SUM(
            (t.x3_min - m.x3bar_min)
            * (t.y_min - m.ybar_min)
        ) AS sy3_min

    FROM training_presion t
    CROSS JOIN medias m
),


-- =============================================================================
-- B4 PRESIÓN
-- Coeficientes mediante inversa de matriz 3x3.
-- =============================================================================
coeficientes_presion AS (
    SELECT
        *,
        
        -- Determinante MAX
        (
            s11_max * (s22_max * s33_max - s23_max * s23_max)
            - s12_max * (s12_max * s33_max - s23_max * s13_max)
            + s13_max * (s12_max * s23_max - s22_max * s13_max)
        ) AS det_max,

        -- Determinante MIN
        (
            s11_min * (s22_min * s33_min - s23_min * s23_min)
            - s12_min * (s12_min * s33_min - s23_min * s13_min)
            + s13_min * (s12_min * s23_min - s22_min * s13_min)
        ) AS det_min

    FROM stats_presion
),


betas_presion AS (
    SELECT

        -- =========================
        -- PRESIÓN MAX
        -- =========================

        ybar_max,

        (
            (
                (s22_max * s33_max - s23_max * s23_max) * sy1_max
                + (s13_max * s23_max - s12_max * s33_max) * sy2_max
                + (s12_max * s23_max - s13_max * s22_max) * sy3_max
            )
            / NULLIF(det_max, 0)
        ) AS beta1_max,

        (
            (
                (s13_max * s23_max - s12_max * s33_max) * sy1_max
                + (s11_max * s33_max - s13_max * s13_max) * sy2_max
                + (s12_max * s13_max - s11_max * s23_max) * sy3_max
            )
            / NULLIF(det_max, 0)
        ) AS beta2_max,

        (
            (
                (s12_max * s23_max - s13_max * s22_max) * sy1_max
                + (s12_max * s13_max - s11_max * s23_max) * sy2_max
                + (s11_max * s22_max - s12_max * s12_max) * sy3_max
            )
            / NULLIF(det_max, 0)
        ) AS beta3_max,

        -- =========================
        -- PRESIÓN MIN
        -- =========================

        ybar_min,

        (
            (
                (s22_min * s33_min - s23_min * s23_min) * sy1_min
                + (s13_min * s23_min - s12_min * s33_min) * sy2_min
                + (s12_min * s23_min - s13_min * s22_min) * sy3_min
            )
            / NULLIF(det_min, 0)
        ) AS beta1_min,

        (
            (
                (s13_min * s23_min - s12_min * s33_min) * sy1_min
                + (s11_min * s33_min - s13_min * s13_min) * sy2_min
                + (s12_min * s13_min - s11_min * s23_min) * sy3_min
            )
            / NULLIF(det_min, 0)
        ) AS beta2_min,

        (
            (
                (s12_min * s23_min - s13_min * s22_min) * sy1_min
                + (s12_min * s13_min - s11_min * s23_min) * sy2_min
                + (s11_min * s22_min - s12_min * s12_min) * sy3_min
            )
            / NULLIF(det_min, 0)
        ) AS beta3_min,

        x1bar_max,
        x2bar_max,
        x3bar_max,

        x1bar_min,
        x2bar_min,
        x3bar_min

    FROM coeficientes_presion
),


-- =============================================================================
-- B4 FINAL
-- Imputación de presión de Retiro.
--
-- Solo se aplica a los huecos de octubre de 2024.
-- =============================================================================
capa_analitica_final AS (
    SELECT

        b.fecha,
        b.estacion_id,

        b.temp_media,
        b.temp_min,
        b.temp_max,

        b.humedad_media,
        b.humedad_min,
        b.humedad_max,

        b.insolacion,
        b.precipitacion,

        b.direccion_racha_max,

        -- -------------------------------------------------------------
        -- VIENTO
        -- -------------------------------------------------------------

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2020-10-01'
                                 AND DATE '2022-03-31'
                 AND b.viento_velocidad IS NULL
            THEN
                COALESCE(
                    0.518
                    + 0.293 * d.v_getafe
                    + 0.173 * d.v_aero
                    + 0.009 * d.v_cuatro,

                    0.520
                    + 0.295 * d.v_getafe
                    + 0.175 * d.v_aero,

                    0.540
                    + 0.310 * d.v_getafe
                    + 0.015 * d.v_cuatro
                )

            ELSE b.viento_velocidad
        END AS viento_velocidad,

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2020-10-01'
                                 AND DATE '2022-03-31'
                 AND b.viento_racha IS NULL
            THEN
                0.518
                + 0.293 * d.r_getafe
                + 0.173 * d.r_aero
                + 0.009 * d.r_cuatro

            ELSE b.viento_racha
        END AS viento_racha,

        -- -------------------------------------------------------------
        -- PRESIÓN
        -- B4: Retiro, octubre 2024
        -- -------------------------------------------------------------

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2024-10-01'
                                 AND DATE '2024-10-31'
                 AND b.presion_max IS NULL
            THEN
                bp.ybar_max
                + bp.beta1_max
                    * (dp.pmax_getafe - bp.x1bar_max)
                + bp.beta2_max
                    * (dp.pmax_aero - bp.x2bar_max)
                + bp.beta3_max
                    * (dp.pmax_cuatro - bp.x3bar_max)

            ELSE b.presion_max
        END AS presion_max,

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2024-10-01'
                                 AND DATE '2024-10-31'
                 AND b.presion_min IS NULL
            THEN
                bp.ybar_min
                + bp.beta1_min
                    * (dp.pmin_getafe - bp.x1bar_min)
                + bp.beta2_min
                    * (dp.pmin_aero - bp.x2bar_min)
                + bp.beta3_min
                    * (dp.pmin_cuatro - bp.x3bar_min)

            ELSE b.presion_min
        END AS presion_min,

        -- -------------------------------------------------------------
        -- FLAGS
        -- -------------------------------------------------------------

        CASE
            WHEN b.flag_interp_corta THEN TRUE

            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2020-10-01'
                                 AND DATE '2022-03-31'
                 AND (
                     b.viento_velocidad IS NULL
                     OR b.viento_racha IS NULL
                 )
                THEN TRUE

            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2024-10-01'
                                 AND DATE '2024-10-31'
                 AND (
                     b.presion_max IS NULL
                     OR b.presion_min IS NULL
                 )
                THEN TRUE

            ELSE FALSE
        END AS flag_imputado,

        CASE
            WHEN b.flag_interp_corta
                THEN 'interpolacion_lineal_corta'

            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2020-10-01'
                                 AND DATE '2022-03-31'
                 AND (
                     b.viento_velocidad IS NULL
                     OR b.viento_racha IS NULL
                 )
                THEN 'regresion_multiple_viento'

            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2024-10-01'
                                 AND DATE '2024-10-31'
                 AND (
                     b.presion_max IS NULL
                     OR b.presion_min IS NULL
                 )
                THEN 'regresion_multiple_presion'

            -- B5: Retiro precipitación
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2023-08-01'
                                 AND DATE '2023-11-30'
                 AND b.precipitacion IS NULL
                THEN 'no_imputado_precipitacion'

            -- B6: Cuatro Vientos insolación
            WHEN b.estacion_id = '3196'
                 AND b.fecha BETWEEN DATE '2024-11-01'
                                 AND DATE '2024-12-31'
                 AND b.insolacion IS NULL
                THEN 'no_imputado_insolacion'

            ELSE 'original'
        END AS metodo_imputacion

    FROM b3_final b

    LEFT JOIN donantes_viento d
        ON b.fecha = d.fecha

    LEFT JOIN donantes_presion dp
        ON b.fecha = dp.fecha

    CROSS JOIN betas_presion bp
)


SELECT *
FROM capa_analitica_final;