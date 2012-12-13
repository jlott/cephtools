osdconvert
==========

Convert ceph OSD file systems

This script is intended to be run on one node in a live ceph cluster. It will serially step through every osd file system (or one with the -o flag) and stop the service, reformat its file system to XFS, remount, add the mount point to fstab, restart the service, and wait for cluster health to return to OK before processing the next osd.

It tries to be very conservative about cluster health. It will not process any OSD unless cluster health is OK and every OSD in the cluster is up/in.
