"""
Descarga de datos climatológicos diarios de AEMET OpenData
============================================================

Descarga los valores climatológicos diarios (2020-2024) para las estaciones
meteorológicas de Madrid y entorno, y los combina en un único CSV.

Requisitos:
    pip install requests pandas

Uso:
    1. Consigue tu API key gratuita en:
       https://opendata.aemet.es/centrodedescargas/altaUsuario
    2. Guárdala en la variable de entorno AEMET_API_KEY.
    3. Ejecuta:
       python descarga_aemet.py

Salidas:
    - aemet_diarios_2020_2024.csv   -> CSV combinado, limpio, listo para el TFM
    - raw_json/                     -> JSON crudo de cada estación/año (backup)
"""

import os
import time
import json
import logging
from pathlib import Path
from datetime import datetime

import requests
import pandas as pd

# --------------------------------------------------------------------------
# CONFIGURACIÓN
# --------------------------------------------------------------------------

VERSION = "v5-2026-07-16"  # Si el log no muestra esta versión, estás con un archivo antiguo.

# La API key SIEMPRE se lee desde la variable de entorno AEMET_API_KEY.
API_KEY = os.environ.get("AEMET_API_KEY")

# Estaciones AEMET recomendadas (municipio de Madrid y entorno)
STATIONS = {
    "3195": "MADRID, RETIRO",
    "3129": "MADRID AEROPUERTO (Barajas)",
    "3196": "MADRID, CUATRO VIENTOS",
    "3194U": "MADRID, C. UNIVERSITARIA",
    "3200": "GETAFE",
}

FECHA_INICIO = datetime(2020, 1, 1)
FECHA_FIN = datetime(2024, 12, 31)

BASE_URL = (
    "https://opendata.aemet.es/opendata/api/valores/climatologicos/diarios/datos/"
    "fechaini/{ini}/fechafin/{fin}/estacion/{estacion}"
)

OUTPUT_DIR = Path(__file__).parent
RAW_DIR = OUTPUT_DIR / "raw_json"
RAW_DIR.mkdir(exist_ok=True)
OUTPUT_CSV = OUTPUT_DIR / "aemet_diarios_2020_2024.csv"

# Columnas numéricas típicas de este dataset que vienen con coma decimal
NUMERIC_COLUMNS = [
    "tmed", "prec", "tmin", "tmax", "dir", "velmedia", "racha",
    "sol", "presMax", "presMin", "hrMedia", "hrMax", "hrMin",
]

# Pausa entre peticiones para respetar el límite de AEMET (~50 peticiones/min).
SLEEP_BETWEEN_REQUESTS = 3.0
MAX_REINTENTOS = 6

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


# --------------------------------------------------------------------------
# FUNCIONES AUXILIARES
# --------------------------------------------------------------------------

def generar_rangos_anuales(fecha_inicio: datetime, fecha_fin: datetime):
    """Genera tramos de fechas de 6 meses como máximo (límite real de la API
    de AEMET para este endpoint: 'El rango de fechas no puede ser superior
    a 6 meses'). Devuelve tuplas (inicio_dt, fin_dt)."""
    rangos = []
    inicio_tramo = fecha_inicio
    while inicio_tramo <= fecha_fin:
        # Primer semestre (ene-jun) o segundo semestre (jul-dic) del año en curso
        if inicio_tramo.month <= 6:
            fin_tramo = datetime(inicio_tramo.year, 6, 30)
        else:
            fin_tramo = datetime(inicio_tramo.year, 12, 31)

        fin_tramo = min(fin_tramo, fecha_fin)
        rangos.append((inicio_tramo, fin_tramo))

        if fin_tramo.month == 6:
            inicio_tramo = datetime(fin_tramo.year, 7, 1)
        else:
            inicio_tramo = datetime(fin_tramo.year + 1, 1, 1)

    return rangos


def formatear_fecha_aemet(fecha: datetime, es_inicio: bool) -> str:
    """AEMET exige el formato AAAA-MM-DDTHH:MM:SSUTC"""
    hora = "00:00:00" if es_inicio else "23:59:59"
    return f"{fecha.strftime('%Y-%m-%d')}T{hora}UTC"


