# Azure Resources and Let's Encrypt SSL Certificate Automation

In the digital age, securing your web applications with SSL/TLS certificates is not just an option—it's a necessity. Microsoft Azure users have a powerful toolset at their disposal to automate this process, using a combination of Azure resources, Bicep, and Let's Encrypt. This guide dives into the specifics of setting up Azure resources with Bicep and automating SSL certificate generation and renewal with Let's Encrypt, highlighting the integration with Azure Key Vault for secure storage of certificates and service principle details.

Let's Encrypt, a free, automated, and open Certificate Authority, offers a straightforward way to obtain SSL certificates. By integrating Let's Encrypt with Azure services, you can automate the generation and renewal of SSL certificates. This process involves scripts that handle everything from installing dependencies, such as Azure CLI and Certbot, to configuring Azure DNS/GoDaddy plugin's credentials for Certbot, generating SSL certificates, and securely storing them in Azure Key Vault.

The main example will use Azure DNS to host a domain and Azure Key Vault to store all the certificates and service principle details. The second example show how to use GoDaddy as the DNS provider. GoDaddy is a public DNS provider with their own API, updates to this provider do take time and process is slower. If you are running your own domain, try Azure DNS.

The process will create Azure Resources first. I assume that user already has Azure CLI and Azure Bicep running on their system. The first stage uses a configuration script in PowerShell, this script creates Azure Resources, Service Princple and all records are stored in an Azure Key Vault. The next stage is to create Pipeline in ADO. I have provided example pipelines and scripts. The scripts have been designed to run in a pipeline or locally on your workstation, I would recommend using Windows with WSL or a Linux workstation. The scripts have been tested on a Raspbery PI 4 running Ubuntu.

## Directory Structure

```bash
Certificates/
├── create-certificate-azuredns.sh
├── create-certificate-godaddy.sh
├── Azure
│   ├── main-AzureDNS.bicep
│   ├── main-GoDaddyDNS.bicep
│   ├── config-AzureDNS.ps1
│   ├── config-GoDaddyDNS.ps1
└── Workflows
    ├── github-certbot_azure.yml
    ├── ado-certbot_azure.yml
```

## Azure Resource Setup with Bicep

Ensure Azure CLI and Bicep are installed, then proceed with creating the necessary Azure resources.

### Step 1: Bicep File for Azure Resources

Create `main-AzureDNS.bicep` with the content below to define Azure DNS and Key Vault resources:

```PowerShell
param dnsZoneName string
param keyVaultName string
param location string = 'eastus'

resource dnsZone 'Microsoft.Network/dnsZones@2018-05-01' = {
  name: dnsZoneName
  location: 'global'
}

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    accessPolicies: []
  }
}
```

### Step 2: Deploy Bicep File

Deploy the Bicep file to your resource group:

Create 'config.ps1' with the content below to configure and deploy the resources.

```powershell

$SUBSCRIPTION_ID = "00000000-0000-0000-0000-000000000000"
$DNS_ZONE_NAME = "youdomain.com"
$KEY_VAULT_NAME = "kv-youdomain-certificate"
$APP_NAME = "youdomain-certificate-letsencrypt"
$AZURE_ROLE = "Contributor"
$RESOURCE_GROUP_NAME = "rg-letsencrypt"

# Login to Azure:

az login
az account set --subscription $SUBSCRIPTION_ID

# Create a resource group and deploy the Bicep template:

az group create --name $RESOURCE_GROUP_NAME --location eastus
az deployment group create --resource-group $RESOURCE_GROUP_NAME --template-file main-AzureDNS.bicep --parameters dnsZoneName=$DNS_ZONE_NAME keyVaultName=$KEY_VAULT_NAME

# Create a Service Principal for automation and grant it access to the Key Vault:

$result = az ad sp create-for-rbac --name "http://$($APP_NAME)-1" --role $AZURE_ROLE --scopes /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME | ConvertFrom-Json
az keyvault set-policy --name $KEY_VAULT_NAME --object-id $result.appId --secret-permissions get list set delete

```

