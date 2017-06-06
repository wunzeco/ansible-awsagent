#!/bin/bash

#By installing the Amazon Inspector Agent, you agree that your use is
# subject to the terms of your existing AWS Customer Agreement or other
# agreement with Amazon Web Services, Inc. or its affiliates governing your
# use of AWS services. You may not install and use the
# Amazon Inspector Agent unless you have an account in good standing with AWS.

# Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
# Licensed under the terms of your existing AWS Customer Agreement
# <https://aws.amazon.com/agreement/> or other agreement with Amazon Web Services, Inc.
# or its affiliates governing your use of AWS services.
#
# Inspector Agent installer script to get the proper package installed.
# Version: 1.0.915.0

# For debugging, uncomment this line:

#set -eux

###GET_INSTALL_FUNCTIONS###
#!/bin/bash

#functions
function in_array() {
    local haystack=${1}[@]
    local needle=${2}
    for i in ${!haystack}; do
        if [[ ${i} == ${needle} ]]; then
            return 0
        fi
    done
    return 1
}

function exit_run_once {
    local pidfile=${1}
    local exitcode=${2}

    rm -f $pidfile
    exit $exitcode
}

function init_run_once {
    local pidfile=${1}
    local pid_creation_code=1
    if [[ -f $pidfile ]]; then
        local pid=$(cat $pidfile)
        ps -p $pid > /dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo "Script $0 is already running. Will retry at next cron interval."
            exit 1
        else # assume stale pidfile
            echo $$ > $pidfile
            pid_creation_code=$?
        fi
    else # There a theoretical race condition right here, but our cron does not spawn twice within a fractional second or even a minute, ever.
        echo $$ > $pidfile
        pid_creation_code=$?
    fi

    if [[ $pid_creation_code -ne 0 ]]; then
        echo "Could not create PID file: $pidfile."
        exit 1
    fi
}


