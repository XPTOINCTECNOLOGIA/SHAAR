-- =====================================================================
-- O ofício, e a excepção escrita sobre o ofício
-- =====================================================================
--
-- O dono confirmou a regra: o CEO pode aprovar a própria operação estratégica.
-- Ao ir escrevê-la, a base respondeu duas coisas que a mudam:
--
--   · não existe cargo CEO. Há CFO, COO, CTO, CGO, CISO, CLO, CMO, CSCO e
--     CONSELHEIRO — o ofício de quem dirige a empresa não está na tabela.
--   · quem criou e aprovou as três operações estratégicas do rasto é o
--     CONSELHEIRO, não o CEO. São pessoas diferentes e regras diferentes.
--
-- Este ficheiro trata as duas em separado, e de propósito não estica a regra
-- do CEO para cobrir actos que não são do CEO. Se a excepção fosse escrita
-- larga o suficiente para os apanhar, deixava de ser uma excepção e passava a
-- ser a ausência da regra.
--
-- E não se escreve sobre o perfil. «Quem tem SUPER ADMIN aprova a própria
-- operação» daria a isenção a qualquer pessoa que viesse a receber esse
-- perfil, em silêncio — o mesmo defeito da regra do CFO que a migração 002
-- passou a limpo. SUPER ADMIN é uma condição técnica; CEO é um ofício.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. O CARGO PASSA A EXISTIR
-- ---------------------------------------------------------------------
insert into public.positions (name, description, active)
select 'CEO', 'Direccao executiva da empresa', true
 where not exists (select 1 from public.positions where upper(name) = 'CEO');


-- ---------------------------------------------------------------------
-- 2. O CARGO FICA ATRIBUIDO, E SO SE A CORRESPONDENCIA FOR INEQUIVOCA
-- ---------------------------------------------------------------------
-- O dono disse «Claudio e o CEO». Um primeiro nome nao e uma chave, e este
-- ecossistema ja teve contas duplicadas para a mesma pessoa. Por isso a
-- atribuicao so acontece se houver exactamente UMA pessoa activa chamada
-- Claudio; havendo mais, o ficheiro rebenta e a escolha fica para gente.
do $mig$
declare
  v_n      int;
  v_quem   text;
  v_id     bigint;
  v_antigo text;
  v_cargo  bigint;
begin
  select count(*), string_agg(u.email::text, ', ')
    into v_n, v_quem
    from public.users u
   where u.active
     and (lower(u.full_name) like '%claudio%' or lower(u.full_name) like '%cláudio%');

  if v_n <> 1 then
    raise exception
      'esperava exactamente uma pessoa activa chamada Claudio e encontrei %: %. '
      'A atribuicao do cargo de CEO nao se faz por adivinhacao — resolver a mao.',
      v_n, coalesce(v_quem, 'nenhuma');
  end if;

  select u.id, pos.name into v_id, v_antigo
    from public.users u
    left join public.positions pos on pos.id = u.position_id
   where u.active
     and (lower(u.full_name) like '%claudio%' or lower(u.full_name) like '%cláudio%');

  -- A vista do modelo antigo ainda tem o ramo do cargo CFO: quem ocupa esse
  -- cargo exerce o perfil FINANCEIRO. Trocar o cargo a essa pessoa retirava
  -- esse ramo e a divergencia — que tem de ser zero — saltava. Se for o caso,
  -- este ficheiro para e a troca decide-se com esse facto a frente.
  if upper(coalesce(v_antigo, '')) = 'CFO' then
    raise exception
      'a pessoa a quem ia atribuir o cargo de CEO ocupa hoje o cargo de CFO, e '
      'a vista do modelo antigo depende desse cargo. Trocar assim faria a '
      'divergencia deixar de ser zero. Decidir primeiro o que fica do ramo CFO.';
  end if;

  select id into v_cargo from public.positions where upper(name) = 'CEO';

  update public.users set position_id = v_cargo where id = v_id;

  -- Um cargo que muda de mao e uma decisao, e fica registada. Se havia cargo
  -- antes, o que estava la fica escrito: quem ler daqui a um ano precisa de
  -- saber o que foi substituido, e nao so o que ficou.
  insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
  select v_id, null, 'migracao',
         jsonb_build_object(
           'nota', 'Cargo de CEO atribuido. O oficio passou a existir na tabela '
                || 'de cargos para que as regras assentem no oficio e nao na pessoa.',
           'cargo_anterior', coalesce(v_antigo, '(sem cargo)'),
           'decisao', 'do dono, 06/09/2026')
   where not exists (
     select 1 from public.shaar_permission_revisao r
      where r.user_id = v_id and r.gatilho = 'migracao'
        and r.detalhe ->> 'decisao' = 'do dono, 06/09/2026');

  raise notice 'CEO atribuido (cargo anterior: %)', coalesce(v_antigo, 'nenhum');