def descargar_json(url: str, params: dict = None, encoding: str = None, etiqueta: str = ""):
    """Descarga una URL de AEMET y devuelve el JSON parseado, o None si falla.

    Reintenta con backoff exponencial ante:
      - errores 429 (rate limit)
      - errores 5xx (el servidor de datos de AEMET falla de forma intermitente)
      - errores 404 que devuelven HTML en lugar de JSON (fallo temporal, no un
        404 real: un 404 legítimo de AEMET viene con JSON y su campo 'estado')
      - respuestas que no son JSON válido
      - fallos de red / timeouts
    """
    for intento in range(1, MAX_REINTENTOS + 1):
        espera = min(2 ** intento, 60)
        try:
            resp = requests.get(url, params=params, timeout=60)
        except requests.exceptions.RequestException as e:
            logger.warning(f"{etiqueta} Error de red: {e}. "
                           f"Reintento {intento}/{MAX_REINTENTOS} en {espera}s...")
            time.sleep(espera)
            continue

        if resp.status_code == 429:
            logger.warning(f"{etiqueta} Rate limit (429). "
                           f"Reintento {intento}/{MAX_REINTENTOS} en {espera}s...")
            time.sleep(espera)
            continue

        if resp.status_code >= 500:
            logger.warning(f"{etiqueta} Error de servidor ({resp.status_code}). "
                           f"Reintento {intento}/{MAX_REINTENTOS} en {espera}s...")
            time.sleep(espera)
            continue

        if encoding:
            resp.encoding = encoding

        try:
            return json.loads(resp.text)
        except json.JSONDecodeError:
            # No es JSON: casi siempre una página de error HTML de Tomcat
            logger.warning(f"{etiqueta} Respuesta no JSON ({resp.status_code}). "
                           f"Reintento {intento}/{MAX_REINTENTOS} en {espera}s...")
            time.sleep(espera)
            continue

    logger.error(f"{etiqueta} Fallo definitivo tras {MAX_REINTENTOS} intentos.")
    return None


def descargar_tramo(indicativo: str, nombre_estacion: str, ini_dt: datetime, fin_dt: datetime):
    """Descarga los datos de una estación para un tramo de fechas (máx. 6 meses).
    Devuelve una lista de dicts (registros diarios) o [] si no hay datos."""

    ini_str = formatear_fecha_aemet(ini_dt, es_inicio=True)
    fin_str = formatear_fecha_aemet(fin_dt, es_inicio=False)
    etiqueta = f"[{indicativo} {ini_dt.date()}->{fin_dt.date()}]"

    # --- Caché: si este tramo ya se descargó en una ejecución anterior, reutilizarlo ---
    nombre_archivo = RAW_DIR / f"{indicativo}_{ini_dt.year}_{ini_dt.month:02d}.json"
    if nombre_archivo.exists():
        try:
            with open(nombre_archivo, encoding="utf-8") as f:
                cacheados = json.load(f)
            if isinstance(cacheados, list) and cacheados:
                logger.info(f"{etiqueta} CACHÉ: {len(cacheados)} registros ya descargados, no se pide a la API.")
                return cacheados
        except (json.JSONDecodeError, OSError):
            pass  # caché corrupta -> se vuelve a descargar

    logger.info(f"Solicitando estación {indicativo} ({nombre_estacion}) "
                f"[{ini_dt.date()} -> {fin_dt.date()}]")

    # --- Paso 1: pedir los metadatos (AEMET devuelve la URL real de los datos) ---
    url = BASE_URL.format(ini=ini_str, fin=fin_str, estacion=indicativo)
    body = descargar_json(url, params={"api_key": API_KEY}, etiqueta=f"{etiqueta} (paso 1)")

    if body is None:
        return []

    if body.get("estado") != 200:
        logger.warning(f"{etiqueta} AEMET devolvió estado {body.get('estado')}: "
                       f"{body.get('descripcion')}")
        return []

    datos_url = body.get("datos")
    if not datos_url:
        logger.warning(f"{etiqueta} Sin URL de datos en la respuesta.")
        return []

    # --- Paso 2: descargar los datos reales desde la URL temporal ---
    time.sleep(SLEEP_BETWEEN_REQUESTS)
    registros = descargar_json(
        datos_url,
        encoding="ISO-8859-15",   # AEMET codifica el contenido real en ISO-8859-15
        etiqueta=f"{etiqueta} (paso 2)",
    )

    if registros is None:
        return []

    # Backup del JSON crudo (sirve además de caché para futuras ejecuciones)
    with open(nombre_archivo, "w", encoding="utf-8") as f:
        json.dump(registros, f, ensure_ascii=False, indent=2)

    return registros


