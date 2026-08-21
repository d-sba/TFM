WITH

-- =============================================================================
-- B1 + B2
--
-- Correcciones específicas de calidad.
-- =============================================================================

b1_b2_limpieza AS (
    SELECT
        fecha,
        estacion_id,
        variable_meteo AS variable,
        uom,

        CASE
            WHEN estacion_id = '3200'
                 AND variable_meteo IN (
                     'humedad_max',
                     'humedad_min'
                 )
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
--
-- Variables susceptibles de interpolación.
-- =============================================================================

b3_contexto AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,

        -- -------------------------------------------------------------
        -- ÚLTIMO VALOR VÁLIDO ANTERIOR
        -- -------------------------------------------------------------

        LAST_VALUE(
            uom_value IGNORE NULLS
        ) OVER (
            PARTITION BY estacion_id, variable
            ORDER BY fecha
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND 1 PRECEDING
        ) AS prev_value,

        LAST_VALUE(
            CASE
                WHEN uom_value IS NOT NULL
                THEN fecha
            END
            IGNORE NULLS
        ) OVER (
            PARTITION BY estacion_id, variable
            ORDER BY fecha
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND 1 PRECEDING
        ) AS prev_date,

        -- -------------------------------------------------------------
        -- PRIMER VALOR VÁLIDO POSTERIOR
        -- -------------------------------------------------------------

        FIRST_VALUE(
            uom_value IGNORE NULLS
        ) OVER (
            PARTITION BY estacion_id, variable
            ORDER BY fecha
            ROWS BETWEEN 1 FOLLOWING
                     AND UNBOUNDED FOLLOWING
        ) AS next_value,

        FIRST_VALUE(
            CASE
                WHEN uom_value IS NOT NULL
                THEN fecha
            END
            IGNORE NULLS
        ) OVER (
            PARTITION BY estacion_id, variable
            ORDER BY fecha
            ROWS BETWEEN 1 FOLLOWING
                     AND UNBOUNDED FOLLOWING
        ) AS next_date

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
--
-- INTERPOLACIÓN LINEAL
--
-- Solo huecos de <= 5 días.
-- =============================================================================

b3_interpolado AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,

        CASE
            WHEN uom_value IS NOT NULL
                THEN uom_value

            WHEN prev_date IS NOT NULL
             AND next_date IS NOT NULL

             AND date_diff(
                    'day',
                    prev_date,
                    next_date
                 ) - 1 <= 5

            THEN
                prev_value
                +
                (
                    next_value - prev_value
                )
                *
                (
                    CAST(
                        date_diff(
                            'day',
                            prev_date,
                            fecha
                        )
                        AS DOUBLE
                    )
                    /
                    NULLIF(
                        CAST(
                            date_diff(
                                'day',
                                prev_date,
                                next_date
                            )
                            AS DOUBLE
                        ),
                        0
                    )
                )

            ELSE NULL
        END AS uom_value,

        CASE
            WHEN uom_value IS NULL
             AND prev_date IS NOT NULL
             AND next_date IS NOT NULL
             AND date_diff(
                    'day',
                    prev_date,
                    next_date
                 ) - 1 <= 5

                THEN TRUE

            ELSE FALSE
        END AS flag_interp_corta

    FROM b3_contexto
),


-- =============================================================================
-- VARIABLES QUE NO PASAN POR B3
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
-- B3 FINAL LONG
-- =============================================================================

