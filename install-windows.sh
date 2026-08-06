#!/bin/bash
#
# Bootstrap installs Windows ISO to a Linode from a temporary block storage volume.
# by Kit Knox - Akamai Technologies
#
# - Downloads ISO directly from Microsoft
# - Overlays VirtIO Drivers into ISO
# - Deploys ISO as Bootable USB on recovery partition on main raw disk
# - Deploys autounattend.xml to fully automate installation of Windows and enabling of Remote Desktop
#
#<UDF name="TOKEN" Label="Linode API Token" />
#<UDF name="WINDOWS_PASSWORD" Label="Administrator Password for Windows" example="Password" />
#<UDF name="INSTALL_WINDOWS_VERSION" Label="Windows Version" oneOf="w11,2k22" default="2k22"/>
#<UDF name="AUTOLOGIN" Label="Auto Login to Windows" oneOf="true,false" default="true"/>
#<UDF name="W11_ISO_URL" Label="Windows 11 ISO URL (Not Required For Windows Server) - Get Fresh URL From https://www.microsoft.com/en-us/software-download/windows11" default="NOURL"/>

# Replaced with values from StackScript UDF
#TOKEN=
#WINDOWS_PASSWORD=
#INSTALL_WINDOWS_VERSION=
#AUTOLOGIN=
#W11_ISO_URL=
W2K22_ISO_URL='https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'

# STAGE changes dynamically as install progresses
STAGE=1
# Persist UDF variables for future stages after reboot
if [ $STAGE == 1 ]; then
  sed -i "s/^#TOKEN=/TOKEN=$TOKEN/" /root/StackScript
  sed -i "s/^#WINDOWS_PASSWORD=/WINDOWS_PASSWORD=\"$(echo $WINDOWS_PASSWORD | sed -e 's/\\/\\\\/g; s/\//\\\//g; s/&/\\\&/g')\"/" /root/StackScript
  sed -i "s/^#INSTALL_WINDOWS_VERSION=/INSTALL_WINDOWS_VERSION=$INSTALL_WINDOWS_VERSION/" /root/StackScript
  sed -i "s/^#AUTOLOGIN=/AUTOLOGIN=$AUTOLOGIN/" /root/StackScript
  sed -i "s/^#W11_ISO_URL=/W11_ISO_URL=\"$(echo $W11_ISO_URL | sed -e 's/\\/\\\\/g; s/\//\\\//g; s/&/\\\&/g')\"/" /root/StackScript
fi

