WITH data_20_23 AS (
    SELECT * FROM aire20
    UNION ALL 
    SELECT * FROM aire21
    UNION ALL
    SELECT * FROM aire22
    UNION ALL
    SELECT * FROM aire23
),
unpivoted_data AS (
    UNPIVOT data_20_23
    ON h01, h02, h03, h04, h05, h06, h07, h08,
       h09, h10, h11, h12, h13, h14, h15, h16,
       h17, h18, h19, h20, h21, h22, h23, h24
    INTO
        NAME variable
        VALUE valor
)
SELECT
    provincia,
    municipio,
    estacion,
    magnitud,
    "punto muestreo" AS punto_muestreo,
    MAKE_DATE(anno, mes, dia) AS fecha,
    variable,
    valor
FROM unpivoted_data;