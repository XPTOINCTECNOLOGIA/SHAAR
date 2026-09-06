-- =====================================================================
-- No TETELESTAI, criar e aprovar a mesma operação é o desenho
-- =====================================================================
--
-- O dono: «qualquer um que pode criar pode aprovar operação».
--
-- Isso responde à pergunta que ficou em aberto, e responde-a mais larga do que
-- eu tinha suposto. Eu escrevi a excepção sobre o cargo de CEO, a pensar que
-- acima dele não há segunda assinatura. Mas a regra não é sobre o CEO: no
-- TETELESTAI não existe separação entre propor e aprovar, para ninguém. Quem
-- tem as duas permissões faz os dois passos, e é assim que a aplicação foi
-- desenhada — `can_approve_operation()` é só a permissão, sem verificação de
-- criador, e não é um esquecimento.
--
-- Duas coisas minhas caem com isto:
--
--   · a excepção `cargo:CEO` é estreita demais. Deixaria três actos do
--     conselheiro por explicar para sempre, e explicá-los um a um seria
--     transformar uma regra em vinte decisões.
--
--   · o par declarado `operation.create + operation.approve` avisa, na
--     concessão, de uma acumulação que é o funcionamento normal. Sai, como
--     saíram os quatro da 021, e pela mesma razão: um aviso que nunca
--     corresponde a nada ensina a ignorar avisos.
--
-- O QUE NÃO CAI, e é de propósito: o ramo do rasto continua a contar. Os actos
-- ficam registados e visíveis, marcados como esperados e com o motivo à frente.
-- Apagar o ramo dava um número mais bonito e perdia a resposta à pergunta «quem
-- aprovou a própria operação, e quando» — que continua a ser uma pergunta
-- legítima de auditoria mesmo quando a resposta não é uma violação.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. O CRITERIO `todos`
-- ---------------------------------------------------------------------
-- Uma excepcao que vale para toda a gente e diferente de nao haver regra: fica
-- escrita, datada e assinada. Quem ler daqui a um ano ve que isto foi decidido
-- e por quem, em vez de encontrar um silencio e ter de adivinhar.
create or replace function public.shaar_excepcao_aplica(p_criterio text, p_user_id bigint)
returns boolean
language sql stable security definer set search_path = public as $fn$
  select case
    when p_criterio = 'todos' then true
    when p_criterio like 'cargo:%' then exists (
      select 1
        from public.users u
        join public.positions p on p.id = u.position_id and p.active
       where u.id = p_user_id
         and upper(p.name) = upper(substring(p_criterio from 7)))
    else false
  end;
$fn$;

comment on table public.shaar_segregacao_excepcao is
  'Casos em que a mesma pessoa assinar os dois passos e o desenho pretendido, e '
  'nao um achado. O criterio e uma propriedade que a Central sabe ler: `todos` '
  '(a aplicacao nao separa os dois passos para ninguem) ou `cargo:<NOME>` (so '
  'quem ocupa aquele oficio). Um criterio que a funcao nao saiba ler nao isenta '
  'ninguem — falha fechado.';


-- ---------------------------------------------------------------------
-- 2. A EXCEPCAO PASSA A SER A REGRA DA APLICACAO
-- ---------------------------------------------------------------------
delete from public.shaar_segregacao_excepcao
 where app_code = 'TETELESTAI'
   and regra    = 'criou a operacao e aprovou-a'
   and criterio = 'cargo:CEO';

insert into public.shaar_segregacao_excepcao (app_code, regra, criterio, motivo, decidido_por)
values ('TETELESTAI', 'criou a operacao e aprovou-a', 'todos',
        'O TETELESTAI nao separa propor de aprovar: quem pode criar pode aprovar, '
        'e isso vale para qualquer pessoa com as duas permissoes. Nao e uma '
        'isencao dada a alguem — e a ausencia declarada da regra nesta aplicacao.',
        'o dono, 06/09/2026')
on conflict (app_code, regra, criterio) do update
  set motivo = excluded.motivo, decidido_por = excluded.decidido_por;


-- ---------------------------------------------------------------------
-- 3. O PAR DECLARADO SAI
-- ---------------------------------------------------------------------
delete from public.shaar_permission_conflito
 where (app_a, code_a, app_b, code_b)
     = ('TETELESTAI', 'operation.create', 'TETELESTAI', 'operation.approve');

update public.shaar_permission_revisao r
   set resolvido_em = now(),
       decisao = 'Fechado sem decisao: no TETELESTAI quem pode criar pode aprovar, '
              || 'por desenho da aplicacao. O par avisava de uma acumulacao que e o '
              || 'funcionamento normal. Decidido pelo dono em 06/09/2026.'
 where r.gatilho = 'conflito'
   and r.resolvido_em is null
   and r.detalhe ->> 'par' = 'TETELESTAI/operation.create + TETELESTAI/operation.approve';


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

-- Os tres actos do TETELESTAI tem de passar todos a esperados. Se algum ficar
-- por explicar, o criterio nao esta a ser lido e o ficheiro nao entra.
do $mig$
declare v_falta int;
begin
  select coalesce(sum(por_explicar), 0) into v_falta
    from public.shaar_segregacao_resumo()
   where app_code = 'TETELESTAI';
  if v_falta <> 0 then
    raise exception
      'ficaram % actos do TETELESTAI por explicar depois de declarar a excepcao. '
      'O criterio nao esta a ser lido — nada disto entra.', v_falta;
  end if;
  raise notice 'TETELESTAI: nenhum acto por explicar';
end
$mig$;

select 'ACTOS POR EXPLICAR NO TOTAL: ' || coalesce(sum(por_explicar), 0)::text
  from public.shaar_segregacao_resumo();
