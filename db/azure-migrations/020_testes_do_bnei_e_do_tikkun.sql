-- =====================================================================
-- Os quatro casos de referencia do BNEI e do TIKKUN passam a existir
-- =====================================================================
--
-- O relatorio ficou em 8/10 depois das trocas de ontem. Os dois vermelhos
-- sao estes:
--
--   tecnico do TIKKUN executa ordem de servico   [esperado true, obtido false]
--   consulta do BNEI ve o quadro de pessoas      [esperado true, obtido false]
--
-- Nao e a autorizacao que partiu. Sao os testes que citavam codigos que eu
-- tinha inventado — `os.executar`, `pessoa.consultar` — e que sairam do
-- catalogo quando o BNEI e o TIKKUN passaram a ser descritos pelo que as
-- aplicacoes mesmo fazem (016 e 018).
--
-- E ha uma segunda metade, pior, que o vermelho tapava: os outros dois casos
-- desse grupo — `os.aprovar` e `pessoa.gerir`, ambos a esperar FALSO —
-- continuavam verdes. Verdes porque os codigos nao existem, portanto
-- responderiam falso acontecesse o que acontecesse. Um teste que nao pode
-- falhar e pior do que um teste vermelho: o vermelho chama alguem, o verde
-- vazio da confianca.
--
-- Os quatro sao substituidos por casos assentes na verdade das aplicacoes:
--
--   · BNEI: `bnei_role_has_permission(papel, codigo)` — uma funcao pura, que
--     se pode perguntar directamente.
--   · TIKKUN: as proprias funcoes antigas, perguntadas pessoa a pessoa com
--     impersonacao, como em 018. A resposta fica CONGELADA na linha do teste.
--     E um retrato do sistema antigo, nao uma leitura da Central — e por isso
--     e que fica vermelho no dia em que alguem mexer numa concessao sem
--     decidir mexer.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. FORA OS QUATRO
-- ---------------------------------------------------------------------
delete from public.shaar_autorizacao_teste
 where app_code in ('BNEI', 'TIKKUN');


-- ---------------------------------------------------------------------
-- 2. BNEI — o papel tem, e o papel nao tem
-- ---------------------------------------------------------------------
-- Sem emails escritos a mao: as pessoas vem de quem la esta. Exige-se o
-- portao nos dois casos de proposito, para o que se testa ser a permissao e
-- nao a entrada — o portao ja tem o seu caso, no JIREH.
insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'BNEI: quem tem o papel ' || r.role || ' pode ' || sp.code
       || ' (bnei_role_has_permission diz que sim)',
       u.email, 'BNEI', sp.code, '{}', true
  from public.bnei_user_roles r
  join public.users u             on u.id = r.user_id and u.active
  join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'BNEI'
  join public.shaar_permission sp on sp.app_code = 'BNEI' and sp.active
 where public.bnei_role_has_permission(r.role, sp.code)
 order by r.role, sp.code, u.email
 limit 1;

insert into public.shaar_autorizacao_teste (descricao, email, app_code, code, contexto, esperado)
select 'BNEI: quem tem o papel ' || r.role || ' NAO pode ' || sp.code
       || ' (bnei_role_has_permission diz que nao)',
       u.email, 'BNEI', sp.code, '{}', false
  from public.bnei_user_roles r
  join public.users u             on u.id = r.user_id and u.active
  join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'BNEI'
  join public.shaar_permission sp on sp.app_code = 'BNEI' and sp.active
 where not exists (
         select 1 from public.bnei_user_roles r2
          where r2.user_id = u.id
            and public.bnei_role_has_permission(r2.role, sp.code))
 order by r.role, sp.code, u.email
 limit 1;


-- ---------------------------------------------------------------------
-- 3. TIKKUN — perguntado as funcoes antigas, e congelado
-- ---------------------------------------------------------------------
do $mig$
declare
  r     record;
  c     text;
  v     boolean;
  v_sim text;
  v_nao text;
  v_n   int := 0;
