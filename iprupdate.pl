#!/usr/bin/perl
use lib '/home/adcockm/perl5/lib/perl5';
use lib '/home/adcockm/lib/perl5';
use lib '/home/adcockm/lib/perl5/lib64/perl5';
use lib '/home/adcockm/lib/perl5/share/perl5';
use DateTime;
use DateTime::Duration;
use JSON::XS;
use LWP::UserAgent;
use Mozilla::CA;
use utf8;
use POSIX qw(floor);
use File::Slurp qw(read_file write_file);
use URL::Encode qw(url_encode);
use Web::Scraper;
use Data::Dumper;
use strict;
use warnings;
#$SIG{'INT'} = 'IGNORE';

my $debugmode = 0;

my $ratingsdate = $ARGV[0];
my $dtCurrent = DateTime->now;
my $currentdate = $dtCurrent->ymd;
my $dtDuration = DateTime::Duration->new( days => 8 );	
my $dtQuery = $dtCurrent->subtract_duration($dtDuration);
if(!$ratingsdate) {
	$ratingsdate = $dtQuery->ymd;
}

my $csvfilename = "playerinfo.csv";
my @playersCSV;
open(my $inputcsvfh, "<", $csvfilename)
	or die "Failed to open file: $!\n";
while(<$inputcsvfh>) { 
	chomp; 
	push @playersCSV, $_;
} 
close $inputcsvfh;

my $players = {};
my $IFPAids = {};
my $playerinfo = {};
my @nonIFPA;
my $matchplayURL = "https://matchplay.events/data/ifpa/ratings/$ratingsdate/";
my $playercount = 0;
my $IFPAcount = 0;
foreach (@playersCSV) {
	my $line = $_;
	my ($name, $IFPAid, $team, $role) = split /,/, $line;
	if ($name eq "Name") { next; }
	$players->{$name}->{team} = $team;
	$players->{$name}->{role} = $role;
	if ($IFPAid) {
		$IFPAids->{$IFPAid}->{name} = $name;
		$matchplayURL .= $IFPAid . ",";
		$IFPAcount++;
	}
	else {
		push @nonIFPA, $name;
	}
	$playercount++;
}
my $MPcount = scalar @nonIFPA;
print "$playercount players, $IFPAcount IFPA IDs, $MPcount Non-IFPA players\n";

# json utility object
my $json = new JSON::XS;
$json->canonical(1);

my $ua = LWP::UserAgent->new(ssl_opts => { SSL_ca_file => Mozilla::CA::SSL_ca_file() });
$ua->agent("Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/34.0.1847.131 Safari/537.36");
my $res = "";

# get Matchplay ratings for IFPA IDs
my $matchplayPage = "";
$res = $ua->request(HTTP::Request->new(GET => $matchplayURL));
if ($debugmode){ print("GET " . $matchplayURL . ": " . $res->status_line . "\n"); }
if ($res->is_success) {
	$matchplayPage = $res->decoded_content;
	my $matchplayresponse = &decodeJSON($matchplayPage);
	
	my $tempmpifpacount = 0;
	foreach my $IFPAid (keys(%$IFPAids)) {
		$players->{$IFPAids->{$IFPAid}->{name}}->{MP}->{date_collected} = $ratingsdate;
		$players->{$IFPAids->{$IFPAid}->{name}}->{MP}->{rating} = $matchplayresponse->{$IFPAid}->{rating};
		$players->{$IFPAids->{$IFPAid}->{name}}->{MP}->{rd} = $matchplayresponse->{$IFPAid}->{rd};
		$players->{$IFPAids->{$IFPAid}->{name}}->{MP}->{lower_bound} = $matchplayresponse->{$IFPAid}->{lower_bound};
		$players->{$IFPAids->{$IFPAid}->{name}}->{MP}->{upper_bound} = $matchplayresponse->{$IFPAid}->{rating} + ($matchplayresponse->{$IFPAid}->{rd} * 2);
		$tempmpifpacount++;
	}
	print "$tempmpifpacount/$IFPAcount players Matchplay ratings from IFPA IDs collected.\n";
}
else { print("Matchplay [GET " . $matchplayURL . "]: " . $res->status_line . "\n"); }

