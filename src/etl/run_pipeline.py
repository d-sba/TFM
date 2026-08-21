import argparse
from pathlib import Path

import duckdb
import polars as pl
import yaml


# ============================================================
# RUTAS DEL PROYECTO
# ============================================================

# Directorio donde está este fichero, por ejemplo:
# src/etl/
MODULE_DIR = Path(__file__).resolve().parent

# Raíz del proyecto:
# TFM/
# └── src/
#     └── etl/
#         └── este_fichero.py
PROJECT_ROOT = MODULE_DIR.parents[1]


# ============================================================
# UTILIDADES
# ============================================================

def load_yaml(file_path: Path) -> dict:
    """Carga un archivo YAML validando su existencia."""
    if not file_path.exists():
        raise FileNotFoundError(
            f"❌ No se encontró el archivo '{file_path}'"
        )

    with open(file_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def resolve_path(path_str: str, stage_dir: Path) -> Path:
    """
    Resuelve rutas relativas a:
    - raíz del proyecto para rutas globales
    - carpeta de la etapa para el resto
    """

    p = Path(path_str)

    if p.is_absolute():
        return p

    # Rutas globales del proyecto
    if any(
        path_str.startswith(prefix)
        for prefix in [
            "data/",
            "src/",
            "results/",
            "configs/",
        ]
    ):
        return PROJECT_ROOT / p

    # Rutas relativas a la etapa actual
    # Ejemplo:
    # normalized/sql/customers.sql
    # normalized/tests/customers_test.sql
    return stage_dir / p


def get_or_create_parquet(
    file_path: Path,
    delim: str = ";"
) -> Path:
    """Convierte CSV a Parquet si es necesario."""

    if file_path.suffix.lower() == ".parquet":
        return file_path

    if file_path.suffix.lower() == ".csv":

        parquet_dir = (
            file_path.parent / "parquet_files"
        )

        parquet_dir.mkdir(
            parents=True,
            exist_ok=True
        )

        parquet_path = (
            parquet_dir
            / f"{file_path.stem}.parquet"
        )

        # Solo convertir si no existe
        # o el CSV es más reciente
        if (
            not parquet_path.exists()
            or file_path.stat().st_mtime
            > parquet_path.stat().st_mtime
        ):

            print(
                "   ⚡ Convirtiendo CSV a Parquet: "
                f"'{file_path.name}' -> "
                f"'parquet_files/{parquet_path.name}'..."
            )

            convert_query = f"""
                COPY (
                    SELECT *
                    FROM read_csv_auto(
                        '{file_path.as_posix()}',
                        delim='{delim}'
                    )
                )
                TO '{parquet_path.as_posix()}'
                (
                    FORMAT PARQUET,
                    COMPRESSION 'SNAPPY'
                );
            """

            with duckdb.connect() as local_con:
                local_con.execute(convert_query)

        return parquet_path

    return file_path


# ============================================================
# TESTS DE CALIDAD
# ============================================================

def load_test_query(
    test_sql_file: str,
    stage_dir: Path
) -> str:
    """
    Carga una query SQL de test desde un fichero.

    Las rutas relativas se resuelven respecto a la etapa.
    """

    test_path = resolve_path(
        test_sql_file,
        stage_dir
    )

    if not test_path.exists():
        raise FileNotFoundError(
            f"❌ No se encontró el archivo de test "
            f"'{test_path}'"
        )

    with open(
        test_path,
        "r",
        encoding="utf-8"
    ) as f:
        query = f.read().strip().rstrip(";")

    if not query:
        raise ValueError(
            f"❌ El archivo de test "
            f"'{test_path}' está vacío."
        )

    return query


def run_pipeline_tests(
    con,
    tests: list,
    stage_dir: Path,
    pipeline_name: str,
) -> bool:
    """
    Ejecuta los tests de calidad definidos
    para una pipeline.

    Convención:

        0 filas  -> TEST PASADO
        >=1 fila -> TEST FALLIDO

    Los tests se ejecutan sobre la vista temporal
    'result', que contiene el resultado de la pipeline.

    Devuelve True si todos los tests pasan.
    """

    if not tests:
        print(
            "   ℹ️ No hay tests configurados."
        )
        return True

    print(
        f"\n   🧪 Ejecutando "
        f"{len(tests)} test(s) de calidad..."
    )

    all_passed = True

    for i, test in enumerate(tests, 1):

        # ----------------------------------------------------
        # Validar configuración del YAML
        # ----------------------------------------------------

        if not isinstance(test, dict):

            print(
                f"   ❌ [{i}/{len(tests)}] "
                "Configuración de test inválida."
            )

            all_passed = False
            continue

        test_name = test.get(
            "name",
            f"Test_{i}"
        )

        test_sql_file = test.get(
            "sql_file"
        )

        # La severidad pertenece a cada test y se define en el YAML.
        # Por defecto: error.
        test_severity = str(
            test.get("severity", "error")
        ).lower()

        if test_severity not in ("error", "warning"):
            print(
                f"   ❌ [{i}/{len(tests)}] "
                f"{test_name}: severity inválida "
                f"'{test_severity}'. "
                "Debe ser 'error' o 'warning'."
            )
            all_passed = False
            continue

        if not test_sql_file:

            print(
                f"   ❌ [{i}/{len(tests)}] "
                f"{test_name}: "
                "no se ha especificado 'sql_file'."
            )

            all_passed = False
            continue

        # ----------------------------------------------------
        # Leer SQL del test
        # ----------------------------------------------------

        try:

            test_query = load_test_query(
                test_sql_file,
                stage_dir
            )

        except Exception as e:

            print(
                f"   ❌ [{i}/{len(tests)}] "
                f"{test_name}: {e}"
            )

            all_passed = False
            continue

        # ----------------------------------------------------
        # Ejecutar test
        # ----------------------------------------------------

        try:

            result = con.execute(
                test_query
            )

            # Solo necesitamos saber si existe
            # al menos una fila.
            first_row = result.fetchone()

            if first_row is None:

                print(
                    f"   ✅ [{i}/{len(tests)}] "
                    f"{test_name}"
                )

            else:
                if test_severity == "warning":
                    print(
                        f"   ⚠️ [{i}/{len(tests)}] "
                        f"{test_name} (WARNING)"
                    )

                    print(
                        "      El test ha devuelto "
                        "al menos una fila, "
                        "pero no bloquea la pipeline."
                    )

                    print(
                        f"      Primera fila problemática: "
                        f"{first_row}"
                    )

                else:
                    all_passed = False

                    print(
                        f"   ❌ [{i}/{len(tests)}] "
                        f"{test_name}"
                    )

                    print(
                        "      El test ha devuelto "
                        "al menos una fila."
                    )

                    print(
                        f"      Primera fila problemática: "
                        f"{first_row}"
                    )

        except Exception as e:

            all_passed = False

            print(
                f"   ❌ [{i}/{len(tests)}] "
                f"{test_name}: "
                f"error al ejecutar el test:"
            )

            print(
                f"      {e}"
            )

    # --------------------------------------------------------
    # Resultado global
    # --------------------------------------------------------

    if all_passed:

        print(
            "\n   🎉 Todos los tests "
            "han pasado correctamente."
        )

    else:

        print(
            "\n   🚨 Han fallado "
            "uno o más tests."
        )

    return all_passed


# ============================================================
# PIPELINE PRINCIPAL
# ============================================================

def run_pipeline(
    stage: str = "normalized",
    pipeline_name: str = None
):
    """
    Orquestador de pipelines ETL por capas.

    Soporta:
        - normalized
        - enriched
    """

    # --------------------------------------------------------
    # Directorio de la etapa
    # --------------------------------------------------------

    stage_dir = MODULE_DIR / stage

    if not stage_dir.exists():

        print(
            f"❌ Error: La carpeta de etapa "
            f"'{stage_dir}' no existe."
        )

        return

    # --------------------------------------------------------
    # Configuración
    # --------------------------------------------------------

    configs_folder = (
        stage_dir / "configs"
        if (stage_dir / "configs").exists()
        else stage_dir
    )

    pipelines_path = (
        configs_folder / "pipelines.yml"
    )

    datasets_path = (
        configs_folder / "datasets.yml"
    )

    pipelines_config = load_yaml(
        pipelines_path
    )

    datasets_config = load_yaml(
        datasets_path
    )

    catalog = datasets_config.get(
        "datasets",
        {}
    )

    pipelines = pipelines_config.get(
        "pipelines",
        []
    )

    # --------------------------------------------------------
    # Filtrar pipeline concreta
    # --------------------------------------------------------

    if pipeline_name:

        pipelines = [
            p
            for p in pipelines
            if p.get("name", "").lower()
            == pipeline_name.lower()
        ]

        if not pipelines:

            print(
                f"⚠️ No se encontró ninguna pipeline "
                f"con el nombre '{pipeline_name}' "
                f"en [{stage}]"
            )

            return

    print(
        f"🚀 Ejecutando "
        f"{len(pipelines)} pipeline(s) "
        f"para la capa: "
        f"[{stage.upper()}]\n"
    )

    # ========================================================
    # EJECUTAR PIPELINES
    # ========================================================

    for i, pipe in enumerate(
        pipelines,
        1
    ):

        name = pipe.get(
            "name",
            f"Pipeline_{i}"
        )

        print(
            f"▶ [{i}/{len(pipelines)}] "
            f"Procesando: '{name}'"
        )

        con = duckdb.connect()

        try:

            # =================================================
            # 1. CARGAR SOURCES
            # =================================================

            sources_dict = pipe.get(
                "sources",
                {}
            )

            missing_datasets = []

            for alias, dataset_key in sources_dict.items():

                # ---------------------------------------------
                # Dataset no definido en datasets.yml
                # ---------------------------------------------

                if dataset_key not in catalog:

                    missing_datasets.append(
                        dataset_key
                    )

                    continue

                ds_info = catalog[
                    dataset_key
                ]

                # ---------------------------------------------
                # Obtener path y delimitador
                # ---------------------------------------------

                if isinstance(
                    ds_info,
                    dict
                ):

                    raw_path = ds_info.get(
                        "path"
                    )

                    delim = ds_info.get(
                        "delim",
                        ";"
                    )

                else:

                    raw_path = ds_info

                    delim = ";"

                # ---------------------------------------------
                # Resolver ruta
                # ---------------------------------------------

                source_file = resolve_path(
                    raw_path,
                    stage_dir
                )

                if not source_file.exists():

                    print(
                        "   ❌ Error: El archivo "
                        f"de origen '{source_file}' "
                        "no existe."
                    )

                    missing_datasets.append(
                        dataset_key
                    )

                    continue

                # ---------------------------------------------
                # Optimizar CSV -> Parquet
                # ---------------------------------------------

                optimized_parquet_file = (
                    get_or_create_parquet(
                        source_file,
                        delim
                    )
                )

                # ---------------------------------------------
                # Crear vista temporal
                # ---------------------------------------------

                create_view_sql = f"""
                    CREATE OR REPLACE TEMP VIEW {alias} AS
                    SELECT *
                    FROM read_parquet(
                        '{optimized_parquet_file.as_posix()}'
                    );
                """

                con.execute(
                    create_view_sql
                )

                print(
                    f"   📥 Source '{alias}' "
                    f"← {optimized_parquet_file.name}"
                )

            # =================================================
            # Validar sources
            # =================================================

            if missing_datasets:

                print(
                    f"   ❌ Error: Los datasets "
                    f"{missing_datasets} "
                    f"no existen o no se pudieron cargar."
                )

                print(
                    f"   ⏭️ Pipeline '{name}' omitida.\n"
                )

                continue

            # =================================================
            # 2. RESOLVER SQL Y OUTPUT
            # =================================================

            sql_file = resolve_path(
                pipe.get(
                    "sql_file",
                    ""
                ),
                stage_dir
            )

            output_parquet = resolve_path(
                pipe.get(
                    "output_parquet",
                    ""
                ),
                stage_dir
            )

            if not sql_file.exists():

                print(
                    f"   ❌ Error: El archivo SQL "
                    f"'{sql_file}' no existe."
                )

                print(
                    f"   ⏭️ Pipeline '{name}' omitida.\n"
                )

                continue

            output_parquet.parent.mkdir(
                parents=True,
                exist_ok=True
            )

            # =================================================
            # 3. LEER SQL DE TRANSFORMACIÓN
            # =================================================

            with open(
                sql_file,
                "r",
                encoding="utf-8"
            ) as sf:

                raw_sql = (
                    sf.read()
                    .strip()
                    .rstrip(";")
                )

            if not raw_sql:

                print(
                    f"   ❌ Error: El archivo SQL "
                    f"'{sql_file}' está vacío."
                )

                print(
                    f"   ⏭️ Pipeline '{name}' omitida.\n"
                )

                continue

            # =================================================
            # 4. CREAR RESULTADO TEMPORAL
            # =================================================

            print(
                "   🔄 Ejecutando transformación..."
            )

            create_result_view_sql = f"""
                CREATE OR REPLACE TEMP VIEW result AS
                {raw_sql}
            """

            con.execute(
                create_result_view_sql
            )

            print(
                "   ✅ Transformación ejecutada."
            )

            # =================================================
            # 5. EJECUTAR TESTS
            # =================================================

            tests = pipe.get(
                "tests",
                []
            )

            tests_passed = run_pipeline_tests(
                con=con,
                tests=tests,
                stage_dir=stage_dir,
                pipeline_name=name
            )

            # =================================================
            # 6. SI FALLAN TESTS, NO ESCRIBIR PARQUET
            # =================================================

            if not tests_passed:

                print(
                    f"\n   ⏭️ Pipeline '{name}' "
                    "omitida porque han "
                    "fallado los tests."
                )

                print(
                    "   🚫 No se ha escrito "
                    "el Parquet de salida."
                )

                print(
                    "=" * 70
                    + "\n"
                )

                continue

            # =================================================
            # 7. GUARDAR RESULTADO
            # =================================================

            print(
                "   💾 Tests OK. "
                "Guardando Parquet..."
            )

            if output_parquet.exists():
                print(
                    f"   🔄 Sobrescribiendo Parquet existente: "
                    f"{output_parquet}"
                )
                output_parquet.unlink()

            copy_query = f"""
                COPY (
                    SELECT *
                    FROM result
                )
                TO '{output_parquet.as_posix()}'
                (
                    FORMAT PARQUET,
                    COMPRESSION 'SNAPPY'
                );
            """

            con.execute(copy_query)

            print(
                f"   ✅ Guardado Parquet en: "
                f"{output_parquet}"
            )
            # =================================================
            # 8. VISTA PREVIA
            # =================================================

            df_preview = con.execute(
                f"""
                SELECT *
                FROM read_parquet(
                    '{output_parquet.as_posix()}'
                )
                LIMIT 5
                """
            ).pl()

            print(
                "\n   📊 Vista previa "
                "de la tabla final:"
            )

            print(
                df_preview
            )

            print(
                "=" * 70
                + "\n"
            )

        except Exception as e:

            print(
                f"   ❌ Error en pipeline "
                f"'{name}': {e}\n"
            )

        finally:

            con.close()


# ============================================================
# CLI
# ============================================================

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
        description=(
            "Ejecutor de pipelines ETL "
            "de DuckDB por capas."
        )
    )

    parser.add_argument(
        "--stage",
        "-s",
        type=str,
        default="normalized",
        choices=[
            "normalized",
            "enriched"
        ],
        help=(
            "Capa ETL a ejecutar: "
            "'normalized' o 'enriched' "
            "(por defecto: normalized)."
        ),
    )

    parser.add_argument(
        "--pipeline",
        "-p",
        type=str,
        default=None,
        help=(
            "Nombre opcional de la pipeline "
            "a ejecutar dentro de la capa "
            "especificada."
        ),
    )

    args = parser.parse_args()

    run_pipeline(
        stage=args.stage,
        pipeline_name=args.pipeline
    )