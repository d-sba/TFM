"""
Análisis de Componentes Principales (PCA) exploratorio
========================================================
Aplica PCA por separado a los datasets normalizados de:
  - Calidad del aire  -> data/normalized/fact/calidad_aire_historico.parquet
  - Meteorología AEMET -> data/normalized/fact/meteo_aemet_historico.parquet

Requisitos:
    pip install pandas pyarrow duckdb scikit-learn matplotlib seaborn

Uso:
    Coloca este archivo en la raíz del repo (junto a data/, src/, results/) y
    corre:
        python pca_exploratorio.py
"""

from pathlib import Path
import gc

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns
from sklearn.decomposition import PCA
from sklearn.preprocessing import StandardScaler

PROJECT_ROOT = Path(__file__).resolve().parent  # asume que el script está en la raíz del repo

# --------------------------------------------------------------------------
# FIX: datasets.yml apunta a "Nox_HH_2024.csv" pero el archivo real en el
# repo es "NOx_HH_2024.csv". En Windows/macOS (no distinguen mayúsculas) no
# se nota, pero en Linux sí falla. Lo corregimos aquí, sin tocar el repo
# original en GitHub.
# --------------------------------------------------------------------------

_datasets_yml = PROJECT_ROOT / "src" / "etl" / "normalized" / "configs" / "datasets.yml"
if _datasets_yml.exists():
    _contenido = _datasets_yml.read_text(encoding="utf-8")
    if "Nox_HH_2024.csv" in _contenido:
        _datasets_yml.write_text(
            _contenido.replace("Nox_HH_2024.csv", "NOx_HH_2024.csv"), encoding="utf-8"
        )
        print("🔧 Corregido mismatch de mayúsculas: Nox_HH_2024.csv -> NOx_HH_2024.csv")

# --------------------------------------------------------------------------
# CONFIGURACIÓN
# --------------------------------------------------------------------------

DATA_FACT_DIR = PROJECT_ROOT / "data" / "normalized" / "fact"
RESULTS_DIR = PROJECT_ROOT / "results" / "pca"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

AIRE_PARQUET = DATA_FACT_DIR / "calidad_aire_historico.parquet"
METEO_PARQUET = DATA_FACT_DIR / "meteo_aemet_historico.parquet"

VARIANZA_OBJETIVO = 0.90  # % de varianza acumulada a alcanzar


# --------------------------------------------------------------------------
# FUNCIONES AUXILIARES
# --------------------------------------------------------------------------

def cargar_y_pivotar_aire(path: Path) -> pd.DataFrame:
    """Carga la tabla de hechos de aire (formato largo, horario) y la agrega
    a MEDIA DIARIA + pivota a formato ancho, todo dentro de DuckDB.

    Importante: los datos son horarios (2020-2024, ~24 estaciones x 9
    contaminantes) — pivotar ese detalle horario directamente con pandas
    puede agotar la RAM en Colab. Al agregar a diario primero (24x menos
    filas) y dejar que DuckDB haga el trabajo pesado en disco/streaming,
    evitamos ese problema.

    Además, traduce los códigos numéricos de 'magnitud' (1, 6, 8...) a sus
    nombres reales (SO2, CO, NO2...) usando dim_variable_aire.parquet, para
    que las columnas del resultado sean legibles.
    """
    import duckdb

    dim_path = (
        path.parent.parent / "static_files" / "dim_variable_aire.parquet"
    )

    con = duckdb.connect()

    if dim_path.exists():
        expr_magnitud = "COALESCE(dim.ABREVIATURA, CAST(base.magnitud AS VARCHAR))"
        join_clause = f"""
            LEFT JOIN read_parquet('{dim_path.as_posix()}') AS dim
                ON base.magnitud = dim.MAGNITUD
        """
    else:
        print(f"   ⚠️  No se encontró {dim_path}, se usarán los códigos numéricos de magnitud.")
        expr_magnitud = "CAST(base.magnitud AS VARCHAR)"
        join_clause = ""

    df_diario_largo = con.execute(f"""
        WITH base AS (
            SELECT
                estacion,
                CAST(fecha AS DATE) AS fecha,
                magnitud,
                TRY_CAST(
                    NULLIF(REPLACE(CAST(uom_value AS VARCHAR), ',', '.'), '')
                    AS DOUBLE
                ) AS valor
            FROM read_parquet('{path.as_posix()}')
        )
        SELECT
            base.estacion,
            base.fecha,
            {expr_magnitud} AS magnitud,
            AVG(base.valor) AS valor
        FROM base
        {join_clause}
        GROUP BY base.estacion, base.fecha, {expr_magnitud}
    """).df()
    con.close()

    wide = df_diario_largo.pivot_table(
        index=["estacion", "fecha"],
        columns="magnitud",
        values="valor",
        aggfunc="mean",
    ).reset_index()

    wide.columns.name = None
    return wide