## Script for Automating SSL Certificate Generation and Management with Azure and Let's Encrypt

This script automates the process of generating SSL certificates using Let's Encrypt and managing them with Azure services. It performs several key operations including installing necessary dependencies, logging into Azure, generating SSL certificates, and storing them in Azure Key Vault.

### Environment Variables Setup

The script starts by ensuring that all necessary environment variables are set, providing default values where not already defined.

```bash
clientId=${clientId:-""}
clientSecret=${clientSecret:-""}
tenantId=${tenantId:-""}
domainName=${domainName:-""}
emailAddress=${emailAddress:-""}
keyVaultName=${keyVaultName:-""}
Build_SourcesDirectory=${Build_SourcesDirectory:-"."}
subscriptionID=${subscriptionID:-""}
resourceGroups=${resourceGroups:-""}
```

### Installing Dependencies

It checks for and installs the Azure CLI and Certbot, along with any other required dependencies.

```bash
sudo apt update && sudo apt install -y python3 python3-venv curl openssl
```

If the Azure CLI is not found, it uses Microsoft's script to install it.

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

### Setting Up Certbot

The script then sets up a Python virtual environment and installs Certbot and the Certbot DNS Azure plugin.

```bash
python3 -m venv certbot_venv
source certbot_venv/bin/activate
pip install certbot certbot-dns-azure
```

### Azure Login and Account Setup

Logs into Azure using a service principal and sets the active subscription.

```bash
az login --service-principal -u \$clientId -p \$clientSecret --tenant \$tenantId --output none
az account set --subscription \$subscriptionID
az account show --output json
```

### Create Azure Certbot Credentials File

Generates a configuration file for Certbot with Azure DNS plugin credentials.

```bash
cat > \$Build_SourcesDirectory/azure_certbot_credentials.ini <<EOF
dns_azure_sp_client_id = \$clientId
dns_azure_sp_client_secret = \$clientSecret
dns_azure_tenant_id = \$tenantId

dns_azure_environment = "AzurePublicCloud"

dns_azure_zone1 = \$domainName:/subscriptions/\$subscriptionID/resourceGroups/\$resourceGroups
EOF
```

### Generate/Refresh SSL Certificate

Executes Certbot to generate or renew the SSL certificate.

```bash
chmod 600 \$Build_SourcesDirectory/azure_certbot_credentials.ini # Locking down permissions on the credentials file
certbot certonly --authenticator dns-azure --preferred-challenges dns --dns-azure-credentials \$Build_SourcesDirectory/azure_certbot_credentials.ini -d \$domainName -d *.\$domainName --config-dir \$Build_SourcesDirectory/letsencrypt --work-dir \$Build_SourcesDirectory/letsencrypt/work --logs-dir \$Build_SourcesDirectory/letsencrypt/logs --non-interactive --agree-tos --email \$emailAddress
```

### Convert Certificates to PFX

Converts the generated certificates to PFX format for use in various services.

```bash
openssl pkcs12 -export -out \$Build_SourcesDirectory/letsencrypt/live/\$domainName/certificate.pfx -inkey \$Build_SourcesDirectory/letsencrypt/live/\$domainName/privkey.pem -in \$Build_SourcesDirectory/letsencrypt/live/\$domainName/cert.pem -certfile \$Build_SourcesDirectory/letsencrypt/live/\$domainName/chain.pem -passout pass:\$clientSecret
```

### Store Certificates in Azure Key Vault

Uploads the generated certificates to Azure Key Vault for secure storage.

