#! /bin/bash

PREFIX="ciscomcd-walsaid"
webhook_endpoint=""

usage() {
    echo "Usage: $0 [args]"
    echo "-h This help message"
    echo "-p <prefix> - Prefix to use for the App and IAM Role, defaults to ciscomcd"
    echo "-w <webhook_endpoint> - Your Webhook Endpoint"
    exit 1
}

while getopts "hp:w:" optname; do
    case "${optname}" in
        h)
            usage
            ;;
        p)
            PREFIX=${OPTARG}
            ;;
        w)
            webhook_endpoint=${OPTARG}
            ;;
    esac
done

account_info=$(az account show)
sub_name=$(echo $account_info | jq -r .name)
sub_id=$(echo $account_info | jq -r .id)

echo "Your current subscription is ${sub_name} / ${sub_id}"
read -p "Is this the subscription you want to onboard to Cisco Multicloud Defense? [y/n] " -n 1

if [ "$REPLY" == "n" ]; then
    all_sub=$(az account list)
    sub_list=$(echo $all_sub | jq -r '.[].name')
    tmp_id_list=$(echo $all_sub | jq -r '.[].id')
    id_list=($tmp_id_list)
    echo "Select your subscription:"
    IFS=$'\n'
    num=0
    for i in $sub_list; do
        echo "($num) $i / ${id_list[$num]}"
        num=$(( $num + 1 ))
    done
    num=$(($num-1))
    read -p "Enter number from 0 - $num: " sub_selection
    tmp_sub_list=($sub_list)
    echo "Setting the subscription to ${tmp_sub_list[$sub_selection]} / ${id_list[$sub_selection]}"
    az account set --subscription ${id_list[$sub_selection]} --only-show-errors
    account_info=$(az account show -s ${id_list[$sub_selection]})
    sub_name=$(echo $account_info | jq -r .name)
    sub_id=$(echo $account_info | jq -r .id)
    unset IFS
fi

APP_NAME=$PREFIX-controller-app
ROLE_NAME=$PREFIX-controller-role
EVENT_SUB_NAME=$PREFIX-controller-inventory

tenant_id=$(echo $account_info | jq -r .tenantId)

echo
echo Using the subscription \"$sub_name / $sub_id\"
echo Create AD App Registraion $APP_NAME
echo Create Custom IAM Role $ROLE_NAME

read -p "Continue creating? [y/n] " -n 1
echo ""
if [[ "$REPLY" != "y" ]]; then
    exit 1
fi

echo "Enabling microsoft.compute in Resource Providers"
az provider register --namespace 'microsoft.compute' --subscription $sub_id
echo "Enabling microsoft.network in Resource Providers"
az provider register --namespace 'microsoft.network' --subscription $sub_id
echo "Enabling microsoft.eventgrid in Resource Providers"
az provider register --namespace 'microsoft.eventgrid' --subscription $sub_id
echo "Enabling microsoft.marketplace in Resource Providers"
az provider register --namespace 'microsoft.marketplace' --subscription $sub_id

cat > /tmp/role.json <<- EOF
{
    "Name": "$ROLE_NAME",
    "Description": "Role used by the Cisco Multicloud Defense Controller to manage Subscription(s)",
    "IsCustom": true,
    "Actions": [
      "Microsoft.ApiManagement/service/*",
      "Microsoft.Compute/disks/*",
      "Microsoft.Compute/images/read",
      "Microsoft.Compute/sshPublicKeys/read",
      "Microsoft.Compute/virtualMachines/*",
      "Microsoft.ManagedIdentity/userAssignedIdentities/read",
      "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
      "Microsoft.Network/loadBalancers/*",
      "Microsoft.Network/networkinterfaces/*",
      "Microsoft.Network/networkSecurityGroups/*",
      "Microsoft.Network/publicIPAddresses/*",
      "Microsoft.Network/routeTables/*",
      "Microsoft.Network/virtualNetworks/*",
      "Microsoft.Network/virtualNetworks/subnets/*",
      "Microsoft.Resources/subscriptions/resourcegroups/*",
      "Microsoft.Storage/storageAccounts/blobServices/*",
      "Microsoft.Storage/storageAccounts/listkeys/action",
      "Microsoft.Network/networkWatchers/*",
      "Microsoft.Network/applicationSecurityGroups/*",
      "Microsoft.Compute/diskEncryptionSets/read"
    ],
    "AssignableScopes": [
        "/subscriptions/$sub_id"
    ]
}
EOF