def cargar_y_pivotar_meteo(path: Path) -> pd.DataFrame:
    """Carga la tabla de hechos de meteo (formato largo) y la pivota a formato
    ancho: una fila por estación+fecha, una columna por variable meteorológica.

    'viento_direccion' viene en grados (0-360) y es una variable CIRCULAR:
    359° y 1° representan casi la misma dirección (norte), pero numéricamente
    están en extremos opuestos. Usarla tal cual en grados distorsiona el PCA
    (y cualquier método basado en distancias/correlación lineal), así que se
    descompone en 'viento_direccion_sin' y 'viento_direccion_cos', que sí
    respetan la continuidad circular.
    """
    import numpy as np

    df = pd.read_parquet(path)

    wide = df.pivot_table(
        index=["estacion_id", "fecha"],
        columns="variable_meteo",
        values="valor",
        aggfunc="mean",
    ).reset_index()

    wide.columns.name = None

    if "viento_direccion" in wide.columns:
        radianes = np.deg2rad(wide["viento_direccion"])
        wide["viento_direccion_sin"] = np.sin(radianes)
        wide["viento_direccion_cos"] = np.cos(radianes)
        wide = wide.drop(columns=["viento_direccion"])

    return wide


def detectar_atipicos(X: pd.DataFrame, factor_iqr: float = 1.5) -> pd.Series:
    """Detecta valores atípicos por columna usando el método IQR (rango
    intercuartílico): atípico si está fuera de [Q1 - factor*IQR, Q3 + factor*IQR].
    Devuelve el % de valores atípicos por columna e imprime un resumen.
    """
    Q1 = X.quantile(0.25)
    Q3 = X.quantile(0.75)
    IQR = Q3 - Q1
    limite_inf = Q1 - factor_iqr * IQR
    limite_sup = Q3 + factor_iqr * IQR

    es_atipico = (X < limite_inf) | (X > limite_sup)
    pct_atipicos = es_atipico.mean().sort_values(ascending=False)

    print(f"   🔎 Atípicos detectados (método IQR, factor={factor_iqr}):")
    for col, pct in pct_atipicos.items():
        print(f"        - {col}: {pct:.1%} de valores atípicos")

    return pct_atipicos


def tratar_atipicos_winsorizar(X: pd.DataFrame, factor_iqr: float = 1.5) -> pd.DataFrame:
    """Recorta (winsoriza) los valores atípicos a los límites de Q1/Q3 ± factor*IQR,
    en vez de eliminar filas completas por un solo valor extremo en una columna."""
    Q1 = X.quantile(0.25)
    Q3 = X.quantile(0.75)
    IQR = Q3 - Q1
    limite_inf = Q1 - factor_iqr * IQR
    limite_sup = Q3 + factor_iqr * IQR
    return X.clip(lower=limite_inf, upper=limite_sup, axis=1)


