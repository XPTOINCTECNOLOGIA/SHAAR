-- =====================================================================
-- A permissao e da pessoa; o portao diz se ela entra hoje
-- =====================================================================
--
-- Estava a tratar isto ao contrario, e o erro e meu.
--
-- O portao e a permissao sao independentes. A permissao pertence a pessoa e
-- fica registada; o portao diz se ela pode entrar na aplicacao hoje. Abre-se
-- e fecha-se o portao quando for preciso, e as permissoes acompanham — no dia
-- em que o portao abrir, o que a pessoa ja tinha passa a valer, sem ninguem
-- ter de reconceder nada.
--
-- Isto desfaz duas coisas que eu tinha escrito:
--
-- 1. As 37 pessoas do JIREH com permissoes e sem portao nao sao uma
--    incoerencia a resolver. E o estado correcto.
--
-- 2. O `perde_sem_portao` que pus no guard ha uma hora esta errado.
--    Bloquearia o JIREH para sempre por causa de um "acesso" que essas
--    pessoas so tem porque as nove aplicacoes partilham a mesma base: hoje
--    conseguem agir nas tabelas do JIREH pela API sem nunca terem entrado no
--    JIREH, porque a funcao antiga nunca olhou para o portao. Exigir o portao
--    nao lhes tira nada que devessem ter — fecha um buraco.
--
-- E deixa a descoberto o defeito a serio, que e o oposto: o espelho junta
-- `shaar_gate_access` em todos os ramos, portanto so importou permissoes de
-- quem tinha o portao aberto naquele momento. As permissoes dessas 37 pessoas
-- NAO estao guardadas na Central. Abrir-lhes o portao amanha nao lhes daria
-- nada — que e exactamente o contrario do modelo.
--
-- Este ficheiro guarda o que faltava, alinha a medicao, e troca o guard
-- errado por aquele que protege o que interessa: nenhuma permissao se perde
-- do registo, tenha a pessoa portao ou nao.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. A VISTA DO MODELO ANTIGO DEIXA DE EXIGIR PORTAO
-- ---------------------------------------------------------------------
-- Ela mede o que a pessoa TEM DIREITO, nao se consegue entrar hoje. O unico
-- ramo onde o portao continua a ser a fonte e o do SPHRAGIS, porque essa
-- aplicacao nunca teve permissoes: quem entrava podia tudo, e o portao e
-- literalmente o direito.
create or replace view public.shaar_permissao_verdade_antiga as
  -- perfil -> permissão
  select distinct u.id as user_id, sp.app_code, sp.code
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
   where u.active
  union
  -- concessões individuais do JIREH
  select distinct u.id, sp.app_code, sp.code
    from public.jireh_user_permissions jup
    join public.users u             on u.id = jup.user_id and u.active
    join public.permissions p       on p.id = jup.permission_id
    join public.shaar_permission sp on sp.code = p.code and sp.origem = 'herdado'
  union
  -- cargo CFO exerce o perfil FINANCEIRO
  select distinct u.id, sp.app_code, sp.code
    from public.users u
    join public.positions pos on pos.id = u.position_id and pos.active
    join public.profiles fin  on upper(fin.name) = 'FINANCEIRO' and fin.active
    join public.profile_permissions pp on pp.profile_id = fin.id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
   where u.active and not u.blocked and upper(pos.name) = 'CFO'
  union
  -- papéis do BNEI
  select u.id, 'BNEI', c.code
    from public.bnei_user_roles r
    join public.users u on u.id = r.user_id and u.active
    cross join lateral (select unnest(case r.role
      when 'consulta' then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar']
      when 'gestor'   then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir']
      when 'admin'    then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir','financeiro.gerir','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  -- papéis do TIKKUN
  select u.id, 'TIKKUN', c.code
    from public.tikkun_user_roles r
    join public.users u on u.id = r.user_id and u.active
    cross join lateral (select unnest(case r.role::text
      when 'tecnico'       then array['os.consultar','os.executar','os.assinar']
      when 'supervisor'    then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar']
      when 'gestor'        then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar']
      when 'administrador' then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  -- SPHRAGIS: aqui o portao E o direito, porque nunca houve outro
  select g.user_id, 'SPHRAGIS', sp.code
    from public.shaar_gate_access g
    join public.users u             on u.id = g.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'SPHRAGIS'
   where g.app_code = 'SPHRAGIS';

comment on view public.shaar_permissao_verdade_antiga is
  'O que cada pessoa TEM DIREITO no modelo antigo, tenha ou nao o portao '
  'aberto hoje. O portao e independente da permissao: abre e fecha, e a '
  'permissao fica. So no SPHRAGIS o portao e a propria fonte do direito, '
  'porque essa aplicacao nunca teve permissoes.';


-- ---------------------------------------------------------------------
-- 2. GUARDAR O QUE FALTAVA
-- ---------------------------------------------------------------------
-- Aditivo e so aditivo: `on conflict do nothing` e nenhum delete. Nao ha
-- caminho por onde este ficheiro tire uma permissao a alguem.
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
select a.user_id, a.app_code, a.code, 'permitir', '{}'::jsonb,
       'migracao do modelo anterior — direito que existia e nao tinha sido '
       'guardado porque a pessoa nao tinha o portao aberto na altura do espelho',
       null::bigint, now()
  from public.shaar_permissao_verdade_antiga a
 where not exists (
   select 1 from public.shaar_permission_grant g
    where g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code)
on conflict (user_id, app_code, code) do nothing;


-- ---------------------------------------------------------------------
-- 3. O GUARD PASSA A PROTEGER O QUE INTERESSA
-- ---------------------------------------------------------------------
-- Sai o `perde_sem_portao`, que estava errado. Entra a pergunta certa:
-- ficou alguma permissao do modelo antigo POR GUARDAR? Se sim, ligar
-- perderia esse direito para sempre, e ai sim e para recusar.
create or replace function public.shaar_ligar_central(p_app text, p_motivo text)
returns text
language plpgsql
volatile
set search_path = public
as $$
declare r record; v_cods bigint; v_falta bigint;
begin
  if not exists (select 1 from public.shaar_apps a where a.code = p_app) then
    raise exception 'aplicacao % nao existe no catalogo', p_app;
  end if;

  if exists (select 1 from public.shaar_app_central c where c.app_code = p_app) then
    return p_app || ' ja obedecia; nada a fazer';
  end if;

  select count(*) into v_cods
    from public.shaar_permission sp
   where sp.app_code = p_app and sp.origem = 'herdado' and sp.active;

  if v_cods = 0 then
    raise exception
      'a aplicacao % nao tem codigos herdados: o interruptor nao lhe pega', p_app;
  end if;

  if not public.shaar_impersonacao_funciona() then
    raise exception 'a impersonacao nao esta a funcionar: nao se liga as cegas';
  end if;

  -- A pergunta que protege o modelo: nenhum direito pode ficar por guardar.
  -- Quem nao tem portao hoje pode te-lo amanha, e nesse dia o que ja era dele
  -- tem de estar la.
  select count(*) into v_falta
    from public.shaar_permissao_verdade_antiga a
    left join public.shaar_permission_grant g
      on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
   where a.app_code = p_app and g.user_id is null;

  if v_falta > 0 then
    raise exception
      'ha % direitos do modelo antigo do % que nao estao guardados na Central. '
      'Ligar assim perdia-os: no dia em que a pessoa tivesse o portao aberto, '
      'nao receberia o que ja era dela. Guardar primeiro',
      v_falta, p_app;
  end if;

  select * into r from public.shaar_divergencia_real_resumo(p_app);

  if r.perdia > 0 then
    raise exception
      'ligar % tiraria acesso em % respostas a gente COM o portao aberto',
      p_app, r.perdia;
  end if;

  if r.ganha_sem_revisao > 0 then
    raise exception
      'ligar % daria acesso novo em % respostas a gente sem revisao aberta',
      p_app, r.ganha_sem_revisao;
  end if;

  insert into public.shaar_app_central (app_code, motivo) values (p_app, p_motivo);

  return format(
    '%s obedece a Central. %s codigos, %s pares medidos, ninguem com portao '
    'perde acesso, %s respostas de acesso novo (com revisao aberta). E %s '
    'respostas deixam de valer para quem NAO tem o portao aberto — essas '
    'pessoas mantem os direitos guardados e voltam a exerce-los no dia em que '
    'o portao abrir',
    p_app, v_cods, r.pares_avaliados, r.ganharia, r.perde_sem_portao);
end $$;

revoke all on function public.shaar_ligar_central(text, text) from public;


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'concessoes: ' || count(*)::text || ' para ' ||
       count(distinct user_id)::text || ' pessoas'
  from public.shaar_permission_grant;

select 'direitos do modelo antigo por guardar: ' || count(*)::text
  from public.shaar_permissao_verdade_antiga a
  left join public.shaar_permission_grant g
    on g.user_id = a.user_id and g.app_code = a.app_code and g.code = a.code
 where g.user_id is null;

select 'divergencia: ' || count(*)::text
  from public.shaar_permissao_divergencias;

select 'JIREH — direitos guardados de quem NAO tem portao: ' ||
       count(*)::text || ' em ' || count(distinct g.user_id)::text || ' pessoas'
  from public.shaar_permission_grant g
 where g.app_code = 'JIREH'
   and not exists (select 1 from public.shaar_gate_access ga
                    where ga.user_id = g.user_id and ga.app_code = 'JIREH');
