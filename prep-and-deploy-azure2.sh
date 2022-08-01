#!/bin/bash
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
1. Creates all Azure prerequisites for Terraform deployments
2. Applies the Zsclaer Cloud Connector Terraform plan
================
"

# Check to make sure the script is in the Zscaler Cloud Connector terraform template folder
FILE1=zsec
FILE2=terraform.tfvars
if test -f "$FILE1"; then
    echo ""
    if test -f "$FILE2"; then 
        echo ""
    else   
    echo "${red}This script must be run in the root directory of the Azure Terraform Cloud Connector template..."
    echo "Quitting...${reset}"
    exit
    fi
else
    echo "${red}This script must be run in the root directory of the Azure Terraform Cloud Connector template..."
    echo "Quitting...${reset}"
    exit
fi

# Check OS and install Azure CLI and prerequisites if needed on macos
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "${blue}Checking for prerequisites...${reset}"
    which -s brew
    if [[ $? != 0 ]] ; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    which -s az
    if [[ $? != 0 ]] ; then
        brew update && brew install azure-cli
        echo "${blue}Log into Azure CLI [ ${reset}az login${blue} ] and then restart this script...${reset}"
        exit
    fi
fi

echo "${blue}Here's an up-to-date list of all the Azure Regions:${reset} "
az account list-locations --query "[].{Name:name}" -o tsv | xargs -n5 | sort | sed 's/ / | /g'
echo ""
read -p "${purple}Azure Region to Use:${reset} " azure_location
echo ""
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
read -p "${purple}Cloud Connector Provisioning URL:${reset} " PROV_URL_NEW
read -p "${purple}Cloud Connector HTTP Probe Port:${reset} " PROBE_PORT_NEW
read -p "${purple}Cloud Connector API Key:${reset} " cc_api_key
read -p "${purple}Cloud Connector Username:${reset} " cc_admin_user
read -p "${purple}Cloud Connector Password:${reset} " -s cc_admin_pass
echo -e "\n"

# Check if unzip is installed
which unzip > /dev/null 2>&1
if [ $? != 0 ]
then
    apt install unzip -y
fi

# Obtain Azure Subscription and TenantID, set as variables for currently logged in user
echo "Current Azure Information: "
azure_tenant_id=$(az account show --query tenantId --output tsv)
azure_subscription_name=$(az account show --query name --output tsv)
azure_subscription_id=$(az account show --query id --output tsv)
echo "Tenant ID: $azure_tenant_id"
echo "Subscription Name: $azure_subscription_name"
echo "Subscription ID: $azure_subscription_id"

echo ""
read -p "${purple}The above is the current Azure account. Continue? [y|n]: ${reset}" confirm
echo ""
if [ $confirm = "y" ]
then
    # Ask User for inputs on naming prefix for  objects, Azure region
    echo "Starting the Deployment..."
else
    echo "${red}Cancelling...${reset}"
    exit
fi
random=$(openssl rand -hex 2)

echo "Zscaler Cloud Connector on Azure Deployment Prep Information" | tee zsccazureprep-$random.output
echo ""  | tee -a zsccazureprep-$random.output
date | tee -a zsccazureprep-$random.output
echo "Directory (tenant) ID: $azure_tenant_id" | tee -a zsccazureprep-$random.output
echo "Azure Region: $azure_location" | tee -a zsccazureprep-$random.output

# Create Azure Service Principle required for Terraform Use
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
     echo "Azure Service Principal: $prefix-serviceprincipal" | tee -a zsccazureprep-$random.output
    echo "Application (client) ID: $azure_sp_appid" | tee -a zsccazureprep-$random.output
    echo "Client Secret Value: $azure_sp_pwd" | tee -a zsccazureprep-$random.output
fi

echo "Azure Subscription Name: $azure_subscription_name" | tee -a zsccazureprep-$random.output
echo "Azure Subcription Id: $azure_subscription_id" | tee -a zsccazureprep-$random.output

# Create Azure Resource Group
echo "${blue}Creating Azure Resource Group...${reset}"
az group create --name "$prefix-rg" -l "$azure_location"
echo "Azure Resource Group: $prefix-rg" | tee -a zsccazureprep-$random.output

# Create Azure User Assigned Managed Identity and Assign Required Roles
echo "${blue}Creating Azure Managed Identity...${reset}"
az identity create --name "$prefix-managedidentity" --resource-group "$prefix-rg" --location "$azure_location"
azure_managed_id=$(az resource show --id "/subscriptions/$azure_subscription_id/resourceGroups/$prefix-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$prefix-managedidentity" --query "properties.principalId" -o tsv)
echo "${blue}Creating Custom Role with Network Interfaces read permissions...${reset}"
#Need to create custom json file and role 

#Assign that new custom role to the managed identity
echo "${blue}Assigning Managed Identity to a Custom Role...${reset}"
az role assignment create --assignee-object-id "$azure_managed_id" --assignee-principal-type "ServicePrincipal" --role "Network Contributor" --scope "/subscriptions/$azure_subscription_id"
echo "Azure Managed Identity Name: $prefix-managedidentity" | tee -a zsccazureprep-$random.output

