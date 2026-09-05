#!/usr/bin/env bash
# Sincroniza o diretorio corporativo (Microsoft Entra ID) com a base das
# microaplicacoes. Roda na vm-supabase por cron, todo dia as 02:00 UTC, que sao
# 23:00 em Brasilia. Fecha o dia: quem for admitido hoje entra amanha de manha.
#
# Criterio de quem entra: conta de membro, habilitada, COM licenca do
# Microsoft 365 e com endereco @xptoinc.com.br. Quem nao cumpre nao e trazido.
#
# O que a rotina faz:  cria na base quem falta, liga quem ja existe, e abre o
#                      portao do TETELESTAI para quem cria.
# O que ela NAO faz:   nao altera cadastro existente, nao define perfil e nao
#                      abre nenhum outro portao. Isso e do administrador.
#
# Credenciais em /etc/xpto/sync-diretorio.env (modo 600, dono root):
#   TENANT_ID=...
#   CLIENT_ID=...
#   CLIENT_SECRET=...
set -euo pipefail

CONF="${SYNC_CONF:-/etc/xpto/sync-diretorio.env}"
DOMINIO="${SYNC_DOMINIO:-@xptoinc.com.br}"
COMPOSE="${SYNC_COMPOSE:-/opt/supa}"
APLICAR="${1:-simular}"          # "aplicar" grava; qualquer outra coisa so relata

[ -r "$CONF" ] || { echo "faltando $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
: "${TENANT_ID:?}" "${CLIENT_ID:?}" "${CLIENT_SECRET:?}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- 1. token de aplicacao ----
TOKEN="$(curl -sS --fail-with-body \
  -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d grant_type=client_credentials \
  -d "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  -d scope=https://graph.microsoft.com/.default | jq -r .access_token)"
[ -n "$TOKEN" ] && [ "$TOKEN" != null ] || { echo "sem token do Entra"; exit 1; }

# ---- 2. todas as paginas de usuarios ----
URL='https://graph.microsoft.com/v1.0/users?$select=id,userPrincipalName,displayName,mail,proxyAddresses,accountEnabled,assignedLicenses,userType,jobTitle,department&$top=999'
: > "$TMP/brutos.json"
while [ -n "$URL" ]; do
  curl -sS --fail-with-body -H "Authorization: Bearer $TOKEN" "$URL" -o "$TMP/pagina.json"
  jq -c '.value[]' "$TMP/pagina.json" >> "$TMP/brutos.json"
  URL="$(jq -r '."@odata.nextLink" // empty' "$TMP/pagina.json")"
done
echo "diretorio: $(wc -l < "$TMP/brutos.json") contas lidas"

# ---- 3. o criterio ----
jq -s --arg dom "$DOMINIO" '
  [ .[]
    | select(.userType == "Member" and .accountEnabled == true)
    | select((.assignedLicenses // []) | length > 0)
    | . as $u
    | ( [ $u.mail, $u.userPrincipalName ]
        + ( ($u.proxyAddresses // []) | map(split(":") | last) )
        | map(select(. != null) | ascii_downcase) | unique ) as $ends
    | ( if ($u.mail // "" | ascii_downcase | endswith($dom))
          then ($u.mail | ascii_downcase)
        elif ($u.userPrincipalName // "" | ascii_downcase | endswith($dom))
          then ($u.userPrincipalName | ascii_downcase)
        else null end ) as $principal
    | select($principal != null)
    | { oid: $u.id, email: $principal, enderecos: $ends,
        nome: ($u.displayName // ""), cargo: $u.jobTitle, area: $u.department }
  ] | sort_by(.email)
' "$TMP/brutos.json" > "$TMP/roster.json"

N="$(jq length "$TMP/roster.json")"
echo "elegiveis (habilitada + licenca + $DOMINIO): $N"
[ "$N" -gt 0 ] || { echo "roster vazio — abortando sem tocar na base"; exit 1; }

# ---- 4. entregar a base ----
CRIAR=false; [ "$APLICAR" = "aplicar" ] && CRIAR=true
{ printf 'select jsonb_pretty(public.shaar_sync_diretorio($SYNC$'
  cat "$TMP/roster.json"
  printf '$SYNC$::jsonb, %s));\n' "$CRIAR"
} > "$TMP/chamada.sql"

cd "$COMPOSE"
docker compose exec -T db psql -U postgres -d postgres -At -f - < "$TMP/chamada.sql"
