# SHAAR — deploy no Azure Static Web Apps

Site estático, sem build. Três passos para o ambiente existir; depois, todo push publica.

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

Repositório → **Settings → Secrets and variables → Actions** →
`AZURE_STATIC_WEB_APPS_API_TOKEN`.

## 3. Publicar

O workflow publica a cada push em `main` e também pode ser disparado à mão
(**Actions → Deploy SHAAR → Run workflow**). Todo PR ganha um ambiente de
preview próprio, encerrado quando o PR fecha.

---

## Quem consegue entrar

O acesso é fechado por padrão, em duas camadas:

1. **Login** pelo provedor **Microsoft Entra ID pré-configurado** do Static Web Apps —
   não exige registrar aplicativo no Azure.
2. **Autorização** pelo papel `preview`: só quem foi convidado enxerga o site.
   Quem entra sem o papel cai em `/sem-acesso.html`.

### Convidar alguém

Portal do Azure → o Static Web App → **Role management** → **Invite**:

| Campo | Valor |
|---|---|
| Authorization provider | Microsoft Entra ID (`aad`) |
| Invitee details | e-mail da pessoa |
| Domain | o `defaultHostname` (ou o domínio próprio) |
| Role | `preview` |

Ou pela CLI:

```bash
az staticwebapp users invite -n swa-shaar-hub -g rg-shaar \
  --authentication-provider aad \
  --user-details pessoa@xptoinc.com.br \
  --domain <defaultHostname> \
  --roles preview \
  --invitation-expiration-in-hours 168
```

> **Atenção:** o provedor pré-configurado aceita login de qualquer conta Microsoft.
> É o papel `preview` que restringe de fato o acesso — nunca troque
> `"allowedRoles": ["preview"]` por `["authenticated"]` achando que basta.

### Restringir ao tenant da XPTO (produção)

Quando o SHAAR sair do preview, registre um provedor próprio — isso limita o login
ao tenant e **desativa os provedores pré-configurados**:

```bash
az ad app create --display-name "SHAAR Hub" \
  --web-redirect-uris "https://<defaultHostname>/.auth/login/aad/callback"

az staticwebapp appsettings set -n swa-shaar-hub -g rg-shaar \
  --setting-names AAD_CLIENT_ID=<appId> AAD_CLIENT_SECRET=<secret>
```

E acrescente ao `site/staticwebapp.config.json`:

```json
"auth": {
  "identityProviders": {
    "azureActiveDirectory": {
      "registration": {
        "openIdIssuer": "https://login.microsoftonline.com/<TENANT_ID>/v2.0",
        "clientIdSettingName": "AAD_CLIENT_ID",
        "clientSecretSettingName": "AAD_CLIENT_SECRET"
      }
    }
  }
}
```

## Domínio próprio

```bash
az staticwebapp hostname set -n swa-shaar-hub -g rg-shaar \
  --hostname shaar.xptoinc.com.br
```
