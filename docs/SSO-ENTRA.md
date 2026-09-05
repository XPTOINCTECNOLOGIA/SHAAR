# SSO Microsoft Entra ID

Quem tem conta **@xptoinc.com.br** entra no SHAAR pelo SSO corporativo. Quem não
tem — terceiros, parceiros — continua entrando por e-mail e senha.

> **O Entra ID autentica; a base do TETELESTAI autoriza.**
> Estar no tenant não concede aplicação nenhuma. Não estar não retira o que a base
> já concedeu. Uma pessoa que entre por SSO sem linha ativa em `public.users` vê
> "nenhuma aplicação liberada" — e é o comportamento correto.

## O que está configurado

### No Entra ID

| Item | Valor |
|---|---|
| Aplicativo | **XPTO Ecossistema SSO** |
| Application (client) ID | `689ba542-9314-4079-a0ec-1c7bf49ff1a9` |
| Tenant | `ac2c03c7-d196-4402-870a-64c1f3485a5d` |
| Público | `AzureADMyOrg` — **só contas do tenant XPTO** |
| URI de redirecionamento | `https://api.xptoinc.com.br/auth/v1/callback` |
| Claims no id_token | `email`, `upn`, `preferred_username`, `given_name`, `family_name` |
| Permissões (com consentimento do admin) | `openid`, `profile`, `email` |
| Segredo | válido por 2 anos — **anotar a data de expiração** |

O `email` como claim opcional é essencial: é por ele que o GoTrue encontra a pessoa
em `public.users`. Sem ele, o login completa mas não casa com ninguém.

### Armadilha: a URL do provedor não leva `/v2.0`

O GoTrue **acrescenta** `/oauth2/v2.0/authorize` à URL configurada. Se
`GOTRUE_EXTERNAL_AZURE_URL` terminar em `/v2.0`, o endereço final fica
`.../v2.0/oauth2/v2.0/authorize` — um endpoint que não existe. A Microsoft devolve
vazio e o navegador **baixa um arquivo chamado `authorize`** em vez de mostrar a
tela de login. O valor correto termina no id do tenant:

```
https://login.microsoftonline.com/<tenant-id>
```

### No Supabase (VM `vm-supabase`, `/opt/supa`)

```
GOTRUE_EXTERNAL_AZURE_ENABLED=true
GOTRUE_EXTERNAL_AZURE_CLIENT_ID=689ba542-9314-4079-a0ec-1c7bf49ff1a9
GOTRUE_EXTERNAL_AZURE_SECRET=<no .env, não versionado>
GOTRUE_EXTERNAL_AZURE_URL=https://login.microsoftonline.com/<tenant>
GOTRUE_EXTERNAL_AZURE_REDIRECT_URI=https://api.xptoinc.com.br/auth/v1/callback
ADDITIONAL_REDIRECT_URLS=<SHAAR + as oito aplicações>
```

O bloco do provedor no `docker-compose.yml` vinha comentado no template do Supabase
e foi ativado. Há backups datados de `.env` e `docker-compose.yml` no mesmo diretório.

## Como funciona na prática

1. A pessoa clica em **Entrar com SSO XPTO** no SHAAR
2. Vai para `login.microsoftonline.com/<tenant>` — só o tenant XPTO é aceito
3. Autenticada, volta para `api.xptoinc.com.br/auth/v1/callback`
4. O GoTrue lê o e-mail do id_token e **casa com a conta existente** em `auth.users`
5. Devolve a sessão ao SHAAR, que chama `shaar_minhas_apps()`
6. A autorização sai da base do TETELESTAI, como sempre

## Manutenção

**O segredo expira em 2 anos.** Quando chegar perto:

```bash
az ad app credential reset --id 689ba542-9314-4079-a0ec-1c7bf49ff1a9 \
  --display-name supabase-gotrue --years 2 --query password -o tsv
```

Grave o novo valor em `GOTRUE_EXTERNAL_AZURE_SECRET` no `/opt/supa/.env` e recrie
o container:

```bash
cd /opt/supa && docker compose up -d --no-deps --force-recreate auth
```

**Aplicação nova no ecossistema** precisa entrar em `ADDITIONAL_REDIRECT_URLS`,
senão o retorno do SSO é recusado.