# get Matchplay ratings for player names (no IFPA IDs)
my $tempmpcount = 0;
foreach (@nonIFPA) {
	my $name = $_;
	my $searchPage = "";
	my $searchURL = "https://matchplay.events/live/ratings/search?query=" . &url_encode($name);
	$res = $ua->request(HTTP::Request->new(GET => $searchURL));
	if ($debugmode){ print("GET " . $searchURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$searchPage = $res->decoded_content;
	}
	else { print("ERROR [" . $searchURL . "]: " . $res->status_line . "\n"); exit 1; }

	my $scraper = scraper { process '//tr/td[2]', 'ratings[]' => 'TEXT'; };
	my $playertemp  = $scraper->scrape($searchPage);

	if ($playertemp->{ratings}) {
		if ($playertemp->{ratings}[0]) {
			my ($rating, $delta) = split / ±/, $playertemp->{ratings}[0];
			$players->{$name}->{MP}->{date_collected} = $ratingsdate;
			$players->{$name}->{MP}->{rating} = int($rating);
			$players->{$name}->{MP}->{rd} = floor($delta/2);
			$players->{$name}->{MP}->{lower_bound} = $rating - $delta;
			$players->{$name}->{MP}->{upper_bound} = $rating + $delta;
			$tempmpcount++;
		}
	}
	else {
		print "$name not found in Matchplay Ratings.\n";
		if ($debugmode){ print("GET " . $searchURL . ": " . $res->status_line . "\n"); }
	}
	sleep 1;
}
print "$tempmpcount/$MPcount players Matchplay ratings from names collected.\n";

# get IFPA ranks
my $tempmpifpacount = 0;
foreach my $IFPAid (keys(%$IFPAids)) {
	my $IFPAURL = "https://api.ifpapinball.com/v1/player/$IFPAid?api_key=6655c7e371c30c5cecda4a6c8ad520a4";
	my $IFPAPage = "";
	$res = $ua->request(HTTP::Request->new(GET => $IFPAURL));
	if ($debugmode){ print("GET " . $IFPAURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$IFPAPage = $res->decoded_content;
		my $IFPAresponse = &decodeJSON($IFPAPage);
		my $oldplayername = $IFPAids->{$IFPAid}->{name};
		$players->{$oldplayername}->{IFPA}->{date_collected} = $currentdate;
		$players->{$oldplayername}->{IFPA}->{player}->{player_id} = $IFPAresponse->{player}->{player_id};
		$players->{$oldplayername}->{IFPA}->{player}->{first_name} = $IFPAresponse->{player}->{first_name};
		$players->{$oldplayername}->{IFPA}->{player}->{last_name} = $IFPAresponse->{player}->{last_name};
		my $playername = $IFPAresponse->{player}->{first_name} . " " . $IFPAresponse->{player}->{last_name};
		$playername =~ s/^\s+|\s+$//g; # trim leading/trailing spaces
		$players->{$oldplayername}->{IFPA}->{player}->{city} = $IFPAresponse->{player}->{city};
		$players->{$oldplayername}->{IFPA}->{player}->{state} = $IFPAresponse->{player}->{state};
		$players->{$oldplayername}->{IFPA}->{player}->{country_code} = $IFPAresponse->{player}->{country_code};
		$players->{$oldplayername}->{IFPA}->{player}->{country_name} = $IFPAresponse->{player}->{country_name};
		$players->{$oldplayername}->{IFPA}->{player}->{initials} = $IFPAresponse->{player}->{initials};
		$players->{$oldplayername}->{IFPA}->{player}->{age} = $IFPAresponse->{player}->{age};
		$players->{$oldplayername}->{IFPA}->{player}->{excluded_flag} = $IFPAresponse->{player}->{excluded_flag};
		$players->{$oldplayername}->{IFPA}->{player}->{ifpa_registered} = $IFPAresponse->{player}->{ifpa_registered};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{current_wppr_rank} = $IFPAresponse->{player_stats}->{current_wppr_rank};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{last_month_rank} = $IFPAresponse->{player_stats}->{last_month_rank};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{last_year_rank} = $IFPAresponse->{player_stats}->{last_year_rank};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{highest_rank} = $IFPAresponse->{player_stats}->{highest_rank};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{highest_rank_date} = $IFPAresponse->{player_stats}->{highest_rank_date};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{current_wppr_value} = $IFPAresponse->{player_stats}->{current_wppr_value};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{wppr_points_all_time} = $IFPAresponse->{player_stats}->{wppr_points_all_time};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{best_finish} = $IFPAresponse->{player_stats}->{best_finish};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{best_finish_count} = $IFPAresponse->{player_stats}->{best_finish_count};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{average_finish} = $IFPAresponse->{player_stats}->{average_finish};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{average_finish_last_year} = $IFPAresponse->{player_stats}->{average_finish_last_year};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{total_events_all_time} = $IFPAresponse->{player_stats}->{total_events_all_time};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{total_active_events} = $IFPAresponse->{player_stats}->{total_active_events};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{total_events_away} = $IFPAresponse->{player_stats}->{total_events_away};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{ratings_rank} = $IFPAresponse->{player_stats}->{ratings_rank};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{ratings_value} = $IFPAresponse->{player_stats}->{ratings_value};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{efficiency_rank} = $IFPAresponse->{player_stats}->{efficiency_rank};
		$players->{$oldplayername}->{IFPA}->{player_stats}->{efficiency_value} = $IFPAresponse->{player_stats}->{efficiency_value};
		# normalize all names to match IFPA names if they exist
		if ($playername && (lc($oldplayername) ne lc($playername)) && ($playername ne "Suppresed Player")) {
			$players->{$playername} = delete $players->{$oldplayername};
			$IFPAids->{$IFPAid}->{name} = $playername;
			print "[$oldplayername] corrected to IFPA standard: [$playername].\n";
		}
		# if it's a suppressed player, they get rank 149 (to force a level 6)
		if ($playername && ($playername eq "Suppresed Player")) {
			$players->{$oldplayername}->{IFPA}->{player_stats}->{current_wppr_rank} = "149";
			$players->{$oldplayername}->{IFPA}->{player}->{player_id} = $IFPAid;
			print "[$oldplayername] is Suppressed Player, setting IFPA rank to 149!\n";
		}
		$tempmpifpacount++;
		if ($debugmode){ print Dumper $players->{$IFPAids->{$IFPAid}->{name}}; }
	}
	else { print("IFPA [GET " . $IFPAURL . "]: " . $res->status_line . "\n"); }
	sleep 1;
}
print "$tempmpifpacount/$IFPAcount players IFPA ranks from IFPA IDs collected.\n";

# calculate IPR for every player
my @rosterplayers_lb;
foreach my $playername (keys(%$players)) {
	if ($players->{$playername}->{team}) {
		if ($players->{$playername}->{MP}->{lower_bound}) {
			my $lb = $players->{$playername}->{MP}->{lower_bound};
			if ($debugmode){ print("Roster player $playername on " . $players->{$playername}->{team} . " has LB = $lb\n"); }
			push @rosterplayers_lb, $lb;
		}
		else {
			if ($debugmode){ print("Roster player $playername on " . $players->{$playername}->{team} . " has LB = null\n"); }
			push @rosterplayers_lb, 0;
		}
	}
}
my $rosterplayers = scalar @rosterplayers_lb;
print "$rosterplayers roster players found.\n";
my @ranktargetplayers;
my @ranktargetpercentage = (0,.15,.20,.30,.20,.13,.02);
my @ranklbtarget;
$ranktargetplayers[6] = int($rosterplayers * $ranktargetpercentage[6] + .5); # 2%
$ranktargetplayers[5] = int($rosterplayers * $ranktargetpercentage[5] + .5); # 13%
$ranktargetplayers[4] = int($rosterplayers * $ranktargetpercentage[4] + .5); # 20%
$ranktargetplayers[3] = int($rosterplayers * $ranktargetpercentage[3] + .5); # 30%
$ranktargetplayers[2] = int($rosterplayers * $ranktargetpercentage[2] + .5); # 20%
$ranktargetplayers[1] = int($rosterplayers * $ranktargetpercentage[1] + .5); # 15%
print "IPR, Target Players, Target %\n";
my $targetplayertotal = 0;
my $targetpercenttotal = 0;
for (my $i=6; $i > 0; $i--) {
	print $i . ", " . $ranktargetplayers[$i] . ", " . ($ranktargetpercentage[$i]*100) . "%\n";
	$targetplayertotal += $ranktargetplayers[$i];
	$targetpercenttotal += $ranktargetpercentage[$i]*100;
}
print "-----";
print $targetplayertotal . ", " . $targetpercenttotal . "%\n";

if ($debugmode){ print Dumper @ranktargetplayers};
@rosterplayers_lb = sort { $b <=> $a } @rosterplayers_lb;
if ($debugmode){ print Dumper @rosterplayers_lb};
my $i = 0;
my $currentrank = 6;
foreach (@rosterplayers_lb) {
	my $currentlb = $_;
	$i++;
	if ($i == $ranktargetplayers[$currentrank]) {
		$ranklbtarget[$currentrank] = $currentlb - 1;
		$currentrank--;
		$i = 0;
	}
	if ($currentrank < 2) { last; }
}
my @ranktargetIFPA = (0,5000,5000,2500,1000,500,150);
my @ranktargetgrade = (0,"D","C","B","A","AA","AAA");
print "IPR, IFPA, MP LB\n";
for (my $i=6; $i > 2; $i--) {
	$playerinfo->{thresholds}->{"IFPA" . $i} = $ranktargetIFPA[$i];
	$playerinfo->{thresholds}->{"MP" . $i} = $ranklbtarget[$i];
	print $i . " < " . $ranktargetIFPA[$i] . " > " . $ranklbtarget[$i] . "\n";
}
print "2 < " . $ranktargetIFPA[2] . " > " . $ranklbtarget[2] . "\n";
print "1 >= " . $ranktargetIFPA[1] . " <= " . $ranklbtarget[2] . "\n";
$playerinfo->{thresholds}->{IFPA21} = int($ranktargetIFPA[2]);
$playerinfo->{thresholds}->{MP21} = int($ranklbtarget[2]);
my @rankrosterplayers = (0,0,0,0,0,0,0);
my @rankallplayers = (0,0,0,0,0,0,0);
foreach my $playername (keys(%$players)) {
	my $IFPA_IPR = 0;
	my $MP_IPR = 0;
	my $IPR = 0;
	if ($players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank}) {
		my $IFPArank = $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank};
		if ($IFPArank < $ranktargetIFPA[6]) {
			$IFPA_IPR = 6;
		}
		elsif ($IFPArank < $ranktargetIFPA[5]) {
			$IFPA_IPR = 5;
		}
		elsif ($IFPArank < $ranktargetIFPA[4]) {
			$IFPA_IPR = 4;
		}
		elsif ($IFPArank < $ranktargetIFPA[3]) {
			$IFPA_IPR = 3;
		}
		elsif ($IFPArank < $ranktargetIFPA[2]) {
			$IFPA_IPR = 2;
		}
		else {
			$IFPA_IPR = 1;
		}
	}
	else {
		$IFPA_IPR = 1;
	}
	if ($players->{$playername}->{MP}->{lower_bound}) {
		my $lb = $players->{$playername}->{MP}->{lower_bound};
		if ($lb > $ranklbtarget[6]) {
			$MP_IPR = 6;
		}
		elsif ($lb > $ranklbtarget[5]) {
			$MP_IPR = 5;
		}
		elsif ($lb > $ranklbtarget[4]) {
			$MP_IPR = 4;
		}
		elsif ($lb > $ranklbtarget[3]) {
			$MP_IPR = 3;
		}
		elsif ($lb > $ranklbtarget[2]) {
			$MP_IPR = 2;
		}
		else {
			$MP_IPR = 1;
		}
	}
	else {
		$MP_IPR = 1;
	}
	$players->{$playername}->{MP}->{IPR} = $MP_IPR;
	$players->{$playername}->{IFPA}->{IPR} = $IFPA_IPR;
	$players->{$playername}->{IPR} = ($MP_IPR > $IFPA_IPR) ? $MP_IPR : $IFPA_IPR;
	if ($players->{$playername}->{team}) {
		$rankrosterplayers[$MP_IPR] +=1;
		$rankallplayers[$players->{$playername}->{IPR}] +=1;
	}
	else {
		$rankallplayers[$players->{$playername}->{IPR}] +=1;
	}
}
print "IPR, Roster Players, %\n";
my $rosterplayertotal = 0;
my $rosterpercenttotal = 0;
$playerinfo->{rosterpercentages}->{playercount} = $rosterplayers;
for (my $i=6; $i > 0; $i--) {
	my $rosterpercentage = ($rankrosterplayers[$i]/$rosterplayers)*100;
	$playerinfo->{rosterpercentages}->{"IPR" . $i} = $rosterpercentage;
	print $i . ", " . $rankrosterplayers[$i] . ", " . $rosterpercentage . "%\n";
	$rosterplayertotal += $rankrosterplayers[$i];
	$rosterpercenttotal += $rosterpercentage;
}
print "-----";
print $rosterplayertotal . ", " . $rosterpercenttotal . "%\n";

