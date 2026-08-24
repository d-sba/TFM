SELECT
    estacion_id,
    fecha,
    variable,
    COUNT(*) AS n_filas
FROM result
GROUP BY
    estacion_id,
    fecha,
    variable
HAVING COUNT(*) > 1;
