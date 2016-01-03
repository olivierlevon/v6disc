#!/bin/bash

#
#	Script auto discovers IPv6 hosts on interface, and ping6 them
#
#	by Craig Miller		15 Dec 2015

#	
#	Assumptions:
#		All prefixes are assumed /64
#		Discovers _only_ RFC 4862 SLAAC addresses (MAC-based)
#
#
#	TODO: 
#		print only hosts validated with ping
#		x Add nmap option
#		


function usage {
               echo "	$0 - auto discover IPv6 hosts "
	       echo "	e.g. $0 -D -P "
	       echo "	-p  Ping discovered hosts"
	       echo "	-i  use this interface"
	       echo "	-L  show link-local only"
	       echo "	-D  Dual Stack, show IPv4 addresses"
	       echo "	-N  Scan with nmap -6 -sT"
	       echo "	-q  quiet, just print discovered hosts"
	       echo "	"
	       echo " By Craig Miller - Version: $VERSION"
	       exit 1
           }

VERSION=0.96

# initialize some vars
hostlist=""
INTERFACE=""
LINK_LOCAL=0
DUAL_STACK=0
NMAP=0
PING=0
DEBUG=0
QUIET=0

# commands needed for this script
ip="ip"
v4="./v4disc.sh"
nmap="nmap"
nmap_options=" -6 -sT -F "

DEBUG=0

while getopts "?hdpqi:LDN" options; do
  case $options in
    p ) PING=1
    	let numopts+=1;;
    q ) QUIET=1
    	let numopts+=1;;
    L ) LINK_LOCAL=1
    	let numopts+=1;;
    N ) NMAP=1
    	let numopts+=1;;
    D ) DUAL_STACK=1
    	let numopts+=1;;
    i ) INTERFACE=$OPTARG
    	let numopts+=2;;
    d ) DEBUG=1
    	let numopts+=1;;
    h ) usage;;
    \? ) usage	# show usage with flag and no value
         exit 1;;
    * ) usage		# show usage with unknown flag
    	 exit 1;;
  esac
done
# remove the options as cli arguments
shift $numopts

