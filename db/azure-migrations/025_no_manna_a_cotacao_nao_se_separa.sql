-- =====================================================================
-- No MANNA, conduzir a cotação e aprová-la é o desenho
-- =====================================================================
--
-- O dono: «no MANNA quem conduz a cotação pode aprovar também».
--
-- Mesmo tratamento que o TETELESTAI levou na 023, e pela mesma razão: o par
-- declarado avisava, no momento da concessão, de uma acumulação que é o
-- funcionamento normal. Era o último par de detenção de pé além do da própria
-- Central, e sustentava sozinho as 20 revisões de conflito que restavam.
--
-- O ramo do rasto fica. Continua a responder «quem aprovou a cotação que
-- conduziu, e quando» — pergunta legítima de auditoria mesmo quando a resposta
-- não é uma violação. Passa a estar marcado como esperado, com o motivo e a
-- data da decisão à frente.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. O PAR SAI
-- ---------------------------------------------------------------------
delete from public.shaar_permission_conflito
 where (app_a, code_a, app_b, code_b)
     = ('MANNA', 'quotation.manage', 'MANNA', 'quotation.approve');

update public.shaar_permission_revisao r
   set resolvido_em = now(),
       decisao = 'Fechado sem decisao: no MANNA quem conduz a cotacao pode '
              || 'aprova-la, por desenho da aplicacao. O par avisava de uma '
              || 'acumulacao que e o funcionamento normal. Decidido pelo dono '
              || 'em 06/09/2026.'
 where r.gatilho = 'conflito'
   and r.resolvido_em is null
   and r.detalhe ->> 'par' = 'MANNA/quotation.manage + MANNA/quotation.approve';


-- ---------------------------------------------------------------------
-- 2. A EXCEPCAO FICA ESCRITA
-- ---------------------------------------------------------------------
insert into public.shaar_segregacao_excepcao (app_code, regra, criterio, motivo, decidido_por)
values ('MANNA', 'conduziu a cotacao e aprovou-a', 'todos',
        'O MANNA nao separa conduzir a cotacao de aprova-la: quem conduz pode '
        'aprovar, e isso vale para qualquer pessoa com as duas permissoes. Nao e '
        'uma isencao dada a alguem — e a ausencia declarada da regra nesta parte '
        'da aplicacao.',
        'o dono, 06/09/2026')
on conflict (app_code, regra, criterio) do update
  set motivo = excluded.motivo, decidido_por = excluded.decidido_por;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'pares declarados: ' || count(*)::text
       || coalesce(' — ' || string_agg(app_a || '/' || code_a || ' + ' || code_b, '; '
                                       order by app_a, code_a), '')
  from public.shaar_permission_conflito;

select 'avisos de conflito ainda abertos: ' || count(*)::text
  from public.shaar_permission_revisao
 where gatilho = 'conflito' and resolvido_em is null;

select 'RASTO ' || app_code || ' / ' || regra || ': ' || ocorrencias::text
       || ' actos — ' || esperados::text || ' esperados, '
       || por_explicar::text || ' por explicar'
  from public.shaar_segregacao_resumo();

do $mig$
declare v_falta int;
begin
  select coalesce(sum(por_explicar), 0) into v_falta
    from public.shaar_segregacao_resumo()
   where app_code = 'MANNA' and regra = 'conduziu a cotacao e aprovou-a';
  if v_falta <> 0 then
    raise exception
      'ficaram % actos da cotacao do MANNA por explicar depois de declarar a '
      'excepcao. O criterio nao esta a ser lido — nada disto entra.', v_falta;
  end if;
  raise notice 'cotacao do MANNA: nenhum acto por explicar';
end
$mig$;

select 'ACTOS POR EXPLICAR NO TOTAL: ' || coalesce(sum(por_explicar), 0)::text
  from public.shaar_segregacao_resumo();
