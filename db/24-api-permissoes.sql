-- =====================================================================
-- Central de Permissionamento — funções de leitura e escrita da API
-- =====================================================================
--
-- As regras que o esquema sozinho não sabe aplicar vivem aqui, e não na
-- função de borda: quem escreve para a base tem de passar por elas, venha de
-- onde vier. Uma regra que só existe no servidor HTTP é uma regra que se
-- contorna assim que alguém chamar a base por outro caminho.
--
-- São quatro, e a terceira é a mais importante de todo o sistema:
--
--   1. quem escreve tem de ter SHAAR/permissao.gerir
--   2. motivo é obrigatório, e não pode ser espaço em branco
--   3. NINGUÉM CONCEDE PERMISSÕES A SI PRÓPRIO
--   4. só se concede o que existe no catálogo daquela aplicação
--
-- Sem a terceira, qualquer conta com acesso à Central é, na prática,
-- administradora de todo o ecossistema: basta dar-se o que lhe falta, e a
-- auditoria regista um acto perfeitamente legítimo. Com ela, elevar
-- privilégio exige duas pessoas e deixa duas assinaturas.
--
-- Nenhuma destas funções levanta excepção numa recusa. Devolvem `ok: false`
-- com o motivo — porque `raise` faz rollback da transacção inteira, incluindo
-- o registo de auditoria da tentativa, e uma recusa que não fica registada é
-- pior do que não ter recusado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- LEITURA — o que a tela precisa para desenhar uma aba
-- ---------------------------------------------------------------------
create or replace function public.shaar_estado_permissoes(p_user_id bigint, p_app text)
returns table (
  code text, name text, description text, grupo text,
  escopo_dimensoes text[], sort_order integer,
  concedida boolean, efeito text, escopo jsonb,
  motivo text, granted_by_nome text, granted_at timestamptz, valido_ate timestamptz
)
language sql stable security definer set search_path = public as $$
  select c.code, c.name, c.description, c.grupo, c.escopo_dimensoes, c.sort_order,
         g.user_id is not null, g.efeito, coalesce(g.escopo, '{}'::jsonb),
         g.motivo, q.full_name, g.granted_at, g.valido_ate
    from public.shaar_permission c
    left join public.shaar_permission_grant g
           on g.app_code = c.app_code and g.code = c.code and g.user_id = p_user_id
    left join public.users q on q.id = g.granted_by
   where c.app_code = p_app
     and c.active
     and (public.shaar_pode('SHAAR','permissao.gerir')
          or public.shaar_pode('SHAAR','permissao.auditar')
          or p_user_id = public.shaar_usuario_atual())
   order by c.grupo, c.sort_order, c.code;
$$;

-- Resumo por aplicação, para as contagens nas abas.
create or replace function public.shaar_resumo_permissoes(p_user_id bigint)
returns table (app_code text, app_name text, tem_portao boolean,
               total integer, concedidas integer, negadas integer, com_escopo integer)
language sql stable security definer set search_path = public as $$
  select a.code, a.name,
         exists (select 1 from public.shaar_gate_access x
                  where x.user_id = p_user_id and x.app_code = a.code),
         (select count(*)::integer from public.shaar_permission c
           where c.app_code = a.code and c.active),
         (select count(*)::integer from public.shaar_permission_grant g
           where g.user_id = p_user_id and g.app_code = a.code and g.efeito = 'permitir'),
         (select count(*)::integer from public.shaar_permission_grant g
           where g.user_id = p_user_id and g.app_code = a.code and g.efeito = 'negar'),
         (select count(*)::integer from public.shaar_permission_grant g
           where g.user_id = p_user_id and g.app_code = a.code and g.escopo <> '{}'::jsonb)
    from public.shaar_apps a
   where a.active or a.code = 'SHAAR'
     and (public.shaar_pode('SHAAR','permissao.gerir')
          or public.shaar_pode('SHAAR','permissao.auditar')
          or p_user_id = public.shaar_usuario_atual())
   order by a.sort_order, a.code;
