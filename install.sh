#!/bin/bash
set -euo pipefail

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="${MYDIR}/config.yaml"
TEMPLATES_PATH="${MYDIR}/templates"


help()
{
    echo
    echo "Deploys and configure Azure infrastrucure for CycleCloud cluster"
    echo
    echo "USAGE: install.sh [OPTION]"
    echo "Options:"
    echo "-a    Run only ansible configuration"
    echo "-b    Run only bastion deployment"
    echo "-h    Prints this help"
    echo
}

create_bastion_scripts()
{
    TARGET_NAME=$1
    BICEP_OUTPUT_FILE=$2
    VMRESOURCEIDS=("${@:3}")

    USER=$(jq -r '.globalVars.value.cycleserverAdmin' ${BICEP_OUTPUT_FILE})
    BASTIONNAME=$(jq -r '.globalVars.value.bastionName' ${BICEP_OUTPUT_FILE})
    KEY="${MYDIR}/${USERNAME}_id_rsa"

    for TEMPLATE_ROOT in bastion_ssh bastion_tunnel; do
        VMRESOURCEIDS_STR=$(IFS=' '; echo "${VMRESOURCEIDS[*]}")
        sed -e "s|<RESOURCEGROUP>|${RESOURCE_GROUP}|g" \
            -e "s|<USERNAME>|${USER}|g" \
            -e "s|<SSHKEYPATH>|${KEY}|g" \
            -e "s|<BASTIONNAME>|${BASTIONNAME}|g" \
            -e "s|<VMRESOURCEIDS>|${VMRESOURCEIDS_STR}|g" \
            -e "s|<SUBNAME>|${SUBSCRIPTION}|g" \
            ${TEMPLATES_PATH}/${TEMPLATE_ROOT}.template > ${TEMPLATE_ROOT}_${TARGET_NAME}.sh
        chmod +x ${TEMPLATE_ROOT}_${TARGET_NAME}.sh
    done
}

# Run everything by default
RUN_BICEP=true
RUN_ANSIBLE=true

while getopts ":abh" OPT; do
    case $OPT in
        a) RUN_BICEP=false;;
        b) RUN_ANSIBLE=false;;
        h) help
           exit 0;;
        \?) help
           exit 1;;
    esac
done

##############
### CHECKS ###
##############

cmd_exists() {
    command -v "$@" &> /dev/null || { echo >&2 "$@ is required but not installed. Aborting."; exit 1; }
}

cmd_exists az
cmd_exists jq
cmd_exists yq
cmd_exists perl
cmd_exists rsync

# Check that config file is valid
source ./scripts/validate_config.sh

# Make sure submodules are also cloned
git submodule update --init --recursive

#############
### BICEP ###
#############

# Those variables must be exported to be visible from Ansible
export RESOURCE_GROUP=$(yq -r '.resource_group_name' ${CONFIG_FILE})
export SUBSCRIPTION=$(yq -r '.subscription_name' ${CONFIG_FILE})
export REGION=$(yq -r '.region' ${CONFIG_FILE})

USERNAME=$(grep cycleAdminUsername bicep/params.bicepparam | cut -d"'" -f 2)
KEYFILE="${USERNAME}_id_rsa"
MYSQL_PWD_FILE="mysql_admin_pwd.txt"