# Create Cloud Connector API Information, Create Azure Key Vault, Assign Acess Policy and Create Secrets
# Also generate a pesudo random  string to add as suffix to key vault name as it needs to be globally unique in Azure
echo "${blue}Creating Azure Key Vault and Storing Cloud Connector Secrets. This can take a couple minutes...${reset}"
az keyvault create --name "$prefix-vault-$random" --resource-group "$prefix-rg" --location "$azure_location" --enabled-for-template-deployment true
az keyvault set-policy --name "$prefix-vault-$random" --object-id "$azure_managed_id" --secret-permissions get list
az keyvault secret set --vault-name "$prefix-vault-$random" --name "api-key" --value "$cc_api_key"
az keyvault secret set --vault-name "$prefix-vault-$random" --name "username" --value "$cc_admin_user"
az keyvault secret set --vault-name "$prefix-vault-$random" --name "password" --value "$cc_admin_pass"
echo "Azure Vault URL: https://$prefix-vault-$random.vault.azure.net" | tee -a zsccazureprep-$random.output

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

# Display output
cat zsccazureprep-$random.output
echo ""
echo "${purple}The above is also saved to output-$prefix.log in current directory"
echo "Don't forget to Download your private key file from ~/.ssh directory${reset}"
echo ""
echo "${purple}ZSCALER CLOUD CONNECTOR AZURE PREP SCRIPT COMPLETED SUCCESSFULLY!${redset}"

# These will be generated from the prep output to be used by terraform
if [[ "$OSTYPE" == "darwin"* ]]; then
    #sed with the -i .bak parameters
    sed -i .bak 's/#cc_vm_prov_url/cc_vm_prov_url/g' terraform.tfvars
    PROV_URL=connector.zscalerbeta.net/wapi/v1/provUrl?name=azure_prov_url
    sed -i .bak 's,'"$PROV_URL"','"$PROV_URL_NEW"',' terraform.tfvars

    sed -i .bak 's/#http_probe_port/http_probe_port/g' terraform.tfvars
    PROBE_PORT=50000
    sed -i .bak 's,'"$PROBE_PORT"','"$PROBE_PORT_NEW"',' terraform.tfvars

    sed -i .bak 's/#azure_vault_url/azure_vault_url/g' terraform.tfvars
    VAULT_URL=https://zscaler-cc-demo.vault.azure.net
    VAULT_URL_NEW=$(echo "https://${prefix}-vault-${random}.vault.azure.net")
    sed -i .bak 's,'"$VAULT_URL"','"$VAULT_URL_NEW"',' terraform.tfvars

    sed -i .bak 's/#cc_vm_managed_identity_name/cc_vm_managed_identity_name/g' terraform.tfvars
    MANAGED_ID=cloud_connector_managed_identity
    MANAGED_ID_NEW=$(echo "${prefix}-managedidentity")
    sed -i .bak 's,'"$MANAGED_ID"','"$MANAGED_ID_NEW"',' terraform.tfvars

    sed -i .bak 's/#cc_vm_managed_identity_resource_group/cc_vm_managed_identity_resource_group/g' terraform.tfvars
    CC_RG=cloud_connector_rg_1
    CC_RG_NEW=$(echo "${prefix}-rg")
    sed -i .bak 's,'"$CC_RG"','"$CC_RG_NEW"',' terraform.tfvars 
else
    sed -i 's/#cc_vm_prov_url/cc_vm_prov_url/g' terraform.tfvars
    PROV_URL=connector.zscalerbeta.net/wapi/v1/provUrl?name=azure_prov_url
    sed -i 's,'"$PROV_URL"','"$PROV_URL_NEW"',' terraform.tfvars

    sed -i 's/#http_probe_port/http_probe_port/g' terraform.tfvars
    PROBE_PORT=50000
    sed -i 's,'"$PROBE_PORT"','"$PROBE_PORT_NEW"',' terraform.tfvars

    sed -i 's/#azure_vault_url/azure_vault_url/g' terraform.tfvars
    VAULT_URL=https://zscaler-cc-demo.vault.azure.net
    VAULT_URL_NEW=$(echo "https://${prefix}-vault-${random}.vault.azure.net")
    sed -i 's,'"$VAULT_URL"','"$VAULT_URL_NEW"',' terraform.tfvars

    sed -i 's/#cc_vm_managed_identity_name/cc_vm_managed_identity_name/g' terraform.tfvars
    MANAGED_ID=cloud_connector_managed_identity
    MANAGED_ID_NEW=$(echo "${prefix}-managedidentity")
    sed -i 's,'"$MANAGED_ID"','"$MANAGED_ID_NEW"',' terraform.tfvars

    sed -i 's/#cc_vm_managed_identity_resource_group/cc_vm_managed_identity_resource_group/g' terraform.tfvars
    CC_RG=cloud_connector_rg_1
    CC_RG_NEW=$(echo "${prefix}-rg")
    sed -i 's,'"$CC_RG"','"$CC_RG_NEW"',' terraform.tfvars 
fi

echo "export ARM_CLIENT_ID=${azure_sp_appid}" > .zsecrc
echo "export ARM_CLIENT_SECRET=${azure_sp_pwd}" >> .zsecrc
echo "export ARM_SUBSCRIPTION_ID=${azure_subscription_id}" >> .zsecrc
echo "export ARM_TENANT_ID=${azure_tenant_id}" >> .zsecrc
echo "export TF_VAR_ARM_LOCATION=${azure_location}" >> .zsecrc

# Run the terraform deployment script
./zsec up