def limpiar_dataframe(df: pd.DataFrame) -> pd.DataFrame:
    """Convierte las columnas numéricas (que vienen con coma decimal) a float,
    y la fecha a datetime."""
    for col in NUMERIC_COLUMNS:
        if col in df.columns:
            df[col] = (
                df[col]
                .astype(str)
                .str.replace(",", ".", regex=False)
                .replace({"nan": None, "": None})
            )
            df[col] = pd.to_numeric(df[col], errors="coerce")

    if "fecha" in df.columns:
        df["fecha"] = pd.to_datetime(df["fecha"], errors="coerce")

    return df


# --------------------------------------------------------------------------
# SCRIPT PRINCIPAL
# --------------------------------------------------------------------------

def main():
    logger.info(f"descarga_aemet.py {VERSION}  |  pausa={SLEEP_BETWEEN_REQUESTS}s  reintentos={MAX_REINTENTOS}")

    if not API_KEY:
        logger.error(
            "No se ha configurado la API key de AEMET. "
            "Antes de ejecutar el script, define la variable de entorno AEMET_API_KEY en la terminal:\n"
            "  PowerShell:  $env:AEMET_API_KEY=\"tu_api_key\"\n"
            "  CMD:         set AEMET_API_KEY=tu_api_key\n"
            "  Mac/Linux:    export AEMET_API_KEY=\"tu_api_key\""
        )
        return

    rangos = generar_rangos_anuales(FECHA_INICIO, FECHA_FIN)
    todos_los_registros = []
    tramos_fallidos = []

    for indicativo, nombre_estacion in STATIONS.items():
        for ini_dt, fin_dt in rangos:
            registros = descargar_tramo(indicativo, nombre_estacion, ini_dt, fin_dt)
            if registros:
                todos_los_registros.extend(registros)
                logger.info(f"  -> {len(registros)} registros obtenidos.")
            else:
                tramos_fallidos.append((indicativo, nombre_estacion, ini_dt, fin_dt))
            time.sleep(SLEEP_BETWEEN_REQUESTS)

    if not todos_los_registros:
        logger.error("No se ha descargado ningún registro. Revisa la API key y los indicativos.")
        return

    df = pd.DataFrame(todos_los_registros)
    df = limpiar_dataframe(df)
    df = df.sort_values(["indicativo", "fecha"]).reset_index(drop=True)

    df.to_csv(OUTPUT_CSV, index=False, encoding="utf-8-sig")

    # ---------------- Resumen final ----------------
    logger.info("=" * 70)
    logger.info(f"CSV combinado guardado en: {OUTPUT_CSV}")
    logger.info(f"Total de registros: {len(df)}")
    logger.info(f"Rango de fechas: {df['fecha'].min().date()} -> {df['fecha'].max().date()}")

    # Días esperados por estación en el periodo solicitado
    dias_esperados = (FECHA_FIN - FECHA_INICIO).days + 1
    logger.info(f"Días esperados por estación: {dias_esperados}")
    logger.info("Cobertura por estación:")
    for indicativo, nombre_estacion in STATIONS.items():
        n = int((df["indicativo"] == indicativo).sum()) if "indicativo" in df.columns else 0
        pct = 100 * n / dias_esperados if dias_esperados else 0
        logger.info(f"  {indicativo:<7} {nombre_estacion:<32} {n:>5} días ({pct:.1f}%)")

    if tramos_fallidos:
        logger.warning("=" * 70)
        logger.warning(f"ATENCIÓN: {len(tramos_fallidos)} tramo(s) sin datos. "
                       f"Vuelve a ejecutar el script más tarde para completarlos:")
        for indicativo, nombre_estacion, ini_dt, fin_dt in tramos_fallidos:
            logger.warning(f"  {indicativo} ({nombre_estacion}): "
                           f"{ini_dt.date()} -> {fin_dt.date()}")
    else:
        logger.info("Todos los tramos se descargaron correctamente.")


if __name__ == "__main__":
    main()
