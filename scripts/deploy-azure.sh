#!/usr/bin/env bash
# Publica o SHAAR no Azure Static Web Apps direto pela CLI.
#
# Nao depende de secret no GitHub: o token e lido do proprio recurso, usando
# a sua sessao do `az`. Rode `az login` antes, se ainda nao estiver logado.
#
#   ./scripts/deploy-azure.sh              # publica em producao
#   ./scripts/deploy-azure.sh preview      # publica num ambiente de preview
set -euo pipefail

APP="${SWA_NAME:-swa-shaar}"
GRUPO="${SWA_GROUP:-rg-xpto-plataforma}"
AMBIENTE="${1:-production}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v az >/dev/null || { echo "Azure CLI nao encontrada. Instale: https://aka.ms/InstallAzureCLIDeb"; exit 1; }
az account show >/dev/null 2>&1 || { echo "Sem sessao do Azure. Rode: az login --use-device-code"; exit 1; }

echo "Recurso: $APP  ·  grupo: $GRUPO  ·  ambiente: $AMBIENTE"

TOKEN="$(az staticwebapp secrets list -n "$APP" -g "$GRUPO" --query 'properties.apiKey' -o tsv)"
if [ "${#TOKEN}" -lt 40 ]; then
  echo "Token nao veio do recurso. Confira se '$APP' existe em '$GRUPO':"
  echo "  az staticwebapp list -o table"
  exit 1
fi

npx --yes @azure/static-web-apps-cli@latest deploy "$RAIZ/site" \
  --deployment-token "$TOKEN" \
  --env "$AMBIENTE" \
  --no-use-keychain

echo
echo "Endereco: https://$(az staticwebapp show -n "$APP" -g "$GRUPO" --query defaultHostname -o tsv)"
