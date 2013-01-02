#!/usr/bin/env perl

use strict;
use warnings;
use bignum;
use POSIX 'strftime';
use IPC::System::Simple qw(capture);


my $weight_increment = 0.01;
my $sleep_interval = 3;

# make STDOUT hot
$| = 1;

# read in user argument
my $osd = $ARGV[0];

# generate array of local OSDs
my @osd_list;
for (capture("ceph-conf -l osd. --filter-key-value host=\$(hostname)")) {
	chomp;
	push (@osd_list,$_);
}

# validate user input
unless (defined $osd && grep(/^osd\.$osd$/, @osd_list)) {
	print "You must specify a single OSD that lives on this host!\n";
	exit 1;
}

# get the state of the OSD
my ($osd_state, $osd_quorum, $osd_weight) = (capture('ceph osd dump') =~ /osd\.$osd\s+(up|down)\s+(in|out)\s+weight\s+(\d+\.?\d*)\s+.+/);

# exit if the OSD is already at weight 1
if ($osd_weight == 1) {
	print "osd.$osd is already at weight 1.\n";
	exit 0;
}

# if the osd is down and out
if ($osd_state eq 'down' && $osd_quorum eq 'out') {
	&timestamp; print "osd.$osd is down and out.\n";
	&timestamp; print "Setting weight of osd.$osd to 0... ";	capture("ceph osd reweight osd.$osd $osd_weight"); print "done.\n";
	&timestamp; print "Starting osd.$osd... "; capture("service ceph start osd.$osd > /dev/null 2>&1"); print "done.\n";
}

# wait for healthy cluster
&wait_health_good();

###########
# this can almost certainly be done better
if (($osd_weight + $weight_increment) > 1) {
	$weight_increment = (1 - $osd_weight);
}

for (my $weight = ($osd_weight + $weight_increment); $weight <= 1; $weight += $weight_increment) {
	&timestamp; print "Setting weight of osd.$osd to $weight... "; capture("ceph osd reweight $osd $weight"); print "done.\n";
	&wait_health_bad();
	&wait_health_good();
	&timestamp; print "Sleeping for $sleep_interval seconds... "; sleep $sleep_interval; print "done.\n";
}

($osd_state, $osd_quorum, $osd_weight) = (capture('ceph osd dump') =~ /osd\.$osd\s+(up|down)\s+(in|out)\s+weight\s+(\d+\.?\d*)\s+.+/);

if ($osd_weight ne 0) {
	&timestamp; print "Setting weight of osd.$osd to 1... "; capture("ceph osd reweight $osd 1"); print "done.\n";
	&wait_health_bad();
	&wait_health_good();
}

&timestamp; print "Reweighting of osd.$osd complete!\n\n";
###########

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
	&timestamp; print "Waiting for healthy cluster... ";
	while () {
		chomp (my $health = capture('ceph health'));
		if ($health ne "HEALTH_OK") {
			sleep 1;
		} else {
			print "done.\n";
			return;
		}
	}
}
