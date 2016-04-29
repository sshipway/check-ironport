#!/usr/bin/perl
# vim:ts=4
#
# Check Ironport status
#
# check_ironport -H hostname -U username -P password [ -M | -N ]
#     ( -g gauge[,gauge...] | -c counter[,counter...] | -r rate[,rate...] |
#       -l license[,license...] )
#     [ -W warn[,warn...] -C crit[,crit...] ]
#
# Works by fetching the XML page and parsing out the objects.
# -M MRTG mode requires 1 or 2 items, -N nagios mode can be any number
# Threholds must be of same quantity as items
#
# 0.3 : Add license checks; check for unknown counter/rate/gauge name;
#       use 5min rates and not 1min rates.
#
####################################################################
# LWP::AutoUA
# User Agent with overrides for the authentication functions
package LWP::AutoUA;
require LWP::UserAgent;
@ISA = qw(LWP::UserAgent);
my($USER,$PASS) = ('','');
sub get_basic_credentials(@) { return ($USER,$PASS); }
sub set_credentials(@) { ($obj,$USER,$PASS)=@_; }
package main;

use strict;
use LWP;
use Getopt::Std;
use Text::ParseWords;
use LWP::UserAgent;
use vars qw/$opt_L $opt_H $opt_U $opt_P $opt_M $opt_N $opt_h $opt_g $opt_d $opt_c $opt_r $opt_W $opt_C $opt_p $opt_S $opt_l/;

###########################################################################
my($VERSION) = "0.3";
###########################################################################
my($NAGIOS) = 1;
my($DEBUG) = 0;
my($HOST) = 'localhost';
my($PORT) = 443;
my($SSL) = 0;
my($TIMEOUT) = 10;
my($STATUS) = 0;
my($MESSAGE) = "";
my($USER) = 'guest';
my($PASS) = 'password';
my($A,$B) = ('U','U');
my($UPTIME) = '';
my($PERF) = "";
###########################################################################
my(%counters,%gauges,%rates,%features);
my(@l,@c,@g,@r,@warn,@crit,@values);
###########################################################################
sub do_help() {
	print "$0 [-d] [-N|-M] -H host [-p port] [-S] -U user -P password\n";
	print "    ( -c counter[,counter...] | -g gauge[,gauge...] | -r rate[,rate...] \n";
	print "    | -l license[,license...] )\n";
	print "    [ -w warn[,warn...] -c crit[,crit...] ]\n\n";
	print "-L : List available counters/gauges/rates (requires host and login info)\n";
	print "-N : Nagios\n-M : MRTG\n-S : Use SSL\n\nVersion $VERSION\n";
}
sub getdata() {
	# Create and set up the useragent
	my($req,$res,$u,$xml);
	my($ua);
	my($n,$v);

	$u = "http".($SSL?"s":"")."://$HOST:$PORT/xml/status";
	print "URL: $u\n" if($DEBUG);
	$ua = LWP::AutoUA->new;
	$ua->set_credentials($USER,$PASS);
	$ua->agent("check_ironport/$VERSION");
	$ua->timeout($TIMEOUT) ;
	$req = HTTP::Request->new(GET=>$u);
    $res = $ua->request($req);
	print "Response: ".$res->status_line."\n" if($DEBUG);
    if(!$res or !$res->is_success) {
        $STATUS = 3; $MESSAGE = "Error: Unable to retrieve status"; 
		$MESSAGE .= ": ".$res->status_line if($res);
		return; 
	}
	# We now have the page in $res->content
	$xml = $res->content;
	print "$xml\n" if($DEBUG>1);
	if($xml=~/birth_time\s+timestamp="([^"]+)"/) { $UPTIME=$1; }
	while( $xml =~ s/<counter\s+name="([^"]+)"\s+reset="\d+"\s+uptime="\d+"\s+lifetime="(\d+)"// ) {
		$counters{$1}=$2; print "Counter $1 = $2\n" if($DEBUG);
	}
	while( $xml =~ s/<rate\s+name="([^"]+)"\s+last_1_min="\d+"\s+last_5_min="(\d+)"// ) {
		$rates{$1}=$2; print "Rate $1 = $2\n" if($DEBUG);
	}
	while( $xml =~ s/<gauge\s+name="([^"]+)"\s+current="(\d+)"// ) {
		($n,$v) = ($1,$2);
		if( $v =~ s/(KMGT)// ) {
			$v *= 1024 if($1 eq 'K');
			$v *= 1024000 if($1 eq 'M');
			$v *= 1024000000 if($1 eq 'G');
			$v *= 1024000000000 if($1 eq 'T');
		}
		$gauges{$n}=$v; print "Gauge $n = $v\n" if($DEBUG);
	}
	while( $xml =~ s/<feature\s+name="([^"]+)"\s+time_remaining="(\d+)"// ) {
		my $l = lc $1;
		$features{$l}=int($2/(3600*24));  # convert to days
		print "Feature $l = ".$features{$l}."\n" if($DEBUG);
	}
}
sub do_list() {
	getdata();
	print "COUNTERS (constantly increasing, good for MRTG):\n";
	foreach ( sort keys %counters ) { printf "  %-30s = %12d\n",$_,$counters{$_};}
	print "\nRATES (in items per minute: MRTG should divide by 60 for per-second):\n";
	foreach ( sort keys %rates ) { printf "  %-30s = %12.2f\n",$_,$rates{$_}; }
	print "\nGAUGES (point-in-time measurement; utilization figures given in %):\n";
	foreach ( sort keys %gauges ) { printf "  %-30s = %12.2f\n",$_,$gauges{$_}; }
	print "\nLICENSES (days remaining)\n";
	foreach ( sort keys %features ) { printf "  %-30s = %9d\n",('"'.$_.'"'),$features{$_}; }
}

