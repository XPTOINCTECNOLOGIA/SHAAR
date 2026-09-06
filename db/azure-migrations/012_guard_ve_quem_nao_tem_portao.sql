-- =====================================================================
-- O guard tinha um buraco, e o JIREH mostrou-o
-- =====================================================================
--
-- A medicao do JIREH deu `perde: 0` — e ligar o JIREH tiraria acesso a 37
-- pessoas. As duas coisas sao verdadeiras ao mesmo tempo, e e por isso que
-- isto e grave.
--
-- `shaar_divergencia_real_resumo` so percorre quem TEM o portao da
-- aplicacao aberto. Faz sentido para comparar respostas, porque `shaar_pode`
-- exige o portao. Mas a funcao antiga NAO exige: quem tem a permissao pelo
-- perfil consegue agir mesmo sem portao, porque todas as aplicacoes
-- partilham a mesma base e o mesmo PostgREST. Essas pessoas sao invisiveis
-- para o resumo — e sao exactamente as que a troca prejudica.
--
-- Ou seja: o meu guard recusava-se a magoar quem eu estava a olhar, e nao
-- olhava para quem estava em risco. Um guard com este buraco e pior do que
-- nenhum, porque autoriza com ar de ter verificado.
--
--   JIREH:    perde 0 (dos 2 com portao) | 37 pessoas, 164 permissoes sem portao
--   MERKAVAH: perde 0 (dos 3 com portao) |  3 pessoas,  29 permissoes sem portao
--
-- Este ficheiro tapa o buraco e, antes disso, verifica se ele ja fez
-- estragos nas tres aplicacoes que liguei hoje.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. PRIMEIRO, O ESTRAGO: aconteceu nas que ja liguei?
-- ---------------------------------------------------------------------
-- Se alguma destas contar acima de zero, ha gente que perdeu acesso hoje
-- por minha causa, e reverter e apagar uma linha de shaar_app_central.
select 'JA LIGADAS — quem tinha permissao pelo modelo antigo e nao tem portao: '
       || coalesce(string_agg(app_code || ' ' || pessoas || 'p/' || perms || 'x',
                              ', ' order by app_code), 'nenhuma')
  from (
    select sp.app_code,
           count(distinct u.id)::text as pessoas,
           count(*)::text             as perms
      from public.shaar_app_central c
      join public.shaar_permission sp on sp.app_code = c.app_code
                                     and sp.origem = 'herdado' and sp.active
      join public.permissions p          on p.code = sp.code and p.active
      join public.profile_permissions pp on pp.permission_id = p.id
      join public.users u                on u.profile_id = pp.profile_id
     where u.active and not u.blocked
       and not exists (select 1 from public.shaar_gate_access g
                        where g.user_id = u.id and g.app_code = sp.app_code)
     group by sp.app_code
  ) d;


-- ---------------------------------------------------------------------
-- 2. O RESUMO PASSA A VER TODA A GENTE
-- ---------------------------------------------------------------------
drop function if exists public.shaar_divergencia_real_resumo(text);

create function public.shaar_divergencia_real_resumo(p_app text)
returns table (
  total              bigint,
  perdia             bigint,   -- com portao: antigo sim, Central nao
  perde_sem_portao   bigint,   -- SEM portao: antigo sim, Central nao. O buraco.
  ganharia           bigint,
  ganha_sem_revisao  bigint,
  pessoas            bigint,
  pessoas_sem_portao bigint,
  controlo_positivos bigint,
  pares_avaliados    bigint
)
language plpgsql
volatile
set search_path = public
as $$
declare
  r          record;
  v_a        boolean;
  v_c        boolean;
  v_quem     bigint[] := '{}';
  v_quem_sp  bigint[] := '{}';
begin
  total := 0; perdia := 0; perde_sem_portao := 0;
  ganharia := 0; ganha_sem_revisao := 0;
  controlo_positivos := 0; pares_avaliados := 0;

  -- Sem o filtro do portao: percorre TODA a gente activa. Quem nao tem
  -- portao entra com `tem_portao` falso e conta na coluna propria.
  for r in
    select u.id, u.auth_user_id, sp.code,
           exists (select 1 from public.shaar_gate_access g
                    where g.user_id = u.id and g.app_code = p_app) as tem_portao,
           exists (select 1 from public.shaar_permission_revisao rv
                    where rv.user_id = u.id and rv.resolvido_em is null) as tem_revisao
      from public.users u
      cross join public.shaar_permission sp
     where u.active and not u.blocked
       and sp.app_code = p_app and sp.origem = 'herdado' and sp.active
  loop
    if r.auth_user_id is null then
      perform set_config('request.jwt.claim.sub', '',   true);
      perform set_config('request.jwt.claims',    '{}', true);
    else
      perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
      perform set_config('request.jwt.claims',
                         json_build_object('sub', r.auth_user_id::text)::text, true);
    end if;

    v_a := public.jireh_has_permission_legado(r.code::varchar);
    v_c := public.shaar_pode(p_app, r.code, '{}'::jsonb, r.id);

    pares_avaliados := pares_avaliados + 1;
    if v_a and r.auth_user_id is not null then
      controlo_positivos := controlo_positivos + 1;
    end if;

    if v_a is distinct from v_c then
      total := total + 1;
      if v_a and not v_c then
        if r.tem_portao then
          perdia := perdia + 1;
        else
          perde_sem_portao := perde_sem_portao + 1;
          if not (r.id = any (v_quem_sp)) then
            v_quem_sp := v_quem_sp || r.id;
          end if;
        end if;
      else
        ganharia := ganharia + 1;
        if not r.tem_revisao then
          ganha_sem_revisao := ganha_sem_revisao + 1;
        end if;
      end if;
      if not (r.id = any (v_quem)) then
        v_quem := v_quem || r.id;
      end if;
    end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  pessoas            := coalesce(array_length(v_quem,    1), 0);
  pessoas_sem_portao := coalesce(array_length(v_quem_sp, 1), 0);
  return next;
