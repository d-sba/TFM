from pathlib import Path

import duckdb


# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parents[2]

DATA_DIR = ROOT / "data"
DB_DIR = ROOT / "src/database"
DB_PATH = DB_DIR / "TFM.duckdb"

LAYERS = {
    "normalized": DATA_DIR / "normalized",
    "enriched": DATA_DIR / "enriched",
}


# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

def sanitize_identifier(name: str) -> str:
    """
    Convierte un nombre de fichero en un identificador SQL válido.

    Ejemplo:
        meteo-final.parquet
        -> meteo_final
    """

    name = name.replace("-", "_")
    name = name.replace(" ", "_")

    return name


def create_schema(connection, schema: str):
    connection.execute(
        f'CREATE SCHEMA IF NOT EXISTS "{schema}"'
    )


def create_view(
    connection,
    schema: str,
    table_name: str,
    parquet_path: Path,
):
    """
    Crea una view DuckDB que apunta directamente al Parquet.
    """

    # Ruta absoluta convertida a string SQL-safe
    parquet_str = parquet_path.as_posix().replace("'", "''")

    sql = f"""
        CREATE OR REPLACE VIEW
            "{schema}"."{table_name}"
        AS
        SELECT *
        FROM read_parquet('{parquet_str}');
    """

    connection.execute(sql)


# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

def build_database():

    print("=" * 70)
    print("BUILDING DUCKDB DATABASE")
    print("=" * 70)

    DB_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    # -----------------------------------------------------------------------
    # Connect
    # -----------------------------------------------------------------------

    connection = duckdb.connect(
        str(DB_PATH)
    )

    try:

        total_views = 0

        # -------------------------------------------------------------------
        # Process layers
        # -------------------------------------------------------------------

        for schema, layer_path in LAYERS.items():

            print()
            print(f"[{schema.upper()}]")
            print("-" * 70)

            if not layer_path.exists():

                print(
                    f"⚠️  Directory does not exist: {layer_path}"
                )

                continue

            create_schema(
                connection,
                schema,
            )

            parquet_files = sorted(
                layer_path.rglob("*.parquet")
            )

            if not parquet_files:

                print(
                    "  No Parquet files found."
                )

                continue

            for parquet_path in parquet_files:

                table_name = sanitize_identifier(
                    parquet_path.stem
                )

                print(
                    f"  ✓ {table_name}"
                )
                print(
                    f"    {parquet_path.relative_to(ROOT)}"
                )

                create_view(
                    connection=connection,
                    schema=schema,
                    table_name=table_name,
                    parquet_path=parquet_path,
                )

                total_views += 1

        # -------------------------------------------------------------------
        # Summary
        # -------------------------------------------------------------------

        print()
        print("=" * 70)
        print("DATABASE READY")
        print("=" * 70)

        print(
            f"Database: {DB_PATH}"
        )

        print(
            f"Views created: {total_views}"
        )

        print()
        print("Schemas:")

        schemas = connection.execute(
            """
            SELECT schema_name
            FROM information_schema.schemata
            WHERE schema_name IN ('normalized', 'enriched')
            ORDER BY schema_name
            """
        ).fetchall()

        for (schema,) in schemas:
            print(
                f"  ✓ {schema}"
            )

        return True

    finally:

        connection.close()


# ---------------------------------------------------------------------------
# ENTRY POINT
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    build_database()