WITH

-- =============================================================================
-- B1 + B2
-- Eliminamos la estacion de CU completa y ciertos pares estacion(variable)
-- =============================================================================

b1_b2_limpieza AS (
    SELECT
        fecha,
        estacion_id,
        variable_meteo AS variable,
        uom,
        uom_value

    FROM meteo_normalized

    WHERE estacion_id != '3194U'
      AND NOT (
          estacion_id = '3200'
          AND variable_meteo IN (
              'humedad_max',
              'humedad_min'
          )
      )
      AND NOT (
          estacion_id = '3195'
          AND variable_meteo = 'insolacion'
      )
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
             AND b.variable = 'viento_velocidad'
             AND b.fecha BETWEEN DATE '2020-10-01'
                             AND DATE '2022-03-31'
             AND b.uom_value IS NULL

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
             AND b.variable = 'viento_velocidad'
             AND b.fecha BETWEEN DATE '2020-10-01'
                             AND DATE '2022-03-31'
             AND b.uom_value IS NULL

                THEN 'regresion_multiple_viento'

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
-- B5
--
-- COMPLETITUD PARA MODELADO
--
-- La tabla enriched es la entrada directa del modelo y, por tanto, no puede
-- contener valores nulos. Los huecos que no resolvieron B3/B4 se completan con
-- la media de las estaciones donantes disponible ese día. Si no hay donantes,
-- se usa la mediana de la misma estación y mes; como último recurso, la mediana
-- global de la variable. La dirección se trata de forma circular.
-- =============================================================================

fallback_diario AS (
    SELECT
        fecha,
        variable,

        AVG(
            CASE
                WHEN variable != 'direccion_racha_max'
                THEN uom_value
            END
        ) AS media_donantes_diaria,

        MOD(
            DEGREES(
                ATAN2(
                    AVG(
                        CASE
                            WHEN variable = 'direccion_racha_max'
                            THEN SIN(RADIANS(uom_value))
                        END
                    ),
                    AVG(
                        CASE
                            WHEN variable = 'direccion_racha_max'
                            THEN COS(RADIANS(uom_value))
                        END
                    )
                )
            ) + 360,
            360
        ) AS direccion_donantes_diaria

    FROM b4_resultado

    GROUP BY
        fecha,
        variable
),


fallback_estacional AS (
    SELECT
        estacion_id,
        variable,
        EXTRACT(MONTH FROM fecha) AS mes,

        MEDIAN(
            CASE
                WHEN variable != 'direccion_racha_max'
                THEN uom_value
            END
        ) AS mediana_estacion_mes,

        MOD(
            DEGREES(
                ATAN2(
                    AVG(
                        CASE
                            WHEN variable = 'direccion_racha_max'
                            THEN SIN(RADIANS(uom_value))
                        END
                    ),
                    AVG(
                        CASE
                            WHEN variable = 'direccion_racha_max'
                            THEN COS(RADIANS(uom_value))
                        END
                    )
                )
            ) + 360,
            360
        ) AS direccion_estacion_mes

    FROM b4_resultado

    GROUP BY
        estacion_id,
        variable,
        EXTRACT(MONTH FROM fecha)
),


fallback_global AS (
    SELECT
        variable,

        MEDIAN(
            CASE
                WHEN variable != 'direccion_racha_max'
                THEN uom_value
            END
        ) AS mediana_global,

        MOD(
            DEGREES(
                ATAN2(
                    AVG(
                        CASE
                            WHEN variable = 'direccion_racha_max'
                            THEN SIN(RADIANS(uom_value))
                        END
                    ),
                    AVG(
                        CASE
                            WHEN variable = 'direccion_racha_max'
                            THEN COS(RADIANS(uom_value))
                        END
                    )
                )
            ) + 360,
            360
        ) AS direccion_global

    FROM b4_resultado

    GROUP BY variable
),


completitud_modelo AS (
    SELECT
        b.fecha,
        b.estacion_id,
        b.variable,
        b.uom,

        CASE
            WHEN b.uom_value IS NOT NULL
                THEN b.uom_value

            WHEN b.variable = 'direccion_racha_max'
                THEN COALESCE(
                    d.direccion_donantes_diaria,
                    e.direccion_estacion_mes,
                    g.direccion_global,
                    0.0
                )

            ELSE COALESCE(
                d.media_donantes_diaria,
                e.mediana_estacion_mes,
                g.mediana_global,
                0.0
            )
        END AS uom_value,

        CASE
            WHEN b.uom_value IS NULL THEN TRUE
            ELSE b.imputado
        END AS imputado,

        CASE
            WHEN b.uom_value IS NOT NULL
                THEN b.metodo_imputacion

            WHEN b.variable = 'direccion_racha_max'
             AND d.direccion_donantes_diaria IS NOT NULL
                THEN 'imputacion_circular_donantes_diaria'

            WHEN b.variable = 'direccion_racha_max'
             AND e.direccion_estacion_mes IS NOT NULL
                THEN 'imputacion_circular_estacional'

            WHEN b.variable = 'direccion_racha_max'
             AND g.direccion_global IS NOT NULL
                THEN 'imputacion_circular_global'

            WHEN d.media_donantes_diaria IS NOT NULL
                THEN 'media_donantes_diaria'

            WHEN e.mediana_estacion_mes IS NOT NULL
                THEN 'mediana_estacion_mes'

            WHEN g.mediana_global IS NOT NULL
                THEN 'mediana_global_variable'

            ELSE 'valor_reserva_cero'
        END AS metodo_imputacion

    FROM b4_resultado b

    LEFT JOIN fallback_diario d
        ON b.fecha = d.fecha
        AND b.variable = d.variable

    LEFT JOIN fallback_estacional e
        ON b.estacion_id = e.estacion_id
        AND b.variable = e.variable
        AND EXTRACT(MONTH FROM b.fecha) = e.mes

    LEFT JOIN fallback_global g
        ON b.variable = g.variable
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

    FROM completitud_modelo
)


SELECT
    fecha,
    estacion_id,
    variable,
    uom,
    uom_value,
    extra

FROM capa_analitica_final;