echo "Create AD App Registration $APP_NAME"
app_rsp=$(az ad app create --display-name $APP_NAME 2>&1)
app_output=$(az ad app list --display-name $APP_NAME | jq -r '.[0]')
app_id=$(echo $app_output | jq -r .appId)
if [ "$app_id" = "null" ]; then
    echo "App cannot be created, trying running script again after checking permissions"
    echo $app_rsp
    exit 1
fi
echo "Create App Service Prinicipal $APP_NAME"
sp_rsp=$(az ad sp create --id $app_id 2>&1)
sp_object_rsp=$(az ad sp show --id $app_id)
sp_object_id=$(echo $sp_object_rsp | jq -r 'if .objectId != null then .objectId else .id end')
if [ "$sp_object_id" = "null" ]; then
    echo "Service Principal for the App cannot be created"
    echo $sp_rsp
    exit 1
fi
echo "Create App Secret"
secret=$(az ad app credential reset --id $app_id --credential-description 'ciscomcd-secret' --years 5 2>/dev/null | jq -r .password)
if [ "$secret" = "null" -o "$secret" = "" ]; then
    secret=$(az ad app credential reset --id $app_id --display-name 'ciscomcd-secret' --years 5 2>/dev/null | jq -r .password)
fi
if [ "$secret" = "null" ]; then
    echo "App Secret cannot be created"
    exit 1
fi

echo "Create IAM Role $ROLE_NAME"
role_rsp=$(az role definition create --subscription $sub_id --role-definition /tmp/role.json 2>&1)
# if you want to reuse the role (continuing aborted run), dont depend on the exit code of the previous
# command to continue further
echo "Assign the Role $ROLE_NAME to the App $APP_NAME"
for i in {1..10}; do
    role_app_rsp=$(az role assignment create --subscription $sub_id \
        --assignee-object-id $sp_object_id \
        --assignee-principal-type ServicePrincipal \
        --role $ROLE_NAME 2>&1)
    pname=$(az role assignment list --subscription $sub_id --role $ROLE_NAME | jq -r '.[0].principalName')
    if [ "$pname" != "$app_id" ]; then
        if [ $i -eq 10 ]; then
            echo -e "\033[31m** Role could not be assigned to the App\033[0m"
            echo "Role assignment output"
            echo $role_app_rsp
            echo
        else
            sleep 5
        fi
    else
        break
    fi
done

echo "Accept Marketplace agreements for Cisco Multicloud Defense Gateway Image"
mkt_rsp=$(az vm image terms accept --subscription $sub_id --publisher valtix --offer datapath --plan valtix_dp_image)
terms_rsp=$(echo $mkt_rsp | jq -r .accepted)
if [ "$terms_rsp" != "true" ]; then
    echo -e "\033[31m** Marketplace terms could not be accepted\033[0m"
    echo $mkt_rsp
fi

echo "Creating event subscription for an Azure subscription"
az eventgrid event-subscription create \
    --source-resource-id "/subscriptions/${sub_id}" \
    --name "$EVENT_SUB_NAME" \
    --endpoint "$webhook_endpoint" \
    --included-event-types \
    Microsoft.Resources.ResourceWriteSuccess \
    Microsoft.Resources.ResourceDeleteSuccess \
    Microsoft.Resources.ResourceActionSuccess

cleanup_file="delete-azure-setup-$sub_id.sh"
echo "Create uninstaller script in the current directory '$cleanup_file'"

cat > $cleanup_file <<- EOF
echo Delete Event Subscription $EVENT_SUB_NAME for the subscription $subscription
az eventgrid event-subscription delete --source-resource-id /subscriptions/${sub_id} --name $EVENT_SUB_NAME
echo Delete Role Assignment $ROLE_NAME for the AD app $APP_NAME
for i in {1..5}; do
    az role assignment delete --subscription $sub_id --assignee $sp_object_id --role $ROLE_NAME
    pname=\$(az role assignment list --subscription $sub_id --role $ROLE_NAME | jq -r '.[0].principalName')
    if [ "\$pname" = "null" ]; then
        break
    else
        sleep 5
    fi
done
echo Delete IAM Role $ROLE_NAME
az role definition delete --subscription $sub_id --name $ROLE_NAME
echo Delete AD App Registration $APP_NAME
az ad app delete --id $app_id
rm $cleanup_file

EOF
chmod +x $cleanup_file

echo
echo "----------------------------------------------------------------------------------------------------"
echo "Information shown below is needed to onboard subscription to the Cisco Multicloud Defense Controller"
echo "----------------------------------------------------------------------------------------------------"
echo "Tenant/Directory: $tenant_id"
echo "    Subscription: $sub_id"
echo "             App: $app_id"
echo "          Secret: $secret"
echo "----------------------------------------------------------------------------------------------------"
echo
