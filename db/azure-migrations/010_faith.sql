-- =====================================================================
-- FAITH passa a obedecer a Central
-- =====================================================================
--
-- Terceira aplicacao, e a primeira em que ligar e so um acto — a
-- verificacao esta dentro de `shaar_ligar_central` e nao na minha memoria.
-- Se alguma coisa estiver errada, esta migracao recusa-se a correr e
-- explica porque.
--
-- O que a medicao previa deu:
--
--   controlo 576 | perde 0 | ganha sem revisao 0 | ganha com revisao 48
--   pares 624 | 16 codigos herdados
--
-- Ninguem perde acesso. As 48 respostas de acesso novo sao o mesmo padrao
-- do TETELESTAI — tres pessoas sem `auth_user_id`, reconhecidas por e-mail
-- pela Central e invisiveis para o codigo antigo, vezes os 16 codigos.
-- Todas com revisao aberta desde a migracao 003.
-- =====================================================================

select public.shaar_ligar_central(
  'FAITH',
  'Impacto medido antes de ligar: 624 pares, ninguem perde acesso, 48 respostas '
  'de acesso novo para tres pessoas sem conta em auth.users que entram por Entra '
  'ID e para quem o codigo antigo nunca respondia. Todas com revisao aberta.');


-- ---------------------------------------------------------------------
-- Que caminho serve cada aplicacao que falta
-- ---------------------------------------------------------------------
-- Ha dois caminhos e nao sao intercambiaveis, e vale a pena ter isto a vista
-- em vez de descobrir a meio de uma migracao:
--
--   · quem tem codigos HERDADOS decide por has_permission, e liga-se pela
--     tabela — como o TETELESTAI e agora o FAITH;
--   · quem nao tem, nunca passou por essa funcao. Decide por outra coisa
--     (papeis proprios, ou nada) e obedece por politicas RLS restritivas,
--     como o SPHRAGIS.
--
-- Ligar pela tabela uma aplicacao do segundo grupo nao faria mal nenhum, e e
-- pior do que fazer mal: nao faria nada, com ar de ter feito.
select 'catalogo por aplicacao: ' || string_agg(
         app_code || ' ' || herdados || '/' || total ||
         case when herdados = 0 then ' (RLS)' else ' (tabela)' end,
         ', ' order by app_code)
  from (
    select app_code,
           count(*) filter (where origem = 'herdado' and active) as herdados,
           count(*)                                              as total
      from public.shaar_permission
     group by app_code
  ) d;

select 'aplicacoes a obedecer: ' ||
       string_agg(app_code, ', ' order by app_code)
  from public.shaar_app_central;
