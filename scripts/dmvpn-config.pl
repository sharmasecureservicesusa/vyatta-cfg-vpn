#!/usr/bin/perl
#
# Module: dmvpn-config.pl
#

use strict;
use lib "/opt/vyatta/share/perl5";

use constant IKELIFETIME_DEFAULT => 28800;    # 8 hours
use constant ESPLIFETIME_DEFAULT => 3600;     # 1 hour
use constant REKEYMARGIN_DEFAULT => 540;      # 9 minutes
use constant REKEYFUZZ_DEFAULT   => 100;
use constant INVALID_LOCAL_IP    => 254;
use constant VPN_MAX_PROPOSALS   => 10;

use Vyatta::TypeChecker;
use Vyatta::VPN::Util;
use Getopt::Long;
use Vyatta::Misc;
use NetAddr::IP;
use Vyatta::VPN::vtiIntf;

my $config_file;
my $init_script;
my $tunnel_context;
my $tun_id;
GetOptions(
    "config_file=s"  => \$config_file,
    "init_script=s"  => \$init_script,
    "tunnel_context" => \$tunnel_context,
    "tun_id=s"       => \$tun_id
);

my $LOGFILE          = '/var/log/vyatta/ipsec.log';

my $vpn_cfg_err   = "VPN configuration error:";
my $genout;
my $dh_disable;

$genout .= "# generated by $0\n\n";

#
# Prepare Vyatta::Config object
#
use Vyatta::Config;
my $vc    = new Vyatta::Config();
my $vcVPN = new Vyatta::Config();
$vcVPN->setLevel('vpn');

