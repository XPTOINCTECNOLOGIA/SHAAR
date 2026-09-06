-- =====================================================================
-- Central de Permissionamento do SHAAR — estrutura
-- =====================================================================
--
-- O SHAAR passa a ser a autoridade única de autorização do ecossistema.
-- Cada microaplicação deixa de decidir quem pode o quê e passa a perguntar.
--
-- Três coisas que este ficheiro estabelece, e que valem a pena ler antes:
--
--   1. A concessão é INDIVIDUAL. Não há papel, perfil nem grupo em lado
--      nenhum deste esquema. O que existe é (pessoa, aplicação, permissão),
--      e nada mais decide por si.
--
--   2. A concessão tem ESCOPO. "Pode aprovar pagamentos" quase nunca é
--      verdade sem qualificação; o que é verdade é "pode aprovar pagamentos
--      da sua área, até cinquenta mil". Sem escopo, essas regras voltam para
--      dentro do código de cada aplicação, que é a dispersão que se quer
--      acabar. As regras de escopo são quatro, declarativas, e deliberadamente
--      NÃO formam uma linguagem de expressões: uma linguagem de regras dentro
--      da base torna-se, em pouco tempo, código que ninguém revê nem audita.
--
--   3. Falha FECHADA, sempre. Dimensão de escopo declarada e ausente do
--      contexto devolve falso. Erro devolve falso. Ausência devolve falso.
--      Um esquecimento de programação vira bloqueio visível, e não buraco
--      silencioso.
--
-- As aplicações nunca leem estas tabelas. Falam com o contrato:
--     pode(pessoa, aplicação, permissão, contexto) -> verdadeiro | falso
-- implementado aqui por shaar_pode(). É essa fronteira que permite, um dia,
-- trocar o motor de decisão sem tocar nas oito aplicações.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- CATÁLOGO — o que existe para ser concedido, por aplicação
-- ---------------------------------------------------------------------
-- A chave é composta de propósito. O catálogo actual (public.permissions)
-- é achatado: 96 permissões num espaço de nomes só, lido por seis
-- aplicações, onde `dashboard.view` não diz de quem é. Com (app_code, code)
-- duas aplicações podem ter o mesmo código sem colidir, e a tela sabe o que
-- pôr em cada aba.
create table if not exists public.shaar_permission (
  app_code    text        not null references public.shaar_apps(code) on update cascade,
  code        text        not null,
  name        text        not null,
  description text        not null default '',
  grupo       text        not null default 'geral',
  -- que dimensões de escopo esta permissão aceita. Vazio = sempre global.
  -- A tela usa isto para saber que campos de limite oferecer.
  escopo_dimensoes text[] not null default '{}',
  sort_order  integer     not null default 100,
  active      boolean     not null default true,
  origem      text        not null default 'catalogo',
  created_at  timestamptz not null default now(),
  primary key (app_code, code),
  constraint shaar_permission_forma
    check (code ~ '^[a-z][a-z0-9_]*([.:][a-z][a-z0-9_]*)+$')
);

comment on table public.shaar_permission is
  'Catálogo de permissões por aplicação. Cada aplicação publica o seu; o SHAAR nao inventa permissoes, so as guarda, concede e audita.';

-- ---------------------------------------------------------------------
-- VERSÃO — a chave de cache de toda a arquitectura
-- ---------------------------------------------------------------------
-- Cache de permissões tem um problema só: revogar. Datar por tempo deixa uma
-- janela em que a revogação não tem efeito, e é nessa janela que ocorrem os
-- incidentes que se quer evitar. Datamos por versão: qualquer alteração
-- incrementa o contador na mesma transacção, o bilhete carrega o valor, e a
-- chave antiga simplesmente deixa de ser consultada.
create table if not exists public.shaar_permission_version (
  user_id  bigint      not null,
  app_code text        not null,
  versao   bigint      not null default 1,
  mudou_em timestamptz not null default now(),
  primary key (user_id, app_code)
);

