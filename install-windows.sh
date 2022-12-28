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
    curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{
        \"label\": \"temp-$LINODE_ID\",
        \"size\": 30,
        \"linode_id\": $LINODE_ID
      }" \
      https://api.linode.com/v4/volumes | json_pp
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
  VOLUME_ID=`curl -sH "Authorization: Bearer $TOKEN"     https://api.linode.com/v4/volumes | jq ".data[] | select (.label == \"temp-$LINODE_ID\") | .id"`
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
  chmod +x /mnt/temp-$LINODE_ID/rc.local
  sed -i "s/STAGE=1/STAGE=2/" /mnt/temp-$LINODE_ID/etc/rc.local
  
  # Reboot
  curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{\"config_id\": $BLOCK_CONFIG_ID}" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot | jq
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

  sleep 10
  curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" -X POST\
      https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot | jq
}

stage3() {

  export LINODE_ID=`dmidecode -t1 | grep Serial | awk '{print $3}'`
  if ! [ $LINODE_ID -gt 0 ]; then
    echo "Invalid LinodeID"
    exit
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

  if ! [ -f /usr/bin/wimmount ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt update
    apt install -yq wimtools genisoimage libwin-hivex-perl
  fi

  if ! [ -f /snap/bin/distrobuilder ]; then
    snap install distrobuilder --classic
  fi

  if ! [ -f woeusb.sh ]; then
    wget -O woeusb.sh https://github.com/WoeUSB/WoeUSB/releases/download/v5.2.4/woeusb-5.2.4.bash
    chmod +x woeusb.sh
  fi
  if ! [ -f windows.iso ]; then
    if [ $INSTALL_WINDOWS_VERSION == "2k22" ]; then
      wget -q -O windows.iso $W2K22_ISO_URL
    fi
    if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
      wget -q -O windows.iso $W11_ISO_URL
    fi
  fi
  if ! [ -f windows.iso ]; then
    echo "Error: No valid ISO found."
    exit
  fi

  if ! [ -f windows_virtio.iso ]; then
    distrobuilder repack-windows windows.iso windows_virtio.iso --windows-version=$INSTALL_WINDOWS_VERSION
  fi
  if ! [ -f windows_virtio.iso ]; then
    echo "Error: No valid VirtIO ISO found."
    exit
  fi

  if ! [ -a /dev/sdb1 ]; then
    fdisk /dev/sdb < /root/fdisk.txt
  fi
  mkfs.fat /dev/sdb1
  ./woeusb.sh --partition windows_virtio.iso /dev/sdb1
  mount /dev/sdb1 /mnt
  cp /root/autounattend.xml /mnt
  umount /mnt
  rm /etc/rc.local
  curl -sH "Content-Type: application/json" \
      -H "Authorization: Bearer $TOKEN" \
      -X POST -d "{\"config_id\": $WINDOWS_CONFIG_ID}" \
      https://api.linode.com/v4/linode/instances/$LINODE_ID/reboot | jq
}

createfdisk() {
cat > /root/fdisk.txt<<EOF
n
p
1
8192
+6G
n
p
2
12591104

t
1
c
t
2
c
a
1
w
EOF
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
[B<?xml version="1.0" encoding="utf-8"?>
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
                            <Value>Windows 11 Pro</Value>
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
                <Enabled>true</Enabled>
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
  echo "Installing Windwos Server"
fi

if [ $INSTALL_WINDOWS_VERSION == "w11" ]; then
  echo "Installing Windows 11"
fi

if [ $STAGE == 1 ]; then
  createfdisk
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
