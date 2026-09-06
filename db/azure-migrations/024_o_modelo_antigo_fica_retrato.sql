-- =====================================================================
-- O modelo antigo passa a ser retrato, e deixa de ser autoridade
-- =====================================================================
--
-- O dono: «com a central de permissionamento não devemos mais condicionar
-- permissões a perfis».
--
-- A decisão já não depende de perfis: `shaar_pode` lê o portão, a concessão, o
-- escopo e a negação, e mais nada. Mas a VIGILÂNCIA depende, e de uma maneira
-- que torna a Central inutilizável para aquilo que ela é:
--
--   `shaar_permissao_verdade_antiga` é recalculada AO VIVO a partir de
--   `profile_permissions`. Dela saem DIVERGENCIA e DIREITOS_POR_GUARDAR, que
--   põem o relatório vermelho. Portanto:
--
--     conceder a alguém algo que o perfil dele não tem  -> vermelho
--     retirar a alguém algo que o perfil dele tem       -> vermelho
--     alguém editar um perfil                           -> vermelho
--
--   Hoje está tudo a zero não porque esteja certo, mas porque ninguém ainda
--   tomou uma decisão individual. O dia em que a Central for usada para aquilo
--   que existe é o dia em que o painel fica vermelho.
--
-- O QUE ESTE FICHEIRO FAZ
-- -----------------------
-- Congela. O modelo antigo passa a ser um RETRATO datado — verdadeiro para
-- sempre porque datado — em vez de uma verdade recalculada a cada leitura. A
-- diferença entre o retrato e a Central deixa de ser um alarme e passa a ser o
-- que é: a lista das decisões tomadas desde a migração, que cresce quando se
-- decide e é suposto crescer.
--
-- O RAMO DO CARGO CFO, e porque não se apaga
-- ------------------------------------------
-- Aquele ramo diz que quem ocupa o cargo de CFO tem, por isso, as 63 permissões
-- do perfil FINANCEIRO. Hoje não faz nada — DIREITOS_POR_GUARDAR está a zero, o
-- que prova que tudo o que ele produz já existe como concessão individual. Mas
-- no dia em que o CFO mudar exigiria 63 concessões para quem entrasse, sem
-- ninguém ter decidido, e marcaria como divergência as concessões de quem
-- saísse. Herança automática por cargo, a entrar pela porta da vigilância
-- depois de ter saído pela porta da decisão — e a contradizer em silêncio a
-- revisão que a 002 deixou aberta precisamente para isso.
--
-- Não se apaga: apagar perdia a memória de uma regra que EXISTIU, decidida em
-- 25/08. Congela-se. A regra fica guardada em texto, tal como a base a
-- escreve — sem eu a transcrever — e deixa de poder forçar comportamento.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. A DEFINIÇÃO DA REGRA, GUARDADA TAL COMO ESTÁ
-- ---------------------------------------------------------------------
-- `pg_get_viewdef` faz a base descrever-se a si própria. É a mesma técnica que
-- usei para copiar corpos de funções: o que se guarda é o que lá está, e não a
-- minha leitura do que lá está.
create table if not exists public.shaar_modelo_antigo_definicao (
  retratado_em timestamptz primary key default now(),
  definicao    text not null,
  nota         text
);

insert into public.shaar_modelo_antigo_definicao (retratado_em, definicao, nota)
select now(),
       pg_get_viewdef('public.shaar_permissao_verdade_antiga'::regclass, true),
       'Definicao da verdade antiga no momento em que deixou de ser recalculada '
    || 'ao vivo. Inclui o ramo do cargo CFO -> perfil FINANCEIRO (decisao de '
    || '25/08). Guardada para que a regra continue conhecida depois de deixar '
    || 'de valer.'
 where not exists (select 1 from public.shaar_modelo_antigo_definicao);


-- ---------------------------------------------------------------------
-- 2. O RETRATO DAS LINHAS
-- ---------------------------------------------------------------------
create table if not exists public.shaar_modelo_antigo_retrato (
  user_id      bigint not null references public.users(id) on delete cascade,
  app_code     text   not null,
  code         text   not null,
  retratado_em timestamptz not null default now(),
  primary key (user_id, app_code, code)
);

comment on table public.shaar_modelo_antigo_retrato is
  'O que o modelo antigo conferia a cada pessoa no momento da migracao. E um '
  'retrato datado, nao uma verdade viva: nao se recalcula, nao se actualiza '
  'quando um perfil muda, e nao e autoridade sobre coisa nenhuma. Serve para '
  'responder a uma pergunta so — o que mudou desde entao, e por decisao de quem.';

-- Copiado da propria vista, e nao reescrito ramo a ramo: transcrever cinco
-- ramos a mao era a forma mais provavel de o retrato sair diferente do
-- original. So enche se estiver vazio — o retrato tira-se uma vez.
do $mig$
declare v_n int;
begin
  if exists (select 1 from public.shaar_modelo_antigo_retrato) then
    raise notice 'o retrato ja existe; nada a fazer';
    return;
  end if;

  insert into public.shaar_modelo_antigo_retrato (user_id, app_code, code)
  select distinct user_id, app_code, code
    from public.shaar_permissao_verdade_antiga
  on conflict do nothing;

  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception
      'o retrato saiu vazio. A vista do modelo antigo devolveu zero linhas, o '
      'que nao pode estar certo — congelar um retrato vazio apagava a memoria '
      'toda de uma vez.';
  end if;
  raise notice 'retrato do modelo antigo: % direitos', v_n;
end
$mig$;


