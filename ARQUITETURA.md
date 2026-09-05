# SHAAR by XPTO — arquitetura

**SHAAR** (שער, "portão") é o hub de acesso do ecossistema XPTO: o usuário faz um login
central e vê apenas as microaplicações que tem direito de acessar.

## Regras de produto

1. **Uma conta para tudo.** A base de usuários é a do **TETELESTAI** — `public.users`.
   O SHAAR não tem base própria e não cria usuário.
1b. **Entra ID autentica; a base do TETELESTAI autoriza.** Quem existe na base
   *e também* no Entra ID entra pelo Entra ID. Estar no Entra não concede acesso
   nenhum, e não estar não retira o que a base já concedeu.
2. **Autorização é por aplicação.** Cada microaplicação continua dona da sua
   autorização. O SHAAR decide apenas *se* a pessoa entra, nunca *o que ela faz lá*.
3. **Uma aplicação → entra direto.** Sem painel intermediário.
4. **Duas ou mais → painel de escolha.**
5. **O que não é autorizado não aparece.** Nem esmaecido, nem com botão de solicitar.
   A filtragem acontece no banco, não no front.
6. **Convite carrega o acesso.** O administrador escolhe as aplicações e os papéis
   *antes* de gerar o link; ao aceitar, o acesso já nasce em vigor.

## A base real (levantada no ambiente, não suposta)

Todo o ecossistema vive num **único banco Supabase**, hoje auto-hospedado no Azure
(VM `vm-supabase`, servido em `api.xptoinc.com.br`). As tabelas são prefixadas por
aplicação; o núcleo sem prefixo é o TETELESTAI.

> O levantamento de estrutura abaixo foi feito no projeto Supabase anterior, antes da
> migração. O esquema é o mesmo; o endereço mudou.

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

## Autenticação — dois caminhos, uma identidade

A autorização **vem sempre da base do TETELESTAI**. O que muda é como a pessoa prova
quem é:

| Caminho | Quem usa | Como |
|---|---|---|
| **Entra ID** | Quem existe na base **e** no tenant XPTO | SSO corporativo. O Static Web App entrega o e-mail no claim. |
| **Credencial local** | Terceiros e quem não está no Entra | `public.user_local_credentials`, como hoje (41 dos 42 usuários). |

**O Entra ID nunca autoriza.** Estar no tenant não concede aplicação nenhuma; não
estar não retira o que a base já concedeu. Ele só responde "esta pessoa é quem diz
ser" — e, para quem tem essa opção, é o caminho preferencial de entrada.

O **e-mail** é a chave que une os dois caminhos: a mesma linha de `public.users`
serve o funcionário que entrou por SSO e o terceiro que entrou por senha. Quem
resolve isso é `shaar_usuario_atual()`, que aceita tanto `auth.uid()` quanto o claim
de e-mail.

A tela de acesso já reflete os dois: o botão **Entrar com SSO XPTO** para quem tem
Entra, e e-mail + senha para os demais.

## Achado que merece decisão

Nenhuma pessoa ativa tem menos de **cinco** aplicações: 23 têm cinco, 12 têm seis e
1 tem sete. BNEI e MERKAVAH concedem acesso a 41 dos 42 usuários.

Ou seja: **hoje o acesso é concedido de forma ampla, quase por padrão.** O caso
"usuário com uma só aplicação" — que motivou a regra do redirecionamento direto —
praticamente não ocorre no estado atual.

O Quadro de Acessos do SHAAR torna isso visível de uma vez, e é a ferramenta para
apertar o que precisar ser apertado.

## Infraestrutura — levantada no ambiente

Tudo em `rg-xpto-plataforma`, subscription `Azure subscription 1`.

| Camada | Recurso | Onde |
|---|---|---|
| Dados e identidade | **Supabase auto-hospedado** na VM `vm-supabase` (Ubuntu 24.04, Standard_E2bds_v5) | brazilsouth |
| Endpoint da base | `https://api.xptoinc.com.br` → `20.226.86.230` | Cloudflare, DNS-only |
| PostgreSQL gerenciado | `pg-xpto-plataforma` (PG 15, Burstable B1ms) — provisionado, **sem banco de aplicação** | brazilsouth |
| Backends próprios | Container Apps `app-tetelestai` e `app-bneiyisrael`, ambiente `cae-xpto` | brazilsouth |
| Segredos | Key Vault `kv-xpto-ec26a224` | brazilsouth |
| Hospedagem do hub | Azure Static Web Apps `swa-shaar` | eastus2 |
| Domínio do hub | `shaar.xptoinc.com.br` | Cloudflare, DNS-only |
| Preview aberto | GitHub Pages — sem dado real | — |

### Dois pontos que merecem sua atenção

**`pg-xpto-plataforma` está vazio.** O servidor existe e está saudável, mas só tem os
bancos de sistema (`postgres`, `azure_sys`, `azure_maintenance`). Ou a migração para
ele não aconteceu, ou ele foi provisionado para um passo futuro. Custa mesmo parado.

**`swa-tetelestai` e `swa-bnei` estão órfãos.** Existem como Static Web Apps, mas os
domínios `tetelestai.` e `bnei.` apontam para os Container Apps. São provavelmente
sobra de uma tentativa anterior.