# check to see if the config has changed.
# if it has not then exit
my $ipsecstatus = $vcVPN->isChanged('ipsec');
if ( $ipsecstatus && $tunnel_context ) {
	# no sence to do same update twice, will be done via vpn context
	exit 0;
}
if ( !$ipsecstatus ) {
	my $tun_ip_changed = 0;
	my @tuns           = $vc->listNodes('interfaces tunnel');
	my @profs          = $vcVPN->listNodes('ipsec profile');
	foreach my $prof (@profs) {
		my @tuns = $vcVPN->listNodes("ipsec profile $prof bind tunnel");
		foreach my $tun (@tuns) {
			my $lip_old = $vc->returnOrigValue("interfaces tunnel $tun local-ip");
			my $lip_new = $vc->returnValue("interfaces tunnel $tun local-ip");
			if ( !( "$lip_old" eq "$lip_new" ) ) {
				if ($tun_ip_changed) {
					# tunnel $tun_id is not the last tunnel with updated local-ip, so skip
                    exit 0;
				}
				if ( "$tun" eq "$tun_id" ) {
					$tun_ip_changed = 1;
				}
			}
		}
	}
	if ( !$tun_ip_changed ) {
		exit 0;
	}
}
if ( $vcVPN->exists('ipsec') ) {
	#
	# Connection configurations
	#
	my @profiles     = $vcVPN->listNodes('ipsec profile');
	my $prev_profile = "";
	foreach my $profile (@profiles) {
		my $conf_header = 0;
		my $profile_ike_group = $vcVPN->returnValue("ipsec profile $profile ike-group");
		if ( !defined($profile_ike_group) || $profile_ike_group eq '' ) {
			vpn_die([ "vpn", "ipsec", "profile", $profile, "ike-group" ],
			"$vpn_cfg_err No IKE group specified for profile \"$profile\".\n");
		}
		elsif ( !$vcVPN->exists("ipsec ike-group $profile_ike_group") ) {
			vpn_die([ "vpn", "ipsec", "profile", $profile, "ike-group" ],
			"$vpn_cfg_err The IKE group \"$profile_ike_group\" specified for profile "
			. "\"$profile\" has not been configured.\n");
		}

		#
		# ESP group
		#
		my $profile_esp_group = $vcVPN->returnValue("ipsec profile $profile esp-group");
		if ( !defined($profile_esp_group) || $profile_esp_group eq '' ) {
			vpn_die([ "vpn", "ipsec", "profile", $profile, "esp-group" ],
			"$vpn_cfg_err No ESP group specified for profile \"$profile\".\n");
		}
		elsif ( !$vcVPN->exists("ipsec esp-group $profile_esp_group") ) {
			vpn_die([ "vpn", "ipsec", "profile", $profile, "esp-group" ],
			"$vpn_cfg_err The ESP group \"$profile_esp_group\" specified "
			. "for profile \"$profile\" has not been configured.\n");
		}

		#
		# Authentication mode
		#
		#
		# Write shared secrets to ipsec.secrets
		#
		my $auth_mode = $vcVPN->returnValue("ipsec profile $profile authentication mode");
		my $psk = '';
		if ( !defined($auth_mode) || $auth_mode eq '' ) {
			vpn_die(
				[ "vpn", "ipsec", "profile", $profile, "authentication" ],
				"$vpn_cfg_err No authentication mode for profile \"$profile\" specified.\n"
			);
		}
		elsif ( defined($auth_mode) && ( $auth_mode eq 'pre-shared-secret' ) ) { 
			$psk = $vcVPN->returnValue("ipsec profile $profile authentication pre-shared-secret");
			my $orig_psk = $vcVPN->returnOrigValue("ipsec profile $profile authentication pre-shared-secret");
			$orig_psk = "" if ( !defined($orig_psk) );
			if ( $psk ne $orig_psk && $orig_psk ne "" ) {
				print "WARNING: The pre-shared-secret will not be updated until the next re-keying interval\n";
				print "To force the key change use: 'reset vpn ipsec-peer'\n";
			}
			if ( !defined($psk) || $psk eq '' ) {
				vpn_die(
					[ "vpn", "ipsec", "profile", $profile, "authentication" ],
					"$vpn_cfg_err No 'pre-shared-secret' specified for profile \"$profile\""
					. " while 'pre-shared-secret' authentication mode is specified.\n"
				);
			}
		}
		else {
			vpn_die(
				[ "vpn", "ipsec", "profile", $profile, "authentication" ],
				"$vpn_cfg_err Unknown/unsupported authentication mode \"$auth_mode\" for profile "
				. "\"$profile\" specified.\n"
			);
		}

		my @tunnels = $vcVPN->listNodes("ipsec profile $profile bind tunnel");
		foreach my $tunnel (@tunnels) {
			#
			# Check whether this tunnel is already in some profile
			#
			foreach my $prof (@profiles) {
				if ( $prof != $profile ) {
					if ( $vcVPN->exists("ipsec profile $prof bind tunnel $tunnel") )
                    {
						vpn_die(["vpn",  "ipsec",  "profile", $profile,"bind", "tunnel", $tunnel],
						"$vpn_cfg_err Tunnel \"$tunnel\" is already configured in profile \"$prof\".");
					}
				}
			}

			my $needs_passthrough = 'false';
			my $tunKeyword        = 'tunnel ' . "$tunnel";

			if ( $conf_header eq 0 ) {
				$genout .= "connections {\n";
				$conf_header = 1;
			}

			my $conn_head = "\tdmvpn-$profile-$tunnel {\n";
			$genout .= $conn_head;

			my $lip = $vc->returnValue("interfaces tunnel $tunnel local-ip");
			my $leftsourceip = undef;

			#
			# Write IKE configuration from group
			#
			my $ikelifetime = IKELIFETIME_DEFAULT;
			$genout .= "\t\tproposals = ";
			my $ike_group = $vcVPN->returnValue("ipsec  profile $profile ike-group");
			if ( defined($ike_group) && $ike_group ne '' ) {
				my @ike_proposals = $vcVPN->listNodes("ipsec ike-group $ike_group proposal");
				my $first_ike_proposal = 1;
				foreach my $ike_proposal (@ike_proposals) {
					#
					# Get encryption, hash & Diffie-Hellman  key size
					#
					my $encryption = $vcVPN->returnValue("ipsec ike-group $ike_group proposal $ike_proposal encryption");
					my $hash = $vcVPN->returnValue("ipsec ike-group $ike_group proposal $ike_proposal hash");
					my $dh_group = $vcVPN->returnValue("ipsec ike-group $ike_group proposal $ike_proposal dh-group");

					if ( defined($dh_group) ) {
						$dh_disable = 1;
					}

					#
					# Write separator if not first proposal
					#
					if ($first_ike_proposal) {
						if ( !defined($dh_group) ) {
							vpn_die(["vpn","ipsec","profile", $profile,"bind","tunnel", $tunnel],"$vpn_cfg_err 'dh-group' must be specified in ".
									"ike-group \"$ike_group\" proposal \"$ike_proposal\"  dh-group. \n");
						}
						$first_ike_proposal = 0;
					}
					else {
						$genout .= ",";
					}

					#
					# Write values
					#
					if ( defined($encryption) && defined($hash) ) {
						$genout .= "$encryption-$hash";
						if ( defined($dh_group) ) {
							my $cipher_out = get_dh_cipher_result($dh_group);
							if ($cipher_out eq 'unknown') {
								vpn_die(["vpn","ipsec","profile", $profile,"bind","tunnel", $tunnel],"$vpn_cfg_err Invalid 'dh-group' $dh_group specified in ".
								"profile \"$profile\" for $tunKeyword.  Only 2, 5, or 14 through 26 accepted.\n");
							} else {
								$genout .= "-$cipher_out";
							}
						}
					}
				}
				$genout .= "\n";
				
				#
				# Get IKE version setting
				#
				my $key_exchange = $vcVPN->returnValue("ipsec ike-group $ike_group key-exchange");
				if ( defined($key_exchange) ) {
					if ( $key_exchange eq 'ikev1' ) {
						$genout .= "\t\tversion = 1\n";
					}
					if ( $key_exchange eq 'ikev2' ) {
						$genout .= "\t\tversion = 2\n";
					}
				}else {
					$genout .= "\t\tversion = 0\n";
				}

				#
				# Get ikev2-reauth configuration
				# Check IKE Lifetime
				#
				my $ikev2_group_reauth = $vcVPN->returnValue("ipsec ike-group $ike_group ikev2-reauth");
				my $t_ikelifetime = $vcVPN->returnValue("ipsec ike-group $ike_group lifetime");
				if ( defined($t_ikelifetime) && $t_ikelifetime ne '' ) {
					$ikelifetime = $t_ikelifetime;
				}
				if ( defined($ikev2_group_reauth) ) {
					if ( $ikev2_group_reauth eq 'yes' && defined($ikelifetime) ) {
						$genout .= "\t\treauth_time = $ikelifetime" . "s\n";
						}else {
							$genout .= "\t\trekey_time = $ikelifetime" . "s\n";
						}
				} else {
					$genout .= "\t\trekey_time = $ikelifetime" . "s\n";
				}
                
				#
				# Allow the user to disable MOBIKE for IKEv2 connections
				#
				my $mob_ike = $vcVPN->returnValue("ipsec ike-group $ike_group mobike");
 
				if (defined($mob_ike)) {
					if (defined($key_exchange) && $key_exchange eq 'ikev2') {
						if ($mob_ike eq 'enable') {
							$genout .= "\t\tmobike = yes";
						}
						if ($mob_ike eq 'disable') {
							$genout .= "\t\tmobike = no";
						}
					}else {
						$genout .= "\t\tmobike = no";
					}
				}

				#
				# Check for Dead Peer Detection DPD
				#
				my $dpd_interval = $vcVPN->returnValue("ipsec ike-group $ike_group dead-peer-detection interval");
				my $dpd_timeout = $vcVPN->returnValue("ipsec ike-group $ike_group dead-peer-detection timeout");
				my $dpd_action = $vcVPN->returnValue("ipsec ike-group $ike_group dead-peer-detection action");
				if ( defined($dpd_interval) && defined($dpd_timeout) && defined($dpd_action) ) {
					$genout .= "\t\tdpd_delay = $dpd_interval" . "s\n";
					$genout .= "\t\tdpd_timeout = $dpd_timeout" . "s\n";
				}
			}

			$genout .= "\t\tkeyingtries = 0\n";

			#
			# Authentication
			#
			$genout .="\t\tlocal {\n";
			if ( defined($auth_mode) && ( $auth_mode eq 'pre-shared-secret' ) ) {
				$genout .= "\t\t\tauth = psk\n";
			}
			$genout .="\t\t}\n";
			$genout .="\t\tremote {\n";
			if ( defined($auth_mode) && ( $auth_mode eq 'pre-shared-secret' ) ) {
				$genout .= "\t\t\tauth = psk\n";
			}
			$genout .="\t\t}\n";

			#
			# Write ESP configuration from group
			#
			$genout .="\t\tchildren {\n";
			$genout .="\t\t\tdmvpn {\n";
			my $esplifetime = ESPLIFETIME_DEFAULT;
			$genout .= "\t\t\t\tesp_proposals = ";
			my $esp_group = $vcVPN->returnValue("ipsec profile $profile esp-group");
			if ( defined($esp_group) && $esp_group ne '' ) {
				my @esp_proposals =	$vcVPN->listNodes("ipsec esp-group $esp_group proposal");
				my $first_esp_proposal = 1;
				foreach my $esp_proposal (@esp_proposals) {
					#
					# Get encryption, hash
					#
					my $encryption = $vcVPN->returnValue("ipsec esp-group $esp_group proposal $esp_proposal encryption");
					my $hash = $vcVPN->returnValue("ipsec esp-group $esp_group proposal $esp_proposal hash");
					my $pfs = $vcVPN->returnValue("ipsec esp-group $esp_group pfs");
                    
					#
					# Write separator if not first proposal
					#
					if ($first_esp_proposal) {
						$first_esp_proposal = 0;
					}
					else {
						$genout .= ",";
					}
					if (defined($pfs)) {
						if ($pfs eq 'enable') {
							# Get the first IKE group's dh-group and use that as our PFS setting
							my $default_pfs = $vcVPN->returnValue("ipsec ike-group $ike_group proposal 1 dh-group");
							$pfs = get_dh_cipher_result($default_pfs);
							if ( !defined($default_pfs) && $pfs eq 'unknown' ) {
								vpn_die(["vpn","ipsec","profile", $profile,"bind","tunnel", $tunnel],"$vpn_cfg_err 'pfs enabled' needs 'dh-group' specified in ".
								"ike-group \"$ike_group\" proposal 1 dh-group. \n");
							}
						} elsif ($pfs eq 'disable') {
							undef $pfs;
						} else {
							$pfs = get_dh_cipher_result($pfs);
						}
					}

					#
					# Write values
					#
					if ( defined($encryption) && defined($hash) ) {
						$genout .= "$encryption-$hash";
						if (defined($pfs)) {
							$genout .= "-$pfs";
						}
					}
				}
				$genout .= "\n";

				my $t_esplifetime =	$vcVPN->returnValue("ipsec esp-group $esp_group lifetime");
				if ( defined($t_esplifetime) && $t_esplifetime ne '' ) {
					$esplifetime = $t_esplifetime;
				}
				$genout .= "\t\t\t\trekey_time = $esplifetime" . "s\n";

				my $lower_lifetime = $ikelifetime;
				if ( $esplifetime < $ikelifetime ) {
					$lower_lifetime = $esplifetime;
				}
				
				#
				# The lifetime values need to be greater than:
				#   rekeymargin*(100+rekeyfuzz)/100
				#
				my $rekeymargin = REKEYMARGIN_DEFAULT;
				if ($lower_lifetime <= (2 * $rekeymargin)) {
					$rekeymargin = int($lower_lifetime / 2) - 1;
				}
				$genout .= "\t\t\t\trand_time = $rekeymargin" . "s\n";
                
				#
				# Protocol/port
				#
				my $protocol   = "gre";
				my $lprotoport = '';
				if ( defined($protocol) ) {
					$lprotoport .= $protocol;
				}
				if ( not( $lprotoport eq '' ) ) {
					$genout .= "\t\t\t\tlocal_ts = dynamic[$lprotoport]\n";
				}

				my $rprotoport = '';
				if ( defined($protocol) ) {
					$rprotoport .= $protocol;
				}
				if ( not( $rprotoport eq '' ) ) {
					$genout .= "\t\t\t\tremote_ts = dynamic[$rprotoport]\n";
				}
            
				#
				# Mode (tunnel or transport)
				#
				my $espmode = $vcVPN->returnValue("ipsec esp-group $esp_group mode");
				if ( !defined($espmode) || $espmode eq '' ) {
					$espmode = "transport";
				}
				$genout .= "\t\t\t\tmode = $espmode\n";
				
				#
				# Check for Dead Peer Detection DPD
				#
				my $dpd_interval = $vcVPN->returnValue("ipsec ike-group $ike_group dead-peer-detection interval");
				my $dpd_timeout = $vcVPN->returnValue("ipsec ike-group $ike_group dead-peer-detection timeout");
				my $dpd_action = $vcVPN->returnValue("ipsec ike-group $ike_group dead-peer-detection action");	
				if (   defined($dpd_interval) && defined($dpd_timeout) && defined($dpd_action) ) {

					$genout .= "\t\t\t\tdpd_action = $dpd_action\n";
				}
				

				#
				# Compression
				#
				my $compression = $vcVPN->returnValue("ipsec esp-group $esp_group compression");
				if ( defined($compression) ) {
					if ( $compression eq 'enable' ) {
						$genout .= "\t\t\t\tipcomp=yes\n";
					}
				}
			}

			$genout .= "\t\t\t}\n";
			$genout .= "\t\t}\n";
			$genout .= "\t}\n"; # to identify end of connection definition
								# used by clear vpn op-mode command
		}
		$genout .= "}\n";
		$genout .= "secrets {\n";
		my @tunnels = $vcVPN->listNodes("ipsec profile $profile bind tunnel");
		foreach my $tunnel (@tunnels) {
			#
			# Check whether this tunnel is already in some profile
			#
			foreach my $prof (@profiles) {
				if ( $prof != $profile ) {
					if ($vcVPN->exists("ipsec profile $prof bind tunnel $tunnel")){
						vpn_die(["vpn",  "ipsec",  "profile", $profile,"bind", "tunnel", $tunnel],
								"$vpn_cfg_err Tunnel \"$tunnel\" is already configured in profile \"$prof\".");
					}
				}
			}
			my $ike_id = "\tike-dmvpn-$tunnel {\n";
			$genout .= $ike_id;
			$genout .= "\t\tsecret = $psk\n";
			$genout .= "\t}\n";
		}
		$genout .= "}\n";
	}
}
else {
	#
	# remove any previous config lines, so that when "clear vpn ipsec-process"
	# is called it won't find the vyatta keyword and therefore will not try
	# to start the ipsec process.
	#
	$genout = '';
	$genout         .= "# No VPN configuration exists.\n";
}

