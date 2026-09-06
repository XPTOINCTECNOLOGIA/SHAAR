-- =====================================================================
-- MERKAVAH obedece; e o BNEI e o TIKKUN ficam medidos para decisao
-- =====================================================================
--
-- O MERKAVAH e a ultima do grupo demonstravel, e fica para o fim por decisao
-- do dono: a aplicacao ainda nao esta 100% pronta. Ligar a Central nao lhe
-- muda o desenvolvimento — muda quem decide as permissoes dela — mas a ordem
-- e para respeitar.
--
-- Medido antes: controlo 208, perde 0, ganha 0, 396 pares. Tres pessoas com
-- 29 direitos e sem portao, agora guardados pela migracao 013.
--
-- A seguir a isto sobram duas, e nenhuma delas se liga por aqui. O BNEI e o
-- TIKKUN nao tem codigos herdados: decidem por papeis proprios e obedecem por
-- politicas RLS, como o SPHRAGIS. E ha uma diferenca que importa dizer em voz
-- alta — no SPHRAGIS nao havia nada a traduzir, quem entrava podia tudo. No
-- BNEI e no TIKKUN ha papeis, e a traducao de papel para permissoes fui EU
-- que a fiz. Nao ha funcao antiga contra a qual a provar, ao contrario de
-- tudo o resto de hoje.
--
-- Por isso este ficheiro nao os liga. Mostra o mapeamento e quanta gente
-- depende de cada linha dele, para ser confirmado por quem sabe.
-- =====================================================================

select public.shaar_ligar_central(
  'MERKAVAH',
  'Ultima do grupo demonstravel. Medido antes de ligar: ninguem com portao '
  'perde acesso, e as 3 pessoas com direitos e sem portao mantem-nos guardados '
  'desde a migracao 013.');


-- ---------------------------------------------------------------------
-- O que falta decidir: papel -> permissoes, no BNEI e no TIKKUN
-- ---------------------------------------------------------------------
-- Cada linha diz o papel, quantas pessoas o tem hoje, e que permissoes eu
-- lhe atribui. Se alguma linha estiver errada, a pessoa fica sem trabalhar e
-- eu nao tenho como detectar antes — nao ha modelo antigo com que comparar.
select 'BNEI ' || r.role || ': ' || count(distinct r.user_id)::text ||
       ' pessoa(s) -> ' || (
         select string_agg(c, ', ') from unnest(case r.role
           when 'consulta' then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar']
           when 'gestor'   then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir']
           when 'admin'    then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir','financeiro.gerir','configuracao.gerir']
           else array[]::text[] end) as c)
  from public.bnei_user_roles r
  join public.users u on u.id = r.user_id and u.active and not u.blocked
 group by r.role
 order by r.role;

select 'TIKKUN ' || r.role::text || ': ' || count(distinct r.user_id)::text ||
       ' pessoa(s) -> ' || (
         select string_agg(c, ', ') from unnest(case r.role::text
           when 'tecnico'       then array['os.consultar','os.executar','os.assinar']
           when 'supervisor'    then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar']
           when 'gestor'        then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar']
           when 'administrador' then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar','configuracao.gerir']
           else array[]::text[] end) as c)
  from public.tikkun_user_roles r
  join public.users u on u.id = r.user_id and u.active and not u.blocked
 group by r.role
 order by r.role;

-- Permissoes do catalogo que NENHUM papel alcanca: se houver, ha coisas que
-- ninguem pode fazer, e isso tambem e uma decisao a tomar e nao um detalhe.
select 'BNEI — permissoes que nenhum papel alcanca: ' ||
       coalesce(string_agg(sp.code, ', ' order by sp.code), 'nenhuma')
  from public.shaar_permission sp
 where sp.app_code = 'BNEI' and sp.active
   and not exists (select 1 from public.shaar_permission_grant g
                    where g.app_code = 'BNEI' and g.code = sp.code);

select 'TIKKUN — permissoes que nenhum papel alcanca: ' ||
       coalesce(string_agg(sp.code, ', ' order by sp.code), 'nenhuma')
  from public.shaar_permission sp
 where sp.app_code = 'TIKKUN' and sp.active
   and not exists (select 1 from public.shaar_permission_grant g
                    where g.app_code = 'TIKKUN' and g.code = sp.code);


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'aplicacoes a obedecer: ' ||
       string_agg(app_code, ', ' order by app_code)
  from public.shaar_app_central;

select 'direitos por guardar: ' || count(*)::text
  from public.shaar_permissao_verdade_antiga a
  left join public.shaar_permission_grant g
    on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
 where g.user_id is null;

select 'divergencia: ' || count(*)::text
  from public.shaar_permissao_divergencias;
