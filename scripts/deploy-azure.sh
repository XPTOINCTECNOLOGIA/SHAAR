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

# Configuracao do front. A chave anonima vem do ambiente e nunca entra no
# repositorio. Defina SUPABASE_ANON_KEY antes de publicar; sem ela o site sobe
# em modo demonstracao, com personas ficticias e sem tocar na base.
BASE_URL="${SUPABASE_URL:-https://api.xptoinc.com.br}"
if [ -n "${SUPABASE_ANON_KEY:-}" ]; then
  cat > "$RAIZ/site/config.js" <<CFG
window.SHAAR_CONFIG = { url: "$BASE_URL", anonKey: "$SUPABASE_ANON_KEY" };
CFG
  echo "Modo: conectado a $BASE_URL"
else
  echo 'window.SHAAR_CONFIG = {};' > "$RAIZ/site/config.js"
  echo "Modo: DEMONSTRACAO (defina SUPABASE_ANON_KEY para conectar a base)"
fi

npx --yes @azure/static-web-apps-cli@latest deploy "$RAIZ/site" \
  --deployment-token "$TOKEN" \
  --env "$AMBIENTE" \
  --no-use-keychain

echo
rm -f "$RAIZ/site/config.js"

echo "Endereco: https://$(az staticwebapp show -n "$APP" -g "$GRUPO" --query defaultHostname -o tsv)"