def preparar_matriz_numerica(
    df_wide: pd.DataFrame,
    columnas_id: list[str],
    umbral_nulos: float = 0.3,
    tratar_atipicos: bool = False,
    factor_iqr: float = 1.5,
) -> pd.DataFrame:
    """Deja solo columnas numéricas, descarta las que tienen demasiados nulos,
    elimina filas incompletas restantes, y reporta (y opcionalmente trata)
    valores atípicos con el método IQR.

    tratar_atipicos=False (default): solo REPORTA el % de atípicos por
        columna, no los modifica. Recomendado como primer paso — muchos
        "atípicos" en aire/meteo son eventos reales (olas de calor,
        episodios de contaminación), no errores de medición.
    tratar_atipicos=True: además los winsoriza (recorta a los límites del
        IQR) antes de devolver la matriz.
    """
    X = df_wide.drop(columns=columnas_id, errors="ignore")

    # Descartar columnas con más de `umbral_nulos` proporción de NaN
    prop_nulos = X.isna().mean().sort_values(ascending=False)
    columnas_ok = prop_nulos[prop_nulos <= umbral_nulos].index
    descartadas = prop_nulos[prop_nulos > umbral_nulos]
    conservadas = prop_nulos[prop_nulos <= umbral_nulos]

    if len(descartadas):
        print(f"   ⚠️  Columnas descartadas por exceso de nulos (>{umbral_nulos:.0%}):")
        for col, pct in descartadas.items():
            print(f"        - {col}: {pct:.1%} nulos")
    if len(conservadas):
        print(f"   ✅ Columnas conservadas:")
        for col, pct in conservadas.items():
            print(f"        - {col}: {pct:.1%} nulos")

    X = X[columnas_ok]

    filas_antes = len(X)
    X = X.dropna()
    print(f"   ℹ️  Filas: {filas_antes} -> {len(X)} tras eliminar nulos restantes")

    # --- Atípicos: siempre se reportan; solo se tratan si se pide ---
    detectar_atipicos(X, factor_iqr=factor_iqr)
    if tratar_atipicos:
        X = tratar_atipicos_winsorizar(X, factor_iqr=factor_iqr)
        print(f"   🔧 Atípicos winsorizados (recortados a límites IQR x{factor_iqr})")

    return X


