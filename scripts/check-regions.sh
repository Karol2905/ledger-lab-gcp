#!/usr/bin/env bash
# Muestra las cuentas de facturacion y las regiones donde existen Cloud Run y Cloud SQL.
# Uso: scripts/check-regions.sh [proyecto-existente-para-consultar]
source "$(dirname "$0")/lib.sh"
use_gcloud_identity

echo
echo "Cuentas de facturacion abiertas:"
gcloud billing accounts list --filter=open=true --format="table(name.basename(), displayName, currencyCode)"

PROJECT="${1:-$(gcloud config get-value project 2>/dev/null)}"
if [[ -z "$PROJECT" ]]; then
  echo
  echo "Pasa un proyecto existente como argumento para listar regiones."
  exit 0
fi

echo
echo "Regiones de Cloud SQL (proyecto $PROJECT):"
gcloud sql tiers list --project "$PROJECT" --filter="tier=db-f1-micro" --format="value(region.list())" 2>/dev/null \
  | tr ';,' '\n\n' | sort -u | paste -sd' ' || echo "  (habilita sqladmin.googleapis.com para consultarlas)"

echo
echo "Regiones de Cloud Run de nivel 1 (capa gratuita de solicitudes y menor precio):"
echo "  us-central1 us-east1 us-east4 us-west1 europe-west1 europe-west4 asia-east1 asia-northeast1"
echo
echo "Use una region que aparezca en ambas listas (variable GCP_REGION)."
