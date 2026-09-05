-- SHAAR · liberação por aplicação
--
-- O catálogo passa a ter um estado de liberação. Aplicação não liberada some
-- do hub para todo mundo, EXCETO para o super administrador (perfil nível 100),
-- que continua enxergando tudo — é ele quem libera.
--
-- Isto NÃO altera a autorização que cada aplicação guarda na sua própria tabela.
-- Quem tinha acesso ao TIKKUN continua tendo, do ponto de vista do TIKKUN; o que
-- muda é o portão deixar de aparecer no SHAAR. Liberar de volta é um UPDATE.

alter table public.shaar_apps
  add column if not exists released boolean not null default false;

comment on column public.shaar_apps.released is
  'Aplicacao liberada no hub. Nao liberada aparece apenas para o super administrador.';

-- estado pedido: só o TETELESTAI liberado
update public.shaar_apps set released = (code = 'TETELESTAI'), updated_at = now();

-- a view expõe o estado; quem filtra é shaar_minhas_apps()
drop view if exists public.shaar_user_apps cascade;
create view public.shaar_user_apps as
with concessoes as (
  select u.id as user_id, 'TETELESTAI'::text as app_code, p.name::text as role, 'perfil'::text as fonte
    from public.users u join public.profiles p on p.id = u.profile_id and p.active
  union all
  select distinct u.id, 'MANNA', 'Conforme perfil', 'rbac'
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions pe on pe.id = pp.permission_id
   where pe.active and pe.module = 'MANNA'
  union all
  select distinct u.id, 'FAITH', 'Conforme perfil', 'rbac'
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions pe on pe.id = pp.permission_id
   where pe.active and pe.module = 'oportunidades'
  union all
  select distinct j.user_id, 'JIREH', 'Conforme concessão', 'tabela' from public.jireh_user_permissions j
  union all
  select t.user_id, 'TIKKUN', t.role::text, 'tabela' from public.tikkun_user_roles t
  union all
  select b.user_id, 'BNEI', b.role::text, 'tabela' from public.bnei_user_roles b
  union all
  select m.user_id, 'MERKAVAH', m.role::text, 'tabela' from public.merkavah_memberships m where m.active
  union all
  select s.user_id, 'SPHRAGIS', 'Signatário(a)', 'tabela' from public.sphragis_perfis_assinatura s
)
select
  u.id as user_id, u.email, u.full_name, u.user_kind,
  pr.name::text as profile_name, pr.level as profile_level,
  a.code as app_code, a.name as app_name, a.description as app_description,
  a.url as app_url, a.sort_order, a.released as app_released,
  min(c.role) as role, min(c.fonte) as fonte
from public.users u
join concessoes c on c.user_id = u.id
join public.shaar_apps a on a.code = c.app_code and a.active
left join public.profiles pr on pr.id = u.profile_id
where u.active and not u.blocked
group by u.id, u.email, u.full_name, u.user_kind, pr.name, pr.level,
         a.code, a.name, a.description, a.url, a.sort_order, a.released;

-- o hub entrega só o que está liberado; o super administrador vê tudo
create or replace function public.shaar_minhas_apps()
returns setof public.shaar_user_apps
language sql stable security definer set search_path = public as $$
  select *
    from public.shaar_user_apps
   where user_id = public.shaar_usuario_atual()
     and (app_released or coalesce(public.shaar_meu_nivel(), 0) >= 100)
   order by sort_order;
$$;

comment on function public.shaar_minhas_apps is
  'Aplicacoes que o usuario pode abrir no hub: autorizadas na base do TETELESTAI '
  'E liberadas no catalogo. O super administrador enxerga tambem as nao liberadas.';

revoke all on function public.shaar_minhas_apps() from public;
grant execute on function public.shaar_minhas_apps() to authenticated;

-- o Quadro continua mostrando o quadro inteiro, liberado ou não
create or replace function public.shaar_quadro()
returns table (
  user_id bigint, full_name text, email varchar, user_kind varchar,
  profile_name text, app_code text, app_name text, role text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  return query
    select u.id, u.full_name, u.email, u.user_kind, pr.name::text,
           v.app_code, v.app_name, v.role
      from public.users u
      left join public.profiles pr on pr.id = u.profile_id
      left join public.shaar_user_apps v on v.user_id = u.id
     where u.active and not u.blocked
     order by pr.level desc nulls last, u.full_name;
end;
$$;

revoke all on function public.shaar_quadro() from public;
grant execute on function public.shaar_quadro() to authenticated;
