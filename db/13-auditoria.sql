-- SHAAR · auditoria central
--
-- Fecha o achado V6. Existiam nove tabelas de auditoria, uma por aplicação, e
-- nenhuma registava o que mais interessa a uma investigação: o acesso NEGADO,
-- o token inválido, a tentativa de manipulação. Quem consegue entrar deixa
-- rasto; quem tenta e falha, não deixava nenhum.
--
-- Esta tabela não substitui as nove: elas continuam a registar o que acontece
-- DENTRO de cada aplicação. Esta regista o que acontece NA PORTA.

create table if not exists public.shaar_auditoria (
  id           bigint generated always as identity primary key,
  quando       timestamptz not null default now(),
  evento       text        not null,
  resultado    text        not null default 'sucesso',   -- sucesso | negado | erro
  user_id      bigint      references public.users(id) on delete set null,
  email        text,                                     -- guardado a parte: o utilizador pode nem existir
  app_code     text,
  ip           inet,
  agente       text,
  detalhe      jsonb       not null default '{}'::jsonb,
  constraint shaar_auditoria_evento_check check (evento in (
    'LOGIN','LOGOUT','ACESSO','NEGATIVA','PORTAO_ABERTO','PORTAO_FECHADO',
    'PORTAO_EM_MASSA','ALTERACAO_PERFIL','ALTERACAO_PERMISSAO','SINCRONIZACAO',
    'TOKEN_INVALIDO','TOKEN_EXPIRADO','TENTATIVA_SUSPEITA'
  )),
  constraint shaar_auditoria_resultado_check check (resultado in ('sucesso','negado','erro'))
);

comment on table public.shaar_auditoria is
  'Registo central do que acontece na porta do ecossistema. Inclui o que as '
  'auditorias por aplicacao nao capturavam: negativa de acesso e token invalido.';

create index if not exists shaar_auditoria_quando  on public.shaar_auditoria (quando desc);
create index if not exists shaar_auditoria_pessoa  on public.shaar_auditoria (user_id, quando desc);
create index if not exists shaar_auditoria_evento  on public.shaar_auditoria (evento, quando desc);
create index if not exists shaar_auditoria_negadas on public.shaar_auditoria (quando desc)
  where resultado = 'negado';

alter table public.shaar_auditoria enable row level security;
-- ninguem escreve nem le direto: so pelas funcoes abaixo
revoke all on table public.shaar_auditoria from public, anon, authenticated;

-- ------------------------------------------------------------------
-- Registar. Nunca falha: auditoria que derruba a operacao auditada e
-- pior do que auditoria nenhuma, porque cria um modo de negacao de servico.
-- ------------------------------------------------------------------
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
  v_uid   bigint;
  v_email text;
  v_ip    inet;
  v_ag    text;
  v_hdr   jsonb;
begin
  begin
    v_uid := coalesce(p_user_id, public.shaar_usuario_atual());

    v_email := coalesce(
      p_email,
      nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'email', ''),
      (select u.email from public.users u where u.id = v_uid)
    );

    -- cabecalhos que o PostgREST expoe; ausentes fora de uma requisicao HTTP
    v_hdr := nullif(current_setting('request.headers', true), '')::jsonb;
    v_ip  := nullif(split_part(coalesce(v_hdr ->> 'x-forwarded-for', ''), ',', 1), '')::inet;
    v_ag  := left(coalesce(v_hdr ->> 'user-agent', ''), 400);

    insert into public.shaar_auditoria
           (evento, resultado, user_id, email, app_code, ip, agente, detalhe)
    values (p_evento, p_resultado, v_uid, lower(v_email), p_app_code,
            v_ip, nullif(v_ag, ''), coalesce(p_detalhe, '{}'::jsonb));
  exception when others then
    -- engolir de proposito: ver o comentario acima
    null;
  end;
end;
$$;

comment on function public.shaar_registrar is
  'Regista um evento na auditoria central. Nunca levanta excecao: auditoria que '
  'derruba a operacao auditada seria um modo de negacao de servico.';

revoke all on function public.shaar_registrar(text,text,text,jsonb,text,bigint) from public;
grant execute on function public.shaar_registrar(text,text,text,jsonb,text,bigint) to authenticated;

-- ------------------------------------------------------------------
-- Ler. Restrito ao super administrador, e a leitura tambem fica registada.
-- ------------------------------------------------------------------
create or replace function public.shaar_ver_auditoria(
  p_desde timestamptz default now() - interval '7 days',
  p_evento text default null,
  p_limite int default 500
) returns table (
  quando timestamptz, evento text, resultado text,
  nome text, email text, app_code text, ip inet, detalhe jsonb
)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
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

-- ------------------------------------------------------------------
-- Ligar as operacoes existentes a auditoria
-- ------------------------------------------------------------------

