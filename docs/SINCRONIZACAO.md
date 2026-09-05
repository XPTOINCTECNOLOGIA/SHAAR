# Sincronização entre o diretório corporativo e a base das microaplicações

O Entra ID diz **quem a pessoa é**. A base diz **o que ela acessa**. Sem as duas
listas apontando para as mesmas pessoas, o login único leva gente a lugar nenhum.

## Critério

Entra na base quem cumpre as três condições ao mesmo tempo:

- conta de **membro** (não convidado) do tenant;
- conta **habilitada**;
- **com licença** do Microsoft 365;
- com endereço **@xptoinc.com.br** (principal ou alias).

Quem não cumpre não é trazido — e aparece no relatório de divergências para
decisão humana.

## O que a rotina faz e o que não faz

| Faz | Não faz |
| --- | --- |
| Cria na base quem falta | Alterar cadastro que já existe |
| Abre o portão do **TETELESTAI** para quem cria | Abrir qualquer outro portão |
| Liga a conta do Entra ao cadastro existente, por qualquer endereço conhecido | Definir perfil |
| Marca quem saiu do critério | Desativar ninguém |
| Registra tudo em `shaar_directory` | Abrir portão no SHAAR |

As três últimas colunas da direita são decisões de gestão, não de rotina
automática. A sincronização entrega a pessoa cadastrada e para aí.

## Peças na base

| Objeto | Papel |
| --- | --- |
| `shaar_directory` | Espelho do diretório: uma linha por conta elegível, ligada ao `users.id` |
| `shaar_directory_ignorar` | Endereços que a rotina não deve trazer, com o motivo |
| `shaar_directory_vinculo` | Casamentos que o endereço não resolve sozinho |
| `shaar_sync_diretorio(jsonb, boolean)` | A rotina. Com `false` apenas simula |
| `shaar_divergencias` | O que não bate entre os dois lados |
| `shaar_ver_divergencias()` | A mesma coisa, exposta ao super administrador |
| Perfil `SEM PERFIL` (nível 0) | Perfil de chegada. Não concede nada |

O casamento entre os dois lados usa **todos** os endereços conhecidos da conta
— principal, UPN e aliases. É assim que `luca.confente@` casaria com
`luca.borges@`, e `dpo@` casa com `pedro.junior@`.

## Estado

**Em produção desde 05/09/2026.** Roda todo dia às 23:00 de Brasília, na
`vm-supabase`. Registro em `/var/log/xpto-sync-diretorio.log`.

| | |
| --- | --- |
| Identidade | `xpto-sync-diretorio` · `0bf41859-34ea-42d0-ae38-9caad4a5d3b3` |
| Permissão | Microsoft Graph · `User.Read.All` (somente leitura) |
| Credencial | `/etc/xpto/sync-diretorio.env` (modo 600, root) · expira em 09/2028 |
| Script | `/opt/xpto/sync-diretorio.sh` |
| Agendamento | `/etc/cron.d/xpto-sync-diretorio` |

O segredo tem validade de dois anos. **Renovar antes de setembro de 2028**,
senão a sincronização para em silêncio.

## Como foi ligada

Registro do que foi feito, caso precise refazer.

### 1. Criar a identidade da rotina

```bash
APP=$(az ad app create --display-name "xpto-sync-diretorio" \
        --sign-in-audience AzureADMyOrg --query appId -o tsv)
az ad sp create --id "$APP"

# Microsoft Graph · User.Read.All (permissão de aplicação, somente leitura)
az ad app permission add --id "$APP" \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions df021288-bdef-4463-88db-98f22de89214=Role

az ad app permission admin-consent --id "$APP"

SEGREDO=$(az ad app credential reset --id "$APP" --years 2 --query password -o tsv)
echo "CLIENT_ID=$APP"; echo "CLIENT_SECRET=$SEGREDO"
```

`User.Read.All` é o mínimo necessário: lê o diretório, não escreve nada nele.

### 2. Instalar na vm-supabase

Copie `scripts/sync-diretorio.sh` para `/opt/xpto/sync-diretorio.sh` (modo 755),
crie `/etc/xpto/sync-diretorio.env` com modo **600** e dono root:

```
TENANT_ID=ac2c03c7-d196-4402-870a-64c1f3485a5d
CLIENT_ID=<o appId acima>
CLIENT_SECRET=<o segredo acima>
```

E o agendamento, em `/etc/cron.d/xpto-sync-diretorio`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# A maquina roda em UTC. 02:00 UTC = 23:00 em Brasília (UTC-3, sem horário
# de verão desde 2019). Quem for admitido durante o dia entra no dia seguinte.
0 2 * * * root /opt/xpto/sync-diretorio.sh aplicar >> /var/log/xpto-sync-diretorio.log 2>&1
```

O horário é deliberado: a rotina fecha o dia. Uma pessoa criada no Entra a
qualquer hora de hoje está cadastrada e com o portão do TETELESTAI aberto
antes do expediente de amanhã.

Requer `jq` instalado na máquina.

### 3. Conferir antes de deixar solto

```bash
/opt/xpto/sync-diretorio.sh            # simula, não grava
/opt/xpto/sync-diretorio.sh aplicar    # grava
```

O script aborta se o roster vier vazio, para que uma falha de rede nunca marque
o diretório inteiro como ausente.

## Rotina de operação

Depois de cada sincronização, o administrador olha as divergências:

```sql
select * from shaar_divergencias order by situacao, email;
```

| Situação | O que significa | O que fazer |
| --- | --- | --- |
| `aguardando perfil` | Pessoa criada pela rotina, ainda com `SEM PERFIL` | Definir o perfil e abrir os portões |
| `sem cadastro na base` | Está no diretório e a rotina ainda não criou | Rodar com `aplicar` |
| `sem conta no diretório` | Ativa na base, fora do critério | Verificar licença, ou desativar |
| `saiu do diretório, ativa na base` | Perdeu licença ou foi desativada no Entra | Provável desligamento — conferir |

## Porta de chegada

Quem a rotina cria entra com o **portão do TETELESTAI aberto** e perfil
`SEM PERFIL`. É o mínimo para que o primeiro login leve a algum lugar — sem
isso a pessoa autentica com sucesso e encontra o salão vazio. Todos os demais
portões ficam fechados, à espera da decisão do administrador.

## Vínculos manuais em vigor

| Endereço no diretório | Pessoa na base | Motivo |
| --- | --- | --- |
| `luca.borges@xptoinc.com.br` | `luca.confente@xptoinc.com.br` | O Entra não conhece o segundo endereço; sem o vínculo a rotina criaria uma segunda pessoa |

```sql
insert into shaar_directory_vinculo (email_diretorio, user_id, motivo)
values ('novo@xptoinc.com.br', 42, 'motivo');
```

## Exceções em vigor

| Endereço | Motivo |
| --- | --- |
| `sphragis@xptoinc.com.br` | Caixa de serviço da aplicação, não é pessoa. Consome duas licenças |
| `victor.silva@xptoinc.com.br` | Segunda conta de Vitor Rogerio Soares Campelo da Silva, já cadastrado como `vitor.silva@`. Resolver no Entra ID |

Para acrescentar uma exceção:

```sql
insert into shaar_directory_ignorar (email, motivo) values ('caixa@xptoinc.com.br', 'motivo');
```
