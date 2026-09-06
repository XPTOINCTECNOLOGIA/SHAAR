-- =====================================================================
-- `tikkun_is_admin()`: o último sítio onde o perfil ainda era autoridade
-- =====================================================================
--
--   SELECT COALESCE(tikkun_current_role() = 'administrador', false)
--     OR COALESCE((SELECT p.level FROM users u JOIN profiles p ON p.id = u.profile_id
--                  WHERE u.auth_user_id = auth.uid()) >= 90, false);
--
-- Decide por `profiles.level >= 90`. É exactamente o que o dono disse que não
-- pode acontecer — «perfil não é autoridade» — e ninguém tem hoje o papel
-- `administrador` no TIKKUN, portanto o primeiro ramo está vazio e é só o
-- perfil a decidir.
--
-- A migração 019 substituiu os corpos de `tikkun_can_supervise` e
-- `tikkun_can_manage`, que a chamavam. Mas ela não ficou órfã: TRÊS políticas
-- RLS chamam-na directamente e continuam a decidir por perfil —
--
--   tikkun_roles_select     em tikkun_user_roles   (quem lê os papéis)
--   tikkun_roles_admin_all  em tikkun_user_roles   (quem concede e revoga papéis)
--   tikkun_dash_owner       em tikkun_dashboards   (dono ou admin)
--
-- PORQUE O RELATÓRIO NÃO A APANHOU
-- --------------------------------
-- `DECISAO_FORA_DA_CENTRAL` conta políticas que chamam `has_permission` ou
-- `shaar_pode`. Uma política que chama um predicado PRÓPRIO da aplicação não é
-- apanhada por nenhum dos dois padrões. O ponto cego é meu e fica dito aqui;
-- a medição que o fecha é assunto de outro ficheiro.
--
-- O QUE ESTE FICHEIRO FAZ
-- -----------------------
-- O mesmo que a 019 fez às outras duas: o nome da função fica, e troca-se o que
-- está por baixo. As três políticas não mudam uma linha — muda a fonte da
-- verdade sob elas. As concessões saem de PERGUNTAR à função antiga, pessoa a
-- pessoa, com impersonação; não da minha leitura do `or`.
--
-- UMA permissão, não três. Traduzir `tikkun_is_admin()` em três permissões
-- finas seria eu a redesenhar o TIKKUN, que não é o que foi pedido nem o que
-- sei fazer sem o dono. Uma permissão que responde exactamente o que aquela
-- função respondia é uma tradução; três seriam uma opinião.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. GUARDAR A FUNCAO ANTIGA, COPIADA PELA PROPRIA BASE
-- ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  if to_regprocedure('public.tikkun_is_admin_legado()') is not null then
    raise notice 'tikkun_is_admin_legado ja existe';
    return;
  end if;
  select regexp_replace(pg_get_functiondef(p.oid),
                        'FUNCTION public\.tikkun_is_admin\(',
                        'FUNCTION public.tikkun_is_admin_legado(')
    into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tikkun_is_admin'
     and p.pronargs = 0;
  if v_def is null then
    raise exception 'nao encontrei public.tikkun_is_admin() para copiar';
  end if;
  execute v_def;
end
$mig$;


-- ---------------------------------------------------------------------
-- 2. O CATALOGO
-- ---------------------------------------------------------------------
-- O codigo e `administracao.gerir` e nao `administrar` porque a tabela tem uma
-- restricao de forma — `^[a-z][a-z0-9_-]*([.:][a-z][a-z0-9_-]*)+$` — que exige
-- pelo menos um separador. A primeira versao deste ficheiro rebentou por isso.
-- E uma boa restricao: mantem o catalogo legivel e fecha a porta a texto livre
-- vindo do cliente.
insert into public.shaar_permission
  (app_code, code, name, description, grupo, sort_order, origem)
values
 ('TIKKUN', 'administracao.gerir', 'Administrar o TIKKUN',
  'Ler e alterar os papeis do TIKKUN (tikkun_user_roles) e os paineis de '
  'qualquer pessoa. Corresponde exactamente ao que tikkun_is_admin() decidia — '
  'que ate aqui era o nivel do PERFIL (level >= 90), e portanto perfil como '
  'autoridade.',
  'administracao', 30, 'aplicacao')
on conflict (app_code, code) do update
  set name = excluded.name, description = excluded.description,
      grupo = excluded.grupo, sort_order = excluded.sort_order,
      origem = excluded.origem, active = true;


-- ---------------------------------------------------------------------
-- 3. AS CONCESSOES, PERGUNTADAS A FUNCAO ANTIGA
-- ---------------------------------------------------------------------
do $mig$
declare
  r          record;
  v_n        int := 0;
  v_sem_port int := 0;
