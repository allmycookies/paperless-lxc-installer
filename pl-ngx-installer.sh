#!/bin/bash

# ==============================================================================
# Paperless-ngx Installer & Manager (Intelligent & Interactive) for Debian 12 - V26
#
# - Performs an interactive initial installation with sane defaults.
# - Checks Ghostscript version and only compiles from source if necessary.
# - Detects an existing installation and provides a full management menu.
# - Manages services (status, start, stop, autostart).
# - Provides options for updates, reinstallation, and uninstallation.
# - Provides an option to reset the user password.
#
# (c) 2025 Denys Safra / Github:allmycookies
# ==============================================================================

set -e # Stops the script immediately if a command fails

# --- Global Variables ---
SERVICES=(
    "paperless-webserver.service"
    "paperless-consumer.service"
    "paperless-scheduler.service"
    "paperless-task-queue.service"
)

# ==============================================================================
# --- FUNCTION DEFINITIONS ---
# ==============================================================================

# Function to clean up an existing installation
cleanup() {
    echo " Starting cleanup of the Paperless installation..."
    sudo systemctl stop "${SERVICES[@]}" &>/dev/null || true
    sudo systemctl disable "${SERVICES[@]}" &>/dev/null || true
    sudo rm -f /etc/systemd/system/paperless-*.service
    sudo systemctl daemon-reload

    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$PAPERLESS_DB_NAME"; then
        sudo -u postgres sh -c "cd /tmp && psql -c 'DROP DATABASE ${PAPERLESS_DB_NAME};'"
    fi
    if sudo -u postgres psql -t -c '\du' | cut -d \| -f 1 | grep -qw "$PAPERLESS_USER"; then
        sudo -u postgres sh -c "cd /tmp && psql -c 'DROP USER ${PAPERLESS_USER};'"
    fi

    if id "$PAPERLESS_USER" &>/dev/null; then
        sudo deluser --remove-home "$PAPERLESS_USER"
    elif [ -d "$PAPERLESS_HOME" ]; then
        echo " Warning: User ${PAPERLESS_USER} not found, but directory ${PAPERLESS_HOME} exists. It will be deleted."
        sudo rm -rf "$PAPERLESS_HOME"
    fi
    
    rm -f .install_state
    echo "✅ Cleanup complete."
}

# Function to manually compile and install Ghostscript
ghostscript_update() {
    readonly GS_VERSION="10.04.0" # A stable, bug-free version
    
    CURRENT_GS_VERSION=$(gs --version 2>/dev/null || echo "0")
    
    if dpkg --compare-versions "$CURRENT_GS_VERSION" "ge" "$GS_VERSION"; then
        echo "✅ Ghostscript version ${CURRENT_GS_VERSION} is already sufficient. Skipping manual compilation."
        return 0
    else
        echo "Ghostscript version ${CURRENT_GS_VERSION} is outdated or not found. Starting manual update to ${GS_VERSION}..."
    fi

    readonly GS_DOWNLOAD_URL="https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs${GS_VERSION//./}/ghostscript-${GS_VERSION}.tar.gz"
    readonly GS_ARCHIVE_NAME="ghostscript-${GS_VERSION}.tar.gz"
    readonly GS_SOURCE_DIR="ghostscript-${GS_VERSION}"

    echo "--- Manual Ghostscript Update ---"
    
    echo "Step 1: Installing necessary build dependencies..."
    apt-get install -y build-essential wget libgs-dev
    echo "✅ Dependencies installed."

    echo "Step 2: Downloading Ghostscript v${GS_VERSION}..."
    cd /tmp
    wget -q --show-progress "$GS_DOWNLOAD_URL"
    echo "✅ Download complete."

    echo "Step 3: Extracting source code..."
    rm -rf "$GS_SOURCE_DIR"
    tar -xzf "$GS_ARCHIVE_NAME"
    echo "✅ Extraction complete."

    cd "$GS_SOURCE_DIR"
    echo "Step 4: Configuring the build (this may take a moment)..."
    ./configure
    
    echo "Step 5: Compiling the source code (this will take several minutes)..."
    make
    
    echo "Step 6: Installing the new version..."
    make install
    echo "✅ Installation complete."

    echo "Step 7: Updating shared library cache..."
    ldconfig
    echo "✅ Library cache updated."

    echo "Step 8: Cleaning up temporary files..."
    # CORRECTED: Clean up from the /tmp directory directly, as the source folder might be gone
    cd /tmp
    rm -rf "$GS_SOURCE_DIR" "$GS_ARCHIVE_NAME"
    echo "✅ Cleanup complete."
    echo "--- Ghostscript update successful ---"
}

