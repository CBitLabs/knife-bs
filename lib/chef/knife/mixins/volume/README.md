Volume Init Scripts
===================

Mixin containing a set of init scripts that are used to configure
volumes on system startup. Specifically it deals with RAID volumes,
ephemeral storage and bind mounts

# Ephemeral #
Installs an init script that on system startup (before hadoop init) will
either mount each individual drive or create a RAID of the instance
store. The number of drives to RAID is dependant upon the instance
type.

# EBS #
Also an init script whose purpose is to be more granular than mounting
via FSTAB. Because of 'temp' drives used for /tmp storage, these drives
must also be mounted before any hadoop services are started, however it
must be done after ephemeral drives are mounted. Init scripts are used
for run dependencies

### RAID ###
EBS Volume RAID array configuration

### Bind ###
Local filesystem *mounts*/**symlinks**
