#!/usr/bin/env python3
"""Estima el costo mensual desde `terraform show -json`.

Usa la Cloud Billing Catalog API de Google: es gratuita, pero exige un token de acceso. En el
pipeline lo entrega la autenticacion OIDC (variable GOOGLE_OAUTH_ACCESS_TOKEN). Sin token o sin red
usa la copia local prices-snapshot.json. Solo depende de la biblioteca estandar. El consumo no
aparece en un plan, por eso se declara en usage.json.
"""

import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

CATALOG_URL = "https://cloudbilling.googleapis.com/v1/services/{service}/skus"
HERE = Path(__file__).parent

# Servicios del catalogo de facturacion de Google.
CLOUD_RUN = "152E-C115-5142"
CLOUD_SQL = "9662-B51E-5089"
SECRET_MANAGER = "EE2C-7FAC-5E08"
CLOUD_LOGGING = "5490-F7B7-8DF6"
CLOUD_STORAGE = "95FF-2EF5-5EA1"

# clave: (servicio, expresion sobre la descripcion del SKU, unidad de uso, multiplicador)
# El multiplicador lleva el precio a la unidad que usa este estimador (p. ej., por millon).
METERS = {
    "run_vcpu_second": (CLOUD_RUN, r"^Services CPU \(Request-based billing\)", "s", 1),
    "run_gib_second": (CLOUD_RUN, r"^Services Memory \(Request-based billing\)", "GiBy.s", 1),
    "run_million_requests": (CLOUD_RUN, r"^Requests$", "count", 1_000_000),
    "sql_micro_hour": (
        CLOUD_SQL, r"^Cloud SQL for PostgreSQL: Zonal - Micro instance in ", "h", 1,
    ),
    "sql_ssd_gib_month": (
        CLOUD_SQL, r"^Cloud SQL for PostgreSQL: Zonal - Standard storage in ", "GiBy.mo", 1,
    ),
    "sql_backup_gib_month": (CLOUD_SQL, r"^Cloud SQL: Backups in ", "GiBy.mo", 1),
    "secret_version_month": (SECRET_MANAGER, r"^Secret version replica storage$", "mo", 1),
    "secret_10k_access": (SECRET_MANAGER, r"^Access operations$", "count", 10_000),
    "log_gib": (CLOUD_LOGGING, r"^Log Storage cost$", "GiBy", 1),
    "gcs_gib_month": (CLOUD_STORAGE, r"^Standard Storage ", "GiBy.mo", 1),
    "gcs_10k_writes": (CLOUD_STORAGE, r"^Regional Standard Class A Operations$", "count", 10_000),
}

# Recursos sin cargo propio: su costo aparece, si lo hay, en los recursos que los usan.
FREE_RESOURCES = {
    "google_project_iam_member",
    "google_secret_manager_secret",  # Se cobra cada version activa, no el contenedor del secreto.
    "google_secret_manager_secret_iam_member",
    "google_service_account",
    "google_sql_database",
    "google_sql_user",
    "google_logging_project_sink",
    "google_storage_bucket_iam_member",
}


class PriceNotFound(Exception):
    pass


def _unit_price(sku: dict) -> float:
    expression = sku["pricingInfo"][0]["pricingExpression"]
    rates = [
        int(rate["unitPrice"].get("units", 0)) + rate["unitPrice"].get("nanos", 0) / 1e9
        for rate in expression["tieredRates"]
    ]
    # El primer escalon suele ser la capa gratuita (0 USD); la capa gratuita se calcula aparte.
    return max(rates)