# Function for the installation process
installation() {
    # 1. System Preparation
    echo " Performing system updates and installing base packages..."
    apt-get update
    apt-get upgrade -y
    apt-get install -y sudo curl wget gnupg locales # Add locales package
    echo "✅ System preparation complete."

    # 1.5 Generate locale for PostgreSQL
    echo " Generating en_US.UTF-8 locale for database..."
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    locale-gen
    echo "✅ Locale generated."

    # 2. Install Dependencies
    echo " Installing all required dependencies for Paperless-ngx..."
    apt-get install -y \
        python3 python3-pip python3-dev python3-venv imagemagick fonts-liberation \
        gnupg libpq-dev default-libmysqlclient-dev pkg-config libmagic-dev \
        libzbar0 poppler-utils tesseract-ocr
    
    TESSERACT_LANG_PACKAGES=$(echo "tesseract-ocr-${OCR_LANGUAGES}" | sed 's/+/ tesseract-ocr-/g')
    apt-get install -y \
        unpaper ghostscript icc-profiles-free qpdf liblept5 libxml2 \
        pngquant zlib1g ${TESSERACT_LANG_PACKAGES}

    apt-get install -y \
        build-essential python3-setuptools python3-wheel
    echo "✅ All dependencies installed."
    
    # 2.5 Manual Ghostscript update to fix the Debian bug
    ghostscript_update

    # 3. Install Database and Cache
    echo " Installing and configuring PostgreSQL and Redis..."
    apt-get install -y redis-server
    systemctl enable --now redis-server
    apt-get install -y postgresql
    systemctl enable --now postgresql

    sudo -u postgres psql -c "CREATE USER ${PAPERLESS_USER} WITH PASSWORD '${PAPERLESS_PW}';"
    sudo -u postgres psql -c "CREATE DATABASE ${PAPERLESS_DB_NAME} OWNER ${PAPERLESS_USER} ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;"
    echo "✅ PostgreSQL and Redis configured."

    # 4. Create Paperless User and Directories
    echo " Creating system user and directory structure for Paperless..."
    adduser "${PAPERLESS_USER}" --system --home "${PAPERLESS_HOME}" --group
    mkdir -p "${PAPERLESS_HOME}/consume" "${PAPERLESS_HOME}/media" "${PAPERLESS_HOME}/data"
    echo "✅ User and directories created."

    # 5. Download and Extract Paperless-ngx
    echo " Downloading Paperless-ngx v${PAPERLESS_VERSION}..."
    cd /tmp
    wget -q --show-progress "https://github.com/paperless-ngx/paperless-ngx/releases/download/v${PAPERLESS_VERSION}/paperless-ngx-v${PAPERLESS_VERSION}.tar.xz"
    tar -xf "paperless-ngx-v${PAPERLESS_VERSION}.tar.xz" -C "${PAPERLESS_HOME}" --strip-components=1
    rm "paperless-ngx-v${PAPERLESS_VERSION}.tar.xz"
    cd - > /dev/null
    echo "✅ Paperless-ngx downloaded and extracted."

    # 6. Configure Paperless-ngx
    echo " Creating the paperless.conf configuration file..."
    SECRET_KEY=$(openssl rand -base64 48)

    TESS_VERSION_DIR=$(tesseract --version | head -n 1 | grep -oP 'tesseract \K[0-9]+' || echo "5")
    TESSDATA_PREFIX="/usr/share/tesseract-ocr/${TESS_VERSION_DIR}/"
    echo "Tesseract data directory auto-detected: ${TESSDATA_PREFIX}"

    DATE_PARSER_LANGS=$(echo "${OCR_LANGUAGES}" | sed "s/deu/'de'/g; s/eng/'en'/g; s/fra/'fr'/g; s/ita/'it'/g; s/spa/'es'/g; s/rus/'ru'/g; s/jpn/'ja'/g" | sed 's/+/ /g' | sed 's/ /, /g')

    tee "${PAPERLESS_HOME}/paperless.conf" > /dev/null <<EOF
PAPERLESS_SECRET_KEY='${SECRET_KEY}'
PAPERLESS_REDIS='redis://localhost:6379'
PAPERLESS_DBENGINE=postgresql
PAPERLESS_DBHOST=localhost
PAPERLESS_DBNAME=${PAPERLESS_DB_NAME}
PAPERLESS_DBUSER=${PAPERLESS_USER}
PAPERLESS_DBPASS='${PAPERLESS_PW}'
PAPERLESS_CONSUMPTION_DIR=${PAPERLESS_HOME}/consume
PAPERLESS_DATA_DIR=${PAPERLESS_HOME}/data
PAPERLESS_MEDIA_ROOT=${PAPERLESS_HOME}/media
PAPERLESS_OCR_LANGUAGE=${OCR_LANGUAGES//+/ }
PAPERLESS_TIME_ZONE=${TIMEZONE}
PAPERLESS_URL=http://$(hostname -I | awk '{print $1}')
PAPERLESS_TESSDATA_PREFIX=${TESSDATA_PREFIX}
PAPERLESS_WEBSERVER_HOST=0.0.0.0
PAPERLESS_WEBSERVER_PORT=8000
PAPERLESS_DATE_PARSER_LANGUAGES=${DATE_PARSER_LANGS}
EOF
    echo "✅ Configuration file created."

    # 7. Set Permissions, Create venv, and Install Python Packages
    echo " Setting permissions, creating venv, and installing Python dependencies..."
    chown -R "${PAPERLESS_USER}":"${PAPERLESS_USER}" "${PAPERLESS_HOME}"
    sudo -u "${PAPERLESS_USER}" -H python3 -m venv "${PAPERLESS_HOME}/venv"
    
    sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/pip" install -r "${PAPERLESS_HOME}/requirements.txt"
    sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/pip" install psycopg2-binary
    
    echo "✅ Python packages installed in venv."

    # 8. Database Setup and Superuser Creation
    echo " Performing database migration and creating the admin user..."
    cd "${PAPERLESS_HOME}/src"
    sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/python3" manage.py migrate --skip-checks
    export DJANGO_SUPERUSER_PASSWORD="${PAPERLESS_PW}"
    sudo -E -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/python3" manage.py createsuperuser \
        --username "${PAPERLESS_USER}" \
        --email "admin@localhost" \
        --no-input \
        --skip-checks
    unset DJANGO_SUPERUSER_PASSWORD
    cd - > /dev/null
    echo "✅ Database initialized and admin user created."

    # 9. Setup Systemd Services
    echo " Setting up Systemd services for automatic startup..."
    cp "${PAPERLESS_HOME}/scripts/paperless-"*.service /etc/systemd/system/
    EXEC_PREFIX="${PAPERLESS_HOME}/venv/bin/"
    
    sed -i "s|/opt/paperless|${PAPERLESS_HOME}|g" /etc/systemd/system/paperless-*.service
    sed -i "s|User=paperless|User=${PAPERLESS_USER}|g" /etc/systemd/system/paperless-*.service
    sed -i "s|Group=paperless|Group=${PAPERLESS_USER}|g" /etc/systemd/system/paperless-*.service
    sed -i "s|exec granian|exec ${EXEC_PREFIX}granian|g" /etc/systemd/system/paperless-webserver.service
    sed -i "s|^ExecStart=python3 manage.py document_consumer|ExecStart=${EXEC_PREFIX}python3 manage.py document_consumer --skip-checks|g" /etc/systemd/system/paperless-consumer.service
    sed -i "s|^ExecStart=celery|ExecStart=${EXEC_PREFIX}celery|g" /etc/systemd/system/paperless-task-queue.service
    sed -i "s|^ExecStart=celery|ExecStart=${EXEC_PREFIX}celery|g" /etc/systemd/system/paperless-scheduler.service

    systemctl daemon-reload
    systemctl enable --now "${SERVICES[@]}"
    echo "✅ Systemd services are active and started."

    # 10. Final Adjustments
    echo " Configuring ImageMagick policy..."
    sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml
    echo "✅ ImageMagick policy adjusted."

    # --- Completion ---
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    echo -e "\n\n🎉 The installation of Paperless-ngx was successful! 🎉"
    echo "------------------------------------------------------------------"
    echo "You can now access Paperless-ngx at the following address:"
    echo -e "\n    \033[1mhttp://${IP_ADDRESS}:8000\033[0m\n"
    echo "Your login credentials are:"
    echo -e "  » Username: \033[1m${PAPERLESS_USER}\033[0m"
    echo -e "  » Password: \033[1m${PAPERLESS_PW}\033[0m"
    echo ""
    echo "The 'consume' folder, where you can place documents, is located here:"
    echo "  » ${PAPERLESS_HOME}/consume"
    echo "------------------------------------------------------------------"
}

# Function to reset the password
reset_password() {
    echo "Setting a new password for user '${PAPERLESS_USER}'."
    read -s -p "Please enter the new password: " NEW_PASSWORD
    echo
    read -s -p "Please confirm the new password: " CONFIRM_PASSWORD
    echo

    if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then
        echo "The passwords do not match. Aborting."
        exit 1
    fi
    
    if [ -z "$NEW_PASSWORD" ]; then
        echo "The password cannot be empty. Aborting."
        exit 1
    fi

    cd "${PAPERLESS_HOME}/src"
    echo -e "$NEW_PASSWORD\n$NEW_PASSWORD" | sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/python3" manage.py changepassword "${PAPERLESS_USER}"
    cd - > /dev/null
    
    echo "✅ Password for '${PAPERLESS_USER}' has been successfully reset."
}

# --- Service Management Functions ---
check_status() {
    echo "Status of Paperless services:"
    sudo systemctl status "${SERVICES[@]}"
}
start_services() {
    echo "Starting Paperless services..."
    sudo systemctl start "${SERVICES[@]}"
    echo "✅ Services started."
}
stop_services() {
    echo "Stopping Paperless services..."
    sudo systemctl stop "${SERVICES[@]}"
    echo "✅ Services stopped."
}
enable_autostart() {
    echo "Enabling autostart for Paperless services..."
    sudo systemctl enable "${SERVICES[@]}"
    echo "✅ Autostart enabled."
}
disable_autostart() {
    echo "Disabling autostart for Paperless services..."
    sudo systemctl disable "${SERVICES[@]}"
    echo "✅ Autostart disabled."
}

# --- Update Function ---
update_paperless() {
    echo "Starting Paperless-ngx Update Process."
    
    read -p "Please enter the new version number (e.g., 2.19.0) [Current: ${PAPERLESS_VERSION}]: " NEW_VERSION
    if [ -z "$NEW_VERSION" ]; then
        echo "No version entered. Aborting."
        exit 1
    fi
    
    echo "------------------------------------------------------------------"
    echo "WARNING: It is strongly recommended to create a backup or"
    echo "a snapshot of your system before updating!"
    echo "------------------------------------------------------------------"
    read -p "Have you created a backup and wish to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborting."
        exit 0
    fi

    echo "Step 1: Updating system packages (PostgreSQL, Redis)..."
    sudo apt-get update
    sudo apt-get install --only-upgrade -y postgresql* redis-server*
    echo "✅ System packages updated."
    
    echo "Step 2: Stopping Paperless services..."
    stop_services

    echo "Step 3: Downloading new Paperless version ${NEW_VERSION}..."
    cd /tmp
    wget -q --show-progress "https://github.com/paperless-ngx/paperless-ngx/releases/download/v${NEW_VERSION}/paperless-ngx-v${NEW_VERSION}.tar.xz"
    
    echo "Step 4: Extracting new version..."
    tar -xf "paperless-ngx-v${NEW_VERSION}.tar.xz" -C "${PAPERLESS_HOME}" --strip-components=1
    rm "paperless-ngx-v${NEW_VERSION}.tar.xz"
    cd - > /dev/null
    echo "✅ New version extracted."

    echo "Step 5: Updating Python dependencies..."
    sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/pip" install -r "${PAPERLESS_HOME}/requirements.txt"
    sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/pip" install psycopg2-binary
    echo "✅ Python dependencies updated."

    echo "Step 6: Performing database migration..."
    cd "${PAPERLESS_HOME}/src"
    sudo -u "${PAPERLESS_USER}" -H "${PAPERLESS_HOME}/venv/bin/python3" manage.py migrate --skip-checks
    cd - > /dev/null
    echo "✅ Database migration complete."

    echo "Step 7: Setting permissions..."
    sudo chown -R "${PAPERLESS_USER}":"${PAPERLESS_USER}" "${PAPERLESS_HOME}"
    echo "✅ Permissions set."

    sed -i "s/PAPERLESS_VERSION='${PAPERLESS_VERSION}'/PAPERLESS_VERSION='${NEW_VERSION}'/g" "$STATE_FILE"

    echo "Step 8: Starting Paperless services..."
    start_services

    echo -e "\n\n🎉 Paperless-ngx has been successfully updated to version ${NEW_VERSION}! 🎉"
}

# ==============================================================================
# --- MAIN LOGIC ---
# ==============================================================================

# Check if the script is being run as root
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root." >&2
   exit 1
fi

STATE_FILE=".install_state"

# Check if a state file exists
if [ -f "$STATE_FILE" ]; then
    echo "An existing Paperless installation has been detected."
    source "$STATE_FILE"
    
    echo
    echo "================ PAPERLESS-NGX MANAGER ================"
    echo "Installation detected for user '${PAPERLESS_USER}' in '${PAPERLESS_HOME}' (Version: ${PAPERLESS_VERSION})"
    echo
    echo "What would you like to do?"
    echo "--- Service Management ---"
    echo "  1) Check service status"
    echo "  2) Start services"
    echo "  3) Stop services"
    echo "  4) Enable autostart"
    echo "  5) Disable autostart"
    echo "--- Installation & Maintenance ---"
    echo "  6) Reset password for '${PAPERLESS_USER}'"
    echo "  7) Update Paperless-ngx & System"
    echo "  8) Clean up and reinstall (REINSTALL)"
    echo "  9) Completely uninstall Paperless-ngx (DELETES EVERYTHING)"
    echo "  10) Abort"
    read -p "Please choose an option [1-10]: " choice
    
    case "$choice" in
        1) check_status ;;
        2) start_services ;;
        3) stop_services ;;
        4) enable_autostart ;;
        5) disable_autostart ;;
        6) reset_password ;;
        7) update_paperless ;;
        8)
            echo "Option 8 chosen: Clean up and reinstall."
            cleanup
            echo "System has been cleaned up. Please run the script again for a fresh installation."
            ;;
        9)
            echo "Option 9 chosen: Complete uninstallation."
            read -p "WARNING: This will permanently delete all Paperless data. Are you sure? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                cleanup
                echo "Paperless-ngx has been completely removed."
            else
                echo "Aborting."
            fi
            ;;
        10)
            echo "Aborting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Aborting."
            exit 1
            ;;
    esac