$$;

-- Recertificação: quem tem esta permissão, e com que alçada.
create or replace function public.shaar_quem_tem(p_app text, p_code text)
returns table (user_id bigint, email text, full_name text, efeito text,
               escopo jsonb, motivo text, granted_at timestamptz, valido_ate timestamptz,
               dias_sem_uso integer)
language sql stable security definer set search_path = public as $$
  select u.id, u.email::text, u.full_name, g.efeito, g.escopo, g.motivo,
         g.granted_at, g.valido_ate,
         case when u.last_seen_at is null then null
              else extract(day from now() - u.last_seen_at)::integer end
    from public.shaar_permission_grant g
    join public.users u on u.id = g.user_id
   where g.app_code = p_app and g.code = p_code
     and (public.shaar_pode('SHAAR','permissao.gerir')
          or public.shaar_pode('SHAAR','permissao.auditar'))
   order by g.efeito, u.full_name;
$$;

create or replace function public.shaar_historico_permissoes(
  p_user_id bigint default null, p_app text default null,
  p_desde timestamptz default now() - interval '90 days', p_limite integer default 500)
returns table (quando timestamptz, acao text, alvo text, app_code text, code text,
               efeito_antes text, efeito_depois text, actor text, motivo text)
language sql stable security definer set search_path = public as $$
  select e.quando, e.acao, u.full_name, e.app_code, e.code,
         e.antes ->> 'efeito', e.depois ->> 'efeito',
         coalesce(e.actor_email, 'sistema'), e.motivo
    from public.shaar_permission_event e
    join public.users u on u.id = e.user_id
   where e.quando >= p_desde
     and (p_user_id is null or e.user_id = p_user_id)
     and (p_app is null or e.app_code = p_app)
     and (public.shaar_pode('SHAAR','permissao.auditar')
          or public.shaar_pode('SHAAR','permissao.gerir'))
   order by e.quando desc
   limit greatest(1, least(p_limite, 5000));
$$;