def fetch_live_price(key: str, region: str) -> float:
    service, pattern, unit, multiplier = METERS[key]
    token = os.environ.get("GOOGLE_OAUTH_ACCESS_TOKEN")
    if not token:
        raise PermissionError("no hay GOOGLE_OAUTH_ACCESS_TOKEN")
    matches, page_token = [], ""
    while True:
        query = urllib.parse.urlencode({"currencyCode": "USD", "pageSize": 5000,
                                        "pageToken": page_token})
        request = urllib.request.Request(
            f"{CATALOG_URL.format(service=service)}?{query}",
            headers={"Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            page = json.load(response)
        for sku in page.get("skus", []):
            regions = sku.get("serviceRegions", [])
            expression = sku["pricingInfo"][0]["pricingExpression"]
            if (re.search(pattern, sku["description"])
                    and expression["usageUnit"] == unit
                    and (region in regions or "global" in regions or not regions)):
                matches.append(_unit_price(sku) * multiplier)
        page_token = page.get("nextPageToken", "")
        if not page_token:
            break
    if not matches:
        raise PriceNotFound(f"Sin precio para {key} en {region}")
    return max(matches)


class PriceBook:
    """Precios en vivo con respaldo a una copia local, para no bloquearse sin red."""

    def __init__(self, snapshot: dict, offline: bool = False, fetcher=fetch_live_price):
        self.snapshot = snapshot
        self.offline = offline
        self.fetcher = fetcher
        self.cache: dict[tuple[str, str], float] = {}
        self.used_snapshot = False

    def price(self, key: str, region: str) -> float:
        if (key, region) in self.cache:
            return self.cache[(key, region)]
        value = None
        if not self.offline:
            try:
                value = self.fetcher(key, region)
            except OSError as error:
                print(f"Aviso: sin acceso a la API de precios ({error})", file=sys.stderr)
        if value is None:
            try:
                value = self.snapshot[region][key]
            except KeyError as error:
                raise PriceNotFound(f"Sin copia local de {key} en {region}") from error
            self.used_snapshot = True
        self.cache[(key, region)] = value
        return value


@dataclass
class Line:
    environment: str
    address: str
    monthly_usd: float
    detail: str


def walk_resources(module: dict):
    yield from module.get("resources", [])
    for child in module.get("child_modules", []):
        yield from walk_resources(child)


def plan_resources(plan: dict) -> list[dict]:
    root = plan.get("planned_values", {}).get("root_module", {})
    return [r for r in walk_resources(root) if r.get("mode") == "managed"]


def plan_region(resources: list[dict], fallback: str) -> str:
    for resource in resources:
        values = resource.get("values", {})
        region = values.get("region") or values.get("location")
        if region and "-" in region:
            return region.lower()
    return fallback


def parse_cpu(cpu: str) -> float:
    return float(cpu[:-1]) / 1000 if cpu.endswith("m") else float(cpu)


def parse_gib(memory: str) -> float:
    units = {"Mi": 1 / 1024, "Gi": 1.0, "M": 1e6 / 2**30, "G": 1e9 / 2**30}
    for suffix, factor in units.items():
        if memory.endswith(suffix):
            return float(memory.removesuffix(suffix)) * factor
    return float(memory) / 2**30


def estimate_plan(name: str, plan: dict, usage: dict, book: PriceBook, grant: dict) -> tuple:
    """Devuelve las lineas de costo y los recursos sin regla de precio."""
    resources = plan_resources(plan)
    region = plan_region(resources, usage.get("default_region", "us-central1"))
    lines, unknown = [], []

    for resource in resources:
        kind, values, address = resource["type"], resource.get("values", {}), resource["address"]
        if kind in FREE_RESOURCES or kind.startswith(("random_", "time_")):
            continue
        if kind == "google_cloud_run_v2_service":
            lines.append(_cloud_run(name, address, values, usage, region, book, grant))
        elif kind == "google_sql_database_instance":
            lines.append(_cloud_sql(name, address, values, usage, region, book))
        elif kind == "google_secret_manager_secret_version":
            lines.append(_secret_version(name, address, usage, region, book, grant))
        elif kind == "google_logging_project_bucket_config":
            free = grant["log_gib"]
            billable = max(0.0, usage["log_gib_per_month"] - free)
            grant["log_gib"] = max(0.0, free - usage["log_gib_per_month"])
            cost = billable * book.price("log_gib", region)
            lines.append(Line(name, address, cost, f"{usage['log_gib_per_month']} GiB (50 gratis)"))
        elif kind == "google_storage_bucket":
            storage = usage["state_storage_gib"] * book.price("gcs_gib_month", region)
            writes = usage["state_writes_per_month"] / 10_000 * book.price("gcs_10k_writes", region)
            lines.append(Line(name, address, storage + writes, f"{usage['state_storage_gib']} GiB"))
        else:
            unknown.append(address)
    return lines, unknown


def _consume(grant: dict, name: str, amount: float) -> float:
    """La capa gratuita es por cuenta de facturacion: dev y prod consumen de la misma bolsa."""
    covered = min(grant[name], amount)
    grant[name] -= covered
    return amount - covered


def _cloud_run(env, address, values, usage, region, book, grant) -> Line:
    limits = values["template"][0]["containers"][0]["resources"][0]["limits"]
    seconds = usage["app_active_hours_per_month"][env] * 3600
    vcpu_seconds = seconds * parse_cpu(limits["cpu"])
    gib_seconds = seconds * parse_gib(limits["memory"])
    requests = usage["requests_per_month"][env]
    cost = (
        _consume(grant, "vcpu_seconds", vcpu_seconds) * book.price("run_vcpu_second", region)
        + _consume(grant, "gib_seconds", gib_seconds) * book.price("run_gib_second", region)
        + _consume(grant, "requests", requests) / 1e6 * book.price("run_million_requests", region)
    )
    return Line(env, address, cost, f"{seconds / 3600:.0f} h activas, {requests:,} solicitudes")


def _cloud_sql(env, address, values, usage, region, book) -> Line:
    settings = values["settings"][0]
    tier = settings["tier"]
    if tier != "db-f1-micro":
        raise PriceNotFound(f"Sin regla de precio para el tier {tier}")
    # Cloud SQL cobra cada hora que la instancia existe encendida, aunque no reciba consultas.
    hours = usage["sql_hours_per_month"][env]
    compute = hours * book.price("sql_micro_hour", region)
    storage = settings["disk_size"] * book.price("sql_ssd_gib_month", region) * hours / 730
    backups = settings.get("backup_configuration") or [{}]
    backup_cost = 0.0
    if backups[0].get("enabled"):
        backup_cost = usage["sql_backup_gib"] * book.price("sql_backup_gib_month", region)
    detail = f"{hours} h encendida, {settings['disk_size']} GiB SSD"
    if backup_cost:
        detail += ", respaldos"
    return Line(env, address, compute + storage + backup_cost, detail)


def _secret_version(env, address, usage, region, book, grant) -> Line:
    versions = _consume(grant, "secret_versions", 1)
    accesses = _consume(grant, "secret_accesses", usage["secret_accesses_per_version"])
    cost = (versions * book.price("secret_version_month", region)
            + accesses / 10_000 * book.price("secret_10k_access", region))
    return Line(env, address, cost, f"1 version, {usage['secret_accesses_per_version']:,} accesos")


def estimate(plans: dict[str, dict], usage: dict, book: PriceBook) -> tuple:
    grant = dict(usage["free_tier"])
    lines, unknown = [], []
    for name, plan in plans.items():
        plan_lines, plan_unknown = estimate_plan(name, plan, usage, book, grant)
        lines += plan_lines
        unknown += [f"{name}: {address}" for address in plan_unknown]
    return lines, unknown


def render(lines: list[Line], unknown: list[str], budget: float | None) -> str:
    width = max([len(line.address) for line in lines] + [7])
    rows = [f"{'Ambiente':<9} {'Recurso':<{width}} {'USD/mes':>9}  Supuesto"]
    rows += [
        f"{line.environment:<9} {line.address:<{width}} {line.monthly_usd:>9.2f}  {line.detail}"
        for line in lines
    ]
    total = sum(line.monthly_usd for line in lines)
    rows.append(f"{'TOTAL':<9} {'':<{width}} {total:>9.2f}")
    if budget is not None:
        rows.append(f"Presupuesto: {budget:.2f} USD/mes")
    rows += [f"SIN PRECIO: {address}" for address in unknown]
    return "\n".join(rows)


def refresh_snapshot(path: Path, region: str) -> None:
    snapshot = json.loads(path.read_text()) if path.exists() else {}
    snapshot[region] = {key: fetch_live_price(key, region) for key in METERS}
    path.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plan", action="append", default=[], metavar="AMBIENTE=ARCHIVO",
        help="Plan JSON de terraform; se puede repetir, p. ej. --plan dev=dev.json",
    )
    parser.add_argument("--usage", type=Path, default=HERE / "usage.json")
    parser.add_argument("--snapshot", type=Path, default=HERE / "prices-snapshot.json")
    parser.add_argument("--offline", action="store_true", help="Usa solo la copia local de precios")
    parser.add_argument("--budget", type=float, help="Falla si el total mensual lo supera")
    parser.add_argument("--refresh-snapshot", metavar="REGION", help="Actualiza la copia local")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    if args.refresh_snapshot:
        refresh_snapshot(args.snapshot, args.refresh_snapshot)
        print(f"Copia de precios actualizada para {args.refresh_snapshot}")
        return 0
    if not args.plan:
        print("Indica al menos un --plan AMBIENTE=ARCHIVO", file=sys.stderr)
        return 2

    plans = {}
    for item in args.plan:
        name, _, filename = item.partition("=")
        plans[name] = json.loads(Path(filename).read_text())
    snapshot = json.loads(args.snapshot.read_text()) if args.snapshot.exists() else {}
    book = PriceBook(snapshot, offline=args.offline)
    usage = json.loads(args.usage.read_text())

    try:
        lines, unknown = estimate(plans, usage, book)
    except PriceNotFound as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    print(render(lines, unknown, args.budget))
    if book.used_snapshot:
        print("Aviso: se usaron precios de la copia local; pueden estar desactualizados.")
    # Un recurso sin regla volveria engañoso el total, asi que tambien detiene el despliegue.
    if unknown:
        print("Error: agrega una regla de precio para los recursos listados.", file=sys.stderr)
        return 1
    total = sum(line.monthly_usd for line in lines)
    if args.budget is not None and total > args.budget:
        print(f"Error: {total:.2f} USD supera el presupuesto.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