begin
  for r in
    select u.id, u.auth_user_id,
           exists (select 1 from public.shaar_gate_access g
                    where g.user_id = u.id and g.app_code = 'TIKKUN') as tem_portao
      from public.users u
     where u.active and u.auth_user_id is not null
  loop
    perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.auth_user_id::text)::text, true);

    if coalesce(public.tikkun_is_admin_legado(), false) then
      insert into public.shaar_permission_grant
        (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
      values (r.id, 'TIKKUN', 'administracao.gerir', 'permitir', '{}'::jsonb,
              'migracao do modelo anterior — tikkun_is_admin() respondia '
              'verdadeiro para esta pessoa (papel administrador ou perfil de '
              'nivel >= 90). A partir daqui a resposta e da Central.',
              null::bigint, now())
      on conflict (user_id, app_code, code) do nothing;
      v_n := v_n + 1;
      if not r.tem_portao then v_sem_port := v_sem_port + 1; end if;
    end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  if v_n = 0 then
    raise exception
      'ninguem recebeu TIKKUN/administracao.gerir. Ou tikkun_is_admin_legado nao '
      'responde por este caminho, ou nao ha administradores — e a primeira '
      'hipotese e demasiado provavel para se assumir a segunda. Se ninguem '
      'fosse mesmo admin, este ficheiro estaria a trancar tres politicas.';
  end if;
  raise notice 'TIKKUN/administracao.gerir: % pessoas (% sem portao do TIKKUN)', v_n, v_sem_port;
end
$mig$;


-- ---------------------------------------------------------------------
-- 4. A TROCA
-- ---------------------------------------------------------------------
-- O nome fica; as tres politicas nao mudam uma linha. `create or replace`
-- preserva a ACL, que aqui importa: a 20260821000200 revogou o execute a
-- authenticated de proposito, e isso tem de continuar assim.
create or replace function public.tikkun_is_admin()
returns boolean
language sql stable security definer
set search_path to 'public'
as $function$
  select public.shaar_pode('TIKKUN', 'administracao.gerir');
$function$;


-- ---------------------------------------------------------------------
-- 5. NINGUEM COM PORTAO PODE PERDER
-- ---------------------------------------------------------------------
do $mig$
declare
  r        record;
  v_ctl    int := 0;
  v_perde  int := 0;
  v_ganha  int := 0;
  v_antes  boolean;
  v_depois boolean;
begin
  for r in
    select u.id, u.auth_user_id
      from public.users u
      join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'TIKKUN'
     where u.active and u.auth_user_id is not null
  loop
    perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.auth_user_id::text)::text, true);

    v_antes  := coalesce(public.tikkun_is_admin_legado(), false);
    v_depois := coalesce(public.tikkun_is_admin(), false);

    if v_antes then v_ctl := v_ctl + 1; end if;
    if v_antes and not v_depois then v_perde := v_perde + 1; end if;
    if v_depois and not v_antes then v_ganha := v_ganha + 1; end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  if v_ctl = 0 then
    raise exception
      'o controlo deu zero: a funcao antiga nunca respondeu verdadeiro a '
      'ninguem com portao do TIKKUN, portanto a medicao nao esta a funcionar e '
      'o "ninguem perde" abaixo nao valeria nada.';
  end if;
  if v_perde > 0 then
    raise exception '% pessoa(s) com portao do TIKKUN perdem administracao.gerir. Nada disto entra.', v_perde;
  end if;
  if v_ganha > 0 then
    raise exception '% pessoa(s) GANHAM administracao.gerir sem ninguem ter decidido. Nada disto entra.', v_ganha;
  end if;

  raise notice 'tikkun_is_admin trocado: controlo %, ninguem perde, ninguem ganha', v_ctl;
end
$mig$;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'catalogo do TIKKUN: ' || string_agg(code, ', ' order by code)
  from public.shaar_permission where app_code = 'TIKKUN' and active;

select 'quem administra o TIKKUN: ' || coalesce(string_agg(u.email::text, ', ' order by u.email), 'ninguem')
  from public.shaar_permission_grant g
  join public.users u on u.id = g.user_id
 where g.app_code = 'TIKKUN' and g.code = 'administracao.gerir' and g.efeito = 'permitir';

-- As tres politicas continuam a existir e a chamar o mesmo nome.
select 'politicas que chamam tikkun_is_admin: ' || count(*)::text
  from pg_policy p
 where coalesce(pg_get_expr(p.polqual, p.polrelid), '') like '%tikkun_is_admin%'
    or coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '') like '%tikkun_is_admin%';

-- E nao sobra nenhuma leitura de perfil no corpo da funcao nova.
select 'tikkun_is_admin ainda le profiles: ' ||
       case when pg_get_functiondef(p.oid) like '%profiles%' then 'SIM — ERRADO' else 'nao' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'tikkun_is_admin' and p.pronargs = 0;