if (!(defined($config_file) && ( $config_file ne '' ))) {
	print "Regular config file output would be:\n\n$genout\n\n";
	exit(0);
}

write_config( $genout, $config_file);

my $update_interval      = $vcVPN->returnValue("ipsec auto-update");
my $update_interval_orig = $vcVPN->returnOrigValue("ipsec auto-update");
$update_interval_orig = 0 if !defined($update_interval_orig);
if ( is_vpn_running() ) {
	vpn_exec( 'ipsec rereadall >&/dev/null', 're-read secrets and certs' );
	vpn_exec( 'ipsec reload >&/dev/null',    'reload changes to ipsec.conf' );
	vpn_exec( 'swanctl -q >&/dev/null',    'reload changes to swanctl.conf' );
}
else {
	if ( !defined($update_interval) ) {
		vpn_exec( 'ipsec start >&/dev/null', 'start ipsec' );
        my $counter = 10;
		while($counter > 0){
			if (-e "/var/run/charon.pid") {
				vpn_exec( 'swanctl -q >&/dev/null',    'reload changes to swanctl.conf' );
				last;
			}
			$counter--;
			sleep(1);
			if($counter == 0){
				vpn_die("$vpn_cfg_err Ipsec is not running.");
			}
		}
	}
	else {
		vpn_exec(
			'ipsec start --auto-update ' . $update_interval . ' >&/dev/null',
			'start ipsec with auto-update $update_interval' );
			        my $counter = 10;
		while($counter > 0){
			if (-e "/var/run/charon.pid") {
				vpn_exec( 'swanctl -q >&/dev/null',    'reload changes to swanctl.conf' );
				last;
			}
			$counter--;
			sleep(1);
			if($counter == 0){
				vpn_die("$vpn_cfg_err Ipsec is not running.");
			}
		}
	}
}

