from pathlib import Path
import polars as pl


# Ruta raíz del proyecto
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# Ruta del dataset normalizado de calidad del aire
AIR_FILE = PROJECT_ROOT / "data" / "normalized" / "fact" / "calidad_aire_historico.parquet"


# Cargar datos
df = pl.read_parquet(AIR_FILE)

print("\n🔍 EJEMPLOS DE VALORES DE uom_value")
print(
    df.select("uom_value")
    .unique()
    .head(30)
)


print("\n🔍 UNIDADES Y NÚMERO DE REGISTROS")
print(
    df.group_by("uom")
    .agg(
        pl.len().alias("n_registros")
    )
    .sort("n_registros", descending=True)
)


print("\n🔍 MAGNITUDES CON uom NULO")
print(
    df.filter(pl.col("uom").is_null())
    .group_by("magnitud")
    .agg(
        pl.len().alias("n_registros")
    )
    .sort("n_registros", descending=True)
)


print("\n🔍 MAGNITUDES Y UNIDADES")
print(
    df.group_by(["magnitud", "uom"])
    .agg(
        pl.len().alias("n_registros")
    )
    .sort(["magnitud", "n_registros"], descending=[False, True])
)

print("=" * 70)
print("AUDITORÍA INICIAL - CALIDAD DEL AIRE")
print("=" * 70)

# 1. Dimensiones
print("\n📐 DIMENSIONES")
print(f"Número de filas: {df.height:,}")
print(f"Número de columnas: {df.width}")


# 2. Columnas
print("\n📋 COLUMNAS")
print(df.columns)


# 3. Tipos de datos
print("\n🔤 TIPOS DE DATOS")
print(df.schema)


# 4. Primeras filas
print("\n👀 PRIMERAS 5 FILAS")
print(df.head())


# 5. Valores nulos
print("\n❓ VALORES NULOS")
print(df.null_count())


# 6. Duplicados
print("\n🔁 DUPLICADOS")
duplicados = df.height - df.unique().height
print(f"Número de filas duplicadas: {duplicados:,}")


# 7. Rango temporal
print("\n📅 RANGO TEMPORAL")
print(f"Fecha mínima: {df['fecha'].min()}")
print(f"Fecha máxima: {df['fecha'].max()}")


# 8. Número de valores únicos
print("\n🔢 VALORES ÚNICOS")

print(f"Provincias: {df['provincia'].n_unique():,}")
print(f"Municipios: {df['municipio'].n_unique():,}")
print(f"Estaciones: {df['estacion'].n_unique():,}")
print(f"Magnitudes: {df['magnitud'].n_unique():,}")
print(f"Puntos de muestreo: {df['punto_muestreo'].n_unique():,}")
print(f"Unidades: {df['uom'].n_unique():,}")


print("\n" + "=" * 70)
print("FIN DE LA AUDITORÍA")
print("=" * 70)