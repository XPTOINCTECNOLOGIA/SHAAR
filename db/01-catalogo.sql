-- SHAAR · catálogo de aplicações
--
-- É a única tabela nova que o SHAAR precisa. O ecossistema já tem base de
-- usuários (public.users, do TETELESTAI) e já tem autorização por aplicação —
-- o que não existe é um lugar que diga quais aplicações existem, como se
-- chamam e onde ficam. Aplicação nova entra como linha; o hub se atualiza
-- sozinho, sem deploy.

create table if not exists public.shaar_apps (
  code          text primary key,
  name          text        not null,
  description   text        not null,
  url           text        not null,
  sort_order    int         not null default 100,
  active        boolean     not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.shaar_apps is
  'Catálogo das microaplicações do ecossistema XPTO exibidas no SHAAR.';

insert into public.shaar_apps (code, name, description, url, sort_order) values
  ('TETELESTAI', 'TETELESTAI',   'Gestão de tarefas e governança corporativa.',        'https://tetelestai.xptoinc.com.br', 10),
  ('JIREH',      'JIREH',        'Gestão de reembolsos corporativos.',                 'https://jireh.xptoinc.com.br',      20),
  ('FAITH',      'FAITH',        'Gestão de leads da parceria XPTO × SERPRO.',         'https://faith.xptoinc.com.br',      30),
  ('TIKKUN',     'TIKKUN',       'Manutenção e garantias — CMMS, EAM Light e RMA.',    'https://tikkun.xptoinc.com.br',     40),
  ('MANNA',      'MANNA',        'Compras e suprimentos — da solicitação ao recebimento.', 'https://manna.xptoinc.com.br',  50),
  ('BNEI',       'BNEI YISRAEL', 'Governança de pessoas, contratos, custos e compliance.', 'https://bnei.xptoinc.com.br',   60),
  ('SPHRAGIS',   'SPHRAGIS',     'Assinatura eletrônica avançada de documentos.',      'https://sphragis.xptoinc.com.br',   70),
  ('MERKAVAH',   'MERKAVAH',     'Gestão de frota e telemetria.',                      'https://merkavah.xptoinc.com.br',   80)
on conflict (code) do update
  set name = excluded.name,
      description = excluded.description,
      url = excluded.url,
      sort_order = excluded.sort_order,
      updated_at = now();

alter table public.shaar_apps enable row level security;

-- catálogo é leitura para qualquer usuário autenticado; a filtragem do que
-- cada um enxerga acontece na view de acessos, não aqui.
drop policy if exists shaar_apps_leitura on public.shaar_apps;
create policy shaar_apps_leitura on public.shaar_apps
  for select to authenticated using (active);
