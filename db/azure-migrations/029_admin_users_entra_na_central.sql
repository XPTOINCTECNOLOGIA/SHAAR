-- =====================================================================
-- `admin:users`: a permissão que o BNEI pede e a Central não conhecia
-- =====================================================================
--
-- A medição nova — a que lê os literais que as políticas e as funções passam a
-- has_permission(...) — encontrou um código pedido pelo código e ausente do
-- catálogo:
--
--   bnei_grant_role   → bnei_has_permission('admin:users')
--   bnei_revoke_role  → bnei_has_permission('admin:users')
--
-- COMO ESCAPOU
-- ------------
-- O catálogo do BNEI (16 códigos, migração 016) foi derivado dos arrays de
-- `bnei_role_has_permission`, um por papel. `admin:users` não está em array
-- nenhum: existe só implícito no primeiro ramo,
--
--     when 'admin' then true          -- verdadeiro para TUDO
--
-- Um código alcançável apenas por esse ramo é invisível para quem lê os
-- arrays. Foi o que me aconteceu. A medição por literais apanha-o porque olha
-- para onde o código é PEDIDO, e não para onde é concedido.
--
-- O QUE ISTO NÃO É
-- ----------------
-- Eu disse ao dono que estas duas funções estavam mortas — que `admin:users`
-- devolvia falso a toda a gente. Errado: pressupus que o despachante era o
-- `has_permission` genérico. É o do BNEI, e enquanto o código não está no
-- catálogo o shim cai em `bnei_has_permission_legado`, que responde
-- `bnei_role_has_permission('admin', 'admin:users')` = **verdadeiro**.
--
-- Quem tem o papel `admin` no BNEI concede e revoga papéis hoje. Pôr o código
-- no catálogo sem conceder a ninguém — que foi o que cheguei a sugerir —
-- tirava-lhes essa capacidade em silêncio, porque o shim passa a consultar a
-- Central assim que o código lá está.
--
-- O QUE ESTE FICHEIRO FAZ
-- -----------------------
-- Põe o código no catálogo E concede-o, na mesma transacção, exactamente a
-- quem a aplicação já diz que sim. As concessões não saem da minha leitura do
-- `case`: saem de perguntar a `bnei_role_has_permission`, como na 016. Nada
-- muda para ninguém; muda o sítio onde a resposta é decidida.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. O CATALOGO
-- ---------------------------------------------------------------------
insert into public.shaar_permission
  (app_code, code, name, description, grupo, sort_order, origem)
values
 ('BNEI', 'admin:users', 'Gerir papeis do BNEI',
  'Conceder e revogar o papel de uma pessoa no BNEI (bnei_grant_role e '
  'bnei_revoke_role), e registar eventos de auditoria sobre user_roles. '
  'Nota: desde que o BNEI obedece a Central, os papeis do BNEI ja nao decidem '
  'autorizacao nenhuma — as permissoes vem da Central. Esta permissao governa '
  'a escrita numa tabela que hoje e sobretudo historica.',
  'administracao', 100, 'aplicacao')
on conflict (app_code, code) do update
  set name = excluded.name, description = excluded.description,
      grupo = excluded.grupo, sort_order = excluded.sort_order,
      origem = excluded.origem, active = true;


-- ---------------------------------------------------------------------
-- 2. AS CONCESSOES, PERGUNTADAS A APLICACAO
-- ---------------------------------------------------------------------
-- Sem gate na condicao, de proposito e como na 016: a permissao e da pessoa, o
-- portao diz se ela entra hoje. Quem tiver o papel e nao tiver portao fica com
-- o direito guardado, exactamente como os outros 16 codigos do BNEI.
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select distinct u.id, 'BNEI', 'admin:users', 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — bnei_role_has_permission dizia que sim a '
       'esta pessoa para admin:users (papel admin). Codigo estava a ser pedido '
       'por bnei_grant_role e bnei_revoke_role sem existir no catalogo.',
       null::bigint, now()
  from public.bnei_user_roles r
  join public.users u on u.id = r.user_id and u.active
 where public.bnei_role_has_permission(r.role, 'admin:users')
on conflict (user_id, app_code, code) do nothing;


-- ---------------------------------------------------------------------
-- 3. NINGUEM PODE PERDER ISTO POR CAUSA DESTE FICHEIRO
-- ---------------------------------------------------------------------
-- Duas verificacoes. A primeira e um controlo: se ninguem recebeu a concessao,
-- ou nao ha admins, ou a funcao nao esta a responder — e nesse caso o ficheiro
-- estaria a desligar uma capacidade em vez de a mudar de sitio.
--
-- A segunda e a medicao a serio, pessoa a pessoa, com impersonacao: para quem
-- tem o portao do BNEI, a resposta da Central tem de ser identica a que a
-- funcao antiga dava. E o mesmo metodo da 017.
do $mig$
declare
  r         record;
  v_n       int := 0;
  v_ctl     int := 0;
  v_perde   int := 0;
  v_antes   boolean;
  v_depois  boolean;
begin
  select count(*) into v_n
    from public.shaar_permission_grant
   where app_code = 'BNEI' and code = 'admin:users' and efeito = 'permitir';

  if v_n = 0 then
    raise exception
      'nenhuma pessoa recebeu admin:users. Ou nao ha ninguem com o papel admin '
      'no BNEI, ou bnei_role_has_permission nao esta a responder — e nos dois '
      'casos este ficheiro estaria a desligar uma capacidade em vez de a mudar '
      'de sitio.';
  end if;

  for r in
    select u.id, u.auth_user_id
      from public.users u
      join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'BNEI'
     where u.active and u.auth_user_id is not null
  loop
    perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', r.auth_user_id::text)::text, true);

    v_antes  := coalesce(public.bnei_has_permission_legado('admin:users'), false);
    v_depois := coalesce(public.shaar_pode('BNEI', 'admin:users'), false);

    if v_antes then v_ctl := v_ctl + 1; end if;
    if v_antes and not v_depois then v_perde := v_perde + 1; end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  if v_perde > 0 then
    raise exception
      '% pessoa(s) com portao do BNEI perdem admin:users por causa deste '
      'ficheiro. Nada disto entra.', v_perde;
  end if;

  raise notice 'admin:users: % concessoes, controlo % (ninguem perde)', v_n, v_ctl;
end
$mig$;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'catalogo do BNEI: ' || count(*)::text || ' permissoes'
  from public.shaar_permission where app_code = 'BNEI' and active;

select 'quem gere papeis do BNEI: ' || coalesce(string_agg(u.email::text, ', ' order by u.email), 'ninguem')
  from public.shaar_permission_grant g
  join public.users u on u.id = g.user_id
 where g.app_code = 'BNEI' and g.code = 'admin:users' and g.efeito = 'permitir';
