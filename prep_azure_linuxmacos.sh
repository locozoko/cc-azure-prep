#!/bin/bash
# This script prepares the Azure account with all the required prerequisites for Cloud Connector

set -e
red=`tput setaf 1`
purple=`tput setaf 5`
blue=`tput setaf 4`
reset=`tput sgr0`

# Script description
echo "${blue} ____    ___   ___    _    _      ___   ____  ";
echo ")___ (  (  _( / _(   )_\  ) |    ) __( /  _ \ ";
echo "  / /_  _) \  ))_   /( )\ | (__  | _)  )  ' / ";
echo " )____()____) \__( )_/ \_()____( )___( |_()_\ ";
echo "                                              ${reset}";
echo "This script can be used to configure Azure with the Cloud Connector prerequisites.
The following actions are taken:
================
1. Checks if Azure CLI is installed
2. Installs Azure CLI (and homebrew on macos) if needed
3. Check if you are logged into Azure CLI
4. Prompts for Azure and Zscaler Information
5. Create Azure Service Principal [terraform only]
6. Create Azure Resource Group for these objects
7. Create Azure Managed Identity with Network Contributor Role
8. Create Azure Key Vault with Secrets
9. CreateAzure SSH Key Pair [azure resource manager only]
10. Accepts the Azure Marketplace Terms for Zscaler Cloud Connector
================
"
read -p "${purple}Do you wish to conintue?${reset} " -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "${blue}Checking for prerequisites...${reset}"
else
    echo "${red}Cancelling the script...${reset}"
    exit
fi
# Check OS and install Azure CLI and prerequisites if needed
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Ubuntu and Debian
        curl -L https://aka.ms/InstallAzureCli | bash
elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macos
        which -s brew
        if [[ $? != 0 ]] ; then
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        which -s az
        if [[ $? != 0 ]] ; then
            brew update && brew install azure-cli
        fi
elif [[ "$OSTYPE" == "win32"  ]]; then
        # Windows
        echo "${red}We have detected you are running this script on Windows. This won't work so please create the Azure requirements manually.${reset}"
        exit
else
        # Unknown OS
        echo "${red}We could not detect the Operating System type. The script might not work so please create the Azure requierments manually.${reset}"
        exit
fi

# Check if logged into Azure with CLI
echo "${blue}Checking if you are logged into the Azure CLI...${reset}"
azurecli_loggedin=$(az account show)
azure_username=$(az account show --query  user.name -o tsv)
if echo $azurecli_loggedin | grep -q "environmentName";
then
    echo "You are logged into the Azure CLI as: $azure_username"
fi

# Obtain Azure Subscription and TenantID, set as variables for currently logged in user
azure_tenant_id=$(az account show --query tenantId --output tsv)
azure_subscription_name=$(az account show --query name --output tsv)
azure_subscription_id=$(az account show --query id --output tsv)
echo "Tenant ID: $azure_tenant_id"
echo "Subscription Name: $azure_subscription_name"
echo "Subscription ID: $azure_subscription_id"

echo ""
read -p "${purple}Is this the correct Tenant and Subscription (continue)?${reset} " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]
then
    # Ask User for inputs on naming prefix for  objects, Azure region
    echo ""
    echo "${blue}Here's an up-to-date list of all the Azure Regions:${reset} "
    az account list-locations --query "[].{Name:name}" -o tsv | xargs -n5 | sort | sed 's/ / | /g'
    echo ""
    read -p "${purple}Azure Region to Use:${reset} " azure_location
    read -p "${purple}Cloud Connector API Key:${reset} " cc_api_key
    read -p "${purple}Cloud Connector Username:${reset} " cc_admin_user
    read -p "${purple}Cloud Connector Password:${reset} " -s cc_admin_pass
    echo -e "\n"
else
    echo "${red}Cancelling the script...${reset}"
    exit
fi