else
    # No state file found -> first-time installation
    echo "Welcome to the Paperless-ngx Installer."
    echo "Please enter the configuration details for the initial installation."
    echo "Press Enter to use the default values in [brackets]."
    echo ""

    read -p "Paperless username [paperlessngx]: " PAPERLESS_USER_INPUT
    PAPERLESS_USER=${PAPERLESS_USER_INPUT:-paperlessngx}

    read -p "Paperless password (also used for the DB) [NgxPower2020]: " PAPERLESS_PW_INPUT
    PAPERLESS_PW=${PAPERLESS_PW_INPUT:-NgxPower2020}

    read -p "Database name [paperlessngx]: " PAPERLESS_DB_NAME_INPUT
    PAPERLESS_DB_NAME=${PAPERLESS_DB_NAME_INPUT:-paperlessngx}

    read -p "Installation directory [/opt/paperlessngx]: " PAPERLESS_HOME_INPUT
    PAPERLESS_HOME=${PAPERLESS_HOME_INPUT:-/opt/paperlessngx}

    read -p "Paperless version [2.18.1]: " PAPERLESS_VERSION_INPUT
    PAPERLESS_VERSION=${PAPERLESS_VERSION_INPUT:-2.18.1}

    # Timezone selection menu
    echo "Please choose your time zone:"
    timezones=(
        "Europe/Berlin"
        "Europe/London"
        "America/New_York"
        "America/Los_Angeles"
        "Asia/Tokyo"
        "Australia/Sydney"
        "UTC"
    )
    select tz_option in "${timezones[@]}" "Other"; do
        if [[ "$REPLY" -gt 0 && "$REPLY" -le ${#timezones[@]} ]]; then
            TIMEZONE=${timezones[$REPLY-1]}
            break
        elif [ "$tz_option" == "Other" ]; then
            read -p "Please enter your time zone (e.g., Europe/Moscow): " TIMEZONE
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done

    echo "Please specify the OCR languages (3-letter codes, separated by '+')."
    echo "TIP: For German and English, enter 'deu+eng'. For only English, enter 'eng'."
    echo "A full list is available here: https://tesseract-ocr.github.io/tessdoc/Data-Files-in-v4.0.0.html"
    read -p "OCR languages [deu]: " OCR_LANGUAGES_INPUT
    OCR_LANGUAGES=${OCR_LANGUAGES_INPUT:-deu}
    
    # Save the most important variables to the state file
    {
        echo "PAPERLESS_USER='${PAPERLESS_USER}'"
        echo "PAPERLESS_DB_NAME='${PAPERLESS_DB_NAME}'"
        echo "PAPERLESS_HOME='${PAPERLESS_HOME}'"
        echo "PAPERLESS_VERSION='${PAPERLESS_VERSION}'" # Version is now also saved
    } > "$STATE_FILE"
    
    echo ""
    echo "Configuration complete. The installation will start with the following values:"
    echo "--------------------------------------------------"
    echo "User:          ${PAPERLESS_USER}"
    echo "Password:      ${PAPERLESS_PW}"
    echo "Database:      ${PAPERLESS_DB_NAME}"
    echo "Directory:     ${PAPERLESS_HOME}"
    echo "Version:       ${PAPERLESS_VERSION}"
    echo "Port:          8000"
    echo "Time zone:     ${TIMEZONE}"
    echo "Languages:     ${OCR_LANGUAGES}"
    echo "--------------------------------------------------"
    read -p "Press Enter to continue, or Ctrl+C to abort."

    installation
fi
