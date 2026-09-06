-- =====================================================================
-- Central de Permissionamento — carga do catálogo
-- =====================================================================
--
-- O catálogo actual (public.permissions) é achatado: 96 permissões num
-- espaço de nomes só, lido por seis aplicações. `dashboard.view` não diz de
-- quem é. Este ficheiro dá dono a cada uma, pela coluna `module` cruzada com
-- onde o código é efectivamente usado em cada repositório:
--
--   todo · user · vertical · position · rbac · settings · analytics ·
--   audit · alert · operation · strategic_room · melhorias  -> TETELESTAI
--   oportunidades                                            -> FAITH
--   jireh · JIREH · CORE                                     -> JIREH
--   MANNA                                                    -> MANNA
--   MERKAVAH                                                 -> MERKAVAH
--
-- Três aplicações não tinham catálogo nenhum e são criadas aqui a partir do
-- que hoje decidem por papel (BNEI, TIKKUN) ou não decidem de todo
-- (SPHRAGIS, onde quem passa o portão pode tudo). O catálogo destas três
-- descreve o que já acontece — não acrescenta nem tira nada a ninguém.
--
-- Nada neste ficheiro concede o que quer que seja. Catálogo é a lista do que
-- PODE ser concedido; quem tem o quê vem no ficheiro seguinte.
-- =====================================================================

begin;

-- Alguns códigos existentes têm hífen (purchase-analysis.decide). A forma
-- aceita-o; o que não se aceita é maiúscula, espaço ou texto livre vindo do
-- cliente, que é por onde um catálogo se transforma em superfície de ataque.
alter table public.shaar_permission drop constraint if exists shaar_permission_forma;
alter table public.shaar_permission add constraint shaar_permission_forma
  check (code ~ '^[a-z][a-z0-9_-]*([.:][a-z][a-z0-9_-]*)+$');

-- O SHAAR é ele próprio uma aplicação com permissões — gerir a Central é uma
-- permissão como as outras. Fica inactivo para não aparecer como portão no
-- Quadro: ninguém "entra no SHAAR" clicando num portão, já lá está.
insert into public.shaar_apps (code, name, description, url, sort_order, active, released)
values ('SHAAR','SHAAR','Hub de acesso e Central de Permissionamento',
        'https://shaar.xptoinc.com.br', 0, false, true)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- As 96 herdadas
-- ---------------------------------------------------------------------
insert into public.shaar_permission
  (app_code, code, name, description, grupo, sort_order, active, origem)
select
  case p.module
    when 'oportunidades' then 'FAITH'
    when 'MANNA'         then 'MANNA'
    when 'MERKAVAH'      then 'MERKAVAH'
    when 'jireh'         then 'JIREH'
    when 'JIREH'         then 'JIREH'
    when 'CORE'          then 'JIREH'
    else 'TETELESTAI'
  end,
  p.code, p.name, coalesce(p.description,''),
  case p.module
    when 'oportunidades' then 'oportunidades'
    when 'MANNA'         then split_part(p.code, '.', 1)
    when 'MERKAVAH'      then coalesce(nullif(split_part(p.code, '.', 2), ''), 'geral')
    when 'jireh'         then split_part(p.code, ':', 1)
    when 'JIREH'         then split_part(p.code, ':', 1)
    when 'CORE'          then split_part(p.code, ':', 1)
    else coalesce(p.module, 'geral')
  end,
  p.id, coalesce(p.active, true), 'herdado'
