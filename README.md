# Paperless-ngx Installer & Manager for Proxmox LXC
![Paperless-ngx UI](https://github.com/paperless-ngx/paperless-ngx/raw/main/resources/logo/web/png/Black%20logo%20-%20no%20background.png)
This script provides a comprehensive, interactive, and robust solution for installing and managing a "Bare Metal" Paperless-ngx instance on a Debian 12 LXC container.

## Features

This script is a "one-stop-shop" designed to make the Paperless-ngx setup as simple and reliable as possible, especially within a Proxmox LXC environment. It handles the entire lifecycle of your instance.

  * **Guided Installation:** Interactive prompts for user, password, languages, and time zone.
  * **Automated Dependency Management:** Installs and configures all required packages for Paperless, OCRmyPDF, and PostgreSQL.
  * **Built-in Troubleshooting:** Automatically fixes common Debian 12 issues:
      * Compiles a modern **Ghostscript** version to prevent PDF processing errors.
      * Generates required **system locales** for proper UTF-8 database creation.
      * Applies workarounds for Paperless-ngx's internal system checks.
  * **Full Configuration:** Sets up the database, system user, directory structure, and `paperless.conf`.
  * **Systemd Integration:** Creates and enables `systemd` services for automatic startup on boot.
  * **Post-Install Management:** After installation, the script becomes a powerful management tool with a menu to:
      * Check, start, or stop services.
      * Update the Paperless-ngx application.
      * Reset the admin user's password.
      * Perform a clean and complete uninstallation.

## Why this script?

While other tools automate container creation, this script focuses on perfecting the process *inside* the container. It was built by solving real-world installation problems.

  * **Problem-Aware:** It contains built-in fixes for known bugs (Ghostscript, locales) that generic installers often overlook, saving you hours of troubleshooting.
  * **Intelligent & State-Aware:** The script detects an existing installation via a `.install_state` file and automatically switches from installer to **manager mode**.
  * **All-in-One:** Use a single command for installation, updates, password resets, and uninstallation. No need to remember multiple commands.
  * **Clean Bare Metal Setup:** It follows the official "Bare Metal" installation guide, giving you a transparent setup without the abstraction layers of Docker.

## How to Use

All you need is a running Debian 12 LXC container.

Log in as the `root` user and execute the following command. The script will be downloaded and run, guiding you through the next steps.

-----

### Option 1: `curl` (Recommended)

```bash
curl -sSL https://raw.githubusercontent.com/allmycookies/paperless-lxc-installer/main/pl-ngx-installer.sh | bash
```

-----

### Option 2: `wget`

```bash
wget -qO - https://raw.githubusercontent.com/allmycookies/paperless-lxc-installer/main/pl-ngx-installer.sh | bash
```

-----

**That's it\!**

  * **On the first run**, the script will perform the interactive installation.
  * **On any subsequent run**, the script will detect your existing installation and launch the management menu.
