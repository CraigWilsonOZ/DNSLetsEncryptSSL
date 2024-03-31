param (
    [Parameter(Mandatory=$true, HelpMessage="Azure Subscription ID where resources are hosted.")]
    [string]$SUBSCRIPTION_ID,

    [Parameter(Mandatory=$true, HelpMessage="The DNS zone name for which the certificate is issued.")]
    [string]$DNS_ZONE_NAME,

    [Parameter(Mandatory=$true, HelpMessage="The name of the Azure Key Vault to store the certificate.")]
    [string]$KEY_VAULT_NAME,

    [Parameter(Mandatory=$true, HelpMessage="The name of the Azure App Service application.")]
    [string]$APP_NAME,

    [Parameter(Mandatory=$true, HelpMessage="The role to be assigned to the application for accessing resources.")]
    [string]$AZURE_ROLE,

    [Parameter(Mandatory=$true, HelpMessage="The name of the Azure Resource Group that contains the resources.")]
    [string]$RESOURCE_GROUP_NAME,

    [Parameter(Mandatory=$true, HelpMessage="Contact email address for the certificate registration.")]
    [string]$emailAddress,

    [Parameter(Mandatory=$true, HelpMessage="The directory where build sources of certificates are stored on the linux host.")]
    [string]$Build_SourcesDirectory
)

# Login to Azure:

Write-Output "-------------------------------------------------------"
Write-Output " Logging into Azure...                                 "
Write-Output " A browser window will open for you to login.          "
Write-Output "-------------------------------------------------------"

az login
az account set --subscription $SUBSCRIPTION_ID

# Create a resource group and deploy the Bicep template:

Write-Output "-------------------------------------------------------"
Write-Output " Creating a resource group and deploying the Bicep     "
Write-Output " template.                                             "
Write-Output "-------------------------------------------------------"

az group create --name $RESOURCE_GROUP_NAME --location eastus
az deployment group create --resource-group $RESOURCE_GROUP_NAME --template-file main-AzureDNS.bicep --parameters dnsZoneName=$DNS_ZONE_NAME keyVaultName=$KEY_VAULT_NAME

# Create a Service Principal for automation and grant it access to the Key Vault:

Write-Output "-------------------------------------------------------"
Write-Output " Creating a Service Principal for automation and       "
Write-Output " granting it access to the Key Vault.                  "
Write-Output "-------------------------------------------------------"

$result = az ad sp create-for-rbac --name "http://$($APP_NAME)" --role $AZURE_ROLE --scopes /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME --sdk-auth
$resultValues = $result | ConvertFrom-Json
# Save the Service Principal credentials to a file for GitLab CI/CD:
$result | Out-File "AZURE_CREDENTIALS.json"

# Grant the current user access to the Key Vault:
$currentUser = (az ad signed-in-user show | ConvertFrom-Json | Select-Object -Property id).id
az keyvault set-policy --name $KEY_VAULT_NAME --object-id $currentUser --secret-permissions get list set delete --certificate-permissions get list delete update create import

# Grant the Service Principal access to the Key Vault:
az keyvault set-policy --name $KEY_VAULT_NAME --spn $resultValues.clientId --secret-permissions get list set delete --certificate-permissions get list delete update create import

# Store the Service Principal credentials in the Key Vault:
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "sp-clientId" --value $resultValues.clientId
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "sp-displayName" --value "http://$($APP_NAME)"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "sp-clientSecret" --value $resultValues.clientSecret
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "sp-tenantId" --value $resultValues.tenantId
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "sp-subscriptionId" --value $SUBSCRIPTION_ID
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "emailAddress" --value $emailAddress
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "domain" --value $DNS_ZONE_NAME
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "resource-group" --value $RESOURCE_GROUP_NAME

Write-Output "-------------------------------------------------------"
Write-Output " Giving the Service Principal access to the DNS Zone.  "
Write-Output "-------------------------------------------------------"

# Give Service Principal access to the DNS Zone:
az role assignment create --role "DNS Zone Contributor" --assignee $resultValues.clientId --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/dnszones/$DNS_ZONE_NAME

# Create local ini file for certbot:
$ini = @"
dns_azure_sp_client_id = $($resultValues.clientId)
dns_azure_sp_client_secret = $($resultValues.clientSecret)
dns_azure_tenant_id = $($resultValues.tenantId)

dns_azure_environment = "AzurePublicCloud"

dns_azure_zone1 = $($DNS_ZONE_NAME):/subscriptions/$($SUBSCRIPTION_ID)/resourceGroups/$($RESOURCE_GROUP_NAME)
"@
$ini | Out-File "azure_certbot_credentials.ini"

Write-Output "-------------------------------------------------------"
Write-Output " File azure_certbot_credentials.ini has been created.  "
Write-Output " Use this file for the certbot command to create the   "
Write-Output " certificate for the domain.                           "
Write-Output "-------------------------------------------------------"

# Lock down the permissions on the ini file for certbot:
Write-Output "-------------------------------------------------------"
Write-Output "Locking down permissions on the ini file for certbot..."
Write-Output "On the linux host run                                  "
Write-Output "chmod 600 ./azure_certbot_credentials.ini              "
Write-Output "-------------------------------------------------------"

$configEnvVars = @"
#!/bin/bash

# Set environment variables with defaults if not already set
export clientId=$($resultValues.clientId)
export clientSecret=$($resultValues.clientSecret)
export tenantId=$($resultValues.tenantId)
export domainName=$($DNS_ZONE_NAME)
export emailAddress=$($emailAddress)
export keyVaultName=$($KEY_VAULT_NAME)
export Build_SourcesDirectory=$($Build_SourcesDirectory)
export subscriptionID=$($SUBSCRIPTION_ID)
export resourceGroups=$($RESOURCE_GROUP_NAME)
"@
$configEnvVars | Out-File "create-envvariables.sh"

Write-Output "-------------------------------------------------------"
Write-Output " File create-envvariables.sh has been created.         "
Write-Output " Please run the following command to set the           "
Write-Output " environment variables on the linux host.              "
Write-Output "-------------------------------------------------------"