-- Entrada no hub: o que a pessoa recebeu, e a negativa quando nao e reconhecida
create or replace function public.shaar_minhas_apps()
returns setof public.shaar_user_apps
-- VOLATILE de proposito: esta funcao audita, e funcao stable nao escreve —
-- o PostgREST corre-a em transacao de leitura e o INSERT falha em silencio.
language plpgsql volatile security definer set search_path = public as $$
declare v_uid bigint; v_n int;
begin
  v_uid := public.shaar_usuario_atual();

  if v_uid is null then
    -- autenticou no Entra mas nao existe no cadastro: e uma negativa, e ate hoje
    -- passava despercebida
    perform public.shaar_registrar('NEGATIVA', 'negado', null,
      jsonb_build_object('motivo', 'identidade autenticada sem cadastro corporativo'));
    return;
  end if;

  return query
    select * from public.shaar_user_apps
     where user_id = v_uid and app_released
     order by sort_order;
  get diagnostics v_n = row_count;

  perform public.shaar_registrar('ACESSO',
    case when v_n = 0 then 'negado' else 'sucesso' end, null,
    jsonb_build_object('portoes', v_n));
end;
$$;

revoke all on function public.shaar_minhas_apps() from public;
grant execute on function public.shaar_minhas_apps() to authenticated;

-- Abrir portao
create or replace function public.shaar_abrir_portao(p_user_id bigint, p_app_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_eu bigint;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('acao','abrir_portao','alvo',p_user_id));
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

  perform public.shaar_registrar('PORTAO_ABERTO', 'sucesso', p_app_code,
    jsonb_build_object('alvo', p_user_id));
  return true;
end;
$$;

-- Fechar portao
create or replace function public.shaar_fechar_portao(p_user_id bigint, p_app_code text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_eu bigint;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('acao','fechar_portao','alvo',p_user_id));
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  v_eu := public.shaar_usuario_atual();
  if p_user_id = v_eu then
    raise exception 'Voce nao pode fechar o proprio portao.' using errcode = '42501';
  end if;
  delete from public.shaar_gate_access
   where user_id = p_user_id and app_code = p_app_code;

  perform public.shaar_registrar('PORTAO_FECHADO', 'sucesso', p_app_code,
    jsonb_build_object('alvo', p_user_id));
  return true;
end;
$$;

-- Em massa
create or replace function public.shaar_portao_em_massa(
  p_app_code text, p_user_ids bigint[], p_abrir boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_eu bigint; v_mexi int;
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('acao','portao_em_massa','pedidas',cardinality(p_user_ids)));
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.shaar_apps a where a.code = p_app_code and a.active) then
    raise exception 'Aplicacao inexistente no catalogo.' using errcode = '22023';
  end if;
  if p_user_ids is null or cardinality(p_user_ids) = 0 then
    raise exception 'Nenhuma pessoa informada.' using errcode = '22023';
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
     where app_code = p_app_code
       and user_id = any (p_user_ids)
       and user_id is distinct from v_eu;
    get diagnostics v_mexi = row_count;
  end if;

  perform public.shaar_registrar('PORTAO_EM_MASSA', 'sucesso', p_app_code,
    jsonb_build_object('abriu', p_abrir, 'pedidas', cardinality(p_user_ids), 'mudaram', v_mexi));

  return jsonb_build_object('app', p_app_code, 'abriu', p_abrir,
    'pedidas', cardinality(p_user_ids), 'mudaram', v_mexi);
end;
$$;

-- Quadro: quem tentou ver sem ser super administrador fica registado
create or replace function public.shaar_quadro()
returns table (
  user_id bigint, full_name text, email varchar, user_kind varchar,
  profile_name text, app_code text, app_name text, app_released boolean,
  posto int, cargo text, area text
)
-- VOLATILE pelo mesmo motivo: regista a negativa de quem tenta ver o Quadro.
language plpgsql volatile security definer set search_path = public as $$
begin
  if coalesce(public.shaar_meu_nivel(), 0) < 100 then
    perform public.shaar_registrar('NEGATIVA', 'negado', null,
      jsonb_build_object('acao','ver_quadro'));
    raise exception 'Acesso restrito ao super administrador.' using errcode = '42501';
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
-- Alteracao de perfil e de permissao, directamente na origem
-- ------------------------------------------------------------------
create or replace function public.shaar_auditar_users() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.profile_id is distinct from old.profile_id then
    perform public.shaar_registrar('ALTERACAO_PERFIL', 'sucesso', null,
      jsonb_build_object('alvo', new.id, 'de', old.profile_id, 'para', new.profile_id));
  end if;
  if new.active is distinct from old.active or new.blocked is distinct from old.blocked then
    perform public.shaar_registrar('ALTERACAO_PERMISSAO', 'sucesso', null,
      jsonb_build_object('alvo', new.id,
        'active', jsonb_build_array(old.active, new.active),
        'blocked', jsonb_build_array(old.blocked, new.blocked)));
  end if;
  return new;
end;
$$;

drop trigger if exists shaar_auditar_users on public.users;
create trigger shaar_auditar_users
  after update of profile_id, active, blocked on public.users
  for each row execute function public.shaar_auditar_users();
