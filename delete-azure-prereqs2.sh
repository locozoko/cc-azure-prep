#/bin/bash
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
echo "                                              ";
echo "This script delete the Azure prereqs created by the prep script
The following actions are taken:
================
2. Displays the Azure resources previously created that will be deleted
3. Delete the Azure Service Principal [terraform only]
4. Delete the Azure Resource Group for these objects, which includes:
    -Azure Managed Identity
    -Azure Key Vault with Secrets
    -Azure SSH Key Pair [azure resource manager only]
================${reset}
"

# Display the Azure resources to be deleted
azure_sp_name=$(cat zsccazureprep-*.output | grep "Azure Service Principal" | cut -d ' ' -f4)
if [ -z "$azure_sp_name" ]
then
    #do not retreieve SP because it's empty
    echo "No Service Principal..."
else
    azure_sp_id=$(az ad sp list --display-name $azure_sp_name --output tsv --query "[].{objectId:objectId}")
fi
azure_rg_name=$(cat zsccazureprep-*.output | grep "Azure Resource Group" | cut -d ' ' -f4)
azure_rg_id=$(az group show --name $azure_rg_name --output tsv | cut -d '/' -f3)
azure_managedid=$(cat zsccazureprep-*.output | grep "Azure Managed Identity" | cut -d ' ' -f5)
azure_vault=$(cat zsccazureprep-*.output | grep "Azure Vault URL" | cut -d ' ' -f4)
azure_sshkey=$(az sshkey list --resource-group $azure_rg_name --output tsv --query "[].{rg:resourceGroup}")
echo ""
echo "The following Azure Service Principal was found: " ${blue} $azure_sp_name ${reset}
echo "The above Azure Service Principal Object Id is: " ${blue} $azure_sp_id ${reset}
echo ""
echo "The following Azure Resource Group was found: " ${blue} $azure_rg_name ${reset}
echo "The above Azure Resource Group Id is: " ${blue} $azure_rg_id ${reset}
echo ""
echo "The following Azure Managed Identity was found: " ${blue} $azure_managedid ${reset}
echo "The following Azure Vault was found: " ${blue} $azure_vault ${reset}
echo ""
echo "The following Azure SSH Key Pair was found: " ${blue} $azure_sshkey ${reset}

#Deletes the appropriate resources
read -p "${purple}The above resources will be deleted. Continue? [y|n]: ${reset}" confirm
echo ""
if [ $confirm = "y" ]
then
    if [ -z "$azure_sp_id" ]
    then
        echo "${purple} Deleting Resource Group...${reset}"
        az group delete --yes --no-wait --resource-group $azure_rg_name
        echo ""
        echo "${purple} Deletion Completed!${reset}"
    else
        echo "${purple} Deleting Service Principal...${reset}"
        az ad sp delete --id $azure_sp_id
        echo "${purple} Deleting Resource Group... this will take several minutes${reset}"
        az group delete --yes --no-wait --resource-group $azure_rg_name
        echo ""
        echo "${purple} Deletion Completed!${reset}"
    fi
else
    echo "${red}Cancelling deletion script...${reset}"
    exit
fi