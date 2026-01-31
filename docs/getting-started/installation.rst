############
Installation
############
To make the laboratory work smoothly, 
we need to install the dependencies described in this section.

.. caution::

    The laboratory was made using Ubuntu 22.04.1 LTS. Other distributions have not been tested.

Requirements
############
The following requirements were taken from my environment.
I propose specific versions for the tools as I haven't had the time to experiment with different versions.

Please feel free to create a new issue if any installation step doesn't work for you.

VMware Workstation Pro
----------------------
VMware Workstation Pro is free for personal use.
Download and install it on your **Windows host** from the official VMware website.

.. code-block::

    # Download from: https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion

Vagrant VMware Utility
~~~~~~~~~~~~~~~~~~~~~~
After installing VMware Workstation Pro, install the Vagrant VMware Utility.
This is a system-level service that Vagrant uses to communicate with VMware.
It must be installed on the **Windows host** (not inside WSL2).

.. code-block::

    # Download the appropriate package from:
    # https://developer.hashicorp.com/vagrant/install/vmware

VMware Network Configuration
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The laboratory uses a host-only network with the subnet ``192.168.56.0/24``.
You must configure this in VMware before launching the lab.

1. Open VMware Workstation Pro.
2. Navigate to **Edit > Virtual Network Editor**.
3. Click **Add Network** and select a free vmnet adapter (e.g., vmnet2).
4. Set the type to **Host-only**.
5. Set the subnet IP to ``192.168.56.0`` with mask ``255.255.255.0``.
6. Uncheck **Use local DHCP service** (the lab uses static IPs).
7. Click **Apply** and **OK**.

Vagrant
-------
To install a specific version, you need to add Vagrant repository.

.. code-block::

    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list

    sudo apt update

Installing Vagrant in version 2.3.0.

.. code-block::

    sudo apt install vagrant=2.3.0

Installing Vagrant plugins.

.. code-block::

    vagrant plugin install vagrant-vmware-desktop
    vagrant plugin install winrm
    vagrant plugin install winrm-fs
    vagrant plugin install winrm-elevated

WSL2 Environment
~~~~~~~~~~~~~~~~
If you are using WSL2, add the following to your ``~/.bashrc`` or ``~/.zshrc``:

.. code-block:: bash

    export VAGRANT_WSL_ENABLE_WINDOWS_ACCESS="1"
    export PATH="$PATH:/mnt/c/Program Files (x86)/VMware/VMware Workstation"

Then reload your shell:

.. code-block::

    source ~/.bashrc

Python & Ansible
----------------

Installing the required dependencies with Python.

.. Note::

    I'm using Python in version 3.10.6.

.. code-block::

    # Current directory: python
    # Creating a virtual environment
    # sudo apt install python3.10-venv -y (if needed)
    python3 -m venv venv .

    # Activating it
    source bin/activate
    
    # Installing the required Python dependencies (ansible-core, pywinrm...)
    python3 -m pip install -r requirements.txt

.. tip::

    To deactivate the virtual environment created with Python, just type ``deactivate`` in the terminal.

Installing the required dependencies with Ansible.

.. code-block::

    # Current directory: ansible
    # Installing the required Ansible dependencies
    ansible-galaxy install -r requirements.yml