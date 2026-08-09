-- Decisiones:
--  1. Limitar datos a Madrid
--  2. Limitar análisis principal a contaminantes 10,9,8,14
--  3. Eliminar registros con concentraciones negativas
--  4. Agregar los datos a nivel diario

WITH filtered_raw AS (
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
      AND an.magnitud IN (8, 9, 10, 14)
      AND an.uom_value >= 0
),
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
data_classified AS (
    SELECT 
        ad.*,
        sr.categoria AS calidad
    FROM aggregated_data ad
    LEFT JOIN seed_rangos_aire sr
        ON ad.magnitud = sr.variable
       AND (
           CASE 
               WHEN sr.rango LIKE '[>%' THEN ad.uom_value > REPLACE(REPLACE(sr.rango, '[>', ''), ']', '')::NUMERIC
               ELSE ad.uom_value BETWEEN 
                        SPLIT_PART(REPLACE(REPLACE(sr.rango, '[', ''), ']', ''), ',', 1)::NUMERIC 
                    AND SPLIT_PART(REPLACE(REPLACE(sr.rango, '[', ''), ']', ''), ',', 2)::NUMERIC
           END
       )
)
SELECT * FROM data_classified;