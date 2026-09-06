-- =====================================================================
-- Ligar uma aplicacao passa a recusar-se a magoar alguem
-- =====================================================================
--
-- Com o interruptor orientado a dados, ligar uma aplicacao e uma linha
-- inserida. Isso e bom para reverter e mau para a disciplina: uma linha
-- inserida nao verifica nada, e a verificacao passa a depender de eu me
-- lembrar de a fazer. Ja me esqueci de coisas hoje.
--
-- Por isso a verificacao deixa de ser um passo meu e passa a ser parte do
-- acto. `shaar_ligar_central` mede antes de ligar e recusa se:
--
--   · alguem PERDER acesso. Nunca e aceitavel.
--   · alguem GANHAR acesso sem revisao aberta, ou seja sem que ninguem
--     tenha sido chamado a decidir.
--   · a aplicacao nao tiver codigos herdados — nesse caso o interruptor
--     nao lhe pega, e ligar seria dar a impressao errada de que pega.
--   · a impersonacao nao estiver a funcionar, porque nesse caso as duas
--     medicoes acima nao valem nada.
--
-- Uma migracao que se recusa a correr e um bom dia de trabalho.
-- =====================================================================


-- ---------------------------------------------------------------------
-- O controlo, independente de qualquer aplicacao
-- ---------------------------------------------------------------------
-- Toda a medicao de divergencia assenta em conseguir fazer-se passar pela
-- pessoa. Se `auth.uid()` nao ler as GUC que pomos, a funcao antiga responde
-- falso a toda a gente e as divergencias sao um artefacto — o pior modo de
-- falha possivel, porque parece uma medicao.
--
-- Isto escolhe alguem com conta de autenticacao e uma permissao pelo perfil,
-- faz-se passar por essa pessoa, e confirma que a funcao antiga diz que sim.
create or replace function public.shaar_impersonacao_funciona()
returns boolean
language plpgsql
volatile
set search_path = public
as $$
declare r record; v boolean;
begin
  select u.auth_user_id as uid, p.code
    into r
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions p on p.id = pp.permission_id and p.active
   where u.active and not u.blocked and u.auth_user_id is not null
   limit 1;

  if r.uid is null then
    return false;   -- nao ha ninguem por quem passar: nao da para afirmar nada
  end if;

  perform set_config('request.jwt.claim.sub', r.uid::text, true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', r.uid::text)::text, true);
  v := public.jireh_has_permission_legado(r.code::varchar);
  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);
  return coalesce(v, false);
end $$;

comment on function public.shaar_impersonacao_funciona is
  'Controlo de sanidade das medicoes de divergencia: faz-se passar por alguem '
  'que tem uma permissao pelo perfil e confirma que a funcao antiga diz que '
  'sim. Se der falso, nenhuma medicao de divergencia real vale nada.';

revoke all on function public.shaar_impersonacao_funciona() from public;


-- ---------------------------------------------------------------------
-- Ligar
-- ---------------------------------------------------------------------
create or replace function public.shaar_ligar_central(p_app text, p_motivo text)
returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  r        record;
  v_cods   bigint;
begin
  if not exists (select 1 from public.shaar_apps a where a.code = p_app) then
    raise exception 'aplicacao % nao existe no catalogo', p_app;
  end if;

  if exists (select 1 from public.shaar_app_central c where c.app_code = p_app) then
    return p_app || ' ja obedecia; nada a fazer';
  end if;

  select count(*) into v_cods
    from public.shaar_permission sp
   where sp.app_code = p_app and sp.origem = 'herdado' and sp.active;

  if v_cods = 0 then
    raise exception
      'a aplicacao % nao tem codigos herdados: o interruptor nao lhe pega, e '
      'liga-la daria a impressao errada de que pega. Se ela obedece, obedece '
      'por politicas RLS, como o SPHRAGIS', p_app;
  end if;

  if not public.shaar_impersonacao_funciona() then
    raise exception
      'a impersonacao nao esta a funcionar, portanto nao da para medir o que '
      'esta troca faria. Nao se liga as cegas';
  end if;

  select * into r from public.shaar_divergencia_real_resumo(p_app);

  if r.perdia > 0 then
    raise exception
      'ligar % faria % respostas passarem de permitido a negado: alguem perde '
      'acesso. Isto nunca e aceitavel — ou o espelho esta incompleto, ou as '
      'concessoes estao erradas, e resolve-se antes e nao depois',
      p_app, r.perdia;
  end if;

  if r.ganha_sem_revisao > 0 then
    raise exception
      'ligar % daria acesso novo em % respostas a gente sem revisao aberta, ou '
      'seja sem que ninguem tenha sido chamado a decidir. Abrir revisao a essas '
      'pessoas primeiro', p_app, r.ganha_sem_revisao;
  end if;

  insert into public.shaar_app_central (app_code, motivo)
  values (p_app, p_motivo);

  return format(
    '%s passa a obedecer a Central. %s codigos herdados, %s pares medidos, '
    'ninguem perde acesso, %s respostas de acesso novo (todas com revisao aberta)',
    p_app, v_cods, r.pares_avaliados, r.ganharia);
end $$;

comment on function public.shaar_ligar_central(text, text) is
  'Liga uma aplicacao a Central depois de medir o que isso faria. Recusa-se se '
  'alguem perder acesso, se alguem ganhar sem revisao aberta, se a aplicacao '
  'nao tiver codigos herdados, ou se a impersonacao nao estiver a funcionar.';

revoke all on function public.shaar_ligar_central(text, text) from public;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'impersonacao funciona: ' || public.shaar_impersonacao_funciona()::text;

-- O que a troca do FAITH faria, ANTES de a fazer.
select 'FAITH — controlo: '     || r.controlo_positivos::text ||
       ' | perde: '             || r.perdia            ::text ||
       ' | ganha sem revisao: ' || r.ganha_sem_revisao ::text ||
       ' | ganha com revisao: ' || (r.ganharia - r.ganha_sem_revisao)::text ||
       ' | pares: '             || r.pares_avaliados   ::text
  from public.shaar_divergencia_real_resumo('FAITH') r;

select 'FAITH — codigos herdados: ' || count(*)::text
  from public.shaar_permission
 where app_code = 'FAITH' and origem = 'herdado' and active;