def ejecutar_pca(X: pd.DataFrame, nombre_dataset: str):
    """Estandariza, ajusta PCA y genera scree plot + heatmap de loadings."""
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    pca = PCA()
    componentes = pca.fit_transform(X_scaled)

    varianza_exp = pca.explained_variance_ratio_
    varianza_acum = varianza_exp.cumsum()

    # Nº de componentes necesarios para alcanzar el objetivo de varianza
    n_componentes_objetivo = int((varianza_acum < VARIANZA_OBJETIVO).sum()) + 1

    print(f"\n=== PCA: {nombre_dataset} ===")
    print(f"Variables analizadas: {list(X.columns)}")
    print(f"Varianza explicada por componente:\n{varianza_exp.round(3)}")
    print(f"Varianza acumulada:\n{varianza_acum.round(3)}")
    print(f"Componentes necesarios para {VARIANZA_OBJETIVO:.0%} de varianza: {n_componentes_objetivo}")

    # --- Scree plot ---
    fig, ax = plt.subplots(figsize=(7, 5))
    ax.plot(range(1, len(varianza_exp) + 1), varianza_acum, marker="o", label="Acumulada")
    ax.bar(range(1, len(varianza_exp) + 1), varianza_exp, alpha=0.4, label="Individual")
    ax.axhline(VARIANZA_OBJETIVO, color="red", linestyle="--", label=f"{VARIANZA_OBJETIVO:.0%}")
    ax.set_xlabel("Componente principal")
    ax.set_ylabel("Varianza explicada")
    ax.set_title(f"Scree plot — {nombre_dataset}")
    ax.legend()
    fig.tight_layout()
    scree_path = RESULTS_DIR / f"scree_plot_{nombre_dataset}.png"
    fig.savefig(scree_path, dpi=150)
    plt.close(fig)
    print(f"   💾 Scree plot guardado en: {scree_path}")

    # --- Loadings (pesos de cada variable en cada componente) ---
    loadings = pd.DataFrame(
        pca.components_.T,
        columns=[f"PC{i+1}" for i in range(pca.n_components_)],
        index=X.columns,
    )
    loadings_path = RESULTS_DIR / f"loadings_{nombre_dataset}.csv"
    loadings.to_csv(loadings_path)
    print(f"   💾 Loadings guardados en: {loadings_path}")

    # Heatmap de los primeros componentes (hasta el objetivo de varianza)
    fig, ax = plt.subplots(figsize=(8, max(4, 0.4 * len(X.columns))))
    sns.heatmap(
        loadings.iloc[:, :n_componentes_objetivo],
        annot=True,
        fmt=".2f",
        cmap="coolwarm",
        center=0,
        ax=ax,
    )
    ax.set_title(f"Loadings (primeros {n_componentes_objetivo} PC) — {nombre_dataset}")
    fig.tight_layout()
    heatmap_path = RESULTS_DIR / f"loadings_heatmap_{nombre_dataset}.png"
    fig.savefig(heatmap_path, dpi=150)
    plt.close(fig)
    print(f"   💾 Heatmap de loadings guardado en: {heatmap_path}")

    # --- Proyección de las observaciones sobre PC1 vs PC2 ---
    if pca.n_components_ >= 2:
        fig, ax = plt.subplots(figsize=(7, 6))
        ax.scatter(componentes[:, 0], componentes[:, 1], alpha=0.3, s=10)
        ax.set_xlabel(f"PC1 ({varianza_exp[0]:.1%} varianza)")
        ax.set_ylabel(f"PC2 ({varianza_exp[1]:.1%} varianza)")
        ax.set_title(f"Proyección PC1 vs PC2 — {nombre_dataset}")
        fig.tight_layout()
        scatter_path = RESULTS_DIR / f"pc1_pc2_{nombre_dataset}.png"
        fig.savefig(scatter_path, dpi=150)
        plt.close(fig)
        print(f"   💾 Proyección PC1 vs PC2 guardada en: {scatter_path}")

    return pca, loadings, varianza_acum


# --------------------------------------------------------------------------
# SCRIPT PRINCIPAL
# --------------------------------------------------------------------------

def main():
    # ----- Calidad del aire -----
    if AIRE_PARQUET.exists():
        print(f"📂 Cargando {AIRE_PARQUET} ...")
        df_aire_wide = cargar_y_pivotar_aire(AIRE_PARQUET)
        X_aire = preparar_matriz_numerica(df_aire_wide, columnas_id=["estacion", "fecha"])
        if not X_aire.empty:
            ejecutar_pca(X_aire, nombre_dataset="calidad_aire")
        else:
            print("   ❌ No quedaron datos suficientes tras limpiar nulos.")
        del df_aire_wide, X_aire
        gc.collect()
    else:
        print(f"❌ No se encontró {AIRE_PARQUET}. "
              f"Ejecuta antes: python src/etl/normalized/main.py --pipeline aire_normalizado")

    # ----- Meteorología -----
    if METEO_PARQUET.exists():
        print(f"\n📂 Cargando {METEO_PARQUET} ...")
        df_meteo_wide = cargar_y_pivotar_meteo(METEO_PARQUET)
        X_meteo = preparar_matriz_numerica(df_meteo_wide, columnas_id=["estacion_id", "fecha"])
        if not X_meteo.empty:
            ejecutar_pca(X_meteo, nombre_dataset="meteo")
        else:
            print("   ❌ No quedaron datos suficientes tras limpiar nulos.")
    else:
        print(f"❌ No se encontró {METEO_PARQUET}. "
              f"Ejecuta antes: python src/etl/normalized/main.py --pipeline meteo_aemet_normalizado")


if __name__ == "__main__":
    main()
