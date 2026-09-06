-- =====================================================================
-- As 65 sao as esperadas. Agora fica escrito qual e a regra
-- =====================================================================
--
-- A medicao respondeu:
--
--   pares avaliados 1400 | controlo 280 | total 65
--   perdia 0 | ganharia 65 | pessoas 3 | dessas sem auth_user_id 3
--
-- O controlo em 280 diz que a impersonacao funciona — sem isso o resto nao
-- valeria nada. `perdia` em zero diz que ninguem perde acesso. E as 65 sao
-- todas de tres pessoas sem `auth_user_id`: aquelas para quem o TETELESTAI
-- estava partido porque o codigo antigo so olhava para esse campo, e que ja
-- ficaram com revisao aberta na migracao 003.
--
-- Ou seja: nao ha defeito. Mas "verifiquei uma vez e estava bem" nao e uma
-- garantia, e a regra certa nao e "zero divergencias" — e mais fina:
--
--   · ninguem pode PERDER acesso por causa da troca. Nunca. `perdia` = 0.
--   · alguem pode GANHAR, mas so se essa pessoa tiver uma revisao aberta,
--     ou seja, so se houver alguem a quem foi pedido que confirme.
--   · e a medicao so vale se o controlo for positivo.
--
-- Ganhar acesso sem que ninguem tenha sido chamado a decidir e exactamente
-- o que este projecto existe para impedir. Passa a ser um numero.
-- =====================================================================

drop function if exists public.shaar_divergencia_real_resumo(text);

create function public.shaar_divergencia_real_resumo(p_app text)
returns table (
  total              bigint,
  perdia             bigint,   -- antigo verdadeiro, Central falso: proibido
  ganharia           bigint,   -- antigo falso, Central verdadeiro
  ganha_sem_revisao  bigint,   -- ganha e ninguem foi chamado a decidir: proibido
  pessoas            bigint,
  pessoas_sem_auth   bigint,
  controlo_positivos bigint,   -- se for zero, a medicao nao vale nada
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
  v_quem_sem bigint[] := '{}';
begin
  total := 0; perdia := 0; ganharia := 0; ganha_sem_revisao := 0;
  controlo_positivos := 0; pares_avaliados := 0;

  for r in
    select u.id, u.auth_user_id, sp.code,
           exists (select 1 from public.shaar_permission_revisao rv
                    where rv.user_id = u.id and rv.resolvido_em is null) as tem_revisao
      from public.users u
      join public.shaar_gate_access g on g.user_id = u.id and g.app_code = p_app
      join public.shaar_permission sp on sp.app_code = p_app
     where u.active and not u.blocked
       and sp.active and sp.origem = 'herdado'
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
        perdia := perdia + 1;
      else
        ganharia := ganharia + 1;
        if not r.tem_revisao then
          ganha_sem_revisao := ganha_sem_revisao + 1;
        end if;
      end if;
      if not (r.id = any (v_quem)) then
        v_quem := v_quem || r.id;
        if r.auth_user_id is null then
          v_quem_sem := v_quem_sem || r.id;
        end if;
      end if;
    end if;
  end loop;

  perform set_config('request.jwt.claim.sub', '',   true);
  perform set_config('request.jwt.claims',    '{}', true);

  pessoas          := coalesce(array_length(v_quem, 1), 0);
  pessoas_sem_auth := coalesce(array_length(v_quem_sem, 1), 0);

  return next;
end
$$;

comment on function public.shaar_divergencia_real_resumo(text) is
  'A regra da troca, em numeros: perdia tem de ser zero (ninguem perde '
  'acesso), ganha_sem_revisao tem de ser zero (ninguem ganha sem que alguem '
  'tenha sido chamado a decidir), e controlo_positivos tem de ser maior que '
  'zero (senao a impersonacao nao funciona e a medicao nao vale nada).';

revoke all on function public.shaar_divergencia_real_resumo(text) from public;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'controlo: '            || r.controlo_positivos::text ||
       ' | perdia: '           || r.perdia            ::text ||
       ' | ganha sem revisao: '|| r.ganha_sem_revisao ::text ||
       ' | ganha com revisao: '|| (r.ganharia - r.ganha_sem_revisao)::text ||
       ' | pessoas: '          || r.pessoas           ::text
  from public.shaar_divergencia_real_resumo('TETELESTAI') r;
