-- SHAAR · a negativa deixa de ser exceção, para poder ser registada
--
-- Problema: a função registava a negativa e logo a seguir levantava a exceção
-- que negava o acesso. A exceção desfazia a transação — e levava o registo
-- junto. Os eventos que mais interessam a uma investigação eram justamente os
-- únicos que nunca ficavam gravados.
--
-- Tentei resolver com dblink, para a auditoria ter transação própria. Não dá
-- sem embutir a senha do Postgres na função, porque `postgres` não é
-- superusuário nesta instalação. E dar a função ao superusuário resolveria o
-- registo criando um problema pior: uma função SECURITY DEFINER de
-- superusuário, chamável por qualquer autenticado, é uma superfície de
-- escalonamento de privilégio.
--
-- Solução: a negativa deixa de ser exceção. Devolve resultado vazio ou falso,
-- e o registo commita com a transação normal.
--
-- Ganho lateral: resultado vazio é melhor do que erro explícito. Erro confirma
-- que a função existe e que a pessoa não tem direito; vazio não confirma nada.

drop extension if exists dblink;

-- shaar_registrar volta a escrever directamente, sem ligacao de volta
create or replace function public.shaar_registrar(
  p_evento    text,
  p_resultado text default 'sucesso',
  p_app_code  text default null,
  p_detalhe   jsonb default '{}'::jsonb,
  p_email     text default null,
  p_user_id   bigint default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid bigint; v_email text; v_ip inet; v_ag text; v_hdr jsonb;
begin
  begin
    v_uid := coalesce(p_user_id, public.shaar_usuario_atual());
    v_email := coalesce(
      p_email,
      nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', ''),
      (select u.email from public.users u where u.id = v_uid));
    v_hdr := nullif(current_setting('request.headers', true), '')::jsonb;
    v_ip  := nullif(split_part(coalesce(v_hdr ->> 'x-forwarded-for', ''), ',', 1), '')::inet;
    v_ag  := nullif(left(coalesce(v_hdr ->> 'user-agent', ''), 400), '');

    insert into public.shaar_auditoria
           (evento, resultado, user_id, email, app_code, ip, agente, detalhe)
    values (p_evento, p_resultado, v_uid, lower(v_email), p_app_code,
            v_ip, v_ag, coalesce(p_detalhe, '{}'::jsonb));
  exception when others then
    null;   -- auditoria nunca derruba a operacao auditada
  end;
end;
$$;

revoke all on function public.shaar_registrar(text,text,text,jsonb,text,bigint) from public;
grant execute on function public.shaar_registrar(text,text,text,jsonb,text,bigint) to authenticated;

-- ------------------------------------------------------------------
-- Quadro: sem direito, devolve vazio e regista
-- ------------------------------------------------------------------
create or replace function public.shaar_quadro()
returns table (
  user_id bigint, full_name text, email varchar, user_kind varchar,
  profile_name text, app_code text, app_name text, app_released boolean,
  posto int, cargo text, area text
)
language plpgsql volatile security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', null,
      jsonb_build_object('acao', 'ver_quadro'));
    return;                      -- vazio, sem confirmar nada a quem tentou
  end if;

  return query
    with pessoa as (
      select u.id, u.full_name, u.email, u.user_kind,
             pr.name::text as profile_name,
             po.name::text as cargo,
             coalesce(nullif(btrim(dep.nome), ''), nullif(btrim(dir.department), '')) as area,
             public.shaar_posto(pr.level, po.nivel_organizacional) as posto
        from public.users u
        left join public.profiles    pr  on pr.id  = u.profile_id
        left join public.positions   po  on po.id  = u.position_id
        left join public.org_departments dep on dep.id = u.department_id
        left join public.shaar_directory dir on dir.user_id = u.id and dir.presente
       where u.active and not u.blocked
    )
    select p.id, p.full_name, p.email, p.user_kind, p.profile_name,
           v.app_code, v.app_name, v.app_released,
           p.posto, p.cargo, p.area
      from pessoa p
      left join public.shaar_user_apps v on v.user_id = p.id
     order by p.posto, p.area nulls last, p.cargo nulls last, p.full_name, v.sort_order;
end;
$$;

revoke all on function public.shaar_quadro() from public;
grant execute on function public.shaar_quadro() to authenticated;

