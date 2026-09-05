-- SHAAR · a lista de quem passa é do hub
--
-- Até aqui o hub deduzia quem entrava lendo a autorização que cada aplicação
-- guarda na sua própria tabela. Isso estava errado por dois motivos:
--
--   1. o hub passava a depender das regras internas de cada aplicação, que
--      não são assunto dele;
--   2. não havia como fechar um portão sem mexer na base da aplicação.
--
-- A partir de agora o SHAAR tem a sua própria lista: shaar_gate_access.
-- Uma linha significa exatamente uma coisa — esta pessoa atravessa este
-- portão. Nada sobre papel, perfil ou permissão: isso continua sendo
-- decidido dentro de cada aplicação, pelas regras dela.
--
-- As autorizações que já existem em jireh_user_permissions, tikkun_user_roles,
-- bnei_user_roles, merkavah_memberships e sphragis_perfis_assinatura NÃO são
-- tocadas. O hub simplesmente deixa de lê-las.

create table if not exists public.shaar_gate_access (
  user_id    bigint  not null references public.users(id)      on delete cascade,
  app_code   text    not null references public.shaar_apps(code) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by bigint  references public.users(id),
  primary key (user_id, app_code)
);

comment on table public.shaar_gate_access is
  'Quem atravessa qual portao. Lista propria do SHAAR — nao reflete nem altera '
  'a autorizacao interna de nenhuma aplicacao.';

create index if not exists shaar_gate_access_app on public.shaar_gate_access(app_code);

alter table public.shaar_gate_access enable row level security;
-- ninguem fala com a tabela direto; so pelas funcoes abaixo
revoke all on table public.shaar_gate_access from public, anon, authenticated;

-- ------------------------------------------------------------------
-- Estado inicial pedido: todos entram no TETELESTAI e em mais nada.
-- O super administrador entra em tudo, porque e quem abre os portoes.
-- ------------------------------------------------------------------
insert into public.shaar_gate_access (user_id, app_code)
select u.id, 'TETELESTAI'
  from public.users u
 where u.active and not u.blocked
on conflict do nothing;

insert into public.shaar_gate_access (user_id, app_code)
select u.id, a.code
  from public.users u
  join public.profiles p on p.id = u.profile_id and p.level >= 100
  cross join public.shaar_apps a
 where u.active and not u.blocked and a.active
on conflict do nothing;

-- As aplicacoes ficam todas habilitadas no catalogo. O que decide quem entra
-- e a lista de portoes, pessoa a pessoa — nao um interruptor por aplicacao.
-- A coluna continua existindo como chave geral, para tirar uma aplicacao do ar
-- no hub (manutencao, desligamento), mas hoje esta ligada para todas.
update public.shaar_apps set released = true, updated_at = now() where not released;

-- ------------------------------------------------------------------
-- Leitura
-- ------------------------------------------------------------------
drop function if exists public.shaar_minhas_apps();
drop view if exists public.shaar_user_apps cascade;

create view public.shaar_user_apps as
select
  u.id            as user_id,
  u.email,
  u.full_name,
  u.user_kind,
  pr.name::text   as profile_name,
  pr.level        as profile_level,
  a.code          as app_code,
  a.name          as app_name,
  a.description   as app_description,
  a.url           as app_url,
  a.sort_order,
  a.released      as app_released,
  g.granted_at,
  g.granted_by
from public.shaar_gate_access g
join public.users u      on u.id = g.user_id and u.active and not u.blocked
join public.shaar_apps a on a.code = g.app_code and a.active
left join public.profiles pr on pr.id = u.profile_id;

comment on view public.shaar_user_apps is
  'Portoes abertos por pessoa. Uma linha = esta pessoa atravessa este portao.';

create function public.shaar_minhas_apps()
returns setof public.shaar_user_apps
language sql stable security definer set search_path = public as $$
  select *
    from public.shaar_user_apps
   where user_id = public.shaar_usuario_atual()
     and app_released
   order by sort_order;
$$;

comment on function public.shaar_minhas_apps is
  'Aplicacoes que a pessoa autenticada abre pelo SHAAR. O que nao esta na lista '
  'nao aparece — nem para pedir acesso.';

revoke all on function public.shaar_minhas_apps() from public;
grant execute on function public.shaar_minhas_apps() to authenticated;

-- Quadro: pessoas x portoes, para o super administrador.
drop function if exists public.shaar_quadro();
create function public.shaar_quadro()
returns table (
  user_id bigint, full_name text, email varchar, user_kind varchar,
  profile_name text, app_code text, app_name text, app_released boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  return query
    select u.id, u.full_name, u.email, u.user_kind, pr.name::text,
           v.app_code, v.app_name, v.app_released
      from public.users u
      left join public.profiles pr on pr.id = u.profile_id
      left join public.shaar_user_apps v on v.user_id = u.id
     where u.active and not u.blocked
     order by pr.level desc nulls last, u.full_name;
end;
$$;

revoke all on function public.shaar_quadro() from public;
grant execute on function public.shaar_quadro() to authenticated;

-- ------------------------------------------------------------------
-- Escrita — abrir e fechar portao. So o super administrador.
-- ------------------------------------------------------------------
create or replace function public.shaar_abrir_portao(p_user_id bigint, p_app_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_eu bigint;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.users u where u.id = p_user_id and u.active and not u.blocked) then
    raise exception 'Pessoa inexistente ou inativa.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.shaar_apps a where a.code = p_app_code and a.active) then
    raise exception 'Aplicacao inexistente no catalogo.' using errcode = '22023';
  end if;
  v_eu := public.shaar_usuario_atual();
  insert into public.shaar_gate_access (user_id, app_code, granted_by)
  values (p_user_id, p_app_code, v_eu)
  on conflict (user_id, app_code) do nothing;
  return true;
end;
$$;

create or replace function public.shaar_fechar_portao(p_user_id bigint, p_app_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_eu bigint;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  v_eu := public.shaar_usuario_atual();
  -- guarda contra tranca-se do lado de fora
  if p_user_id = v_eu then
    raise exception 'Voce nao pode fechar o proprio portao.' using errcode = '42501';
  end if;
  delete from public.shaar_gate_access
   where user_id = p_user_id and app_code = p_app_code;
  return true;
end;
$$;

comment on function public.shaar_abrir_portao  is 'Abre um portao para uma pessoa. Nivel 100.';
comment on function public.shaar_fechar_portao is 'Fecha um portao para uma pessoa. Nivel 100.';

revoke all on function public.shaar_abrir_portao(bigint, text)  from public;
revoke all on function public.shaar_fechar_portao(bigint, text) from public;
grant execute on function public.shaar_abrir_portao(bigint, text)  to authenticated;
grant execute on function public.shaar_fechar_portao(bigint, text) to authenticated;