# check that there are no arguments left to process
if [ $# -ne 0 ]; then
	usage
	exit 1
fi

# check for nmap
if (( $NMAP == 1 )); then
	check=$(which $nmap)
	if (( $? == 1 )); then
		echo "ERROR: nmap not found, disabling nmap option"
		NMAP=0
	else
		# get nnap version, need 6+ to do OS ID
		nmap_version=$($nmap --version | tr -d '\n' | sed -r 's;Nmap version ([0-9]).*;\1;' )
		if (( $nmap_version > 5 )); then
			# add OS check if root - OS ID requires root
			root_check=$(id | sed -r 's;uid=([0-9]+).*;\1;')
			if (( $root_check == 0 )); then
				nmap_options="$nmap_options -O "
			fi
		fi; #version
		if (( $DEBUG == 1 )); then echo "DEBUG: nmap version:$nmap_version options:$nmap_options"; fi
	fi; #which nmap
fi



#======== Actual work performed by script ============


function log {
	#
	#	Common print function which doesn't print when QUIET != 0
	#
	if (( $QUIET == 0 )); then
		# echo string if not quiet
		if [ "$2" == "tab" ]; then
			echo -e $1 | tr ' ' '\t'
		else
			echo -e $1
		fi
	fi
}

function 62mac {
	#
	#	Returns MAC address from host portion of IPv6 address
	#
	host=$1
	#v6_mac=$(echo $host | cut -d ':' -f 5 )
	v6_mac=$(echo $host | sed -r 's;.*:([^ ]+);\1;' )
	# return v6_mac value
	echo $v6_mac
}

function router_addr {
	#
	#	Check if this is the router link-local address, then return ::1 
	#	Routers will NOT have a SLAAC address, they generate RAs, not listen to RAs
	#
	#	Assumption: routers are ::1

	host=$1	
	if [ "fe80:$host" == "$router_ll" ]; then
		# try route at :1
		host="::1"
		if (( $DEBUG == 1 )); then echo "DEBUG found the router entry"; fi
	fi
	echo $host
}

# if -i <intf> is set, then don't detect interfaces, just go with user input
intf_list=$INTERFACE
if [ "$INTERFACE" == "" ]; then
	# check interface(s) are up
	log "-- Searching for interface(s)"
	intf_list=""
	# Get a list of Interfaces which are UP
	intf_list=$($ip link | egrep -i '(state up|multicast,up)' | grep -v -i no-carrier | cut -d ":" -f 2 | cut -d "@" -f 1 )
	if (( $DEBUG == 1 )); then
		echo "DEBUG: listing interfaces $($ip link | egrep '^[0-9]+:')"
	fi

	# if no UP interfaces found, quit
	if [ "$intf_list" == "" ]; then
		echo "ERROR interface not found, sheeplessly quiting"
		exit 1
	else
		log "Found interface(s): $intf_list"
	fi
fi


#
#	Repeat foreach interface found
#

for intf in $intf_list
do
	# get list of prefixes on intf, filter out temp addresses
	prefix_list=$(ip addr show dev $intf | grep -v temp | grep inet6 | grep -v fe80 | sed -r 's;(noprefixroute|inet6|scope|global|dynamic|/64);;g' )
	plist=""
	# 
	#	Massage prefix list to only the first 64 bits of each prefix found
	#
	for prefix in $prefix_list
	do
		p=$(echo $prefix | cut -d ':' -f 1,2,3,4  )
		# fix if double colon prefixes
		p=$(echo $p | sed -r 's;(\w+:):[!-z]+;\1;' )
		plist="$plist $p"
		if (( $DEBUG == 1 )); then
			echo "DEBUG: $plist"
		fi
	done
	# remove duplicate prefixes
	prefix_list=$(echo $plist | tr ' ' '\n' | sort -u )
	
	log "-- INT:$intf	prefixs:$prefix_list"
	
	# exit this interface, if no IPv6 prefixes 
	if [ "$prefix_list" == "" ]; then
		log "No prefixes found."
		if (( $LINK_LOCAL == 0 )); then 
			log "Continuing to next interface..."
			continue
		fi
	fi


	# detect router, won't have a SLAAC address, get router link-local from route table
	router_ll=$($ip -6 route | grep default | grep -v unreachable | cut -d ' ' -f 3 )
	#router_ll=$($ip -6 route | grep default | grep -v unreachable  )
	if (( $DEBUG == 1 )); then echo "Router $router_ll"; fi


	# detect hosts on link
	log "-- Detecting hosts on $intf link"

	# trim any spaces on interface name
	i=$(echo "$intf" | tr -d " ")

	# ping6 all_nodes address, which will return a list of link-locals on the interface
	host_list=$(ping6 -c 2  -I $i ff02::1 | egrep 'icmp|seq=' | sort -u  | sed -r 's;.*:(:[^ ]+): .*;\1;' | sort -u)
	if [ "$host_list" == "" ]; then
		echo "Host detection not working, is IPv6 enabled on $intf?"
	else
		# Dual stack
		if (( $DUAL_STACK == 1 )); then
			#
			# Detect IPv6 addresses by ipv4 pinging subnet
			#
			v4_hosts=$($v4  -6 -q -i $intf)
			v6_hosts=$host_list
			for h in $v6_hosts
			do
				#unpack mac address from link-local address
				v6_mac=$(62mac $h)
				#echo $v6_mac
				# match mac address
				#
				#	Dual stack correlates IPv6 and IPv4 addresses by having a common MAC address
				#
				v4_host=$(echo $v4_hosts | tr ' ' '\n' | tr -d ':' | grep -- $v6_mac |  cut -d '|' -f 1)
				v6_host=$(echo $h | cut -d '|' -f 1)
				# create a tab delimited output
				log "fe80:$v6_host  $v4_host" "tab"
			done
		else
			for h in $host_list
			do
				# fe80 was trimmed earlier in the host detection loop, we add here for readability
				log "fe80:$h"
			done		
		fi; #end of dual stack
		#
		#	Allow running nmap on link-local only addresses with -L -N
		#
		if [ "$prefix_list" == "" ] && (( $LINK_LOCAL == 1 )); then
			if (( $NMAP == 1 )); then
				for h in $host_list
				do
					# scanning hosts discovered with nmap
					log "\n-- HOST:fe80:$h"
					$nmap $nmap_options "fe80:$h%$intf"
				done
			fi
		fi

	fi; #end if host list blank


	# don't display discovered hosts, if there is no prefix
	if [ "$prefix_list" != "" ]; then

		# ping the SLAAC addresses
		if (( $PING == 1 )); then
			log "-- Ping6ing discovered hosts"
		else
			log "-- Discovered hosts"
		fi

		# flag hoststr if ping or nmap
		let options_sum=$PING+$NMAP
		if (( $options_sum > 0 )); then
			hoststr="-- HOST:"
		else
			hoststr=""
		fi

		for prefix in $prefix_list
		do
			for host in $host_list
			do	
				# print spacer
				if (( $options_sum != 0 )); then
					log " "
				fi		
				# list hosts found
				if (( $DUAL_STACK == 1 )); then
					#v6_mac=$(echo $host | cut -d ':' -f 5 )
					# pull MAC from IPv6 address
					v6_mac=$(62mac $host)
					# compare with IPv4 list (which includes MACs)
					v4_host=$(echo $v4_hosts | tr ' ' '\n' | tr -d ':' | grep -- $v6_mac | cut -d '|' -f 1 )
					echo "$hoststr$prefix$(router_addr $host)	$v4_host"
				else
					echo "$hoststr$prefix$(router_addr $host)"
				fi

				if (( $PING == 1 )); then
					# ping6 hosts discovered
					ping6 -c1 $prefix$(router_addr $host)
				fi
				if (( $NMAP == 1 )); then
					# scanning hosts discovered with nmap
					$nmap $nmap_options "$prefix$(router_addr $host)"
				fi

			done; #for host
		done; #for prefix
	fi; # if prefix_list not empty
#nd for intf_list
done

#all pau
log "-- Pau"

