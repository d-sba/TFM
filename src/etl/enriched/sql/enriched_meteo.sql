WITH 
-- =============================================================================
-- B1 & B2: Filtrado de Ciudad Universitaria y anulación de pares (B2)
-- =============================================================================
b1_b2_limpieza AS (
    SELECT 
        fecha,
        estacion_id,
        estacion_nombre,
        variable_meteo,
        
        -- B2: Anular pares específicos directamente en la variable correspondiente
        CASE 
            WHEN estacion_id = '3200' AND variable_meteo IN ('humedad_max', 'humedad_min') THEN NULL
            WHEN estacion_id = '3195' AND variable_meteo = 'insolacion' THEN NULL
            ELSE valor
        END AS valor_limpio
    FROM meteo_normalized
    -- B1: Excluir Ciudad Universitaria (3194U) completa
    WHERE estacion_id != '3194U'
),

-- Pivotado para trabajar con series por variable
datos_pivotados AS (
    SELECT 
        fecha,
        estacion_id,
        estacion_nombre,
        MAX(CASE WHEN variable_meteo = 'viento_velocidad' THEN valor_limpio END) AS viento_velocidad,
        MAX(CASE WHEN variable_meteo = 'viento_racha' THEN valor_limpio END) AS viento_racha,
        MAX(CASE WHEN variable_meteo = 'precipitacion' THEN valor_limpio END) AS precipitacion,
        MAX(CASE WHEN variable_meteo = 'humedad_max' THEN valor_limpio END) AS humedad_max,
        MAX(CASE WHEN variable_meteo = 'humedad_min' THEN valor_limpio END) AS humedad_min,
        MAX(CASE WHEN variable_meteo = 'insolacion' THEN valor_limpio END) AS insolacion,
        MAX(CASE WHEN variable_meteo = 'temp_media' THEN valor_limpio END) AS temp_media,
        MAX(CASE WHEN variable_meteo = 'temp_max' THEN valor_limpio END) AS temp_max,
        MAX(CASE WHEN variable_meteo = 'temp_min' THEN valor_limpio END) AS temp_min
    FROM b1_b2_limpieza
    GROUP BY fecha, estacion_id, estacion_nombre
),

-- =============================================================================
-- B3: Interpolación lineal temporal para huecos <= 5 días
-- =============================================================================
b3_con_bloques AS (
    SELECT *,
        COUNT(viento_velocidad) OVER (PARTITION BY estacion_id ORDER BY fecha) AS grp_viento
    FROM datos_pivotados
),
b3_interpolado AS (
    SELECT 
        fecha,
        estacion_id,
        estacion_nombre,
        humedad_max,
        humedad_min,
        insolacion,
        precipitacion,
        temp_media,
        temp_max,
        temp_min,
        
        CASE 
            WHEN viento_velocidad IS NULL 
                 AND COUNT(*) OVER (PARTITION BY estacion_id, grp_viento) <= 5 THEN
                AVG(viento_velocidad) OVER (
                    PARTITION BY estacion_id 
                    ORDER BY fecha 
                    ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING
                )
            ELSE viento_velocidad 
        END AS viento_velocidad_b3,
        
        CASE 
            WHEN viento_velocidad IS NULL 
                 AND COUNT(*) OVER (PARTITION BY estacion_id, grp_viento) <= 5 THEN TRUE 
            ELSE FALSE 
        END AS flag_interp_corta,
        
        viento_racha
    FROM b3_con_bloques
),

-- =============================================================================
-- B4: Extracción de series donantes para Retiro (3195)
-- Donantes: Getafe (3200), Aeropuerto (3129), Cuatro Vientos (3196)
-- =============================================================================
donantes AS (
    SELECT 
        fecha,
        MAX(CASE WHEN estacion_id = '3200' THEN viento_velocidad_b3 END) AS v_getafe,
        MAX(CASE WHEN estacion_id = '3129' THEN viento_velocidad_b3 END) AS v_aero,
        MAX(CASE WHEN estacion_id = '3196' THEN viento_velocidad_b3 END) AS v_cuatro,
        
        MAX(CASE WHEN estacion_id = '3200' THEN viento_racha END) AS r_getafe,
        MAX(CASE WHEN estacion_id = '3129' THEN viento_racha END) AS r_aero,
        MAX(CASE WHEN estacion_id = '3196' THEN viento_racha END) AS r_cuatro
    FROM b3_interpolado
    GROUP BY fecha
),

-- =============================================================================
-- B4, B5 y B6: Imputación por Regresión Múltiple, Regla de Reserva y B6 (Extremos)
-- =============================================================================
capa_analitica_final AS (
    SELECT 
        b.fecha,
        b.estacion_id,
        b.estacion_nombre,
        b.humedad_max,
        b.humedad_min,
        b.insolacion,
        b.precipitacion,
        b.temp_media,
        b.temp_max,
        b.temp_min,
        
        -- B4: Regresión Lineal Múltiple para Retiro (Oct 2020 - Mar 2022)
        -- Fórmula: Retiro = 0.518 + 0.293*Getafe + 0.173*Aeropuerto + 0.009*Cuatro Vientos
        CASE 
            WHEN b.estacion_id = '3195' 
                 AND b.fecha BETWEEN '2020-10-01' AND '2022-03-31' 
                 AND b.viento_velocidad_b3 IS NULL THEN
                
                COALESCE(
                    -- Modelo Principal (3 donantes)
                    (0.518 + (0.293 * d.v_getafe) + (0.173 * d.v_aero) + (0.009 * d.v_cuatro)),
                    -- Regla de reserva 1 (Falta Cuatro Vientos)
                    (0.520 + (0.295 * d.v_getafe) + (0.175 * d.v_aero)),
                    -- Regla de reserva 2 (Falta Aeropuerto)
                    (0.540 + (0.310 * d.v_getafe) + (0.015 * d.v_cuatro)),
                    -- Regla de reserva 3 (Media ponderada de disponibles)
                    (0.518 + 0.475 * COALESCE(d.v_getafe, d.v_aero, d.v_cuatro))
                )
            ELSE b.viento_velocidad_b3
        END AS viento_velocidad,

        -- B4: viento_racha con la misma técnica
        CASE 
            WHEN b.estacion_id = '3195' 
                 AND b.fecha BETWEEN '2020-10-01' AND '2022-03-31' 
                 AND b.viento_racha IS NULL THEN
                (0.518 + (0.293 * d.r_getafe) + (0.173 * d.r_aero) + (0.009 * d.r_cuatro))
            ELSE b.viento_racha
        END AS viento_racha,

        -- B3 & B4: Flags de imputación
        CASE 
            WHEN b.estacion_id = '3195' AND b.fecha BETWEEN '2020-10-01' AND '2022-03-31' THEN TRUE
            WHEN b.flag_interp_corta THEN TRUE
            ELSE FALSE
        END AS flag_imputado,

        CASE 
            WHEN b.estacion_id = '3195' AND b.fecha BETWEEN '2020-10-01' AND '2022-03-31' 
                THEN 'regresion_multiple'
            WHEN b.flag_interp_corta 
                THEN 'interpolacion_lineal_corta'
            WHEN b.estacion_id = '3195' AND b.fecha BETWEEN '2023-08-01' AND '2023-11-30' 
                 AND b.precipitacion IS NULL 
                THEN 'no_imputado_excluido_b5'
            ELSE 'original'
        END AS metodo_imputacion

    FROM b3_interpolado b
    LEFT JOIN donantes d ON b.fecha = d.fecha
)

SELECT * FROM capa_analitica_final;