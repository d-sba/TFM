from pathlib import Path
import polars as pl

# Ruta raíz del proyecto
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# Ruta del dataset normalizado
AIR_FILE = PROJECT_ROOT / "data" / "normalized" / "fact" / "calidad_aire_historico.parquet"

# Cargar datos
df = pl.read_parquet(AIR_FILE)

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

# 6. Rango temporal
print("\n📅 RANGO TEMPORAL")
print(f"Fecha mínima: {df['fecha'].min()}")
print(f"Fecha máxima: {df['fecha'].max()}")

# 7. Valores únicos
print("\n🔢 VALORES ÚNICOS")
print(f"Provincias: {df['provincia'].n_unique():,}")
print(f"Municipios: {df['municipio'].n_unique():,}")
print(f"Estaciones: {df['estacion'].n_unique():,}")
print(f"Magnitudes: {df['magnitud'].n_unique():,}")
print(f"Puntos de muestreo: {df['punto_muestreo'].n_unique():,}")
print(f"Unidades: {df['uom'].n_unique():,}")

# 8. Distribución de unidades
print("\n📏 DISTRIBUCIÓN DE UNIDADES")
print(
    df.group_by("uom")
      .agg(pl.len().alias("n_registros"))
      .sort("n_registros", descending=True)
)

# 9. Estadísticos básicos
print("\n📊 ESTADÍSTICOS DE uom_value")
print(
    df.select(
        pl.col("uom_value").min().alias("mínimo"),
        pl.col("uom_value").max().alias("máximo"),
        pl.col("uom_value").mean().alias("media"),
        pl.col("uom_value").median().alias("mediana")
    )
)

print("\n" + "=" * 70)
print("FIN DE LA AUDITORÍA")
print("=" * 70)