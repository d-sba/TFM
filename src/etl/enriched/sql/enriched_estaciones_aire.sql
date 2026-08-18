WITH distancias AS (
    SELECT
        s.ESTACION AS estacion,
        s2.ESTACION AS estacion_cercana,

        6371 * 2 * ASIN(
            SQRT(
                POWER(
                    SIN(
                        RADIANS(s2.LATITUD_G - s.LATITUD_G) / 2
                    ),
                    2
                )
                +
                COS(RADIANS(s.LATITUD_G))
                * COS(RADIANS(s2.LATITUD_G))
                * POWER(
                    SIN(
                        RADIANS(s2.LONGITUD_G - s.LONGITUD_G) / 2
                    ),
                    2
                )
            )
        ) AS distancia_km

    FROM seed_estaciones s
    CROSS JOIN seed_estaciones s2

    WHERE s.ESTACION <> s2.ESTACION
),

ranking AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY estacion
            ORDER BY distancia_km
        ) AS rn
    FROM distancias
),

cercanas AS (
    SELECT
        estacion,
        list(estacion_cercana ORDER BY distancia_km) AS ESTACIONES_CERCANAS
    FROM ranking
    WHERE rn <= 5
    GROUP BY estacion
)

SELECT
    s.*,
    c.ESTACIONES_CERCANAS
FROM seed_estaciones s
LEFT JOIN cercanas c
    ON s.ESTACION = c.estacion;