print "IPR, All Players, %\n";
my $allplayertotal = 0;
my $allpercenttotal = 0;
for (my $i=6; $i > 0; $i--) {
	print $i . ", " . $rankallplayers[$i] . ", " . (($rankallplayers[$i]/$playercount)*100) . "%\n";
	$allplayertotal += $rankallplayers[$i];
	$allpercenttotal += ($rankallplayers[$i]/$playercount)*100;
}
print "-----";
print $allplayertotal . ", " . $allpercenttotal . "%\n";

# save new CSV with updated player names
open(my $csvfh, '>:encoding(UTF-8)', $csvfilename)
	or die "Failed to open file: $!\n";	
print $csvfh "Name,IFPA ID,Team,Role\n";
foreach my $playername (sort keys(%$players)) {
	my $IFPAid = $players->{$playername}->{IFPA}->{player}->{player_id} ? $players->{$playername}->{IFPA}->{player}->{player_id} : "";
	my $team = $players->{$playername}->{team} ? $players->{$playername}->{team} : "";
	my $role = $players->{$playername}->{role} ? $players->{$playername}->{role} : "";
	print $csvfh "$playername,$IFPAid,$team,$role\n";
}
close($csvfh);

# copy information to playerinfo
$playerinfo->{dateupdated}->{MP} = $ratingsdate;
$playerinfo->{dateupdated}->{IFPA} = $currentdate;
foreach my $playername (sort keys(%$players)) {
	if ($players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank}) {
		$playerinfo->{players}->{$playername}->{IFPA_ID} = $players->{$playername}->{IFPA}->{player}->{player_id};
		$playerinfo->{players}->{$playername}->{IFPA_RANK} = $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank};
		$playerinfo->{IFPA}->{$players->{$playername}->{IFPA}->{player}->{player_id}} = $playername;
	}
	else {
		$playerinfo->{players}->{$playername}->{IFPA_ID} = 0;
		$playerinfo->{players}->{$playername}->{IFPA_RANK} = 32767;
	}
	$playerinfo->{players}->{$playername}->{IPR} = $players->{$playername}->{IPR};
	if ($players->{$playername}->{MP}->{lower_bound}) {
		$playerinfo->{players}->{$playername}->{MP_LB} = $players->{$playername}->{MP}->{lower_bound};
		$playerinfo->{players}->{$playername}->{MP_RD} = $players->{$playername}->{MP}->{rd};
	}
	else {
		$playerinfo->{players}->{$playername}->{MP_LB} = 0;
		$playerinfo->{players}->{$playername}->{MP_RD} = 0;
	}
}

