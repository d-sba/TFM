SELECT
    estacion,
    magnitud,
    punto_muestreo,
    fecha,
    COUNT(*) AS n_filas
FROM result
GROUP BY
    estacion,
    magnitud,
    punto_muestreo,
    fecha
HAVING COUNT(*) > 1;