end
$mig$;


-- ---------------------------------------------------------------------
-- 3. O CONSELHEIRO TAMBEM PASSA A TER O SEU OFICIO ESCRITO
-- ---------------------------------------------------------------------
-- Quem dirige e quem aconselha nao tinham cargo nenhum na Central. Isso e um
-- buraco mais largo do que esta excepcao: qualquer regra futura assente em
-- oficio era cega para eles.
update public.users u
   set position_id = (select id from public.positions where upper(name) = 'CONSELHEIRO')
 where lower(u.email) = 'jose.filho@xptoinc.com.br'
   and u.active
   and u.position_id is null
   and exists (select 1 from public.positions where upper(name) = 'CONSELHEIRO');


-- ---------------------------------------------------------------------
-- 4. O MECANISMO: EXCEPCAO DECLARADA, ACTO CONTINUA A VISTA
-- ---------------------------------------------------------------------
-- A excepcao nao apaga a linha do rasto. Marca-a como esperada e diz porque.
-- Apagar esconderia o dia em que o mesmo padrao aparecesse noutra pessoa, que
-- e precisamente o dia em que se quer ver.
create table if not exists public.shaar_segregacao_excepcao (
  app_code     text not null,
  regra        text not null,
  criterio     text not null,
  motivo       text not null,
  decidido_por text not null,
  desde        timestamptz not null default now(),
  primary key (app_code, regra, criterio)
);

comment on table public.shaar_segregacao_excepcao is
  'Casos em que a mesma pessoa assinar os dois passos e o desenho pretendido, '
  'e nao um achado. O criterio e uma propriedade que a Central sabe ler — hoje '
  'apenas cargo:<NOME> — para a excepcao acompanhar o oficio e nao a pessoa.';

-- Le o criterio. Falha FECHADO: um criterio que esta funcao nao saiba ler nao
-- isenta ninguem. E a mesma regra do escopo — dimensao ausente nega.
create or replace function public.shaar_excepcao_aplica(p_criterio text, p_user_id bigint)
returns boolean
language sql stable security definer set search_path = public as $fn$
  select case
    when p_criterio like 'cargo:%' then exists (
      select 1
        from public.users u
        join public.positions p on p.id = u.position_id and p.active
       where u.id = p_user_id
         and upper(p.name) = upper(substring(p_criterio from 7)))
    else false
  end;
$fn$;


-- ---------------------------------------------------------------------
-- 5. A VISTA PASSA A DIZER SE O ACTO E ESPERADO
-- ---------------------------------------------------------------------
create or replace view public.shaar_segregacao_no_rasto as
with actos as (
  select 'MANNA'::text                       as app_code,
         'parecer tecnico e decisao'::text   as regra,
         d.decided_by                        as user_id,
         'processo ' || d.process_id::text   as objecto,
         d.decided_at                        as quando
    from public.manna_purchase_analysis_decisions d
    join public.manna_technical_opinions o on o.id = d.technical_opinion_id
   where o.authored_by = d.decided_by
  union all
  select 'MANNA', 'conduziu a cotacao e aprovou-a',
         a.decided_by, 'rodada ' || a.round_id::text, a.decided_at
    from public.manna_quotation_approvals a
    join public.manna_quotation_rounds r on r.id = a.round_id
   where a.decided_by = r.created_by or a.decided_by = r.submitted_by
  union all
  select 'MANNA', 'anuencia e liquidacao',
         s.settled_by, 'pagamento ' || s.payment_id::text, s.settled_at
    from public.manna_payment_settlements s
    join public.manna_payment_consents c on c.id = s.consent_id
   where c.consented_by = s.settled_by
  union all
  select 'JIREH', 'aprovou ou pagou o proprio reembolso',
         h.actor_id, 'reembolso ' || h.reimbursement_id::text, h.created_at
    from public.jireh_reimbursement_history h
    join public.jireh_reimbursements rb on rb.id = h.reimbursement_id
   where h.actor_id = rb.requester_id
     and h.to_status in ('PENDING_FINANCE', 'APPROVED_FOR_PAYMENT', 'PAID')
  union all
  select 'TETELESTAI', 'criou a operacao e aprovou-a',
         o.approved_by, 'operacao ' || o.id::text, o.approved_at
    from public.strategic_operations o
   where o.approved_by is not null and o.approved_by = o.creator_id
)
select a.app_code, a.regra, a.user_id, a.objecto, a.quando,
       (e.criterio is not null) as esperado,
       e.motivo                 as porque
  from actos a
  left join lateral (
    select x.criterio, x.motivo
      from public.shaar_segregacao_excepcao x
     where x.app_code = a.app_code
       and x.regra    = a.regra
       and public.shaar_excepcao_aplica(x.criterio, a.user_id)
     limit 1) e on true;


