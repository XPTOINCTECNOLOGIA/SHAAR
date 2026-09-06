# A fronteira do SHAAR

Como uma aplicação do ecossistema passa a confiar apenas no SHAAR.

## O que mudou

Antes, cada aplicação decidia sozinha quem entrava, contra a mesma base. Um
token do ecossistema servia em toda a parte, e a lista de portões do SHAAR não
era consultada por ninguém — copiar a URL e enviar a um colega funcionava.

Agora o SHAAR emite um **bilhete** por aplicação: assinado em RS256, com
destinatário (`aud`), válido 15 minutos. A aplicação verifica a assinatura com
a chave **pública** e obedece.

Nenhuma aplicação consegue emitir bilhete: a chave privada só existe no
emissor.

## Adoptar numa aplicação de navegador

```ts
import { registerApplication } from "./lib/shaar-guard.js";

const eu = await registerApplication({ app: "TIKKUN", modo: "observar" });
```

Ou, sem copiar o ficheiro, a partir da fonte canónica:

```ts
const { registerApplication } = await import("https://shaar.xptoinc.com.br/shaar-guard.js");
```

## Adoptar numa aplicação com servidor

Container Apps (TETELESTAI, BNEI YISRAEL) verificam **no servidor**. Verificar
no navegador uma aplicação que tem servidor é pedir ao cliente que se autorize
a si mesmo.

```js
import { guardaShaar } from "./shaar-guard-servidor.mjs";

app.use(guardaShaar({ app: "TETELESTAI", modo: "observar" }));
// depois de verificado, req.shaar traz a identidade do bilhete
```

## Os dois modos

| | o que faz |
| --- | --- |
| `observar` | verifica, regista o veredicto, **deixa passar** |
| `exigir` | sem bilhete válido: redirecciona (navegador) ou devolve 403 (servidor) |

**Toda a aplicação estreia em `observar`.** Ligar a fronteira sem essa etapa é
descobrir os casos que faltam através de gente sem conseguir trabalhar. Passar
a valer é trocar uma palavra, depois de a observação mostrar que só entra quem
devia.

## O que a fronteira não faz

Não substitui a autorização do servidor. Esta é a porta; lá dentro, cada
pedido continua a passar pelas regras da base. **Esconder o ecrã nunca foi
defesa e continua a não ser.**

## Pré-requisito para fechar

A fronteira só pode passar a `exigir` quando os portões do Quadro reflectirem
quem de facto usa cada aplicação. Hoje não reflectem: a maioria das pessoas
tem apenas o TETELESTAI aberto, porque foi assim que se configurou de início.

Fechar antes disso tira o acesso a quem trabalha. A ordem é: abrir os portões
certos no Quadro — a autorização em massa serve para isso —, ver a observação
ficar limpa, e só então exigir.

## Rotação da chave de assinatura

O JWKS aceita mais de uma chave ao mesmo tempo. Rodar é: publicar a nova ao
lado da antiga, emitir com a nova, esperar a validade dos bilhetes em
circulação (15 minutos), retirar a antiga. Sem indisponibilidade — foi o mesmo
método usado na rotação da chave anónima.

A chave privada está em `/etc/xpto/shaar-signing.pem`, modo 600, na
`vm-supabase`. **Não está no Key Vault**: assinar pelo Key Vault exige o
emissor a correr no Azure com identidade gerida, e as Edge Functions correm em
Docker na VM. Fica para a fase 5.
