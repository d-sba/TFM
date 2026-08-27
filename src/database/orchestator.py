"""
Orquestador principal del proyecto.

Ubicación:
    src/database/orchestator.py

Uso:
    python src/database/orchestator.py

Ejecuta siempre:
    1. normalized
    2. enriched
    3. DuckDB

Si una etapa falla, se detiene el proceso.
La ejecución manual de pipelines se mantiene en:
    src/etl/run_pipeline.py
"""

import sys
from pathlib import Path


# ============================================================
# RUTAS
# ============================================================

MODULE_DIR = Path(__file__).resolve().parent       # src/database
SRC_DIR = MODULE_DIR.parent                        # src
PROJECT_ROOT = SRC_DIR.parent                      # TFM
ETL_DIR = SRC_DIR / "etl"


# ============================================================
# IMPORTS
# ============================================================

if str(ETL_DIR) not in sys.path:
    sys.path.insert(0, str(ETL_DIR))

from run_pipeline import run_pipeline
from build_db import build_database


# ============================================================
# ORQUESTADOR
# ============================================================

def run_full_pipeline() -> bool:
    print()
    print("=" * 70)
    print("ORQUESTADOR PRINCIPAL")
    print("=" * 70)
    print(f"Proyecto: {PROJECT_ROOT}")
    print()

    # --------------------------------------------------------
    # 1. NORMALIZED
    # --------------------------------------------------------

    print("=" * 70)
    print("[1/3] EJECUTANDO NORMALIZED")
    print("=" * 70)
    print()

    if not run_pipeline(stage="normalized"):
        print()
        print("=" * 70)
        print("❌ NORMALIZED FALLÓ")
        print("=" * 70)
        print("ENRICHED y DuckDB NO se ejecutarán.")
        return False

    print()
    print("✅ NORMALIZED completado correctamente.")
    print()

    # --------------------------------------------------------
    # 2. ENRICHED
    # --------------------------------------------------------

    print("=" * 70)
    print("[2/3] EJECUTANDO ENRICHED")
    print("=" * 70)
    print()

    if not run_pipeline(stage="enriched"):
        print()
        print("=" * 70)
        print("❌ ENRICHED FALLÓ")
        print("=" * 70)
        print("DuckDB NO se actualizará.")
        return False

    print()
    print("✅ ENRICHED completado correctamente.")
    print()

    # --------------------------------------------------------
    # 3. DUCKDB
    # --------------------------------------------------------

    print("=" * 70)
    print("[3/3] CONSTRUYENDO DUCKDB")
    print("=" * 70)
    print()

    if not build_database():
        print()
        print("=" * 70)
        print("❌ ERROR CONSTRUYENDO DUCKDB")
        print("=" * 70)
        return False

    print()
    print("=" * 70)
    print("✅ PROCESO COMPLETO FINALIZADO")
    print("=" * 70)
    print()
    print("  ✓ normalized")
    print("  ✓ enriched")
    print("  ✓ DuckDB")
    print()

    return True


if __name__ == "__main__":
    sys.exit(0 if run_full_pipeline() else 1)
