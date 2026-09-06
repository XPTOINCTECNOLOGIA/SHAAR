<!-- xpto-azure-infra: gerado na migração para Azure. Não remover. -->
# ⚙️ Infra XPTO no Azure — LEIA ANTES DE MEXER

O ecossistema XPTO roda no **Microsoft Azure** (produção ÚNICA). O SHAAR nasceu no Azure.

## Infraestrutura (NÃO reverter)
- **Backend de dados (Supabase self-hosted no Azure):** `https://api.xptoinc.com.br`
  - ⚠️ **NUNCA** aponte o app para `*.supabase.co` (projeto antigo `svnfifxiqvztcwegayos`, congelado / em desligamento).
  - O SHAAR autentica e lê dados contra essa base do ecossistema (tabelas `shaar_*`; login contra a base do TETELESTAI). A anon key é pública, protegida por RLS.
- **Hospedagem:** Static Web App `swa-shaar` (grupo `rg-xpto-plataforma`). Frontend em `site/`.

## Deploy (sob demanda pela CLI — ver DEPLOY.md)
- O SHAAR **não** usa deploy automático por push (intencional: sem token no GitHub).
- Publicar: `az login` + `./scripts/deploy-azure.sh` (preview: `./scripts/deploy-azure.sh <branch>`). Autorização pelo papel `preview` — detalhes em `DEPLOY.md`.

## Migrations de banco (mudanças de ESTRUTURA) — IMPORTANTE
- ⚠️ As ferramentas Supabase (MCP) apontam para o projeto ANTIGO CONGELADO — **NÃO** as use para alterar o banco do Azure.
- Os arquivos `db/*.sql` (01..09) são o schema ORIGINAL do SHAAR (já aplicado). Não os reaproveite para novas mudanças.
- Para NOVA mudança de estrutura: crie um `.sql` numerado em **`db/azure-migrations/`** (ex.: `001_nova_tabela.sql`). Ao dar merge na `main`, o workflow **"DB migrations -> Azure"** aplica no backend Azure automaticamente (transacional e idempotente, rastreado em `public._xpto_migrations`).

## Observações
- Segurança de banco: o papel `anon` está alinhado à produção (SELECT/EXECUTE mínimos) — não afrouxe grants sem necessidade.

## 🔐 Permissões — a Central decide, e permissão não é regra de negócio

Desde set/2026 o permissionamento é **INDIVIDUAL e CENTRALIZADO** no SHAAR.
Podem criar-se permissões novas à vontade; o que não se pode é criá-las fora da
Central nem confundi-las com regras de negócio.

**Quem decide:** só `public.shaar_pode('APP','codigo')`. Lê o portão, a
concessão individual, o escopo e a negação — mais nada.
**NUNCA** decida a partir de `profile_id`/`profiles` (perfil **não é
autoridade**), `position_id`/cargo, ou papéis próprios da app (`*_user_roles`).

**Portão e permissão são INDEPENDENTES.** A permissão é da pessoa e fica
registada mesmo com o portão fechado. "Tem permissão numa app onde não entra" é
o estado normal, não um erro.

**Permissão ≠ regra de negócio.** Teste: se a resposta muda consoante **o
registo** em causa, é regra de negócio e fica no código da aplicação. Se depende
só de **quem** pergunta, é permissão e vai para a Central.
Exemplos reais: o JIREH recusa que o requerente aprove o próprio reembolso
(`requester_id <> actor_id`) — regra de negócio, supera a permissão. Posse
(`created_by`), hierarquia e máquina de estados também.
E **nunca infira uma regra de negócio de quem tem que permissões**: ter `criar`
e `aprovar` não prova que alguém criou e aprovou a mesma coisa — isso lê-se no
rasto (`created_by`, `decided_by`, `actor_id`), não no catálogo.

**Como criar uma permissão nova** (só por aqui):
1. `.sql` numerado em `db/azure-migrations/` do repo **SHAAR** — nunca pelas
   ferramentas Supabase (MCP) nem pelo sistema antigo de migrations.
2. `insert into public.shaar_permission (app_code, code, name, description,
   grupo, sort_order, origem) values (...)` com `origem='aplicacao'`.
3. Impor com `shaar_pode` na política RLS (use `as restrictive` — restritivas
   combinam com AND e só estreitam; permissivas combinam com OR e alargam) ou
   no RPC (`if not public.shaar_pode(...) then raise exception 'FORBIDDEN: ...'`).
4. Conceder **pessoa a pessoa, com motivo escrito**. Nunca em massa por perfil
   ou cargo. O histórico é escrito por gatilho — não o escreva à mão.
5. Se pede alçada: declare `escopo_dimensoes` (`valor_max`, `departamento`,
   `nivel_min`) e passe o contexto na chamada. **Dimensão declarada e ausente do
   contexto NEGA** — falha fechado.

**Fica vermelho** no relatório nocturno "Estado da Central": gatilho de registo
desligado, concessão sem evento ou sem motivo, histórico editável, e-mail
ambíguo ou vazio, caso de referência a falhar.
**Não** fica vermelho a Central diferir do modelo antigo de perfis — isso são as
decisões tomadas desde a migração, e é suposto crescer.

Detalhe completo, com exemplos e checklist de PR:
`docs/PERMISSOES-PARA-AGENTES.md` no repositório **SHAAR**.