b3_final_long AS (

    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,
        flag_interp_corta

    FROM b3_interpolado

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
-- DONANTES VIENTO
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
-- DONANTES PRESIÓN
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
-- ENTRENAMIENTO PRESIÓN
-- =============================================================================

training_presion AS (
    SELECT
        r.fecha,

        r.uom_value AS y_max,
        pmin.uom_value AS y_min,

        d.pmax_getafe,
        d.pmax_aero,
        d.pmax_cuatro,

        d.pmin_getafe,
        d.pmin_aero,
        d.pmin_cuatro

    FROM b3_final_long r

    INNER JOIN b3_final_long pmin
        ON  r.fecha = pmin.fecha
        AND r.estacion_id = pmin.estacion_id
        AND pmin.variable = 'presion_min'

    INNER JOIN donantes_presion d
        ON r.fecha = d.fecha

    WHERE r.estacion_id = '3195'
      AND r.variable = 'presion_max'

      AND r.uom_value IS NOT NULL
      AND pmin.uom_value IS NOT NULL

      AND d.pmax_getafe IS NOT NULL
      AND d.pmax_aero IS NOT NULL
      AND d.pmax_cuatro IS NOT NULL

      AND d.pmin_getafe IS NOT NULL
      AND d.pmin_aero IS NOT NULL
      AND d.pmin_cuatro IS NOT NULL
),


-- =============================================================================
-- MEDIAS
-- =============================================================================

medias_presion AS (
    SELECT
        AVG(y_max) AS ybar_max,

        AVG(pmax_getafe) AS x1bar_max,
        AVG(pmax_aero) AS x2bar_max,
        AVG(pmax_cuatro) AS x3bar_max,

        AVG(y_min) AS ybar_min,

        AVG(pmin_getafe) AS x1bar_min,
        AVG(pmin_aero) AS x2bar_min,
        AVG(pmin_cuatro) AS x3bar_min

    FROM training_presion
),


-- =============================================================================
-- ESTADÍSTICOS PRESIÓN
-- =============================================================================

stats_presion AS (
    SELECT
        m.*,

        -- =============================================================
        -- MAX
        -- =============================================================

        SUM(
            (t.pmax_getafe - m.x1bar_max)
            * (t.pmax_getafe - m.x1bar_max)
        ) AS s11_max,

        SUM(
            (t.pmax_aero - m.x2bar_max)
            * (t.pmax_aero - m.x2bar_max)
        ) AS s22_max,

        SUM(
            (t.pmax_cuatro - m.x3bar_max)
            * (t.pmax_cuatro - m.x3bar_max)
        ) AS s33_max,

        SUM(
            (t.pmax_getafe - m.x1bar_max)
            * (t.pmax_aero - m.x2bar_max)
        ) AS s12_max,

        SUM(
            (t.pmax_getafe - m.x1bar_max)
            * (t.pmax_cuatro - m.x3bar_max)
        ) AS s13_max,

        SUM(
            (t.pmax_aero - m.x2bar_max)
            * (t.pmax_cuatro - m.x3bar_max)
        ) AS s23_max,

        SUM(
            (t.pmax_getafe - m.x1bar_max)
            * (t.y_max - m.ybar_max)
        ) AS sy1_max,

        SUM(
            (t.pmax_aero - m.x2bar_max)
            * (t.y_max - m.ybar_max)
        ) AS sy2_max,

        SUM(
            (t.pmax_cuatro - m.x3bar_max)
            * (t.y_max - m.ybar_max)
        ) AS sy3_max,


        -- =============================================================
        -- MIN
        -- =============================================================

        SUM(
            (t.pmin_getafe - m.x1bar_min)
            * (t.pmin_getafe - m.x1bar_min)
        ) AS s11_min,

        SUM(
            (t.pmin_aero - m.x2bar_min)
            * (t.pmin_aero - m.x2bar_min)
        ) AS s22_min,

        SUM(
            (t.pmin_cuatro - m.x3bar_min)
            * (t.pmin_cuatro - m.x3bar_min)
        ) AS s33_min,

        SUM(
            (t.pmin_getafe - m.x1bar_min)
            * (t.pmin_aero - m.x2bar_min)
        ) AS s12_min,

        SUM(
            (t.pmin_getafe - m.x1bar_min)
            * (t.pmin_cuatro - m.x3bar_min)
        ) AS s13_min,

        SUM(
            (t.pmin_aero - m.x2bar_min)
            * (t.pmin_cuatro - m.x3bar_min)
        ) AS s23_min,

        SUM(
            (t.pmin_getafe - m.x1bar_min)
            * (t.y_min - m.ybar_min)
        ) AS sy1_min,

        SUM(
            (t.pmin_aero - m.x2bar_min)
            * (t.y_min - m.ybar_min)
        ) AS sy2_min,

        SUM(
            (t.pmin_cuatro - m.x3bar_min)
            * (t.y_min - m.ybar_min)
        ) AS sy3_min

    FROM training_presion t
    CROSS JOIN medias_presion m

    GROUP BY
        m.ybar_max,
        m.x1bar_max,
        m.x2bar_max,
        m.x3bar_max,
        m.ybar_min,
        m.x1bar_min,
        m.x2bar_min,
        m.x3bar_min
),


-- =============================================================================
-- DETERMINANTES
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


-- =============================================================================
-- BETAS
-- =============================================================================

betas_presion AS (
    SELECT

        -- -------------------------------------------------------------
        -- MAX
        -- -------------------------------------------------------------

        ybar_max,
        x1bar_max,
        x2bar_max,
        x3bar_max,

        (
            (
                (s22_max * s33_max - s23_max * s23_max)
                * sy1_max
            )
            +
            (
                (s13_max * s23_max - s12_max * s33_max)
                * sy2_max
            )
            +
            (
                (s12_max * s23_max - s13_max * s22_max)
                * sy3_max
            )
        ) / NULLIF(det_max, 0) AS beta1_max,

        (
            (
                (s13_max * s23_max - s12_max * s33_max)
                * sy1_max
            )
            +
            (
                (s11_max * s33_max - s13_max * s13_max)
                * sy2_max
            )
            +
            (
                (s12_max * s13_max - s11_max * s23_max)
                * sy3_max
            )
        ) / NULLIF(det_max, 0) AS beta2_max,

        (
            (
                (s12_max * s23_max - s13_max * s22_max)
                * sy1_max
            )
            +
            (
                (s12_max * s13_max - s11_max * s23_max)
                * sy2_max
            )
            +
            (
                (s11_max * s22_max - s12_max * s12_max)
                * sy3_max
            )
        ) / NULLIF(det_max, 0) AS beta3_max,


        -- -------------------------------------------------------------
        -- MIN
        -- -------------------------------------------------------------

        ybar_min,
        x1bar_min,
        x2bar_min,
        x3bar_min,

        (
            (
                (s22_min * s33_min - s23_min * s23_min)
                * sy1_min
            )
            +
            (
                (s13_min * s23_min - s12_min * s33_min)
                * sy2_min
            )
            +
            (
                (s12_min * s23_min - s13_min * s22_min)
                * sy3_min
            )
        ) / NULLIF(det_min, 0) AS beta1_min,

        (
            (
                (s13_min * s23_min - s12_min * s33_min)
                * sy1_min
            )
            +
            (
                (s11_min * s33_min - s13_min * s13_min)
                * sy2_min
            )
            +
            (
                (s12_min * s13_min - s11_min * s23_min)
                * sy3_min
            )
        ) / NULLIF(det_min, 0) AS beta2_min,

        (
            (
                (s12_min * s23_min - s13_min * s22_min)
                * sy1_min
            )
            +
            (
                (s12_min * s13_min - s11_min * s23_min)
                * sy2_min
            )
            +
            (
                (s11_min * s22_min - s12_min * s12_min)
                * sy3_min
            )
        ) / NULLIF(det_min, 0) AS beta3_min

    FROM coeficientes_presion
),


-- =============================================================================
-- B4
--
-- IMPUTACIÓN DE VIENTO Y PRESIÓN
-- =============================================================================

b4_resultado AS (
    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        b.uom_value AS valor_original,


        -- =============================================================
        -- VALOR FINAL
        -- =============================================================

        CASE

            -- ---------------------------------------------------------
            -- VIENTO VELOCIDAD
            -- ---------------------------------------------------------

            WHEN b.estacion_id = '3195'
             AND b.variable = 'viento_velocidad'
             AND b.fecha BETWEEN DATE '2020-10-01'
                             AND DATE '2022-03-31'
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


            -- ---------------------------------------------------------
            -- VIENTO RACHA
            -- ---------------------------------------------------------

            WHEN b.estacion_id = '3195'
             AND b.variable = 'viento_racha'
             AND b.fecha BETWEEN DATE '2020-10-01'
                             AND DATE '2022-03-31'
             AND b.uom_value IS NULL

            THEN
                0.518
                + 0.293 * d.r_getafe
                + 0.173 * d.r_aero
                + 0.009 * d.r_cuatro


            -- ---------------------------------------------------------
            -- PRESIÓN MAX
            -- ---------------------------------------------------------

            WHEN b.estacion_id = '3195'
             AND b.variable = 'presion_max'
             AND b.fecha BETWEEN DATE '2024-10-01'
                             AND DATE '2024-10-31'
             AND b.uom_value IS NULL
             AND bp.beta1_max IS NOT NULL
             AND dp.pmax_getafe IS NOT NULL
             AND dp.pmax_aero IS NOT NULL
             AND dp.pmax_cuatro IS NOT NULL

            THEN
                bp.ybar_max
                + bp.beta1_max
                    * (dp.pmax_getafe - bp.x1bar_max)
                + bp.beta2_max
                    * (dp.pmax_aero - bp.x2bar_max)
                + bp.beta3_max
                    * (dp.pmax_cuatro - bp.x3bar_max)


            -- ---------------------------------------------------------
            -- PRESIÓN MIN
            -- ---------------------------------------------------------

            WHEN b.estacion_id = '3195'
             AND b.variable = 'presion_min'
             AND b.fecha BETWEEN DATE '2024-10-01'
                             AND DATE '2024-10-31'
             AND b.uom_value IS NULL
             AND bp.beta1_min IS NOT NULL
             AND dp.pmin_getafe IS NOT NULL
             AND dp.pmin_aero IS NOT NULL
             AND dp.pmin_cuatro IS NOT NULL

            THEN
                bp.ybar_min
                + bp.beta1_min
                    * (dp.pmin_getafe - bp.x1bar_min)
                + bp.beta2_min
                    * (dp.pmin_aero - bp.x2bar_min)
                + bp.beta3_min
                    * (dp.pmin_cuatro - bp.x3bar_min)


            -- ---------------------------------------------------------
            -- ORIGINAL / SIN REGLA B4
            -- ---------------------------------------------------------

            ELSE b.uom_value

        END AS uom_value,


        -- =============================================================
        -- IMPUTADO
        -- =============================================================

        CASE

            WHEN b.flag_interp_corta
                THEN TRUE

            WHEN b.estacion_id = '3195'
             AND b.variable IN (
                 'viento_velocidad',
                 'viento_racha'
             )
             AND b.fecha BETWEEN DATE '2020-10-01'
                             AND DATE '2022-03-31'
             AND b.uom_value IS NULL

            THEN TRUE

            WHEN b.estacion_id = '3195'
             AND b.variable = 'presion_max'
             AND b.fecha BETWEEN DATE '2024-10-01'
                             AND DATE '2024-10-31'
             AND b.uom_value IS NULL
             AND bp.beta1_max IS NOT NULL
             AND dp.pmax_getafe IS NOT NULL
             AND dp.pmax_aero IS NOT NULL
             AND dp.pmax_cuatro IS NOT NULL

            THEN TRUE

            WHEN b.estacion_id = '3195'
             AND b.variable = 'presion_min'
             AND b.fecha BETWEEN DATE '2024-10-01'
                             AND DATE '2024-10-31'
             AND b.uom_value IS NULL
             AND bp.beta1_min IS NOT NULL
             AND dp.pmin_getafe IS NOT NULL
             AND dp.pmin_aero IS NOT NULL
             AND dp.pmin_cuatro IS NOT NULL

            THEN TRUE

            ELSE FALSE

        END AS imputado,


        -- =============================================================
        -- MÉTODO
        -- =============================================================

        CASE

            WHEN b.flag_interp_corta
                THEN 'interpolacion_lineal_corta'

            WHEN b.estacion_id = '3195'
             AND b.variable IN (
                 'viento_velocidad',
                 'viento_racha'
             )
             AND b.fecha BETWEEN DATE '2020-10-01'
                             AND DATE '2022-03-31'
             AND b.uom_value IS NULL

                THEN 'regresion_multiple_viento'

            WHEN b.estacion_id = '3195'
             AND b.variable IN (
                 'presion_max',
                 'presion_min'
             )
             AND b.fecha BETWEEN DATE '2024-10-01'
                             AND DATE '2024-10-31'
             AND b.uom_value IS NULL

                THEN 'regresion_multiple_presion'

            WHEN b.estacion_id = '3195'
             AND b.variable = 'precipitacion'
             AND b.fecha BETWEEN DATE '2023-08-01'
                             AND DATE '2023-11-30'
             AND b.uom_value IS NULL

                THEN 'no_imputado_precipitacion'

            WHEN b.estacion_id = '3196'
             AND b.variable = 'insolacion'
             AND b.fecha BETWEEN DATE '2024-11-01'
                             AND DATE '2024-12-31'
             AND b.uom_value IS NULL

                THEN 'no_imputado_insolacion'

            ELSE 'original'

        END AS metodo_imputacion

    FROM b3_final_long b

    LEFT JOIN donantes_viento d
        ON b.fecha = d.fecha

    LEFT JOIN donantes_presion dp
        ON b.fecha = dp.fecha

    CROSS JOIN betas_presion bp
),


-- =============================================================================
-- RESULTADO FINAL
-- =============================================================================

capa_analitica_final AS (
    SELECT
        fecha,
        estacion_id,
        variable,
        uom,
        uom_value,

        json_object(
            'imputado', imputado,
            'metodo_imputacion', metodo_imputacion
        ) AS extra

    FROM b4_resultado
)


SELECT
    fecha,
    estacion_id,
    variable,
    uom,
    uom_value,
    extra

FROM capa_analitica_final;