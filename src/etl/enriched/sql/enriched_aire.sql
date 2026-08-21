-- =============================================================================
-- METEOROLOGÍA
-- =============================================================================
-- Estructura final:
--
--   fecha
--   estacion_id
--   variable
--   uom
--   uom_value
--   extra
--
-- Las variables NO se convierten en columnas.
-- Cada variable constituye una fila independiente.
--
-- La información de imputación se guarda en extra como JSON:
--
-- {
--   "imputado": true,
--   "metodo_imputacion": "..."
-- }
--
-- =============================================================================


WITH
-- =============================================================================
-- B1 + B2
-- Limpieza inicial manteniendo el modelo LONG.
-- =============================================================================

b1_b2_limpieza AS (
    SELECT
        fecha,
        estacion_id,
        variable_meteo AS variable,
        uom,

        CASE
            WHEN estacion_id = '3200'
                 AND variable_meteo IN ('humedad_max', 'humedad_min')
                THEN NULL

            WHEN estacion_id = '3195'
                 AND variable_meteo = 'insolacion'
                THEN NULL

            ELSE uom_value
        END AS uom_value

    FROM meteo_normalized

    WHERE estacion_id != '3194U'
),


-- =============================================================================
-- B3
-- Contexto para interpolación lineal.
--
-- Solo se aplica a:
--   temp_media
--   temp_min
--   temp_max
--   humedad_media
--   humedad_min
--   humedad_max
--   presion_min
--   presion_max
--   insolacion
--   viento_velocidad
--
-- Se mantiene una fila por:
--   fecha + estacion + variable
-- =============================================================================

b3_contexto AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,

        MAX(
            CASE
                WHEN uom_value IS NOT NULL THEN fecha
            END
        ) OVER (
            PARTITION BY estacion_id, variable
            ORDER BY fecha
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS prev_valid_date,

        MIN(
            CASE
                WHEN uom_value IS NOT NULL THEN fecha
            END
        ) OVER (
            PARTITION BY estacion_id, variable
            ORDER BY fecha
            ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
        ) AS next_valid_date,

        fill(
            uom_value ORDER BY fecha
        ) OVER (
            PARTITION BY estacion_id, variable
        ) AS uom_value_interpolado

    FROM b1_b2_limpieza

    WHERE variable IN (
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
),


-- =============================================================================
-- B3
-- Aplicamos interpolación únicamente a huecos <= 5 días.
-- =============================================================================

b3_interpolado_largo AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,

        CASE
            WHEN uom_value IS NOT NULL
                THEN uom_value

            WHEN prev_valid_date IS NOT NULL
                 AND next_valid_date IS NOT NULL
                 AND date_diff(
                     'day',
                     prev_valid_date,
                     next_valid_date
                 ) - 1 <= 5

                THEN uom_value_interpolado

            ELSE NULL
        END AS uom_value,

        CASE
            WHEN uom_value IS NULL
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
-- Recuperamos las variables que NO pasan por B3.
--
-- IMPORTANTE:
-- No se hace ningún pivot.
-- =============================================================================

variables_no_b3 AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,

        FALSE AS flag_interp_corta

    FROM b1_b2_limpieza

    WHERE variable IN (
        'precipitacion',
        'viento_racha',
        'direccion_racha_max'
    )
),


-- =============================================================================
-- B3 BASE FINAL LONG
--
-- Unimos:
--   1. variables que pasan por B3
--   2. variables que no pasan por B3
--
-- Sigue habiendo una fila por variable.
-- =============================================================================

b3_final_long AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,
        flag_interp_corta

    FROM b3_interpolado_largo

    UNION ALL

    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,
        flag_interp_corta

    FROM variables_no_b3
),


-- =============================================================================
-- B4
-- DONANTES DE VIENTO
--
-- Internamente calculamos las series de las estaciones donantes.
-- Esto es una estructura técnica para poder aplicar las regresiones.
-- La salida final sigue siendo LONG.
--
--   3200 -> Getafe
--   3129 -> Aeropuerto
--   3196 -> Cuatro Vientos
-- =============================================================================

