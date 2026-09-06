-- =====================================================================
-- Central de Permissionamento — entrada, mudança e saída
-- =====================================================================
--
-- Isto é o que separa um sistema de permissões de um sistema de identidade.
-- Recertificação trimestral apanha problemas com até três meses de atraso;
-- o ciclo de vida apanha-os no dia.
--
-- Não é preciso construir a deteção: a sincronização diária com o Entra ID
-- já sabe quem entrou, quem saiu e o que mudou. Passa a disparar as três
-- transições.
--
--   ENTRADA   conta nova licenciada. Pessoa criada, portão do TETELESTAI
--             aberto, ZERO permissões. Entra na fila de atribuição.
--
--   MUDANÇA   alteração de área, cargo ou gestor. As permissões NÃO são
--             mexidas — abre-se revisão. Revogar automaticamente parece mais
--             seguro e é pior: a pessoa fica sem trabalhar na manhã seguinte,
--             ninguém percebe porquê, e ao fim de duas vezes alguém desliga a
--             automatização. A automatização que a equipa desliga não protege
--             nada. Sinalizar mantém a pessoa a trabalhar e põe a decisão à
--             frente de quem a deve tomar.
--
--   SAÍDA     conta desactivada ou sem licença. Portões fechados e TODAS as
--             concessões revogadas, com evento por cada uma. Aqui não há
--             revisão nem prazo: uma conta que saiu da empresa e mantém
--             acesso é o achado número um de qualquer auditoria, e não há
--             caso legítimo do outro lado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- SAÍDA — imediata, sem revisão
-- ---------------------------------------------------------------------
create or replace function public.shaar_processar_saida(p_user_id bigint, p_motivo text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_motivo text := coalesce(nullif(btrim(coalesce(p_motivo,'')),''),
                            'saida — sincronizacao Entra ID');
  v_perms integer := 0;
  v_portoes integer := 0;
begin
  -- o motivo tem de ficar na linha ANTES do delete: é ele que o gatilho
  -- copia para o evento, e sem isso o histórico não diz porque se revogou
  update public.shaar_permission_grant set motivo = v_motivo where user_id = p_user_id;
  with fora as (delete from public.shaar_permission_grant where user_id = p_user_id returning 1)
    select count(*)::integer into v_perms from fora;
  with fora as (delete from public.shaar_gate_access where user_id = p_user_id returning 1)
    select count(*)::integer into v_portoes from fora;

  update public.shaar_permission_revisao
     set resolvido_em = now(), decisao = 'encerrada pela saida da pessoa'
   where user_id = p_user_id and resolvido_em is null;

  perform public.shaar_registrar('CICLO_SAIDA','sucesso', null,
    jsonb_build_object('alvo', p_user_id, 'permissoes', v_perms,
                       'portoes', v_portoes, 'motivo', v_motivo),
    null, p_user_id);

  return jsonb_build_object('ok', true, 'permissoes_revogadas', v_perms,
                            'portoes_fechados', v_portoes);
end $$;

-- ---------------------------------------------------------------------
-- MUDANÇA — sinaliza, não revoga
-- ---------------------------------------------------------------------
create or replace function public.shaar_processar_mudanca(
  p_user_id bigint, p_o_que text, p_de text, p_para text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_apps integer := 0;
begin
  insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
  select distinct p_user_id, g.app_code, 'mudanca',
         jsonb_build_object('o_que', p_o_que, 'de', p_de, 'para', p_para)
    from public.shaar_permission_grant g
   where g.user_id = p_user_id
     and not exists (select 1 from public.shaar_permission_revisao r
                      where r.user_id = p_user_id and r.app_code = g.app_code
                        and r.gatilho = 'mudanca' and r.resolvido_em is null);
  get diagnostics v_apps = row_count;

  if v_apps > 0 then
    perform public.shaar_registrar('CICLO_MUDANCA','sucesso', null,
      jsonb_build_object('alvo', p_user_id, 'o_que', p_o_que,
                         'de', p_de, 'para', p_para, 'revisoes', v_apps),
      null, p_user_id);
  end if;
  return jsonb_build_object('ok', true, 'revisoes_abertas', v_apps);
end $$;

-- ---------------------------------------------------------------------
-- ENTRADA — portão de chegada, zero permissões
-- ---------------------------------------------------------------------
create or replace function public.shaar_processar_entrada(p_user_id bigint)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  insert into public.shaar_gate_access (user_id, app_code, granted_at)
  values (p_user_id, 'TETELESTAI', now())
  on conflict do nothing;

  insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
  values (p_user_id, null, 'migracao',
          jsonb_build_object('nota','pessoa nova — permissoes por atribuir'));

  perform public.shaar_registrar('CICLO_ENTRADA','sucesso','TETELESTAI',
    jsonb_build_object('alvo', p_user_id), null, p_user_id);

  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- A PASSAGEM DIÁRIA
-- ---------------------------------------------------------------------
-- Corre depois da sincronização com o Entra ID. Compara o directório com o
-- cadastro e aplica as três transições. É idempotente: correr duas vezes no
-- mesmo dia não faz nada de diferente.
create or replace function public.shaar_ciclo_de_vida_diario()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r        record;
  v_saidas   integer := 0;
  v_mudancas integer := 0;
  v_entradas integer := 0;
begin
  -- SAÍDAS: quem está inactivo ou bloqueado no cadastro mas ainda tem portões
  for r in
    select u.id from public.users u
     where (not u.active or u.blocked or u.terminated_at is not null)
       and exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
  loop
    perform public.shaar_processar_saida(r.id, 'saida — conta inactiva no cadastro');
    v_saidas := v_saidas + 1;
  end loop;

  -- SAÍDAS: quem desapareceu do directório licenciado, sem excepção declarada
  for r in
    select u.id from public.users u
     where u.active
       and u.login_method = 'entra'
       and exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
       and not exists (select 1 from public.shaar_directory d
                        where lower(d.email) = lower(u.email))
       and not exists (select 1 from public.shaar_directory_ignorar i
                        where lower(i.email) = lower(u.email))
       and not exists (select 1 from public.shaar_directory_vinculo v
                        where lower(v.email_secundario) = lower(u.email)
                           or lower(v.email_principal) = lower(u.email))
  loop
    perform public.shaar_processar_saida(r.id, 'saida — sem licenca no Entra ID');
    v_saidas := v_saidas + 1;
  end loop;

  -- ENTRADAS: gente no cadastro, activa, ainda sem portão nenhum
  for r in
    select u.id from public.users u
     where u.active and not u.blocked
       and not exists (select 1 from public.shaar_gate_access g where g.user_id = u.id)
  loop
    perform public.shaar_processar_entrada(r.id);
    v_entradas := v_entradas + 1;
  end loop;

  -- MUDANÇAS: área do directório diferente da área do cadastro
  for r in
    select u.id, d.departamento as area_entra, dp.name as area_cadastro
      from public.users u
      join public.shaar_directory d on lower(d.email) = lower(u.email)
      left join public.org_departments dp on dp.id = u.department_id
     where u.active
       and coalesce(d.departamento,'') <> ''
       and coalesce(d.departamento,'') is distinct from coalesce(dp.name,'')
       and exists (select 1 from public.shaar_permission_grant g where g.user_id = u.id)
  loop
    perform public.shaar_processar_mudanca(r.id, 'area', r.area_cadastro, r.area_entra);
    v_mudancas := v_mudancas + 1;
  end loop;

  -- e as permissões com prazo que chegaram ao fim
  perform public.shaar_expirar_permissoes();

  perform public.shaar_registrar('CICLO_DIARIO','sucesso', null,
    jsonb_build_object('saidas', v_saidas, 'entradas', v_entradas,
                       'mudancas', v_mudancas));

  return jsonb_build_object('ok', true, 'saidas', v_saidas,
    'entradas', v_entradas, 'mudancas', v_mudancas);
end $$;

-- ---------------------------------------------------------------------
-- RECERTIFICAÇÃO
-- ---------------------------------------------------------------------
-- Auditoria diz o que aconteceu; recertificação impede o apodrecimento. É a
-- única defesa conhecida contra a acumulação silenciosa de privilégio, que é
-- o risco número um de qualquer modelo individual.
create or replace function public.shaar_relatorio_recertificacao(p_app text default null)
returns table (app_code text, code text, name text, pessoa text, email text,
               motivo text, concedida_em timestamptz, dias_desde integer,
               dias_sem_entrar integer, herdada boolean)
language sql stable security definer set search_path = public as $$
  select g.app_code, g.code, c.name, u.full_name, u.email::text, g.motivo, g.granted_at,
         extract(day from now() - g.granted_at)::integer,
         case when u.last_seen_at is null then null
              else extract(day from now() - u.last_seen_at)::integer end,
         g.motivo like 'migracao do modelo anterior%'
    from public.shaar_permission_grant g
    join public.users u on u.id = g.user_id
    join public.shaar_permission c on c.app_code = g.app_code and c.code = g.code
   where g.efeito = 'permitir'
     and (p_app is null or g.app_code = p_app)
     and (public.shaar_pode('SHAAR','permissao.gerir')
          or public.shaar_pode('SHAAR','permissao.auditar'))
   order by g.app_code, coalesce(extract(day from now() - u.last_seen_at), 9999) desc,
            u.full_name, g.code;
$$;

create or replace function public.shaar_abrir_recertificacao()
returns integer
language plpgsql volatile security definer set search_path = public as $$
declare n integer;
begin
  insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
  select distinct g.user_id, g.app_code, 'periodica',
         jsonb_build_object('trimestre', to_char(now(),'YYYY-"T"Q'))
    from public.shaar_permission_grant g
   where g.efeito = 'permitir'
     and not exists (select 1 from public.shaar_permission_revisao r
                      where r.user_id = g.user_id and r.app_code = g.app_code
                        and r.gatilho = 'periodica' and r.resolvido_em is null);
  get diagnostics n = row_count;
  perform public.shaar_registrar('RECERTIFICACAO_ABERTA','sucesso', null,
    jsonb_build_object('revisoes', n));
  return n;
end $$;

create or replace function public.shaar_revisoes_abertas()
returns table (id bigint, pessoa text, email text, app_code text, gatilho text,
               detalhe jsonb, criado_em timestamptz, dias integer)
language sql stable security definer set search_path = public as $$
  select r.id, u.full_name, u.email::text, r.app_code, r.gatilho, r.detalhe, r.criado_em,
         extract(day from now() - r.criado_em)::integer
    from public.shaar_permission_revisao r
    join public.users u on u.id = r.user_id
   where r.resolvido_em is null
     and (public.shaar_pode('SHAAR','permissao.gerir')
          or public.shaar_pode('SHAAR','permissao.auditar'))
   order by r.criado_em;
$$;

create or replace function public.shaar_resolver_revisao(p_id bigint, p_decisao text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.shaar_pode('SHAAR','permissao.gerir') then
    return jsonb_build_object('ok', false, 'motivo', 'sem_permissao_para_gerir');
  end if;
  if nullif(btrim(coalesce(p_decisao,'')),'') is null then
    return jsonb_build_object('ok', false, 'motivo', 'decisao_obrigatoria');
  end if;
  update public.shaar_permission_revisao
     set resolvido_em = now(), resolvido_por = public.shaar_usuario_atual(),
         decisao = btrim(p_decisao)
   where id = p_id and resolvido_em is null;
  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'revisao_inexistente_ou_ja_resolvida');
  end if;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.shaar_ciclo_de_vida_diario()                   to authenticated;
grant execute on function public.shaar_relatorio_recertificacao(text)           to authenticated;
grant execute on function public.shaar_abrir_recertificacao()                   to authenticated;
grant execute on function public.shaar_revisoes_abertas()                       to authenticated;
grant execute on function public.shaar_resolver_revisao(bigint,text)            to authenticated;

commit;
