#!/bin/bash

# Rebuild OSD file systems to XFS and ensure they're in /etc/fstab

set -eu
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

function die { echo "Error: $1" 1>&2 ; usage ; }
function usage { echo "Usage: $0 [-o OSDNUM|-a]" ; exit 1 ; }

function rebalance {
    while true ; do
        read OSDCOUNT OSDUP OSDIN <<< $(ceph osd stat | awk '{print $2 " " $4 " " $6}')
        HEALTH=$(ceph health)
        if [ "$OSDCOUNT" -eq "$OSDUP" -a "$OSDCOUNT" -eq "$OSDIN" -a "$HEALTH" == "HEALTH_OK" ] ; then break ; fi
        echo "$HEALTH - $OSDUP/$OSDCOUNT OSDs up, $OSDIN/$OSDCOUNT OSDs in - waiting"
        sleep 30
    done
}

OSDLIST=""
while getopts "o:a" OPTION ; do
     case $OPTION in
         a)
            OSDLIST=$(ceph-conf -l osd. --filter-key-value host=$(hostname -s) | awk -F "." '{print $2}')
            ;;
         o)
            test "$OPTARG" -ge 0 || die "invalid OSD number: $OPTARG"
            OSDLIST=$OPTARG
            ;;
         *)
            usage
            ;;
     esac
done
test -n "$OSDLIST" || die "please use -o \$OSD or -a"

for OSD in $OSDLIST ; do
    DEVPATH=$(ceph-conf -n osd.$OSD "btrfs devs")
    DATAPATH=$(ceph-conf -n osd.$OSD "osd data")
    XFSLABEL=$(test $(dirname $DEVPATH) == "/dev/disk/by-label" && echo "-L $(basename $DEVPATH)")

    test $(ceph-conf -n osd.$OSD "host") == $(hostname -s) || die "osd.$OSD does not live on this host"

    rebalance
    
    echo "Rebuilding osd $OSD with XFS on $DEVPATH"
    echo "--------------------------------------"
    service ceph stop osd.$OSD
    ceph osd down $OSD
    ceph osd out $OSD

    rebalance

    ceph osd rm $OSD

    while true ; do
        if umount "$DATAPATH" ; then break ; fi
        sleep 2
    done

    mkfs.xfs -f $XFSLABEL "$DEVPATH"
    mount "$DEVPATH" "$DATAPATH"
    ceph osd create $OSD
    ceph-osd -i $OSD --mkfs --mkkey --mkjournal
    ceph auth add osd.$OSD osd 'allow *' mon 'allow rwx' -i $DATAPATH/keyring
    grep "$DEVPATH" /etc/fstab || echo -e "$DEVPATH\t$DATAPATH\txfs\tdefaults\t0\t2" >> /etc/fstab
    service ceph start osd.$OSD
done
