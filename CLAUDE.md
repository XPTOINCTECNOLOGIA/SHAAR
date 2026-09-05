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
