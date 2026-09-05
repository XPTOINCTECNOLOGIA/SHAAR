# SHAAR — deploy no Azure Static Web Apps

Pacote pronto: HTML estático, sem build. Três passos.

## 1. Criar o recurso

```bash
az group create -n rg-shaar -l eastus2

az deployment group create \
  -g rg-shaar \
  -f infra/main.bicep \
  -p name=swa-shaar-hub location=eastus2 sku=Standard
```

Anote o `defaultHostname` da saída.

## 2. Guardar o token de deploy no GitHub

```bash
az staticwebapp secrets list -n swa-shaar-hub -g rg-shaar \
  --query "properties.apiKey" -o tsv
```

No repositório: **Settings → Secrets and variables → Actions → New secret**
`AZURE_STATIC_WEB_APPS_API_TOKEN` = valor acima.

## 3. Publicar

O workflow `.github/workflows/azure-static-web-apps.yml` publica a cada push.
Todo PR ganha um ambiente de preview próprio, encerrado ao fechar o PR.

---

## Proteger com Entra ID (recomendado para preview interno)

O `site/staticwebapp.config.json` já exige usuário autenticado. Falta registrar o app:

```bash
az ad app create --display-name "SHAAR Hub" \
  --web-redirect-uris "https://<defaultHostname>/.auth/login/aad/callback"
```

Depois, no `staticwebapp.config.json`, troque `<TENANT_ID>` pelo id do tenant, e grave
as configurações do app:

```bash
az staticwebapp appsettings set -n swa-shaar-hub -g rg-shaar \
  --setting-names AAD_CLIENT_ID=<appId> AAD_CLIENT_SECRET=<secret>
```

> Para deixar o preview público, troque em `routes` o `"allowedRoles": ["authenticated"]`
> por `["anonymous"]` e remova o bloco `auth`.

## Domínio próprio

```bash
az staticwebapp hostname set -n swa-shaar-hub -g rg-shaar \
  --hostname shaar.xptoinc.com.br
```
