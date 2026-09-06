# Permissões no ecossistema XPTO — leia antes de criar ou verificar qualquer permissão

Documento para agentes e programadores que trabalham em qualquer uma das nove
aplicações (SHAAR, TETELESTAI, JIREH, FAITH, TIKKUN, MANNA, BNEI YISRAEL,
SPHRAGIS, MERKAVAH). Vale para todas.

Desde Setembro de 2026 o permissionamento é **individual e centralizado**. Podem
criar-se permissões novas à vontade — o que não se pode é criá-las fora da
Central, nem confundi-las com regras de negócio.

---

## 1. Quem decide: `shaar_pode`, e mais nada

Uma pessoa pode fazer X numa aplicação se, e só se:

```sql
public.shaar_pode('APP', 'codigo.da.permissao')   -- devolve boolean
```

Essa função lê **quatro** coisas e nenhuma outra:

1. o **portão** — a pessoa tem acesso àquela aplicação (`shaar_gate_access`);
2. a **concessão individual** — permitir, dentro da validade (`shaar_permission_grant`);
3. o **escopo** da concessão — tecto por valor, lista por departamento, piso por nível;
4. a ausência de **negação explícita**.

**Nunca** faça uma decisão de autorização a partir de:

- `users.profile_id` / `profiles` / `profile_permissions` — perfil **não é
  autoridade**. É legado; no máximo serve de molde para semear concessões
  quando se cria uma pessoa.
- `users.position_id` / `positions` — cargo é ofício, não permissão. Já houve
  uma regra "quem é CFO exerce o perfil FINANCEIRO"; foi convertida em
  concessões individuais precisamente porque mudava de comportamento sozinha
  quando a pessoa do cargo mudasse.
- papéis próprios da aplicação (`*_user_roles`) — foram traduzidos para o
  catálogo; não acrescente novos.

Se escrever código que pergunta "qual é o perfil dele?" para decidir, está a
reconstruir o mundo que a Central substituiu.

---

## 2. Portão e permissão são INDEPENDENTES

A **permissão é da pessoa** e fica registada mesmo que ela não tenha o portão
aberto. O **portão** diz se ela entra hoje. Abre-se e fecha-se a qualquer
momento, e as permissões acompanham.

Consequência prática: "esta pessoa tem uma permissão numa aplicação onde não
entra" **não é incoerência** — é o estado normal. Não escreva código, nem
alarmes, que tratem isso como erro.

---

## 3. Permissão NÃO é regra de negócio

Esta é a distinção que mais custa dinheiro quando se erra.

| | **Permissão** | **Regra de negócio** |
|---|---|---|
| Responde a | *esta pessoa pode fazer este tipo de coisa?* | *este acto concreto é aceitável?* |
| Depende de | **quem** pergunta | **qual** registo, em que **estado**, e quem lhe mexeu antes |
| Vive em | na Central, como concessão | na aplicação, no código |
| Muda por | decisão de quem gere permissões | alteração da aplicação |

**Teste rápido:** se a resposta muda consoante o registo em causa, é regra de
negócio. Se depende só de quem está a perguntar, é permissão.

Exemplos reais deste ecossistema:

- **JIREH** — `jireh_multilevel_workflow.sql:181` e `:693`:
  `requester_id <> actor_id`. O requerente **não** aprova o próprio reembolso,
  tenha a permissão que tiver. A regra de negócio supera a permissão.
- **MANNA** — escrever o parecer técnico e decidir sobre ele passam pela
  **mesma** permissão (`purchase-analysis.decide`); dar a anuência e liquidar,
  pela mesma (`finance.settle`). O que separa os passos é a máquina de estados
  e o rasto: separa os **momentos**, não as **mãos**.
- **SPHRAGIS / TIKKUN** — posse (`created_by`, o técnico e a sua própria OS) é
  regra de negócio, não permissão.

### Dois erros a não repetir

1. **Não implemente uma regra de negócio como permissão.** Se a regra depende do
   registo, nenhuma concessão a consegue exprimir.
2. **Não infira uma regra de negócio a partir de quem tem que permissões.** Ter
   `criar` e `aprovar` não prova que alguém criou e aprovou a mesma coisa. Para
   isso lê-se o **rasto** — `created_by`, `decided_by`, `authored_by`,
   `consented_by`, `settled_by`, `actor_id` — que é onde os actos estão
   escritos. Ver `public.shaar_segregacao_no_rasto`.

---

## 4. Como criar uma permissão nova

Toda a mudança de estrutura vai num `.sql` numerado em
**`db/azure-migrations/`** do repositório **SHAAR**, aplicado automaticamente
ao dar merge na branch padrão. Nunca use as ferramentas Supabase (MCP) nem o
sistema antigo de migrations: apontam para o projeto congelado.

**Passo 1 — pôr no catálogo:**

```sql
insert into public.shaar_permission
  (app_code, code, name, description, grupo, sort_order, origem)
values
 ('MINHA_APP', 'recurso.accao', 'Nome legível',
  'O que esta permissão deixa fazer, em português e sem jargão.',
  'grupo_no_ecra', 10, 'aplicacao')
on conflict (app_code, code) do update
  set name = excluded.name, description = excluded.description, active = true;
```

