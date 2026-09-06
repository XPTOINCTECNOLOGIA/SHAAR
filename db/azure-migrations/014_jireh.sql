-- =====================================================================
-- JIREH passa a obedecer a Central
-- =====================================================================
--
-- O JIREH esteve bloqueado a manha toda por uma razao que era minha e nao
-- dele: eu tratava "permissao sem portao" como incoerencia. Nao e. A
-- permissao e da pessoa e fica guardada; o portao diz se ela entra hoje.
--
-- Depois da migracao 013 os numeros sao estes:
--
--   · 164 direitos de 37 pessoas sem portao — agora GUARDADOS na Central.
--     No dia em que alguem lhes abrir o portao do JIREH, exercem-nos, sem
--     ninguem ter de reconceder nada. Antes da 013 nao estavam guardados, e
--     abrir-lhes o portao nao lhes daria nada.
--   · das 2 pessoas com portao: perde 0, ganha 0. Nada muda para quem
--     trabalha no JIREH hoje.
--
-- O que muda de facto: essas 37 pessoas deixam de conseguir agir nas tabelas
-- do JIREH pela API sem terem entrado no JIREH. Conseguiam porque as nove
-- aplicacoes partilham a mesma base e a funcao antiga nunca olhou para o
-- portao. Nao e um acesso que se lhes tire — e um buraco que se fecha, e e
-- para isto que a Central existe.
-- =====================================================================

select public.shaar_ligar_central(
  'JIREH',
  'Ligada depois de a migracao 013 guardar os 164 direitos de 37 pessoas que o '
  'espelho tinha deixado de fora por elas nao terem o portao aberto. Das 2 '
  'pessoas com portao, ninguem perde nem ganha. As 37 mantem os direitos '
  'guardados e voltam a exerce-los no dia em que o portao abrir; ate la deixam '
  'de poder agir pela API sem terem entrado, que era um buraco e nao um direito.');

select 'aplicacoes a obedecer: ' ||
       string_agg(app_code, ', ' order by app_code)
  from public.shaar_app_central;

select 'direitos do modelo antigo por guardar: ' || count(*)::text
  from public.shaar_permissao_verdade_antiga a
  left join public.shaar_permission_grant g
    on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
 where g.user_id is null;

select 'divergencia: ' || count(*)::text
  from public.shaar_permissao_divergencias;