begin
  foreach c in array array['os.supervisionar', 'os.gerir'] loop
    v_sim := null;
    v_nao := null;

    for r in
      select u.email, u.auth_user_id
        from public.users u
        join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'TIKKUN'
       where u.active and u.auth_user_id is not null
       order by u.email
    loop
      perform set_config('request.jwt.claim.sub', r.auth_user_id::text, true);
      perform set_config('request.jwt.claims',
                         json_build_object('sub', r.auth_user_id::text)::text, true);

      v := coalesce(public.tikkun_capacidade_legada(c), false);

      if v and v_sim is null then
        v_sim := r.email;
      elsif not v and v_nao is null then
        v_nao := r.email;
      end if;
      exit when v_sim is not null and v_nao is not null;
    end loop;

    if v_sim is not null then
      insert into public.shaar_autorizacao_teste
        (descricao, email, app_code, code, contexto, esperado)
      values ('TIKKUN: a funcao antiga respondia SIM a esta pessoa em ' || c
              || ' — a Central tem de continuar a responder o mesmo',
              v_sim, 'TIKKUN', c, '{}', true);
      v_n := v_n + 1;
    end if;

    if v_nao is not null then
      insert into public.shaar_autorizacao_teste
        (descricao, email, app_code, code, contexto, esperado)
      values ('TIKKUN: a funcao antiga respondia NAO a esta pessoa em ' || c
              || ' — a Central nao pode passar a responder que sim',
              v_nao, 'TIKKUN', c, '{}', false);
      v_n := v_n + 1;
    end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  -- Se o TIKKUN nao deu casos nenhuns, ou nao ha ninguem com portao e conta
  -- de autenticacao, ou a impersonacao nao esta a funcionar por este caminho.
  -- Nos dois casos o ficheiro nao pode dar-se por feito em silencio.
  if v_n = 0 then
    raise exception
      'nenhum caso de referencia do TIKKUN foi semeado: ou nao ha gente com '
      'portao e conta de autenticacao, ou a impersonacao nao funciona daqui';
  end if;
  raise notice 'casos do TIKKUN semeados: %', v_n;
end
$mig$;


-- ---------------------------------------------------------------------
-- 4. NENHUM CASO NASCE VERMELHO
-- ---------------------------------------------------------------------
-- Um ficheiro de migracao que instale um teste ja a falhar nao esta a fixar
-- comportamento nenhum — esta a pintar de vermelho o painel de outra pessoa.
-- Como o pipeline corre em transaccao unica, esta excepcao desfaz tudo.
do $mig$
declare
  v_mau text;
  v_n   int;
begin
  select count(*), string_agg(t.descricao || ' [esperado ' || t.esperado
                              || ', obtido ' || coalesce(t.obtido::text, 'nulo') || ']', '; ')
    into v_n, v_mau
    from public.shaar_correr_testes() t
    join public.shaar_autorizacao_teste s on s.id = t.id
   where not t.passou and s.app_code in ('BNEI', 'TIKKUN');

  if v_n > 0 then
    raise exception 'casos do BNEI/TIKKUN semeados ja a falhar: %', v_mau;
  end if;
end
$mig$;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'casos de referencia: ' || count(*)::text
       || ' (' || (count(*) filter (where app_code = 'BNEI'))::text || ' do BNEI, '
       || (count(*) filter (where app_code = 'TIKKUN'))::text || ' do TIKKUN)'
  from public.shaar_autorizacao_teste;

select 'testes de autorizacao: '
       || (count(*) filter (where passou))::text || '/' || count(*)::text
  from public.shaar_correr_testes();

select 'casos que nao podem falhar (codigo fora do catalogo): ' || count(*)::text
  from public.shaar_autorizacao_teste t
 where t.esperado = false
   and not exists (select 1 from public.shaar_permission sp
                    where sp.app_code = t.app_code and sp.code = t.code and sp.active);