end $$;

comment on function public.shaar_divergencia_real_resumo(text) is
  'Percorre TODA a gente activa, com portao e sem. Quem nao tem portao e '
  'invisivel para shaar_pode mas nao para a funcao antiga, que nunca exigiu '
  'portao: sao essas as pessoas que uma troca prejudica, e por isso tem '
  'coluna propria em vez de ficarem de fora da contagem.';

revoke all on function public.shaar_divergencia_real_resumo(text) from public;


-- ---------------------------------------------------------------------
-- 3. O GUARD PASSA A OLHAR PARA ONDE DOI
-- ---------------------------------------------------------------------
create or replace function public.shaar_ligar_central(p_app text, p_motivo text)
returns text
language plpgsql
volatile
set search_path = public
as $$
declare r record; v_cods bigint;
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
      'liga-la daria a impressao errada de que pega', p_app;
  end if;

  if not public.shaar_impersonacao_funciona() then
    raise exception 'a impersonacao nao esta a funcionar: nao se liga as cegas';
  end if;

  select * into r from public.shaar_divergencia_real_resumo(p_app);

  if r.perdia > 0 then
    raise exception
      'ligar % tiraria acesso em % respostas a gente COM o portao aberto',
      p_app, r.perdia;
  end if;

  -- O buraco que o JIREH mostrou. A funcao antiga nunca exigiu portao e
  -- `shaar_pode` exige: quem tem a permissao pelo perfil e nao tem portao
  -- perde acesso, e nao aparecia em lado nenhum.
  if r.perde_sem_portao > 0 then
    raise exception
      'ligar % tiraria acesso em % respostas a % pessoas que tem a permissao '
      'pelo modelo antigo mas NAO tem o portao aberto. A funcao antiga nunca '
      'exigiu portao e a Central exige. Isto decide-se antes: ou se lhes abre '
      'o portao, ou se assume que nao deviam ter o acesso — e nenhuma das duas '
      'e uma decisao tecnica',
      p_app, r.perde_sem_portao, r.pessoas_sem_portao;
  end if;

  if r.ganha_sem_revisao > 0 then
    raise exception
      'ligar % daria acesso novo em % respostas a gente sem revisao aberta',
      p_app, r.ganha_sem_revisao;
  end if;

  insert into public.shaar_app_central (app_code, motivo) values (p_app, p_motivo);

  return format(
    '%s passa a obedecer a Central. %s codigos herdados, %s pares medidos, '
    'ninguem perde acesso (nem com portao nem sem), %s respostas de acesso novo '
    '(todas com revisao aberta)',
    p_app, v_cods, r.pares_avaliados, r.ganharia);
end $$;

revoke all on function public.shaar_ligar_central(text, text) from public;


-- ---------------------------------------------------------------------
-- Conferencia: as tres ja ligadas, agora medidas a serio
-- ---------------------------------------------------------------------
select 'TETELESTAI — perde com portao: ' || r.perdia::text ||
       ' | perde SEM portao: '           || r.perde_sem_portao::text ||
       ' | pessoas sem portao: '         || r.pessoas_sem_portao::text
  from public.shaar_divergencia_real_resumo('TETELESTAI') r;

select 'FAITH — perde com portao: ' || r.perdia::text ||
       ' | perde SEM portao: '      || r.perde_sem_portao::text ||
       ' | pessoas sem portao: '    || r.pessoas_sem_portao::text
  from public.shaar_divergencia_real_resumo('FAITH') r;

select 'MANNA — perde com portao: ' || r.perdia::text ||
       ' | perde SEM portao: '      || r.perde_sem_portao::text ||
       ' | pessoas sem portao: '    || r.pessoas_sem_portao::text
  from public.shaar_divergencia_real_resumo('MANNA') r;
