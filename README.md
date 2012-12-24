osdconvert
==========

Convert ceph OSD file systems

This script is intended to be run on one node in a live ceph cluster. It will serially step through every osd file system and stop the service, reformat its file system to XFS, remount, restart the service, and wait for cluster health to return to OK before processing the next osd.

It tries to be very conservative about cluster health. It will not process any OSD unless cluster health is OK and every OSD in the cluster is up/in. It also slowly ramps up OSD weight 1% at a time to minimize impact to other IO during the process.

This script makes a few assumptions about its environment
 - we are converting from btrfs to XFS
 - we want labeled file systems, and are using /dev/disk/by-label in ceph.conf
 - we want converted file systems to be present in /etc/fstab
