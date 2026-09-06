-- =====================================================================
-- O TIKKUN traduzido fielmente: duas capacidades, e a leitura intacta
-- =====================================================================
--
-- O TIKKUN nao tem catalogo de permissoes nenhum. Tem 56 politicas
-- permissivas sobre tres funcoes:
--
--   tikkun_can_supervise()  = papel em (administrador, gestor, supervisor)
--                             OU tikkun_is_admin()
--   tikkun_can_manage()     = o equivalente para gerir
--   tikkun_current_user_id() = a posse, para o tecnico mexer na sua OS
--
-- e o `select` de todas as tabelas e `true`: le toda a gente da casa. Isso
-- fica como esta, por decisao do dono. Este ficheiro nao cria uma unica
-- politica restritiva.
--
-- As nove permissoes que eu tinha inventado para o TIKKUN — `os.consultar`,
-- `os.executar`, `os.criar`, `os.aprovar`… — nao correspondem a nada. Sao
-- substituidas por duas, que sao as capacidades que a aplicacao mesmo tem.
--
-- COMO as concessoes sao decididas, e a parte que interessa: nao decomponho
-- as funcoes. PERGUNTO-LHES, pessoa a pessoa, com a mesma impersonacao que
-- ja usei o dia todo. Assim apanho o `tikkun_is_admin()` e qualquer outro
-- ramo que eu nao tenha lido — a traducao e fiel por construcao, e nao por
-- eu ter percebido bem o codigo.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. FORA A INVENCAO
-- ---------------------------------------------------------------------
delete from public.shaar_permission_grant
 where app_code = 'TIKKUN'
   and code in ('os.consultar','os.executar','os.assinar','os.criar',
                'os.aprovar','equipa.gerir','custo.consultar',
                'relatorio.consultar','configuracao.gerir');

delete from public.shaar_permission
 where app_code = 'TIKKUN'
   and code in ('os.consultar','os.executar','os.assinar','os.criar',
                'os.aprovar','equipa.gerir','custo.consultar',
                'relatorio.consultar','configuracao.gerir');


-- ---------------------------------------------------------------------
-- 2. O CATALOGO: duas capacidades, e nada sobre ler
-- ---------------------------------------------------------------------
-- Nao ha permissao de leitura de proposito. A leitura das ordens de servico
-- continua aberta a toda a gente da casa, e criar uma permissao para ela
-- daria a entender que se pode recortar — o que hoje nao e verdade e nao e
-- para ser.
insert into public.shaar_permission
  (app_code, code, name, description, grupo, sort_order, origem)
values
 ('TIKKUN','os.supervisionar','Supervisionar ordens de servico',
  'Alterar e apagar ordens de servico, materiais, fotografias, servicos e '
  'assinaturas de qualquer tecnico. Corresponde a tikkun_can_supervise().',
  'ordens', 10, 'aplicacao'),
 ('TIKKUN','os.gerir','Gerir ordens de servico',
  'Apagar ordens de servico. Corresponde a tikkun_can_manage().',
  'ordens', 20, 'aplicacao')
on conflict (app_code, code) do update
  set name = excluded.name, description = excluded.description,
      grupo = excluded.grupo, sort_order = excluded.sort_order,
      origem = excluded.origem, active = true;


-- ---------------------------------------------------------------------
-- 3. AS CONCESSOES, PERGUNTADAS AS PROPRIAS FUNCOES
-- ---------------------------------------------------------------------
do $mig$
declare
  r     record;
  v_sup boolean;
  v_ger boolean;
  v_n   int := 0;
