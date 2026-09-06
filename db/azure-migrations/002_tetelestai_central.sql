-- =====================================================================
-- Fase 5 — troca de autoridade: TETELESTAI
-- =====================================================================
--
-- O SPHRAGIS foi fácil porque não havia nada a substituir. O TETELESTAI é o
-- oposto, e o levantamento apanhou três coisas que teriam partido produção se
-- eu tivesse aplicado a primeira versão que escrevi:
--
--   1. `has_permission` não decide nada — delega em `jireh_has_permission`,
--      uma função com o nome de outra aplicação, herdada de quando as bases se
--      juntaram. 169 políticas de todo o ecossistema dependem dela.
--
--   2. `jireh_has_permission` tem TRÊS ramos, não dois. Além do perfil e das
--      concessões individuais, há um terceiro: quem ocupa o cargo de CFO
--      exerce as permissões do perfil FINANCEIRO, por decisão de 25/08, sem
--      que isso esteja em `profile_permissions`. O espelho não o importou.
--
--   3. As duas funções identificam a pessoa de maneiras diferentes:
--      `jireh_has_permission` só por `auth_user_id`; `shaar_usuario_atual`
--      também por email. Há quatro contas activas, com portão aberto, sem
--      `auth_user_id` — para quem a aplicação está partida hoje, e que
--      passariam a funcionar de repente. Uma correcção bem-vinda, mas não
--      como efeito colateral silencioso de outra coisa.
--
-- Este ficheiro trata as três antes de trocar seja o que for.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. LIGAR AS CONTAS ÓRFÃS
-- ---------------------------------------------------------------------
-- A causa das duas funções discordarem não é filosófica: é que quatro
-- registos de pessoa nunca foram ligados à respectiva conta de autenticação.
-- Ligá-los faz as duas concordarem, e conserta uma aplicação que hoje não
-- funciona para essas pessoas.
--
-- Duas salvaguardas, e a segunda não é teórica: este ecossistema já teve contas
-- duplicadas para a mesma pessoa. Só liga quando a correspondência é
-- inequívoca dos DOIS lados — exactamente uma conta de autenticação com aquele
-- email, e exactamente um registo de pessoa com aquele email. Onde houver
-- ambiguidade, não liga nada e a ambiguidade fica para ser resolvida por
-- gente, que é o único sítio onde se resolve bem.
with ligadas as (
  update public.users u
     set auth_user_id = a.id
    from auth.users a
   where u.auth_user_id is null
     and u.active and not u.blocked
     and lower(a.email) = lower(u.email)
     and (select count(*) from auth.users x
           where lower(x.email) = lower(u.email)) = 1
     and (select count(*) from public.users y
           where lower(y.email) = lower(u.email)) = 1
  returning u.email
)
select 'contas ligadas: ' || count(*)::text
       || coalesce(' — ' || string_agg(email::text, ', '), '')
  from ligadas;


-- ---------------------------------------------------------------------
-- 2. A REGRA DO CARGO CFO, ESCRITA COMO DADO
-- ---------------------------------------------------------------------
-- Hoje a regra é redundante: quem é CFO tem o perfil FINANCEIRO, portanto as
-- 63 permissões já lhe chegam pelo primeiro ramo. Mas ela existe para o dia em
-- que isso deixe de ser verdade — e nesse dia o comportamento mudaria sozinho,
-- sem registo e sem decisão.
--
-- Passa a estar escrita na concessão, com o motivo a citar a decisão. Quando o
-- CFO mudar, alguém tem de decidir em vez de acontecer.
update public.shaar_permission_grant g
   set motivo = g.motivo || ' [+ cargo CFO exerce o perfil FINANCEIRO, decisao de 25/08]'
  from public.users u
  join public.positions pos on pos.id = u.position_id and pos.active
 where g.user_id = u.id
   and upper(pos.name) = 'CFO'
   and g.motivo not like '%cargo CFO%'
   and exists (
     select 1
       from public.profiles fin
       join public.profile_permissions pp on pp.profile_id = fin.id
       join public.permissions perm on perm.id = pp.permission_id
      where upper(fin.name) = 'FINANCEIRO' and fin.active
        and perm.code = g.code);

-- E fica uma revisão aberta, para que a saída desta regra do código não passe
-- despercebida a quem gere a Central.
insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
select u.id, null, 'migracao',
       jsonb_build_object(
         'nota', 'O cargo CFO deixou de herdar o perfil FINANCEIRO automaticamente. '
              || 'As permissoes ficaram escritas como concessao individual. '
              || 'Quando o CFO mudar, e preciso conceder a quem entrar e rever quem sai.',
         'decisao_original', '25/08')
  from public.users u
  join public.positions pos on pos.id = u.position_id and pos.active
 where u.active and upper(pos.name) = 'CFO'
   and not exists (
     select 1 from public.shaar_permission_revisao r
      where r.user_id = u.id and r.gatilho = 'migracao'
        and r.detalhe ->> 'decisao_original' = '25/08');


