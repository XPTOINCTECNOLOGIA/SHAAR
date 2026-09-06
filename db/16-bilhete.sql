-- SHAAR · autorização de bilhete por aplicação
--
-- Esta é a pergunta que o sistema nunca soube responder: "esta pessoa pode
-- usar ESTA aplicação?". A RLS sabe dizer que linhas alguém lê; não sabe de
-- que aplicação veio o pedido, nem se a pessoa tinha direito de lá entrar.
--
-- O emissor de bilhetes chama esta função com o token do próprio utilizador,
-- para que shaar_usuario_atual() resolva a identidade real. A função não
-- assina nada — só decide e regista. Assinar é do emissor, que é quem tem a
-- chave privada.

create or replace function public.shaar_autorizar_bilhete(p_app_code text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid   bigint;
  v_app   record;
  v_p     record;
  v_abre  boolean;
begin
  v_uid := public.shaar_usuario_atual();

  if v_uid is null then
    perform public.shaar_registrar('NEGATIVA', 'negado', p_app_code,
      jsonb_build_object('motivo', 'identidade autenticada sem cadastro corporativo'));
    return jsonb_build_object('permitido', false, 'motivo', 'sem_cadastro');
  end if;

  select a.code, a.name, a.url, a.released
    into v_app
    from public.shaar_apps a
   where a.code = p_app_code and a.active;

  if not found then
    perform public.shaar_registrar('NEGATIVA', 'erro', p_app_code,
      jsonb_build_object('motivo', 'aplicacao inexistente'));
    return jsonb_build_object('permitido', false, 'motivo', 'app_desconhecida');
  end if;

  -- a decisao: a pessoa tem o portao aberto E a aplicacao esta em vigor
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

  perform public.shaar_registrar('ACESSO', 'sucesso', v_app.code,
    jsonb_build_object('bilhete', true));

  -- O que vai no bilhete. Nada aqui vem do navegador: tudo sai da base.
  -- E por isso que alterar o papel no cliente nao muda coisa nenhuma.
  return jsonb_build_object(
    'permitido', true,
    'sub',   v_p.id::text,
    'email', v_p.email,
    'nome',  v_p.full_name,
    'app',   v_app.code,
    'url',   v_app.url,
    'perfil', v_p.perfil,
    'nivel',  coalesce(v_p.nivel, 0),
    'cargo',  v_p.cargo
  );
end;
$$;

comment on function public.shaar_autorizar_bilhete is
  'Decide se a pessoa autenticada pode entrar numa aplicacao e devolve o que o '
  'bilhete deve conter. Nao assina: assinar e do emissor, que tem a chave privada. '
  'Todo o conteudo vem da base, nunca do cliente.';

revoke all on function public.shaar_autorizar_bilhete(text) from public;
grant execute on function public.shaar_autorizar_bilhete(text) to authenticated;