###########################################################################
# MAIN CODE STARTS HERE

getopts('LdhSH:U:P:MNg:c:r:W:C:p:l:');

if($opt_h) {
	do_help();
	exit 0;
}
$DEBUG = 1 if($opt_d);
$NAGIOS = 1 if($opt_N);
$NAGIOS = 0 if($opt_M);
$HOST = $opt_H if($opt_H);
$PORT = $opt_p if($opt_p);
$USER = $opt_U if($opt_U);
$PASS = $opt_P if($opt_P);
$SSL = 1 if($opt_S or ($PORT==443) );
if($opt_L) { do_list(); exit(0); }

if(((defined $opt_c)+(defined $opt_r)+(defined $opt_g)+(defined $opt_l))!=1) {
	print "U\nU\n\n" if(!$NAGIOS);
	print "Must have exactly one of -c, -r, -g, -l\n";
	exit 3 if($NAGIOS);
	exit 0;
}
if(!$HOST) {
	print "U\nU\n\n" if(!$NAGIOS);
	print "Must specify a hostname with -H\n";
	exit 3 if($NAGIOS);
	exit 0;
}

@l = @c = @g = @r = @warn = @crit = ();
@c = split /,/,$opt_c if($opt_c);
@g = split /,/,$opt_g if($opt_g);
@r = split /,/,$opt_r if($opt_r);
@l = split /,/,$opt_l if($opt_l);
@warn = split /,/,$opt_W if($opt_W);
@crit = split /,/,$opt_C if($opt_C);
getdata();

if(!$STATUS) {
	my($i) = 0;
	@values = ();
	if(@c) {
		foreach (@c) { 
			push @values, $counters{$_}; 
			if( defined $counters{$_} ) {
				$MESSAGE .= "$_=".$counters{$_}." ";
			} else {
				$MESSAGE .= "$_=Undefined "; $STATUS = 3;
			}
		}
	} elsif(@g) {
		foreach (@g) { 
			push @values, $gauges{$_}; 
			if( defined $gauges{$_} ) {
				$MESSAGE .= "$_=".$gauges{$_}." ";
				$PERF .= "$_=".$gauges{$_}.";".$warn[$i].";".$crit[$i].";0; ";
			} else {
				$MESSAGE .= "$_=Undefined "; $STATUS = 3;
			}
			$i += 1;
		}
	} elsif(@r) {
		foreach (@r) { 
			push @values, $rates{$_}; 
			if( defined $rates{$_} ) {
				$MESSAGE .= "$_=".$rates{$_}." ";
				$PERF .= "$_=".$gauges{$_}.";".$warn[$i].";".$crit[$i].";0; ";
			} else {
				$MESSAGE .= "$_=Undefined "; $STATUS = 3;
			}
			$i += 1;
		}
	} else {
		foreach (@l) { 
			my $l = lc $_;
			my $dy = $features{$l};
			push @values, $dy; 
			if( defined $dy ) {
				if($dy < 0) {
				$MESSAGE .= "$l = Perpetual license\\n";
				} else {
				$MESSAGE .= "$l = $dy days remaining\\n";
				}
			} else {
				$MESSAGE .= "$l: Not recognised\\n";
				$STATUS = 3;
			}
		}
	}

	if($NAGIOS) {
		foreach my $i (0...$#values) {
			next if(!defined $i or !defined $warn[$i] or !defined $crit[$i]);
			if($crit[$i] >= $warn[$i] ) {
				if($values[$i]>=$crit[$i]) {
					$STATUS = 2; last;
				} elsif($values[$i]>=$warn[$i]) {
					$STATUS = 1;
				}
			} else {
				if($values[$i]<=$crit[$i]) {
					$STATUS = 2; last;
				} elsif($values[$i]<=$warn[$i]) {
					$STATUS = 1;
				}
			}
		}
	}
}

if(!$NAGIOS) {
	$A = $values[0] if(defined $values[0]);
	$B = $values[1] if(defined $values[1]);
    print "$A\n$B\n$UPTIME\n";
    print "$MESSAGE\n";
    exit 0;
} else {
    print "$MESSAGE|$PERF\n";
    exit($STATUS);
}


exit 0;
