# Funciones comunes. Se carga con `source`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "Error: $*" >&2
  exit 1
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "falta '$tool' en el PATH"
  done
}

# Toda la autenticacion sale de `gcloud auth login`. No hay claves de cuentas de servicio.
use_gcloud_identity() {
  require gcloud
  GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
  [[ -n "$GCLOUD_ACCOUNT" ]] || die "ejecuta primero: gcloud auth login"
  echo "Cuenta: $GCLOUD_ACCOUNT"
}