-- ------------------------------------------------------------------
-- Abrir e fechar portao: devolvem falso em vez de levantar
-- ------------------------------------------------------------------
create or replace function public.shaar_abrir_portao(p_user_id bigint, p_app_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_eu bigint;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('acao','abrir_portao','alvo',p_user_id));
    return false;
  end if;
  if not exists (select 1 from public.users u where u.id = p_user_id and u.active and not u.blocked)
     or not exists (select 1 from public.shaar_apps a where a.code = p_app_code and a.active) then
    perform public.shaar_registrar('NEGATIVA', 'erro', p_app_code,
      jsonb_build_object('acao','abrir_portao','alvo',p_user_id,'motivo','alvo ou aplicacao invalidos'));
    return false;
  end if;

  v_eu := public.shaar_usuario_atual();
  insert into public.shaar_gate_access (user_id, app_code, granted_by)
  values (p_user_id, p_app_code, v_eu)
      on conflict (user_id, app_code) do nothing;

  perform public.shaar_registrar('PORTAO_ABERTO', 'sucesso', p_app_code,
    jsonb_build_object('alvo', p_user_id));
  return true;
end;
$$;

create or replace function public.shaar_fechar_portao(p_user_id bigint, p_app_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_eu bigint;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('acao','fechar_portao','alvo',p_user_id));
    return false;
  end if;
  v_eu := public.shaar_usuario_atual();
  if p_user_id = v_eu then
    perform public.shaar_registrar('NEGATIVA', 'erro', p_app_code,
      jsonb_build_object('acao','fechar_portao','motivo','o proprio portao'));
    return false;
  end if;

  delete from public.shaar_gate_access
   where user_id = p_user_id and app_code = p_app_code;

  perform public.shaar_registrar('PORTAO_FECHADO', 'sucesso', p_app_code,
    jsonb_build_object('alvo', p_user_id));
  return true;
end;
$$;

-- ------------------------------------------------------------------
-- Em massa: devolve o resultado com a marca de negativa
-- ------------------------------------------------------------------
create or replace function public.shaar_portao_em_massa(
  p_app_code text, p_user_ids bigint[], p_abrir boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_eu bigint; v_mexi int;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('acao','portao_em_massa','pedidas',coalesce(cardinality(p_user_ids),0)));
    return jsonb_build_object('negado', true);
  end if;
  if not exists (select 1 from public.shaar_apps a where a.code = p_app_code and a.active)
     or p_user_ids is null or cardinality(p_user_ids) = 0 then
    return jsonb_build_object('negado', true, 'motivo', 'aplicacao ou lista invalidas');
  end if;

  v_eu := public.shaar_usuario_atual();

  if p_abrir then
    insert into public.shaar_gate_access (user_id, app_code, granted_by)
    select u.id, p_app_code, v_eu
      from public.users u
     where u.id = any (p_user_ids) and u.active and not u.blocked
        on conflict (user_id, app_code) do nothing;
    get diagnostics v_mexi = row_count;
  else
    delete from public.shaar_gate_access
     where app_code = p_app_code and user_id = any (p_user_ids)
       and user_id is distinct from v_eu;
    get diagnostics v_mexi = row_count;
  end if;

  perform public.shaar_registrar('PORTAO_EM_MASSA', 'sucesso', p_app_code,
    jsonb_build_object('abriu', p_abrir, 'pedidas', cardinality(p_user_ids), 'mudaram', v_mexi));

  return jsonb_build_object('app', p_app_code, 'abriu', p_abrir,
    'pedidas', cardinality(p_user_ids), 'mudaram', v_mexi, 'negado', false);
end;
$$;

-- ------------------------------------------------------------------
-- Ver a auditoria: mesma regra
-- ------------------------------------------------------------------
create or replace function public.shaar_ver_auditoria(
  p_desde timestamptz default now() - interval '7 days',
  p_evento text default null,
  p_limite int default 500
) returns table (
  quando timestamptz, evento text, resultado text,
  nome text, email text, app_code text, ip inet, detalhe jsonb
)
language plpgsql volatile security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', null,
      jsonb_build_object('acao', 'ver_auditoria'));
    return;
  end if;
  return query
    select a.quando, a.evento, a.resultado,
           u.full_name, a.email, a.app_code, a.ip, a.detalhe
      from public.shaar_auditoria a
      left join public.users u on u.id = a.user_id
     where a.quando >= p_desde
       and (p_evento is null or a.evento = p_evento)
     order by a.quando desc
     limit least(greatest(p_limite, 1), 5000);
end;
$$;

revoke all on function public.shaar_ver_auditoria(timestamptz,text,int) from public;
grant execute on function public.shaar_ver_auditoria(timestamptz,text,int) to authenticated;