ok=0
while [ $ok = 0 ]
do
    read -p "${purple}Prefix to use (leave empty to use zscalercc):${reset} " prefix
    prefix=${prefix:-zscalercc}
    if [ ${#prefix} -gt 13 ]
    then
        echo "${red}Too long - 13 characters max${reset}"
    else
    ok=1
    fi
done

echo ""
echo "*Note: arm is Azure Resource Manager*"
read -p "${purple}How will you deploy Cloud Connectors in Azure? [arm|terraform]${reset} " deployment
echo ""

echo "Zscaler Cloud Connector on Azure Deployment Prep Information" | tee output.log
echo ""  | tee -a output.log
date | tee -a output.log
echo "Directory (tenant) ID: $azure_tenant_id" | tee -a output.log
echo "Azure Region: $azure_location" | tee -a output.log

# Create Azure Service Principle required for Terraform Use
if [[ $deployment = "terraform" ]];
then
    # Service Principal Creation 
    echo "${blue}Checking if the Azure Service Principle $prefix-serviceprincipal already exists...${reset}"
    check_sp_exists=$(az ad sp list --display-name $prefix-serviceprincipal)
    if ! echo $check_sp_exists | grep -q "accountEnabled";
    then
        echo "${blue}Creating new Azure Service Principal...${reset}"
        az ad sp create-for-rbac --role="Contributor" --scopes="/subscriptions/$azure_subscription_id" --name $prefix-serviceprincipal --output tsv > prep_azure.tmp
        azure_sp_appid=$(cut -f1 prep_azure.tmp)
        azure_sp_display=$(cut -f2 prep_azure.tmp)
        azure_sp_pwd=$(cut -f3 prep_azure.tmp)
        azure_sp_tenant=$(cut -f4 prep_azure.tmp)
        echo "Azure Service Principal Created Successfully..."
        echo "Azure Service Principal: $prefix-serviceprincipal" | tee -a output.log
    fi
else
    echo "${blue}Skipping Azure Service Principal Creation (only needed with Terraform)...${reset}"
fi
echo "Azure Subscription Name: $azure_subscription_name" | tee -a output.log
echo "Azure Subcription Id: $azure_subscription_id" | tee -a output.log
echo "Application (client) ID: $azure_sp_appid" | tee -a output.log
echo "Client Secret Value: $azure_sp_pwd" | tee -a output.log

# Create Azure Resource Group
echo "${blue}Creating Azure Resource Group...${reset}"
az group create --name "$prefix-rg" -l "$azure_location"
echo "Azure Resource Group: $prefix-rg" | tee -a output.log

# Create Azure User Assigned Managed Identity and Assign Required Roles
echo "${blue}Creating Azure Managed Identity...${reset}"
az identity create --name "$prefix-managedidentity" --resource-group "$prefix-rg" --location "$azure_location"
azure_managed_id=$(az resource show --id "/subscriptions/$azure_subscription_id/resourceGroups/$prefix-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$prefix-managedidentity" --query "properties.principalId" -o tsv)
echo "${blue}Assigning Managed Identity to Network Contributor Role...${reset}"
az role assignment create --assignee-object-id "$azure_managed_id" --assignee-principal-type "ServicePrincipal" --role "Network Contributor" --scope "/subscriptions/$azure_subscription_id"
echo "Azure Managed Identity Name: $prefix-managedidentity" | tee -a output.log

# Create Cloud Connector API Information, Create Azure Key Vault, Assign Acess Policy and Create Secrets
# Also generate a pesudo random  string to add as suffix to key vault name as it needs to be globally unique in Azure
echo "${blue}Creating Azure Key Vault and Storing Cloud Connector Secrets. This can take a couple minutes...${reset}"
random=$(openssl rand -hex 2)
az keyvault create --name "$prefix-vault-$random" --resource-group "$prefix-rg" --location "$azure_location" --enabled-for-template-deployment true
az keyvault set-policy --name "$prefix-vault-$random" --object-id "$azure_managed_id" --secret-permissions get list
az keyvault secret set --vault-name "$prefix-vault-$random" --name "api-key" --value "$cc_api_key"
az keyvault secret set --vault-name "$prefix-vault-$random" --name "username" --value "$cc_admin_user"
az keyvault secret set --vault-name "$prefix-vault-$random" --name "password" --value "$cc_admin_pass"
echo "Azure Vault URL: https://$prefix-vault-$random.vault.azure.net" | tee -a output.log

# Check for and Accept the Terms for the Zscaler Cloud Connector Application
echo "${blue}Checking if the Zscaler Cloud Connector Terms Accepted in the Azure Marketplace...${reset}"
accepted_terms=$(az vm image terms show --urn zscaler1579058425289:zia_cloud_connector:zs_ser_cc_03:latest --query accepted)
if [[ "$accepted_terms" == "true" ]]; 
then
    echo ${blue}"Terms Already Accepted...${reset}"
else
    echo "${blue}Accepting Terms for the Zscaler Cloud Connector...${reset}"
    az vm image terms accept --urn zscaler1579058425289:zia_cloud_connector:zs_ser_cc_03:latest
fi

# Create Azure SSH Key Pair if Deployment with Azure Resource Manager (skip if using Terraform)
if [[ $deployment = "arm" || $deployment = "ARM" ]];
then
    # Create SSH keys if using Azure Resource Manager (ARM)
    echo "${blue}Creating Azure SSH Key Pair...${reset}"
    az sshkey create --location "$azure_location" --resource-group "$prefix-rg" --name "$prefix-sshkeypair"
    echo "Azure SSH Key Pair files stored in the ~/.ssh directory" | tee -a output.log
else
    echo "${blue}Skipping SSH Key Creation (only needed with ARM)...${reset}"
fi

# Display output
cat output.log
echo ""
echo "${purple}The above is also saved to output.log in current directory${reset}"
echo ""
echo "${purple}ZSCALER CLOUD CONNECTOR AZURE PREP SCRIPT COMPLETED SUCCESSFULLY!${redset}"

## need to add managed identity name to output!!!