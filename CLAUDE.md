# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

TFM (Trabajo Fin de Máster) analyzing Madrid air quality vs. meteorological data. Comments, docstrings, and print output throughout the codebase are in Spanish — match that when editing existing pipeline/SQL/notebook code.

## Commands

There is no test suite, linter, or formatter configured in this repo (no pytest, no pyproject.toml/setup.cfg). Data quality checks live inside the ETL pipeline itself (see below).

Install dependencies:
```
pip install -r requirements.txt
```
Note: `requirements.txt` only covers the raw HTTP/data-transport deps (requests, numpy, pandas, duckdb, polars, PyYAML, pyarrow). Modeling scripts/notebooks additionally require `scikit-learn`, `matplotlib`, `seaborn`, and `xgboost`, which are not pinned anywhere — install as needed.

Run an ETL stage (defaults to `normalized`):
```
python src/etl/run_pipeline.py --stage normalized
python src/etl/run_pipeline.py --stage enriched
```
Run a single pipeline within a stage:
```
python src/etl/run_pipeline.py --stage enriched --pipeline aire_enriched
```

Rebuild the local DuckDB catalog (creates `src/database/TFM.duckdb` with views over every Parquet file under `data/normalized` and `data/enriched`):
```
python src/database/build_db.py
```

Run the standalone PCA exploration script (reads `data/normalized/fact/*.parquet`, writes plots/loadings to `results/pca/`):
```
python src/models/pca/pca_exploratorio.py
```

Everything else (EDA, imputation write-ups, XGBoost modeling) lives in Jupyter notebooks under `src/eda/Notebooks/` and `src/models/xgboost/<pollutant>/` and is run interactively.

## Architecture

### Data layers (medallion-style)

`data/raw` → `data/normalized` → `data/enriched`, all Parquet, all produced by DuckDB SQL run through the same generic pipeline engine (`src/etl/run_pipeline.py`). There is no ORM/Python transformation layer — business logic lives in the `.sql` files, not in Python.

- **raw**: source CSVs from the Madrid air quality portal (`datos_aire/`, one file per year 2020–2023 plus per-pollutant hourly files for 2024) and AEMET meteorological CSVs (`datos_meteo/`), plus static reference CSVs (`static_files/`: pollutant/variable dimensions, quality-range thresholds, station metadata, public holidays). CSVs are tracked via Git LFS (`.gitattributes`).
- **normalized**: long-format fact tables (`fact/calidad_aire_historico.parquet`, `fact/meteo_aemet_historico.parquet`) produced by unpivoting the raw hourly/wide CSVs, plus normalized seed/dimension tables (`static_files/`).
- **enriched**: business-ready fact tables (`fact/calidad_aire_final.parquet`, `fact/meteo_final.parquet`) and dimension tables (`dims/dim_estaciones_*.parquet`), with quality classification, holiday/workday flags, and spatial imputation applied.

### Pipeline engine (`src/etl/run_pipeline.py`)

A single generic orchestrator drives both the `normalized` and `enriched` stages via `--stage`. Per stage, two YAML files under `src/etl/<stage>/configs/` define everything:
- `datasets.yml` — catalog of named source datasets (`path` + CSV `delim`).
- `pipelines.yml` — list of pipelines, each with `sources` (alias → dataset key), `sql_file` (the transform, relative to `src/etl/<stage>/sql/`), `output_parquet`, and optional `tests` (SQL files relative to `src/etl/<stage>/tests/`).

For each pipeline the engine: loads each source CSV as a DuckDB view (auto-converting CSV→Parquet under a sibling `parquet_files/` cache, keyed on mtime), runs the pipeline's SQL as a `result` view, runs any quality tests against that view, and — only if all `error`-severity tests pass (`warning` tests don't block) — writes `result` to `output_parquet`. A test SQL file must return **zero rows** to pass; any row is a failure. If any source dataset or test fails, that pipeline is skipped and no Parquet is written, but other pipelines in the run continue.

Path resolution (`resolve_path`): strings starting with `data/`, `src/`, `results/`, or `configs/` resolve relative to the project root; everything else resolves relative to the current stage directory (`src/etl/<stage>/`).

### Database layer (`src/database/build_db.py`)

Builds a single `src/database/TFM.duckdb` with one schema per layer (`normalized`, `enriched`), each schema populated with **views** (not materialized tables) pointing directly at the corresponding `data/<layer>/**/*.parquet` files via `read_parquet()`. Re-run after regenerating Parquet outputs to refresh the views — DuckDB and Parquet files themselves are gitignored, so this is a local build step, not something to commit.

### Domain-specific transform logic worth knowing before touching the SQL

- `dn_air_transformer.sql` unions 2020–2023 (wide, one column per pollutant) with 2024 (wide, one file per pollutant) air-quality CSVs, then `UNPIVOT`s the hourly columns (`h01`..`h24`) into long format, and joins the pollutant-code dimension for units.
- `enriched_aire.sql` performs **IDW (inverse-distance-weighted) spatial imputation** for a fixed set of pollutant codes (station-measured-history-aware: a station never gets imputed rows for a pollutant it has never measured), using Haversine distance and per-pollutant `(k, p)` configs. It also assigns air-quality categories from range lookup tables and a Madrid-city workday flag (weekends + holidays from a festivos table = non-workday). Province/municipality are hardcoded to Madrid (28/79) — this pipeline is Madrid-specific, not general.
- Wind direction (`viento_direccion`, degrees) is a circular variable; anywhere it's consumed for modeling (see `pca_exploratorio.py`) it must be decomposed into sin/cos components rather than used raw, to avoid distorting distance/correlation-based methods.

### Modeling

`src/models/pca/pca_exploratorio.py` and the XGBoost notebooks under `src/models/xgboost/<pollutant>/` consume the **normalized** (not enriched) fact Parquet files directly via DuckDB/pandas, pivoting long→wide (station+date rows, one column per pollutant/variable) before analysis. PCA results (loadings, scree plots, heatmaps) are written to `results/pca/` (a separate script-relative copy also lives checked in under `src/models/pca/results/`).
