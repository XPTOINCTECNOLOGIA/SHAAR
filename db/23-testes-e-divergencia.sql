-- =====================================================================
-- Central de Permissionamento — testes de autorização e divergência
-- =====================================================================
--
-- Duas ferramentas para a mesma pergunta: "posso ligar a chave sem partir
-- nada?".
--
--   DIVERGÊNCIA compara, pessoa a pessoa, o que a Central diria com o que o
--   modelo antigo de cada aplicação decide hoje. Enquanto houver diferença,
--   não se troca quem decide. É o mesmo padrão de shaar_divergencias, que já
--   serve o directório.
--
--   TESTES fixam o comportamento esperado num conjunto de referência que
--   corre em cada migração. Autorização é código, e código sem testes muda-se
--   com medo. A diferença é que aqui um erro não dá um ecrã feio — dá alguém
--   a ver o que não devia, ou o financeiro sem conseguir fechar o mês.
--
-- Depois da migração ninguém se vai lembrar por que razão a permissão X
-- estava assim. O teste lembra-se.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- DIVERGÊNCIA
-- ---------------------------------------------------------------------
-- Recalcula a verdade de HOJE a partir dos modelos antigos e compara com o
-- que está na Central. Por construção, no dia da importação dá zero. O valor
-- está em correr todos os dias: apanha quem mexer no modelo antigo depois
-- disso, que é como as duas realidades se afastam sem ninguém reparar.
create or replace view public.shaar_permissao_verdade_antiga as
  -- perfil -> permissão, cinco aplicações
  select distinct u.id as user_id, sp.app_code, sp.code
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
    join public.shaar_gate_access g    on g.user_id = u.id and g.app_code = sp.app_code
   where u.active
  union
  -- concessões individuais do JIREH
  select distinct u.id, sp.app_code, sp.code
    from public.jireh_user_permissions jup
    join public.users u             on u.id = jup.user_id and u.active
    join public.permissions p       on p.id = jup.permission_id
    join public.shaar_permission sp on sp.code = p.code and sp.origem = 'herdado'
    join public.shaar_gate_access g on g.user_id = u.id and g.app_code = sp.app_code
  union
  -- papéis do BNEI
  select u.id, 'BNEI', c.code
    from public.bnei_user_roles r
    join public.users u             on u.id = r.user_id and u.active
    join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'BNEI'
    cross join lateral (select unnest(case r.role
      when 'consulta' then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar']
      when 'gestor'   then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir']
      when 'admin'    then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir','financeiro.gerir','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  -- papéis do TIKKUN
  select u.id, 'TIKKUN', c.code
    from public.tikkun_user_roles r
    join public.users u             on u.id = r.user_id and u.active
    join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'TIKKUN'
    cross join lateral (select unnest(case r.role::text
      when 'tecnico'       then array['os.consultar','os.executar','os.assinar']
      when 'supervisor'    then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar']
      when 'gestor'        then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar']
      when 'administrador' then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  -- SPHRAGIS: quem passa o portão pode tudo
  select g.user_id, 'SPHRAGIS', sp.code
    from public.shaar_gate_access g
    join public.users u             on u.id = g.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'SPHRAGIS'
   where g.app_code = 'SPHRAGIS';

create or replace view public.shaar_permissao_divergencias as
  select coalesce(a.user_id, b.user_id)   as user_id,
         u.email,
         u.full_name,
         coalesce(a.app_code, b.app_code) as app_code,
         coalesce(a.code, b.code)         as code,
         case when b.user_id is null then 'so_no_modelo_antigo'
              when a.user_id is null then 'so_na_central'
         end                              as divergencia
    from public.shaar_permissao_verdade_antiga a
    full outer join (
      select user_id, app_code, code
        from public.shaar_permission_grant
       where efeito = 'permitir'
         and valido_de <= now()
         and (valido_ate is null or valido_ate > now())
         and app_code <> 'SHAAR'          -- a Central nao existia no modelo antigo
    ) b on b.user_id = a.user_id and b.app_code = a.app_code and b.code = a.code
    join public.users u on u.id = coalesce(a.user_id, b.user_id)
   where a.user_id is null or b.user_id is null;

comment on view public.shaar_permissao_divergencias is
  'Diferenca entre o que a Central diria e o que o modelo antigo decide hoje. Criterio de passagem da migracao: zero durante sete dias seguidos.';

create or replace function public.shaar_ver_divergencias_permissao()
returns setof public.shaar_permissao_divergencias
language sql stable security definer set search_path = public as $$
  select * from public.shaar_permissao_divergencias
   order by app_code, email, code;
$$;

-- ---------------------------------------------------------------------
-- TESTES DE AUTORIZAÇÃO
-- ---------------------------------------------------------------------
create table if not exists public.shaar_autorizacao_teste (
  id        bigserial primary key,
  descricao text    not null,
  email     text    not null,
  app_code  text    not null,
  code      text    not null,
  contexto  jsonb   not null default '{}'::jsonb,
  esperado  boolean not null,
  criado_em timestamptz not null default now()
);

create or replace function public.shaar_correr_testes()
returns table (id bigint, descricao text, esperado boolean, obtido boolean, passou boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.descricao, t.esperado,
         public.shaar_pode(t.app_code, t.code, t.contexto, u.id),
         public.shaar_pode(t.app_code, t.code, t.contexto, u.id) is not distinct from t.esperado
    from public.shaar_autorizacao_teste t
    join public.users u on lower(u.email) = lower(t.email)
   order by 5, t.id;
$$;

-- As regras de escopo são testadas em separado, como função pura: não
-- dependem de ninguém e é onde vive o caso mais importante de todos —
-- contexto em falta tem de negar.
create or replace function public.shaar_correr_testes_escopo()
returns table (caso text, esperado boolean, obtido boolean, passou boolean)
language sql immutable set search_path = public as $$
  with c(caso, escopo, ctx, esperado) as (values
    ('escopo vazio nao limita nada',
     '{}'::jsonb, '{}'::jsonb, true),
    ('lista: valor presente na lista',
     '{"departamento":["FIN","OPS"]}'::jsonb, '{"departamento":"FIN"}'::jsonb, true),
    ('lista: valor fora da lista',
     '{"departamento":["FIN","OPS"]}'::jsonb, '{"departamento":"MKT"}'::jsonb, false),
    ('lista: dimensao ausente do contexto NEGA',
     '{"departamento":["FIN","OPS"]}'::jsonb, '{}'::jsonb, false),
    ('tecto: dentro do limite',
     '{"valor_max":50000}'::jsonb, '{"valor":40000}'::jsonb, true),
    ('tecto: exactamente no limite',
     '{"valor_max":50000}'::jsonb, '{"valor":50000}'::jsonb, true),
    ('tecto: acima do limite',
     '{"valor_max":50000}'::jsonb, '{"valor":900000}'::jsonb, false),
    ('tecto: dimensao ausente do contexto NEGA',
     '{"valor_max":50000}'::jsonb, '{}'::jsonb, false),
    ('tecto: valor nao numerico NEGA',
     '{"valor_max":50000}'::jsonb, '{"valor":"muito"}'::jsonb, false),
    ('piso: acima do minimo',
     '{"nivel_min":90}'::jsonb, '{"nivel":100}'::jsonb, true),
    ('piso: abaixo do minimo',
     '{"nivel_min":90}'::jsonb, '{"nivel":50}'::jsonb, false),
    ('duas dimensoes: ambas satisfeitas',
     '{"departamento":["FIN"],"valor_max":50000}'::jsonb,
     '{"departamento":"FIN","valor":10}'::jsonb, true),
    ('duas dimensoes: uma falha, nega tudo',
     '{"departamento":["FIN"],"valor_max":50000}'::jsonb,
     '{"departamento":"FIN","valor":99999}'::jsonb, false),
    ('igualdade exacta',
     '{"unidade":"matriz"}'::jsonb, '{"unidade":"matriz"}'::jsonb, true),
    ('contexto a mais nao estorva',
     '{"departamento":["FIN"]}'::jsonb,
     '{"departamento":"FIN","valor":1,"outra":"coisa"}'::jsonb, true)
  )
  select c.caso, c.esperado,
         public.shaar_escopo_satisfeito(c.escopo, c.ctx),
         public.shaar_escopo_satisfeito(c.escopo, c.ctx) is not distinct from c.esperado
    from c order by 4, 1;
$$;

commit;

-- ---------------------------------------------------------------------
-- Conjunto de referência, semeado a partir de gente real
-- ---------------------------------------------------------------------
-- Sem emails escritos à mão: os casos são semeados a partir de quem existe,
-- para o conjunto continuar válido quando as pessoas mudarem.
begin;
delete from public.shaar_autorizacao_teste;

-- quem administra o hub consegue gerir permissões
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'SUPER ADMIN gere permissoes na Central', u.email, 'SHAAR', 'permissao.gerir', '{}', true
  from public.users u join public.profiles p on p.id = u.profile_id
 where p.name = 'SUPER ADMIN' and u.active
   and exists (select 1 from public.shaar_gate_access g where g.user_id=u.id and g.app_code='SHAAR')
 limit 1;

-- quem não administra, não gere
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'COLABORADOR nao gere permissoes na Central', u.email, 'SHAAR', 'permissao.gerir', '{}', false
  from public.users u join public.profiles p on p.id = u.profile_id
 where p.name = 'COLABORADOR' and u.active limit 1;

-- sem portão não há permissão, mesmo com concessão
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'sem portao do JIREH nao passa', u.email, 'JIREH', 'reports:read', '{}', false
  from public.users u
 where u.active
   and not exists (select 1 from public.shaar_gate_access g where g.user_id=u.id and g.app_code='JIREH')
 limit 1;

-- permissão que ninguém tem
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'permissao nunca concedida e negada', u.email, 'SPHRAGIS', 'documento.excluir', '{}', false
  from public.users u
 where u.active
   and not exists (select 1 from public.shaar_permission_grant x
                    where x.user_id=u.id and x.app_code='SPHRAGIS' and x.code='documento.excluir')
 limit 1;

-- quem passa o portão do SPHRAGIS assina, como hoje
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'com portao do SPHRAGIS assina documentos', u.email, 'SPHRAGIS', 'documento.assinar', '{}', true
  from public.users u
  join public.shaar_gate_access g on g.user_id=u.id and g.app_code='SPHRAGIS'
 where u.active limit 1;

-- técnico do TIKKUN executa mas não aprova
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'tecnico do TIKKUN executa ordem de servico', u.email, 'TIKKUN', 'os.executar', '{}', true
  from public.users u join public.tikkun_user_roles r on r.user_id = u.id
  join public.shaar_gate_access g on g.user_id=u.id and g.app_code='TIKKUN'
 where r.role::text = 'tecnico' and u.active limit 1;

insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'tecnico do TIKKUN NAO aprova ordem de servico', u.email, 'TIKKUN', 'os.aprovar', '{}', false
  from public.users u join public.tikkun_user_roles r on r.user_id = u.id
  join public.shaar_gate_access g on g.user_id=u.id and g.app_code='TIKKUN'
 where r.role::text = 'tecnico' and u.active limit 1;

-- consulta do BNEI vê mas não gere
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'consulta do BNEI ve o quadro de pessoas', u.email, 'BNEI', 'pessoa.consultar', '{}', true
  from public.users u join public.bnei_user_roles r on r.user_id = u.id
  join public.shaar_gate_access g on g.user_id=u.id and g.app_code='BNEI'
 where r.role = 'consulta' and u.active limit 1;

insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'consulta do BNEI NAO gere pessoas', u.email, 'BNEI', 'pessoa.gerir', '{}', false
  from public.users u join public.bnei_user_roles r on r.user_id = u.id
  join public.shaar_gate_access g on g.user_id=u.id and g.app_code='BNEI'
 where r.role = 'consulta' and u.active limit 1;

-- utilizador inactivo não passa
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'conta inactiva nao tem permissao espelhada', u.email, 'TETELESTAI', 'todo.create', '{}', false
  from public.users u
 where not u.active
   and not exists (select 1 from public.shaar_permission_grant x
                    where x.user_id=u.id and x.app_code='TETELESTAI' and x.code='todo.create')
 limit 1;

commit;

select count(*) || ' casos semeados' from public.shaar_autorizacao_teste;
