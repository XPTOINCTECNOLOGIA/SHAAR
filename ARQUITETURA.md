# SHAAR by XPTO — arquitetura

**SHAAR** (שער, "portão") é o hub de acesso do ecossistema XPTO: o usuário faz um login
central e vê apenas as microaplicações que tem direito de acessar.

## Regras de produto

1. **Uma conta para tudo.** A base de usuários é a do **TETELESTAI** — `public.users`.
   O SHAAR não tem base própria e não cria usuário.
2. **Autorização é por aplicação.** Cada microaplicação continua dona da sua
   autorização. O SHAAR decide apenas *se* a pessoa entra, nunca *o que ela faz lá*.
3. **Uma aplicação → entra direto.** Sem painel intermediário.
4. **Duas ou mais → painel de escolha.**
5. **O que não é autorizado não aparece.** Nem esmaecido, nem com botão de solicitar.
   A filtragem acontece no banco, não no front.
6. **Convite carrega o acesso.** O administrador escolhe as aplicações e os papéis
   *antes* de gerar o link; ao aceitar, o acesso já nasce em vigor.

## A base real (levantada no ambiente, não suposta)

Todo o ecossistema vive num **único projeto Supabase** (`svnfifxiqvztcwegayos`,
PostgreSQL 17). As tabelas são prefixadas por aplicação; o núcleo sem prefixo é o
TETELESTAI.

### Identidade — `public.users`

42 pessoas, 36 ativas. Colunas relevantes: `id` (bigint), `auth_user_id` (uuid do
Supabase Auth), `email`, `full_name`, `profile_id`, `active`, `blocked`,
`user_kind` (`real` / `test`), `login_method`.

**41 dos 42 usuários têm `login_method = 'local'`** — a autenticação é por credencial
local (`public.user_local_credentials`), não por provedor externo. Qualquer desenho
que pressuponha Entra ID como base de identidade está errado.

### Autorização — dois mecanismos convivendo

| Aplicação | Como autoriza hoje | Pessoas |
|---|---|---|
| TETELESTAI | `profiles` (perfil ativo) | 36 |
| MANNA | RBAC central, `permissions.module = 'MANNA'` | via perfil |
| FAITH | RBAC central, `permissions.module = 'oportunidades'` | via perfil |
| JIREH | `jireh_user_permissions` | 2 |
| TIKKUN | `tikkun_user_roles` | 12 |
| BNEI YISRAEL | `bnei_user_roles` | 41 |
| MERKAVAH | `merkavah_memberships` (ativos) | 41 |
| SPHRAGIS | `sphragis_perfis_assinatura` | 3 |

Uns usam o RBAC central do TETELESTAI (`profiles` → `profile_permissions` →
`permissions.module`); outros têm tabela própria. **O SHAAR respeita os dois** e não
substitui nenhum.

## O que o SHAAR acrescenta

Só duas coisas, ambas em `db/`:

- **`shaar_apps`** — o catálogo. É o que não existe hoje: uma lista de quais
  aplicações existem, como se chamam e onde ficam. Aplicação nova entra como linha;
  o hub se atualiza sem deploy.
- **`shaar_user_apps`** — uma *view* de leitura que agrega as autorizações já
  existentes e responde: quais aplicações esta pessoa abre, e com que papel. Não
  concede nada. Acrescentar aplicação = acrescentar um bloco no `union`.

A função `shaar_minhas_apps()` devolve apenas as linhas do próprio usuário — é assim
que a regra nº 5 fica garantida no servidor.

## Autenticação

O SHAAR autentica contra a base do TETELESTAI. Duas opções, a definir:

- **Reaproveitar o Supabase Auth** do ecossistema (`auth_user_id` já liga
  `public.users` ao usuário autenticado) — caminho mais curto e coerente.
- **Delegar ao TETELESTAI** via redirect e devolver uma sessão ao hub — mais próximo
  de um SSO clássico, mais trabalho.

> O gate de **Entra ID** hoje ativo no Static Web App protege apenas o *ambiente de
> preview*. Não é a autenticação do produto e não deve ser confundida com ela.

## Achado que merece decisão

Nenhuma pessoa ativa tem menos de **cinco** aplicações: 23 têm cinco, 12 têm seis e
1 tem sete. BNEI e MERKAVAH concedem acesso a 41 dos 42 usuários.

Ou seja: **hoje o acesso é concedido de forma ampla, quase por padrão.** O caso
"usuário com uma só aplicação" — que motivou a regra do redirecionamento direto —
praticamente não ocorre no estado atual.

O Quadro de Acessos do SHAAR torna isso visível de uma vez, e é a ferramenta para
apertar o que precisar ser apertado.

## Infraestrutura

| Camada | Onde |
|---|---|
| Dados e identidade | Supabase (PostgreSQL 17), projeto único do ecossistema |
| Hospedagem do hub | Azure Static Web Apps — `swa-shaar`, `rg-xpto-plataforma` |
| Domínio | `shaar.xptoinc.com.br` (Cloudflare, DNS-only) |
| Preview | GitHub Pages, aberto, sem dado real |