if [ ${RUN_BICEP} == true ]; then

    DEPLOYMENT_NAME=bicepdeploy-$(date +%Y%m%d%H%M%S)
    DEPLOYMENT_OUTPUT=${RESOURCE_GROUP}_${DEPLOYMENT_NAME}.json

    if [ ! -f ./${KEYFILE} ]; then
        echo "Generating new keypair for ${USERNAME}"
        ssh-keygen -m PEM -t rsa -b 4096 -f ./${KEYFILE} -N ''
        # Remove newline after public key to avoid issues when using it as parameter json files
        perl -pi -e 'chomp if eof' ./${KEYFILE}.pub
    fi

    # Generate password for MySQL database
    if [ ! -f ./${MYSQL_PWD_FILE} ]; then
        echo "Generating new password for MySQL database"
        openssl rand -base64 16 | tr -d \\n > ./${MYSQL_PWD_FILE}
        chmod 400 ./${MYSQL_PWD_FILE}
    fi

    # Make sure we are using the correct subscription
    az account set --subscription "${SUBSCRIPTION}"

    # Accept Azure Marketplace terms for CycleCloud image
    az vm image terms accept --publisher azurecyclecloud \
                             --offer azure-cyclecloud \
                             --plan cyclecloud8-gen2

    # Required to grant access to key vault secrets
    export USER_OBJECTID=$(az ad signed-in-user show --query id --output tsv)

    # Create JSON files for additional bicep variables
    set +e  # Ignore errors when the optional variables are not present
    yq -ej '.resource_group_tags' ${CONFIG_FILE} > bicep/rg_tags.json
    [ $? -ne 0 ] && echo '{}' > bicep/rg_tags.json
    yq -ej '.monitor_tags' ${CONFIG_FILE} > bicep/monitor_tags.json
    [ $? -ne 0 ] && echo '{}' > bicep/monitor_tags.json
    set -e  # Resume normal error handling

    # Start deployment
    az deployment sub create --template-file bicep/main.bicep \
                             --parameters bicep/params.bicepparam \
                             --location ${REGION} \
                             --name ${DEPLOYMENT_NAME}

    # Collect deployment output
    az deployment sub show --name ${DEPLOYMENT_NAME} \
                           --query properties.outputs \
                           > ${DEPLOYMENT_OUTPUT}

    # Assign Metrics Publisher role to Prometheus VM identity
    # Cannot be done in previous bicep deployment as explained here:
    # https://github.com/Azure/bicep/discussions/13352
    ROLE_ASSIGNMENT_OUTPUT_FILE=metrics_publisher_assignment.json
    VM_PRINCIPAL_ID=$(jq -r '.globalVars.value.prometheusVmPrincipalId' ${DEPLOYMENT_OUTPUT})
    ROLE_SCOPE=$(jq -r '.globalVars.value.dataCollectionRuleId' ${DEPLOYMENT_OUTPUT})
    az role assignment create --role 'Monitoring Metrics Publisher' \
                              --assignee ${VM_PRINCIPAL_ID} \
                              --scope ${ROLE_SCOPE} > ${ROLE_ASSIGNMENT_OUTPUT_FILE}

    # Add the system managed identity application ID to the deployment output file
    APP_ID=$(jq -r '.principalName' ${ROLE_ASSIGNMENT_OUTPUT_FILE})

    # Sometimes the application ID is not immediately available, so we try again
    while [ $(echo $APP_ID | wc -m) -lt 37 ]; do
        sleep 5
        APP_ID=$(az role assignment list --role 'Monitoring Metrics Publisher' --assignee ${VM_PRINCIPAL_ID} --scope ${ROLE_SCOPE} --query '[].principalName' --output tsv)
    done

    # Propogate env vars to Ansible via the deployment output file
    jq --arg appId "${APP_ID}" '.globalVars.value.prometheusMetricsPubAppId = $appId' ${DEPLOYMENT_OUTPUT} > temp.json && mv temp.json ${DEPLOYMENT_OUTPUT}
    jq --arg hpcSku "${HPC_SKU}" '.globalVars.value.hpcSku = $hpcSku' ${DEPLOYMENT_OUTPUT} > temp.json && mv temp.json ${DEPLOYMENT_OUTPUT}
    jq --arg hpcMaxCoreCount "${HPC_MAX_CORE_COUNT}" '.globalVars.value.hpcMaxCoreCount = $hpcMaxCoreCount' ${DEPLOYMENT_OUTPUT} > temp.json && mv temp.json ${DEPLOYMENT_OUTPUT}
    jq --arg hpcMaxNumVMs "${HPC_MAX_NUM_VMS}" '.globalVars.value.hpcMaxNumVMs = $hpcMaxNumVMs' ${DEPLOYMENT_OUTPUT} > temp.json && mv temp.json ${DEPLOYMENT_OUTPUT}

    # Add fields removed from deployment output to be ingested by Ansible
    jq --arg cycleserverAdminPubKey "$(cat cycleadmin_id_rsa.pub)" '.globalVars.value.cycleserverAdminPubKey = $cycleserverAdminPubKey' ${DEPLOYMENT_OUTPUT} > temp.json && mv temp.json ${DEPLOYMENT_OUTPUT}
    jq --arg mySqlPwd "$(cat mysql_admin_pwd.txt)" '.globalVars.value.mySqlPwd = $mySqlPwd' ${DEPLOYMENT_OUTPUT} > temp.json && mv temp.json ${DEPLOYMENT_OUTPUT}
    rm -f ${ROLE_ASSIGNMENT_OUTPUT_FILE}
fi

# Use the latest available Bicep deployment output
DEPLOYMENT_OUTPUT=$(ls -t ${RESOURCE_GROUP}_bicepdeploy-*.json | head -1)

