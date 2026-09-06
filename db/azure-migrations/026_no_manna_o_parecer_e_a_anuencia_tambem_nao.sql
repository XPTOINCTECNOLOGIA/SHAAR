-- =====================================================================
-- No MANNA, o parecer e a anuência também não se separam
-- =====================================================================
--
-- O dono: «no MANNA parecer/decisão e anuência/liquidação também não separam».
--
-- Confirma o que o código já dizia, e vale a pena deixar escrito porque é a
-- razão pela qual estas duas regras nunca poderiam ter sido impostas pela
-- Central:
--
--   manna_record_technical_opinion  verifica  has_permission('purchase-analysis.decide')
--   manna_decide_analysis           verifica  has_permission('purchase-analysis.decide')
--
--   manna_consent_payment           verifica  has_permission('finance.settle')
--   manna_settle_payment            verifica  has_permission('finance.settle')
--
-- Escrever o parecer e decidir sobre ele são gated pela MESMA permissão. Dar a
-- anuência e liquidar, idem. Não são duas autoridades: é uma. A aplicação não
-- distingue os dois actos ao nível da permissão, e portanto nenhuma concessão
-- da Central — feita como for — conseguiria exigir duas pessoas.
--
-- O que separa os passos no MANNA é a máquina de estados (o processo tem de
-- passar por um estado antes do outro, uma vez cada) e o rasto (`authored_by`,
-- `decided_by`, `consented_by`, `settled_by`). Separa os MOMENTOS, não as MÃOS.
--
-- Depois deste ficheiro, os únicos actos por explicar no rasto são os seis do
-- JIREH — o requerente a mover o próprio reembolso, em 20/08, dois dias antes
-- de o guarda `requester_id <> actor_id` existir. Ficam por explicar de
-- propósito: são os únicos que a aplicação de hoje recusaria.
-- =====================================================================

insert into public.shaar_segregacao_excepcao (app_code, regra, criterio, motivo, decidido_por)
values
 ('MANNA', 'parecer tecnico e decisao', 'todos',
  'O MANNA nao separa escrever o parecer tecnico de decidir sobre ele: os dois '
  'actos passam pela MESMA permissao (purchase-analysis.decide), portanto nao '
  'sao duas autoridades. O que os separa e a maquina de estados e o rasto — os '
  'momentos, nao as maos.',
  'o dono, 06/09/2026'),
 ('MANNA', 'anuencia e liquidacao', 'todos',
  'O MANNA nao separa dar a anuencia de liquidar o pagamento: os dois actos '
  'passam pela MESMA permissao (finance.settle). Mesma razao que o parecer.',
  'o dono, 06/09/2026')
on conflict (app_code, regra, criterio) do update
  set motivo = excluded.motivo, decidido_por = excluded.decidido_por;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'excepcoes declaradas: ' || count(*)::text
  from public.shaar_segregacao_excepcao;

select 'RASTO ' || app_code || ' / ' || regra || ': ' || ocorrencias::text
       || ' actos — ' || esperados::text || ' esperados, '
       || por_explicar::text || ' por explicar'
  from public.shaar_segregacao_resumo();

-- Os seis do JIREH tem de continuar por explicar. Se este ficheiro os apanhasse
-- por engano — um criterio largo de mais, uma regra com o nome trocado — o
-- unico achado verdadeiro do sistema desaparecia em silencio.
do $mig$
declare v_manna int; v_jireh int;
begin
  select coalesce(sum(por_explicar), 0) into v_manna
    from public.shaar_segregacao_resumo() where app_code = 'MANNA';
  if v_manna <> 0 then
    raise exception 'ficaram % actos do MANNA por explicar; o criterio nao esta a ser lido', v_manna;
  end if;

  select coalesce(sum(por_explicar), 0) into v_jireh
    from public.shaar_segregacao_resumo() where app_code = 'JIREH';
  if v_jireh <> 6 then
    raise exception
      'os actos do JIREH por explicar passaram de 6 para %. Este ficheiro nao '
      'devia toca-los: sao os unicos que a aplicacao de hoje recusaria, e '
      'perde-los de vista era perder o unico achado verdadeiro.', v_jireh;
  end if;
  raise notice 'MANNA sem actos por explicar; os 6 do JIREH intactos';
end
$mig$;

select 'ACTOS POR EXPLICAR NO TOTAL: ' || coalesce(sum(por_explicar), 0)::text
  from public.shaar_segregacao_resumo();
