-- =====================================================================
-- Segregação de funções: medir actos, não permissões
-- =====================================================================
--
-- O dono apanhou o erro numa frase: «o utilizador pode ter a permissão mas a
-- regra de negócio supera a permissão». Fui ver o código das três aplicações
-- e ele tem razão em toda a linha.
--
-- O QUE EU TINHA FEITO
-- --------------------
-- Declarei sete pares de permissões e chamei conflito ao facto de alguém ter
-- os dois lados. Isso mede DETENÇÃO. Segregação de funções é sobre ACTOS: o
-- mesmo par de mãos nos dois passos do mesmo processo. As duas coisas não são
-- a mesma, e a diferença não é subtil — dos 76 avisos abertos, nenhum
-- demonstrava uma única violação.
--
-- O QUE O CÓDIGO DAS APLICAÇÕES DIZ
-- ---------------------------------
--   JIREH — a regra existe, escrita, e supera a permissão:
--     jireh_multilevel_workflow.sql:181   and r.requester_id <> me.id
--                                :693     and v_reimbursement.requester_id <> v_actor_id
--   Quem tem `create` e `approve_finance` aprova reembolsos DE OUTROS; o seu
--   está barrado pelo código. Os dois pares do JIREH não avisam de nada.
--
--   MANNA — dois dos meus pares citam códigos que a aplicação nunca pergunta:
--     `purchase-analysis.opine` não aparece uma única vez no repositório;
--     quem escreve o parecer passa por has_permission('purchase-analysis.decide')
--     (0003_manna_rpcs.sql:391). Opinar e decidir são a MESMA permissão.
--     `finance.consent` está listado pela auditoria do próprio MANNA
--     (0006_fix_manna_notify.sql:10) entre os «códigos de permissão
--     inexistentes no catálogo», corrigido para `finance.settle`; é
--     `finance.settle` que manna_consent_payment verifica (0003:576).
--
-- O QUE FICA
-- ---------
--   `quotation.manage + quotation.approve` (MANNA) e
--   `operation.create + operation.approve` (TETELESTAI) ficam declarados: são
--   duas verificações distintas e reais, e não encontrei no código guarda
--   nenhuma que impeça a mesma pessoa de fazer os dois passos. Aí, avisar na
--   concessão continua a dizer algo verdadeiro — «esta pessoa passa a poder
--   fazer os dois, e nada a impede». O par do SHAAR fica pela mesma razão.
--
-- E O QUE PASSA A EXISTIR
-- -----------------------
-- O rasto. As aplicações guardam quem fez cada acto — `authored_by`,
-- `decided_by`, `consented_by`, `settled_by`, `actor_id`, `creator_id`,
-- `approved_by` — e é aí que uma violação, se existir, está escrita. A vista
-- abaixo não infere nada: lê linhas que dizem que a mesma pessoa fez os dois
-- passos do mesmo processo.
--
-- Este ficheiro NÃO abre revisões pelo que a vista encontrar. Mede primeiro;
-- decidir o que fazer com os números é do dono, e com os números à frente.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. FORA OS PARES QUE NÃO CORRESPONDEM À APLICAÇÃO
-- ---------------------------------------------------------------------
delete from public.shaar_permission_conflito
 where (app_a, code_a, app_b, code_b) in (
   ('MANNA','purchase-analysis.opine','MANNA','purchase-analysis.decide'),
   ('MANNA','finance.consent','MANNA','finance.settle'),
   ('JIREH','reimbursements:create','JIREH','reimbursements:approve_finance'),
   ('JIREH','reimbursements:approve_manager','JIREH','reimbursements:approve_finance'));


-- ---------------------------------------------------------------------
-- 2. FECHAR OS AVISOS QUE ESSES PARES ABRIRAM
-- ---------------------------------------------------------------------
-- Ficam fechados com o motivo escrito, e não apagados: o histórico de que o
-- aviso existiu e por que razão deixou de valer é parte do que a Central
-- serve para guardar. `resolvido_por` fica nulo de propósito — não foi
-- ninguém que decidiu, foi a regra que se revelou errada.
update public.shaar_permission_revisao r
   set resolvido_em = now(),
       decisao = 'Fechado sem decisao: o par nao correspondia a aplicacao. '
              || 'Ou citava um codigo que a aplicacao nunca pergunta, ou o '
              || 'proprio codigo ja impede a combinacao nociva (JIREH: '
              || 'requester_id <> actor_id). Substituido pela verificacao no '
              || 'rasto — ver public.shaar_segregacao_no_rasto.'
 where r.gatilho = 'conflito'
   and r.resolvido_em is null
   and r.detalhe ->> 'par' in (
     'MANNA/purchase-analysis.opine + MANNA/purchase-analysis.decide',
     'MANNA/finance.consent + MANNA/finance.settle',
     'JIREH/reimbursements:create + JIREH/reimbursements:approve_finance',
     'JIREH/reimbursements:approve_manager + JIREH/reimbursements:approve_finance');


