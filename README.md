# ZFS Backup Script for TrueNAS SCALE

A robust, automated ZFS backup solution for TrueNAS SCALE that performs incremental backups to external SATA or USB drives using ZFS Snapshots.

## Disclaimer

This script is provided as is. I am not responsible for any data loss or damage this script may cause.
This script only works with TrueNAS Version >= 25.10, because it utilizes the new JSON-RPC 2.0 Websocket API.  

I only tested it with SATA drives. It should work with USB drives as well though. If not, feel free to submit an issue.  

S.M.A.R.T Data on the backup drives should be checked regularly.

## Features

- **Automatic backup on drive insertion**: Automatically starts backup when a drive is connected
- **Automatic disk detection**: Identifies backup disks by serial number for hands-free operation
- **Configuration management**: Uses `config.sh` file for easy setup
- **Multiple backup configurations**: Support for different backup disks
- **Backup docker containers safely**: Optionally shut down the docker service before snapshot creation for consistent data. Will spin up again automatically when                                   snapshots are taken
- **Smart scrubbing**: Optional scrubbing based on time since last scrub
- **Utilizes zfs_autobackup**: Uses the popular zfs_aurobackup script for backing up (https://github.com/psy0rz/zfs_autobackup)
- **Email notifications**: Optional email alerts when backup starts and completes (https://github.com/oxyde1989/standalone-tn-send-email)

## How It Works

1. **Disk Detection**: Scans `/dev/disk/by-id/` for connected ATA and USB drives and matches serials against configuration
2. **Pool Import**: Safely imports the destination pool using TrueNAS middleware
3. **Scrub**: Run a scrub to ensure data integrity
4. **Backup**: Use zfs_autobackup script to create and copy the backup
7. **Pool Export**: Safely exports the destination pool using TrueNAS middleware

# Installation

1. Clone this repository to your TrueNAS SCALE system:
   ```bash
   git clone <repository-url> /path/to/backup-script
   cd /path/to/backup-script
   ```

2. Make the scripts executable:
   ```bash
   chmod +x backup.sh setup_udev_manual.sh setup_udev_auto.sh
   ```

3. Copy the example configuration:
   ```bash
   cp example_config.sh config.sh
   ```

4. Edit the configuration file:
   ```bash
   nano config.sh
   ```

5. (Optional) Set up automatic backup on drive insertion:
   see "Automatic Backup on Drive Insertion" section
   

Since TrueNAS does not allow the use of apt or pip, all dependencies are bundled with this script.
The required pip packages for the zfs_autobackup script are located in the vendor folder and were packaged with the "build-vendor.ps1" script.

# Configuration

### Configuration Parameters (see config.sh file)

| Parameter | Description | Example |
|-----------|-------------|---------|
| `BACKUP_SERIALS` | Array of backup disk serial numbers | `("AB7563DEF" "CD34895FEYZ")` |
| `BACKUP_ZFS_GROUPS` | Array of ZFS group names (without `autobackup:` prefix) | `("offsite1" "offsite2")` |
| `BACKUP_DST_POOLS` | Array of destination pool names | `("offsite_backup_1" "offsite_backup_2")` |
| `BACKUP_DOCKER_CONTAINERS` | If true, docker service will shutdown during snapshot creation | `(true false)` |
| `LOG_APPEND` | Append to log file (true) or overwrite (false) | `true` |
| `SCRUB_INTERVAL_DAYS` | Days since last scrub before performing a new scrub | `14` |
| `ENABLE_SCRUB` | Enable automatic scrubbing | `true` |
| `KEEP_COUNT` | Number of snapshots to retain per dataset | `1` |
| `EMAIL_ENABLED` | Enable email notifications | `true` |
| `EMAIL_ADDRESS` | Email address to send notifications to | `admin@example.com` |
| `EMAIL_SUBJECT_PREFIX` | Prefix for email subject lines | `"[ZFS Backup]"` |
| `ALLOW_AUTOSTART` | Allow automatic backup execution | `true` |
| `DISK_BY_ID_PATH` | Path to disk by ID directory (usually no need to change) | `"/dev/disk/by-id"` |


### zfs_autobackup Configuration

Since this is basically a wrapper for the zfs_autobackup project, configuration according to the zfs_autobackup documentation needs to be done.

### Select Filesystems to Backup

We specify the filesystems we want to snapshot and replicate by assigning a unique group name to those filesystems.

It's important to choose a unique group name and to use the name consistently. (Advanced tip: If you have multiple sets of filesystems that you wish to backup differently, you may do this by creating multiple group names.)

In this example, we assign the group name `offsite1` to the filesystems we want to backup.

On the source machine, we set the `autobackup:offsite1` zfs property to true, as follows:

```bash
[root@pve01 ~]# zfs set autobackup:offsite1=true rpool
[root@pve01 ~]# zfs get -t filesystem,volume autobackup:offsite1
NAME                      PROPERTY             VALUE                SOURCE
rpool                     autobackup:offsite1  true                 local
rpool/ROOT                autobackup:offsite1  true                 inherited from rpool
rpool/ROOT/pve-1          autobackup:offsite1  true                 inherited from rpool
rpool/data                autobackup:offsite1  true                 inherited from rpool
rpool/data/vm-100-disk-0  autobackup:offsite1  true                 inherited from rpool
rpool/data/vm-101-disk-0  autobackup:offsite1  true                 inherited from rpool
rpool/tmp                 autobackup:offsite1  true                 inherited from rpool
```
ZFS properties are inherited by child datasets. Since we've set the property on the highest dataset, we're essentially backing up the whole pool.

If we don't want to backup everything, we can exclude certain filesystem by setting the property to false:

```bash
[root@pve01 ~]# zfs set autobackup:offsite1=false rpool/tmp
[root@pve01 ~]# zfs get -t filesystem,volume autobackup:offsite1
NAME                      PROPERTY             VALUE                SOURCE
rpool                     autobackup:offsite1  true                 local
rpool/ROOT                autobackup:offsite1  true                 inherited from rpool
rpool/ROOT/pve-1          autobackup:offsite1  true                 inherited from rpool
rpool/data                autobackup:offsite1  true                 inherited from rpool
rpool/data/vm-100-disk-0  autobackup:offsite1  true                 inherited from rpool
rpool/data/vm-101-disk-0  autobackup:offsite1  true                 inherited from rpool
rpool/tmp                 autobackup:offsite1  false                local
```

The autobackup property can have these values:

- **`true`**: Backup the dataset and all its children.
- **`false`**: Don't backup the dataset and all its children. (Exclude the dataset)
- **`child`**: Only backup the children of the dataset, not the dataset itself.
- **`parent`**: Only backup the dataset, but not the children. (supported in version 3.2 or higher)

> **Note**: Only use the `zfs` command to set these properties. Do not use the `zpool` command.

To remove the property completely, use:

```bash
zfs inherit autobackup:offsite1 rpool
```

### ix-apps dataset
The ix-apps dataset, that holds the docker install on TrueNAS Scale should always be excluded, because it can cause some weird behaviour if it is backed up and two datasets with the name "ix-apps" exist on one truenas. You can see where your ix-apps dataset is stored in the WebUI under Apps > Configuration > Choose pool.

### readonly property
Set the readonly property of the target filesystem to on. You can do this in the TrueNAS Webui under datasets. This prevents changes on the target side. (Due to the nature of ZFS itself, if any changes are made to a dataset on the target machine, then the next backup to that target machine will probably fail. Such a failure can probably be resolved by perfroming a target-side zfs rollback of the affected dataset.) Note that readonly prevents changes to the CONTENTS of the dataset directly. It's still possible to receive new datasets and manipulate properties etc.


# Usage

### Prerequisites

1. **TrueNAS SCALE system** with ZFS pools configured and TrueNAS version >= 25.10
2. **External backup drive** SATA or USB
3. **Destination pool** already created in TrueNAS (via web interface)
4. **Root/sudo access** for pool operations
5. **Email Notifications** If using email notifications, they have to be already set up in TrueNAS.

## Running Methods

## Option 1: Automatic Backup on Drive Insertion

This script includes automatic backup functionality that triggers whenever a configured backup drive is inserted. This feature works through udev rules and systemd services.

For production use, set up this script as a TrueNAS SCALE Init Task, since TrueNAS will override our configs on every reboot:

1. Make the automatic setup script executable:
   ```bash
   chmod +x setup_udev_auto.sh
   ```

2. In TrueNAS SCALE Web UI:
   - Go to **System Settings → Advanced → Init/Shutdown Scripts**
   - Click **"Add"**
   - Select Type: **"Script"**
   - Description: **"ZFS Backup Auto Setup"**
   - Script: Enter the full path to `setup_udev_auto.sh`
   - When: **"Post Init"**
   - Enabled: **Yes**

#### How It Works

1. When any drive is inserted, a udev rule detects the event
2. The systemd service is triggered, running the wrapper script, which will run the backup script with the "auto" argument, if it was a configured drive
3. The backup script checks again if the inserted drive is configured for backup
4. If configured, the backup process begins automatically
5. All activity is logged both to the journal and the backup log file

#### Troubleshooting

If automatic backups aren't working:

1. Check the setup logs:
   ```bash
   cat /path/to/backup-script/setup_udev_auto.log
   ```

2. Check the systemd service status:
   ```bash
   systemctl status zfs-backup
   ```

3. View the service logs:
   ```bash
   journalctl -u zfs-backup -f
   ```

## Option 2: Manual Execution

#### Workflow

1. **Connect your backup drive** - If multiple are configured, the script will detect the right one
2. **Run the script** - If no automatic execution is configured or `ALLOW_AUTOSTART=false` in the `config.sh` file.
   ```bash
   # Make the script executable
   chmod +x backup.sh

   # Run the backup 
   sudo ./backup.sh
   ```
3. **Answer tmux prompt** - To prevent interruptions due to a dropped ssh connection, the script will ask if it should execute itself in a tmux session.
You should always type `y` for yes, unless you are doing some tests. Note: When using the shell in the truenas WebUI, tmux is a bit buggy, so I wouldn't use it there. This is why you should ssh into your truenas from your console or using something like PuTTy. It will enable you to use tmux.
4. **Disconnect your backup drive** - After completion message appears
5. **Check logs** - Review `backup.log` or your email for detailed information

The script automatically detects which of your configured backup disk is connected.



## Email Notifications

The script can send email notifications at the start and completion of backup operations.

Email features:
- Start notification with basic information about the backup operation
- Completion notification with success/failure status
- Log file attached to the completion email for detailed review
- Uses [standalone-tn-send-email script](https://github.com/oxyde1989/standalone-tn-send-email)


## Technical Information

Documentation about the TrueNAS API used can be found in `doc/truenas_v25_10_api_docs/`.  
Documentation about zfs_autobackup can be found in `doc/zfs_autbackup`.

Quote from TrueNAS about their API that this script also uses:  
"The versioned JSON-RPC 2.0 Websocket Application Programming Interface (API) was introduced with TrueNAS 25.04.
Advanced users can interact with the TrueNAS API to perform management tasks using the TrueNAS API Client as an alternative to the TrueNAS web UI. This websocket client provides the command line tool `midclt` and allows users to communicate with TrueNAS middleware using Python by making API calls. The client can connect to the local TrueNAS instance or to a specified remote socket."

## Contributing
If you want a similar feature to be added to TrueNAS natively, please Vote for this [feature request](https://forums.truenas.com/t/local-backup-to-sata-or-usb-hdd/55041).

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

Or open an issue if you see room for improvement somewhere or encounter any errors or weird behaviour.

## Roadmap

### 🚀 Planned Features


#### Rewrite the Script in Python
- The script is getting quite big and it would be easier to maintain and add new features in python

#### Enhanced Logging System
- Rework Logging

#### Automatic Shutdown and Restart of VMs
- Before taking ZFS snapshots, the script will automatically stop all running virtual machines to ensure data consistency
- After the snapshots are taken, all previously running VMs will be restarted automatically
- This will help prevent data corruption and ensure reliable backups of live services

#### TrueNAS Configuration Backup
- The script will include an option to automatically export and back up the TrueNAS system configuration file as part of the backup process
- This ensures you always have a recent copy of your system settings, making disaster recovery and migration much easier


## Credits and Dependencies
[zfs_autobackup](https://github.com/psy0rz/zfs_autobackup)  
[standalone-tn-send-email](https://github.com/oxyde1989/standalone-tn-send-email)
---









