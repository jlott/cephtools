#!/usr/bin/env perl

use strict;
use warnings;
use bignum;
use POSIX 'strftime';
use IPC::System::Simple qw(capture);

$| = 1;

my @osds;
for (capture("ceph-conf -l osd. --filter-key-value host=\$(hostname)")) {
	chomp;
	push (@osds,$_);
}

foreach (@osds) {
	if (`mount -t xfs | grep $_`) {
		&timestamp; print "$_ appears to be mounted as XFS. Skipping.\n";
	} else {
		&wait_health_good(0);
		&timestamp(); print "Starting conversion of $_\n";
		my ($num) = ($_ =~ m/osd\.(\d+)/);
		chomp (my $path = capture("ceph-conf -n $_ \"btrfs devs\""));
		chomp (my $mountpoint = capture("ceph-conf -n $_ \"osd data\""));
		my $label = "$_-data";
		&timestamp; print "Stopping service for $_... "; capture("service ceph stop $_"); print "done.\n";
		&timestamp; print "Marking $_ down... "; capture("ceph osd down $num"); print "done.\n";
		&timestamp; print "Marking $_ out... "; capture("ceph osd out $num"); print "done.\n";
		&wait_health_bad();
		&wait_health_good(1);
		&timestamp; print "Removing $_ from the crush map... "; capture("ceph osd rm $num"); print "done.\n";
		# FIXME this should really time out and die eventually
		&timestamp; print "Waiting for file handles on $mountpoint to be released... "; do { sleep 1; } while (`lsof | grep $mountpoint`); print "done.\n";
		&timestamp; print "Unmounting $mountpoint... "; capture('umount',$mountpoint); print "done.\n";
		&timestamp; print "Formatting $path as XFS... "; capture("mkfs.xfs -f -L $label $path"); print "done.\n";
		&timestamp; print "Mounting $path at $mountpoint... "; capture("mkdir -p $mountpoint"); capture("mount $path $mountpoint"); print "done.\n";
		&timestamp; print "Adding $_ to the crush map... "; capture("ceph osd create $num"); print "done.\n";
		&timestamp; print "Creating $_ file system, key, and journal... "; capture("ceph-osd -i $num --mkfs --mkkey --mkjournal > /dev/null 2>&1"); print "done.\n";
		&timestamp; print "Adding $_ key to the cluster... "; capture("ceph auth add $_ osd 'allow *' mon 'allow rwx' -i $mountpoint/keyring > /dev/null 2>&1"); print "done.\n";
		unless (`grep $mountpoint /etc/fstab`) { open (FSTAB, '>>/etc/fstab'); print FSTAB "$path\t$mountpoint\txfs\tdefaults\t0\t2\n"; close (FSTAB); };
		&timestamp; print "Setting initial weight of $_ to 0... "; capture("ceph osd reweight $num 0"); print "done.\n";
		&timestamp; print "Starting service for $_... "; capture("service ceph start $_ > /dev/null 2>&1"); print "done.\n";
		for (my $weight = 0.01; $weight <= 1; $weight += 0.01) {
			&timestamp; print "Setting weight of $_ to $weight... "; capture("ceph osd reweight $num $weight"); print "done.\n";
			&wait_health_bad();
			&wait_health_good(0);
		}
		&timestamp; print "Conversion of $_ complete!\n\n";
	}
}

sub timestamp {
	my $now_string = strftime "%b %e %H:%M:%S : ", localtime;
	print $now_string;
}

# These two subs are a dirty hack for a race condition. When performing an
# action that results in an unhealthy cluster, there is a variable amount of
# time before 'ceph health' will show it as unhealthy. Other times, the cluster
# will go healthy/unhealthy/healthy before we even get a chance to check it.
# With wait_health_bad(), we wait a specified period of time for an unhealthy
# cluster before continuing on. wait_health_good() waits indefinitely for a
# healthy cluster.

# Wait up to 60 seconds for an unhealthy cluster
sub wait_health_bad {
	&timestamp; print "Waiting for unhealthy cluster... ";
	my $i = 0;
	while ($i < 60) {
		chomp (my $health = capture('ceph health'));
		if ($health eq "HEALTH_OK") {
			$i++;
			sleep 1;
		} else {
			print "done.\n";
			return;
		}
	}
	print "timed out.\n";
}

# Wait indefinitely for a healthy cluster
sub wait_health_good {
	my $allowed_down = $_[0];
	&timestamp; print "Waiting for healthy cluster... ";
	while () {
		my ($osd_tot, $osd_up, $osd_in) = (`ceph osd stat` =~ /e\d+: (\d+) osds: (\d+) up, (\d+) in/);
		$osd_tot -= $allowed_down;
		chomp (my $health = capture('ceph health'));
		if ($health ne "HEALTH_OK" || $osd_tot ne $osd_up || $osd_tot ne $osd_in) {
			sleep 1;
		} else {
			print "done.\n";
			return;
		}
	}
}
