-- =====================================================================
-- Divergencia medida contra a funcao antiga, nao contra o meu modelo dela
-- =====================================================================
--
-- `shaar_permissao_divergencias` compara a Central com uma vista que EU
-- escrevi a imitar o sistema antigo. Ja falhou uma vez: faltava-lhe o ramo
-- do cargo CFO, e os "zero divergencias" que reportei eram verdadeiros para
-- o que ela media — sendo que o que ela media estava incompleto.
--
-- Corrigi esse ramo, e depois li a funcao antiga inteira (1693 caracteres,
-- tres ramos: perfil, concessoes individuais do JIREH, cargo CFO). Nao ha
-- um quarto. Mas continuam a existir diferencas de detalhe entre a minha
-- vista e a funcao — a vista nao exige `perm.active`, por exemplo — e a
-- questao de fundo mantem-se: uma comparacao contra um modelo so vale o que
-- valer o modelo, e a maneira de descobrir que ele esta errado costuma ser
-- alguem ficar sem trabalhar.
--
-- Agora que a copia legada existe e esta estavel, ha uma alternativa melhor:
-- perguntar as duas funcoes. Para cada pessoa e cada permissao, poe-se o
-- `sub` da pessoa nas claims, chama-se a funcao antiga, chama-se a Central,
-- e comparam-se as respostas. Sem modelo pelo meio.
--
-- Isto e uma ferramenta de diagnostico que se faz passar por outra pessoa
-- para lhe fazer a pergunta. Fica sem execute para `public`: quem a corre e
-- o workflow de leitura, ligado como postgres.
-- =====================================================================

create or replace function public.shaar_divergencia_real(p_app text)
returns table (user_id bigint, code text, antigo boolean, central boolean)
language plpgsql
volatile
set search_path = public
as $$
declare
  r   record;
  v_a boolean;
  v_c boolean;
begin
  for r in
    select u.id, u.auth_user_id, sp.code
      from public.users u
      join public.shaar_gate_access g on g.user_id = u.id and g.app_code = p_app
      join public.shaar_permission sp on sp.app_code = p_app
     where u.active and not u.blocked
       and sp.active and sp.origem = 'herdado'
  loop
    -- Poe-se a identidade da pessoa nas claims do pedido. `true` = local a
    -- transaccao, portanto nao sobra nada para a chamada seguinte. Escrevem-se
    -- as duas formas porque `auth.uid()` le uma ou outra conforme a versao.
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

    if v_a is distinct from v_c then
      user_id := r.id;
      code    := r.code;
      antigo  := v_a;
      central := v_c;
      return next;
    end if;
  end loop;

  -- Repor com '{}' e nao com '': `current_setting(..., true)` devolve NULL
  -- quando nunca foi posta, mas devolve a cadeia vazia quando foi posta a
  -- vazio — e ''::jsonb levanta excepcao. Deixar '' aqui partia a proxima
  -- chamada a auth.uid() dentro da mesma transaccao.
  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);
end
$$;

comment on function public.shaar_divergencia_real(text) is
  'Compara a Central com a funcao antiga perguntando as duas, pessoa a pessoa '
  'e permissao a permissao, em vez de comparar com um modelo escrito a mao. '
  'So considera quem tem o portao aberto, porque e isso que shaar_pode exige. '
  'Diagnostico: faz-se passar por outra pessoa para lhe fazer a pergunta.';

revoke all on function public.shaar_divergencia_real(text) from public;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'divergencia real TETELESTAI: ' || count(*)::text
  from public.shaar_divergencia_real('TETELESTAI');

-- E quando ha, diz-se quais. Sem e-mails: isto corre em registos de CI.
select 'codigos divergentes: ' || coalesce(string_agg(distinct code, ', '), 'nenhum')
  from public.shaar_divergencia_real('TETELESTAI');

select 'divergencia modelada (a vista antiga): ' || count(*)::text
  from public.shaar_permissao_divergencias;