from public.permissions p
on conflict (app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- Dimensões de escopo das permissões que pedem alçada
-- ---------------------------------------------------------------------
-- Declarar a dimensão não limita ninguém: só diz à tela que campos oferecer.
-- O limite concreto vive na concessão, e enquanto lá não estiver, a permissão
-- é global — exactamente como é hoje.
update public.shaar_permission set escopo_dimensoes = array['departamento','valor_max']
 where (app_code, code) in (
   ('JIREH','reimbursements:approve_manager'),
   ('JIREH','reimbursements:approve_finance'),
   ('JIREH','reimbursements:approve_hierarchy'),
   ('JIREH','payments:manage'));

update public.shaar_permission set escopo_dimensoes = array['valor_max']
 where (app_code, code) in (
   ('MANNA','quotation.approve'),
   ('MANNA','purchase-analysis.decide'),
   ('MANNA','finance.settle'),
   ('MANNA','finance.consent'),
   ('FAITH','opp.doc.approve'),
   ('FAITH','opp.close'));

update public.shaar_permission set escopo_dimensoes = array['nivel_min']
 where (app_code, code) in (('TETELESTAI','operation.approve'));

update public.shaar_permission set escopo_dimensoes = array['departamento']
 where (app_code, code) in (('TETELESTAI','todo.view_all'), ('MANNA','reports.manage'));

-- ---------------------------------------------------------------------
-- BNEI YISRAEL — governança de pessoas, contratos, finanças e compliance
-- ---------------------------------------------------------------------
-- Hoje decide por papel: admin (3 pessoas), gestor (11), consulta (27).
-- O catálogo abaixo descreve o que cada papel já faz.
insert into public.shaar_permission (app_code, code, name, description, grupo, sort_order, origem) values
 ('BNEI','pessoa.consultar','Consultar quadro de pessoas','Ver o quadro de pessoas e os seus dados de cadastro','pessoas',10,'derivado'),
 ('BNEI','pessoa.gerir','Gerir pessoas','Criar e editar registos de pessoas','pessoas',20,'derivado'),
 ('BNEI','contrato.consultar','Consultar contratos','Ver contratos e respectivos prazos','contratos',30,'derivado'),
 ('BNEI','contrato.gerir','Gerir contratos','Criar, editar e encerrar contratos','contratos',40,'derivado'),
 ('BNEI','financeiro.consultar','Consultar dados financeiros','Ver valores, centros de custo e vínculos financeiros','financeiro',50,'derivado'),
 ('BNEI','financeiro.gerir','Gerir dados financeiros','Alterar valores e vínculos financeiros','financeiro',60,'derivado'),
 ('BNEI','compliance.consultar','Consultar compliance','Ver a trilha de conformidade','compliance',70,'derivado'),
 ('BNEI','compliance.gerir','Gerir compliance','Registar e encerrar ocorrências de conformidade','compliance',80,'derivado'),
 ('BNEI','configuracao.gerir','Configurar a aplicação','Parâmetros gerais do BNEI YISRAEL','administracao',90,'derivado')
on conflict (app_code, code) do nothing;

update public.shaar_permission set escopo_dimensoes = array['departamento']
 where app_code = 'BNEI' and code in ('pessoa.consultar','contrato.consultar','financeiro.consultar');

-- ---------------------------------------------------------------------
-- TIKKUN — ordens de serviço
-- ---------------------------------------------------------------------
-- Hoje decide por papel: administrador (1), gestor (2), supervisor (1),
-- tecnico (8). Nota para a fase de desmontagem: tikkun_user_roles guarda
-- também custo_hora, que é dado de negócio e não permissão — essa coluna
-- muda de casa antes de a tabela sair.
insert into public.shaar_permission (app_code, code, name, description, grupo, sort_order, origem) values
 ('TIKKUN','os.consultar','Consultar ordens de serviço','Ver ordens de serviço e o seu estado','ordens',10,'derivado'),
 ('TIKKUN','os.criar','Abrir ordem de serviço','Criar novas ordens de serviço','ordens',20,'derivado'),
 ('TIKKUN','os.executar','Executar ordem de serviço','Registar execução e apontamentos','ordens',30,'derivado'),
 ('TIKKUN','os.assinar','Assinar ordem de serviço','Recolher e apor assinaturas de execução','ordens',40,'derivado'),
 ('TIKKUN','os.aprovar','Aprovar ordem de serviço','Aprovar ou devolver ordens executadas','ordens',50,'derivado'),
 ('TIKKUN','equipa.gerir','Gerir equipa','Atribuir técnicos e supervisores','equipa',60,'derivado'),
 ('TIKKUN','custo.consultar','Consultar custos','Ver custo-hora e custo das ordens','custos',70,'derivado'),
 ('TIKKUN','relatorio.consultar','Consultar relatórios','Indicadores de execução','relatorios',80,'derivado'),
 ('TIKKUN','configuracao.gerir','Configurar a aplicação','Parâmetros gerais do TIKKUN','administracao',90,'derivado')
on conflict (app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- SPHRAGIS — assinatura de documentos
-- ---------------------------------------------------------------------
-- Não tem modelo de permissão nenhum: quem passa o portão pode tudo. O
-- catálogo torna isso explícito, e é por isso que o SPHRAGIS é o primeiro a
-- trocar de autoridade — não há nada a partir.
insert into public.shaar_permission (app_code, code, name, description, grupo, sort_order, origem) values
 ('SPHRAGIS','documento.consultar','Consultar documentos','Ver documentos e o seu estado de assinatura','documentos',10,'derivado'),
 ('SPHRAGIS','documento.criar','Criar documento','Preparar um documento para assinatura','documentos',20,'derivado'),
 ('SPHRAGIS','documento.enviar','Enviar para assinatura','Despachar o documento aos signatários','documentos',30,'derivado'),
 ('SPHRAGIS','documento.assinar','Assinar documento','Apor a própria assinatura','documentos',40,'derivado'),
 ('SPHRAGIS','documento.acompanhar','Acompanhar assinaturas','Ver o andamento e reenviar convites','documentos',50,'derivado'),
 ('SPHRAGIS','documento.cancelar','Cancelar documento','Interromper um processo de assinatura em curso','documentos',60,'derivado'),
 ('SPHRAGIS','documento.excluir','Excluir documento','Remover definitivamente um documento','documentos',70,'derivado'),
 ('SPHRAGIS','auditoria.consultar','Consultar auditoria','Ver a trilha de assinaturas e acessos','auditoria',80,'derivado')
on conflict (app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- SHAAR — a própria Central
-- ---------------------------------------------------------------------
-- Gerir permissões é uma permissão. Auditar é outra, e estão em conflito
-- declarado entre si: quem concede não audita a si próprio.
insert into public.shaar_permission (app_code, code, name, description, grupo, sort_order, origem) values
 ('SHAAR','quadro.consultar','Consultar o Quadro de Acessos','Ver quem entra em que aplicação','quadro',10,'derivado'),
 ('SHAAR','portao.gerir','Abrir e fechar portões','Conceder ou retirar o acesso a uma aplicação','quadro',20,'derivado'),
 ('SHAAR','permissao.gerir','Gerir permissões','Conceder e revogar permissões na Central','central',30,'derivado'),
 ('SHAAR','permissao.auditar','Auditar permissões','Ler o histórico completo de concessões e revogações','central',40,'derivado'),
 ('SHAAR','diretorio.gerir','Gerir o directório','Sincronização com o Entra ID e excepções','directorio',50,'derivado'),
 ('SHAAR','auditoria.consultar','Consultar a auditoria do hub','Trilha de entradas, recusas e emissão de bilhetes','directorio',60,'derivado')
on conflict (app_code, code) do nothing;

-- ---------------------------------------------------------------------
-- SEGREGAÇÃO DE FUNÇÕES
-- ---------------------------------------------------------------------
-- Estes pares não foram inventados: o próprio catálogo do MANNA já os
-- reconhece, ao ter `purchase-analysis.decide_own` e `finance.settle_own`
-- marcados como "(excepção)". A regra existia no negócio e vivia numa
-- descrição; aqui passa a ser dado, verificado na concessão.
--
-- Severidade 'avisar' em todos, e não 'bloquear', por uma razão de migração:
-- há pessoas que hoje têm ambas as permissões de cada par. Bloquear agora
-- faria a importação do espelho falhar e trancaria trabalho legítimo. O aviso
-- abre uma revisão, e é a primeira recertificação que decide o que fica.
-- Depois disso, subir os pares financeiros a 'bloquear' é uma linha de SQL.
insert into public.shaar_permission_conflito (app_a, code_a, app_b, code_b, motivo, severidade) values
 ('MANNA','purchase-analysis.opine','MANNA','purchase-analysis.decide',
  'Quem emite o parecer tecnico nao decide sobre ele — o proprio catalogo trata isto como excepcao (purchase-analysis.decide_own)','avisar'),
 ('MANNA','finance.consent','MANNA','finance.settle',
  'Quem concede a anuencia nao liquida o pagamento — o proprio catalogo trata isto como excepcao (finance.settle_own)','avisar'),
 ('MANNA','quotation.manage','MANNA','quotation.approve',
  'Quem conduz a cotacao nao a aprova','avisar'),
 ('JIREH','reimbursements:create','JIREH','reimbursements:approve_finance',
  'Quem cria o reembolso nao o aprova como financeiro','avisar'),
 ('JIREH','reimbursements:approve_manager','JIREH','reimbursements:approve_finance',
  'Aprovacao de gestor e de financeiro sao dois olhares distintos sobre o mesmo pedido','avisar'),
 ('TETELESTAI','operation.create','TETELESTAI','operation.approve',
  'Quem propoe a operacao estrategica nao a aprova','avisar'),
 ('SHAAR','permissao.gerir','SHAAR','permissao.auditar',
  'Quem concede permissoes nao audita as suas proprias concessoes','avisar')
on conflict do nothing;

commit;

-- Conferência
select app_code, count(*) as permissoes,
       count(*) filter (where escopo_dimensoes <> '{}') as com_escopo
  from public.shaar_permission group by app_code order by app_code;