#
# Return success
#
exit 0;

sub vpn_die {
	my ( @path, $msg ) = @_;
	Vyatta::Config::outputError( @path, $msg );
	exit 1;
}

sub write_config {
	my ( $genout, $config_file) = @_;

	open my $output_config, '>', $config_file
		or die "Can't open $config_file: $!";
	print ${output_config} $genout;
	close $output_config;
}

sub vpn_exec {
	my ( $command, $desc ) = @_;

	open my $logf, '>>', $LOGFILE
		or die "Can't open $LOGFILE: $!";

	use POSIX;
	my $timestamp = strftime( "%Y-%m-%d %H:%M.%S", localtime );

	print ${logf} "$timestamp\nExecuting: $command\nDescription: $desc\n";

	my $cmd_out = qx($command);
	my $rval    = ( $? >> 8 );
	print ${logf} "Output:\n$cmd_out\n---\n";
	print ${logf} "Return code: $rval\n";
	if ($rval) {
		if ( $command =~ /^ipsec.*--asynchronous$/ && ( $rval == 104 || $rval == 29 ) ) {
			print ${logf} "OK when bringing up VPN connection\n";
		}
		else {
			#
			# We use to consider the commit failed if we got a error
			# from the call to ipsec, but this causes the configuration
			# to not get included in the running config.  Now that
			# we support dynamic interface/address (e.g. dhcp, pppoe)
			# we want a valid config to get committed even if the
			# interface doesn't exist yet.  That way we can use
			# "clear vpn ipsec-process" to bring up the tunnel once
			# the interface is instantiated.  For pppoe we will add
			# a script to /etc/ppp/ip-up.d to bring up the vpn
			# tunnel.
			#
			print ${logf} "VPN commit error.  Unable to $desc, received error code $?\n";

			#
			# code 768 is for a syntax error in the secrets file
			# this happens when a dhcp interface is configured
			# but no address is assigned yet.
			# only the line that has the syntax error is not loaded
			# So we can safely ignore this error since our code generates
			# secrets file.
			#
			if ( $? ne '768' ) {
				print "Warning: unable to [$desc], received error code $?\n";
				print "$cmd_out\n";
			}
		}
	}
	print ${logf} "---\n\n";
	close $logf;
}