stage1() {
  echo "Stage 1 started"
  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  ROOT_UUID=`lsblk -o UUID,MOUNTPOINT -P |  grep 'MOUNTPOINT="/"' | sed 's/[0-9]*$//' | awk '{print $1}' | sed 's/UUID="//' | sed 's/"//'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
  fi
  if ! [ -f "/usr/bin/jq" ]; then
    echo "jq package missing"
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -yq jq wimtools genisoimage libwin-hivex-perl
  fi
  if ! [ -e "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" ]; then
    echo "LinodeID: $LINODE_ID - Creating Block Storage Volume"
    VOLUME_ID=$(curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{
        \"label\": \"temp-$LINODE_ID\",
        \"size\": 30,
        \"linode_id\": $LINODE_ID
      }" \
      https://api.linode.com/v4/volumes | jq -r '.id')
    echo "Created Block Storage Volume ID: $VOLUME_ID"
  else
    echo "Block storage volume device already exists, querying for Volume ID"
    VOLUME_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
      -H "X-Filter: {\"label\": \"temp-$LINODE_ID\"}" \
      https://api.linode.com/v4/volumes | jq -r '.data[0].id')
    echo "Found existing Block Storage Volume ID: $VOLUME_ID"
  fi
  while ! [ -e "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" ]
  do
    echo "Waiting for block storage volume."
    sleep 5
  done
  echo "Found block storage volume for Linode ID: $LINODE_ID"
  if ! lsblk -f "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" | grep ext4 > /dev/null; then
    echo "No filesystem found, creating."
    mkfs.ext4 -U $ROOT_UUID "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID"
  fi
  mkdir "/mnt/temp-$LINODE_ID"
  mount  "/dev/disk/by-id/scsi-0Linode_Volume_temp-$LINODE_ID" /mnt/temp-$LINODE_ID
  echo "Block Storage Volume ID: $VOLUME_ID"

  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`
  NEW_CONFIG=`curl -sH "Authorization: Bearer $TOKEN" \
    https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq ".data[] | select (.label|test(\"My (Ubuntu|Debian).*\"))" | jq '.kernel = "linode/grub2"' | jq ' .devices.sda.disk_id = null | .devices.sda.disk_id = null | .devices.sdc.disk_id = null | .devices.sdd = null | .devices.sdb = null | .root_device = "/dev/sda"' | jq " .devices.sda.volume_id = $VOLUME_ID" | jq " .devices.sdc = null" | grep -v "\"id\":" | jq '.label = "BLOCK"' | grep -v "\"created\":" | grep -v "\"updated\":"`

  echo "## New Config"
  echo "$NEW_CONFIG" | jq

  if ! [ $BLOCK_CONFIG_ID -gt 0 ]; then
    echo "BLOCK config doesn't exist, creating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq
  else
    echo "BLOCK config exists, updating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X PUT -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$BLOCK_CONFIG_ID | jq
  fi

  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`
  echo "BLOCK ConfigID: $BLOCK_CONFIG_ID"

  echo "rsync started"
  rsync -aAX / /mnt/temp-$LINODE_ID/ --exclude /sys/ --exclude /proc/ --exclude /dev/ --exclude /tmp/ --exclude /media/ --exclude /mnt/ --exclude /run/
  mkdir /mnt/temp-$LINODE_ID/sys /mnt/temp-$LINODE_ID/proc /mnt/temp-$LINODE_ID/dev /mnt/temp-$LINODE_ID/tmp /mnt/temp-$LINODE_ID/media /mnt/temp-$LINODE_ID/mnt /mnt/temp-$LINODE_ID/run
  echo "rsync finished"
  # Remove swap from fstab
  grep -v swap /mnt/temp-$LINODE_ID/etc/fstab > fstab.new
  cp fstab.new /mnt/temp-$LINODE_ID/etc/fstab
  rm fstab.new
  cp $0 /mnt/temp-$LINODE_ID/etc/rc.local
  chmod +x /mnt/temp-$LINODE_ID/etc/rc.local
  sed -i "s/STAGE=1/STAGE=2/" /mnt/temp-$LINODE_ID/etc/rc.local

  # Retry reboot with exponential backoff if Linode is busy
  MAX_RETRIES=5
  RETRY_COUNT=0
  WAIT_TIME=10

  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Attempting reboot (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    sleep $WAIT_TIME

    REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "{\"config_id\": $BLOCK_CONFIG_ID}" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

    echo "$REBOOT_RESPONSE" | jq

    # Check if response contains "Linode busy" error
    if echo "$REBOOT_RESPONSE" | grep -q "Linode busy"; then
      RETRY_COUNT=$((RETRY_COUNT + 1))
      WAIT_TIME=$((WAIT_TIME * 2))  # Exponential backoff
      echo "Linode busy, waiting ${WAIT_TIME}s before retry..."
    else
      # Success or different error - exit loop
      echo "Reboot request completed"
      break
    fi
  done

  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "Error: Failed to reboot after $MAX_RETRIES attempts"
    exit 1
  fi
}

stage2() {
  echo "Stage 2 started"
  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
  fi
  ROOT_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Ubuntu|Debian).*\")) | .id"`
  echo "Root Disk ID: $ROOT_DISK_ID"
  echo "Deleting Root Disk"
  curl -sH "Authorization: Bearer $TOKEN" \
      -X DELETE \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks/$ROOT_DISK_ID
  while [ $ROOT_DISK_ID -gt 0 ]; do
    echo "Root disk still exist.  Waiting."
    sleep 5
    ROOT_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Ubuntu|Debian).*\")) | .id"`
    echo "ROOT_DISK_ID: $ROOT_DISK_ID"
  done
  SWAP_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Swap).*\")) | .id"`
  echo "SWAP Disk ID: $SWAP_DISK_ID"
  echo "Deleting Swap Disk"
  curl -sH "Authorization: Bearer $TOKEN" \
      -X DELETE \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks/$SWAP_DISK_ID
  while [ $SWAP_DISK_ID -gt 0 ]; do
    echo "Swap disk still exist.  Waiting."
    sleep 5
    SWAP_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label|test(\"(Swap).*\")) | .id"`
    echo "ROOT_DISK_ID: $ROOT_DISK_ID"
  done
  LINODE_INSTANCE_TYPE=`dmidecode -t1|grep "Family" | awk '{print $2}' | sed 's/Linode.//'`
  LINODE_DISK_MAX=`curl https://api.linode.com/v4/linode/types | jq ".data[] | select (.id == \"$LINODE_INSTANCE_TYPE\") | .disk"`
  echo "DISK_MAX: $LINODE_DISK_MAX"
  NEW_DISK_SIZE=$(($LINODE_DISK_MAX))

  echo "Instance Type: $LINODE_INSTANCE_TYPE - New Size: $NEW_DISK_SIZE"
  curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{
        \"label\": \"Windows\",
        \"filesystem\": \"raw\",
        \"size\": $NEW_DISK_SIZE
      }" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq

  RAW_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label == \"Windows\") | .id"`
  echo "RAW_DISK_ID: $RAW_DISK_ID"
  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`

  NEW_CONFIG=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK")' | jq ' .devices.sdb = null' | jq " .devices.sdb.disk_id = $RAW_DISK_ID" | grep -v "\"id\":" | jq '.label = "BLOCK"' | grep -v "\"created\":" | grep -v "\"updated\":"`

  echo "## New Config"
  echo "$NEW_CONFIG" | jq
  echo

  if ! [ $BLOCK_CONFIG_ID -gt 0 ]; then
    echo "## BLOCK config doesn't exist, creating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq
  else
    echo "## BLOCK config exists, updating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X PUT -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$BLOCK_CONFIG_ID | jq
  fi

  BLOCK_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK") | .id'`
  echo "## BLOCK Config: $BLOCK_CONFIG_ID"

  sed -i "s/STAGE=2/STAGE=3/" /etc/rc.local

  # Retry reboot with exponential backoff if Linode is busy
  MAX_RETRIES=5
  RETRY_COUNT=0
  WAIT_TIME=10

  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "Attempting reboot (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
    sleep $WAIT_TIME

    REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" -X POST\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

    echo "$REBOOT_RESPONSE" | jq

    # Check if response contains "Linode busy" error
    if echo "$REBOOT_RESPONSE" | grep -q "Linode busy"; then
      RETRY_COUNT=$((RETRY_COUNT + 1))
      WAIT_TIME=$((WAIT_TIME * 2))  # Exponential backoff
      echo "Linode busy, waiting ${WAIT_TIME}s before retry..."
    else
      # Success or different error - exit loop
      echo "Reboot request completed"
      break
    fi
  done

  if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    echo "Error: Failed to reboot after $MAX_RETRIES attempts"
    exit 1
  fi
}

