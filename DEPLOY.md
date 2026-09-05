# SHAAR — publicação

O SHAAR vive em dois endereços, com propósitos diferentes.

| Ambiente | Endereço | Acesso | Publica |
|---|---|---|---|
| **Azure** (oficial) | https://blue-sea-07ebdbc0f.6.azurestaticapps.net | Fechado — Entra ID + convite | Pela CLI, sob demanda |
| **GitHub Pages** (vitrine) | https://xptoinc.github.io/SHAAR/ | Aberto | Sozinho, a cada push |

---

## Azure — publicar

Não há token guardado no GitHub: o deploy usa a sua própria sessão do `az`.

```bash
az login --use-device-code     # só na primeira vez
./scripts/deploy-azure.sh
```

Para um ambiente de preview, sem tocar em produção:

```bash
./scripts/deploy-azure.sh minha-branch
```

O recurso segue a convenção do ecossistema: `swa-shaar`, no grupo
`rg-xpto-plataforma`, região East US 2, SKU Free — o mesmo padrão de
`swa-tetelestai`, `swa-sphragis`, `swa-tikkun` e os demais.

## Azure — quem entra

Duas camadas:

1. **Login** pelo provedor **Entra ID pré-configurado** do Static Web Apps —
   não exige registrar aplicativo no Azure.
2. **Autorização** pelo papel `preview`. Quem entra sem ele cai em
   `/sem-acesso.html`.

### Convidar alguém

```bash
az staticwebapp users invite -n swa-shaar -g rg-xpto-plataforma \
  --authentication-provider aad \
  --user-details pessoa@xptoinc.com.br \
  --domain blue-sea-07ebdbc0f.6.azurestaticapps.net \
  --roles preview \
  --invitation-expiration-in-hours 168
```

O comando devolve um link; a pessoa precisa **abrir esse link** para o papel
valer. Sem isso, o acesso não é concedido.

Ver quem já tem acesso:

```bash
az staticwebapp users list -n swa-shaar -g rg-xpto-plataforma -o table
```

> **Atenção:** o provedor pré-configurado aceita login de qualquer conta
> Microsoft. Quem restringe de fato é o papel `preview` — nunca troque
> `"allowedRoles": ["preview"]` por `["authenticated"]` achando que basta.

### Restringir ao tenant da XPTO (produção)

Registre um provedor próprio — isso limita o login ao tenant e **desativa os
provedores pré-configurados**. Exige SKU **Standard**:

```bash
az staticwebapp update -n swa-shaar -g rg-xpto-plataforma --sku Standard

az ad app create --display-name "SHAAR Hub" \
  --web-redirect-uris "https://<host>/.auth/login/aad/callback"

az staticwebapp appsettings set -n swa-shaar -g rg-xpto-plataforma \
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
az staticwebapp hostname set -n swa-shaar -g rg-xpto-plataforma \
  --hostname shaar.xptoinc.com.br
```

## GitHub Pages — a vitrine

O workflow `.github/workflows/github-pages.yml` publica `site/` a cada push em
`main`. Serve para mostrar o mockup sem exigir login. Como é público, não deve
receber dado real — quando o SHAAR passar a ler concessões de verdade, desligue-o.

## Infraestrutura como código

`infra/main.bicep` descreve o Static Web App. O recurso atual foi criado pela
CLI seguindo a convenção do ecossistema; o Bicep serve para recriá-lo ou para
provisionar outros ambientes:

```bash
az deployment group create -g rg-xpto-plataforma -f infra/main.bicep \
  -p name=swa-shaar-hml location=eastus2 sku=Free
```