&saveJSON($players, "fullplayerinfo.json");
&saveJSON($playerinfo, "playerinfo.json");

# save new CSV with updated player names
open(my $spreadsheetfh, '>:encoding(UTF-8)', "temp.csv")
	or die "Failed to open file: $!\n";	
print $spreadsheetfh "MP RP,IFPA RP,IPR,Name,Team,Role,IFPA ID,IFPA Rank,MP LB,MP RD,MPR\n";
foreach my $playername (sort keys(%$players)) {
	my $IFPAid = $players->{$playername}->{IFPA}->{player}->{player_id} ? $players->{$playername}->{IFPA}->{player}->{player_id} : "";
	my $IFPArank = $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank} : "";
	my $IFPAIPR = $players->{$playername}->{IFPA}->{IPR} ? $players->{$playername}->{IFPA}->{IPR} : "";
	my $MPlb = $players->{$playername}->{MP}->{lower_bound} ? $players->{$playername}->{MP}->{lower_bound} : "";
	my $MPrd = $players->{$playername}->{MP}->{rd} ? $players->{$playername}->{MP}->{rd} : "";
	my $MPrating = $players->{$playername}->{MP}->{rating} ? $players->{$playername}->{MP}->{rating} : "";
	my $MPIPR = $players->{$playername}->{MP}->{IPR} ? $players->{$playername}->{MP}->{IPR} : "";
	my $team = $players->{$playername}->{team} ? $players->{$playername}->{team} : "";
	my $role = $players->{$playername}->{role} ? $players->{$playername}->{role} : "";
	my $IPR = $players->{$playername}->{IPR} ? $players->{$playername}->{IPR} : "";
	print $spreadsheetfh "$MPIPR,$IFPAIPR,$IPR,$playername,$team,$role,$IFPAid,$IFPArank,$MPlb,$MPrd,$MPrating\n";
}
close($spreadsheetfh);

