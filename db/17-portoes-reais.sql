-- SHAAR · alinhar os portões com quem realmente usa cada aplicação
--
-- A fronteira vai passar a valer. Antes disso, a lista de portões do hub tem
-- de refletir a realidade — hoje não reflete: quase toda a gente tem apenas o
-- TETELESTAI aberto, porque foi assim que se semeou quando o Quadro só
-- mostrava e não governava.
--
-- Fechar a fronteira sobre essa lista tirava o acesso a quem trabalha.
--
-- A realidade não precisa de ser inventada: cada aplicação já guarda, na sua
-- própria tabela, quem autorizou. Essas tabelas nunca foram tocadas — o hub
-- apenas deixou de as ler quando passou a ter lista própria. Agora servem de
-- fonte para a semear.
--
-- Isto NÃO concede nada de novo. Copia para o hub o que cada aplicação já
-- tinha concedido por conta própria.

with concessoes as (
  -- TETELESTAI: ter perfil activo e o acesso a plataforma-mae
  select u.id as user_id, 'TETELESTAI'::text as app_code
    from public.users u
    join public.profiles p on p.id = u.profile_id and p.active

  union
  -- MANNA: RBAC central, modulo MANNA
  select distinct u.id, 'MANNA'
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions pe on pe.id = pp.permission_id
   where pe.active and pe.module = 'MANNA'

  union
  -- FAITH: RBAC central, modulo 'oportunidades'
  select distinct u.id, 'FAITH'
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions pe on pe.id = pp.permission_id
   where pe.active and pe.module = 'oportunidades'

  union
  select distinct j.user_id, 'JIREH'    from public.jireh_user_permissions j
  union
  select distinct t.user_id, 'TIKKUN'   from public.tikkun_user_roles t
  union
  select distinct b.user_id, 'BNEI'     from public.bnei_user_roles b
  union
  select distinct m.user_id, 'MERKAVAH' from public.merkavah_memberships m where m.active
  union
  select distinct s.user_id, 'SPHRAGIS' from public.sphragis_perfis_assinatura s
)
insert into public.shaar_gate_access (user_id, app_code)
select c.user_id, c.app_code
  from concessoes c
  join public.users u      on u.id = c.user_id and u.active and not u.blocked
  join public.shaar_apps a on a.code = c.app_code and a.active
on conflict (user_id, app_code) do nothing;

-- o super administrador entra em tudo: e quem abre e fecha
insert into public.shaar_gate_access (user_id, app_code)
select u.id, a.code
  from public.users u
  join public.profiles p on p.id = u.profile_id and p.level >= 100
  cross join public.shaar_apps a
 where u.active and not u.blocked and a.active
on conflict (user_id, app_code) do nothing;

-- deixar rasto de que isto aconteceu, e de quantos portoes
insert into public.shaar_auditoria (evento, resultado, detalhe)
select 'SINCRONIZACAO', 'sucesso',
       jsonb_build_object(
         'acao', 'semear portoes a partir das bases das aplicacoes',
         'total', (select count(*) from public.shaar_gate_access));
