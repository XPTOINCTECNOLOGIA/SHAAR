-- =====================================================================
-- MANNA passa a obedecer; e ficam medidos o JIREH e o MERKAVAH
-- =====================================================================
--
-- O mapa do catalogo separou as sete aplicacoes que faltavam em dois grupos,
-- e a separacao nao e de estilo:
--
--   TETELESTAI 35/35, FAITH 16/16, JIREH 16/16, MANNA 18/18, MERKAVAH 11/11
--       — tem codigos herdados, decidem por has_permission, ligam-se pela
--         tabela, e a troca e DEMONSTRAVEL: compara-se com a funcao antiga,
--         pessoa a pessoa.
--
--   BNEI 0/9, TIKKUN 0/9, SPHRAGIS 0/8, SHAAR 0/6
--       — nunca passaram por essa funcao. Decidem por papeis proprios ou por
--         nada, e obedecem por politicas RLS. Nao ha funcao antiga contra a
--         qual provar seja o que for.
--
-- Este ficheiro faz o MANNA, que e do primeiro grupo.
--
-- As medicoes do JIREH e do MERKAVAH vao PRIMEIRO e de proposito: se o guard
-- do MANNA se recusar a ligar, a transaccao desfaz-se, mas o que ja foi
-- impresso fica no registo. Os numeros sobrevivem mesmo que a migracao nao.
-- =====================================================================


-- ---------------------------------------------------------------------
-- O que ligar o JIREH faria — sem ligar
-- ---------------------------------------------------------------------
-- O JIREH e o caso dificil, e nao por causa do codigo: 37 pessoas tem
-- permissoes do JIREH pelo perfil mas nao tem o portao aberto, e so 2 em 39
-- o tem. Como `shaar_pode` exige o portao, ligar sem mais nada tira acesso a
-- essas pessoas. Este numero mostra exactamente quanto.
select 'JIREH — controlo: '     || r.controlo_positivos::text ||
       ' | perde: '             || r.perdia            ::text ||
       ' | ganha sem revisao: ' || r.ganha_sem_revisao ::text ||
       ' | ganha com revisao: ' || (r.ganharia - r.ganha_sem_revisao)::text ||
       ' | pessoas afectadas: ' || r.pessoas           ::text ||
       ' | pares: '             || r.pares_avaliados   ::text
  from public.shaar_divergencia_real_resumo('JIREH') r;

-- E quanta gente ficaria de fora por nao ter portao, que e a pergunta que
-- o resumo acima NAO responde: ele so olha para quem tem portao.
select 'JIREH — com permissao pelo modelo antigo e sem portao: ' ||
       count(distinct u.id)::text || ' pessoas, ' || count(*)::text || ' permissoes'
  from public.users u
  join public.profile_permissions pp on pp.profile_id = u.profile_id
  join public.permissions p          on p.id = pp.permission_id and p.active
  join public.shaar_permission sp    on sp.code = p.code and sp.app_code = 'JIREH'
                                     and sp.origem = 'herdado' and sp.active
 where u.active and not u.blocked
   and not exists (select 1 from public.shaar_gate_access g
                    where g.user_id = u.id and g.app_code = 'JIREH');

-- ---------------------------------------------------------------------
-- O mesmo para o MERKAVAH, que fica para o fim por decisao do dono
-- ---------------------------------------------------------------------
select 'MERKAVAH — controlo: '  || r.controlo_positivos::text ||
       ' | perde: '             || r.perdia            ::text ||
       ' | ganha sem revisao: ' || r.ganha_sem_revisao ::text ||
       ' | ganha com revisao: ' || (r.ganharia - r.ganha_sem_revisao)::text ||
       ' | pessoas afectadas: ' || r.pessoas           ::text ||
       ' | pares: '             || r.pares_avaliados   ::text
  from public.shaar_divergencia_real_resumo('MERKAVAH') r;

select 'MERKAVAH — com permissao pelo modelo antigo e sem portao: ' ||
       count(distinct u.id)::text || ' pessoas, ' || count(*)::text || ' permissoes'
  from public.users u
  join public.profile_permissions pp on pp.profile_id = u.profile_id
  join public.permissions p          on p.id = pp.permission_id and p.active
  join public.shaar_permission sp    on sp.code = p.code and sp.app_code = 'MERKAVAH'
                                     and sp.origem = 'herdado' and sp.active
 where u.active and not u.blocked
   and not exists (select 1 from public.shaar_gate_access g
                    where g.user_id = u.id and g.app_code = 'MERKAVAH');


-- ---------------------------------------------------------------------
-- O MANNA, medido e ligado
-- ---------------------------------------------------------------------
select 'MANNA — controlo: '     || r.controlo_positivos::text ||
       ' | perde: '             || r.perdia            ::text ||
       ' | ganha sem revisao: ' || r.ganha_sem_revisao ::text ||
       ' | ganha com revisao: ' || (r.ganharia - r.ganha_sem_revisao)::text ||
       ' | pares: '             || r.pares_avaliados   ::text
  from public.shaar_divergencia_real_resumo('MANNA') r;

select public.shaar_ligar_central(
  'MANNA',
  'Quarta aplicacao pela via demonstravel. Impacto medido contra a propria '
  'funcao antiga antes de ligar: ninguem perde acesso, e o acesso novo e o '
  'mesmo padrao das anteriores — gente sem conta em auth.users que entra por '
  'Entra ID, toda com revisao aberta.');

select 'aplicacoes a obedecer: ' ||
       string_agg(app_code, ', ' order by app_code)
  from public.shaar_app_central;
