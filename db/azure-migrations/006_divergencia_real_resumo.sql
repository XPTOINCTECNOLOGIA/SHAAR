-- =====================================================================
-- 65 divergencias reais. Onde, em que sentido, e sera que a medicao presta
-- =====================================================================
--
-- `shaar_divergencia_real` devolveu 65 discordancias no TETELESTAI, em 35
-- codigos, enquanto a vista modelada continua a dizer zero. Uma das duas
-- esta errada, e o numero cru nao chega para saber qual.
--
-- Ha tres explicacoes possiveis e sao muito diferentes entre si:
--
--   1. As quatro pessoas sem `auth_user_id`. Para elas a funcao antiga ve
--      `auth.uid()` nulo e responde sempre falso; a Central reconhece-as
--      pelo e-mail. Nesse caso as 65 sao todas no sentido "antigo=falso,
--      central=verdadeiro", todas dessas quatro pessoas, e nao sao um
--      defeito — sao a correccao que ja estava registada em revisao.
--
--   2. A minha impersonacao nao funciona. Se `auth.uid()` nao ler as GUC
--      que eu ponho, a funcao antiga responde falso a toda a gente e as
--      "divergencias" sao um artefacto da medicao. Seria o pior dos casos:
--      uma ferramenta de verificacao que da alarme falso e pior do que
--      nenhuma, porque ensina a ignorar alarmes.
--
--   3. Ha gente a ganhar ou a perder acesso a serio.
--
-- O resumo abaixo separa as tres. A coluna que decide e `controlo`: conta
-- as respostas VERDADEIRAS que a funcao antiga deu a pessoas COM
-- `auth_user_id`. Se for zero, a impersonacao nao esta a funcionar e todo o
-- resto desta medicao e para deitar fora.
-- =====================================================================

create or replace function public.shaar_divergencia_real_resumo(p_app text)
returns table (
  total              bigint,
  perdia             bigint,   -- antigo verdadeiro, Central falso
  ganharia           bigint,   -- antigo falso, Central verdadeiro
  pessoas            bigint,
  pessoas_sem_auth   bigint,
  controlo_positivos bigint,   -- respostas TRUE da funcao antiga a quem tem auth_user_id
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
  total := 0; perdia := 0; ganharia := 0;
  controlo_positivos := 0; pares_avaliados := 0;

  for r in
    select u.id, u.auth_user_id, sp.code
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
  'Resume shaar_divergencia_real: em que sentido, de quantas pessoas, e '
  'quantas delas sem auth_user_id. controlo_positivos conta as respostas '
  'verdadeiras que a funcao antiga deu a quem TEM auth_user_id: se for zero, '
  'a impersonacao nao funciona e a medicao toda nao vale nada.';

revoke all on function public.shaar_divergencia_real_resumo(text) from public;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'pares avaliados: '     || r.pares_avaliados    ::text ||
       ' | controlo (TRUE do antigo a quem tem auth): ' || r.controlo_positivos::text ||
       ' | total divergente: ' || r.total              ::text ||
       ' | perdia: '           || r.perdia             ::text ||
       ' | ganharia: '         || r.ganharia           ::text ||
       ' | pessoas: '          || r.pessoas            ::text ||
       ' | dessas sem auth_user_id: ' || r.pessoas_sem_auth::text
  from public.shaar_divergencia_real_resumo('TETELESTAI') r;
