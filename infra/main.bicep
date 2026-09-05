// SHAAR by XPTO — Azure Static Web App para o hub de acesso
targetScope = 'resourceGroup'

@description('Nome do recurso Static Web App')
param name string = 'swa-shaar'

@description('Regiao (SWA tem regioes limitadas: eastus2, centralus, westus2, westeurope, eastasia)')
@allowed(['eastus2', 'centralus', 'westus2', 'westeurope', 'eastasia'])
param location string = 'eastus2'

@description('Free basta para o provedor Entra pre-configurado; Standard so para provedor proprio')
@allowed(['Free', 'Standard'])
param sku string = 'Free'

param tags object = {
  produto: 'SHAAR'
  ecossistema: 'XPTO'
  ambiente: 'preview'
}

resource swa 'Microsoft.Web/staticSites@2023-01-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    tier: sku
  }
  properties: {
    // deploy feito pelo GitHub Actions com o token do recurso
    allowConfigFileUpdates: true
    stagingEnvironmentPolicy: 'Enabled'
    enterpriseGradeCdnStatus: 'Disabled'
  }
}

output staticWebAppName string = swa.name
output defaultHostname string = swa.properties.defaultHostname