# Generate bastion scripts for cycleserver and promehteus VMs
VM_ID=$(jq -r '.globalVars.value.cycleserverId' ${DEPLOYMENT_OUTPUT})
create_bastion_scripts 'cycleserver' ${DEPLOYMENT_OUTPUT} ${VM_ID}

VM_ID=$(jq -r '.globalVars.value.prometheusVmId' ${DEPLOYMENT_OUTPUT})
create_bastion_scripts 'prometheus' ${DEPLOYMENT_OUTPUT} ${VM_ID}

###############
### ANSIBLE ###
###############

if [ ${RUN_ANSIBLE} == true ]; then

    # Install Ansible in conda environment
    [ -d ./miniconda ] || ./ansible/install/install_ansible.sh > "${MYDIR}/ansible_install.log" 2>&1

    # The special variable @ must be set to empty before activating the conda
    # environment as the conda activate script appends it to the conda command
    # causing it to fail if still containing the install script options
    set --

    # Activate conda environment
    source ${MYDIR}/miniconda/bin/activate

    # Create inventory file with the appropriate variable to execute through jump host
    ANSIBLE_INVENTORY=${MYDIR}/ansible/inventory.json
    sed "s|ROOT_DIR|${MYDIR}|g" ansible/templates/ssh_jumphost_vars.json.tmpl > ansible/templates/ssh_jumphost_vars.json
    jq -s '.[0].ansible_inventory.value * {"all": .[1]}' ${DEPLOYMENT_OUTPUT} ansible/templates/ssh_jumphost_vars.json > ${ANSIBLE_INVENTORY}

    # Create global variables file
    mkdir -p ansible/group_vars/all
    jq -s '.[].globalVars.value' ${DEPLOYMENT_OUTPUT} > ansible/group_vars/all/global_vars.json

    # Open SSH tunnel through bastion
    ./bastion_tunnel_cycleserver.sh 22 10022 &
    sleep 5

    # Kill tunnel processes on exit
    TUNNEL_PIDS=$(ps aux | grep bastion | grep -v grep | awk '{print $2}')
    trap 'kill $(echo $TUNNEL_PIDS)' EXIT

    # Run Ansible playbooks
    export ANSIBLE_CONFIG=${MYDIR}/ansible/ansible.cfg
    ansible-playbook -i ${ANSIBLE_INVENTORY} ansible/playbooks/cyclecloud.yml
    sleep 15  # Necessary for SSH control persist to expire (see ansible.cfg)
    ansible-playbook -i ${ANSIBLE_INVENTORY} ansible/playbooks/prometheus.yml

    # Create Bastion connection scripts for scheduler VM
    for i in {1..20}; do
        SCHEDULER_VM_ID=$(az resource list -g ${RESOURCE_GROUP} --resource-type 'Microsoft.Compute/virtualMachines' --query "[?tags.Name == 'scheduler'].id" -o tsv)

        # If scheduler VM is not yet created, wait and try again
        if [ -z "${SCHEDULER_VM_ID}" ]; then
            echo "Scheduler VM not yet allocated. Retrying bastion scripts generation in 5 seconds..."
            sleep 5
            continue
        else
            create_bastion_scripts 'scheduler' ${DEPLOYMENT_OUTPUT} ${SCHEDULER_VM_ID}
            break
        fi
    done

    # Create Bastion connection scripts for login VMs
    NUMBER_OF_LOGIN_VMS=$(jq -r '.globalVars.value.loginNicsCount' ${DEPLOYMENT_OUTPUT})
    LOGIN_VM_IDS=()

    for LOGIN_VM_IDX in $(seq 1 ${NUMBER_OF_LOGIN_VMS}); do
        for i in {1..20}; do
            LOGIN_VM_ID=$(az resource list -g ${RESOURCE_GROUP} --resource-type 'Microsoft.Compute/virtualMachines' --query "[?tags.Name == 'login${LOGIN_VM_IDX}'].id" -o tsv)

            # If login VM is not yet created, wait and try again
            if [ -z "${LOGIN_VM_ID}" ]; then
                echo "Login VM ${LOGIN_VM_IDX} not yet allocated. Retrying bastion scripts generation in 5 seconds..."
                sleep 5
                continue
            else
                LOGIN_VM_IDS+=(${LOGIN_VM_ID})
                break
            fi
        done
    done

    # Create scripts only if all VM resource IDs have been collected
    if [ ${#LOGIN_VM_IDS[@]} -eq ${NUMBER_OF_LOGIN_VMS} ]; then
        create_bastion_scripts 'login' ${DEPLOYMENT_OUTPUT} "${LOGIN_VM_IDS[@]}"
    else
        echo "Could not retreive all login VMs resource ID"
        exit 1
    fi
fi
