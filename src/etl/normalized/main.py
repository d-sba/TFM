import argparse
import sys
from pathlib import Path
import duckdb
import polars as pl
import yaml

# 1. Anclamos la ruta base al directorio donde RESIDE este archivo main.py (src/etl/normalized)
MODULE_DIR = Path(__file__).resolve().parent

# 2. La raíz del proyecto (TFM) está 3 niveles arriba: normalized -> etl -> src -> TFM
PROJECT_ROOT = MODULE_DIR.parents[2]


def load_yaml(file_path: Path) -> dict:
    """Carga un archivo YAML validando su existencia."""
    if not file_path.exists():
        raise FileNotFoundError(f"❌ No se encontró el archivo '{file_path}'")
    with open(file_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def resolve_path(path_str: str) -> Path:
    """Resuelve rutas relativas a la raíz del TFM o al propio módulo."""
    p = Path(path_str)
    if p.is_absolute():
        return p

    if any(
        path_str.startswith(prefix) for prefix in ["data/", "src/", "results/"]
    ):
        return PROJECT_ROOT / p

    return MODULE_DIR / p


def get_or_create_parquet(
    con: duckdb.DuckDBPyConnection, file_path: Path, delim: str = ";"
) -> Path:
    """Si el archivo es un CSV, lo convierte a Parquet automáticamente en la

    subcarpeta 'parquet_files/' dentro de su mismo directorio.
    """
    if file_path.suffix.lower() == ".parquet":
        return file_path

    if file_path.suffix.lower() == ".csv":
        # 1. Creamos la subcarpeta data/raw/parquet_files si no existe
        parquet_dir = file_path.parent / "parquet_files"
        parquet_dir.mkdir(parents=True, exist_ok=True)

        # 2. Definimos la ruta de destino: data/raw/parquet_files/DatosAire2020.parquet
        parquet_path = parquet_dir / f"{file_path.stem}.parquet"

        # 3. Convertimos solo si no existe o si el CSV se ha modificado recientemente
        if (
            not parquet_path.exists()
            or file_path.stat().st_mtime > parquet_path.stat().st_mtime
        ):
            print(
                f"   ⚡ Convirtiendo CSV a Parquet: '{file_path.name}' -> 'parquet_files/{parquet_path.name}'..."
            )

            convert_query = f"""
                COPY (
                    SELECT * FROM read_csv_auto('{file_path.as_posix()}', delim='{delim}')
                ) TO '{parquet_path.as_posix()}' (FORMAT PARQUET, COMPRESSION 'SNAPPY');
            """
            con.execute(convert_query)

        return parquet_path

    return file_path


def run_pipeline(
    pipeline_name: str = None,
    pipelines_file: str = "configs/pipelines.yml",
    datasets_file: str = "configs/datasets.yml",
):
    """Orquestador autoreferenciado optimizado para lectura rápida de datos."""
    pipelines_path = resolve_path(pipelines_file)
    datasets_path = resolve_path(datasets_file)

    pipelines_config = load_yaml(pipelines_path)
    datasets_config = load_yaml(datasets_path)

    catalog = datasets_config.get("datasets", {})
    pipelines = pipelines_config.get("pipelines", [])

    if pipeline_name:
        pipelines = [
            p
            for p in pipelines
            if p.get("name").lower() == pipeline_name.lower()
        ]
        if not pipelines:
            print(
                f"⚠️ No se encontró ninguna pipeline con el nombre: '{pipeline_name}'"
            )
            return

    print(
        f"🚀 Ejecutando {len(pipelines)} pipeline(s) desde: {MODULE_DIR.name}\n"
    )

    for i, pipe in enumerate(pipelines, 1):
        name = pipe.get("name", f"Pipeline_{i}")
        print(f"▶ [{i}/{len(pipelines)}] Procesando: '{name}'")

        con = duckdb.connect()

        # 1. Registrar vistas temporales en DuckDB (usando Parquet optimizado)
        sources_dict = pipe.get("sources", {})
        missing_datasets = []

        for alias, dataset_key in sources_dict.items():
            if dataset_key not in catalog:
                missing_datasets.append(dataset_key)
                continue

            ds_info = catalog[dataset_key]

            if isinstance(ds_info, dict):
                raw_path = ds_info.get("path")
                delim = ds_info.get("delim", ";")
            else:
                raw_path = ds_info
                delim = ";"

            source_file = resolve_path(raw_path)

            if not source_file.exists():
                print(
                    f"   ❌ Error: El archivo de origen '{source_file}' no existe."
                )
                continue

            # Conversión o recuperación automática a Parquet
            optimized_parquet_file = get_or_create_parquet(
                con, source_file, delim
            )

            # Crear VISTA temporal leyendo el archivo Parquet
            create_view_sql = f"""
                CREATE OR REPLACE TEMP VIEW {alias} AS 
                SELECT * FROM read_parquet('{optimized_parquet_file.as_posix()}');
            """
            con.execute(create_view_sql)

        if missing_datasets:
            print(
                f"   ❌ Error: Los datasets {missing_datasets} no existen en '{datasets_path}'."
            )
            con.close()
            continue

        # 2. Resolver rutas de SQL y salida
        sql_file = resolve_path(pipe.get("sql_file", ""))
        output_parquet = resolve_path(pipe.get("output_parquet", ""))

        if not sql_file.exists():
            print(f"   ❌ Error: El archivo SQL '{sql_file}' no existe.")
            con.close()
            continue

        output_parquet.parent.mkdir(parents=True, exist_ok=True)

        # 3. Leer la consulta SQL y limpiar el ';' del final
        with open(sql_file, "r", encoding="utf-8") as sf:
            raw_sql = sf.read().strip().rstrip(";")

        # 4. Ejecutar COPY en DuckDB hacia Parquet
        copy_query = f"""
            COPY (
                {raw_sql}
            ) TO '{output_parquet.as_posix()}' (FORMAT PARQUET, COMPRESSION 'SNAPPY');
        """

        try:
            con.execute(copy_query)
            print(f"   ✅ Guardado Parquet en: {output_parquet}")

            # 5. Vista previa con Polars
            df_preview = con.execute(
                f"SELECT * FROM '{output_parquet.as_posix()}' LIMIT 5"
            ).pl()
            print("\n   📊 Vista previa de la tabla final:")
            print(df_preview)
            print("=" * 70 + "\n")

        except Exception as e:
            print(f"   ❌ Error al ejecutar DuckDB o guardar Parquet: {e}\n")

        finally:
            con.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Ejecutor de pipelines ETL de DuckDB."
    )
    parser.add_argument(
        "--pipeline",
        "-p",
        type=str,
        default=None,
        help="Nombre opcional de la pipeline a ejecutar.",
    )

    args = parser.parse_args()
    run_pipeline(pipeline_name=args.pipeline)