```bash
az keyvault secret set --vault-name \$keyVaultName --name "PEM-Certificate" --file \$Build_SourcesDirectory/letsencrypt/live/\$domainName/cert.pem
az keyvault secret set --vault-name \$keyVaultName --name "PEM-PrivateKey" --file \$Build_SourcesDirectory/letsencrypt/live/\$domainName/privkey.pem
az keyvault secret set --vault-name \$keyVaultName --name "PEM-FullChain" --file \$Build_SourcesDirectory/letsencrypt/live/\$domainName/fullchain.pem
az keyvault secret set --vault-name \$keyVaultName --name "PEM-Chain" --file \$Build_SourcesDirectory/letsencrypt/live/\$domainName/chain.pem
az keyvault secret set --vault-name \$keyVaultName --name "PFX-Certificate-b64" --file \$Build_SourcesDirectory/letsencrypt/live/\$domainName/certificate.pfx --encoding base64
az keyvault certificate import --vault-name \$keyVaultName --name \${domainName//./-} --file \$Build_SourcesDirectory/letsencrypt/live/\$domainName/certificate.pfx --password \$clientSecret
```

### Completion

Indicates the completion of the process.

```bash
echo "Process completed."
```

## Connecting Azure DevOps Variable Group to Azure Key Vault

Connecting an Azure DevOps (ADO) variable group to an Azure Key Vault is a secure and efficient way to manage secrets and configuration values used in a CI/CD pipelines. This integration allows the pipeline to leverage Key Vault's robust security features, such as secret management and access policies, directly within Azure DevOps pipelines. I have used this to store all my variables and certificates I create in the script. This will allow future use of the certificates in other projects.

Here's how to set it up a Azure Key Vault to an Azure DevOps Pipeline Variable Group:

### Step 1: Create an Azure Key Vault

Create an Azure Key Vault, which was done for us in the bicep code.

### Step 2: Add Secrets to Your Key Vault

Populate the Key Vault with the secrets or configuration values for the pipeline requires. This was also done in the configuration script.

### Step 3: Create a Service Connection in Azure DevOps

In Azure DevOps, navigate to Project Settings > Service connections, and create a new service connection of type 'Azure Resource Manager'. Choose 'Service principal (automatic)' for authentication and select the subscription and Key Vault resource. This service connection will be used to authenticate Azure DevOps to your Key Vault.

### Step 4: Create a Variable Group Linked to Key Vault

Go to Pipelines > Library in Azure DevOps, and create a new variable group. Enable the option "Link secrets from an Azure key vault as variables". Select the service connection you created in the previous step and choose your Key Vault. You can then select which secrets to link to the variable group.

### Step 5: Use the Variable Group in Your Pipelines

In your pipeline YAML, reference the variable group using the `variableGroups` keyword. Variables from the group can then be used in your pipeline tasks.

```yaml
variables:
- group: 'your-variable-group-name'
```

## Benefits of Linking ADO Variable Group to Azure Key Vault

- **Security**: Key Vault provides a centralized and secure storage for your secrets, keys, and certificates. By integrating with Key Vault, you minimize the risk of exposing sensitive information in your pipeline definitions.

- **Access Control**: Azure Key Vault allows you to define fine-grained access policies for your secrets. This means you can control which pipelines or individuals have access to specific secrets.

- **Audit Trails**: Key Vault offers logging and monitoring capabilities, enabling you to audit access to secrets. This is crucial for compliance and security monitoring.

- **Simplified Secret Management**: Updating secrets in Key Vault automatically propagates the changes to your pipelines. This eliminates the need to manually update secrets in multiple places.

- **Scalability**: As your project grows, managing secrets through Key Vault and Azure DevOps variable groups makes it easier to manage and scale your CI/CD processes securely.

By connecting Azure DevOps variable groups to Azure Key Vault, you enhance the security and manageability of your CI/CD pipelines, ensuring that sensitive information is handled securely and efficiently.

## Azure DevOps Pipeline for Let's Encrypt

This section describes setting up an Azure DevOps pipeline to automate SSL certificate generation and renewal.

### Prerequisites