-- ---------------------------------------------------------------------
-- CONCESSÕES — quem tem o quê, e até onde
-- ---------------------------------------------------------------------
create table if not exists public.shaar_permission_grant (
  user_id    bigint      not null references public.users(id) on delete cascade,
  app_code   text        not null,
  code       text        not null,
  -- 'negar' existe mesmo num modelo individual, onde a ausência de linha já
  -- significa "não". Dá duas coisas: uma negação explícita e auditável, que
  -- sobrevive a qualquer aplicação em massa futura, e um ponto de corte
  -- imediato num incidente sem apagar o histórico do que a pessoa tinha.
  efeito     text        not null default 'permitir'
               check (efeito in ('permitir','negar')),
  escopo     jsonb       not null default '{}'::jsonb,
  -- motivo é not null no esquema, não só no formulário. Num modelo
  -- individual, a pergunta que se faz seis meses depois nunca é "tem?",
  -- é "porquê?".
  motivo     text        not null,
  granted_by bigint      references public.users(id),
  granted_at timestamptz not null default now(),
  valido_de  timestamptz not null default now(),
  valido_ate timestamptz,
  primary key (user_id, app_code, code),
  foreign key (app_code, code)
    references public.shaar_permission(app_code, code) on update cascade,
  constraint shaar_grant_janela
    check (valido_ate is null or valido_ate > valido_de),
  constraint shaar_grant_escopo_objecto
    check (jsonb_typeof(escopo) = 'object')
);

create index if not exists shaar_grant_pessoa_app
  on public.shaar_permission_grant (user_id, app_code) where efeito = 'permitir';
create index if not exists shaar_grant_por_permissao
  on public.shaar_permission_grant (app_code, code);
create index if not exists shaar_grant_a_expirar
  on public.shaar_permission_grant (valido_ate) where valido_ate is not null;

-- ---------------------------------------------------------------------
-- HISTÓRICO — append-only, escrito por gatilho
-- ---------------------------------------------------------------------
-- É gatilho e não chamada no código de propósito: o que se pode esquecer,
-- esquece-se, e uma trilha com buracos não serve para auditoria nenhuma.
create table if not exists public.shaar_permission_event (
  id          bigserial primary key,
  quando      timestamptz not null default now(),
  acao        text not null check (acao in ('conceder','revogar','alterar','expirar')),
  user_id     bigint not null,
  app_code    text   not null,
  code        text   not null,
  antes       jsonb,
  depois      jsonb,
  actor_id    bigint,
  actor_email text,
  motivo      text,
  ip          inet,
  agente      text
);
create index if not exists shaar_event_pessoa
  on public.shaar_permission_event (user_id, app_code, quando desc);
create index if not exists shaar_event_quando
  on public.shaar_permission_event (quando desc);

-- ---------------------------------------------------------------------
-- SEGREGAÇÃO DE FUNÇÕES — combinações que não podem existir
-- ---------------------------------------------------------------------
-- Um modelo individual torna a acumulação de privilégio MAIS fácil, porque
-- não há um cargo a limitar. Criar e aprovar o próprio pagamento é o exemplo
-- clássico: inofensivo em separado, risco de fraude junto.
create table if not exists public.shaar_permission_conflito (
  app_a  text not null, code_a text not null,
  app_b  text not null, code_b text not null,
  motivo text not null,
  severidade text not null default 'avisar'
    check (severidade in ('bloquear','avisar')),
  primary key (app_a, code_a, app_b, code_b)
);

-- ---------------------------------------------------------------------
-- FILA DE REVISÃO — o ciclo de vida deixa trabalho aqui
-- ---------------------------------------------------------------------
create table if not exists public.shaar_permission_revisao (
  id          bigserial primary key,
  user_id     bigint not null references public.users(id) on delete cascade,
  app_code    text,
  gatilho     text not null
    check (gatilho in ('mudanca','periodica','conflito','emergencia','migracao')),
  detalhe     jsonb not null default '{}'::jsonb,
  criado_em   timestamptz not null default now(),
  resolvido_em timestamptz,
  resolvido_por bigint references public.users(id),
  decisao     text
);
create index if not exists shaar_revisao_abertas
  on public.shaar_permission_revisao (criado_em) where resolvido_em is null;

