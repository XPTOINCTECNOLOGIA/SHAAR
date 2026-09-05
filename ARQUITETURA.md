# SHAAR by XPTO — arquitetura

**SHAAR** (שער, "portão") é o hub de acesso do ecossistema XPTO: o usuário faz um login
central e vê apenas as microaplicações que tem direito de acessar.

## Regras de produto

1. **Uma conta para tudo.** Funcionários XPTO e terceiros usam a mesma identidade.
2. **Autorização é por aplicação.** Cada microaplicação é independente quanto a permissão
   de uso; o SHAAR decide apenas *se* o usuário entra, nunca *o que ele faz lá dentro*.
3. **Uma aplicação → entra direto.** Sem painel intermediário.
4. **Duas ou mais → painel de escolha.**
5. **O que não é autorizado não aparece.** Nada de aplicação esmaecida nem botão de
   "solicitar acesso": o usuário não descobre a existência do que não lhe foi concedido.
   Isso vale também no backend — a consulta ao catálogo já filtra por concessão.
6. **Convite carrega o acesso.** O administrador escolhe as aplicações e os papéis
   *antes* de gerar o link; ao aceitar, o acesso já nasce em vigor.

## Alicerce (definido)

| Camada | Escolha |
|---|---|
| Identidade | **Microsoft Entra ID** — funcionários no tenant; terceiros como convidados **B2B** |
| Hospedagem | **Azure Static Web Apps** (Standard) com provedor Entra ID |
| CI/CD | **GitHub Actions** → `Azure/static-web-apps-deploy` |
| Infra | **Bicep** (`infra/main.bicep`) |
| Segredos | **Azure Key Vault** |
| APIs | **Azure Functions** (deploy junto ao SWA, `api_location`) |

Entra ID resolve nativamente a exigência nº 1: o tenant é a base única de usuários, e o
convite B2B é o mecanismo oficial para terceiros — sem senha própria, sem base paralela.

## Em aberto

- **Banco de dados**: Azure SQL vs. PostgreSQL Flexible Server vs. Cosmos DB.
  A modelagem abaixo é relacional e roda em qualquer um dos dois primeiros sem mudança.

## Modelo de dados (independente do banco escolhido)

- `apps` — catálogo: código, nome, descrição, URL, ícone, ativa/inativa.
  Aplicação nova entra como linha; o hub renderiza sem deploy.
- `app_memberships` — `user_object_id` (o oid do Entra), `app_id`, `role`, `status`.
- `invites` — `token_hash` (só o hash; o token vive apenas no link), `email`,
  `invited_by`, `status`, `expires_at`, `accepted_by`, `accepted_at`.
- `invite_grants` — `invite_id`, `app_id`, `role`. É o carimbo de acessos do convite.

O aceite roda numa Function com identidade gerenciada (nunca no cliente): valida o token
(hash, validade, e-mail), dispara o convite B2B ou vincula o usuário existente, copia
`invite_grants` → `app_memberships` e encerra o convite — tudo em uma transação.

## Filtragem de aplicações

O SWA resolve papéis por uma função `GetRoles` no login: ela lê as `app_memberships` do
usuário e devolve os papéis. As rotas de cada aplicação ficam restritas a esses papéis,
e o catálogo devolvido ao front já vem filtrado — a invisibilidade da regra nº 5 é
garantida no servidor, não no CSS.

## SSO entre as aplicações

Todas as microaplicações usam o mesmo registro de aplicativo no Entra ID (ou registros
distintos no mesmo tenant, com consentimento prévio). O usuário autentica uma vez e
atravessa os portões sem novo login.