stage3() {

  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
  fi

  # Install all required packages for stage 3 in one operation
  PACKAGES_NEEDED=false
  if ! [ -f /usr/bin/wimmount ]; then PACKAGES_NEEDED=true; fi
  if ! command -v kexec >/dev/null; then PACKAGES_NEEDED=true; fi
  if ! [ -f /usr/bin/cpio ]; then PACKAGES_NEEDED=true; fi

  if [ "$PACKAGES_NEEDED" = true ]; then
    echo "Installing required packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -yq wimtools genisoimage libwin-hivex-perl ntfs-3g kexec-tools cpio libarchive-tools
  fi

  RAW_DISK_ID=`curl -sH "Authorization: Bearer $TOKEN" \
        https://api.linode.com/v4/linode/instances/$LINODE_ID/disks | jq ".data[] | select (.label == \"Windows\") | .id"`
   echo "RAW_DISK_ID: $RAW_DISK_ID"

  WINDOWS_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "Windows") | .id'`

  NEW_CONFIG=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "BLOCK")' | jq ' .kernel = "linode/direct-disk" | .devices.sda.volume_id = null | .devices.sdb = null | .devices.sdc = null | .root_device = "/dev/sda"' | jq " .devices.sda.disk_id = $RAW_DISK_ID" | grep -v "\"id\":" | jq '.label = "Windows"' | grep -v "\"created\":" | grep -v "\"updated\":"`

  echo "## New Config"
  echo "$NEW_CONFIG" | jq

  if ! [ $WINDOWS_CONFIG_ID -gt 0 ]; then
    echo "## Windows config doesn't exist, creating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X POST -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq
  else
    echo "## Windows config exists, updating."
    curl -sH "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -X PUT -d "$NEW_CONFIG"\
        https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$WINDOWS_CONFIG_ID | jq
 fi

  WINDOWS_CONFIG_ID=`curl -sH "Authorization: Bearer $TOKEN" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | jq '.data[] | select (.label == "Windows") | .id'`
  echo "## Windows Config: $WINDOWS_CONFIG_ID"

  # Query for the temp block volume ID
  VOLUME_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
    -H "X-Filter: {\"label\": \"temp-$LINODE_ID\"}" \
    https://api.linode.com/v4/volumes | jq -r '.data[0].id')
  echo "Volume ID: $VOLUME_ID"

  # v3.2 is required for Windows 11 24H2 driver injection to work --edge gets us this
  if ! [ -f /snap/bin/distrobuilder ]; then
    snap install distrobuilder --classic --edge
  fi

  if ! [ -f woeusb.sh ]; then
    wget -O woeusb.sh https://github.com/WoeUSB/WoeUSB/releases/download/v5.2.4/woeusb-5.2.4.bash
    chmod +x woeusb.sh
  fi
  # ===== diagnostic hardening: prevent silent empty-media builds =====
  # Halt (do NOT reboot) on any media-build failure so the build env + logs survive for SSH inspection.
  fail_halt() {
    echo "############ BUILD VALIDATION FAILED: $1 ############"
    echo "Halting (no reboot) so build env survives. SSH: root@$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "Logs: /root/distrobuilder.log /root/woeusb.log"; df -h 2>&1
    touch /root/BUILD_FAILED
    exit 1
  }

  # ===== Heavy repack runs on the 160GB raw target disk (sdb), NOT the 30GB build root =====
  # Root cause of the empty-media bug (confirmed): the ~30GB build root cannot hold
  # source(8GB) + distrobuilder overlay + output(8GB) for the English ISO, so ISO generation hit
  # ENOSPC (exit 28) and left a truncated windows_virtio.iso that WoeUSB could not extract
  # -> empty media partition -> "Booting from Hard Disk..." hang. sdb is the eventual Windows
  # target but is unused until the partitioning step below, so borrow it as scratch first.
  WORK=/mnt/work
  if ! mountpoint -q "$WORK" 2>/dev/null; then
    mkdir -p "$WORK"
    umount /dev/sdb1 2>/dev/null; umount /dev/sdb 2>/dev/null
    wipefs -a /dev/sdb >/dev/null 2>&1 || true
    mkfs.ext4 -F -q /dev/sdb
    mount /dev/sdb "$WORK"
  fi
  echo "Scratch on sdb (160GB):"; df -h "$WORK"

  # Stage source ISO onto the big scratch disk (move it off the small root if already downloaded there)
  if [ ! -f "$WORK/windows-amd64.iso" ]; then
    if [ -f windows-amd64.iso ]; then mv windows-amd64.iso "$WORK/windows-amd64.iso"
    elif [ "$INSTALL_WINDOWS_VERSION" == "2k22" ]; then wget -q -O "$WORK/windows-amd64.iso" "$W2K22_ISO_URL"
    elif [ "$INSTALL_WINDOWS_VERSION" == "w11" ]; then wget -q -O "$WORK/windows-amd64.iso" "$W11_ISO_URL"
    fi
  fi
  [ -f "$WORK/windows-amd64.iso" ] || fail_halt "no source ISO staged on scratch"

  if [ ! -f "$WORK/windows_virtio.iso" ]; then
    echo "Running distrobuilder repack-windows (cache-dir + source + output + TMPDIR all on 160GB sdb scratch)..."
    mkdir -p "$WORK/dbcache" "$WORK/tmp"
    export TMPDIR="$WORK/tmp"   # keep any tool honoring TMPDIR off the small 30GB root
    distrobuilder repack-windows "$WORK/windows-amd64.iso" "$WORK/windows_virtio.iso" \
      --windows-version=$INSTALL_WINDOWS_VERSION --cache-dir="$WORK/dbcache" > /root/distrobuilder.log 2>&1
    DB_RC=$?
    echo "distrobuilder exit code: $DB_RC" | tee -a /root/distrobuilder.log
  fi

  # --- Validate distrobuilder output BEFORE destroying anything (root cause of the empty-media bug) ---
  [ -f "$WORK/windows_virtio.iso" ] || fail_halt "distrobuilder produced no windows_virtio.iso"
  VIRTIO_BYTES=$(stat -c%s "$WORK/windows_virtio.iso" 2>/dev/null || echo 0)
  SRC_BYTES=$(stat -c%s "$WORK/windows-amd64.iso" 2>/dev/null || echo 0)
  echo "ISO sizes: source=$SRC_BYTES virtio=$VIRTIO_BYTES"
  if [ "$VIRTIO_BYTES" -lt 3221225472 ] || [ "$VIRTIO_BYTES" -lt $((SRC_BYTES * 80 / 100)) ]; then
    fail_halt "windows_virtio.iso too small ($VIRTIO_BYTES vs source $SRC_BYTES) - likely truncated repack (ENOSPC?)"
  fi
  if command -v bsdtar >/dev/null 2>&1; then VLIST=$(bsdtar -tf "$WORK/windows_virtio.iso" 2>/dev/null)
  else VLIST=$(isoinfo -f -i "$WORK/windows_virtio.iso" 2>/dev/null); fi
  echo "$VLIST" | grep -qiE 'sources/install\.(wim|esd)' || fail_halt "windows_virtio.iso missing sources/install.wim"
  echo "$VLIST" | grep -qiE '(^|/)bootmgr(\.|;|$)'        || fail_halt "windows_virtio.iso missing bootmgr"
  echo "windows_virtio.iso validated OK ($VIRTIO_BYTES bytes)"

  # Move the validated ISO OFF sdb to the build root (30GB root has ~15GB free without swap/source), then release sdb.
  echo "Staging validated ISO to build root and releasing sdb for partitioning..."
  cp "$WORK/windows_virtio.iso" /windows_virtio.iso || fail_halt "cp of windows_virtio.iso to build root failed"
  sync
  ROOT_BYTES=$(stat -c%s /windows_virtio.iso 2>/dev/null || echo 0)
  [ "$ROOT_BYTES" -eq "$VIRTIO_BYTES" ] || fail_halt "staged ISO size mismatch ($ROOT_BYTES vs $VIRTIO_BYTES) - truncated cp (root ENOSPC?)"
  cd /
  export TMPDIR=/tmp
  # Recursively release sdb (distrobuilder may leave loop/overlay mounts under $WORK); HARD-GATE before parted.
  umount -R "$WORK" 2>/dev/null || { fuser -km "$WORK" 2>/dev/null; sleep 3; umount -R "$WORK" 2>/dev/null; }
  sleep 1
  mountpoint -q "$WORK" && fail_halt "sdb scratch still mounted at $WORK - cannot repartition"
  grep -q '^/dev/sdb' /proc/mounts && fail_halt "sdb still busy (mounted) - cannot repartition"

  # Create manual partition layout to support >4GB files and provide empty installation target
  # Partition 1: 8GB NTFS (bootable, contains installation media)
  # Partition 2: Remaining space NTFS (empty, Windows installation target)
  echo "Creating MBR partition table on /dev/sdb..."
  parted -s /dev/sdb mklabel msdos || fail_halt "parted mklabel failed"

  echo "Creating partition 1 (12GB NTFS for installation media - English repacked ISO is ~8.5GB)..."
  parted -s /dev/sdb mkpart primary ntfs 1MiB 12GiB || fail_halt "parted mkpart1 failed"
  parted -s /dev/sdb set 1 boot on || fail_halt "parted set boot flag failed"

  echo "Creating partition 2 (remaining space for Windows installation)..."
  parted -s /dev/sdb mkpart primary ntfs 12GiB 100% || fail_halt "parted mkpart2 failed"

  # Settle the new partition table BEFORE formatting (mkfs must not race udev device-node creation)
  partprobe /dev/sdb; udevadm settle 2>/dev/null; sleep 2
  [ -b /dev/sdb1 ] || fail_halt "/dev/sdb1 did not appear after partprobe"
  [ -b /dev/sdb2 ] || fail_halt "/dev/sdb2 did not appear after partprobe"

  # Format both partitions as NTFS
  echo "Formatting partitions as NTFS..."
  mkfs.ntfs -f -Q /dev/sdb1 || fail_halt "mkfs.ntfs sdb1 failed"  # installation media
  mkfs.ntfs -f -Q /dev/sdb2 || fail_halt "mkfs.ntfs sdb2 failed"  # Windows install target
  udevadm settle 2>/dev/null; sleep 1

  # Use WoeUSB in partition mode to copy installation media to partition 1 only
  # This leaves partition 2 empty for Windows installation
  echo "Copying Windows installation media to /dev/sdb1 with WoeUSB (logging to /root/woeusb.log)..."
  /woeusb.sh --partition /windows_virtio.iso /dev/sdb1 > /root/woeusb.log 2>&1
  WOE_RC=$?
  echo "woeusb exit code: $WOE_RC" | tee -a /root/woeusb.log
  [ "$WOE_RC" -eq 0 ] || fail_halt "woeusb exited non-zero ($WOE_RC)"

  # Validate the MBR bootstrap was actually written. WoeUSB installs grub to the parent disk (/dev/sdb);
  # parted mklabel + mkfs.ntfs alone do NOT write bootable MBR code. An empty MBR reproduces the exact
  # "Booting from Hard Disk..." SeaBIOS hang even when the files on the partition are correct.
  if ! dd if=/dev/sdb bs=446 count=1 2>/dev/null | tr -d '\0' | grep -q . ; then
    fail_halt "sdb MBR bootstrap empty - no bootloader (would hang at 'Booting from Hard Disk')"
  fi
  echo "MBR bootstrap present (non-empty)."

  # --- Validate the media partition actually received the Windows files (the empty-media bug) ---
  mount /dev/sdb1 /mnt
  if [ ! -f /mnt/bootmgr ] || ! ls /mnt/sources/install.* >/dev/null 2>&1; then
    echo "media partition contents after woeusb:"; ls -la /mnt 2>&1; df -h /mnt 2>&1
    umount /mnt
    fail_halt "media partition missing bootmgr or sources/install.* after woeusb"
  fi
  echo "Media partition validated: bootmgr + sources/install.* present."

  # Copy autounattend.xml to the installation media partition
  echo "Copying autounattend.xml to installation media..."
  cp /root/autounattend.xml /mnt/
  umount /mnt

  # ===== kexec-based cleanup =====
  echo "Preparing cleanup environment..."

  # Build initramfs structure
  echo "Building initramfs..."
  mkdir -p /tmp/initramfs/{bin,lib,lib64,dev,proc,sys,etc}

  # Copy busybox
  cp /bin/busybox /tmp/initramfs/bin/
  ln -s busybox /tmp/initramfs/bin/sh

  # Copy curl and its shared libraries
  cp /usr/bin/curl /tmp/initramfs/bin/
  for lib in $(ldd /usr/bin/curl | grep -o '/lib[^ ]*'); do
    mkdir -p "/tmp/initramfs$(dirname $lib)"
    cp "$lib" "/tmp/initramfs$lib" 2>/dev/null || true
  done

  # Copy jq and its shared libraries
  cp /usr/bin/jq /tmp/initramfs/bin/
  for lib in $(ldd /usr/bin/jq | grep -o '/lib[^ ]*'); do
    mkdir -p "/tmp/initramfs$(dirname $lib)"
    cp "$lib" "/tmp/initramfs$lib" 2>/dev/null || true
  done

  # Copy SSL certificates for HTTPS
  echo "Copying SSL certificates..."
  mkdir -p /tmp/initramfs/etc/ssl/certs
  cp -r /etc/ssl/certs/* /tmp/initramfs/etc/ssl/certs/ 2>/dev/null || true
  # Also copy ca-certificates
  if [ -f /etc/ca-certificates.conf ]; then
    cp /etc/ca-certificates.conf /tmp/initramfs/etc/
  fi

  # Copy kernel modules for network support
  echo "Copying kernel modules..."
  KVER=$(uname -r)
  mkdir -p /tmp/initramfs/lib/modules/$KVER

  # Use modprobe --show-depends to get exact module dependencies
  echo "Querying virtio_net dependencies..."
  modprobe --show-depends virtio_net 2>/dev/null | awk '{print $2}' | while read module; do
    if [ -f "$module" ]; then
      # Create directory structure in initramfs
      module_dir=$(dirname "$module")
      mkdir -p "/tmp/initramfs$module_dir"
      # Copy the module
      cp "$module" "/tmp/initramfs$module"
      echo "  Copied: $module"
    fi
  done

  # Copy modules.dep and related files for modprobe to work
  echo "Copying module metadata..."
  cp /lib/modules/$KVER/modules.order /tmp/initramfs/lib/modules/$KVER/ 2>/dev/null || true
  cp /lib/modules/$KVER/modules.builtin /tmp/initramfs/lib/modules/$KVER/ 2>/dev/null || true
  cp /lib/modules/$KVER/modules.builtin.bin /tmp/initramfs/lib/modules/$KVER/ 2>/dev/null || true

  # Generate a minimal modules.dep for just the modules we copied
  depmod -b /tmp/initramfs $KVER 2>/dev/null || true

  # Copy modprobe and kmod
  cp /usr/bin/kmod /tmp/initramfs/bin/ 2>/dev/null || cp /bin/kmod /tmp/initramfs/bin/ 2>/dev/null || true
  ln -s kmod /tmp/initramfs/bin/modprobe 2>/dev/null || true
  ln -s kmod /tmp/initramfs/bin/insmod 2>/dev/null || true

  # Copy kmod dependencies
  for lib in $(ldd /usr/bin/kmod 2>/dev/null | grep -o '/lib[^ ]*' || ldd /bin/kmod 2>/dev/null | grep -o '/lib[^ ]*'); do
    mkdir -p "/tmp/initramfs$(dirname $lib)"
    cp "$lib" "/tmp/initramfs$lib" 2>/dev/null || true
  done

  # Capture current network configuration
  # Detect current network interface dynamically
  CURRENT_IFACE=$(ip route | grep default | awk '{print $5}')
  CURRENT_IP=$(ip -4 addr show dev $CURRENT_IFACE | grep inet | awk '{print $2}')
  CURRENT_GW=$(ip route | grep default | awk '{print $3}')
  echo "Current network: $CURRENT_IFACE with IP $CURRENT_IP, gateway $CURRENT_GW"

  # Create init script for cleanup
  echo "Creating cleanup script..."
  cat > /tmp/initramfs/init <<'INITEOF'
#!/bin/busybox sh

# Mount essential filesystems
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys

# Load network drivers
echo "Loading virtio network drivers..."
export LD_LIBRARY_PATH=/lib:/lib64
/bin/modprobe virtio_net 2>&1 || /bin/busybox echo "modprobe failed, network may not work"

# Configure networking with static IP
# Wait for network interfaces to appear (up to 10 seconds)
echo "Waiting for network interfaces..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  IFACE=$(/bin/busybox ls /sys/class/net/ | /bin/busybox grep -v lo | /bin/busybox head -n 1)
  if [ -n "$IFACE" ]; then
    break
  fi
  /bin/busybox sleep 1
done

# Debug: Show all network interfaces
echo "=== Network Interface Debug ==="
/bin/busybox ls -la /sys/class/net/
/bin/busybox ip link show
echo "Detected interface: '$IFACE'"
echo "==============================="

if [ -z "$IFACE" ]; then
  echo "ERROR: No network interface detected!"
  IFACE=eth0  # Fallback to eth0
fi

echo "Using network interface: $IFACE"
/bin/busybox ip link set lo up
/bin/busybox ip addr add CURRENT_IP_PLACEHOLDER dev $IFACE
/bin/busybox ip link set $IFACE up
/bin/busybox ip route add default via CURRENT_GW_PLACEHOLDER
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# Give network time to initialize
/bin/busybox sleep 3

# Verify network configuration
echo "=== Network Configuration Verification ==="
echo "IP address being set: CURRENT_IP_PLACEHOLDER"
echo "Gateway being set: CURRENT_GW_PLACEHOLDER"
echo ""
echo "Interface status:"
/bin/busybox ip addr show
echo ""
echo "Routing table:"
/bin/busybox ip route show
echo ""
echo "Testing connectivity to gateway..."
/bin/busybox ping -c 1 -W 2 CURRENT_GW_PLACEHOLDER && echo "Gateway: OK" || echo "Gateway: FAILED"
echo ""
echo "Testing connectivity to 8.8.8.8..."
/bin/busybox ping -c 1 -W 2 8.8.8.8 && echo "8.8.8.8: OK" || echo "8.8.8.8: FAILED"
echo ""
echo "Testing DNS resolution..."
/bin/busybox nslookup api.linode.com && echo "DNS: OK" || echo "DNS: FAILED"
echo "=========================================="

# Embedded variables
TOKEN="TOKEN_PLACEHOLDER"
LINODE_ID=LINODE_ID_PLACEHOLDER
VOLUME_ID=VOLUME_ID_PLACEHOLDER
WINDOWS_CONFIG_ID=WINDOWS_CONFIG_ID_PLACEHOLDER

export LD_LIBRARY_PATH=/lib:/lib64

# Test curl with verbose output
echo "=== Testing curl HTTPS connectivity ==="
echo "Attempting to fetch Linode API status..."
curl -v -H "Authorization: Bearer $TOKEN" \
  https://api.linode.com/v4/linode/instances/$LINODE_ID/configs 2>&1 | head -20
echo ""
echo "Checking SSL certificate bundle..."
ls -la /etc/ssl/certs/ | head -10
echo "=========================================="

echo "Cleaning up configuration profiles..."

# Delete Ubuntu config
UBUNTU_CONFIG_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
  https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | \
  jq -r '.data[] | select(.label | test("My (Ubuntu|Debian).*")) | .id')
if [ -n "$UBUNTU_CONFIG_ID" ]; then
  echo "Deleting Ubuntu config ID: $UBUNTU_CONFIG_ID"
  curl -sH "Authorization: Bearer $TOKEN" \
    -X DELETE https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$UBUNTU_CONFIG_ID
fi

# Delete BLOCK config
BLOCK_CONFIG_ID=$(curl -sH "Authorization: Bearer $TOKEN" \
  https://api.linode.com/v4/linode/instances/$LINODE_ID/configs | \
  jq -r '.data[] | select(.label == "BLOCK") | .id')
if [ -n "$BLOCK_CONFIG_ID" ]; then
  echo "Deleting BLOCK config ID: $BLOCK_CONFIG_ID"
  curl -sH "Authorization: Bearer $TOKEN" \
    -X DELETE https://api.linode.com/v4/linode/instances/$LINODE_ID/configs/$BLOCK_CONFIG_ID
fi

echo "Detaching block volume ID: $VOLUME_ID"
DETACH_RESPONSE=$(curl -sH "Authorization: Bearer $TOKEN" \
  -X POST https://api.linode.com/v4/volumes/$VOLUME_ID/detach)
echo "Detach API response: $DETACH_RESPONSE"

# Poll for detachment (60 second timeout)
echo "Waiting for volume detachment..."
DETACHED=false
for i in $(seq 1 30); do
  echo "Detachment check attempt $i/30..."
  VOLUME_STATUS=$(curl -sH "Authorization: Bearer $TOKEN" \
    https://api.linode.com/v4/volumes/$VOLUME_ID)
  ATTACHED=$(echo "$VOLUME_STATUS" | jq -r '.linode_id')
  echo "Volume status: linode_id=$ATTACHED"

  if [ "$ATTACHED" = "null" ]; then
    DETACHED=true
    echo "Volume detached successfully"
    break
  fi
  /bin/busybox sleep 2
done

# Delete volume if detached
if [ "$DETACHED" = "true" ]; then
  echo "Deleting block volume..."
  curl -sH "Authorization: Bearer $TOKEN" \
    -X DELETE https://api.linode.com/v4/volumes/$VOLUME_ID
else
  echo "Volume detachment timed out, skipping deletion"
fi

# Reboot to Windows config with retry logic
echo "Rebooting to Windows configuration..."
MAX_RETRIES=5
RETRY_COUNT=0
WAIT_TIME=10

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  /bin/busybox sleep $WAIT_TIME

  REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -X POST -d "{\"config_id\": $WINDOWS_CONFIG_ID}" \
    https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

  if echo "$REBOOT_RESPONSE" | grep -q "Linode busy"; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    WAIT_TIME=$((WAIT_TIME * 2))
    echo "Linode busy, retrying in ${WAIT_TIME}s..."
  else
    echo "Reboot initiated successfully"
    break
  fi
done

# Fallback to forced reboot
echo "Forcing reboot in 10 seconds..."
/bin/busybox sleep 10
/bin/busybox reboot -f

# Wait indefinitely for reboot to complete (init must never exit)
echo "Waiting for reboot to complete..."
while true; do
  /bin/busybox sleep 60
done
INITEOF

  # Validate all required variables are set
  if [ -z "$VOLUME_ID" ]; then echo "ERROR: VOLUME_ID not set"; exit 1; fi
  if [ -z "$WINDOWS_CONFIG_ID" ]; then echo "ERROR: WINDOWS_CONFIG_ID not set"; exit 1; fi
  if [ -z "$LINODE_ID" ]; then echo "ERROR: LINODE_ID not set"; exit 1; fi
  if [ -z "$TOKEN" ]; then echo "ERROR: TOKEN not set"; exit 1; fi
  if [ -z "$CURRENT_IP" ]; then echo "ERROR: CURRENT_IP not set"; exit 1; fi
  if [ -z "$CURRENT_GW" ]; then echo "ERROR: CURRENT_GW not set"; exit 1; fi

  echo "Cleanup variables validated: VOLUME_ID=$VOLUME_ID LINODE_ID=$LINODE_ID WINDOWS_CONFIG_ID=$WINDOWS_CONFIG_ID"

  # Substitute placeholders with actual values
  sed -i "s|CURRENT_IP_PLACEHOLDER|$CURRENT_IP|g" /tmp/initramfs/init
  sed -i "s|CURRENT_GW_PLACEHOLDER|$CURRENT_GW|g" /tmp/initramfs/init
  sed -i "s|TOKEN_PLACEHOLDER|$TOKEN|g" /tmp/initramfs/init
  sed -i "s|LINODE_ID_PLACEHOLDER|$LINODE_ID|g" /tmp/initramfs/init
  sed -i "s|VOLUME_ID_PLACEHOLDER|$VOLUME_ID|g" /tmp/initramfs/init
  sed -i "s|WINDOWS_CONFIG_ID_PLACEHOLDER|$WINDOWS_CONFIG_ID|g" /tmp/initramfs/init

  chmod +x /tmp/initramfs/init

  # Pack initramfs
  echo "Packing initramfs..."
  cd /tmp/initramfs
  find . | cpio -o -H newc 2>/dev/null | gzip > /tmp/cleanup.cpio.gz
  cd /

  # Load kernel and initramfs with kexec
  echo "Loading cleanup environment with kexec..."

  # Extract only safe kernel parameters
  CONSOLE_PARAM=$(cat /proc/cmdline | grep -oE 'console=[^ ]+' || echo "console=ttyS0,19200n8")
  IFNAMES_PARAM=$(cat /proc/cmdline | grep -oE 'net\.ifnames=[^ ]+' || echo "net.ifnames=0")
  BIOSDEV_PARAM=$(cat /proc/cmdline | grep -oE 'biosdevname=[^ ]+' || echo "")

  KEXEC_CMDLINE="$CONSOLE_PARAM $IFNAMES_PARAM $BIOSDEV_PARAM quiet"
  echo "kexec cmdline: $KEXEC_CMDLINE"

  kexec -l /boot/vmlinuz-$(uname -r) \
    --initrd=/tmp/cleanup.cpio.gz \
    --append="$KEXEC_CMDLINE"

  # Execute kexec (this never returns)
  echo "Launching cleanup environment..."
  echo "Windows installation will continue automatically after cleanup."
  sleep 2
  kexec -e

  # Should never reach here
  echo "ERROR: kexec failed, attempting fallback direct reboot"
  sleep 5

  # Last resort: reboot to Windows config via API
  REBOOT_RESPONSE=$(curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{\"config_id\": $WINDOWS_CONFIG_ID}" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot)

  echo "$REBOOT_RESPONSE" | jq

  # If that fails, force reboot without cleanup
  sleep 10
  reboot -f
}


createunattend() {
  if [ $INSTALL_WINDOWS_VERSION == "2k22" ]; then
cat > /root/autounattend.xml<<EOF
<?xml version="1.0" encoding="utf-8"?>
<!-- C:\Windows\Panther\unattend.xml -->
<unattend xmlns="urn:schemas-microsoft-com:unattend"
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
			<InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>2</PartitionID>
                            <Format>NTFS</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>false</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>Windows Server 2022 SERVERDATACENTER</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>2</PartitionID>
                    </InstallTo>
                    <WillShowUI>OnError</WillShowUI>
                    <InstallToAvailablePartition>false</InstallToAvailablePartition>
                </OSImage>
            </ImageInstall>
            <UserData>
			    <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <TimeZone>Pacific Standard Time</TimeZone>
        </component>
	<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <FirewallGroups>
                <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
                    <Active>true</Active>
                    <Group>Remote Desktop</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
            </FirewallGroups>
        </component>
        <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SecurityLayer>2</SecurityLayer>
            <UserAuthentication>1</UserAuthentication>
        </component>
	<component name="Microsoft-Windows-ServerManager-SvrMgrNc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
           <RunSynchronous>
             <RunSynchronousCommand wcm:action="add">
               <Order>1</Order>
               <Path>cmd /c bcdedit /emssettings emsport:1 emsbaudrate:115200</Path>
               <Description>BCD 1</Description>
             </RunSynchronousCommand>
             <RunSynchronousCommand wcm:action="add">
               <Order>2</Order>
               <Path>cmd /c bcdedit /ems {default} on</Path>
               <Description>BCD 2</Description>
             </RunSynchronousCommand>
             <RunSynchronousCommand wcm:action="add">
               <Order>3</Order>
               <Path>cmd /c bcdedit /bootems yes</Path>
               <Description>BCD 3</Description>
             </RunSynchronousCommand>
             <RunSynchronousCommand wcm:action="add">
               <Order>4</Order>
               <Path>cmd /c bcdedit /set {emmsettings} bootems yes</Path>
               <Description>BCD 4</Description>
             </RunSynchronousCommand>
           </RunSynchronous>
         </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>2</LogonCount>
                <Username>Administrator</Username>
                <Enabled>$AUTOLOGIN</Enabled>
            </AutoLogon>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
    <cpi:offlineImage cpi:source="wim:c:/wims/install.wim#Windows Server 2022 SERVERDATACENTER" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
EOF
  fi
  if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
cat > /root/autounattend.xml<<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t reg_dword /d 0x00000001 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>2</PartitionID>
                            <Format>NTFS</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>false</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <UserData>
                <AcceptEula>true</AcceptEula>
                <ProductKey>
                    <Key></Key>
                </ProductKey>
            </UserData>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/NAME</Key>
                            <Value>Windows 10 Pro</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>2</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UILanguageFallback>en-US</UILanguageFallback>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </Password>
                <LogonCount>3</LogonCount>
                <Username>Administrator</Username>
                <Enabled>$AUTOLOGIN</Enabled>
            </AutoLogon>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$WINDOWS_PASSWORD</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>1</ProtectYourPC>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <FirewallGroups>
                <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
                    <Active>true</Active>
                    <Group>Remote Desktop</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
            </FirewallGroups>
        </component>
        <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SecurityLayer>2</SecurityLayer>
            <UserAuthentication>1</UserAuthentication>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Description>test</Description>
                    <Order>1</Order>
                    <Path>cmd /c echo Windows 11 Specialize &gt;&gt; C:\log.txt</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Description>Show File Extention</Description>
                    <Order>2</Order>
                    <Path>cmd /k reg add &quot;HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced&quot; /v HideFileExt /t REG_DWORD /d 0 /f &amp;&amp; exit</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Path>cmd /c reg load HKLM\DEFAULT c:\users\default\ntuser.dat &amp;&amp; reg add HKLM\DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarMn  /t REG_DWORD /d 0 /f &amp;&amp; reg unload HKLM\DEFAULT &amp;&amp; exit</Path>
                    <Order>4</Order>
                    <Description>Hide Chat</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>cmd /c reg load HKLM\DEFAULT c:\users\default\ntuser.dat &amp;&amp; reg add HKLM\DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced /v TaskbarDa  /t REG_DWORD /d 0 /f &amp;&amp; reg unload HKLM\DEFAULT &amp;&amp; exit</Path>
                    <Description>Hide Widget</Description>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
</unattend>
EOF
  fi
}

if [ $INSTALL_WINDOWS_VERSION == "2k22" ]; then
  echo "Installing Windows Server"
fi

if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
  echo "Installing Windows 11"
fi

if [ $STAGE == 1 ]; then
  createunattend
  stage1
fi
if [ $STAGE == 2 ]; then
  stage2
fi
if [ $STAGE == 3 ]; then
  createunattend
  stage3
fi