-- ---------------------------------------------------------------------
-- ESCOPO — as quatro regras
-- ---------------------------------------------------------------------
--   {}                                 sem limite
--   {"departamento": ["FIN","OPS"]}    contexto.departamento tem de estar na lista
--   {"valor_max": 50000}               contexto.valor <= 50000
--   {"nivel_min": 3}                   contexto.nivel  >= 3
--
-- A regra que torna isto seguro: dimensão declarada no escopo e AUSENTE do
-- contexto devolve falso. Se a concessão limita por departamento e a
-- aplicação se esquece de o enviar, a resposta é "não" — nunca "sim por
-- omissão". É a diferença entre falhar fechado e falhar aberto.
--
-- Se alguém pedir uma quinta regra, isso não é sinal de esticar esta função:
-- é sinal de que chegou a hora de um motor de política a sério (Cedar, OPA)
-- por trás do mesmo contrato.
create or replace function public.shaar_escopo_satisfeito(p_escopo jsonb, p_ctx jsonb)
returns boolean
language sql immutable
as $$
  select coalesce(bool_and(
    case
      when jsonb_typeof(v) = 'array' then
        (p_ctx ? k) and (v ? (p_ctx ->> k))
      when k like '%\_max' then
        (p_ctx ? left(k, length(k) - 4))
        and (p_ctx ->> left(k, length(k) - 4)) ~ '^-?[0-9]+(\.[0-9]+)?$'
        and (p_ctx ->> left(k, length(k) - 4))::numeric <= (v #>> '{}')::numeric
      when k like '%\_min' then
        (p_ctx ? left(k, length(k) - 4))
        and (p_ctx ->> left(k, length(k) - 4)) ~ '^-?[0-9]+(\.[0-9]+)?$'
        and (p_ctx ->> left(k, length(k) - 4))::numeric >= (v #>> '{}')::numeric
      else
        (p_ctx ? k) and ((p_ctx -> k) = v)
    end
  ), true)   -- bool_and de conjunto vazio e nulo: escopo vazio nao limita nada
  from jsonb_each(coalesce(p_escopo, '{}'::jsonb)) as e(k, v);
$$;

-- ---------------------------------------------------------------------
-- O CONTRATO — a única porta de decisão
-- ---------------------------------------------------------------------
-- Portão fechado ganha de tudo. Negação ganha de concessão. Fora da janela
-- de validade não conta. Fora do escopo não conta.
--
-- É `stable` e nunca levanta excepção, por uma razão aprendida à custa:
-- um `raise` faz rollback da transacção inteira, incluindo a linha de
-- auditoria acabada de escrever. Recusa devolve falso. Vantagem lateral:
-- um falso não confirma a quem sonda que a permissão sequer existe.
create or replace function public.shaar_pode(
  p_app  text,
  p_code text,
  p_ctx  jsonb  default '{}'::jsonb,
  p_user bigint default null
) returns boolean
language sql stable security definer set search_path = public
as $$
  with eu as (select coalesce(p_user, public.shaar_usuario_atual()) as id)
  select
    exists (select 1 from public.shaar_gate_access g, eu
             where g.user_id = eu.id and g.app_code = p_app)
    and exists (select 1 from public.shaar_permission_grant p, eu
                 where p.user_id = eu.id and p.app_code = p_app and p.code = p_code
                   and p.efeito = 'permitir'
                   and p.valido_de <= now()
                   and (p.valido_ate is null or p.valido_ate > now())
                   and public.shaar_escopo_satisfeito(p.escopo, coalesce(p_ctx,'{}'::jsonb)))
    and not exists (select 1 from public.shaar_permission_grant n, eu
                     where n.user_id = eu.id and n.app_code = p_app and n.code = p_code
                       and n.efeito = 'negar'
                       and n.valido_de <= now()
                       and (n.valido_ate is null or n.valido_ate > now())
                       and public.shaar_escopo_satisfeito(n.escopo, coalesce(p_ctx,'{}'::jsonb)));
$$;

-- Versão explicada. Diz PORQUÊ — para a API, para o ecrã de diagnóstico e
-- para a auditoria de uma recusa. A decisão em si continua a ser shaar_pode.
create or replace function public.shaar_porque(
  p_app  text,
  p_code text,
  p_ctx  jsonb  default '{}'::jsonb,
  p_user bigint default null
) returns table (permitido boolean, motivo text)
language sql stable security definer set search_path = public
as $$
  with eu as (select coalesce(p_user, public.shaar_usuario_atual()) as id),
       g  as (select exists (select 1 from public.shaar_gate_access a, eu
                              where a.user_id = eu.id and a.app_code = p_app) as ok),
       c  as (select p.* from public.shaar_permission_grant p, eu
               where p.user_id = eu.id and p.app_code = p_app and p.code = p_code)
  select public.shaar_pode(p_app, p_code, p_ctx, (select id from eu)),
         case
           when not (select ok from g)                              then 'portao_fechado'
           when not exists (select 1 from c)                        then 'sem_concessao'
           when exists (select 1 from c where efeito = 'negar'
                          and valido_de <= now()
                          and (valido_ate is null or valido_ate > now())
                          and public.shaar_escopo_satisfeito(escopo, coalesce(p_ctx,'{}'::jsonb)))
                                                                    then 'negacao_explicita'
           when exists (select 1 from c where valido_ate is not null
                          and valido_ate <= now())                   then 'expirada'
           when exists (select 1 from c where valido_de > now())     then 'ainda_nao_vigente'
           when exists (select 1 from c where efeito = 'permitir'
                          and not public.shaar_escopo_satisfeito(escopo, coalesce(p_ctx,'{}'::jsonb)))
                                                                    then 'fora_de_escopo'
           else 'permitido'
         end;
$$;

-- Lista completa de uma pessoa numa aplicação: é isto que entra no bilhete.
create or replace function public.shaar_minhas_permissoes(p_app text)
returns table (code text, escopo jsonb)
language sql stable security definer set search_path = public
as $$
  select p.code, p.escopo
    from public.shaar_permission_grant p
   where p.user_id = public.shaar_usuario_atual()
     and p.app_code = p_app
     and p.efeito = 'permitir'
     and p.valido_de <= now()
     and (p.valido_ate is null or p.valido_ate > now())
     and not exists (select 1 from public.shaar_permission_grant n
                      where n.user_id = p.user_id and n.app_code = p.app_code
                        and n.code = p.code and n.efeito = 'negar'
                        and n.valido_de <= now()
                        and (n.valido_ate is null or n.valido_ate > now()))
     and exists (select 1 from public.shaar_gate_access g
                  where g.user_id = p.user_id and g.app_code = p_app)
   order by p.code;
$$;

create or replace function public.shaar_versao_permissoes(p_app text, p_user bigint default null)
returns bigint
language sql stable security definer set search_path = public
as $$
  select coalesce((select v.versao from public.shaar_permission_version v
                    where v.user_id = coalesce(p_user, public.shaar_usuario_atual())
                      and v.app_code = p_app), 0);
$$;

-- ---------------------------------------------------------------------
-- GATILHOS — histórico, versão e segregação
-- ---------------------------------------------------------------------
create or replace function public.shaar_registar_permissao()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_actor bigint := public.shaar_usuario_atual();
  v_user  bigint := coalesce(new.user_id,  old.user_id);
  v_app   text   := coalesce(new.app_code, old.app_code);
begin
  insert into public.shaar_permission_event
    (acao, user_id, app_code, code, antes, depois,
     actor_id, actor_email, motivo, ip, agente)
  values (
    case tg_op when 'INSERT' then 'conceder'
               when 'DELETE' then 'revogar'
               else 'alterar' end,
    v_user, v_app, coalesce(new.code, old.code),
    case when tg_op = 'INSERT' then null else to_jsonb(old) end,
    case when tg_op = 'DELETE' then null else to_jsonb(new) end,
    v_actor,
    (select email from public.users where id = v_actor),
    coalesce(new.motivo, old.motivo),
    inet_client_addr(),
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'user-agent'
  );

  insert into public.shaar_permission_version (user_id, app_code, versao, mudou_em)
  values (v_user, v_app, 1, now())
  on conflict (user_id, app_code)
    do update set versao = shaar_permission_version.versao + 1, mudou_em = now();

  return coalesce(new, old);
end $$;

drop trigger if exists shaar_grant_auditar on public.shaar_permission_grant;
create trigger shaar_grant_auditar
  after insert or update or delete on public.shaar_permission_grant
  for each row execute function public.shaar_registar_permissao();

-- Conflitos verificados na ESCRITA, não na leitura: o custo fica no acto raro
-- (conceder) e não no acto constante (decidir).
create or replace function public.shaar_verificar_conflito()
returns trigger
language plpgsql set search_path = public
as $$
declare r record;
begin
  if new.efeito <> 'permitir' then return new; end if;
  for r in
    select c.* from public.shaar_permission_conflito c
     where (c.app_a = new.app_code and c.code_a = new.code)
        or (c.app_b = new.app_code and c.code_b = new.code)
  loop
    if exists (
      select 1 from public.shaar_permission_grant g
       where g.user_id = new.user_id and g.efeito = 'permitir'
         and ((g.app_code = r.app_a and g.code = r.code_a)
           or (g.app_code = r.app_b and g.code = r.code_b))
         and not (g.app_code = new.app_code and g.code = new.code)
    ) then
      if r.severidade = 'bloquear' then
        raise exception 'conflito de segregacao de funcoes: %', r.motivo
          using errcode = 'check_violation';
      end if;
      -- 'avisar' deixa passar e deixa marca: o administrador tem de registar
      -- a compensacao (tipicamente, limitar o escopo de aprovacao por valor).
      insert into public.shaar_permission_revisao (user_id, app_code, gatilho, detalhe)
      values (new.user_id, new.app_code, 'conflito',
              jsonb_build_object('conflito', r.motivo,
                                 'par', r.app_a||'/'||r.code_a||' + '||r.app_b||'/'||r.code_b));
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists shaar_grant_conflito on public.shaar_permission_grant;
create trigger shaar_grant_conflito
  before insert or update on public.shaar_permission_grant
  for each row execute function public.shaar_verificar_conflito();

-- ---------------------------------------------------------------------
-- EXPIRAÇÃO — permissão temporária é a que mais apodrece
-- ---------------------------------------------------------------------
-- Concede-se para umas férias e fica para sempre. Com janela de validade,
-- a permissão morre sozinha e a morte entra no histórico como evento.
create or replace function public.shaar_expirar_permissoes()
returns integer
language plpgsql volatile security definer set search_path = public
as $$
declare n integer;
begin
  with mortas as (
    delete from public.shaar_permission_grant
     where valido_ate is not null and valido_ate <= now()
    returning 1
  ) select count(*)::integer into n from mortas;
  if n > 0 then
    update public.shaar_permission_event
       set acao = 'expirar'
     where id in (select id from public.shaar_permission_event
                   where acao = 'revogar' and quando > now() - interval '1 minute'
                   order by id desc limit n);
  end if;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- SEGURANÇA DAS PRÓPRIAS TABELAS
-- ---------------------------------------------------------------------
-- Histórico imutável, e isso inclui o administrador. Um administrador pode
-- conceder e revogar à vontade — mas não pode apagar o registo de o ter
-- feito. Sem esta linha, a trilha de auditoria é uma sugestão.
revoke update, delete on public.shaar_permission_event from public;
revoke update, delete on public.shaar_permission_event from anon, authenticated;

alter table public.shaar_permission              enable row level security;
alter table public.shaar_permission_grant        enable row level security;
alter table public.shaar_permission_event        enable row level security;
alter table public.shaar_permission_version      enable row level security;
alter table public.shaar_permission_conflito     enable row level security;
alter table public.shaar_permission_revisao      enable row level security;

-- O catálogo é público para quem está autenticado: saber que a permissão
-- existe não é saber que se tem.
drop policy if exists shaar_permission_ler on public.shaar_permission;
create policy shaar_permission_ler on public.shaar_permission
  for select to authenticated using (true);

-- Cada pessoa vê as suas concessões; quem gere vê todas.
drop policy if exists shaar_grant_ler on public.shaar_permission_grant;
create policy shaar_grant_ler on public.shaar_permission_grant
  for select to authenticated
  using (user_id = public.shaar_usuario_atual()
         or public.shaar_pode('SHAAR','permissao.gerir')
         or public.shaar_pode('SHAAR','permissao.auditar'));

-- Escrita NUNCA pelo cliente. Só pela API, que corre como função de borda e
-- aplica as regras que o esquema sozinho não sabe (segregação de funções em
-- relação ao actor, proibição de se servir a si próprio, motivo obrigatório).
drop policy if exists shaar_grant_escrever on public.shaar_permission_grant;

drop policy if exists shaar_event_ler on public.shaar_permission_event;
create policy shaar_event_ler on public.shaar_permission_event
  for select to authenticated
  using (public.shaar_pode('SHAAR','permissao.auditar')
         or user_id = public.shaar_usuario_atual());

drop policy if exists shaar_versao_ler on public.shaar_permission_version;
create policy shaar_versao_ler on public.shaar_permission_version
  for select to authenticated
  using (user_id = public.shaar_usuario_atual()
         or public.shaar_pode('SHAAR','permissao.gerir'));

drop policy if exists shaar_conflito_ler on public.shaar_permission_conflito;
create policy shaar_conflito_ler on public.shaar_permission_conflito
  for select to authenticated using (true);

drop policy if exists shaar_revisao_ler on public.shaar_permission_revisao;
create policy shaar_revisao_ler on public.shaar_permission_revisao
  for select to authenticated
  using (public.shaar_pode('SHAAR','permissao.gerir')
         or user_id = public.shaar_usuario_atual());

grant select on public.shaar_permission, public.shaar_permission_grant,
                public.shaar_permission_event, public.shaar_permission_version,
                public.shaar_permission_conflito, public.shaar_permission_revisao
  to authenticated;

grant execute on function public.shaar_pode(text,text,jsonb,bigint) to authenticated;
grant execute on function public.shaar_porque(text,text,jsonb,bigint) to authenticated;
grant execute on function public.shaar_minhas_permissoes(text) to authenticated;
grant execute on function public.shaar_versao_permissoes(text,bigint) to authenticated;
grant execute on function public.shaar_escopo_satisfeito(jsonb,jsonb) to authenticated;

commit;