- An Azure DevOps organization and project.
- A self-hosted or Microsoft-hosted agent with Azure CLI and Python installed.

### Step 1: Define Azure Pipeline Variables

In your Azure DevOps project, define the following pipeline variables:

- `AZURE_CREDENTIALS`: The JSON output from creating the service principal.
- `SP_CLIENTID` : Client ID for service principal account
- `SP_CLIENTSECRET`:  Client ID for service principal account
- `SP_TENANTID` : Entra ID tenant id.
- `SP_SUBSCRIPTIONID` : Subscription ID for you azure subscription
- `DOMAIN`: Domain name, e.g., `example.com`.
- `EMAIL_ADDRESS`: Email address for Let's Encrypt notifications.
- `KEYVAULTNAME`: The name of the Azure Key Vault.
- `RESOURCE_GROUP` : The name of the resource groupS

### Step 2: Create the Pipeline

Create a new pipeline `ado-certbot_azure.yml` in your Azure DevOps project with the following content:

```yaml
trigger:
- none

pool:
  vmImage: ubuntu-latest

variables:
- group: LetsEncrypt

steps:
- script: |
    echo "---------------------"
    printenv | sort
    ls -la
    pwd
    echo "---------------------"
    # Run bash script
    chmod +x ./create-certificate-azuredns.sh
    ./create-certificate-azuredns.sh
    echo "---------------------"
    echo "Script debug log file"
    echo "---------------------"
    cat ./letsencrypt/logs/letsencrypt.log
    echo "---------------------"
  env:
    # Map the pipeline variable to the script environment variable
    clientId: $(sp-clientId)
    clientSecret: $(sp-clientSecret)
    tenantId: $(sp-tenantId)
    subscriptionID: $(sp-subscriptionId)
    domainName: $(domain)
    emailAddress: $(emailAddress)
    keyVaultName: $(keyVaultName)
    resourceGroups: $(resource-group)
  displayName: 'Lets Encrypt Certbot Certificates Creation'
```

### Azure DevOps Notes

- This Azure DevOps pipeline automates the SSL certificate generation/renewal process and stores the certificates in Azure Key Vault.
- Ensure to replace placeholders with actual values and configure paths and permissions as needed.

## GoDaddy DNS Exmaple

let's Encrypt also works with other DNS provided like Cloud Flare and GoDaddy. In this example I will use GoDaddy to create a new certificate. The process will follow the same as the Azure DNS, how the DNS will be hosted by GoDaddy.

The steps follow the above example:

1. **Create the GoDaddy API Keys**, API keys will be used to connect to GoDaddy and create the DNS records.2.
2. **Create the Azure Key Vault resources**, Update the bicep script to remove the Azure DNS resources since we will be using GoDaddy.
3. **Update configuration PowerShell**, Add the GoDaddy parameters to the PowerShell script and also update the secert creation section to store those parameters in the Key Vault
4. **Update the main bash script**, Remove the Azure DNS option and replace it with GoDaddy.
5. **Create a new Pipeline**, Create an addtional pipeline to run the script.

### GoDaddy DNS Registration

To use GoDaddy DNS provider, additional actions are requird. An API key is required and some updates to the scripts.

1. **Log in to your GoDaddy account:** Open your web browser and go to the GoDaddy website. Log in using your GoDaddy account credentials.

