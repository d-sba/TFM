WITH aire_24 AS (
    SELECT * FROM C6H6
    UNION ALL
    SELECT * FROM CO
    UNION ALL
    SELECT * FROM NO_
    UNION ALL
    SELECT * FROM NO2
    UNION ALL
    SELECT * FROM NOx
    UNION ALL
    SELECT * FROM O3
    UNION ALL
    SELECT * FROM PM10
    UNION ALL
    SELECT * FROM PM25
    UNION ALL
    SELECT * FROM SO2
),
data_20_23 AS (
    SELECT * FROM aire20
    UNION ALL 
    SELECT * FROM aire21
    UNION ALL
    SELECT * FROM aire22
    UNION ALL
    SELECT * FROM aire23
),
total_data AS (
    SELECT * FROM data_20_23
    UNION ALL
    SELECT * FROM aire_24
),
unpivoted_data AS (
    UNPIVOT total_data
    ON h01, h02, h03, h04, h05, h06, h07, h08,
       h09, h10, h11, h12, h13, h14, h15, h16,
       h17, h18, h19, h20, h21, h22, h23, h24
    INTO
        NAME hora
        VALUE valor
)
SELECT
    up.provincia,
    up.municipio,
    up.estacion,
    up.magnitud,
    up."punto muestreo" AS punto_muestreo,
    MAKE_TIMESTAMP(
        up.anno, 
        up.mes, 
        up.dia, 
        CAST(REPLACE(up.hora, 'h', '') AS INT) - 1, 
        0, 
        0
    ) AS fecha,
    seed.UNIDAD AS uom,
    up.valor AS uom_value
FROM unpivoted_data AS up
LEFT JOIN dimension_unidades_aire AS seed
    ON up.magnitud = seed.MAGNITUD;