-- ---------------------------------------------------------------------
-- ESCRITA — o PUT declarativo
-- ---------------------------------------------------------------------
-- Recebe a aba inteira e escreve só o diferencial, numa transacção. Se cada
-- interruptor fosse uma chamada, meia gravação deixaria a pessoa num estado
-- que ninguém pediu, e a auditoria encheria de ruído. É idempotente: repetir
-- não faz mal.
--
-- p_permissoes: [{"code":"x.y","efeito":"permitir","escopo":{...},"valido_ate":"..."}]
-- Ausente da lista = revogada.
create or replace function public.shaar_definir_permissoes(
  p_user_id bigint, p_app text, p_permissoes jsonb, p_motivo text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_actor    bigint := public.shaar_usuario_atual();
  v_motivo   text   := nullif(btrim(coalesce(p_motivo, '')), '');
  v_alteracoes jsonb := '[]'::jsonb;
  v_avisos   jsonb := '[]'::jsonb;
  r          record;
  v_conflito record;
begin
  -- 1. quem escreve tem de poder escrever
  if not public.shaar_pode('SHAAR','permissao.gerir', '{}'::jsonb, v_actor) then
    perform public.shaar_registrar('PERMISSAO_NEGADA','negado', p_app,
      jsonb_build_object('motivo','sem permissao.gerir','alvo', p_user_id));
    return jsonb_build_object('ok', false, 'motivo', 'sem_permissao_para_gerir');
  end if;

  -- 2. motivo obrigatorio
  if v_motivo is null then
    return jsonb_build_object('ok', false, 'motivo', 'motivo_obrigatorio');
  end if;

  -- 3. ninguem se serve a si proprio. A regra mais importante do sistema.
  if v_actor = p_user_id then
    perform public.shaar_registrar('PERMISSAO_NEGADA','negado', p_app,
      jsonb_build_object('motivo','tentativa de alterar as proprias permissoes'));
    return jsonb_build_object('ok', false, 'motivo', 'nao_pode_alterar_as_proprias');
  end if;

  -- 4. sem portao, conceder permissao nao produz efeito nenhum
  if not exists (select 1 from public.shaar_gate_access g
                  where g.user_id = p_user_id and g.app_code = p_app) then
    return jsonb_build_object('ok', false, 'motivo', 'portao_fechado',
      'detalhe', 'abra o portao desta aplicacao antes de conceder permissoes');
  end if;

  -- 5. so se concede o que existe no catalogo
  for r in select x.code from jsonb_to_recordset(coalesce(p_permissoes,'[]'::jsonb))
                  as x(code text, efeito text, escopo jsonb, valido_ate timestamptz)
  loop
    if not exists (select 1 from public.shaar_permission c
                    where c.app_code = p_app and c.code = r.code and c.active) then
      return jsonb_build_object('ok', false, 'motivo', 'permissao_desconhecida',
        'detalhe', r.code);
    end if;
  end loop;

  -- revogar o que saiu da lista
  for r in
    select g.code, g.efeito from public.shaar_permission_grant g
     where g.user_id = p_user_id and g.app_code = p_app
       and g.code not in (select x.code from jsonb_to_recordset(coalesce(p_permissoes,'[]'::jsonb))
                            as x(code text))
  loop
    update public.shaar_permission_grant set motivo = v_motivo
     where user_id = p_user_id and app_code = p_app and code = r.code;
    delete from public.shaar_permission_grant
     where user_id = p_user_id and app_code = p_app and code = r.code;
    v_alteracoes := v_alteracoes || jsonb_build_object(
      'code', r.code, 'de', r.efeito, 'para', null);
  end loop;

  -- inserir ou actualizar o que veio
  for r in select x.* from jsonb_to_recordset(coalesce(p_permissoes,'[]'::jsonb))
                  as x(code text, efeito text, escopo jsonb, valido_ate timestamptz)
  loop
    declare
      v_antes  record;
      v_efeito text  := coalesce(nullif(r.efeito,''), 'permitir');
      v_escopo jsonb := coalesce(r.escopo, '{}'::jsonb);
    begin
      if v_efeito not in ('permitir','negar') then
        return jsonb_build_object('ok', false, 'motivo', 'efeito_invalido', 'detalhe', r.code);
      end if;
      if jsonb_typeof(v_escopo) <> 'object' then
        return jsonb_build_object('ok', false, 'motivo', 'escopo_invalido', 'detalhe', r.code);
      end if;

      select efeito, escopo, valido_ate into v_antes
        from public.shaar_permission_grant
       where user_id = p_user_id and app_code = p_app and code = r.code;

      if v_antes is null then
        insert into public.shaar_permission_grant
          (user_id, app_code, code, efeito, escopo, motivo, granted_by, valido_ate)
        values (p_user_id, p_app, r.code, v_efeito, v_escopo, v_motivo, v_actor, r.valido_ate);
        v_alteracoes := v_alteracoes || jsonb_build_object(
          'code', r.code, 'de', null, 'para', v_efeito, 'escopo', v_escopo);
      elsif v_antes.efeito is distinct from v_efeito
         or v_antes.escopo is distinct from v_escopo
         or v_antes.valido_ate is distinct from r.valido_ate then
        update public.shaar_permission_grant
           set efeito = v_efeito, escopo = v_escopo, motivo = v_motivo,
               granted_by = v_actor, granted_at = now(), valido_ate = r.valido_ate
         where user_id = p_user_id and app_code = p_app and code = r.code;
        v_alteracoes := v_alteracoes || jsonb_build_object(
          'code', r.code, 'de', v_antes.efeito, 'para', v_efeito,
          'escopo_de', v_antes.escopo, 'escopo_para', v_escopo);
      end if;
    end;
  end loop;

  -- conflitos de segregacao abertos por esta gravacao
  for v_conflito in
    select detalhe ->> 'conflito' as texto, detalhe ->> 'par' as par
      from public.shaar_permission_revisao
     where user_id = p_user_id and gatilho = 'conflito' and resolvido_em is null
       and criado_em > now() - interval '5 seconds'
  loop
    v_avisos := v_avisos || jsonb_build_object(
      'tipo','conflito_segregacao','detalhe', v_conflito.texto, 'par', v_conflito.par);
  end loop;

  perform public.shaar_registrar('PERMISSAO_ALTERADA','sucesso', p_app,
    jsonb_build_object('alvo', p_user_id, 'alteracoes', jsonb_array_length(v_alteracoes),
                       'motivo', v_motivo));

  return jsonb_build_object(
    'ok', true, 'app', p_app,
    'versao', public.shaar_versao_permissoes(p_app, p_user_id),
    'alteracoes', v_alteracoes,
    'avisos', v_avisos);
end $$;

-- ---------------------------------------------------------------------
-- ACESSO DE EMERGÊNCIA
-- ---------------------------------------------------------------------
-- Às três da manhã alguém vai precisar de uma permissão que não tem. Se não
-- houver caminho previsto, o caminho será partilhar credenciais ou entrar na
-- base com service_role — e aí não há auditoria nenhuma. Este caminho tem
-- prazo curto obrigatório, motivo, e revisão no dia seguinte. Pressa não dá
-- excepção: um conflito de bloquear continua a bloquear.
create or replace function public.shaar_conceder_emergencia(
  p_user_id bigint, p_app text, p_code text, p_horas numeric, p_motivo text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_actor  bigint := public.shaar_usuario_atual();
  v_motivo text   := nullif(btrim(coalesce(p_motivo,'')), '');
  v_horas  numeric := least(greatest(coalesce(p_horas, 4), 0.25), 4);
begin
  if not public.shaar_pode('SHAAR','permissao.gerir','{}'::jsonb, v_actor) then
    return jsonb_build_object('ok', false, 'motivo', 'sem_permissao_para_gerir');
  end if;
  if v_motivo is null then
    return jsonb_build_object('ok', false, 'motivo', 'motivo_obrigatorio');
  end if;
  if v_actor = p_user_id then
    perform public.shaar_registrar('PERMISSAO_NEGADA','negado', p_app,
      jsonb_build_object('motivo','emergencia para si proprio'));
    return jsonb_build_object('ok', false, 'motivo', 'nao_pode_alterar_as_proprias');
  end if;

  insert into public.shaar_permission_grant
    (user_id, app_code, code, efeito, escopo, motivo, granted_by, valido_ate)
  values (p_user_id, p_app, p_code, 'permitir', '{}'::jsonb,
          'EMERGENCIA: ' || v_motivo, v_actor, now() + (v_horas || ' hours')::interval)
  on conflict (user_id, app_code, code) do update
     set valido_ate = now() + (v_horas || ' hours')::interval,
         motivo = 'EMERGENCIA: ' || v_motivo, granted_by = v_actor, granted_at = now();

  insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
  values (p_user_id, p_app, 'emergencia',
          jsonb_build_object('code', p_code, 'motivo', v_motivo, 'horas', v_horas));

  perform public.shaar_registrar('PERMISSAO_EMERGENCIA','sucesso', p_app,
    jsonb_build_object('alvo', p_user_id, 'code', p_code, 'horas', v_horas, 'motivo', v_motivo));

  return jsonb_build_object('ok', true, 'expira_em', now() + (v_horas || ' hours')::interval);
end $$;

-- ---------------------------------------------------------------------
-- O BILHETE passa a levar as permissões
-- ---------------------------------------------------------------------
-- `perms` é um objecto código -> escopo. Escopo vazio significa sem limite.
-- `pv` é a versão: com ela, a aplicação sabe quando o que tem na mão ficou
-- velho, sem ter de perguntar a cada clique.
--
-- Isto decide o que APARECE, não o que ACONTECE. Quem alterar a lista no
-- navegador vê o botão, e ao carregar nele leva um "não" da base de dados.
create or replace function public.shaar_autorizar_bilhete(p_app_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid   bigint;
  v_app   record;
  v_p     record;
  v_abre  boolean;
  v_perms jsonb;
begin
  v_uid := public.shaar_usuario_atual();

  if v_uid is null then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('motivo', 'identidade autenticada sem cadastro corporativo'));
    return jsonb_build_object('permitido', false, 'motivo', 'sem_cadastro');
  end if;

  select a.code, a.name, a.url, a.released into v_app
    from public.shaar_apps a where a.code = p_app_code and a.active;

  if not found then
    perform public.shaar_registrar('NEGATIVA', 'erro', p_app_code,
      jsonb_build_object('motivo', 'aplicacao inexistente'));
    return jsonb_build_object('permitido', false, 'motivo', 'app_desconhecida');
  end if;

  v_abre := v_app.released and exists (
    select 1 from public.shaar_gate_access g
     where g.user_id = v_uid and g.app_code = v_app.code);

  if not v_abre then
    perform public.shaar_registrar('NEGATIVA', 'negado', v_app.code,
      jsonb_build_object('motivo', case when v_app.released
                                        then 'portao fechado para esta pessoa'
                                        else 'aplicacao fora de vigor' end));
    return jsonb_build_object('permitido', false, 'motivo', 'sem_portao');
  end if;

  select u.id, u.email, u.full_name, pr.level as nivel, pr.name as perfil,
         po.name as cargo
    into v_p
    from public.users u
    left join public.profiles  pr on pr.id = u.profile_id
    left join public.positions po on po.id = u.position_id
   where u.id = v_uid and u.active and not u.blocked;

  if not found then
    perform public.shaar_registrar('NEGATIVA', 'negado', v_app.code,
      jsonb_build_object('motivo', 'pessoa inativa ou bloqueada'));
    return jsonb_build_object('permitido', false, 'motivo', 'inativo');
  end if;

  -- as permissoes efectivas desta pessoa nesta aplicacao, com escopo
  select coalesce(jsonb_object_agg(g.code, g.escopo), '{}'::jsonb) into v_perms
    from public.shaar_permission_grant g
   where g.user_id = v_uid and g.app_code = v_app.code
     and g.efeito = 'permitir'
     and g.valido_de <= now()
     and (g.valido_ate is null or g.valido_ate > now())
     and not exists (select 1 from public.shaar_permission_grant n
                      where n.user_id = g.user_id and n.app_code = g.app_code
                        and n.code = g.code and n.efeito = 'negar'
                        and n.valido_de <= now()
                        and (n.valido_ate is null or n.valido_ate > now()));

  perform public.shaar_registrar('ACESSO', 'sucesso', v_app.code,
    jsonb_build_object('bilhete', true, 'permissoes', jsonb_array_length(
      coalesce(jsonb_path_query_array(v_perms, '$.keyvalue().key'), '[]'::jsonb))));

  return jsonb_build_object(
    'permitido', true,
    'sub',   v_p.id::text,
    'email', v_p.email,
    'nome',  v_p.full_name,
    'app',   v_app.code,
    'url',   v_app.url,
    'perfil', v_p.perfil,
    'nivel',  coalesce(v_p.nivel, 0),
    'cargo',  v_p.cargo,
    'perms',  v_perms,
    'pv',     public.shaar_versao_permissoes(v_app.code, v_uid)
  );
end $$;

grant execute on function public.shaar_estado_permissoes(bigint,text)        to authenticated;
grant execute on function public.shaar_resumo_permissoes(bigint)             to authenticated;
grant execute on function public.shaar_quem_tem(text,text)                   to authenticated;
grant execute on function public.shaar_historico_permissoes(bigint,text,timestamptz,integer) to authenticated;
grant execute on function public.shaar_definir_permissoes(bigint,text,jsonb,text) to authenticated;
grant execute on function public.shaar_conceder_emergencia(bigint,text,text,numeric,text) to authenticated;
grant execute on function public.shaar_ver_divergencias_permissao()          to authenticated;
grant execute on function public.shaar_correr_testes()                       to authenticated;
grant execute on function public.shaar_correr_testes_escopo()                to authenticated;

commit;