sub printTree {
	my ( $vc, $path, $depth ) = @_;

	my @children = $vc->listNodes($path);
	foreach my $child (@children) {
		print '    ' x $depth;
		print $child . "\n";
		printTree( $vc, "$path $child", $depth + 1 );
	}
}

sub printTreeOrig {
	my ( $vc, $path, $depth ) = @_;

	my @children = $vc->listOrigNodes($path);
	foreach my $child (@children) {
		print '    ' x $depth;
		print $child . "\n";
		printTreeOrig( $vc, "$path $child", $depth + 1 );
	}
}

sub get_dh_cipher_result { 
	my ($cipher) = @_;
	my $ciph_out;
	if ($cipher eq '2' || $cipher eq 'dh-group2') {
		$ciph_out = 'modp1024';
	} elsif ($cipher eq '5' || $cipher eq 'dh-group5') {
		$ciph_out = 'modp1536';
	} elsif ($cipher eq '14' || $cipher eq 'dh-group14') {
		$ciph_out = 'modp2048';
	} elsif ($cipher eq '15' || $cipher eq 'dh-group15') {
		$ciph_out = 'modp3072';
	} elsif ($cipher eq '16' || $cipher eq 'dh-group16') {
		$ciph_out = 'modp4096';
	} elsif ($cipher eq '17' || $cipher eq 'dh-group17') {
		$ciph_out = 'modp6144';
	} elsif ($cipher eq '18' || $cipher eq 'dh-group18') {
		$ciph_out = 'modp8192';
	} elsif ($cipher eq '19' || $cipher eq 'dh-group19') {
		$ciph_out = 'ecp256';
	} elsif ($cipher eq '20' || $cipher eq 'dh-group20') {
		$ciph_out = 'ecp384';	
	} elsif ($cipher eq '21' || $cipher eq 'dh-group21') {
		$ciph_out = 'ecp521';
	} elsif ($cipher eq '22' || $cipher eq 'dh-group22') {
		$ciph_out = 'modp1024s160';
	} elsif ($cipher eq '23' || $cipher eq 'dh-group23') {
		$ciph_out = 'modp2048s224';
	} elsif ($cipher eq '24' || $cipher eq 'dh-group24') {
		$ciph_out = 'modp2048s256';
	} elsif ($cipher eq '25' || $cipher eq 'dh-group25') {
		$ciph_out = 'ecp192';
	} elsif ($cipher eq '26' || $cipher eq 'dh-group26') {
		$ciph_out = 'ecp224';
	} else {
		$ciph_out = 'unknown';
	}
	return $ciph_out;
}
# end of file