donantes_viento AS (
    SELECT
        fecha,

        MAX(
            CASE
                WHEN estacion_id = '3200'
                 AND variable = 'viento_velocidad'
                THEN uom_value
            END
        ) AS v_getafe,

        MAX(
            CASE
                WHEN estacion_id = '3129'
                 AND variable = 'viento_velocidad'
                THEN uom_value
            END
        ) AS v_aero,

        MAX(
            CASE
                WHEN estacion_id = '3196'
                 AND variable = 'viento_velocidad'
                THEN uom_value
            END
        ) AS v_cuatro,

        MAX(
            CASE
                WHEN estacion_id = '3200'
                 AND variable = 'viento_racha'
                THEN uom_value
            END
        ) AS r_getafe,

        MAX(
            CASE
                WHEN estacion_id = '3129'
                 AND variable = 'viento_racha'
                THEN uom_value
            END
        ) AS r_aero,

        MAX(
            CASE
                WHEN estacion_id = '3196'
                 AND variable = 'viento_racha'
                THEN uom_value
            END
        ) AS r_cuatro

    FROM b3_final_long

    GROUP BY fecha
),


-- =============================================================================
-- B4
-- DONANTES DE PRESIÓN
-- =============================================================================

donantes_presion AS (
    SELECT
        fecha,

        MAX(
            CASE
                WHEN estacion_id = '3200'
                 AND variable = 'presion_max'
                THEN uom_value
            END
        ) AS pmax_getafe,

        MAX(
            CASE
                WHEN estacion_id = '3129'
                 AND variable = 'presion_max'
                THEN uom_value
            END
        ) AS pmax_aero,

        MAX(
            CASE
                WHEN estacion_id = '3196'
                 AND variable = 'presion_max'
                THEN uom_value
            END
        ) AS pmax_cuatro,

        MAX(
            CASE
                WHEN estacion_id = '3200'
                 AND variable = 'presion_min'
                THEN uom_value
            END
        ) AS pmin_getafe,

        MAX(
            CASE
                WHEN estacion_id = '3129'
                 AND variable = 'presion_min'
                THEN uom_value
            END
        ) AS pmin_aero,

        MAX(
            CASE
                WHEN estacion_id = '3196'
                 AND variable = 'presion_min'
                THEN uom_value
            END
        ) AS pmin_cuatro

    FROM b3_final_long

    GROUP BY fecha
),


-- =============================================================================
-- B4 PRESIÓN
-- Datos de entrenamiento para regresión múltiple.
--
-- Se utilizan únicamente observaciones reales.
-- =============================================================================

training_presion AS (
    SELECT
        r.fecha,

        r.uom_value AS y_max,

        pmin.uom_value AS y_min,

        dp.pmax_getafe AS x1_max,
        dp.pmax_aero   AS x2_max,
        dp.pmax_cuatro AS x3_max,

        dp.pmin_getafe AS x1_min,
        dp.pmin_aero   AS x2_min,
        dp.pmin_cuatro AS x3_min

    FROM b3_final_long r

    INNER JOIN b3_final_long pmin
        ON r.fecha = pmin.fecha
       AND r.estacion_id = pmin.estacion_id
       AND pmin.variable = 'presion_min'

    INNER JOIN donantes_presion dp
        ON r.fecha = dp.fecha

    WHERE r.estacion_id = '3195'
      AND r.variable = 'presion_max'

      AND r.uom_value IS NOT NULL
      AND pmin.uom_value IS NOT NULL

      AND dp.pmax_getafe IS NOT NULL
      AND dp.pmax_aero IS NOT NULL
      AND dp.pmax_cuatro IS NOT NULL

      AND dp.pmin_getafe IS NOT NULL
      AND dp.pmin_aero IS NOT NULL
      AND dp.pmin_cuatro IS NOT NULL
),


-- =============================================================================
-- ESTADÍSTICOS DE REGRESIÓN
-- =============================================================================