-- ---------------------------------------------------------------------
-- 3. A VISTA PASSA A LER O RETRATO
-- ---------------------------------------------------------------------
-- Mesmo nome e mesmas colunas de proposito: tudo o que a consulta continua a
-- funcionar, e o que muda e a fonte por baixo. A partir daqui, editar um perfil
-- nao mexe no que a Central e comparada.
create or replace view public.shaar_permissao_verdade_antiga as
  select user_id, app_code, code
    from public.shaar_modelo_antigo_retrato;

comment on view public.shaar_permissao_verdade_antiga is
  'RETRATO do modelo antigo a data da migracao. Ja nao le perfis nem cargos: le '
  'a tabela shaar_modelo_antigo_retrato. Mantem o nome para nao partir as '
  'consultas que a usam, mas deixou de ser "a verdade" — e a memoria de uma.';


-- ---------------------------------------------------------------------
-- 4. A DIFERENÇA PASSA A CHAMAR-SE PELO NOME
-- ---------------------------------------------------------------------
-- Uma pessoa com uma permissao que o modelo antigo nao lhe dava nao e uma
-- divergencia: e uma concessao decidida. Uma pessoa sem uma permissao que o
-- modelo antigo lhe dava nao e um erro: e uma revogacao decidida. O sistema foi
-- construido para que isto aconteca.
create or replace function public.shaar_decisoes_desde_a_migracao()
returns table (tipo text, quantas bigint, pessoas bigint, aplicacoes text)
language sql stable security definer set search_path = public as $fn$
  select case d.divergencia
           when 'so_na_central'      then 'concedido desde a migracao'
           when 'so_no_modelo_antigo' then 'revogado desde a migracao'
           else d.divergencia
         end                                              as tipo,
         count(*)                                         as quantas,
         count(distinct d.user_id)                        as pessoas,
         string_agg(distinct d.app_code, ', ')            as aplicacoes
    from public.shaar_permissao_divergencias d
   group by 1
   order by 2 desc;
$fn$;

grant execute on function public.shaar_decisoes_desde_a_migracao() to authenticated;


-- ---------------------------------------------------------------------
-- 5. O QUE PASSA A MERECER ALARME
-- ---------------------------------------------------------------------
-- A pergunta deixa de ser «isto continua igual ao modelo antigo?» — que
-- proibia decidir — e passa a ser «toda a mudanca teve uma decisao por tras?».
-- Essa continua a valer daqui a dez anos, quando o modelo antigo nao for
-- memoria de ninguem.
create or replace function public.shaar_integridade_do_registo()
returns table (indicador text, valor bigint, explicacao text)
language sql stable security definer set search_path = public as $fn$
  -- O gatilho que escreve o historico existe e esta ligado?
  select 'gatilho_de_registo_desligado'::text,
         count(*) filter (where t.tgenabled = 'D' or t.oid is null),
         'O gatilho shaar_grant_auditar escreve o historico a cada concessao. '
      || 'Desligado, as mudancas deixam de ser registadas e tudo o resto aqui '
      || 'deixa de significar nada.'::text
    from (select 1) x
    left join pg_trigger t
      on t.tgname = 'shaar_grant_auditar'
     and t.tgrelid = 'public.shaar_permission_grant'::regclass
     and not t.tgisinternal

  union all
  -- Concessoes activas sem um unico evento no historico.
  select 'concessoes_sem_registo',
         count(*),
         'Concessoes activas para as quais o historico nao tem evento nenhum. '
      || 'Uma permissao que aparece sem deixar rasto e uma permissao que '
      || 'ninguem decidiu.'
    from public.shaar_permission_grant g
   where not exists (
     select 1 from public.shaar_permission_event e
      where e.user_id = g.user_id and e.app_code = g.app_code and e.code = g.code)

  union all
  -- Concessoes sem motivo escrito.
  select 'concessoes_sem_motivo',
         count(*),
         'Concessoes sem motivo. Uma decisao sem razao escrita nao se consegue '
      || 'rever: daqui a um ano ninguem sabe se ainda faz sentido.'
    from public.shaar_permission_grant g
   where g.motivo is null or length(trim(g.motivo)) = 0

  union all
  -- O historico continua a nao poder ser editado?
  select 'historico_editavel',
         case when has_table_privilege('authenticated','public.shaar_permission_event','UPDATE')
                or has_table_privilege('authenticated','public.shaar_permission_event','DELETE')
              then 1 else 0 end,
         'Se o historico puder ser editado, deixa de ser historico e passa a ser '
      || 'uma opiniao sobre o passado.';
$fn$;

grant execute on function public.shaar_integridade_do_registo() to authenticated;


-- ---------------------------------------------------------------------
-- Conferência
-- ---------------------------------------------------------------------
select 'retrato: ' || count(*)::text || ' direitos, '
       || count(distinct user_id)::text || ' pessoas'
  from public.shaar_modelo_antigo_retrato;

select 'definicao guardada: ' || length(definicao)::text || ' caracteres'
  from public.shaar_modelo_antigo_definicao;

select 'DECISAO ' || tipo || ': ' || quantas::text || ' (' || pessoas::text
       || ' pessoas, ' || aplicacoes || ')'
  from public.shaar_decisoes_desde_a_migracao();

select 'INTEGRIDADE ' || indicador || ': ' || valor::text
  from public.shaar_integridade_do_registo();

-- A prova de que congelar nao mexeu em nada: a diferenca continua a ser a que
-- era ha um minuto. Se o retrato tivesse saido diferente da vista, isto
-- apanhava-o e o ficheiro nao entrava.
do $mig$
declare v_n int;
begin
  select count(*) into v_n from public.shaar_permissao_divergencias;
  if v_n <> 0 then
    raise exception
      'depois de congelar, a diferenca entre a Central e o retrato e de % linhas '
      'quando era zero. O retrato nao saiu igual a vista — nada disto entra.', v_n;
  end if;
  raise notice 'congelado sem alterar nada: a diferenca continua zero';
end
$mig$;
