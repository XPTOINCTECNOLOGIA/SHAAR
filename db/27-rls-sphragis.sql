-- =====================================================================
-- Fase 5 — troca de autoridade: SPHRAGIS
-- =====================================================================
--
-- Primeira aplicação a passar a obedecer à Central. É o ensaio limpo por
-- duas razões que não se repetem nas outras sete:
--
--   · o SPHRAGIS nunca teve modelo de permissões. Quem passava o portão
--     podia tudo. Não há nada a partir, porque não há nada a substituir.
--   · as três pessoas com o portão aberto receberam, no espelho, as oito
--     permissões do catálogo. Ligar isto hoje não tira nada a ninguém —
--     o que muda é passar a haver um sítio onde recortar.
--
-- COMO, e é a parte que importa: as políticas novas são RESTRICTIVE.
--
-- Políticas permissivas combinam-se com OR: acrescentar uma alarga o
-- acesso. Restritivas combinam-se com AND: acrescentar uma só pode
-- estreitar. Trocar as duas é o erro que abre acesso em silêncio, e é por
-- isso que aqui vai escrito em maiúsculas.
--
-- O que o SPHRAGIS já tinha — posse (`created_by = sphragis_current_user_id()`),
-- o próprio perfil de assinatura, o dono do documento — fica exactamente
-- como está. Passa a valer isso E a permissão. Ninguém ganha acesso novo
-- por causa deste ficheiro; no limite, perde-se.
--
-- E são `to authenticated` de propósito. O caminho de quem assina de fora,
-- por link e OTP, é anónimo e servido por funções com service_role, que
-- ignoram RLS. Apertar `anon` aqui partiria a assinatura externa sem que
-- isso tivesse nada a ver com permissões de gente da casa.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- DOCUMENTOS
-- ---------------------------------------------------------------------
drop policy if exists sphragis_perm_documents_select on public.sphragis_documents;
create policy sphragis_perm_documents_select
  on public.sphragis_documents as restrictive for select to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.consultar'));

drop policy if exists sphragis_perm_documents_insert on public.sphragis_documents;
create policy sphragis_perm_documents_insert
  on public.sphragis_documents as restrictive for insert to authenticated
  with check (public.shaar_pode('SPHRAGIS','documento.criar'));

-- Actualizar um documento é acompanhá-lo (reenviar, marcar andamento) ou
-- continuar a prepará-lo. Qualquer das duas serve; exigir as duas seria
-- estreitar mais do que o que se passa hoje.
drop policy if exists sphragis_perm_documents_update on public.sphragis_documents;
create policy sphragis_perm_documents_update
  on public.sphragis_documents as restrictive for update to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.acompanhar')
         or public.shaar_pode('SPHRAGIS','documento.criar'))
  with check (public.shaar_pode('SPHRAGIS','documento.acompanhar')
         or public.shaar_pode('SPHRAGIS','documento.criar'));

-- Apagar continua sem política permissiva, portanto continua negado a
-- toda a gente pela via do cliente. A restritiva fica aqui para o dia em
-- que alguém abrir a permissiva: nesse dia já não é preciso lembrar-se
-- de que apagar tem de exigir permissão.
drop policy if exists sphragis_perm_documents_delete on public.sphragis_documents;
create policy sphragis_perm_documents_delete
  on public.sphragis_documents as restrictive for delete to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.excluir'));

-- ---------------------------------------------------------------------
-- SIGNATÁRIOS E CAMPOS DE ASSINATURA
-- ---------------------------------------------------------------------
drop policy if exists sphragis_perm_signatarios_select on public.sphragis_signatarios;
create policy sphragis_perm_signatarios_select
  on public.sphragis_signatarios as restrictive for select to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.consultar'));

drop policy if exists sphragis_perm_fields_select on public.sphragis_signature_fields;
create policy sphragis_perm_fields_select
  on public.sphragis_signature_fields as restrictive for select to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.consultar'));

drop policy if exists sphragis_perm_fields_insert on public.sphragis_signature_fields;
create policy sphragis_perm_fields_insert
  on public.sphragis_signature_fields as restrictive for insert to authenticated
  with check (public.shaar_pode('SPHRAGIS','documento.criar'));

-- ---------------------------------------------------------------------
-- PERFIL DE ASSINATURA — a rubrica da própria pessoa
-- ---------------------------------------------------------------------
-- Já é self-scoped (auth.uid() = auth_user_id). Passa a exigir também a
-- permissão de assinar: quem não assina não precisa de rubrica guardada.
drop policy if exists sphragis_perm_perfis_select on public.sphragis_perfis_assinatura;
create policy sphragis_perm_perfis_select
  on public.sphragis_perfis_assinatura as restrictive for select to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.assinar'));

drop policy if exists sphragis_perm_perfis_insert on public.sphragis_perfis_assinatura;
create policy sphragis_perm_perfis_insert
  on public.sphragis_perfis_assinatura as restrictive for insert to authenticated
  with check (public.shaar_pode('SPHRAGIS','documento.assinar'));

drop policy if exists sphragis_perm_perfis_update on public.sphragis_perfis_assinatura;
create policy sphragis_perm_perfis_update
  on public.sphragis_perfis_assinatura as restrictive for update to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.assinar'))
  with check (public.shaar_pode('SPHRAGIS','documento.assinar'));

drop policy if exists sphragis_perm_perfis_delete on public.sphragis_perfis_assinatura;
create policy sphragis_perm_perfis_delete
  on public.sphragis_perfis_assinatura as restrictive for delete to authenticated
  using (public.shaar_pode('SPHRAGIS','documento.assinar'));

-- ---------------------------------------------------------------------
-- AUDITORIA
-- ---------------------------------------------------------------------
drop policy if exists sphragis_perm_audit_select on public.sphragis_audit_logs;
create policy sphragis_perm_audit_select
  on public.sphragis_audit_logs as restrictive for select to authenticated
  using (public.shaar_pode('SPHRAGIS','auditoria.consultar'));

commit;

-- ---------------------------------------------------------------------
-- Conferência: quem tinha acesso continua a ter
-- ---------------------------------------------------------------------
-- As três pessoas com o portão do SPHRAGIS receberam as oito permissões no
-- espelho. shaar_pode devolve verdadeiro para todas, portanto o AND das
-- restritivas não muda nada. Se alguma linha abaixo der `f`, algo está
-- errado e reverte-se apagando as políticas `sphragis_perm_*`.
select u.full_name,
       public.shaar_pode('SPHRAGIS','documento.consultar','{}'::jsonb,u.id) as consultar,
       public.shaar_pode('SPHRAGIS','documento.criar','{}'::jsonb,u.id)     as criar,
       public.shaar_pode('SPHRAGIS','documento.assinar','{}'::jsonb,u.id)   as assinar,
       public.shaar_pode('SPHRAGIS','documento.excluir','{}'::jsonb,u.id)   as excluir,
       public.shaar_pode('SPHRAGIS','auditoria.consultar','{}'::jsonb,u.id) as auditar
  from public.users u
  join public.shaar_gate_access g on g.user_id = u.id and g.app_code = 'SPHRAGIS'
 order by u.full_name;
