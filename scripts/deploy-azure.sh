#!/usr/bin/env bash
# Publica o SHAAR no Azure Static Web Apps direto pela CLI.
#
# Nao depende de secret no GitHub: o token e lido do proprio recurso, usando
# a sua sessao do `az`. Rode `az login` antes, se ainda nao estiver logado.
#
# A chave anonima da base vem de SUPABASE_ANON_KEY e e gravada DENTRO do
# index.html publicado — sem requisicao separada, sem cache nem CSP no caminho.
# O arquivo original e restaurado logo apos o envio, entao a chave nunca entra
# no repositorio.
#
#   SUPABASE_ANON_KEY=... ./scripts/deploy-azure.sh            # producao
#   SUPABASE_ANON_KEY=... ./scripts/deploy-azure.sh minha-br   # preview
#   ./scripts/deploy-azure.sh                                  # demonstracao
set -euo pipefail

APP="${SWA_NAME:-swa-shaar}"
GRUPO="${SWA_GROUP:-rg-xpto-plataforma}"
AMBIENTE="${1:-production}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARCADOR='<script id="shaar-config">window.SHAAR_CONFIG = {};</script>'

command -v az >/dev/null || { echo "Azure CLI nao encontrada. Instale: https://aka.ms/InstallAzureCLIDeb"; exit 1; }
az account show >/dev/null 2>&1 || { echo "Sem sessao do Azure. Rode: az login --use-device-code"; exit 1; }

echo "Recurso: $APP  ·  grupo: $GRUPO  ·  ambiente: $AMBIENTE"

TOKEN="$(az staticwebapp secrets list -n "$APP" -g "$GRUPO" --query 'properties.apiKey' -o tsv)"
if [ "${#TOKEN}" -lt 40 ]; then
  echo "Token nao veio do recurso. Confira se '$APP' existe em '$GRUPO':"
  echo "  az staticwebapp list -o table"
  exit 1
fi

# guarda o original e garante a restauracao mesmo em caso de erro
ORIGINAL="$(mktemp)"
cp "$RAIZ/site/index.html" "$ORIGINAL"
restaurar(){ cp "$ORIGINAL" "$RAIZ/site/index.html"; rm -f "$ORIGINAL"; }
trap restaurar EXIT

BASE_URL="${SUPABASE_URL:-https://api.xptoinc.com.br}"
if [ -n "${SUPABASE_ANON_KEY:-}" ]; then
  grep -qF "$MARCADOR" "$RAIZ/site/index.html" \
    || { echo "Marcador shaar-config nao encontrado no index.html"; exit 1; }
  NOVO="<script id=\"shaar-config\">window.SHAAR_CONFIG = {\"url\":\"$BASE_URL\",\"anonKey\":\"$SUPABASE_ANON_KEY\"};</script>"
  # JWT em base64url nao contem '|', entao o delimitador do sed e seguro
  sed -i "s|$MARCADOR|$NOVO|" "$RAIZ/site/index.html"
  grep -q 'anonKey' "$RAIZ/site/index.html" \
    || { echo "Falha ao gravar a configuracao no index.html"; exit 1; }
  echo "Modo: conectado a $BASE_URL"
else
  echo "Modo: DEMONSTRACAO (defina SUPABASE_ANON_KEY para conectar a base)"
fi

npx --yes @azure/static-web-apps-cli@latest deploy "$RAIZ/site" \
  --deployment-token "$TOKEN" \
  --env "$AMBIENTE" \
  --no-use-keychain

echo
echo "Endereco: https://$(az staticwebapp show -n "$APP" -g "$GRUPO" --query defaultHostname -o tsv)"
