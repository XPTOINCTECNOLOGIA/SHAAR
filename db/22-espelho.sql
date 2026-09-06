-- =====================================================================
-- Central de Permissionamento — espelho do acesso efectivo actual
-- =====================================================================
--
-- Este ficheiro NÃO decide nada. Copia para a Central o que cada pessoa já
-- pode hoje, exactamente como pode, para que ligar a chave mais tarde não
-- tranque ninguém fora. É o passo que torna a migração reversível: enquanto
-- o espelho e a realidade disserem o mesmo, trocar quem decide não muda
-- nada para quem trabalha.
--
-- Fontes, uma por modelo actual:
--
--   profile_permissions       TETELESTAI · FAITH · JIREH · MANNA · MERKAVAH
--   jireh_user_permissions    JIREH, concessões individuais que já existiam
--   bnei_user_roles           BNEI, 3 papéis
--   tikkun_user_roles         TIKKUN, 4 papéis
--   (nenhuma)                 SPHRAGIS, onde quem passa o portão pode tudo
--   perfil                    SHAAR, a própria Central
--
-- Em todas: só para quem tem o portão daquela aplicação aberto. Uma
-- permissão sem portão nunca produziu efeito e não vale a pena importar.
--
-- O escopo entra vazio de propósito. Vazio significa "sem limite", que é o
-- que se passa hoje. Apertar alçadas é trabalho da primeira recertificação,
-- decidido por gente, não adivinhado por uma migração.
--
-- ATENÇÃO, e vale ser dito: importar o estado actual importa também os erros
-- actuais. A marca `motivo` distingue o que foi decidido do que foi herdado,
-- e é por aí que a recertificação começa.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Perfil -> permissão, para as cinco aplicações que usam o catálogo
-- ---------------------------------------------------------------------
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select distinct
  u.id, sp.app_code, sp.code, 'permitir', '{}'::jsonb,
  'migracao do modelo anterior — perfil ' || pf.name, null::bigint, now()
from public.users u
join public.profiles pf            on pf.id = u.profile_id
join public.profile_permissions pp on pp.profile_id = u.profile_id
join public.permissions p          on p.id = pp.permission_id
join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
join public.shaar_gate_access g    on g.user_id = u.id and g.app_code = sp.app_code
where u.active
on conflict (user_id, app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- 2. JIREH — concessões individuais que já existiam
-- ---------------------------------------------------------------------
-- O JIREH já fazia o que a Central vai generalizar: permissão pessoa a
-- pessoa, com quem concedeu e porquê. O `reason` original é preservado.
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select distinct on (u.id, sp.app_code, sp.code)
  u.id, sp.app_code, sp.code, 'permitir', '{}'::jsonb,
  'migracao do modelo anterior — concessao individual JIREH'
    || coalesce(': ' || nullif(trim(jup.reason), ''), ''),
  jup.granted_by, coalesce(jup.created_at, now())
from public.jireh_user_permissions jup
join public.users u             on u.id = jup.user_id and u.active
join public.permissions p       on p.id = jup.permission_id
join public.shaar_permission sp on sp.code = p.code and sp.origem = 'herdado'
join public.shaar_gate_access g on g.user_id = u.id and g.app_code = sp.app_code
order by u.id, sp.app_code, sp.code, jup.created_at desc
on conflict (user_id, app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- 3. BNEI YISRAEL — 3 papéis
-- ---------------------------------------------------------------------
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select u.id, 'BNEI', c.code, 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — papel ' || r.role, null::bigint, now()
from public.bnei_user_roles r
join public.users u             on u.id = r.user_id and u.active
join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'BNEI'
cross join lateral (
  select unnest(
    case r.role
      when 'consulta' then array['pessoa.consultar','contrato.consultar',
                                 'financeiro.consultar','compliance.consultar']
      when 'gestor'   then array['pessoa.consultar','contrato.consultar',
                                 'financeiro.consultar','compliance.consultar',
                                 'pessoa.gerir','contrato.gerir','compliance.gerir']
      when 'admin'    then array['pessoa.consultar','contrato.consultar',
                                 'financeiro.consultar','compliance.consultar',
                                 'pessoa.gerir','contrato.gerir','compliance.gerir',
                                 'financeiro.gerir','configuracao.gerir']
      else array[]::text[]
    end) as code
) c
on conflict (user_id, app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- 4. TIKKUN — 4 papéis
-- ---------------------------------------------------------------------
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select u.id, 'TIKKUN', c.code, 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — papel ' || r.role::text, null::bigint, now()
from public.tikkun_user_roles r
join public.users u             on u.id = r.user_id and u.active
join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'TIKKUN'
cross join lateral (
  select unnest(
    case r.role::text
      when 'tecnico'       then array['os.consultar','os.executar','os.assinar']
      when 'supervisor'    then array['os.consultar','os.executar','os.assinar',
                                      'os.criar','os.aprovar']
      when 'gestor'        then array['os.consultar','os.executar','os.assinar',
                                      'os.criar','os.aprovar','equipa.gerir',
                                      'custo.consultar','relatorio.consultar']
      when 'administrador' then array['os.consultar','os.executar','os.assinar',
                                      'os.criar','os.aprovar','equipa.gerir',
                                      'custo.consultar','relatorio.consultar',
                                      'configuracao.gerir']
      else array[]::text[]
    end) as code
) c
on conflict (user_id, app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- 5. SPHRAGIS — quem passa o portão pode tudo
-- ---------------------------------------------------------------------
-- Não é uma decisão nova: é o que acontece hoje, escrito. A partir do momento
-- em que fica escrito, passa a poder ser recortado — que é todo o objectivo.
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select g.user_id, 'SPHRAGIS', sp.code, 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — SPHRAGIS nao tinha permissoes; quem entrava podia tudo',
       null, now()
from public.shaar_gate_access g
join public.users u          on u.id = g.user_id and u.active
join public.shaar_permission sp on sp.app_code = 'SPHRAGIS'
where g.app_code = 'SPHRAGIS'
on conflict (user_id, app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- 6. SHAAR — a própria Central
-- ---------------------------------------------------------------------
-- Abre o portão do SHAAR a quem já administrava o hub. Sem esta parte,
-- ninguém consegue usar a Central — incluindo quem a vai ligar.
insert into public.shaar_gate_access (user_id, app_code, granted_at)
select u.id, 'SHAAR', now()
from public.users u
join public.profiles pf on pf.id = u.profile_id
where u.active and pf.name in ('SUPER ADMIN','BOARD','CEO')
on conflict do nothing;

insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select u.id, 'SHAAR', c.code, 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — perfil ' || pf.name || ' ja administrava o hub',
       null, now()
from public.users u
join public.profiles pf on pf.id = u.profile_id
cross join lateral (
  select unnest(
    case pf.name
      when 'SUPER ADMIN' then array['quadro.consultar','portao.gerir','permissao.gerir',
                                    'diretorio.gerir','auditoria.consultar']
      when 'BOARD'       then array['quadro.consultar','auditoria.consultar']
      when 'CEO'         then array['quadro.consultar','auditoria.consultar']
      else array[]::text[]
    end) as code
) c
where u.active
on conflict (user_id, app_code, code) do nothing;

commit;

-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select app_code,
       count(*)                          as concessoes,
       count(distinct user_id)           as pessoas,
       count(*) filter (where escopo <> '{}'::jsonb) as com_escopo
  from public.shaar_permission_grant
 group by app_code order by app_code;

select 'eventos de historico' as o, count(*)::text as v from public.shaar_permission_event
union all
select 'revisoes abertas por conflito', count(*)::text from public.shaar_permission_revisao where resolvido_em is null;