function handle_status() {

    local result_param="nil"
    local result="nil"
    if [[ $# -eq 0 ]]; then
        echo "Error while handling status function. Atleast one argument should be passed."
        exit 129
    else
        if [[ $# > 1 ]]; then
            result_param=$2
        fi
        result=$1
    fi

    #if inventory url is defined then start publishing
    if [[ ! -z ${AGENT_METRICS_URL} ]]; then
        ${CURL} --head "${AGENT_METRICS_URL}&x-op=${OP}&x-result=${result}&x-result-param=${result_param}"
    else
        echo "AWS Agent Inventory URL is not yet defined."
    fi

    echo "Script exited with status code ${result} ${result_param}"

    if [[ "${result}" = "SUCCESS" ]]; then
        exit 0
    else
        exit 1
    fi
}

function download_and_verify_sig() {

    local download_url=$1
    local download_file_name=$2

    if [[ -z "${SECURE_TMP_DIR}" || ! -d "${SECURE_TMP_DIR}" ]]; then
        handle_status "SANITY_CHECK_FAILURE" "SECURE_TMP_DIR"
    fi


    if [[ -z "${SECURE_TMP_DIR}/${PUBKEY_FILE}" || ! -s "${SECURE_TMP_DIR}/${PUBKEY_FILE}" ]]; then
        handle_status "SANITY_CHECK_FAILURE" "PUBKEY_FILE"
    fi

    #get the awsagent inventory file
    ${CURL} -o "${SECURE_TMP_DIR}/${download_file_name}" "${download_url}"
    if [[ $? -ne 0 ]]; then
        echo "Failed to download the ${download_file_name} from ${download_url}"
        handle_status "FILE_DOWNLOAD_ERROR" "${download_file_name}"
    fi

    #get the awsagent inventory signature
    ${CURL} -o "${SECURE_TMP_DIR}/${download_file_name}.sig" "${download_url}.sig"
    if [[ $? -ne 0 ]]; then
        echo "Failed to download the ${download_file_name} signature from ${download_url}.sig"
        handle_status "FILE_DOWNLOAD_ERROR" "${download_file_name}.sig"
    fi

    gpg_results=$( gpg -q --no-default-keyring --keyring "${SECURE_TMP_DIR}/${PUBKEY_FILE}" --verify "${SECURE_TMP_DIR}/${download_file_name}.sig" "${SECURE_TMP_DIR}/${download_file_name}" 2>&1 )
    if [[ $? -eq 0 ]]; then
        echo "Validated ${download_file_name} signature with: $(echo "${gpg_results}" | grep -i fingerprint)"
    else
        echo "Error validating signature of ${download_file_name}, terminating.  Please contact AWS Support."
        echo ${gpg_results}
        handle_status "SIGNATURE_MISMATCH" "${download_file_name}"
    fi
}

function get_signature_timestamp() {
    local download_file_name=$1

    SIGNATURE_TIMESTAMP="$(gpg --list-packets "${SECURE_TMP_DIR}/${download_file_name}.sig" 2>/dev/null | egrep 'version .* created' | head -n 1 | sed -e 's/.* created \([0-9]\{10\}\), .*/\1/')"
}

function verify_signature_timestamp() {
    local previous_timestamp=$1
    local signature_timestamp=$2

    # SANITY CHECKS
    # date --date='@1470000000' ==> Sun Jul 31 21:20:00 UTC 2016
    # date --date='@2000000000' ==> Wed May 18 03:33:20 UTC 2033
    if [[ -z "${previous_timestamp}" || -z "${signature_timestamp}" ]]; then
        echo "Missing timestamp."
        return 2
    fi
    if [[ "${previous_timestamp}" -lt 1470000000 || "${previous_timestamp}" -gt 2000000000 ]]; then
        echo "Invalid previous timestamp."
        return 3
    fi
    if [[ "${signature_timestamp}" -lt 1470000000 || "${signature_timestamp}" -gt 2000000000 ]]; then
        echo "Invalid signature timestamp."
        return 4
    fi

    # We have two valid timestamps -- the new one should excede the old
    if [[ "${signature_timestamp}" -ge "${previous_timestamp}" ]]; then
        return 0
    else
        return 1
    fi
}

function package_install() {
    local package_path=$1
    local new_version=$2
    local existing_version=$3
    local rv=0

    if [[ -z ${package_path} || -z ${new_version} || -z ${existing_version} ]]; then
        handle_status "SANITY_CHECK_FAILURE" "PACKAGE_INSTALLATION"
    fi

    local package_name=$(basename ${package_path})

    #calculate version strings
    local new_version_str=$(printf "%06d%06d%06d%06d" $(echo ${new_version} | sed 's/\./ /g'))
    local existing_version_str=$(printf "%06d%06d%06d%06d" $(echo ${existing_version} | sed 's/\./ /g'))

    if [[ "${package_name}" =~ \.deb$ ]] && which apt-get 2>/dev/null; then
        echo "Installing with dpkg..."
        apt-get update
        dpkg --force-overwrite -i "${package_path}"
        apt-get --fix-broken -y install --no-remove
        rv="$?"
    elif [[ "${package_name}" =~ \.rpm$ ]] && which yum 2>/dev/null; then
        echo "Installing with yum..."
        if [[ ${new_version_str} == ${existing_version_str} ]]; then
            yum reinstall -y "${package_path}"
        elif [[ ${new_version_str} > ${existing_version_str} ]]; then
            yum install -y "${package_path}"
        elif [[ ${new_version_str} < ${existing_version_str} ]]; then
             yum downgrade -y "${package_path}"
        else
             handle_status "SANITY_CHECK_FAILURE" "PACKAGE_VERSION_RPM"
        fi

        #rpm -fUvh --force --oldpackage "${package_path}"
        rv="$?"
    else
        echo "No supported package managers are installed."
        handle_status "MISSING_PACKAGE_MANAGER" "${DIST_TYPE}_${package_name}"
    fi

    if [[ ${rv} -ne 0 ]]; then
        handle_status "PACKAGE_INSTALLATION_ERROR" "${package_name}"
    fi

}

function verify_hash_package() {
    local checked_package=$1
    local expected_package_hash=$2

    if [[ ! -s ${checked_package} || -z ${expected_package_hash} ]]; then
        handle_status "SANITY_CHECK_FAILURE" "HASH_VERIFICATION_ERROR"
    fi

    # Check the hash of the package downloaded vs. the hash of the package in the index
    local actual_package_hash=$( sha256sum ${checked_package} | cut -f1 -d' ')
    if [[ "${actual_package_hash}" != "${expected_package_hash}" ]]; then
        echo "Package sha256 hash does not match expected package hash from package inventory."
        handle_status "HASH_MISMATCH" "${checked_package}"
    else
        echo "Validated agent package sha256 hash matches expected value."
    fi
}


function install_kernel_module_package() {
    local km_version_detail=$1
    local new_km_version="${NEW_KM_VERSION}"
    local existing_km_version="${EXISTING_KM_VERSION}"

    if [[ -z "${new_km_version}" || -z "${km_version_detail}" || -z "${existing_km_version}" ]]; then
        echo "New Kernel module Version: ${new_km_version} Existing Kernel module version: ${existing_km_version} & Kernel Version Detail: ${km_version_detail} is invalid"
        handle_status "SANITY_CHECK_FAILURE" "INSTALL_KM_PACKAGE"
    fi

    local km_package_url=$( echo "${km_version_detail}" | cut -f5 -d'|' )
    local km_package_hash=$(echo "${km_version_detail}" | cut -f4 -d'|' )
    local km_package_name=$( echo "${km_version_detail}" | cut -f3 -d'|' )


    if [[ -z "${km_package_url}" || -z "{km_package_name}" || -z "{km_package_hash}" ]]; then
        echo "Kernel Package URL: ${km_package_url} , Kernel Package Hash: ${km_package_hash} & Kernel package name: ${km_package_name} is invalid."
        handle_status "PARSE_ERROR" "KERNEL_MODULE_PACKAGE_${UNIQ_OS_ID}"
    fi

    ${CURL} -o "${SECURE_TMP_DIR}/${km_package_name}" "${km_package_url}"
    if [[ $? -ne 0 ]]; then
        echo "Failed to download the kernel package from ${km_package_url}"
        handle_status "FILE_DOWNLOAD_ERROR" "${km_package_name}"
    fi


    # Check the hash of the package downloaded vs. the hash of the package in the index
    verify_hash_package "${SECURE_TMP_DIR}/${km_package_name}" "${km_package_hash}"
    package_install "${SECURE_TMP_DIR}/${km_package_name}" "${new_km_version}" "${existing_km_version}"

}

function install_agent_package() {

    local agent_version_detail=$1
    local km_version_detail=$2
    local new_agent_version="${NEW_AGENT_VERSION}"
    local existing_agent_version="${EXISTING_AGENT_VERSION}"
    local new_km_version="${NEW_KM_VERSION}"
    local existing_km_version="${EXISTING_KM_VERSION}"



    if [[ -z "${new_agent_version}" || -z "${existing_agent_version}" || -z "${existing_km_version}" || -z "${new_km_version}" || -z "${km_version_detail}" || -z "${agent_version_detail}" ]];then
        handle_status "SANITY_CHECK_FAILURE" "INSTALL_AGENT_PACKAGE"
    fi

    local agent_package_url=$( echo "${agent_version_detail}" | cut -f4 -d' ' )
    local expected_agent_package_hash=$( echo "${agent_version_detail}" | cut -f3 -d' ' )
    local agent_package_name=$( echo "${agent_version_detail}" | cut -f2 -d' ')

    if [[ -z "${agent_package_url}" || -z "${agent_package_name}" || -z "${expected_agent_package_hash}" ]]; then
        echo "Agent package URL: ${agent_package_url}, Agent Package Hash: ${expected_agent_package_hash} & Agent package name: ${agent_package_name} is invalid."
        handle_status "PARSE_ERROR" "AGENT_INSTALL_PACKAGE_${UNIQ_OS_ID}"
    fi

    # Download the package for the proper version.
    ${CURL} -o ${SECURE_TMP_DIR}/${agent_package_name} ${agent_package_url}
    if [[ ! -s ${SECURE_TMP_DIR}/${agent_package_name} ]]; then
        echo "Failed to download package from the path ${agent_package_url}."
        handle_status "FILE_DOWNLOAD_ERROR" "${agent_package_name}"
    fi


    # Check the hash of the package downloaded vs. the hash of the package in the index
    verify_hash_package "${SECURE_TMP_DIR}/${agent_package_name}" "${expected_agent_package_hash}"

    install_kernel_module_package "${km_version_detail}" "${new_km_version}" "${existing_km_version}"
    package_install "${SECURE_TMP_DIR}/${agent_package_name}" "${new_agent_version}" "${existing_agent_version}"

}

function lowercase(){
    echo "$1" | sed "y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/"
}

function uppercase(){
    echo "$1" | sed "y/abcdefghijklmnopqrstuvwxyz/ABCDEFGHIJKLMNOPQRSTUVWXYZ/"
}

function get_os_info () {
    OS=`lowercase \`uname\``
    KERNEL=`uname -r`
    MACH=`uname -m`
    KERNEL_GROUP=$(echo $KERNEL | cut -f1-2 -d'.')

    if [ "${OS}" = "linux" ] ; then
      # Figure out which OS we are running on
      if [ -f /etc/os-release ]; then
          source /etc/os-release
          DIST_TYPE=$ID
          DIST=$NAME
          REV=$VERSION_ID
      elif [ -f /usr/lib/os-release ]; then
          source /usr/lib/os-release
          DIST_TYPE=$ID
          DIST=$NAME
          REV=$VERSION_ID
      elif [ -f /etc/centos-release ]; then
          DIST_TYPE='CentOS'
          DIST=`cat /etc/centos-release |sed s/\ release.*//`
          REV=`cat /etc/centos-release | sed s/.*release\ // | sed s/\ .*//`
      elif [ -f /etc/redhat-release ]; then
          DIST_TYPE='RedHat'
          DIST=`cat /etc/redhat-release |sed s/\ release.*//`
          REV=`cat /etc/redhat-release | sed s/.*release\ // | sed s/\ .*//`
      elif [ -f /etc/system-release ]; then
          if grep "Amazon Linux AMI" /etc/system-release; then
            DIST_TYPE='amzn'
          fi
          DIST=`cat /etc/system-release |sed s/\ release.*//`
          REV=`cat /etc/system-release | sed s/.*release\ // | sed s/\ .*//`
      elif [ -f /etc/SuSE-release ] ; then
          DIST_TYPE='SuSe'
          REV=`cat /etc/SuSE-release | tr "\n" ' ' | sed s/.*=\ //`
      elif [ -f /etc/mandrake-release ] ; then
          DIST_TYPE='Mandrake'
          REV=`cat /etc/mandrake-release | sed s/.*release\ // | sed s/\ .*//`
      elif [ -f /etc/debian_version ] ; then
          DIST_TYPE='Debian'
          DIST=`cat /etc/lsb-release | grep '^DISTRIB_ID' | awk -F=  '{ print $2 }'`
          REV=`cat /etc/lsb-release | grep '^DISTRIB_RELEASE' | awk -F=  '{ print $2 }'`
      fi
      if [ -f /etc/UnitedLinux-release ] ; then
          DIST="${DIST}[`cat /etc/UnitedLinux-release | tr "\n" ' ' | sed s/VERSION.*//`]"
      fi
    fi

    if [ "${OS}" == "darwin" ]; then
        OS=mac
    fi


    DIST_TYPE=`lowercase $DIST_TYPE`
    UNIQ_OS_ID="${DIST_TYPE}-${KERNEL}-${MACH}"
    UNIQ_PLATFORM_ID="${DIST_TYPE}-${KERNEL_GROUP}."

    if [[ -z "${DIST}" || -z "${DIST_TYPE}" ]]; then
    echo "Unsupported distribution: ${DIST} and distribution type: ${DIST_TYPE}"
    exit 1
fi
}


function executeEnvironmentCleanup() {
    echo "Installation script completed successfully."
}

function getAgentStatus() {
    local agent_status=$( ${AGENT_EXEC} status )
    echo "Agent status completed with code:$?"
    echo "${agent_status}"
}

function restartAgent() {
    if [[ -s "${AGENT_INIT_SCRIPT}" && -x "${AGENT_INIT_SCRIPT}" ]]; then
        echo "Restarting agent."
        ${AGENT_INIT_SCRIPT} restart
        #Sleep to allow the agent to initialize fully before continuing
        sleep 35
    else
        handle_status "SANITY_CHECK_FAILURE" "AGENT_RESTART_FAILED"
    fi
}


function usage() {
    executing_script=$(basename "${BASH_SOURCE[0]}")
    echo "Usage sudo ${executing_script}< options > "
    echo "Options:"
    echo "-u [ true | false ] Automatically update Aws Agent when versions become available. Applicable only during first installation."
}

# customer may have somehow disabled agent.
# an update shouldn't override that decision
function check_awsagent_condition() {
    if [[ $(basename "${BASH_SOURCE[0]}" ) = "update" ]]; then # otherwise this is a fresh install
        ps x | grep "/opt/aws/awsagent/bin/awsagent" | grep -v grep > /dev/null
        if [[ $? -eq 1 ]]; then
            echo "awsagent not running so not updating."
            handle_status "SUCCESS" "AGENT_NOT_RUNNING_NO_UPDATE"
        fi
    fi
}

if [[ $(whoami) != "root" ]]; then
    echo "Script is run as $(whoami). Please run as root"
    exit 1
fi

PIDFILE="/var/run/awsagent_install_or_update.PID"
init_run_once $PIDFILE

#Create a Secure temp directory where we get all files and then use them.
SECURE_TMP_DIR=$(mktemp -d /tmp/awsagent.XXXXXXXX)

# Perform Cleanup upon exit
trap "EXIT_CODE=$?; rm -f ${SECURE_TMP_DIR}/*; rmdir ${SECURE_TMP_DIR}; exit_run_once $PIDFILE $EXIT_CODE" EXIT

#define constants
declare -a SUPPORTED_REGIONS=("us-east-1" "us-west-1" "us-west-2" "ap-northeast-1" "eu-west-1" "ap-northeast-2" "ap-southeast-2" "ap-south-1" "eu-central-1")
ROOTDIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd )"
AGENT_INVENTORY_FILE="AWS_AGENT_INVENTORY"
AGENT_MANIFEST_FILE="VERSION"
AGENT_CFG_KEY="agent.cfg"
PUBKEY_FILE="inspector.gpg"
CRON_UPDATE_AGENT=true
OP=install
CURL="curl -s --fail --retry 5 --max-time 30 "

#define inspector constants
AGENT_CONFIG_FILE=/opt/aws/awsagent/etc/agent.cfg
AGENT_EXEC=/opt/aws/awsagent/bin/awsagent
AGENT_KMOD=/opt/aws/awsagent/kmods/amznmon64.ko
AGENT_KMOD_DIR=/opt/aws/awsagent/kmods
AGENT_KMOD_NAME=amznmon64.ko
AGENT_INIT_SCRIPT="/etc/init.d/awsagent"
AGENT_ENV_CONFIG="/etc/init.d/awsagent.env"
INSTALL_CONFIG_FILE=/opt/aws/awsagent/etc/install.cfg

#Domain specific configuration
INSTALLER_EXT=""
BUCKET="aws-agent.us-west-2"

#check if environment environment file exists and if so source it
  if [[ -f "${AGENT_ENV_CONFIG}" ]]; then
      source "${AGENT_ENV_CONFIG}"
  fi


#check if environment override file exists and if so source it
if [[ -f "${ROOTDIRECTORY}/environmentOverride" ]]; then
    source "${ROOTDIRECTORY}/environmentOverride"
fi

#handle installer options
while getopts ":u:" opt; do
    case $opt in
        u)
            echo "Forced update specified as argument is : $OPTARG"
            if [[ $(basename "${BASH_SOURCE[0]}" ) = "install" ]]; then
                CRON_UPDATE_AGENT=$OPTARG
            fi
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            usage
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument."
            usage
            exit 1
            ;;
    esac
done

#call the os info function to get details
get_os_info

check_awsagent_condition

KERNEL_VERSION=$(uname -r )
if [[ -z "${KERNEL_VERSION}" ]]; then
    handle_status "NO_KERNEL_VERSION"
fi
KERNEL_GROUP=$(echo "${KERNEL_VERSION}" | cut -f 1-2 -d'.')
KERNEL_VERSION_WO_ARCH=$(basename ${KERNEL_VERSION} .x86_64)

echo "Distribution of the machine is ${DIST}."
echo "Distribution type of the machine is ${DIST_TYPE}."
echo "Revision of the distro is ${REV}."
echo "Kernel version of the machine is ${KERNEL_VERSION}."

#gather all meta data information
#METADATA_AZ=$( ${CURL} http://169.254.169.254/latest/meta-data/placement/availability-zone)
#METADATA_INSTANCE_TYPE=$( ${CURL} http://169.254.169.254/latest/meta-data/instance-type)
METADATA_AZ=eu-west-1a
METADATA_INSTANCE_TYPE=t2.small
METADATA_REGION=$( echo $METADATA_AZ | sed -e 's/[a-z]*$//' )

if [[ -n "${METADATA_REGION}" ]]; then
    REGION=${METADATA_REGION}
else
    echo "No region information was obtained."
    handle_status "NO_REGION_INFO"
fi

#check if the obtained region is supported by inspector
if in_array SUPPORTED_REGIONS "${REGION}"; then
    echo "$(hostname -f) is an EC2 instance reporting region as ${REGION}."
else
    echo "Aws Agent is only supported in ${SUPPORTED_REGIONS[@]}"
    handle_status "UNSUPPORTED_REGION" ${REGION}
fi

#Base url formation
if [[ -z "${INSTALLER_EXT}" ]]; then
    BUCKET="aws-agent.${REGION}"
fi

BASE_URL="https://s3.dualstack.${REGION}.amazonaws.com/${BUCKET}"

#check existing agent status to get the version information of the running agent
if [[ "${DIST_TYPE}" = "ubuntu" ]]; then
    EXISTING_AGENT_VERSION=$(dpkg-query -W -f='${VERSION}' "awsagent" | cut -f1 -d'-')
    rv=${PIPESTATUS[0]}
else
    EXISTING_AGENT_VERSION=$(rpm -qa "AwsAgent" --queryformat '%{VERSION}')
    rv=$?
fi
echo "Check for existing AwsAgent completed with error code:${rv}"
if [[ -z "${EXISTING_AGENT_VERSION}" ]]; then
    EXISTING_AGENT_VERSION="0.0.0.0"
fi

echo "Existing version of agent installed is ${EXISTING_AGENT_VERSION}."

#get existing kernel module version based on kernel version in machine
if [[ "${DIST_TYPE}" = "ubuntu" ]]; then
    EXISTING_KM_VERSION=$(dpkg-query -W -f='${VERSION}' "awsagentkernelmodule-${KERNEL_VERSION_WO_ARCH}" | cut -f1 -d'-')
    rv=${PIPESTATUS[0]}
else
    EXISTING_KM_VERSION=$(rpm -qa "AwsAgentKernelModule__${DIST_TYPE}__${KERNEL_VERSION_WO_ARCH}" --queryformat '%{VERSION}')
    rv=$?
fi
echo "Check for existing AwsAgentKernelModule completed with error code:${rv}"

if [[ -z "${EXISTING_KM_VERSION}" ]]; then
    EXISTING_KM_VERSION="0.0.0.0"
fi

echo "Existing version of kernel module installed is ${EXISTING_KM_VERSION}."

#Agent and Kernel Param
AGENT_ID_PARAM="x-installer-version=1.0.915.0&x-existing-version=${EXISTING_AGENT_VERSION}&x-uniq-os-id=${UNIQ_OS_ID}&x-instance-type=${METADATA_INSTANCE_TYPE}"
KERNEL_ID_PARAM="x-existing-km-version=${EXISTING_KM_VERSION}"
AGENT_INVENTORY_URL="${BASE_URL}/linux/latest/${AGENT_INVENTORY_FILE}"
AGENT_METRICS_URL="${AGENT_INVENTORY_URL}?${AGENT_ID_PARAM}&${KERNEL_ID_PARAM}"

if [[  -n "${BASH_SOURCE[0]}"  &&  $(basename "${BASH_SOURCE[0]}" ) = "update"  ]]; then
    OP=update
    if [[ ! -f "${AGENT_EXEC}" ]]; then
        echo "Attempting update, but binary does not exist. Please run 'install' instead."
        handle_status "WRONG_EXEC_MODE" "update"
    fi

    if [[ -s "${INSTALL_CONFIG_FILE}" ]]; then
        echo "Detected running as updater script, loading saved configuration from ${INSTALL_CONFIG_FILE}..."
        source ${INSTALL_CONFIG_FILE}
    fi

    COLLECT="$( getAgentStatus | grep -Ei "Collecting\s*:" | sed -re 's/Collecting\s*:\s*//i' )"

    if [[ "${COLLECT}" = "true" ]]; then
        echo "Agent is actively colecting at this time, cannot update agent while it is collecting data!"
        handle_status "AGENT_RUNNING_ASSESSMENT"
    elif [[ "${CRON_UPDATE_AGENT}" = "false" ]]; then
        echo "Update is not permitted according to configuration parameter mentioned as argument."
        restartAgent
        handle_status "CRON_UPDATE_AGENT_DISABLED"
    else
        echo "Agent is inactive, continuing to update..."
    fi
fi

# Check that the dir exists and is owned by our euid (root)
if [[ ! -O "${SECURE_TMP_DIR}" ]]; then
    echo "Unable to create secure temporary directory ${SECURE_TMP_DIR}."
    handle_status "TMP_DIR_ERROR"
fi
chmod 700 "${SECURE_TMP_DIR}"

#get the public key
${CURL} -o "${SECURE_TMP_DIR}/${PUBKEY_FILE}" "${BASE_URL}/linux/latest/${PUBKEY_FILE}"
if [[ $? != 0 ]]; then
    echo "Failed to download public key from the path ${BASE_URL}/linux/latest/${PUBKEY_FILE}"
    handle_status "FILE_DOWNLOAD_ERROR" "${PUBKEY_FILE}"
fi

#get the awsagent inventory file
download_and_verify_sig "${AGENT_INVENTORY_URL}" "${AGENT_INVENTORY_FILE}"

#send start agent census metric
${CURL} --head "${AGENT_METRICS_URL}&x-op=${OP}&x-result=begin"

AGENT_MANIFEST_URL="$(grep "${AGENT_MANIFEST_FILE}" "${SECURE_TMP_DIR}/${AGENT_INVENTORY_FILE}" | grep -v "${AGENT_MANIFEST_FILE}.sig" | cut -f2 -d' ')"
if [[ -z "${AGENT_MANIFEST_URL}" ]]; then
    echo "Agent manifest file URL was not obtained. Please contact AWS aupport."
    handle_status "PARSE_ERROR" "${AGENT_MANIFEST_FILE}"
fi

download_and_verify_sig "${AGENT_MANIFEST_URL}" "${AGENT_MANIFEST_FILE}"

AGENT_VERSION_DETAIL=$( grep -m 1 -i "${UNIQ_PLATFORM_ID}" "${SECURE_TMP_DIR}/${AGENT_MANIFEST_FILE}" )
if [[ -z "${AGENT_VERSION_DETAIL}" ]]; then
    echo "Failed to find an inspector agent package for this OS:${UNIQ_PLATFORM_ID}."
    handle_status "MISSING_AGENT_PLATFORM" "${UNIQ_PLATFORM_ID}"
fi

NEW_AGENT_VERSION=$(echo "${AGENT_VERSION_DETAIL}" | cut -f7 -d'/')
if [[ -z "${NEW_AGENT_VERSION}" ]]; then
    handle_status "SANITY_CHECK_FAILURE" "NEW_AGENT_VERSION"
fi

KERNEL_MANIFEST_VERSION="$(grep "km_version" "${SECURE_TMP_DIR}/${AGENT_INVENTORY_FILE}" | cut -f2 -d' ')"
if [[ -z "${KERNEL_MANIFEST_VERSION}" ]]; then
    echo "Kernel manifest version number was not obtained. Please contact AWS aupport."
    handle_status "PARSE_ERROR" "KERNEL_MANIFEST_VERSION"
fi

DIST_TYPE_UPPERCASE=`uppercase "${DIST_TYPE}"`
KERNEL_MANIFEST_VERSION_3DIGITS=$(echo "${KERNEL_MANIFEST_VERSION}" | cut -f 1-3 -d".")
KERNEL_MANIFEST_FILE_NAME="KM_MANIFEST_${DIST_TYPE_UPPERCASE}_${KERNEL_GROUP}_${KERNEL_MANIFEST_VERSION_3DIGITS}.txt"
KERNEL_MANIFEST_URL="${BASE_URL}/kernel-modules/${KERNEL_MANIFEST_FILE_NAME}"

download_and_verify_sig "${KERNEL_MANIFEST_URL}" "${KERNEL_MANIFEST_FILE_NAME}"

KERNEL_MODULE_VERSION_DETAIL=$( grep -i "${KERNEL_VERSION_WO_ARCH}" "${SECURE_TMP_DIR}/${KERNEL_MANIFEST_FILE_NAME}" | tail -n -1 )
if [[ -z "${KERNEL_MODULE_VERSION_DETAIL}" ]]; then
    echo "Failed to find an inspector kernel module package for this OS: ${UNIQ_OS_ID}."
    handle_status "MISSING_KERNEL_VERSION" "${UNIQ_OS_ID}"
fi

NEW_KM_VERSION=$( echo "${KERNEL_MODULE_VERSION_DETAIL}" | cut -f2 -d'|' )
if [[ -z "${NEW_KM_VERSION}" ]]; then
    handle_status "PARSE_ERROR" "NEW_KM_VERSION"
fi

if [[ "${EXISTING_AGENT_VERSION}" != "${NEW_AGENT_VERSION}" ]]; then #check if agent version is latest, if so install agent and kernel module

    install_agent_package "${AGENT_VERSION_DETAIL}" "${KERNEL_MODULE_VERSION_DETAIL}"

    umask 077
    # Save the config so we can update with the same parameters

    [[ -f ${INSTALL_CONFIG_FILE} ]] && mv -f ${INSTALL_CONFIG_FILE} ${INSTALL_CONFIG_FILE}.old
    echo "AGENT_CFG_KEY=${AGENT_CFG_KEY}" >> ${INSTALL_CONFIG_FILE}
    echo "CRON_UPDATE_AGENT=${CRON_UPDATE_AGENT}" >> ${INSTALL_CONFIG_FILE}
elif [[ "${EXISTING_KM_VERSION}" != "${NEW_KM_VERSION}" ]]; then  #check if kernel module is latest if agent is latest
    install_kernel_module_package "${KERNEL_MODULE_VERSION_DETAIL}"
elif [[ "${OP}" = "update" ]]; then
    # Verify that it's still the case that no assessment is running.
    COLLECT="$( getAgentStatus | grep -Ei "Collecting\s*:" | sed -re 's/Collecting\s*:\s*//i' )"
    if [[ "${COLLECT}" != "true" ]]; then
        restartAgent
    fi
fi

AGENT_KMOD_KERNEL_SPECIFIC="${AGENT_KMOD_DIR}/${NEW_KM_VERSION}/${AGENT_KMOD_NAME}.${KERNEL_VERSION}"
if [[ -f "${AGENT_KMOD_KERNEL_SPECIFIC}" ]]; then
    cp -f "${AGENT_KMOD_KERNEL_SPECIFIC}" "${AGENT_KMOD}"
else
    echo "No supported kernel module is available in this installation package for ${UNIQ_OS_ID}, please contact Amazon Web Services."
    handle_status "MISSING_KM_FILE" "${NEW_KM_VERSION}__${UNIQ_OS_ID}"
fi

if [[ ! -f ${AGENT_CONFIG_FILE} && -f ${AGENT_CONFIG_FILE}.orig ]]; then
    cp ${AGENT_CONFIG_FILE}.orig ${AGENT_CONFIG_FILE}
fi

RUNNING_VERSION=$( getAgentStatus | grep -Ei "Agent\s*version" | sed -re 's/Agent\s*version\s*:\s*//i' )
ARSENAL_ENDPOINT=$( getAgentStatus | grep -Ei "Endpoint" | sed -re 's/Endpoint\s*:\s*//i' )

#send installer end metric
${CURL} --head "${AGENT_METRICS_URL}&x-op=${OP}&x-result=SUCCESS&x-running-agent-version=${RUNNING_VERSION}"

executeEnvironmentCleanup

echo
echo "Notice:"
echo "By installing the Amazon Inspector Agent, you agree that your use is subject to the terms of your existing "
echo "AWS Customer Agreement or other agreement with Amazon Web Services, Inc. or its affiliates governing your "
echo "use of AWS services. You may not install and use the Amazon Inspector Agent unless you have an account in "
echo "good standing with AWS."
echo "*  *  *"
echo "Current running agent reports to arsenal endpoint: $ARSENAL_ENDPOINT"
echo "Current running agent reports version as: $RUNNING_VERSION"
echo "This install script was created to install agent version:1.0.915.0"
echo "In most cases, these version numbers should be the same."