2. **Access the Developer Portal:** Once logged in, navigate to the GoDaddy Developer Portal by visiting [https://developer.godaddy.com](https://developer.godaddy.com). You may need to search for "Developer" in the GoDaddy search bar if the URL changes.

3. **Create a New API Key:** In the Developer Portal, look for the section or button to create a new API Key. This is usually found under a menu named something like "Keys" or "API Keys".

    a. Click on the **Create New API Key** button or link.
    b. Give your API key a name that helps you remember what application or script it's used for. For example, "My Website Certbot".
    c. Select the type of environment for your API key:
        - **Production:** Choose this if you are ready to use the API key on your live website.
        - **OTE (Test Environment):** Choose this if you want to test your scripts without making actual changes to your live DNS records.
    d. Click **Next** or **Create** to generate the API key.

4. **Copy Your New API Key and Secret:** After creating the API key, you will be shown the API key and secret. It's very important to copy these values and keep them secure. You won't be able to see the secret again after you leave this page.

    a. Click on the **Copy** icon next to the API Key and Secret to copy them to your clipboard.
    b. Store them in a secure location. You will need these values when configuring your scripts or applications to interact with GoDaddy's API.

5. **Use Your API Key:** With your API key and secret copied, you can now use them in your applications or scripts to automate tasks with GoDaddy's services.

### Update the Bicep files

Update the bicep script to remove the Azure DNS resources since we will be using GoDaddy. Create `main-GoDaddyDNS.bicep` with the content below to define Key Vault resources:

```bicep
param keyVaultName string
param location string = 'eastus'

resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    accessPolicies: []
  }
}
```

### Update the PowerShell configuration script

The GoDaddy parameters need to be added to the PowerShell script and also update the secert creation section to store those parameters in the Key Vault.

- Copy the config-AzureDNS.ps1 file to config-GoDaddy.ps1.
- Add the following parameters to the script.

```PowerShell

    [Parameter(Mandatory=$true, HelpMessage="The GoDaddy API Application Key.")]
    [string]$GoDaddyAPIKey,

    [Parameter(Mandatory=$true, HelpMessage="The GoDaddy API Secret Key.")]
    [string]$GoDaddyAPISecret

```

- Update the call to create the Azure resources.

```PowerShell

az group create --name $RESOURCE_GROUP_NAME --location eastus
az deployment group create --resource-group $RESOURCE_GROUP_NAME --template-file main-GoDaddy.bicep --parameters keyVaultName=$KEY_VAULT_NAME

```

- Removing the DNS permissions as these will be in GoDaddy now. Delete these lines.

```PowerShell
# Give Service Principal access to the DNS Zone:
az role assignment create --role "DNS Zone Contributor" --assignee $resultValues.clientId --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Network/dnszones/$DNS_ZONE_NAME

```

- Update the Key Vault section to store the GoDaddy API keys. Add the following lines.

```PowerShell
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "GoDaddy-API-Key" --value $GoDaddyAPIKey
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "GoDaddy-API-Secret" --value $GoDaddyAPISecret
```

### Update the Bash script

Remove the Azure DNS option and replace it with GoDaddy.

- Copy the create-certificate-azuredns.sh file to create-certificate-godaddy.sh.
- Add the following environment parameters to the script.

```bash
# Set environment variables with defaults if not already set
clientId=${clientId:-""}
clientSecret=${clientSecret:-""}
tenantId=${tenantId:-""}
domainName=${domainName:-""}
emailAddress=${emailAddress:-""}
keyVaultName=${keyVaultName:-""}
Build_SourcesDirectory=${Build_SourcesDirectory:-"."}
subscriptionID=${subscriptionID:-""}
resourceGroups=${resourceGroups:-""}
GoDaddyAPIKey=${GoDaddyAPIKey:-""}
GoDaddyAPISecret=${GoDaddyAPISecret:-""}

```

- Update the certbot-dns-azure for the python virtual environment.

```bash
# Create a python virtual environment and install certbot
python3 -m venv certbot_venv
source certbot_venv/bin/activate
pip install certbot certbot-dns-godaddy

```

- Replace the section "# Create Azure Certbot Credentials File" with the following code to create a new credential file.

```bash
# Create GoDaddy Certbot Credentials File

cat > $Build_SourcesDirectory/godaddy_certbot_credentials.ini <<EOF
dns_godaddy_secret = $GoDaddyAPISecret
dns_godaddy_key  = $GoDaddyAPIKey
EOF

chmod 600 $Build_SourcesDirectory/godaddy_certbot_credentials.ini # Locking down permisions on the credentials file
ls -la

```

- Update the certbot call

```bash

# Generate/Refresh SSL Certificate

# Generate/Refresh SSL Certificate
certbot certonly --authenticator dns-godaddy \
    --dns-godaddy-credentials $Build_SourcesDirectory/godaddy_certbot_credentials.ini \
    --dns-godaddy-propagation-seconds 900 \
    --server https://acme-v02.api.letsencrypt.org/directory \
    -d $domainName \
    -d *.$domainName \
    --config-dir $Build_SourcesDirectory/letsencrypt \
    --work-dir $Build_SourcesDirectory/letsencrypt/work \
    --logs-dir $Build_SourcesDirectory/letsencrypt/logs \
    --non-interactive \
    --keep-until-expiring \
    --expand \
    --agree-tos \
    --email $emailAddress

```

### Create a new Pipeline

Create an addtional pipeline to run the script. Follow the same steps outlined above, create your variables and update the pipeline scripts to call the new GoDaddy version.

## GitHub Actions Workflow for Let's Encrypt (Optional)

This section outlines automating SSL certificate management using GitHub Actions.

### GitHub Secrets

Add the following secrets in your GitHub repository:

- `AZURE_CREDENTIALS`: The JSON output from creating the service principal.
- `SP_CLIENTID` : Client ID for service principal account
- `SP_CLIENTSECRET`:  Client ID for service principal account
- `SP_TENANTID` : Entra ID tenant id.
- `SP_SUBSCRIPTIONID` : Subscription ID for you azure subscription
- `DOMAIN`: Domain name, e.g., `example.com`.
- `EMAIL_ADDRESS`: Email address for Let's Encrypt notifications.
- `KEYVAULTNAME`: The name of the Azure Key Vault.
- `RESOURCE_GROUP` : The name of the resource group

### Workflow File

Create `.github/workflows/github-certbot_azure.yml` with the content below:

```yaml
name: Lets Encrypt Certificate Creation

# Controls when the action will run.
on:
  workflow_dispatch:
    # Allows you to run this workflow manually from the Actions tab

jobs:
  create-certificate:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout repository
      uses: actions/checkout@v2

    - name: Set up environment variables
      run: |
        echo "CLIENT_ID=${{ secrets.SP_CLIENTID }}" >> $GITHUB_ENV
        echo "CLIENT_SECRET=${{ secrets.SP_CLIENTSECRET }}" >> $GITHUB_ENV
        echo "TENANT_ID=${{ secrets.SP_TENANTID }}" >> $GITHUB_ENV
        echo "SUBSCRIPTION_ID=${{ secrets.SP_SUBSCRIPTIONID }}" >> $GITHUB_ENV
        echo "DOMAIN_NAME=${{ secrets.DOMAIN }}" >> $GITHUB_ENV
        echo "EMAIL_ADDRESS=${{ secrets.EMAILADDRESS }}" >> $GITHUB_ENV
        echo "KEYVAULT_NAME=${{ secrets.KEYVAULTNAME }}" >> $GITHUB_ENV
        echo "RESOURCE_GROUP=${{ secrets.RESOURCE_GROUP }}" >> $GITHUB_ENV

    - name: Run debug commands
      run: |
        echo "---------------------"
        printenv | sort
        ls -la
        pwd
        echo "---------------------"

    - name: Run certificate creation script
      run: |
        chmod +x ./create-certificate-azuredns.sh
        ./create-certificate-azuredns.sh

    - name: Display script debug log file
      run: cat ./letsencrypt/logs/letsencrypt.log
```

### Github Workflow Notes

- This workflow automates the SSL certificate generation/renewal process and stores the certificates in Azure Key Vault.
- Ensure to replace placeholders with actual values and configure paths and permissions as needed.
