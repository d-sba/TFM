"""Prediccion y clasificacion global de calidad del aire.

Carga un regresor Gradient Boosting/XGBoost por contaminante, predice su
concentracion y la convierte a la categoria de la seed. La calidad global es
la moda de las cuatro categorias; si hay empate, se devuelve la peor.

Uso: python src/models/xgboost/predict_air_quality.py --input datos.json

El JSON puede contener variables en un nivel o separadas en ``meteo`` y
``concentracion``. Se buscan artefactos .joblib/.pkl/.pickle en las carpetas
NO2, PM25, PM10 y O3. El modelo debe conservar ``feature_names_in_`` o tener
un fichero de features junto a el (por ejemplo, features_pm10_final.joblib).
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any

import joblib
import pandas as pd


ROOT = Path(__file__).resolve().parents[3]
MODELS_DIR = Path(__file__).resolve().parent
SEED_PATH = ROOT / "data" / "raw" / "static_files" / "rangos_variables_aire.csv"
POLLUTANTS = {"NO2": 8, "PM25": 9, "PM10": 10, "O3": 14}
MODEL_EXTENSIONS = {".joblib", ".pkl", ".pickle"}


def _find_artifact(directory: Path, *, features: bool) -> Path:
    candidates = [
        path for path in directory.rglob("*")
        if path.is_file() and path.suffix.lower() in MODEL_EXTENSIONS
    ]
    candidates = [p for p in candidates if ("feature" in p.stem.lower()) == features]
    if len(candidates) != 1:
        kind = "features" if features else "modelo"
        found = ", ".join(str(p.relative_to(MODELS_DIR)) for p in candidates) or "ninguno"
        raise FileNotFoundError(f"Se esperaba un unico {kind} serializado en {directory}; encontrados: {found}.")
    return candidates[0]


def _feature_names(model: Any, model_dir: Path) -> list[str]:
    names = getattr(model, "feature_names_in_", None)
    if names is None and hasattr(model, "get_booster"):
        names = model.get_booster().feature_names
    if names is None:
        try:
            names = joblib.load(_find_artifact(model_dir, features=True))
        except FileNotFoundError as exc:
            raise ValueError(
                "El modelo no conserva feature_names_in_ y no existe un fichero de features junto a el."
            ) from exc
    return [str(name) for name in names]


def _flatten_input(payload: dict[str, Any]) -> dict[str, Any]:
    flat: dict[str, Any] = {}
    for key, value in payload.items():
        if key in {"meteo", "concentracion"}:
            if not isinstance(value, dict):
                raise ValueError(f"'{key}' debe ser un objeto JSON.")
            flat.update(value)
        else:
            flat[key] = value
    return flat


def _read_ranges(seed_path: Path = SEED_PATH) -> dict[int, list[tuple[int, float, float | None]]]:
    seed = pd.read_csv(seed_path)
    ranges: dict[int, list[tuple[int, float, float | None]]] = {}
    for row in seed.itertuples(index=False):
        text = str(row.rango).strip()
        if text.startswith("[>"):
            lower, upper = float(text[2:-1]), None
        else:
            values = re.fullmatch(r"\[\s*([^,]+)\s*,\s*([^\]]+)\s*\]", text)
            if not values:
                raise ValueError(f"Rango invalido en seed: {text!r}")
            lower, upper = float(values.group(1)), float(values.group(2))
        ranges.setdefault(int(row.variable), []).append((int(row.categoria), lower, upper))
    return ranges


def classify(value: float, pollutant_code: int, ranges: dict[int, list[tuple[int, float, float | None]]]) -> int:
    for category, lower, upper in ranges[pollutant_code]:
        if (upper is None and value > lower) or (upper is not None and lower <= value <= upper):
            return category
    raise ValueError(f"La concentracion {value} no encaja en los rangos de variable {pollutant_code}.")


def predict_air_quality(payload: dict[str, Any], models_dir: Path = MODELS_DIR) -> dict[str, Any]:
    """Predice y clasifica NO2, PM2.5, PM10 y O3 a partir de una observacion."""
    input_values, ranges = _flatten_input(payload), _read_ranges()
    predictions: dict[str, dict[str, float | int]] = {}
    for pollutant, code in POLLUTANTS.items():
        model_dir = models_dir / pollutant
        model = joblib.load(_find_artifact(model_dir, features=False))
        features = _feature_names(model, model_dir)
        missing = [name for name in features if name not in input_values]
        if missing:
            raise ValueError(f"Faltan variables para {pollutant}: {', '.join(missing)}")
        row = pd.DataFrame([[input_values[name] for name in features]], columns=features)
        concentration = float(model.predict(row)[0])
        predictions[pollutant] = {
            "concentracion_predicha": concentration,
            "categoria": classify(concentration, code, ranges),
        }

    votes = Counter(int(result["categoria"]) for result in predictions.values())
    max_votes = max(votes.values())
    tied = [category for category, count in votes.items() if count == max_votes]
    return {
        "predicciones": predictions,
        "calidad_global": max(tied),
        "votos_por_categoria": dict(sorted(votes.items())),
        "criterio_empate": "categoria_mas_alta (peor calidad)" if len(tied) > 1 else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Predice la calidad global del aire con cuatro modelos.")
    parser.add_argument("--input", required=True, type=Path, help="Ruta al JSON con datos meteorologicos y de concentracion.")
    parser.add_argument("--models-dir", type=Path, default=MODELS_DIR, help="Directorio raiz de NO2, PM25, PM10 y O3.")
    args = parser.parse_args()
    with args.input.open(encoding="utf-8") as file:
        payload = json.load(file)
    print(json.dumps(predict_air_quality(payload, args.models_dir), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
