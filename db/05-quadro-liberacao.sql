-- SHAAR · o Quadro mostra também o estado de liberação
--
-- O super administrador precisa distinguir duas coisas diferentes:
--   quem está autorizado na base de cada aplicação, e
--   qual portão está aberto no hub.
-- Sem isso, um portão aceso num aplicativo desabilitado engana.

drop function if exists public.shaar_quadro();
create function public.shaar_quadro()
returns table (
  user_id bigint, full_name text, email varchar, user_kind varchar,
  profile_name text, app_code text, app_name text, role text, app_released boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  return query
    select u.id, u.full_name, u.email, u.user_kind, pr.name::text,
           v.app_code, v.app_name, v.role, v.app_released
      from public.users u
      left join public.profiles pr on pr.id = u.profile_id
      left join public.shaar_user_apps v on v.user_id = u.id
     where u.active and not u.blocked
     order by pr.level desc nulls last, u.full_name;
end;
$$;

comment on function public.shaar_quadro is
  'Quadro de Acessos: pessoas x portoes, com o estado de liberacao de cada '
  'aplicacao. Restrito ao perfil de nivel 100.';

revoke all on function public.shaar_quadro() from public;
grant execute on function public.shaar_quadro() to authenticated;

-- catálogo completo para o hub montar as colunas, inclusive as desabilitadas
drop function if exists public.shaar_catalogo();
create function public.shaar_catalogo()
returns table (code text, name text, description text, url text, sort_order int, released boolean)
language sql stable security definer set search_path = public as $$
  select a.code, a.name, a.description, a.url, a.sort_order, a.released
    from public.shaar_apps a
   where a.active
     and coalesce(public.shaar_meu_nivel(), 0) >= 100
   order by a.sort_order;
$$;

comment on function public.shaar_catalogo is
  'Catalogo completo das aplicacoes. Restrito ao super administrador — o usuario '
  'comum so conhece o que shaar_minhas_apps() lhe devolve.';

revoke all on function public.shaar_catalogo() from public;
grant execute on function public.shaar_catalogo() to authenticated;
