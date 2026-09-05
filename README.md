# SHAAR

**שער · by XPTO** — o hub de acesso do ecossistema XPTO.

O usuário faz **um login central** e encontra as microaplicações que tem direito de
acessar. Se tiver acesso a uma só, entra direto nela; se tiver a duas ou mais, escolhe
num painel. O que não lhe foi concedido não aparece.

Aplicações do ecossistema: TETELESTAI · JIREH · FAITH · TIKKUN · MANNA · BNEI YISRAEL ·
SPHRAGIS — e as que vierem. Todas compartilham a mesma base de usuários e são
independentes quanto a autorização de uso.

## Estado

Em produção. Login contra a base do ecossistema, catálogo e permissões lidos do banco,
redirecionamento real para cada aplicação. O Quadro de Acessos do super administrador
é de leitura — conceder e revogar dependem de uma função de servidor com privilégio,
porque cada aplicação guarda a autorização na sua própria tabela.

```
site/     o mockup — HTML estático, sem build
infra/    Bicep do Azure Static Web App
scripts/  publicação no Azure pela CLI
```

## No ar

**https://shaar.xptoinc.com.br**

Autentica na base do TETELESTAI (`api.xptoinc.com.br`) e mostra as aplicações que
cada pessoa realmente pode abrir. Não existe modo de demonstração: uma publicação
sem credenciais para e diz o que houve, em vez de inventar dados.

- **Arquitetura e regras de produto:** [`ARQUITETURA.md`](ARQUITETURA.md)
- **Como publicar:** [`DEPLOY.md`](DEPLOY.md)

## Conceito visual

Cada aplicação é um **portão**, e as duas folhas de cada portão carregam as duas setas
convergentes do glifo X da XPTO — *"duas setas convergindo para um ponto central, o ponto
de decisão"* (Brand Book, pág. 08). Portão fechado, o glifo está íntegro selando a porta;
ao abrir, as setas se separam e o símbolo próprio da aplicação aparece na luz Ciano.

A marca-mãe sela toda porta; a submarca vive atrás dela.

---

XPTO Inc. — *Tecnologia que protege.*