-- ---------------------------------------------------------------------
-- 3. O RASTO
-- ---------------------------------------------------------------------
-- Cada ramo é uma pergunta com resposta factual: a mesma pessoa assinou os
-- dois passos deste processo? Nenhum ramo lê permissões — se lesse, voltava a
-- medir detenção e a confirmar-se a si próprio.
create or replace view public.shaar_segregacao_no_rasto as
  -- MANNA: escreveu o parecer técnico e decidiu sobre ESSE parecer.
  -- A ligação é pelo technical_opinion_id que a decisão guarda, e não pelo
  -- processo: é o parecer decidido, não um parecer qualquer do processo.
  select 'MANNA'::text                                   as app_code,
         'parecer tecnico e decisao'::text               as regra,
         d.decided_by                                    as user_id,
         'processo ' || d.process_id::text               as objecto,
         d.decided_at                                    as quando
    from public.manna_purchase_analysis_decisions d
    join public.manna_technical_opinions o on o.id = d.technical_opinion_id
   where o.authored_by = d.decided_by

  union all
  -- MANNA: conduziu a rodada de cotacao (criou ou submeteu) e aprovou-a.
  select 'MANNA', 'conduziu a cotacao e aprovou-a',
         a.decided_by,
         'rodada ' || a.round_id::text,
         a.decided_at
    from public.manna_quotation_approvals a
    join public.manna_quotation_rounds r on r.id = a.round_id
   where a.decided_by = r.created_by
      or a.decided_by = r.submitted_by

  union all
  -- MANNA: deu a anuencia e liquidou o pagamento.
  select 'MANNA', 'anuencia e liquidacao',
         s.settled_by,
         'pagamento ' || s.payment_id::text,
         s.settled_at
    from public.manna_payment_settlements s
    join public.manna_payment_consents c on c.id = s.consent_id
   where c.consented_by = s.settled_by

  union all
  -- JIREH: moveu o proprio reembolso para um estado de aprovacao ou de
  -- pagamento. Submeter e cancelar o proprio pedido sao actos legitimos do
  -- requerente e por isso nao entram na lista.
  select 'JIREH', 'aprovou ou pagou o proprio reembolso',
         h.actor_id,
         'reembolso ' || h.reimbursement_id::text,
         h.created_at
    from public.jireh_reimbursement_history h
    join public.jireh_reimbursements rb on rb.id = h.reimbursement_id
   where h.actor_id = rb.requester_id
     and h.to_status in ('PENDING_FINANCE', 'APPROVED_FOR_PAYMENT', 'PAID')

  union all
  -- TETELESTAI: criou a operacao estrategica e aprovou-a. Aqui os dois actos
  -- vivem na mesma linha, o que torna a pergunta especialmente directa.
  select 'TETELESTAI', 'criou a operacao e aprovou-a',
         o.approved_by,
         'operacao ' || o.id::text,
         o.approved_at
    from public.strategic_operations o
   where o.approved_by is not null
     and o.approved_by = o.creator_id;

comment on view public.shaar_segregacao_no_rasto is
  'Segregacao de funcoes medida em ACTOS, no rasto que as aplicacoes guardam '
  '(authored_by, decided_by, consented_by, settled_by, actor_id, creator_id, '
  'approved_by). Substitui a verificacao por deteccao de permissoes, que media '
  'quem podia e nao quem fez. Uma linha aqui e um facto, nao um aviso.';


-- Resumo por regra, com nome de gente — para ler sem escrever SQL.
create or replace function public.shaar_segregacao_resumo()
returns table (app_code text, regra text, ocorrencias bigint,
               pessoas bigint, quem text, mais_recente timestamptz)
language sql stable security definer set search_path = public as $fn$
  select t.app_code, t.regra,
         count(*)                                  as ocorrencias,
         count(distinct t.user_id)                 as pessoas,
         string_agg(distinct coalesce(u.email::text, '(sem registo: ' || t.user_id || ')'),
                    ', ')                          as quem,
         max(t.quando)                             as mais_recente
    from public.shaar_segregacao_no_rasto t
    left join public.users u on u.id = t.user_id
   group by t.app_code, t.regra
   order by 3 desc, 1, 2;
$fn$;

grant execute on function public.shaar_segregacao_resumo() to authenticated;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'pares declarados: ' || count(*)::text
       || ' — ' || string_agg(app_a || '/' || code_a || ' + ' || code_b, '; ' order by app_a, code_a)
  from public.shaar_permission_conflito;

select 'avisos fechados por regra errada: ' || count(*)::text
  from public.shaar_permission_revisao
 where gatilho = 'conflito' and resolvido_em is not null
   and decisao like 'Fechado sem decisao: o par nao correspondia%';

select 'avisos de conflito ainda abertos: ' || count(*)::text
  from public.shaar_permission_revisao
 where gatilho = 'conflito' and resolvido_em is null;

select 'ACTOS NO RASTO: ' || coalesce(sum(ocorrencias), 0)::text
       || ' em ' || count(*)::text || ' regras'
  from public.shaar_segregacao_resumo();

select 'RASTO ' || app_code || ' / ' || regra || ': '
       || ocorrencias::text || ' actos, ' || pessoas::text || ' pessoa(s) — ' || quem
  from public.shaar_segregacao_resumo();