# save CSV with everything
open(my $fullspreadsheetfh, '>:encoding(UTF-8)', "fullplayerinfo.csv")
	or die "Failed to open file: $!\n";	
print $fullspreadsheetfh "MP_IPR,IFPA_IPR,IPR,Name,team,role,IFPA_current_wppr_rank,MP_lower_bound,IFPA_date_collected,IFPA_player_age,IFPA_player_city,IFPA_player_country_code,IFPA_country_name,IFPA_excluded_flag,IFPA_first_name,IFPA_registered,IFPA_initials,IFPA_last_name,IFPA_player_id,IFPA_state,IFPA_average_finish,IFPA_average_finish_last_year,IFPA_best_finish,IFPA_best_finish_count,IFPA_current_wppr_value,IFPA_efficiency_rank,IFPA_efficiency_value,IFPA_highest_rank,IFPA_highest_rank_date,IFPA_last_month_rank,IFPA_last_year_rank,IFPA_ratings_rank,IFPA_ratings_value,IFPA_total_active_events,IFPA_total_events_all_time,IFPA_total_events_away,IFPA_wppr_points_all_time,MP_date_collected,MP_rating,MP_rd,MP_upper_bound\n";
foreach my $playername (sort keys(%$players)) {
	my $IFPA_IPR = $players->{$playername}->{IFPA}->{IPR} ? $players->{$playername}->{IFPA}->{IPR} : "";
	my $IFPA_date_collected = $players->{$playername}->{IFPA}->{date_collected} ? $players->{$playername}->{IFPA}->{date_collected} : "";
	my $IFPA_player_age = $players->{$playername}->{IFPA}->{player}->{age} ? $players->{$playername}->{IFPA}->{player}->{age} : "";
	my $IFPA_player_city = $players->{$playername}->{IFPA}->{player}->{city} ? $players->{$playername}->{IFPA}->{player}->{city} : "";
	my $IFPA_player_country_code = $players->{$playername}->{IFPA}->{player}->{country_code} ? $players->{$playername}->{IFPA}->{player}->{country_code} : "";
	my $IFPA_country_name = $players->{$playername}->{IFPA}->{player}->{country_name} ? $players->{$playername}->{IFPA}->{player}->{country_name} : "";
	my $IFPA_excluded_flag = $players->{$playername}->{IFPA}->{player}->{excluded_flag} ? $players->{$playername}->{IFPA}->{player}->{excluded_flag} : "";
	my $IFPA_first_name = $players->{$playername}->{IFPA}->{player}->{first_name} ? $players->{$playername}->{IFPA}->{player}->{first_name} : "";
	my $IFPA_registered = $players->{$playername}->{IFPA}->{player}->{ifpa_registered} ? $players->{$playername}->{IFPA}->{player}->{ifpa_registered} : "";
	my $IFPA_initials = $players->{$playername}->{IFPA}->{player}->{initials} ? $players->{$playername}->{IFPA}->{player}->{initials} : "";
	my $IFPA_last_name = $players->{$playername}->{IFPA}->{player}->{last_name} ? $players->{$playername}->{IFPA}->{player}->{last_name} : "";
	my $IFPA_player_id = $players->{$playername}->{IFPA}->{player}->{player_id} ? $players->{$playername}->{IFPA}->{player}->{player_id} : "";
	my $IFPA_state = $players->{$playername}->{IFPA}->{player}->{state} ? $players->{$playername}->{IFPA}->{player}->{state} : "";
	my $IFPA_average_finish = $players->{$playername}->{IFPA}->{player_stats}->{average_finish} ? $players->{$playername}->{IFPA}->{player_stats}->{average_finish} : "";
	my $IFPA_average_finish_last_year = $players->{$playername}->{IFPA}->{player_stats}->{average_finish_last_year} ? $players->{$playername}->{IFPA}->{player_stats}->{average_finish_last_year} : "";
	my $IFPA_best_finish = $players->{$playername}->{IFPA}->{player_stats}->{best_finish} ? $players->{$playername}->{IFPA}->{player_stats}->{best_finish} : "";
	my $IFPA_best_finish_count = $players->{$playername}->{IFPA}->{player_stats}->{best_finish_count} ? $players->{$playername}->{IFPA}->{player_stats}->{best_finish_count} : "";
	my $IFPA_current_wppr_rank = $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_rank} : "";
	my $IFPA_current_wppr_value = $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_value} ? $players->{$playername}->{IFPA}->{player_stats}->{current_wppr_value} : "";
	my $IFPA_efficiency_rank = $players->{$playername}->{IFPA}->{player_stats}->{efficiency_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{efficiency_rank} : "";
	my $IFPA_efficiency_value = $players->{$playername}->{IFPA}->{player_stats}->{efficiency_value} ? $players->{$playername}->{IFPA}->{player_stats}->{efficiency_value} : "";
	my $IFPA_highest_rank = $players->{$playername}->{IFPA}->{player_stats}->{highest_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{highest_rank} : "";
	my $IFPA_highest_rank_date = $players->{$playername}->{IFPA}->{player_stats}->{highest_rank_date} ? $players->{$playername}->{IFPA}->{player_stats}->{highest_rank_date} : "";
	my $IFPA_last_month_rank = $players->{$playername}->{IFPA}->{player_stats}->{last_month_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{last_month_rank} : "";
	my $IFPA_last_year_rank = $players->{$playername}->{IFPA}->{player_stats}->{last_year_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{last_year_rank} : "";
	my $IFPA_ratings_rank = $players->{$playername}->{IFPA}->{player_stats}->{ratings_rank} ? $players->{$playername}->{IFPA}->{player_stats}->{ratings_rank} : "";
	my $IFPA_ratings_value = $players->{$playername}->{IFPA}->{player_stats}->{ratings_value} ? $players->{$playername}->{IFPA}->{player_stats}->{ratings_value} : "";
	my $IFPA_total_active_events = $players->{$playername}->{IFPA}->{player_stats}->{total_active_events} ? $players->{$playername}->{IFPA}->{player_stats}->{total_active_events} : "";
	my $IFPA_total_events_all_time = $players->{$playername}->{IFPA}->{player_stats}->{total_events_all_time} ? $players->{$playername}->{IFPA}->{player_stats}->{total_events_all_time} : "";
	my $IFPA_total_events_away = $players->{$playername}->{IFPA}->{player_stats}->{total_events_away} ? $players->{$playername}->{IFPA}->{player_stats}->{total_events_away} : "";
	my $IFPA_wppr_points_all_time = $players->{$playername}->{IFPA}->{player_stats}->{wppr_points_all_time} ? $players->{$playername}->{IFPA}->{player_stats}->{wppr_points_all_time} : "";
	my $IPR = $players->{$playername}->{IPR} ? $players->{$playername}->{IPR} : "";
	my $MP_IPR = $players->{$playername}->{MP}->{IPR} ? $players->{$playername}->{MP}->{IPR} : "";
	my $MP_date_collected = $players->{$playername}->{MP}->{date_collected} ? $players->{$playername}->{MP}->{date_collected} : "";
	my $MP_lower_bound = $players->{$playername}->{MP}->{lower_bound} ? $players->{$playername}->{MP}->{lower_bound} : "";
	my $MP_rating = $players->{$playername}->{MP}->{rating} ? $players->{$playername}->{MP}->{rating} : "";
	my $MP_rd = $players->{$playername}->{MP}->{rd} ? $players->{$playername}->{MP}->{rd} : "";
	my $MP_upper_bound = $players->{$playername}->{MP}->{upper_bound} ? $players->{$playername}->{MP}->{upper_bound} : "";
	my $role = $players->{$playername}->{role} ? $players->{$playername}->{role} : "";
	my $team = $players->{$playername}->{team} ? $players->{$playername}->{team} : "";
	print $fullspreadsheetfh "$MP_IPR,$IFPA_IPR,$IPR,$playername,$team,$role,$IFPA_current_wppr_rank,$MP_lower_bound,$IFPA_date_collected,$IFPA_player_age,$IFPA_player_city,$IFPA_player_country_code,$IFPA_country_name,$IFPA_excluded_flag,$IFPA_first_name,$IFPA_registered,$IFPA_initials,$IFPA_last_name,$IFPA_player_id,$IFPA_state,$IFPA_average_finish,$IFPA_average_finish_last_year,$IFPA_best_finish,$IFPA_best_finish_count,$IFPA_current_wppr_value,$IFPA_efficiency_rank,$IFPA_efficiency_value,$IFPA_highest_rank,$IFPA_highest_rank_date,$IFPA_last_month_rank,$IFPA_last_year_rank,$IFPA_ratings_rank,$IFPA_ratings_value,$IFPA_total_active_events,$IFPA_total_events_all_time,$IFPA_total_events_away,$IFPA_wppr_points_all_time,$MP_date_collected,$MP_rating,$MP_rd,$MP_upper_bound\n"
}
close($fullspreadsheetfh);

# save the object to a JSON file
sub saveJSON {
	my $object = $_[0];
	my $filename = $_[1];
	my $content = &encodeJSON(\%$object);
	chomp($content); #strip any surrounding whitespace and weirdness
	open(my $fh, '>:encoding(UTF-8)', $filename);
	print $fh $content;
	close($fh);
}

# load the object from a JSON file
sub loadJSON {
	my $content = read_file($_[0]);
	my $object = &decodeJSON($content);
	return $object;
}

# encode a Perl data structure to a JSON string
sub encodeJSON {
   my ($data) = @_;
   return $json->pretty(1)->encode($data);
}

# decode a JSON string into a Perl data structure
sub decodeJSON {
	my ($content) = @_;
	return $json->allow_nonref->relaxed->decode($content);
}