`origem`: `'aplicacao'` para permissões novas; `'herdado'` é para as que vieram
do modelo antigo; `'derivado'` para as da própria Central.

**Passo 2 — impor no sítio onde a decisão acontece.** Em política RLS use
**restritiva** (combinam com AND — só podem estreitar; permissivas combinam com
OR e alargam):

```sql
create policy minha_app_perm_select
  on public.minha_tabela as restrictive for select to authenticated
  using (public.shaar_pode('MINHA_APP','recurso.consultar'));
```

Ou, numa função RPC:

```sql
if not public.shaar_pode('MINHA_APP','recurso.accao') then
  raise exception 'FORBIDDEN: recurso.accao';
end if;
```

**Passo 3 — conceder a quem deve ter.** Nunca por adivinhação, nunca em massa
por perfil ou cargo. Cada concessão leva um **motivo escrito** — sem ele não se
consegue rever daqui a um ano, e o relatório fica vermelho:

```sql
insert into public.shaar_permission_grant
  (user_id, app_code, code, efeito, escopo, motivo, granted_by, granted_at)
values (<id>, 'MINHA_APP', 'recurso.accao', 'permitir', '{}'::jsonb,
        'motivo concreto e a decisão que o originou', <quem>, now());
```

Um gatilho escreve o histórico sozinho — não o escreva à mão.

**Passo 4 — se a permissão pede alçada**, declare as dimensões de escopo
(`escopo_dimensoes`: `valor_max`, `departamento`, `nivel_min`) e passe o
contexto na chamada: `shaar_pode('APP','code','{"valor":40000}'::jsonb)`.
Regra que torna isto seguro: **dimensão declarada e ausente do contexto NEGA**.
Falha fechado, nunca "sim por omissão".

---

## 5. O que nunca pode partir

O relatório nocturno "Estado da Central" fica **vermelho** se:

- o gatilho `shaar_grant_auditar` estiver desligado — sem registo não há decisão;
- houver concessão activa **sem evento** no histórico, ou **sem motivo**;
- o histórico de permissões passar a ser editável;
- um e-mail resolver para mais do que uma pessoa, ou houver e-mail vazio;
- algum caso de referência falhar (`shaar_correr_testes`, `..._escopo`).

Repare no que **não** está nesta lista: a Central diferir do modelo antigo de
perfis. Isso é informação — são as decisões tomadas desde a migração, e é
suposto crescer.

---

## 6. Antes de abrir o PR

- [ ] A permissão está no catálogo, com descrição que uma pessoa entende.
- [ ] A decisão passa por `shaar_pode` — não por perfil, cargo ou papel.
- [ ] Se é regra de negócio, ficou no código da aplicação e **não** virou permissão.
- [ ] As políticas novas são `restrictive` (a menos que a intenção seja mesmo alargar).
- [ ] As concessões têm motivo escrito e não foram semeadas por perfil.
- [ ] Se há alçada, a dimensão está declarada e o contexto é passado na chamada.
- [ ] O ficheiro está em `db/azure-migrations/`, numerado, sem `begin;`/`commit;`
      próprios (o pipeline corre em transacção única) e idempotente.

---

## 7. Três pedras em que já tropeçámos, no mesmo dia

Não são teoria: aconteceram todas em 06/09/2026, e custaram tempo a mais do que
uma pessoa.

**Uma migração falhada bloqueia TODA a gente.** O pipeline corre em transacção
única e por ordem de nome de ficheiro. Um ficheiro que rebente impede a sua
migração e todas as seguintes, de qualquer agente, até ser corrigido — e o
sintoma é a sua migração «não ter entrado» sem razão aparente. Se a sua não
aparecer aplicada, veja o log do workflow antes de mexer no seu ficheiro: pode
não ser seu o defeito. E se encontrar um ficheiro alheio a rebentar, corrija-o
— é mais urgente do que aquilo que estava a fazer.

**`create or replace function` NÃO muda o tipo de retorno.** Rebenta com
`cannot change return type of existing function`. É preciso
`drop function if exists ...` antes — e o `drop` leva a ACL consigo, portanto o
`grant execute` tem de vir a seguir. Antes de criar uma função, procure se já
existe uma com esse nome: se existir com outra assinatura, provavelmente há
duas ideias diferentes com o mesmo nome, e a decisão não é técnica.

**Dois agentes escolhem o mesmo número.** Aconteceu com o `028`. Antes de
nomear o ficheiro, faça `git fetch` e olhe para o que já lá está; ao rebentar
um push por o remoto estar à frente, renumere em vez de forçar. Nada se parte
se dois ficheiros partilharem o número — a ordem é por nome e o registo é por
ficheiro — mas o histórico fica ilegível para quem vier a seguir.

---

## 8. Em caso de dúvida

Meça em vez de assumir. A base sabe responder:

```sql
select * from public.shaar_porque('APP','codigo');          -- porque sim ou porque não
select * from public.shaar_correr_testes();                 -- casos de referência
select * from public.shaar_segregacao_resumo();             -- actos, não detenção
select * from public.shaar_integridade_do_registo();         -- o que tem de estar a zero
```
