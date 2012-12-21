#!/bin/bash

set -eu
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

function die { echo "Error: $1" 1>&2 ; usage ; }

function usage { echo "Usage: $0 [-o OSDNUM|-a]" ; exit 1 ; }

function rebalance {
	for HEALTH_CHECK in "HEALTH_WARN" "HEALTH_OK" ; do
	    echo -n "Waiting for $HEALTH_CHECK"
	    while true ; do
		    OSDCOUNT=$1
		    read OSDUP OSDIN <<< $(ceph osd stat | awk '{print $4 " " $6}')
		    HEALTH=$(ceph health | awk '{print $1}')
		    if [ "$OSDCOUNT" -eq "$OSDUP" -a "$OSDCOUNT" -eq "$OSDIN" -a "$HEALTH" == "$HEALTH_CHECK" ] ; then
			    echo " $HEALTH"
			    break
		    else
			    echo -n "."
		    fi
		    sleep 10
	    done
	done
}

function weightramp {
    for WEIGHT in $(seq -w "$1" "$1" 1) ; do
        ceph osd reweight "$2" "$WEIGHT"
        rebalance "$TOTALOSDCOUNT"
    done
    if [ $WEIGHT -lt 1 ] ; then
        ceph osd reweight "$2" "$WEIGHT"
        rebalance "$TOTALOSDCOUNT"
		fi
}

OSDLIST=""
WEIGHT_INCREMENT="0.01"
while getopts "o:a" OPTION ; do
	case $OPTION in
	a)
		OSDLIST=$(ceph-conf -l osd. --filter-key-value host=$(hostname -s) | awk -F "." '{print $2}')
		;;
	o)
		test "$OPTARG" -ge 0 || die "invalid OSD number: $OPTARG"
		OSDLIST=$OPTARG
		;;
    w)
		test "$OPTARG" -gt 0 -a "$OPTARG" -le 0.5 || die "invalid weight increment: $OPTARG"
		WEIGHT_INCREMENT=$OPTARG
		;;
	*)
		usage
		;;
	esac
done
test -n "$OSDLIST" || die "please use -o \$OSD or -a"

TOTALOSDCOUNT=$(ceph osd stat | awk '{print $2}')

HEALTH=$(ceph health | awk '{print $1}')

if [ "$HEALTH" -ne "HEALTH_OK" ]; then
    echo "Ceph cluster health is not HEALTH_OK - refusing to start"
    exit 1
fi

for OSD in $OSDLIST ; do
	DEVPATH=$(ceph-conf -n osd.$OSD "btrfs devs")
	DATAPATH=$(ceph-conf -n osd.$OSD "osd data")
	XFSLABEL=$(test $(dirname $DEVPATH) == "/dev/disk/by-label" && echo "-L $(basename $DEVPATH)")

	test $(ceph-conf -n osd.$OSD "host") == $(hostname -s) || die "osd.$OSD does not live on this host"

	echo "Rebuilding osd $OSD with XFS on $DEVPATH"
	echo "--------------------------------------"
	service ceph stop osd.$OSD
	ceph osd down $OSD
	ceph osd out $OSD

	rebalance $((TOTALOSDCOUNT-1))

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

	ceph osd reweight $OSD 0

	service ceph start osd.$OSD

	weightramp $WEIGHT_INCREMENT $OSD

done