begin
  for r in
    select u.id, u.auth_user_id
      from public.users u
     where u.active
  loop
    if r.auth_user_id is null then
      perform set_config('request.jwt.claim.sub', '',   true);
      perform set_config('request.jwt.claims',    '{}', true);
    else
      perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
      perform set_config('request.jwt.claims',
                         json_build_object('sub', r.auth_user_id::text)::text, true);
    end if;

    v_sup := coalesce(public.tikkun_can_supervise(), false);
    v_ger := coalesce(public.tikkun_can_manage(),    false);

    if v_sup then
      insert into public.shaar_permission_grant
        (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
      values (r.id, 'TIKKUN', 'os.supervisionar', 'permitir', '{}'::jsonb,
              'migracao do modelo anterior — tikkun_can_supervise() respondia '
              'verdadeiro para esta pessoa', null, now())
      on conflict (user_id, app_code, code) do nothing;
      v_n := v_n + 1;
    end if;

    if v_ger then
      insert into public.shaar_permission_grant
        (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
      values (r.id, 'TIKKUN', 'os.gerir', 'permitir', '{}'::jsonb,
              'migracao do modelo anterior — tikkun_can_manage() respondia '
              'verdadeiro para esta pessoa', null, now())
      on conflict (user_id, app_code, code) do nothing;
      v_n := v_n + 1;
    end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  if v_n = 0 then
    raise exception
      'nenhuma pessoa recebeu capacidades do TIKKUN. Ou a impersonacao nao '
      'funciona por este caminho, ou nao ha supervisores nem gestores — e a '
      'primeira hipotese e demasiado provavel para se assumir a segunda';
  end if;
  raise notice 'concessoes do TIKKUN atribuidas: %', v_n;
end
$mig$;


-- ---------------------------------------------------------------------
-- 4. A VISTA DO MODELO ANTIGO DEIXA DE ME CITAR TAMBEM AQUI
-- ---------------------------------------------------------------------
-- O ramo do TIKKUN tinha os meus nove codigos. Passa a ser o que ficou
-- guardado — que veio das proprias funcoes — porque nao ha maneira de
-- escrever `tikkun_can_supervise()` numa vista sem identidade de quem
-- pergunta. As concessoes SAO a resposta das funcoes, pessoa a pessoa.
create or replace view public.shaar_permissao_verdade_antiga as
  select distinct u.id as user_id, sp.app_code, sp.code
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
   where u.active
  union
  select distinct u.id, sp.app_code, sp.code
    from public.jireh_user_permissions jup
    join public.users u             on u.id = jup.user_id and u.active
    join public.permissions p       on p.id = jup.permission_id
    join public.shaar_permission sp on sp.code = p.code and sp.origem = 'herdado'
  union
  select distinct u.id, sp.app_code, sp.code
    from public.users u
    join public.positions pos on pos.id = u.position_id and pos.active
    join public.profiles fin  on upper(fin.name) = 'FINANCEIRO' and fin.active
    join public.profile_permissions pp on pp.profile_id = fin.id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
   where u.active and not u.blocked and upper(pos.name) = 'CFO'
  union
  select distinct u.id, 'BNEI', sp.code
    from public.bnei_user_roles r
    join public.users u             on u.id = r.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'BNEI' and sp.active
   where public.bnei_role_has_permission(r.role, sp.code)
  -- O TIKKUN NAO tem ramo aqui, e a ausencia e deliberada.
  --
  -- Esta vista e o meu modelo do sistema antigo, escrito como consulta. O
  -- modelo do TIKKUN nao e uma consulta: e `tikkun_can_supervise()`, que
  -- responde em funcao de quem pergunta e inclui um `tikkun_is_admin()` por
  -- baixo. Nao ha maneira de escrever isso numa vista sem identidade.
  --
  -- Escrevi primeiro este ramo a ler das proprias concessoes e apaguei-o: a
  -- vista passaria a confirmar-se a si mesma, e a divergencia daria zero por
  -- construcao em vez de por verdade. Um numero que nao pode falhar nao e
  -- uma verificacao — e um enfeite que da confianca a troco de nada.
  --
  -- O TIKKUN e verificado pelo caminho mais forte, que a vista nao consegue:
  -- perguntar as duas funcoes, pessoa a pessoa, com impersonacao. Fica no
  -- relatorio como REAL_TIKKUN.
  union
  select g.user_id, 'SPHRAGIS', sp.code
    from public.shaar_gate_access g
    join public.users u             on u.id = g.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'SPHRAGIS'
   where g.app_code = 'SPHRAGIS';


-- ---------------------------------------------------------------------
-- 5. A COMPARACAO MODELADA DEIXA O TIKKUN DE FORA, E DIZ QUE DEIXA
-- ---------------------------------------------------------------------
-- Sem ramo na vista, as concessoes do TIKKUN apareceriam todas como
-- `so_na_central`. Sai dos dois lados, como ja acontecia com o SHAAR — que
-- tambem nao existia no modelo antigo. O que nao pode acontecer e ficar de
-- fora em silencio: quem ler a vista tem de saber o que ela nao cobre.
create or replace view public.shaar_permissao_divergencias as
  select coalesce(a.user_id, b.user_id)   as user_id,
         u.email,
         u.full_name,
         coalesce(a.app_code, b.app_code) as app_code,
         coalesce(a.code, b.code)         as code,
         case when b.user_id is null then 'so_no_modelo_antigo'
              when a.user_id is null then 'so_na_central'
         end                              as divergencia
    from public.shaar_permissao_verdade_antiga a
    full outer join (
      select user_id, app_code, code
        from public.shaar_permission_grant
       where efeito = 'permitir'
         and valido_de <= now()
         and (valido_ate is null or valido_ate > now())
         and app_code not in ('SHAAR', 'TIKKUN')
    ) b on b.user_id = a.user_id and b.app_code = a.app_code and b.code = a.code
    join public.users u on u.id = coalesce(a.user_id, b.user_id)
   where a.user_id is null or b.user_id is null;

comment on view public.shaar_permissao_divergencias is
  'Diferenca entre o que a Central diz e o modelo antigo, para as aplicacoes '
  'cujo modelo antigo se consegue escrever como consulta. NAO cobre o SHAAR, '
  'que nao existia antes, nem o TIKKUN, cujo modelo e uma funcao que depende '
  'de quem pergunta — esse verifica-se perguntando as funcoes pessoa a pessoa, '
  'que e mais forte, e nao aqui.';


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'catalogo TIKKUN: ' ||
       coalesce(string_agg(code, ', ' order by code), 'vazio')
  from public.shaar_permission where app_code = 'TIKKUN' and active;

select 'concessoes TIKKUN: ' || count(*)::text || ' para ' ||
       count(distinct user_id)::text || ' pessoas ('
       || coalesce(string_agg(distinct code, ', '), '-') || ')'
  from public.shaar_permission_grant where app_code = 'TIKKUN';

select 'quem supervisiona e nao tem portao do TIKKUN: ' || count(*)::text
  from public.shaar_permission_grant g
 where g.app_code = 'TIKKUN'
   and not exists (select 1 from public.shaar_gate_access ga
                    where ga.user_id = g.user_id and ga.app_code = 'TIKKUN');

select 'direitos por guardar: ' || count(*)::text
  from public.shaar_permissao_verdade_antiga a
  left join public.shaar_permission_grant g
    on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
 where g.user_id is null;

select 'divergencia: ' || count(*)::text
  from public.shaar_permissao_divergencias;
