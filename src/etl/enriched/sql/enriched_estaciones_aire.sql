WITH distancias AS (

    SELECT
        a.ESTACION AS estacion_aire,

        m.estacion_id AS estacion_meteo,

        6371.0 * 2 * ASIN(
            SQRT(
                POWER(
                    SIN(
                        RADIANS(
                            m.latitud - a.LATITUD_G
                        ) / 2.0
                    ),
                    2
                )
                +
                COS(RADIANS(a.LATITUD_G))
                * COS(RADIANS(m.latitud))
                * POWER(
                    SIN(
                        RADIANS(
                            m.longitud - a.LONGITUD_G
                        ) / 2.0
                    ),
                    2
                )
            )
        ) AS distancia_km

    FROM seed_estaciones_aire AS a

    CROSS JOIN seed_estaciones_meteo AS m

    WHERE a.LATITUD_G IS NOT NULL
      AND a.LONGITUD_G IS NOT NULL
      AND m.latitud IS NOT NULL
      AND m.longitud IS NOT NULL
),


ranking AS (

    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY estacion_aire
            ORDER BY distancia_km
        ) AS rn

    FROM distancias
),


diccionarios AS (

    SELECT
        estacion_aire,

        MAP(
            LIST(estacion_meteo),
            LIST(ROUND(distancia_km, 2))
        ) AS distancias_meteo

    FROM ranking

    WHERE rn <= 5

    GROUP BY estacion_aire
)


SELECT
    a.*,
    d.distancias_meteo

FROM seed_estaciones_aire AS a

LEFT JOIN diccionarios d
    ON a.ESTACION = d.estacion_aire

ORDER BY a.ESTACION;