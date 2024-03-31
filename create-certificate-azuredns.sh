#!/bin/bash

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

# Setup Environment
echo "Installing Azure CLI and Certbot..."

# installing dependencies
sudo apt update && sudo apt install -y python3 python3-venv curl openssl

# Check if Azure CLI is installed
if ! command -v az &> /dev/null
then
    echo "Azure CLI could not be found. Installing..."

    # Use Microsoft's script to install Azure CLI
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

    echo "Azure CLI installed successfully."
else
    echo "Azure CLI is already installed."
fi

# Create a python virtual environment and install certbot
python3 -m venv certbot_venv
source certbot_venv/bin/activate
pip install certbot certbot-dns-azure

# Login to Azure
echo "Logging into Azure..."
az login --service-principal -u $clientId -p $clientSecret --tenant $tenantId --output none
az account set --subscription $subscriptionID
az account show --output json

# Create Azure Certbot Credentials File

cat > $Build_SourcesDirectory/azure_certbot_credentials.ini <<EOF
dns_azure_sp_client_id = $clientId
dns_azure_sp_client_secret = $clientSecret
dns_azure_tenant_id = $tenantId

dns_azure_environment = "AzurePublicCloud"

dns_azure_zone1 = $domainName:/subscriptions/$subscriptionID/resourceGroups/$resourceGroups
EOF

# Generate/Refresh SSL Certificate
chmod 600 $Build_SourcesDirectory/azure_certbot_credentials.ini # Locking down permisions on the credentials file
ls -la

certbot certonly --authenticator dns-azure \
    --preferred-challenges dns \
    --dns-azure-credentials $Build_SourcesDirectory/azure_certbot_credentials.ini \
    -d $domainName \
    -d *.$domainName \
    --config-dir $Build_SourcesDirectory/letsencrypt \
    --work-dir $Build_SourcesDirectory/letsencrypt/work \
    --logs-dir $Build_SourcesDirectory/letsencrypt/logs \
    --non-interactive \
    --agree-tos \
    --email $emailAddress

# Convert Certificates to PFX
openssl pkcs12 -export \
    -out $Build_SourcesDirectory/letsencrypt/live/$domainName/certificate.pfx \
    -inkey $Build_SourcesDirectory/letsencrypt/live/$domainName/privkey.pem \
    -in $Build_SourcesDirectory/letsencrypt/live/$domainName/cert.pem \
    -certfile $Build_SourcesDirectory/letsencrypt/live/$domainName/chain.pem \
    -passout pass:$clientSecret

# Store Certificates in Azure Key Vault
az keyvault secret set --vault-name $keyVaultName --name "PEM-Certificate" --file $Build_SourcesDirectory/letsencrypt/live/$domainName/cert.pem
az keyvault secret set --vault-name $keyVaultName --name "PEM-PrivateKey" --file $Build_SourcesDirectory/letsencrypt/live/$domainName/privkey.pem
az keyvault secret set --vault-name $keyVaultName --name "PEM-FullChain" --file $Build_SourcesDirectory/letsencrypt/live/$domainName/fullchain.pem
az keyvault secret set --vault-name $keyVaultName --name "PEM-Chain" --file $Build_SourcesDirectory/letsencrypt/live/$domainName/chain.pem
az keyvault secret set --vault-name $keyVaultName --name "PFX-Certificate-b64" --file $Build_SourcesDirectory/letsencrypt/live/$domainName/certificate.pfx --encoding base64
az keyvault certificate import --vault-name $keyVaultName --name ${domainName//./-} --file $Build_SourcesDirectory/letsencrypt/live/$domainName/certificate.pfx --password $clientSecret

echo "Process completed."
