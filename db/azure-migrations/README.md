# Migrations do banco (Azure)

Os arquivos em `db/` na raiz (01-...09-) são o schema ORIGINAL do SHAAR, já aplicado.
Para NOVAS mudanças de ESTRUTURA, coloque aqui arquivos `.sql` numerados (ex.: `001_nova_tabela.sql`).
Ao dar merge na `main`, o workflow "DB migrations -> Azure" aplica os arquivos novos
automaticamente no backend Azure (api.xptoinc.com.br), em transacao e idempotente.
NAO use as ferramentas Supabase antigas para o banco do Azure.