-- ---------------------------------------------------------------------
-- 3. A VISTA DE DIVERGÊNCIA PASSA A DIZER A VERDADE
-- ---------------------------------------------------------------------
-- Isto corrige um ponto cego meu. A vista comparava a Central com o MEU modelo
-- do sistema antigo — perfil, concessões individuais, papéis — e não com o
-- sistema antigo. Faltava-lhe o ramo do cargo CFO, portanto os "zero
-- divergências" que reportei eram verdadeiros para o que ela media, e o que
-- ela media estava incompleto.
create or replace view public.shaar_permissao_verdade_antiga as
  -- perfil -> permissão
  select distinct u.id as user_id, sp.app_code, sp.code
    from public.users u
    join public.profile_permissions pp on pp.profile_id = u.profile_id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
    join public.shaar_gate_access g    on g.user_id = u.id and g.app_code = sp.app_code
   where u.active
  union
  -- concessões individuais do JIREH
  select distinct u.id, sp.app_code, sp.code
    from public.jireh_user_permissions jup
    join public.users u             on u.id = jup.user_id and u.active
    join public.permissions p       on p.id = jup.permission_id
    join public.shaar_permission sp on sp.code = p.code and sp.origem = 'herdado'
    join public.shaar_gate_access g on g.user_id = u.id and g.app_code = sp.app_code
  union
  -- o ramo que faltava: cargo CFO exerce o perfil FINANCEIRO
  select distinct u.id, sp.app_code, sp.code
    from public.users u
    join public.positions pos on pos.id = u.position_id and pos.active
    join public.profiles fin  on upper(fin.name) = 'FINANCEIRO' and fin.active
    join public.profile_permissions pp on pp.profile_id = fin.id
    join public.permissions p          on p.id = pp.permission_id
    join public.shaar_permission sp    on sp.code = p.code and sp.origem = 'herdado'
    join public.shaar_gate_access g    on g.user_id = u.id and g.app_code = sp.app_code
   where u.active and not u.blocked and upper(pos.name) = 'CFO'
  union
  -- papéis do BNEI
  select u.id, 'BNEI', c.code
    from public.bnei_user_roles r
    join public.users u             on u.id = r.user_id and u.active
    join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'BNEI'
    cross join lateral (select unnest(case r.role
      when 'consulta' then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar']
      when 'gestor'   then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir']
      when 'admin'    then array['pessoa.consultar','contrato.consultar','financeiro.consultar','compliance.consultar','pessoa.gerir','contrato.gerir','compliance.gerir','financeiro.gerir','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  -- papéis do TIKKUN
  select u.id, 'TIKKUN', c.code
    from public.tikkun_user_roles r
    join public.users u             on u.id = r.user_id and u.active
    join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'TIKKUN'
    cross join lateral (select unnest(case r.role::text
      when 'tecnico'       then array['os.consultar','os.executar','os.assinar']
      when 'supervisor'    then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar']
      when 'gestor'        then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar']
      when 'administrador' then array['os.consultar','os.executar','os.assinar','os.criar','os.aprovar','equipa.gerir','custo.consultar','relatorio.consultar','configuracao.gerir']
      else array[]::text[] end) as code) c
  union
  -- SPHRAGIS: quem passa o portão pode tudo
  select g.user_id, 'SPHRAGIS', sp.code
    from public.shaar_gate_access g
    join public.users u             on u.id = g.user_id and u.active
    join public.shaar_permission sp on sp.app_code = 'SPHRAGIS'
   where g.app_code = 'SPHRAGIS';


-- ---------------------------------------------------------------------
-- 4. A TROCA
-- ---------------------------------------------------------------------
-- Uma condição. Quando o código pedido pertence ao catálogo do TETELESTAI,
-- quem responde é a Central; para tudo o resto, o caminho antigo continua
-- intacto. As 169 políticas não mudam uma linha — muda-se a fonte da verdade
-- por baixo delas.
--
-- Cada aplicação seguinte é uma condição a mais neste mesmo sítio, e reverter
-- é tirá-la. É de propósito que a mudança seja pequena: numa função de que
-- depende o ecossistema inteiro, o tamanho do diff é uma medida de risco.
--
-- Nota sobre permissões desactivadas: `jireh_has_permission` exige
-- `perm.active`. A condição abaixo também, portanto uma permissão desactivada
-- do TETELESTAI cai no caminho antigo, que devolve falso. O comportamento é o
-- mesmo pelos dois lados.
create or replace function public.has_permission(perm_code character varying)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when exists (
      select 1 from public.shaar_permission sp
       where sp.code = perm_code
         and sp.app_code = 'TETELESTAI'
         and sp.origem = 'herdado'
         and sp.active)
    then public.shaar_pode('TETELESTAI', perm_code)
    else public.jireh_has_permission(perm_code)
  end;
$function$;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
-- A prova de que a troca não muda nada: a divergência entre o que a Central
-- diz e o que o sistema antigo dizia — agora com o ramo do CFO incluído — tem
-- de continuar em zero. Se esta consulta devolver linhas, reverte-se pondo
-- has_permission a chamar jireh_has_permission e mais nada.
select 'divergencia TETELESTAI: ' || count(*)::text
  from public.shaar_permissao_divergencias where app_code = 'TETELESTAI';

select 'divergencia total: ' || count(*)::text
  from public.shaar_permissao_divergencias;

select 'contas activas com portao e sem auth_user_id: ' || count(*)::text
  from public.users u
 where u.active and not u.blocked and u.auth_user_id is null
   and exists (select 1 from public.shaar_gate_access g where g.user_id = u.id);

-- Fumo: a funcao responde sem rebentar. Corre como postgres, onde auth.uid() e
-- nulo, portanto o valor esperado e falso — o que se testa aqui e que a
-- delegacao nao levanta excepcao, nao o resultado.
select 'has_permission responde: ' || coalesce(
         public.has_permission('todo.create'::varchar)::text, 'nulo');