-- O resumo ganha as duas contagens. Muda o tipo de retorno, portanto tem de
-- cair primeiro — e por isso o grant e refeito a seguir.
drop function if exists public.shaar_segregacao_resumo();
create function public.shaar_segregacao_resumo()
returns table (app_code text, regra text, ocorrencias bigint,
               pessoas bigint, quem text, mais_recente timestamptz,
               esperados bigint, por_explicar bigint)
language sql stable security definer set search_path = public as $fn$
  select t.app_code, t.regra,
         count(*)                                          as ocorrencias,
         count(distinct t.user_id)                         as pessoas,
         string_agg(distinct coalesce(u.email::text, '(sem registo: ' || t.user_id || ')'), ', ') as quem,
         max(t.quando)                                     as mais_recente,
         count(*) filter (where t.esperado)                as esperados,
         count(*) filter (where not t.esperado)            as por_explicar
    from public.shaar_segregacao_no_rasto t
    left join public.users u on u.id = t.user_id
   group by t.app_code, t.regra
   order by 8 desc, 3 desc, 1, 2;
$fn$;

grant execute on function public.shaar_segregacao_resumo() to authenticated;


-- ---------------------------------------------------------------------
-- 6. A EXCEPCAO, E SO ESSA
-- ---------------------------------------------------------------------
-- Acima do CEO nao ha segunda assinatura: exigir outra pessoa para aprovar a
-- operacao estrategica seria inventar um superior que nao existe.
--
-- Isto NAO cobre os tres actos que estao hoje no rasto: quem os assinou foi o
-- conselheiro, e conselheiro nao e CEO. Ficam por explicar de proposito, para
-- serem decididos e nao absorvidos.
insert into public.shaar_segregacao_excepcao (app_code, regra, criterio, motivo, decidido_por)
values ('TETELESTAI', 'criou a operacao e aprovou-a', 'cargo:CEO',
        'Acima do CEO nao ha segunda assinatura. Exigir outra pessoa para aprovar '
        'a operacao estrategica seria inventar um superior que nao existe.',
        'o dono, 06/09/2026')
on conflict (app_code, regra, criterio) do update
  set motivo = excluded.motivo, decidido_por = excluded.decidido_por;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'cargo de ' || u.email || ': ' || coalesce(pos.name, '(sem cargo)')
  from public.users u
  left join public.positions pos on pos.id = u.position_id
 where lower(u.email) in ('jose.filho@xptoinc.com.br', 'claudio.haidamus@xptoinc.com.br')
 order by u.email;

select 'excepcoes declaradas: ' || count(*)::text from public.shaar_segregacao_excepcao;

select 'RASTO ' || app_code || ' / ' || regra || ': ' || ocorrencias::text
       || ' actos — ' || esperados::text || ' esperados, '
       || por_explicar::text || ' por explicar (' || quem || ')'
  from public.shaar_segregacao_resumo();

select 'ACTOS POR EXPLICAR: ' || coalesce(sum(por_explicar), 0)::text
  from public.shaar_segregacao_resumo();

-- A rede de seguranca. Mexer em cargos toca no modelo antigo por caminhos que
-- eu posso nao ter previsto; a divergencia e o numero que os apanha todos. Se
-- deixou de ser zero, este ficheiro nao entra — o pipeline corre em transaccao
-- unica e esta excepcao desfaz tudo.
do $mig$
declare v_div int;
begin
  select count(*) into v_div from public.shaar_permissao_divergencias;
  if v_div <> 0 then
    raise exception
      'a divergencia entre a Central e o modelo antigo passou a % depois de '
      'mexer nos cargos. Alguma regra assenta no cargo por um caminho que eu '
      'nao previ. Nada disto entra.', v_div;
  end if;
  raise notice 'divergencia continua zero';
end
$mig$;
