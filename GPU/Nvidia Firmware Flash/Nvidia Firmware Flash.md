Ref: https://myminingrig.com/how-to-flash-a-gpu-bios-with-nvflash/  
Ref: https://www.techpowerup.com/download/nvidia-nvflash/  
Ref: https://support.hpe.com/connect/s/softwaredetails?language=en_US&collectionId=MTX-bdee89928ef4480f  
  
Engineering Sample Card:
```text
SKU: 699-2G133-0200-TS2

PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 --version
NVIDIA Firmware Update Utility (Version 5.867.0)
Copyright (C) 1993-2024, NVIDIA Corporation. All rights reserved.

Reading EEPROM (this operation may take up to 30 seconds)

Redundant Firmware    : Instance 0 (Identical)
Sign-On Message       : PG133 SKU 200 VGA BIOS
Build GUID            : 47CEB145082D40418D059A6092991FF0
Build Number          : 29194928
IFR Subsystem ID      : 10DE-145A
Subsystem Vendor ID   : 0x10DE
Subsystem ID          : 0x145A
Version               : 94.02.3E.00.03
Image Hash            : N/A
Product Name          : GPU Board
Device Name(s)        : Graphics Device
Board ID              : 0x0240
Vendor ID             : 0x10DE
Device ID             : 0x2235
Hierarchy ID          : Normal Board
Chip SKU              : 895-0
Project               : G133-0200
Build Date            : 10/13/20
Modification Date     : 10/14/20
UEFI Version          : No Version Found or Out-dated (  )
UEFI Variant ID       : No Variant ID Found ( No Variant ID Found )
UEFI Signer(s)        : Unknown signer
XUSB-FW Version ID    : N/A
XUSB-FW Build Time    : N/A
InfoROM Version       : G133.0200.00.05
InfoROM Backup        : Present
License Placeholder   : Present
GPU Mode              : Compute
CEC OTA-signed Blob   : Present



PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 .\a40ebay\g133_0200_895__94025C0003-94025C000F-prod.nvr
NVIDIA Firmware Update Utility (Version 5.867.0)
Copyright (C) 1993-2024, NVIDIA Corporation. All rights reserved.

Checking for matches between display adapter(s) and image(s)...

Reading EEPROM (this operation may take up to 30 seconds)

WARNING: None of the firmware image compatible Board ID's
match the Board ID of the adapter.
  Adapter Board ID:        0240
  Firmware image Board ID: 0296

Error : Board ID mismatch.
No matches found.

Results:
 Index | Match | Flash | Name
  <00>     *             Graphics Device  (10DE,2235,10DE,145A) S:00, B:81
Nothing changed!
ERROR: Failed to update display adapter firmware.



PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflashk --index=0 -6 .\a40ebay\g133_0200_895__94025C0003-94025C000F-prod.nvr
nvflashk pre-release
github.com/notfromstatefarm/nvflashk - Safer GUI version with autorecovery coming by September!

Checking for matches between display adapter(s) and image(s)...

Reading EEPROM (this operation may take up to 30 seconds)

WARNING: None of the firmware image compatible Board ID's
match the Board ID of the adapter.
  Adapter Board ID:        0240
  Firmware image Board ID: 0296
Board ID mismatch

Board ID mismatch bypassed!
This could be dangerous. It could also get you a high score..

==BACK UP YOUR BIOS TO STAY SAFE==
Type "YES" to continue sending it:
YES

Bypassing the Board ID mismatch

Current      - Version:94.02.3E.00.03 ID:10DE:2235:10DE:145A
               GPU Board (Normal Board)
Replace with - Version:94.02.5C.00.03 ID:10DE:2235:10DE:145A
               GPU Board (Normal Board)
You are intending to flash the VBIOS firmware image through CEC.
Are you sure you want to continue?
Press 'y' to continue (any other key to abort): y

[==================================================] 100 %

Flashed firmware successfully.
Reboot and say hi to @kefinator on discord.gg/overclock


Firmware update process is completed.
No more matches found.

Results:
 Index | Match | Flash | Name
  <00>     *       *     Graphics Device  (10DE,2235,10DE,145A) S:00, B:81

Firmware update process is completed.
Reboot and say hi to @kefinator on discord.gg/overclock



PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 --list
NVIDIA Firmware Update Utility (Version 5.867.0)
Copyright (C) 1993-2024, NVIDIA Corporation. All rights reserved.

NVIDIA display adapters present in system:
<0> Graphics Device      (10DE,2235,10DE,145A) S:00,B:81,D:00,F:00
PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 --version
NVIDIA Firmware Update Utility (Version 5.867.0)
Copyright (C) 1993-2024, NVIDIA Corporation. All rights reserved.

Reading EEPROM (this operation may take up to 30 seconds)

Redundant Firmware    : Instance 0 (Identical)
Sign-On Message       : PG133 SKU 200 VGA BIOS
Build GUID            : C1319E579D764A80A992D3795CDB5DD6
Build Number          : 29403198
IFR Subsystem ID      : 10DE-145A
Subsystem Vendor ID   : 0x10DE
Subsystem ID          : 0x145A
Version               : 94.02.5C.00.03
Image Hash            : N/A
Product Name          : GPU Board
Device Name(s)        : Graphics Device
Board ID              : 0x0296
Vendor ID             : 0x10DE
Device ID             : 0x2235
Hierarchy ID          : Normal Board
Chip SKU              : 895-0
Project               : G133-0200
Build Date            : 12/08/20
Modification Date     : 12/08/20
UEFI Version          : No Version Found or Out-dated (  )
UEFI Variant ID       : No Variant ID Found ( No Variant ID Found )
UEFI Signer(s)        : Unknown signer
XUSB-FW Version ID    : N/A
XUSB-FW Build Time    : N/A
InfoROM Version       : G133.0200.00.05
InfoROM Backup        : Present
License Placeholder   : Present
GPU Mode              : Compute
CEC OTA-signed Blob   : Present
```
Retail Card:
```text
PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 --save .\a40og\backup.rom

PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 --list
NVIDIA Firmware Update Utility (Version 5.867.0)
Copyright (C) 1993-2024, NVIDIA Corporation. All rights reserved.

NVIDIA display adapters present in system:
<0> Graphics Device      (10DE,2235,10DE,145A) S:00,B:81,D:00,F:00
PS Microsoft.PowerShell.Core\FileSystem::\\172.16.1.100\iso\Nvidia\nvflash_5.867> .\nvflash64 --version
NVIDIA Firmware Update Utility (Version 5.867.0)
Copyright (C) 1993-2024, NVIDIA Corporation. All rights reserved.

Reading EEPROM (this operation may take up to 30 seconds)

Redundant Firmware    : Instance 0 (Identical)
Sign-On Message       : PG133 SKU 200 VGA BIOS
Build GUID            : C1319E579D764A80A992D3795CDB5DD6
Build Number          : 29403198
IFR Subsystem ID      : 10DE-145A
Subsystem Vendor ID   : 0x10DE
Subsystem ID          : 0x145A
Version               : 94.02.5C.00.03
Image Hash            : N/A
Product Name          : GPU Board
Device Name(s)        : Graphics Device
Board ID              : 0x0296
Vendor ID             : 0x10DE
Device ID             : 0x2235
Hierarchy ID          : Normal Board
Chip SKU              : 895-0
Project               : G133-0200
Build Date            : 12/08/20
Modification Date     : 12/08/20
UEFI Version          : No Version Found or Out-dated (  )
UEFI Variant ID       : No Variant ID Found ( No Variant ID Found )
UEFI Signer(s)        : Unknown signer
XUSB-FW Version ID    : N/A
XUSB-FW Build Time    : N/A
InfoROM Version       : G133.0200.00.05
InfoROM Backup        : Present
License Placeholder   : Present
GPU Mode              : Physical display enabled
CEC OTA-signed Blob   : Present
```