stats_presion AS (

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

        ANY_VALUE(m.ybar_max) AS ybar_max,
        ANY_VALUE(m.x1bar_max) AS x1bar_max,
        ANY_VALUE(m.x2bar_max) AS x2bar_max,
        ANY_VALUE(m.x3bar_max) AS x3bar_max,

        ANY_VALUE(m.ybar_min) AS ybar_min,
        ANY_VALUE(m.x1bar_min) AS x1bar_min,
        ANY_VALUE(m.x2bar_min) AS x2bar_min,
        ANY_VALUE(m.x3bar_min) AS x3bar_min,


        -- =============================================================
        -- X'X PRESIÓN MAX
        -- =============================================================

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


        -- =============================================================
        -- X'Y PRESIÓN MAX
        -- =============================================================

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


        -- =============================================================
        -- X'X PRESIÓN MIN
        -- =============================================================

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


        -- =============================================================
        -- X'Y PRESIÓN MIN
        -- =============================================================

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
-- COEFICIENTES
-- =============================================================================

coeficientes_presion AS (
    SELECT
        *,

        (
            s11_max * (
                s22_max * s33_max
                - s23_max * s23_max
            )
            - s12_max * (
                s12_max * s33_max
                - s23_max * s13_max
            )
            + s13_max * (
                s12_max * s23_max
                - s22_max * s13_max
            )
        ) AS det_max,

        (
            s11_min * (
                s22_min * s33_min
                - s23_min * s23_min
            )
            - s12_min * (
                s12_min * s33_min
                - s23_min * s13_min
            )
            + s13_min * (
                s12_min * s23_min
                - s22_min * s13_min
            )
        ) AS det_min

    FROM stats_presion
),


betas_presion AS (
    SELECT

        -- =============================================================
        -- PRESIÓN MAX
        -- =============================================================

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


        -- =============================================================
        -- PRESIÓN MIN
        -- =============================================================

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
-- B4
-- PREPARAMOS LOS VALORES IMPUTADOS DE VIENTO Y PRESIÓN.
--
-- Se generan en LONG:
--
--   fecha + estacion + variable + uom_value
--
-- =============================================================================

b4_imputaciones AS (

    -- =============================================================
    -- VIENTO VELOCIDAD
    -- =============================================================

    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        COALESCE(
            CASE
                WHEN b.estacion_id = '3195'
                     AND b.fecha BETWEEN DATE '2020-10-01'
                                         AND DATE '2022-03-31'
                     AND b.variable = 'viento_velocidad'
                     AND b.uom_value IS NULL

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

                ELSE NULL
            END,

            b.uom_value
        ) AS uom_value,

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2020-10-01'
                                     AND DATE '2022-03-31'
                 AND b.variable = 'viento_velocidad'
                 AND b.uom_value IS NULL

            THEN
                'regresion_multiple_viento'

            ELSE NULL
        END AS metodo_imputacion

    FROM b3_final_long b

    LEFT JOIN donantes_viento d
        ON b.fecha = d.fecha

    WHERE b.variable = 'viento_velocidad'


    UNION ALL


    -- =============================================================
    -- VIENTO RACHA
    -- =============================================================

    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        COALESCE(
            CASE
                WHEN b.estacion_id = '3195'
                     AND b.fecha BETWEEN DATE '2020-10-01'
                                         AND DATE '2022-03-31'
                     AND b.variable = 'viento_racha'
                     AND b.uom_value IS NULL

                THEN
                    0.518
                    + 0.293 * d.r_getafe
                    + 0.173 * d.r_aero
                    + 0.009 * d.r_cuatro

                ELSE NULL
            END,

            b.uom_value
        ) AS uom_value,

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2020-10-01'
                                     AND DATE '2022-03-31'
                 AND b.variable = 'viento_racha'
                 AND b.uom_value IS NULL

            THEN
                'regresion_multiple_viento'

            ELSE NULL
        END AS metodo_imputacion

    FROM b3_final_long b

    LEFT JOIN donantes_viento d
        ON b.fecha = d.fecha

    WHERE b.variable = 'viento_racha'


    UNION ALL


    -- =============================================================
    -- PRESIÓN MAX
    -- =============================================================

    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        COALESCE(
            CASE
                WHEN b.estacion_id = '3195'
                     AND b.fecha BETWEEN DATE '2024-10-01'
                                         AND DATE '2024-10-31'
                     AND b.variable = 'presion_max'
                     AND b.uom_value IS NULL

                THEN
                    bp.ybar_max
                    + bp.beta1_max
                        * (dp.pmax_getafe - bp.x1bar_max)
                    + bp.beta2_max
                        * (dp.pmax_aero - bp.x2bar_max)
                    + bp.beta3_max
                        * (dp.pmax_cuatro - bp.x3bar_max)

                ELSE NULL
            END,

            b.uom_value
        ) AS uom_value,

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2024-10-01'
                                     AND DATE '2024-10-31'
                 AND b.variable = 'presion_max'
                 AND b.uom_value IS NULL

            THEN
                'regresion_multiple_presion'

            ELSE NULL
        END AS metodo_imputacion

    FROM b3_final_long b

    LEFT JOIN donantes_presion dp
        ON b.fecha = dp.fecha

    CROSS JOIN betas_presion bp

    WHERE b.variable = 'presion_max'


    UNION ALL


    -- =============================================================
    -- PRESIÓN MIN
    -- =============================================================

    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        COALESCE(
            CASE
                WHEN b.estacion_id = '3195'
                     AND b.fecha BETWEEN DATE '2024-10-01'
                                         AND DATE '2024-10-31'
                     AND b.variable = 'presion_min'
                     AND b.uom_value IS NULL

                THEN
                    bp.ybar_min
                    + bp.beta1_min
                        * (dp.pmin_getafe - bp.x1bar_min)
                    + bp.beta2_min
                        * (dp.pmin_aero - bp.x2bar_min)
                    + bp.beta3_min
                        * (dp.pmin_cuatro - bp.x3bar_min)

                ELSE NULL
            END,

            b.uom_value
        ) AS uom_value,

        CASE
            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2024-10-01'
                                     AND DATE '2024-10-31'
                 AND b.variable = 'presion_min'
                 AND b.uom_value IS NULL

            THEN
                'regresion_multiple_presion'

            ELSE NULL
        END AS metodo_imputacion

    FROM b3_final_long b

    LEFT JOIN donantes_presion dp
        ON b.fecha = dp.fecha

    CROSS JOIN betas_presion bp

    WHERE b.variable = 'presion_min'
),


-- =============================================================================
-- B4 FINAL LONG
--
-- Variables que tienen una imputación B4 utilizan el valor calculado.
-- Las demás conservan el resultado B3/original.
-- =============================================================================

b4_final_long AS (
    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        COALESCE(
            i.uom_value,
            b.uom_value
        ) AS uom_value,

        CASE
            WHEN i.metodo_imputacion IS NOT NULL
                THEN TRUE

            WHEN b.flag_interp_corta
                THEN TRUE

            ELSE FALSE
        END AS imputado,

        CASE
            WHEN i.metodo_imputacion IS NOT NULL
                THEN i.metodo_imputacion

            WHEN b.flag_interp_corta
                THEN 'interpolacion_lineal_corta'

            WHEN b.estacion_id = '3195'
                 AND b.fecha BETWEEN DATE '2023-08-01'
                                     AND DATE '2023-11-30'
                 AND b.variable = 'precipitacion'
                 AND b.uom_value IS NULL
                THEN 'no_imputado_precipitacion'

            WHEN b.estacion_id = '3196'
                 AND b.fecha BETWEEN DATE '2024-11-01'
                                     AND DATE '2024-12-31'
                 AND b.variable = 'insolacion'
                 AND b.uom_value IS NULL
                THEN 'no_imputado_insolacion'

            ELSE 'original'
        END AS metodo_imputacion

    FROM b3_final_long b

    LEFT JOIN b4_imputaciones i
        ON b.fecha = i.fecha
       AND b.estacion_id = i.estacion_id
       AND b.variable = i.variable
),


-- =============================================================================
-- RESULTADO FINAL
--
-- Una fila = una variable.
--
-- Ejemplo:
--
-- fecha       estacion variable             uom    uom_value
-- 2024-10-01  3195     temp_media           °C     18.2
-- 2024-10-01  3195     temp_min             °C     12.1
-- 2024-10-01  3195     presion_max          hPa    1012.4
-- 2024-10-01  3195     presion_min          hPa    1002.7
-- 2024-10-01  3195     viento_velocidad     km/h   11.3
--
-- =============================================================================

capa_analitica_final AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,

        json_object(
            'imputado',
            imputado,

            'metodo_imputacion',
            metodo_imputacion
        ) AS extra

    FROM b4_final_long
)


SELECT
    fecha,
    estacion_id,
    variable,
    uom,
    uom_value,
    extra

FROM capa_analitica_final;