-- =====================================================================
-- A lista de aplicacoes que obedecem passa a ser dado, nao codigo
-- =====================================================================
--
-- Hoje o interruptor tem uma condicao escrita a mao para o TETELESTAI.
-- Com sete aplicacoes pela frente isso seriam sete condicoes numa funcao de
-- que dependem 169 politicas, cada uma delas uma migracao a mexer no corpo
-- da funcao. Sete oportunidades de enganar-se no sitio onde enganar-se e
-- mais caro.
--
-- Passa a haver uma tabela: quem esta la, obedece a Central. Ligar uma
-- aplicacao e uma linha inserida; reverter e uma linha apagada. A funcao
-- deixa de mudar. E, de brinde, fica registado QUANDO e PORQUE cada
-- aplicacao passou a obedecer — que e informacao que hoje so existe na
-- mensagem de um commit.
--
-- Isto so e seguro porque cada codigo pertence a uma aplicacao so (medido:
-- zero codigos em mais do que uma). Mas confiar numa medicao de hoje para
-- uma funcao que vai correr durante anos e frouxo, por isso a unicidade
-- passa a ser garantida por indice: deixa de poder acontecer.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. A UNICIDADE DEIXA DE SER SORTE
-- ---------------------------------------------------------------------
-- A procura e por codigo. Se o mesmo codigo herdado existisse em duas
-- aplicacoes, a funcao teria de escolher uma — e escolher a sorte num
-- sistema de autorizacao nao e aceitavel. O indice torna o caso impossivel
-- em vez de o tratar.
create unique index if not exists shaar_permission_codigo_herdado_unico
  on public.shaar_permission (code)
  where origem = 'herdado' and active;


-- ---------------------------------------------------------------------
-- 2. QUEM OBEDECE
-- ---------------------------------------------------------------------
create table if not exists public.shaar_app_central (
  app_code   text        primary key
               references public.shaar_apps (code) on update cascade,
  desde      timestamptz not null default now(),
  motivo     text        not null,
  quem       text        not null default current_user
);

comment on table public.shaar_app_central is
  'Aplicacoes cuja autorizacao passou a ser respondida pela Central. Estar '
  'nesta tabela e o interruptor: inserir liga, apagar reverte. A funcao '
  'jireh_has_permission le daqui e nao muda quando se liga mais uma.';

alter table public.shaar_app_central enable row level security;

-- Quem gere a Central pode ver; ninguem escreve pelo cliente. Ligar uma
-- aplicacao e um acto deliberado, feito por migracao, nao pela API.
drop policy if exists shaar_app_central_ver on public.shaar_app_central;
create policy shaar_app_central_ver
  on public.shaar_app_central for select to authenticated
  using (public.shaar_pode('SHAAR', 'permissao.gerir'));

revoke all on public.shaar_app_central from anon, authenticated;
grant select on public.shaar_app_central to authenticated;

-- O TETELESTAI ja obedece desde a migracao 002: fica registado com a data
-- verdadeira, nao com a de agora.
insert into public.shaar_app_central (app_code, desde, motivo)
values ('TETELESTAI', timestamptz '2026-09-06 13:38:00+00',
        'Primeira aplicacao com modelo antigo a trocar. Divergencia real medida '
        'contra a funcao antiga: ninguem perde acesso, 65 respostas em que tres '
        'pessoas sem auth_user_id passam a conseguir trabalhar, todas com revisao '
        'aberta.')
on conflict (app_code) do nothing;


-- ---------------------------------------------------------------------
-- 3. O INTERRUPTOR DEIXA DE SABER NOMES
-- ---------------------------------------------------------------------
do $mig$
declare
  v_oid  oid;
  v_n    int;
  v_args text;
begin
  select count(*), min(p.oid) into v_n, v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'jireh_has_permission';

  if v_n <> 1 then
    raise exception 'jireh_has_permission tem % assinaturas; esperava uma', v_n;
  end if;

  v_args := pg_get_function_arguments(v_oid);

  execute format($tpl$
    create or replace function public.jireh_has_permission(%s)
    returns boolean
    language sql
    stable
    security definer
    set search_path to 'public'
    as $corpo$
      select coalesce(
        (select public.shaar_pode(sp.app_code, sp.code)
           from public.shaar_permission sp
           join public.shaar_app_central c on c.app_code = sp.app_code
          where sp.code = $1
            and sp.origem = 'herdado'
            and sp.active
          limit 1),
        public.jireh_has_permission_legado($1));
    $corpo$
  $tpl$, v_args);
end
$mig$;

-- Nota sobre o coalesce: `shaar_pode` nunca devolve nulo, portanto a
-- subconsulta so da nulo quando NAO ENCONTRA linha — ou seja, quando o
-- codigo nao pertence a nenhuma aplicacao que ja obedeca. E exactamente
-- nesse caso que se quer o caminho antigo. Se `shaar_pode` alguma vez
-- passar a poder devolver nulo, isto tem de deixar de ser um coalesce.


-- ---------------------------------------------------------------------
-- Conferencia
-- ---------------------------------------------------------------------
select 'aplicacoes a obedecer: ' ||
       coalesce(string_agg(app_code, ', ' order by app_code), 'nenhuma')
  from public.shaar_app_central;

select 'controlo: '            || r.controlo_positivos::text ||
       ' | perde: '            || r.perdia            ::text ||
       ' | ganha sem revisao: '|| r.ganha_sem_revisao ::text ||
       ' | ganha com revisao: '|| (r.ganharia - r.ganha_sem_revisao)::text
  from public.shaar_divergencia_real_resumo('TETELESTAI') r;

select 'divergencia modelada: ' || count(*)::text
  from public.shaar_permissao_divergencias;

-- Fumo: um codigo de aplicacao ja trocada e um codigo que ainda nao trocou.
select 'TETELESTAI (trocada): ' ||
       coalesce(public.has_permission('todo.create'::varchar)::text, 'nulo');
select 'JIREH (por trocar): '   ||
       coalesce(public.has_permission('audit:read'::varchar)::text, 'nulo');
