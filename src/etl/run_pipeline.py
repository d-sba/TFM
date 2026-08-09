import argparse
import sys
from pathlib import Path
import duckdb
import polars as pl
import yaml

# 1. Anclamos la ruta base al directorio 'src/etl'
MODULE_DIR = Path(__file__).resolve().parent

# 2. La raíz del proyecto (TFM) está 2 niveles arriba: etl -> src -> TFM
PROJECT_ROOT = MODULE_DIR.parents[1]


def load_yaml(file_path: Path) -> dict:
    """Carga un archivo YAML validando su existencia."""
    if not file_path.exists():
        raise FileNotFoundError(f"❌ No se encontró el archivo '{file_path}'")
    with open(file_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def resolve_path(path_str: str, stage_dir: Path) -> Path:
    """Resuelve rutas relativas a la raíz del TFM o a la etapa actual (normalized/enriched)."""
    p = Path(path_str)
    if p.is_absolute():
        return p

    # Rutas globales del proyecto
    if any(
        path_str.startswith(prefix) for prefix in ["data/", "src/", "results/", "configs/"]
    ):
        return PROJECT_ROOT / p

    # Rutas relativas a la carpeta de la etapa actual (ej. src/etl/normalized)
    return stage_dir / p


def get_or_create_parquet(file_path: Path, delim: str = ";") -> Path:
    """Convierte CSV a Parquet si es necesario."""
    if file_path.suffix.lower() == ".parquet":
        return file_path

    if file_path.suffix.lower() == ".csv":
        parquet_dir = file_path.parent / "parquet_files"
        parquet_dir.mkdir(parents=True, exist_ok=True)
        parquet_path = parquet_dir / f"{file_path.stem}.parquet"

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
            with duckdb.connect() as local_con:
                local_con.execute(convert_query)

        return parquet_path

    return file_path


def run_pipeline(stage: str = "normalized", pipeline_name: str = None):
    """Orquestador con soporte dinámico para capas (normalized / enriched)."""
    
    # Directorio de la etapa activa (ej: src/etl/normalized o src/etl/enriched)
    stage_dir = MODULE_DIR / stage
    if not stage_dir.exists():
        print(f"❌ Error: La carpeta de etapa '{stage_dir}' no existe.")
        return

    # Buscar configs dentro de src/etl/{stage}/configs/ (o src/etl/{stage}/ si están sueltos)
    configs_folder = stage_dir / "configs" if (stage_dir / "configs").exists() else stage_dir
    pipelines_path = configs_folder / "pipelines.yml"
    datasets_path = configs_folder / "datasets.yml"

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
                f"⚠️ No se encontró ninguna pipeline con el nombre: '{pipeline_name}' en [{stage}]"
            )
            return

    print(
        f"🚀 Ejecutando {len(pipelines)} pipeline(s) para la capa: [{stage.upper()}]\n"
    )

    for i, pipe in enumerate(pipelines, 1):
        name = pipe.get("name", f"Pipeline_{i}")
        print(f"▶ [{i}/{len(pipelines)}] Procesando: '{name}'")

        con = duckdb.connect()

        # 1. Vistas temporales desde Parquet/CSV
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

            source_file = resolve_path(raw_path, stage_dir)

            if not source_file.exists():
                print(
                    f"   ❌ Error: El archivo de origen '{source_file}' no existe."
                )
                continue

            optimized_parquet_file = get_or_create_parquet(source_file, delim)

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
        sql_file = resolve_path(pipe.get("sql_file", ""), stage_dir)
        output_parquet = resolve_path(pipe.get("output_parquet", ""), stage_dir)

        if not sql_file.exists():
            print(f"   ❌ Error: El archivo SQL '{sql_file}' no existe.")
            con.close()
            continue

        output_parquet.parent.mkdir(parents=True, exist_ok=True)

        # 3. Leer la consulta SQL
        with open(sql_file, "r", encoding="utf-8") as sf:
            raw_sql = sf.read().strip().rstrip(";")

        # 4. Ejecutar COPY
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
        description="Ejecutor de pipelines ETL de DuckDB por capas."
    )
    parser.add_argument(
        "--stage",
        "-s",
        type=str,
        default="normalized",
        choices=["normalized", "enriched"],
        help="Capa ETL a ejecutar: 'normalized' o 'enriched' (por defecto: normalized).",
    )
    parser.add_argument(
        "--pipeline",
        "-p",
        type=str,
        default=None,
        help="Nombre opcional de la pipeline a ejecutar dentro de la capa especificada.",
    )

    args = parser.parse_args()
    run_pipeline(stage=args.stage, pipeline_name=args.pipeline)