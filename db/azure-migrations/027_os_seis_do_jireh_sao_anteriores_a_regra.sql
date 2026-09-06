-- =====================================================================
-- Os seis do JIREH: esperados por serem anteriores à regra, e só por isso
-- =====================================================================
--
-- O dono: «os 6 do JIREH foram testes, pode marcar como esperados».
--
-- Marca-se — mas não da maneira mais simples, e a diferença importa.
--
-- O CAMINHO QUE NÃO SE SEGUE
-- --------------------------
-- Declarar `todos` para esta regra, como se fez no MANNA e no TETELESTAI, diria
-- que no JIREH o requerente pode aprovar o próprio reembolso. É falso: a
-- aplicação recusa isso, hoje, em dois sítios do código
-- (`requester_id <> actor_id`, jireh_multilevel_workflow.sql:181 e :693). Uma
-- excepção assim marcaria como esperada qualquer violação futura — e esta é a
-- única regra do ecossistema que tem mesmo um guarda a impô-la.
--
-- Declarar por pessoa também não: isentava o conselheiro desta regra para
-- sempre, e a razão pela qual estes seis actos são inofensivos não tem nada a
-- ver com quem os fez.
--
-- O QUE ELES SÃO
-- --------------
-- Reembolsos 1 e 2 — os dois primeiros do sistema — em 20/08, entre as 23:11 e
-- as 23:12, com um minuto de intervalo. O guarda entrou na migração
-- 20260822020000, dois dias depois. São de quando a regra ainda não existia, e
-- desde que passou a existir nunca mais houve um.
--
-- Por isso o critério é a DATA, não a pessoa nem a regra. Fecha-se sozinho:
-- um acto igual amanhã não é apanhado por ele, e volta a aparecer por explicar
-- como deve.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. O CRITERIO PASSA A PODER OLHAR PARA QUANDO O ACTO ACONTECEU
-- ---------------------------------------------------------------------
-- Continua a falhar FECHADO: um criterio que a funcao nao saiba ler, ou uma
-- data mal escrita, nao isenta ninguem. A guarda da expressao regular existe
-- para que o cast nunca rebente com texto que nao seja uma data.
create or replace function public.shaar_excepcao_aplica(
  p_criterio text, p_user_id bigint, p_quando timestamptz
) returns boolean
language sql stable security definer set search_path = public as $fn$
  select case
    when p_criterio = 'todos' then true
    when p_criterio like 'cargo:%' then exists (
      select 1
        from public.users u
        join public.positions p on p.id = u.position_id and p.active
       where u.id = p_user_id
         and upper(p.name) = upper(substring(p_criterio from 7)))
    when p_criterio ~ '^antes_de:\d{4}-\d{2}-\d{2}$' then
      p_quando is not null
      and p_quando < (substring(p_criterio from 10))::timestamptz
    else false
  end;
$fn$;

grant execute on function public.shaar_excepcao_aplica(text, bigint, timestamptz) to authenticated;

comment on table public.shaar_segregacao_excepcao is
  'Casos em que a mesma pessoa assinar os dois passos e o desenho pretendido, ou '
  'deixou de poder acontecer. Criterios que a Central sabe ler: `todos` (a '
  'aplicacao nao separa os dois passos para ninguem), `cargo:<NOME>` (so quem '
  'ocupa aquele oficio) e `antes_de:AAAA-MM-DD` (actos anteriores a data em que '
  'a regra passou a ser imposta). Um criterio que a funcao nao saiba ler nao '
  'isenta ninguem — falha fechado.';


-- ---------------------------------------------------------------------
-- 2. A VISTA PASSA A DAR-LHE A DATA DO ACTO
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
       and public.shaar_excepcao_aplica(x.criterio, a.user_id, a.quando)
     limit 1) e on true;

drop function if exists public.shaar_excepcao_aplica(text, bigint);


-- ---------------------------------------------------------------------
-- 3. A EXCEPCAO, DATADA
-- ---------------------------------------------------------------------
insert into public.shaar_segregacao_excepcao (app_code, regra, criterio, motivo, decidido_por)
values ('JIREH', 'aprovou ou pagou o proprio reembolso', 'antes_de:2026-08-22',
        'Reembolsos 1 e 2, os dois primeiros do sistema, em 20/08 entre as 23:11 '
        'e as 23:12 — testes de quem estava a construir. O guarda que impede o '
        'requerente de aprovar o proprio reembolso entrou dois dias depois '
        '(migracao 20260822020000) e desde entao nunca mais houve um. A regra '
        'EXISTE e e imposta pelo codigo: esta excepcao nao a levanta, apenas diz '
        'que estes actos sao anteriores a ela. Um acto igual amanha volta a '
        'aparecer por explicar.',
        'o dono, 06/09/2026')
on conflict (app_code, regra, criterio) do update
  set motivo = excluded.motivo, decidido_por = excluded.decidido_por;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'RASTO ' || app_code || ' / ' || regra || ': ' || ocorrencias::text
       || ' actos — ' || esperados::text || ' esperados, '
       || por_explicar::text || ' por explicar'
  from public.shaar_segregacao_resumo();

select 'ACTOS POR EXPLICAR NO TOTAL: ' || coalesce(sum(por_explicar), 0)::text
  from public.shaar_segregacao_resumo();

-- A prova de que o criterio se fecha sozinho. Se um acto de HOJE fosse apanhado
-- por «antes_de:2026-08-22», a excepcao nao era datada — era um cheque em
-- branco, e o unico guarda verdadeiro do ecossistema ficava cego.
do $mig$
declare
  v_id     bigint;
  v_antigo boolean;
  v_hoje   boolean;
  v_falta  int;
begin
  select user_id into v_id
    from public.shaar_segregacao_no_rasto
   where app_code = 'JIREH' limit 1;

  v_antigo := public.shaar_excepcao_aplica('antes_de:2026-08-22', v_id, '2026-08-20 23:11'::timestamptz);
  v_hoje   := public.shaar_excepcao_aplica('antes_de:2026-08-22', v_id, now());

  if not v_antigo then
    raise exception 'o criterio datado nao apanha um acto de 20/08; algo esta mal lido';
  end if;
  if v_hoje then
    raise exception
      'o criterio datado apanha um acto de HOJE. Nao e uma excepcao datada, e um '
      'cheque em branco — e o unico guarda verdadeiro do ecossistema ficava cego.';
  end if;

  select coalesce(sum(por_explicar), 0) into v_falta
    from public.shaar_segregacao_resumo();
  if v_falta <> 0 then
    raise exception 'ficaram % actos por explicar quando deviam ser zero', v_falta;
  end if;

  raise notice 'criterio datado confere: apanha 20/08, nao apanha hoje';
end
$mig$;
