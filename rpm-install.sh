#!/bin/bash

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if required commands are available
required_commands=("sudo" "mkdir" "touch" "exec" "tee" "date" "curl" "uname" "source" "sed" "tr" "systemctl" "chmod" "rpm")
missing_commands=()

for cmd in "${required_commands[@]}"; do
  if ! command_exists "$cmd"; then
    missing_commands+=("$cmd")
  fi
done

if [ ${#missing_commands[@]} -gt 0 ]; then
  echo "Error: The following required commands are missing: ${missing_commands[*]}"
  echo "Please install them and run the script again."
  exit 1
fi


LOG_FILE="/var/log/mw-agent/rpm-installation-$(date +%s).log"
sudo mkdir -p /var/log/mw-agent
sudo touch "$LOG_FILE"

MW_TRACKING_TARGET="https://app.middleware.io"
if [ -n "$MW_API_URL_FOR_CONFIG_CHECK" ]; then
    export MW_TRACKING_TARGET="$MW_API_URL_FOR_CONFIG_CHECK"
fi

function send_logs {
  status=$1
  message=$2
  host_id=$(eval hostname)

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "linux-rpm",
    "status": "ok",
    "message": "$message",
    "host_id": "$host_id",
    "script_logs": "$(sed 's/$/\\n/' "$LOG_FILE" | tr -d '\n' | sed 's/"/\\\"/g')"
  }
}
EOF
)

  curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY \
  --header 'Content-Type: application/json' \
  --data "$payload" > /dev/null
}

function force_continue {
  read -p "Do you still want to continue? (y|N): " response
  case "$response" in
    [yY])
      echo "Continuing with the script..."
      ;;
    [nN])
      echo "Exiting script..."
      exit 1
      ;;
    *)
      echo "Invalid input. Please enter 'yes' or 'no'."
      force_continue # Recursively call the function until valid input is received.
      ;;
  esac
}

function on_exit {
  if [ $? -eq 0 ]; then
    send_logs "installed" "Script Completed"
  else
    send_logs "error" "Script Failed"
  fi
}

trap on_exit EXIT

# recording agent installation attempt
# recording agent installation attempt
send_logs "tried" "Agent Installation Attempted"

# Check if the system is running Linux
if [ "$(uname -s)" != "Linux" ]; then
  echo "This machine is not running Linux, The script is designed to run on a Linux machine."
  force_continue
fi

MW_LATEST_VERSION="1.6.6"
export MW_LATEST_VERSION

# Check if MW_VERSION is provided
if [ "${MW_VERSION}" = "" ]; then 
  MW_VERSION=$MW_LATEST_VERSION
fi
export MW_VERSION
echo -e "\nInstalling Middleware Agent version ${MW_VERSION} on hostname $(hostname) at $(date)" | sudo tee -a "$LOG_FILE"

# Check if /etc/os-release file exists
if [ -f /etc/os-release ]; then
  source /etc/os-release
  case "$ID" in
    rhel|centos|fedora|almalinux|rocky|amzn|ol|sles)
      echo "os-release ID is $ID"
      ;;
    *)
      case "$ID_LIKE" in
        rhel|centos|fedora|suse)
          echo  "os-release ID_LIKE is $ID_LIKE"
          ;;
        *)
          echo "This is not a RPM based Linux distribution."
          force_continue
          ;;
      esac
  esac
else
  echo "/etc/os-release file not found. Unable to determine the distribution."
  force_continue
fi

if [ "${MW_DETECTED_ARCH}" = "" ]; then 
  MW_DETECTED_ARCH=$(uname -m)
  echo -e "cpu architecture detected: '"${MW_DETECTED_ARCH}"'"
else 
  echo -e "cpu architecture provided: '"${MW_DETECTED_ARCH}"'"
fi
export MW_DETECTED_ARCH

RPM_FILE="mw-agent-${MW_VERSION}-1.${MW_DETECTED_ARCH}.rpm"


if [ "${MW_AGENT_HOME}" = "" ]; then 
  MW_AGENT_HOME=/opt/mw-agent
fi
export MW_AGENT_HOME

MW_AGENT_BINARY=mw-agent
if [ "${MW_AGENT_BINARY}" = "" ]; then 
  MW_AGENT_BINARY=mw-agent
fi

if [ "${MW_AUTO_START}" = "" ]; then 
  MW_AUTO_START=true
fi
export MW_AUTO_START

if [ "${MW_API_KEY}" = "" ]; then 
  echo "MW_API_KEY environment variable is required and is not set."
  force_continue
fi
export MW_API_KEY

if [ "${MW_TARGET}" = "" ]; then 
  echo "MW_TARGET environment variable is required and is not set."
  force_continue
fi
export MW_TARGET

skip_certificate_check=""
if [ "${MW_SKIP_CERTIFICATE_CHECK}" = "yes" ]; then 
  skip_certificate_check="--no-check-certificate"
fi

echo -e "\nThe host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]\n"
echo "yum.middleware.io/$MW_DETECTED_ARCH/Packages/$RPM_FILE"
curl -L -q -s -o $RPM_FILE yum.middleware.io/$MW_DETECTED_ARCH/Packages/$RPM_FILE $skip_certificate_check

echo -e "Installing Middleware Agent Service ...\n"

sudo -E rpm -U $RPM_FILE
# Check for errors
if [ $? -ne 0 ]; then
  echo "Error: Failed to install Middleware Agent."
  exit $?
fi

sudo systemctl daemon-reload

sudo systemctl enable mw-agent
#check for errors
if [ $? -ne 0 ]; then
  echo "Error: Failed to enable Middleware Agent service."
  exit $?
fi

if [ "${MW_AUTO_START}" = true ]; then
    sudo systemctl start mw-agent
fi

echo -e "Middleware Agent installation completed successfully.\n"
