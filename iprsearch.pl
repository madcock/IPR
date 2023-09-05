#!/usr/bin/perl
use lib '/home/adcockm/perl5/lib/perl5';
use lib '/home/adcockm/lib/perl5';
use lib '/home/adcockm/lib/perl5/lib64/perl5';
use lib '/home/adcockm/lib/perl5/share/perl5';
use HTTP::Request::Common qw(POST);
use LWP::UserAgent;
use LWP::Protocol::https;
use Mozilla::CA;
use HTTP::Cookies;
use URI;
use Web::Scraper;
use CGI ':standard';
use Time::HiRes qw(time);
use DateTime;
use DateTime::Duration;
use JSON::XS;
use String::Similarity;
use utf8;
use File::Slurp qw(read_file write_file);
use URL::Encode qw(url_encode);
use strict;
use warnings;

binmode STDOUT, ":utf8";
my $start_run = DateTime->from_epoch( epoch => time );
my $ratingsdate;
my $dtCurrent = DateTime->now;
my $currentdate = $dtCurrent->ymd;

# Dave's NWPAS eligibility filter
my $NWPAS = 0;

# what season of MNP is it?
my $season = 18;

# json utility object
my $json = new JSON::XS;
$json->canonical(1);

my $query = CGI->new; # create new CGI object
my $q = $query->param('q');
my $qjson = $query->param('json');
my $default = $query->param('default');
my $team = $query->param('team');
my $playerinfodump = $query->param('playerinfodump');
my $missingipr = $query->param('missingipr');
my $venue = $query->param('venue');
my $iprlower = $query->param('iprlower');
my $ipr = $query->param('ipr');
my $noteam = $query->param('noteam');
my $debugmode = $query->param('d');

if (!$qjson && ($q || $default || $team || $missingipr || $playerinfodump || $iprlower || $ipr || $venue)) {
	print $query->header; # create the HTTP header
	print $query->start_html(-title=>'MNP Search Results', -meta=>{'viewport'=>'width=device-width, initial-scale=1'},
								-script=>[{-type=>'javascript', -src=>'js/sorttable.js'},{-type=>'javascript', -src=>'js/jquery-3.3.1.min.js'},{-type=>'javascript', -src=>'js/jquery.sparkline.min.js'},{-type=>'javascript',-code=>"\$(function() {\n\$(\'.inlinerank\').sparkline(\'html\', {type: \'box\', width: \'75\', height: \'8\', raw: false, boxLineColor: \'#5d1e5d\', boxFillColor: \'#ffffff\', disableTooltips: \'true\'} );\n\$(\'.inlinempr\').sparkline(\'html\', {type: \'box\', width: \'75\', height: \'8\', raw: true, minValue: 1000, maxValue: 2000, outlierLineColor: \'#000000\', medianColor: \'#5d1e5d\', lineColor: \'#5d1e5d\', whiskerColor: \'#5d1e5d\', boxLineColor: \'#5d1e5d\', boxFillColor: \'#a582a5\', disableTooltips: \'true\'} );});\n"}],
								-style=>[{-src=>'css/normalize.css'}, {-src=>'css/skeleton.css'}, {-src=>'https://fonts.googleapis.com/css?family=Montserrat'}, {-src=>'css/font-awesome.min.css'}, {-src=>'css/bootstrap.min.css'}, {-src=>'css/iprsearch.css'}], -head=>Link({-rel=>'icon', -type=>'image/png', -href=>'images/favicon.ico'}));
	print "<br/>\n<div class=\"container\"><form action=\"iprsearch.pl\" method=\"get\">\n<input class=\"u-full-width\" type=\"search\" id=\"searchInput\" name=\"q\">\n<div class=\"ten columns\"><input class=\"button-primary five columns offset-by-four\" type=\"submit\" value=\"Player Search\"></div>\n</form></div>";
}
elsif ($qjson) {
	print $query->header('application/json');
}

# turn off buffering for standard output
select(STDOUT);
$| = 1;

# setup LWP and Scraper 
my $ua = LWP::UserAgent->new;
my $res = "";

if ($q) { $q =~ s/^\s+|\s+$//g; } # trim leading/trailing spaces 

my $logfile = "iprsearchlog.txt";
my $searchinfo = &loadJSON("searchinfo.json");
my $teaminfo = {};
my $addedtocache = 0;
my $indexpicture = "";

$ratingsdate = &getLastMPRatingDate();
&getTeamInfo();

if ($default && $default eq "pics") {
	&resultsPictures();
}
elsif ($default && $default eq "playerinfo") {
	&resultsPlayerinfo();
}
elsif ($default && $default eq "searchinfo") {
	&resultsSearchinfo();
}
elsif ($team) {
	&resultsTeam();
}
elsif ($playerinfodump) {
	&playerInfoDump();
}
elsif ($missingipr) {
	&resultsMissingIPR();
}
elsif ($iprlower) {
	&resultsIPRlower();
}
elsif ($ipr) {
	&resultsIPR();
}
elsif ($venue) {
	&resultsVenue();
}
elsif ($qjson && $qjson =~ /^\d+?$/) {
	my $IFPAid = int($qjson);

	# check IFPA ID against loaded searchinfo.json, if found, print that info and quit
	if ($searchinfo->{IFPA}->{$IFPAid} && ($searchinfo->{players}->{$searchinfo->{IFPA}->{$IFPAid}}->{MP_LB} != 1250)) {
		&resultsIFPAjson($IFPAid);
	}
	else {
		&queryIFPA($IFPAid);
		&saveJSON($searchinfo, "searchinfo.json");
		&resultsIFPAjson($IFPAid);
	}
}
elsif ($qjson) {
	my $namematch = $qjson;

	if (length($namematch) < 4) {
		print "<div id='content'>";
		print h3("Searches must be at least 4 characters. Try again.");
		print "</div>";
		print br;
		print $query->end_html; # end the HTML
		exit 0;
	}

	&queryName($namematch);
	&saveJSON($searchinfo, "searchinfo.json");

	# search for results
	my @cachedresults = &searchName($namematch);
	my $cachedresultscount = scalar @cachedresults;
	if ($cachedresultscount > 0) {
		&resultsNameJson(@cachedresults);
	}
	else {
		print "{}";
		my $searchdetails = "\"JSON=$qjson\" found 0 results (" . &timeElapsed() . " seconds [MPR: $ratingsdate]";
		&logMessage("$searchdetails");
		exit 0;
	}
}
elsif ($q && $q =~ /^\d+?$/) {
	my $IFPAid = int($q);
	# check IFPA ID against loaded searchinfo.json, if found, print that info and quit
	if ($searchinfo->{IFPA}->{$IFPAid} && ($searchinfo->{players}->{$searchinfo->{IFPA}->{$IFPAid}}->{MP_LB} != 1250)) {
		&resultsIFPA($IFPAid);
	}
	else {
		&queryIFPA($IFPAid);
		&saveJSON($searchinfo, "searchinfo.json");
		&resultsIFPA($IFPAid);
	}
}
elsif ($q) {
	my $namematch = $q;

	if (length($namematch) == 3) {
		&resultsTeamOrVenue($namematch);
	}
	elsif (length($namematch) < 4) {
		print "<div id='content'>";
		print h3("Searches must be at least 4 characters. Try again.");
		print "</div>";
		print br;
		print $query->end_html; # end the HTML
		exit 0;
	}

	&queryName($namematch);
	&saveJSON($searchinfo, "searchinfo.json");

	# search for results
	my @cachedresults = &searchName($namematch);
	my $cachedresultscount = scalar @cachedresults;
	if ($cachedresultscount > 0) {
		&resultsName(@cachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}
elsif (!$q && !$qjson && $qjson eq "0") {
	print $query->header('application/json');
	print "{}";
	my $searchdetails = "\"JSON=$qjson\" found 0 results (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	&logMessage("$searchdetails");
	exit 0;
}
else {
	print $query->redirect('/search/');
	exit 0;
}

if (!$qjson) {
	print $query->end_html; # end the HTML
}

&updateIndexHTML();

# get the most recent Ratings date from MP
sub getLastMPRatingDate {
	my $ratingsPage = "";
	my $ratingsURL = "https://matchplay.events/live/ratings";
	$ua->ssl_opts( verify_hostname => 0 ,SSL_verify_mode => 0x00);
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $ratingsURL));
	if ($debugmode){ print("DEBUG: GET " . $ratingsURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$ratingsPage = $res->decoded_content;
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [" . $ratingsURL . "]: " . $res->status_line . "</FONT>\n"); exit 1; }

	my $scraper = scraper { process '//div[contains(@class, "box")]//a', 'ratingperiod' => 'TEXT';
						};
	my $tempratings  = $scraper->scrape($ratingsPage);
	my $tempdate = $tempratings->{ratingperiod};

	my %map = ( 'Jan' => '1', 'Feb' => '2', 'Mar' => '3', 'Apr' => '4',
				'May' => '5', 'Jun' => '6', 'Jul' => '7', 'Aug' => '8',
				'Sep' => '9', 'Oct' => '10', 'Nov' => '11', 'Dec' => '12');
	$tempdate =~ s/(...) (.*), (....)/$3-$map{$1}-$2/;
	my ($year, $month, $day) = split /-/, $tempdate;
	my $dtRatingsDate = DateTime->new( 
		year   => $year,
		month  => $month,
		day    => $day
	);
	my $dtDuration = DateTime::Duration->new( days => 1 );	
	my $dtQuery = $dtRatingsDate->subtract_duration($dtDuration);
	$tempdate = $dtQuery->ymd;
	
	return $tempdate;
}

# print to log
sub logMessage {
	my $dtCurrent = DateTime->now;
	my $message = $dtCurrent->ymd . " " . $dtCurrent->hms . " " . $_[0] . " [$addedtocache new players saved]";
	open (LOGFILE, ">>" . $logfile);
	print LOGFILE $message . "\n";
	close (LOGFILE);
}

# save the object to a JSON file
sub saveJSON {
	if ($addedtocache > 0){ 
		my $object = $_[0];
		my $filename = $_[1];
		my $content = &encodeJSON(\%$object);
		chomp($content); #strip any surrounding whitespace and weirdness
		open(my $fh, '>:encoding(UTF-8)', $filename);
		print $fh $content;
		close($fh);
	}
}

# load the object from a JSON file
sub loadJSON {
	my $content = read_file($_[0], binmode => ':utf8');
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
	return $json->allow_nonref->utf8->relaxed->decode($content);
}

# read the IPR.csv file to get IPR values for known players
sub readIPRCSV {
	# my $MNPIPRURL = "https://raw.githubusercontent.com/mondaynightpinball/data-archive/master/season-$season/IPR.csv";
	# my $MNPIPRURL = "https://raw.githubusercontent.com/mondaynightpinball/data-archive/master/season-13/IPR.csv";
	my $MNPIPRURL = "http://pinballstats.info/search/IPR.csv";
	my $MNPIPRPage = "";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $MNPIPRURL));
	if ($debugmode){ print("DEBUG: GET " . $MNPIPRURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$MNPIPRPage = $res->decoded_content;
		for (split /\n/, $MNPIPRPage) {
			my $line = $_;
			my ($mnpIPR, $playername) = split /,/, $line;
			$teaminfo->{player}->{lc($playername)}->{mnpipr} = $mnpIPR;
			# player IPR from IPR.csv overrides IPR saved in search results
			$searchinfo->{players}->{$playername}->{IPR} = $mnpIPR;
		}
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPIPRURL . "]: " . $res->status_line . "</FONT>\n"); }
}

# return total elapsed time
sub timeElapsed {
	my $now_time = DateTime->from_epoch( epoch => time );
	my $run_time = $now_time - $start_run;
	my $result = $run_time->in_units('seconds');
	if ($result == 0) {
		$result = ($run_time->in_units('nanoseconds')) / 1000000000;
		return sprintf('%.1g', $result);
	}
	return $result;
}

# return URL to picture
sub getPicture {
	my $IFPAid = $_[0];
	my $name = $_[1];

	if ($IFPAid && (-e "pics/$IFPAid.png")) {
		$indexpicture = $IFPAid;
		return "pics/$IFPAid.png";
	}
	elsif (-e "pics/$name.png") {
		$indexpicture = $name;
		return "pics/$name.png";
	}
	else {
		return "pics/blank.png";
	}
}

sub updateIndexHTML {
	if ($indexpicture && (-e "pics/$indexpicture.png")) {
		my $content = read_file("index.html", binmode => ':utf8');
		my $prepiccontent = substr($content, 0, (index($content, "pics/") + 5));
		my $postpiccontent = substr($content, (index($content, ".png")));
		$content = $prepiccontent . $indexpicture . $postpiccontent;
		open(my $fh, '>:encoding(UTF-8)', "index.html");
		print $fh $content;
		close($fh);
		my $playername = $searchinfo->{IFPA}->{$indexpicture};
		if ($playername) {
			&logMessage("updated index.html (" . $indexpicture . ", $playername)");
		}
		else {
			&logMessage("updated index.html (" . $indexpicture . ")");
		}
	}
}

sub trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

sub getTeamInfo {
	# get MNP team associations
	# my $MNPPlayerDBURL = "https://raw.githubusercontent.com/mondaynightpinball/data-archive/master/season-$season/playerdb.csv";
	#my $MNPPlayerDBURL = "https://raw.githubusercontent.com/Invader-Zim/mnp-data-archive/master/season-$season/rosters.csv";
	my $MNPPlayerDBURL = "https://mondaynightpinball.com/rosters.csv";
	my $MNPPlayerDBPage = "";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $MNPPlayerDBURL));
	if ($debugmode){ print("DEBUG: GET " . $MNPPlayerDBURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$MNPPlayerDBPage = $res->decoded_content;
		for (split /^/, $MNPPlayerDBPage) {
			my $line = $_;
			# my ($name, $teamcode, $role, $IFPAid, $division) = split /,/, $line;
			my ($name, $teamcode, $role) = split /,/, $line;
			if ($name) {
				$teaminfo->{player}->{lc($name)}->{name} = trim($name);
				$teaminfo->{player}->{lc($name)}->{teamcode} = $teamcode;
				$teaminfo->{player}->{lc($name)}->{role} = substr($role, 0, 1);
				# $teaminfo->{player}->{lc($name)}->{IFPA} = $IFPAid;
				# $teaminfo->{player}->{lc($name)}->{division} = $division;
			}
		}
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPPlayerDBURL . "]: " . $res->status_line . "</FONT>\n"); }
	
	# my $MNPTeamsURL = "https://raw.githubusercontent.com/mondaynightpinball/data-archive/master/season-$season/teams.csv";
	my $MNPTeamsURL = "https://raw.githubusercontent.com/Invader-Zim/mnp-data-archive/master/season-$season/teams.csv";
	my $MNPTeamsPage = "";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $MNPTeamsURL));
	if ($debugmode){ print("DEBUG: GET " . $MNPTeamsURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$MNPTeamsPage = $res->decoded_content;
		for (split /^/, $MNPTeamsPage) {
			my $line = $_;
			my ($teamcode, $venuecode, $teamname, $division) = split /,/, $line;
			chomp $division;
			$teaminfo->{team}->{$teamcode}->{name} = $teamname;
			$teaminfo->{team}->{$teamcode}->{venuecode} = $venuecode;
			$teaminfo->{team}->{$teamcode}->{division} = $division;
		}
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPTeamsURL . "]: " . $res->status_line . "</FONT>\n"); }
	
	# my $MNPVenuesURL = "https://raw.githubusercontent.com/mondaynightpinball/data-archive/master/season-$season/venues.json";
	# my $MNPVenuesPage = "";
	# $res = $ua->request(HTTP::Request->new(GET => $MNPVenuesURL));
	# if ($debugmode){ print("DEBUG: GET " . $MNPVenuesURL . ": " . $res->status_line . "\n"); }
	# if ($res->is_success) {
		# $MNPVenuesPage = $res->decoded_content;
		
		# my $tempVenues = &decodeJSON($MNPVenuesPage);
		# foreach my $venuecode (sort keys(%{$tempVenues})) {
			# $teaminfo->{venue}->{$venuecode}->{name} = $tempVenues->{$venuecode}->{name};
		# }
	# }
	# else {
		# print("Team [GET " . $MNPVenuesURL . "]: " . $res->status_line . "\n");
	# }
	
	my $MNPVenuesURL = "https://raw.githubusercontent.com/Invader-Zim/mnp-data-archive/master/season-$season/venues.csv";
	my $MNPVenuesPage = "";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $MNPVenuesURL));
	if ($debugmode){ print("DEBUG: GET " . $MNPVenuesURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$MNPVenuesPage = $res->decoded_content;
		for (split /^/, $MNPVenuesPage) {
			my $line = $_;
			my ($venuecode, $venuename) = split /,/, $line;
			$teaminfo->{venue}->{$venuecode}->{name} = $venuename;
		}
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPVenuesURL . "]: " . $res->status_line . "</FONT>\n"); }
	
	foreach my $playername (keys(%{$searchinfo->{players}})) {
		if (!exists($searchinfo->{players}->{$playername}->{IFPA_ID}) &&
			!exists($searchinfo->{players}->{$playername}->{IPR}) &&
			!exists($searchinfo->{players}->{$playername}->{MP_LB}) &&
			!exists($searchinfo->{players}->{$playername}->{IFPA_dateupdated}) &&
			!exists($searchinfo->{players}->{$playername}->{MP_dateupdated})) {
			delete $searchinfo->{players}->{$playername};
			next;
		}		
		my $IFPAdateupdated = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		my $MPdateupdated = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		if (!$IFPAdateupdated && !$MPdateupdated && !($teaminfo->{player}->{lc($playername)}->{teamcode})) {
			$teaminfo->{player}->{lc($playername)}->{teamcode} = "MNP";
			$teaminfo->{team}->{"MNP"}->{name} = "legacy player";
			$teaminfo->{player}->{lc($playername)}->{name} = $playername;
			# $teaminfo->{player}->{lc($playername)}->{role} = "P";
		}
	}
}

# calculate IPR for player name
sub calculateIPR {
	my $playername = $_[0];
	my $IFPA_IPR = 0;
	my $MP_IPR = 0;
	my $IPR = 0;
	if ($searchinfo->{players}->{$playername}->{IFPA_RANK}) {
		my $IFPArank = $searchinfo->{players}->{$playername}->{IFPA_RANK};
		if ($IFPArank < $searchinfo->{thresholds}->{IFPA6}) {
			$IFPA_IPR = 6;
		}
		elsif ($IFPArank < $searchinfo->{thresholds}->{IFPA5}) {
			$IFPA_IPR = 5;
		}
		elsif ($IFPArank < $searchinfo->{thresholds}->{IFPA4}) {
			$IFPA_IPR = 4;
		}
		elsif ($IFPArank < $searchinfo->{thresholds}->{IFPA3}) {
			$IFPA_IPR = 3;
		}
		elsif ($IFPArank < $searchinfo->{thresholds}->{IFPA21}) {
			$IFPA_IPR = 2;
		}
		else {
			$IFPA_IPR = 1;
		}
	}
	else {
		$IFPA_IPR = 1;
	}
	if ($searchinfo->{players}->{$playername}->{MP_LB}) {
		my $lb = $searchinfo->{players}->{$playername}->{MP_LB};
		if ($lb > $searchinfo->{thresholds}->{MP6}) {
			$MP_IPR = 6;
		}
		elsif ($lb > $searchinfo->{thresholds}->{MP5}) {
			$MP_IPR = 5;
		}
		elsif ($lb > $searchinfo->{thresholds}->{MP4}) {
			$MP_IPR = 4;
		}
		elsif ($lb > $searchinfo->{thresholds}->{MP3}) {
			$MP_IPR = 3;
		}
		elsif ($lb > $searchinfo->{thresholds}->{MP21}) {
			$MP_IPR = 2;
		}
		else {
			$MP_IPR = 1;
		}
	}
	else {
		$MP_IPR = 1;
	}
	$searchinfo->{players}->{$playername}->{IPR} = ($MP_IPR > $IFPA_IPR) ? $MP_IPR : $IFPA_IPR;
}

# search for name in cache
sub searchName {
	my $namematch = $_[0];
	my @cachedresults;
	my $matchesfound = {};
	# sort identified MNP players to the top of search results
	foreach my $playername (sort keys(%{$searchinfo->{players}})) {
		if (exists($teaminfo->{player}->{lc($playername)}->{teamcode})) {
			if (index(lc($playername), lc($namematch)) > -1) {				# substring matches on team
				if (!exists($matchesfound->{$playername})) {
					push @cachedresults, $playername;
					$matchesfound->{$playername} = 1;
				}
			}
		}
	}
	foreach my $playername2 (sort keys(%{$searchinfo->{players}})) {
		if (exists($teaminfo->{player}->{lc($playername2)}->{teamcode})) {
			my $similarity = similarity lc($playername2), lc($namematch);
			if ($similarity > 0.75) {										# fuzzy matches on team
				if (!exists($matchesfound->{$playername2})) {
					push @cachedresults, $playername2;
					$matchesfound->{$playername2} = 1;
				}
			}
		}
	}
	# then sort non-MNP players
	foreach my $playername3 (sort keys(%{$searchinfo->{players}})) {
		if (!exists($teaminfo->{player}->{lc($playername3)}->{teamcode})) {
			if (index(lc($playername3), lc($namematch)) > -1) {				# substring matches not on team
				if (!exists($matchesfound->{$playername3})) {
					push @cachedresults, $playername3;
					$matchesfound->{$playername3} = 1;
				}
			}
		}
	}
	foreach my $playername4 (sort keys(%{$searchinfo->{players}})) {
		if (!exists($teaminfo->{player}->{lc($playername4)}->{teamcode})) {
			my $similarity = similarity lc($playername4), lc($namematch);
			if ($similarity > 0.75) {										# fuzzy matches not on team
				if (!exists($matchesfound->{$playername4})) {
					push @cachedresults, $playername4;
					$matchesfound->{$playername4} = 1;
				}
			}
		}
	}
	return @cachedresults;
}

# query externally for IFPA ID
sub queryIFPA {
	my $IFPAid = $_[0];

	# get IFPA rank for IFPA ID
	my $IFPAURL = "https://api.ifpapinball.com/v1/player/$IFPAid?api_key=6655c7e371c30c5cecda4a6c8ad520a4";
	my $IFPAPage = "";
	my $playername = "";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $IFPAURL));
	if ($debugmode){ print("DEBUG: GET " . $IFPAURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$IFPAPage = $res->decoded_content;
		my $IFPAresponse = &decodeJSON($IFPAPage);
		if ($IFPAresponse->{player}->{player_id}) {
			$playername = $IFPAresponse->{player}->{first_name} . " " . $IFPAresponse->{player}->{last_name};
			$playername =~ s/^\s+|\s+$//g; # trim leading/trailing spaces
			if ($playername) {
				$searchinfo->{IFPA}->{$IFPAid} = $playername;
				$searchinfo->{players}->{$playername}->{IFPA_dateupdated} = $currentdate;
				$searchinfo->{players}->{$playername}->{IFPA_ID} = $IFPAresponse->{player}->{player_id};
				$searchinfo->{players}->{$playername}->{IFPA_RANK} = $IFPAresponse->{player_stats}->{current_wppr_rank};
				if ($playername eq "Suppresed Player") {
					$searchinfo->{players}->{$playername}->{IFPA_RANK} = 149;
				}
			}
		}
		else {
			if ($qjson) {
				print "{}";
				my $searchdetails = "\"JSON=$qjson\" found 0 results (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
				&logMessage("$searchdetails");
			}
			else {
				&noResults();
				print $query->end_html; # end the HTML
			}
			exit 0;
		}
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $IFPAURL . "]: " . $res->status_line . "</FONT>\n"); }
	
	# get Matchplay ratings for IFPA ID
	my $matchplayPage = "";
	my $matchplayURL = "https://matchplay.events/data/ifpa/ratings/$ratingsdate/$IFPAid";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $matchplayURL));
	if ($debugmode){ print("DEBUG: GET " . $matchplayURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$matchplayPage = $res->decoded_content;
		my $matchplayresponse = &decodeJSON($matchplayPage);
		$searchinfo->{players}->{$playername}->{MP_dateupdated} = $ratingsdate;
		$searchinfo->{players}->{$playername}->{MP_LB} = $matchplayresponse->{$IFPAid}->{lower_bound};
		$searchinfo->{players}->{$playername}->{MP_RD} = $matchplayresponse->{$IFPAid}->{rd};
		
		if ($searchinfo->{players}->{$playername}->{MP_LB} == 1250){
			# get Matchplay ratings for player names
			my $searchPage = "";
			my $searchURL = "https://matchplay.events/live/ratings/search?query=" . &url_encode($playername);
			$ua->timeout(10);
			$res = $ua->request(HTTP::Request->new(GET => $searchURL));
			if ($debugmode){ print("DEBUG: GET " . $searchURL . ": " . $res->status_line . "\n"); }
			if ($res->is_success) {
				$searchPage = $res->decoded_content;
			}
			else { print("<FONT COLOR=\"#ff0000\">ERROR [" . $searchURL . "]: " . $res->status_line . "</FONT>\n"); exit 1; }

			my $scraper = scraper { process '//tr/td[1]/a', 'links[]' => '@href';
									process '//tr/td[1]/a', 'names[]' => 'TEXT';
									process '//tr/td[2]', 'ratings[]' => 'TEXT';
								};
			my $playertemp  = $scraper->scrape($searchPage);

			my $mpnewplayers = {};
			my $i = 0;
			if ($playertemp->{links}) {
				while ($i < @{$playertemp->{links}}) {
					if ($playertemp->{links}[$i]) {
						if ($playertemp->{names} && $playertemp->{names}[$i] && $playertemp->{ratings} && $playertemp->{ratings}[$i]) {
							my $mpplayername = $playertemp->{names}[$i];
							my ($rating, $delta) = split / ±/, $playertemp->{ratings}[$i];
							if ($mpnewplayers->{players}->{$mpplayername}) {
								# if already found in new player, overwrite if the RD is lower
								if ($mpnewplayers->{players}->{$mpplayername}->{MP_RD} > ($delta/2)) {
									$mpnewplayers->{players}->{$mpplayername}->{MP_LB} = $rating-$delta;
									$mpnewplayers->{players}->{$mpplayername}->{MP_RD} = $delta/2;
									$searchinfo->{players}->{$mpplayername}->{MP_dateupdated} = $ratingsdate;
									$searchinfo->{players}->{$mpplayername}->{MP_LB} = $rating-$delta;
									$searchinfo->{players}->{$mpplayername}->{MP_RD} = $delta/2;
									my $searchdetails = "MPR1250, IPR update ($mpplayername, " . $searchinfo->{players}->{$mpplayername}->{MP_LB} . ")";
									&logMessage("$searchdetails");
								}
							}
							else {
								$mpnewplayers->{players}->{$mpplayername}->{MP_LB} = $rating-$delta;
								$mpnewplayers->{players}->{$mpplayername}->{MP_RD} = $delta/2;
								$searchinfo->{players}->{$mpplayername}->{MP_dateupdated} = $ratingsdate;
								$searchinfo->{players}->{$mpplayername}->{MP_LB} = $rating-$delta;
								$searchinfo->{players}->{$mpplayername}->{MP_RD} = $delta/2;
								my $searchdetails = "MPR1250, IPR update ($mpplayername, " . $searchinfo->{players}->{$mpplayername}->{MP_LB} . ")";
								&logMessage("$searchdetails");
							}
						}
					}
					$i++;
				}
			}
		}
		
		&calculateIPR($playername);
		$addedtocache = 1;
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $matchplayURL . "]: " . $res->status_line . "</FONT>\n"); }
}

# query externally for player name
sub queryName {
	my $namematch = $_[0];
	my $cleanednamematch = $namematch;
	$cleanednamematch =~ s/'/ /ig; # replace apostrophe with space for IFPA matching
	# get IFPA ratings for player names
	my $IFPAURL = "https://api.ifpapinball.com/v1/player/search?api_key=6655c7e371c30c5cecda4a6c8ad520a4&q=$cleanednamematch";
	my $IFPAPage = "";
	$ua->timeout(10);
	$res = $ua->request(HTTP::Request->new(GET => $IFPAURL));
	if ($debugmode){ print("DEBUG: GET " . $IFPAURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$IFPAPage = $res->decoded_content;
		my $IFPAresponse = &decodeJSON($IFPAPage);
		
		if($IFPAresponse->{search} && $IFPAresponse->{search} ne "No players found") {
			foreach my $player (@{$IFPAresponse->{search}}) {
				# look for IFPAid in searchinfo.json
				my $IFPAid = $player->{player_id};
				if ($searchinfo->{IFPA}->{$IFPAid}) {
					# we already have this IFPAid, so skip it
				}
				else {
					# add this player to searchinfo.json
					my $playername = $player->{first_name} . " " . $player->{last_name};
					$playername =~ s/^\s+|\s+$//g; # trim leading/trailing spaces
					$searchinfo->{IFPA}->{$IFPAid} = $playername;
					$searchinfo->{players}->{$playername}->{IFPA_dateupdated} = $currentdate;
					$searchinfo->{players}->{$playername}->{IFPA_ID} = $IFPAid;
					$searchinfo->{players}->{$playername}->{IFPA_RANK} = $player->{wppr_rank};
					
					# get Matchplay ratings for IFPA ID
					my $matchplayPage = "";
					my $matchplayURL = "https://matchplay.events/data/ifpa/ratings/$ratingsdate/$IFPAid";
					$ua->timeout(10);
					$res = $ua->request(HTTP::Request->new(GET => $matchplayURL));
					if ($debugmode){ print("DEBUG: GET " . $matchplayURL . ": " . $res->status_line . "\n"); }
					if ($res->is_success) {
						$matchplayPage = $res->decoded_content;
						my $matchplayresponse = &decodeJSON($matchplayPage);
						$searchinfo->{players}->{$playername}->{MP_dateupdated} = $ratingsdate;
						$searchinfo->{players}->{$playername}->{MP_LB} = $matchplayresponse->{$IFPAid}->{lower_bound};
						$searchinfo->{players}->{$playername}->{MP_RD} = $matchplayresponse->{$IFPAid}->{rd};
						&calculateIPR($playername);
						$addedtocache++;
					}
					else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $matchplayURL . "]: " . $res->status_line . "</FONT>\n"); }
				}
			}
		}
	}
	else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $IFPAURL . "]: " . $res->status_line . "</FONT>\n"); }
	
	
	# get Matchplay ratings for player names
	my $searchPage = "";
	my $searchURL = "https://matchplay.events/live/ratings/search?query=" . &url_encode($namematch);
	$res = $ua->request(HTTP::Request->new(GET => $searchURL));
	if ($debugmode){ print("DEBUG: GET " . $searchURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$searchPage = $res->decoded_content;
	}
	else { print("ERROR [" . $searchURL . "]: " . $res->status_line . "\n"); exit 1; }

	my $scraper = scraper { process '//tr/td[1]/a', 'links[]' => '@href';
							process '//tr/td[1]/a', 'names[]' => 'TEXT';
							process '//tr/td[2]', 'ratings[]' => 'TEXT';
						};
	my $playertemp  = $scraper->scrape($searchPage);

	my $mpnewplayers = {};
	my $i = 0;
	if ($playertemp->{links}) {
		while ($i < @{$playertemp->{links}}) {
			if ($playertemp->{links}[$i]) {
				if ($playertemp->{names} && $playertemp->{names}[$i] && $playertemp->{ratings} && $playertemp->{ratings}[$i]) {
					my $mpplayername = $playertemp->{names}[$i];
					# look for name in searchinfo.json
					my $found = 0;
					my $existingname = "";
					foreach my $cachedname (keys(%{$searchinfo->{players}})) {
						if (lc($cachedname) eq lc($mpplayername)) {
							$found = 1;
							$existingname = $cachedname;
						}
					}
					# if name not found in searchinfo.json, add it to $mpnewplayers
					my ($rating, $delta) = split / ±/, $playertemp->{ratings}[$i];
					if ($found == 0) {
						if ($mpnewplayers->{players}->{$mpplayername}) {
							# if already found in new player, overwrite if the RD is lower
							if ($mpnewplayers->{players}->{$mpplayername}->{MP_RD} > ($delta/2)) {
								$mpnewplayers->{players}->{$mpplayername}->{MP_LB} = $rating-$delta;
								$mpnewplayers->{players}->{$mpplayername}->{MP_RD} = $delta/2;
							}
						}
						else {
							$mpnewplayers->{players}->{$mpplayername}->{MP_LB} = $rating-$delta;
							$mpnewplayers->{players}->{$mpplayername}->{MP_RD} = $delta/2;
						}
					}
					else {
						# player was found, but may be a buggy default from Matchplay Ratings -- override with results from name search
						if ($searchinfo->{players}->{$mpplayername}->{MP_LB} && $searchinfo->{players}->{$mpplayername}->{MP_LB} == 1250){
							$searchinfo->{players}->{$existingname}->{MP_dateupdated} = $ratingsdate;
							$searchinfo->{players}->{$existingname}->{MP_LB} = $rating-$delta;
							$searchinfo->{players}->{$existingname}->{MP_RD} = $delta/2;
							my $searchdetails = "MPR1250, IPR update ($existingname, " . $searchinfo->{players}->{$existingname}->{MP_LB} . ")";
							&logMessage("$searchdetails");
							&calculateIPR($existingname);
						}
						else {
							if ($existingname ne $mpplayername) {
								delete $searchinfo->{players}->{$mpplayername};
							}
						}
					}
				}
			}
			$i++;
		}
	}

	# if we found any new names, move them to searchinfo.json
	foreach my $newcachedname (keys(%{$mpnewplayers->{players}})) {
		$searchinfo->{players}->{$newcachedname}->{MP_dateupdated} = $ratingsdate;
		$searchinfo->{players}->{$newcachedname}->{MP_LB} = $mpnewplayers->{players}->{$newcachedname}->{MP_LB};
		$searchinfo->{players}->{$newcachedname}->{MP_RD} = $mpnewplayers->{players}->{$newcachedname}->{MP_RD};
		$searchinfo->{players}->{$newcachedname}->{IFPA_dateupdated} = $currentdate;
		$searchinfo->{players}->{$newcachedname}->{IFPA_ID} = 0;
		$searchinfo->{players}->{$newcachedname}->{IFPA_RANK} = 32767;
		$addedtocache++;
		&calculateIPR($newcachedname);
		# get IFPA ratings for new name
		my $IFPAURL = "https://api.ifpapinball.com/v1/player/search?api_key=6655c7e371c30c5cecda4a6c8ad520a4&q=$newcachedname";
		my $IFPAPage = "";
		$ua->timeout(10);
		$res = $ua->request(HTTP::Request->new(GET => $IFPAURL));
		if ($debugmode){ print("DEBUG: GET " . $IFPAURL . ": " . $res->status_line . "\n"); }
		if ($res->is_success) {
			$IFPAPage = $res->decoded_content;
			my $IFPAresponse = &decodeJSON($IFPAPage);
			if($IFPAresponse->{search} && $IFPAresponse->{search} ne "No players found") {
				foreach my $player (@{$IFPAresponse->{search}}) {
					# look for IFPAid in searchinfo.json
					my $IFPAid = $player->{player_id};
					if ($searchinfo->{IFPA}->{$IFPAid}) {
						# we already have this IFPAid, so skip it
					}
					else {
						# add this player to searchinfo.json
						my $playername = $player->{first_name} . " " . $player->{last_name};
						$playername =~ s/^\s+|\s+$//g; # trim leading/trailing spaces
						$searchinfo->{IFPA}->{$IFPAid} = $playername;
						$searchinfo->{players}->{$playername}->{IFPA_dateupdated} = $currentdate;
						$searchinfo->{players}->{$playername}->{IFPA_ID} = $IFPAid;
						$searchinfo->{players}->{$playername}->{IFPA_RANK} = $player->{wppr_rank};
						&calculateIPR($playername);
					}
				}
			}
		}
		else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $IFPAURL . "]: " . $res->status_line . "</FONT>\n"); }
	}
}

sub noResults {
	print "<div id='content'>";
	my $searchdetails = "\"" . $q . "\" found 0 results (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	print table({-class=>'table sortable'}, caption($searchdetails),
		Tr({-class=>'header-row'},
			th(""), th("Name"), th({-class=>'text-xs-center'}, "IPR"), th({-class=>'text-xs-center'}, "Matchplay LB"), th({-class=>'text-xs-center'}, "IFPA Rank"))
		);
	print "</div>";
	print br;
	&logMessage("$searchdetails");
}

sub resultsPlayerinfo {
	my @cachedresults;
	foreach my $playername (sort keys(%{$searchinfo->{players}})) {
		my $IFPAdateupdated = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		my $MPdateupdated = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		if (!$IFPAdateupdated && !$MPdateupdated) {
			if ($noteam == 1) {
				if ($teaminfo->{player}->{lc($playername)}->{teamcode} eq "MNP") {
					push @cachedresults, $playername;	# found a player from original playerinfo.json not on a team
				}
			}
			else  {
				push @cachedresults, $playername;	# found a player from original playerinfo.json
			}
		}
	}
	my @sorted_cachedresults = sort @cachedresults;
	my $cachedresultscount = scalar @sorted_cachedresults;
	if ($cachedresultscount > 0) {
		&resultsName(@sorted_cachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsSearchinfo {
	my @cachedresults;
	foreach my $playername (sort keys(%{$searchinfo->{players}})) {
		my $IFPAdateupdated = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		my $MPdateupdated = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		if ($IFPAdateupdated || $MPdateupdated) {
			if ($noteam == 1) {
				if ($teaminfo->{player}->{lc($playername)}->{teamcode} eq "MNP") {
					push @cachedresults, $playername;	# found a player added by search not on a team
				}
			}
			else  {
				push @cachedresults, $playername;	# found a player added by search
			}
		}
	}
	my @sorted_cachedresults = sort @cachedresults;
	my $cachedresultscount = scalar @sorted_cachedresults;
	if ($cachedresultscount > 0) {
		&resultsNameBasic(@sorted_cachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsPictures {
	my @files = <../search/pics/*.png>;
	my @cachedresults;
	foreach my $file (@files) {
		my $filename = substr($file, (index($file, "pics/") + 5), rindex($file, ".")-(index($file, "pics/") + 5));
		if ($filename =~ /^\d+?$/) {
			my $IFPAid = int($filename);
			# check IFPA ID against loaded searchinfo.json, if found, add to result set
			if ($searchinfo->{IFPA}->{$IFPAid}) {
				my $playername = $searchinfo->{IFPA}->{$IFPAid};
				push @cachedresults, $playername;	# found a match
			}
			else {
				&queryIFPA($IFPAid);
				&saveJSON($searchinfo, "searchinfo.json");
			}
		}
		else {
			my $namematch = $filename;
			if ($namematch ne "blank") {
				my $found = 0;
				foreach my $playername (sort keys(%{$searchinfo->{players}})) {
					if (index(lc($playername), lc($namematch)) > -1) {
						push @cachedresults, $playername;	# found a match
						$found = 1;
						last;
					}
				}
				if (!$found) {
					&queryName($namematch);
					&saveJSON($searchinfo, "searchinfo.json");
				}
			}
		}
	}
	my @sorted_cachedresults = sort @cachedresults;
	my $cachedresultscount = scalar @sorted_cachedresults;
	if ($cachedresultscount > 0) {
		&resultsName(@sorted_cachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsTeam {
	my @teamcachedresults;
	foreach my $playername (keys(%{$teaminfo->{player}})) {
		if (lc($teaminfo->{player}->{lc($playername)}->{teamcode}) eq lc($team)) {
			push @teamcachedresults, $teaminfo->{player}->{$playername}->{name};	# found a match
		}
	}
	my @sorted_teamcachedresults = sort @teamcachedresults;
	my $teamcachedresultscount = scalar @sorted_teamcachedresults;
	if ($teamcachedresultscount > 0) {
		&resultsName(@sorted_teamcachedresults);
		print $query->end_html; # end the HTML
		exit 0;
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsMissingIPR {
	my $cachedplayerslc = {};
	foreach my $playername (keys(%{$searchinfo->{players}})) {
		my $lcname = lc($playername);
		$cachedplayerslc->{$lcname}->{IPR} = $searchinfo->{players}->{$playername}->{IPR};
		if (exists($searchinfo->{players}->{$playername}->{IFPA_dateupdated})) {
			$cachedplayerslc->{$lcname}->{IFPA_dateupdated} = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		}
		if (exists($searchinfo->{players}->{$playername}->{MP_dateupdated})) {
			$cachedplayerslc->{$lcname}->{MP_dateupdated} = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		}
	}
	
	my @teamcachedresults;
	foreach my $playername (keys(%{$teaminfo->{player}})) {
		if (!exists($cachedplayerslc->{$playername}) || 
			exists($cachedplayerslc->{$playername}->{IFPA_dateupdated}) ||
			exists($cachedplayerslc->{$playername}->{MP_dateupdated})) {
			push @teamcachedresults, $teaminfo->{player}->{$playername}->{name};	# found a match
		}
	}
	
	my $foundlast = 0;
	for(my $i=1;$i<12;$i++) {
		# get new subs who have played since last update
		my $MNPMatchWeekURL = "https://www.mondaynightpinball.com/match_summary/mnp-$season-$i.json";
		my $MNPMatchWeekPage = "";
		$ua->timeout(10);
		$res = $ua->request(HTTP::Request->new(GET => $MNPMatchWeekURL));
		if ($debugmode){ print("DEBUG: GET " . $MNPMatchWeekURL . ": " . $res->status_line . "\n"); }
		if ($res->is_success) {
			$MNPMatchWeekPage = $res->decoded_content;
			my $tempMatchWeek = &decodeJSON($MNPMatchWeekPage);
			foreach (@{$tempMatchWeek}) {
				my $tempmatch = $_;
				my $teamcode = $tempmatch->{away}->{key};
				foreach (@{$tempmatch->{away}->{lineup}}) {
					my $playername = $_->{name};
					my $lcname = lc($playername);
					$lcname =~ s/^\s+|\s+$//g;
					if (!exists($cachedplayerslc->{$lcname}) || 
						exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
						exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
						if (!(grep( /^$playername$/, @teamcachedresults ))) {
							push @teamcachedresults, $playername;	# found a match
						}
						$teaminfo->{player}->{$lcname}->{teamcode} = $teamcode;	# they subbed for this team
						$teaminfo->{player}->{$lcname}->{lastplayedweek} = $i;
					}
				}
				$teamcode = $tempmatch->{home}->{key};
				foreach (@{$tempmatch->{home}->{lineup}}) {
					my $playername = $_->{name};
					my $lcname = lc($playername);
					$lcname =~ s/^\s+|\s+$//g;
					if (!exists($cachedplayerslc->{$lcname}) || 
						exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
						exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
						if (!(grep( /^$playername$/, @teamcachedresults ))) {
							push @teamcachedresults, $playername;	# found a match
						}
						$teaminfo->{player}->{$lcname}->{teamcode} = $teamcode;	# they subbed for this team
						$teaminfo->{player}->{$lcname}->{lastplayedweek} = $i;
					}
				}
			}
		}
		elsif ($res->code() == 404) {
			$foundlast = 1;
			last;
		}
		else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPMatchWeekURL . "]: " . $res->status_line . "</FONT>\n"); }
	}
	
	if (!$foundlast) {
		for(my $i=91;$i<95;$i++) {
			# get new subs who have played since last update
			my $MNPMatchWeekURL = "https://www.mondaynightpinball.com/match_summary/mnp-$season-$i.json";
			my $MNPMatchWeekPage = "";
			$ua->timeout(10);
			$res = $ua->request(HTTP::Request->new(GET => $MNPMatchWeekURL));
			if ($debugmode){ print("DEBUG: GET " . $MNPMatchWeekURL . ": " . $res->status_line . "\n"); }
			if ($res->is_success) {
				$MNPMatchWeekPage = $res->decoded_content;
				my $tempMatchWeek = &decodeJSON($MNPMatchWeekPage);
				foreach (@{$tempMatchWeek}) {
					my $tempmatch = $_;
					my $teamcode = $tempmatch->{away}->{key};
					foreach (@{$tempmatch->{away}->{lineup}}) {
						my $playername = $_->{name};
						my $lcname = lc($playername);
						$lcname =~ s/^\s+|\s+$//g;
						if (!exists($cachedplayerslc->{$lcname}) || 
							exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
							exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
							push @teamcachedresults, $playername;	# found a match
							$teaminfo->{player}->{$lcname}->{teamcode} = $teamcode;	# they subbed for this team
							$teaminfo->{player}->{$lcname}->{lastplayedweek} = $i;
						}
					}
					$teamcode = $tempmatch->{home}->{key};
					foreach (@{$tempmatch->{home}->{lineup}}) {
						my $playername = $_->{name};
						my $lcname = lc($playername);
						$lcname =~ s/^\s+|\s+$//g;
						if (!exists($cachedplayerslc->{$lcname}) || 
							exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
							exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
							push @teamcachedresults, $playername;	# found a match
							$teaminfo->{player}->{$lcname}->{teamcode} = $teamcode;	# they subbed for this team
							$teaminfo->{player}->{$lcname}->{lastplayedweek} = $i;
						}
					}
				}
			}
			elsif ($res->code() == 404) {
				$foundlast = 1;
				last;
			}
			else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPMatchWeekURL . "]: " . $res->status_line . "</FONT>\n"); }
		}
	}

	my @sorted_teamcachedresults = sort @teamcachedresults;
	my $teamcachedresultscount = scalar @sorted_teamcachedresults;
	if ($teamcachedresultscount > 0) {
		&resultsName(@sorted_teamcachedresults);
		print $query->end_html; # end the HTML
		exit 0;
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub playerInfoDump {
	# save new CSV with updated player names
	my $cachedplayerslc = {};
	foreach my $playername (keys(%{$searchinfo->{players}})) {
		my $lcname = lc($playername);
		$lcname =~ s/^\s+|\s+$//g;
		$cachedplayerslc->{$lcname}->{IPR} = $searchinfo->{players}->{$playername}->{IPR};
		if (exists($searchinfo->{players}->{$playername}->{IFPA_dateupdated})) {
			$cachedplayerslc->{$lcname}->{IFPA_dateupdated} = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		}
		if (exists($searchinfo->{players}->{$playername}->{MP_dateupdated})) {
			$cachedplayerslc->{$lcname}->{MP_dateupdated} = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		}
	}

	my @teamcachedresults;
	foreach my $playername (keys(%{$teaminfo->{player}})) {
		if (!exists($cachedplayerslc->{$playername}) || 
			exists($cachedplayerslc->{$playername}->{IFPA_dateupdated}) ||
			exists($cachedplayerslc->{$playername}->{MP_dateupdated})) {
			push @teamcachedresults, $teaminfo->{player}->{$playername}->{name};	# found a match
		}
	}
	
	my $foundlast = 0;
	for(my $i=1;$i<12;$i++) {
		# get new subs who have played since last update
		my $MNPMatchWeekURL = "https://www.mondaynightpinball.com/match_summary/mnp-$season-$i.json";
		my $MNPMatchWeekPage = "";
		$ua->timeout(10);
		$res = $ua->request(HTTP::Request->new(GET => $MNPMatchWeekURL));
		if ($debugmode){ print("DEBUG: GET " . $MNPMatchWeekURL . ": " . $res->status_line . "\n"); }
		if ($res->is_success) {
			$MNPMatchWeekPage = $res->decoded_content;
			my $tempMatchWeek = &decodeJSON($MNPMatchWeekPage);
			foreach (@{$tempMatchWeek}) {
				my $tempmatch = $_;
				my $teamcode = $tempmatch->{away}->{key};
				foreach (@{$tempmatch->{away}->{lineup}}) {
					my $playername = $_->{name};
					my $lcname = lc($playername);
					$lcname =~ s/^\s+|\s+$//g;
					if (!exists($cachedplayerslc->{$lcname}) || 
						exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
						exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
						if (!(grep( /^$playername$/, @teamcachedresults ))) {
							push @teamcachedresults, $playername;	# found a match
						}
					}
				}
				$teamcode = $tempmatch->{home}->{key};
				foreach (@{$tempmatch->{home}->{lineup}}) {
					my $playername = $_->{name};
					my $lcname = lc($playername);
					$lcname =~ s/^\s+|\s+$//g;
					if (!exists($cachedplayerslc->{$lcname}) || 
						exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
						exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
						if (!(grep( /^$playername$/, @teamcachedresults ))) {
							push @teamcachedresults, $playername;	# found a match
						}
					}
				}
			}
		}
		elsif ($res->code() == 404) {
			$foundlast = 1;
			last;
		}
		else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPMatchWeekURL . "]: " . $res->status_line . "</FONT>\n"); }
	}
	
	if (!$foundlast) {
		for(my $i=91;$i<95;$i++) {
			# get new subs who have played since last update
			my $MNPMatchWeekURL = "https://www.mondaynightpinball.com/match_summary/mnp-$season-$i.json";
			my $MNPMatchWeekPage = "";
			$ua->timeout(10);
			$res = $ua->request(HTTP::Request->new(GET => $MNPMatchWeekURL));
			if ($debugmode){ print("DEBUG: GET " . $MNPMatchWeekURL . ": " . $res->status_line . "\n"); }
			if ($res->is_success) {
				$MNPMatchWeekPage = $res->decoded_content;
				my $tempMatchWeek = &decodeJSON($MNPMatchWeekPage);
				foreach (@{$tempMatchWeek}) {
					my $tempmatch = $_;
					my $teamcode = $tempmatch->{away}->{key};
					foreach (@{$tempmatch->{away}->{lineup}}) {
						my $playername = $_->{name};
						my $lcname = lc($playername);
						$lcname =~ s/^\s+|\s+$//g;
						if (!exists($cachedplayerslc->{$lcname}) || 
							exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
							exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
							push @teamcachedresults, $playername;	# found a match
						}
					}
					$teamcode = $tempmatch->{home}->{key};
					foreach (@{$tempmatch->{home}->{lineup}}) {
						my $playername = $_->{name};
						my $lcname = lc($playername);
						$lcname =~ s/^\s+|\s+$//g;
						if (!exists($cachedplayerslc->{$lcname}) || 
							exists($cachedplayerslc->{$lcname}->{IFPA_dateupdated}) ||
							exists($cachedplayerslc->{$lcname}->{MP_dateupdated})) {
							push @teamcachedresults, $playername;	# found a match
						}
					}
				}
			}
			elsif ($res->code() == 404) {
				$foundlast = 1;
				last;
			}
			else { print("<FONT COLOR=\"#ff0000\">ERROR [cannot read " . $MNPMatchWeekURL . "]: " . $res->status_line . "</FONT>\n"); }
		}
	}
	
	my @sorted_teamcachedresults = sort @teamcachedresults;
	my $teamcachedresultscount = scalar @sorted_teamcachedresults;
	
	if ($teamcachedresultscount > 0) {
		my $csvfilename = "playerinfonew.csv";
		open(my $csvfh, '>:encoding(UTF-8)', $csvfilename)
			or die "Failed to open file: $!\n";	
		print $csvfh "Player Name,Team Code,Role (C/A/P),IFPA,DIV\n";
		foreach (@sorted_teamcachedresults) {
			my $playername = $_;
			my $IFPAid = $searchinfo->{players}->{$playername}->{IFPA_ID} ? $searchinfo->{players}->{$playername}->{IFPA_ID} : "";
			my $team = $teaminfo->{player}->{lc($playername)}->{teamcode} ? $teaminfo->{player}->{lc($playername)}->{teamcode} : "";
			if ($team eq "MNP") { $team = ""; }
			my $role = $teaminfo->{player}->{lc($playername)}->{role} ? $teaminfo->{player}->{lc($playername)}->{role} : "";
			my $division = $teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{division} ? $teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{division} : "";
			print "$playername,$team,$role,$IFPAid,$division<br>";
			print $csvfh "$playername,$team,$role,$IFPAid,$division\n";
		}
		close($csvfh);
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsIPRlower {
	my @cachedresults;
	foreach my $playername (sort keys(%{$searchinfo->{players}})) {
		my $IFPAdateupdated = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		my $MPdateupdated = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		if ((!$IFPAdateupdated && !$MPdateupdated) &&
			($searchinfo->{players}->{$playername}->{IPR} <= $iprlower)) {
			if ($noteam) {
				if ($teaminfo->{player}->{lc($playername)}->{teamcode} eq "MNP") {
					push @cachedresults, $playername;	# found a player from original playerinfo.json not on a team
				}
			}
			else  {
				push @cachedresults, $playername;	# found a player from original playerinfo.json
			}
		}
	}
	my @sorted_cachedresults = sort @cachedresults;
	my $subscachedresultscount = scalar @sorted_cachedresults;
	if ($subscachedresultscount > 0) {
		&resultsName(@sorted_cachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsIPR {
	my @cachedresults;
	foreach my $playername (sort keys(%{$searchinfo->{players}})) {
		my $IFPAdateupdated = $searchinfo->{players}->{$playername}->{IFPA_dateupdated};
		my $MPdateupdated = $searchinfo->{players}->{$playername}->{MP_dateupdated};
		if ((!$IFPAdateupdated && !$MPdateupdated) &&
			($searchinfo->{players}->{$playername}->{IPR} == $ipr)) {
			if ($noteam) {
				if ($teaminfo->{player}->{lc($playername)}->{teamcode} eq "MNP") {
					push @cachedresults, $playername;	# found a player from original playerinfo.json not on a team
				}
			}
			else  {
				push @cachedresults, $playername;	# found a player from original playerinfo.json
			}
		}
	}
	my @sorted_cachedresults = sort @cachedresults;
	my $subscachedresultscount = scalar @sorted_cachedresults;
	if ($subscachedresultscount > 0) {
		&resultsName(@sorted_cachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsVenue {
	my @teamcachedresults;
	foreach my $playername (keys(%{$teaminfo->{player}})) {
		if (lc($teaminfo->{team}->{$teaminfo->{player}->{$playername}->{teamcode}}->{venuecode}) eq lc($venue)) {
			push @teamcachedresults, $teaminfo->{player}->{$playername}->{name};	# found a match
		}
	}
	my @sorted_teamcachedresults = sort @teamcachedresults;
	my $teamcachedresultscount = scalar @sorted_teamcachedresults;
	if ($teamcachedresultscount > 0) {
		&resultsName(@sorted_teamcachedresults);
	}
	else {
		&noResults();
		print $query->end_html; # end the HTML
		exit 0;
	}
}

sub resultsTeamOrVenue {
	my $namematch = uc($_[0]);
	my @teamcachedresults;
	foreach my $playername (keys(%{$teaminfo->{player}})) {
		if ($teaminfo->{player}->{$playername}->{teamcode} eq $namematch) {
			push @teamcachedresults, $teaminfo->{player}->{$playername}->{name};	# found a match
		}
	}
	my @sorted_teamcachedresults = sort @teamcachedresults;
	my $teamcachedresultscount = scalar @sorted_teamcachedresults;
	if ($teamcachedresultscount > 0) {
		$team = $namematch;
		&resultsName(@sorted_teamcachedresults);
		print $query->end_html; # end the HTML
		exit 0;
	}
	else {
		my @venuecachedresults;
		foreach my $playername (keys(%{$teaminfo->{player}})) {
			if ($teaminfo->{team}->{$teaminfo->{player}->{$playername}->{teamcode}}->{venuecode} eq $namematch) {
				push @venuecachedresults, $playername;	# found a match
			}
		}
		my @sorted_venuecachedresults = sort @venuecachedresults;
		my $venuecachedresultscount = scalar @sorted_venuecachedresults;
		if ($venuecachedresultscount > 0) {
			$venue = $namematch;
			&resultsName(@sorted_venuecachedresults);
			print $query->end_html; # end the HTML
			exit 0;
		}
		else {
			print "<div id='content'>";
			print h3("Searches must be at least 4 characters. Try again.");
			print "</div>";
			print br;
			print $query->end_html; # end the HTML
			exit 0;
		}
	}
}

sub resultsIFPA {
	my $IFPAid = $_[0];
	my $name = $searchinfo->{IFPA}->{$IFPAid};
	my $IPR = "<a href=\"http://pinballstats.info/search/iprsearch.pl?ipr=" . $searchinfo->{players}->{$name}->{IPR} . "\"><span class='badge badge-" . $searchinfo->{players}->{$name}->{IPR} . "'>" . $searchinfo->{players}->{$name}->{IPR} . "</span></a>";
	my $lb = $searchinfo->{players}->{$name}->{MP_LB};
	my $plusorminus = $searchinfo->{players}->{$name}->{MP_RD} * 2;
	my $sparklinempr = "";
	if ($lb && ($lb > 0)) {
		$sparklinempr = "<a href=\"https://matchplay.events/live/ratings/search?query=$name\"><span class=\"inlinempr\">1000,$lb," . ($lb+$plusorminus) . "," . ($lb+($plusorminus*2)) . ",2000</span>";
		$sparklinempr .= "<br/><span>$lb</span></a>";
	}
	else {
		$sparklinempr = "";
		$lb = "";
	}
	my $rank = $searchinfo->{players}->{$name}->{IFPA_RANK};
	my $sparklinerank = "";
	if ($rank && ($rank < 32767)) {
		$sparklinerank = "<a href=\"https://www.ifpapinball.com/player.php?p=$IFPAid\"><span class=\"inlinerank\">32767,1,".(32767-$rank)."</span>";
		$sparklinerank .= "<br/><span>$rank</span></a>";
	}
	else {
		$sparklinerank = "";
		$rank = "";
	}
	my $MNPteam = "";
	my $MNPvenue = "";
	if ($teaminfo->{player}->{lc($name)}->{teamcode}) {
		if ($teaminfo->{team}->{$teaminfo->{player}->{lc($name)}->{teamcode}}->{name}) {
			$MNPteam = "<a href=\"http://pinballstats.info/search/iprsearch.pl?team=" . $teaminfo->{player}->{lc($name)}->{teamcode} . "\">" . $teaminfo->{team}->{$teaminfo->{player}->{lc($name)}->{teamcode}}->{name} . "</a>";
		}
		if ($teaminfo->{team}->{$teaminfo->{player}->{lc($name)}->{teamcode}}->{name}) {
			if ($teaminfo->{team}->{$teaminfo->{player}->{lc($name)}->{teamcode}}->{venuecode}) {
				$MNPvenue = "<a href=\"http://pinballstats.info/search/iprsearch.pl?venue=" . $teaminfo->{team}->{$teaminfo->{player}->{lc($name)}->{teamcode}}->{venuecode} . "\">" . $teaminfo->{venue}->{$teaminfo->{team}->{$teaminfo->{player}->{lc($name)}->{teamcode}}->{venuecode}}->{name} . "</a>";
			}
		}
	}
	
	print "<div id='content'>";
	my $searchdetails = "\"IFPA ID = " . $q . "\" found 1 result (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	if ($NWPAS) {
		print table({-class=>'table sortable'}, caption($searchdetails),
			Tr({-class=>'header-row'},
				th(""), th("Name"), th({-class=>'text-xs-center'}, "IPR"), th({-class=>'text-xs-center'}, "Matchplay LB"), th({-class=>'text-xs-center'}, "IFPA Rank"), th({-class=>'text-xs-center'}, "MNP Team"), th({-class=>'text-xs-center'}, "MNP Venue"), th({-class=>'text-xs-center'}, "NWPAS Eligibility")),
			Tr(td(img{src=>&getPicture($IFPAid, $name),height=>32,width=>32,style=>"image-rendering:pixelated;"}),
				td($name),
				td({-class=>'text-xs-center'}, $IPR),
				td({-class=>'text-xs-center'}, $sparklinempr),
				td({-class=>'text-xs-center'}, $sparklinerank),
				td({-class=>'text-xs-center'}, $MNPteam),
				td({-class=>'text-xs-center'}, $MNPvenue),
				td({-class=>'text-xs-center'}, &eligibilityNWPAS($lb, $rank))
			));
	}
	else {
		print table({-class=>'table sortable'}, caption($searchdetails),
			Tr({-class=>'header-row'},
				th(""), th("Name"), th({-class=>'text-xs-center'}, "IPR"), th({-class=>'text-xs-center'}, "Matchplay LB"), th({-class=>'text-xs-center'}, "IFPA Rank"), th({-class=>'text-xs-center'}, "MNP Team"), th({-class=>'text-xs-center'}, "MNP Venue")),
			Tr(td(img{src=>&getPicture($IFPAid, $name),height=>32,width=>32,style=>"image-rendering:pixelated;"}),
				td($name),
				td({-class=>'text-xs-center'}, $IPR),
				td({-class=>'text-xs-center'}, $sparklinempr),
				td({-class=>'text-xs-center'}, $sparklinerank),
				td({-class=>'text-xs-center'}, $MNPteam),
				td({-class=>'text-xs-center'}, $MNPvenue)
			));
	}
	print "</div>";
	print br;
	&logMessage("$searchdetails");
}

sub resultsIFPAjson {
	my $IFPAid = $_[0];
	my $name = $searchinfo->{IFPA}->{$IFPAid};
	my %IFPAblock = ( "$IFPAid" => $name );
	my $result = {};
	$result->{IFPA} = \%IFPAblock;
	$result->{players}->{$name} = \%{$searchinfo->{players}->{$name}};
	$result->{players}->{$name}->{IFPA_dateupdated} = ($searchinfo->{players}->{$name}->{IFPA_dateupdated}) ? $searchinfo->{players}->{$name}->{IFPA_dateupdated} : $searchinfo->{dateupdated}->{IFPA};
	$result->{players}->{$name}->{MP_dateupdated} = ($searchinfo->{players}->{$name}->{MP_dateupdated}) ? $searchinfo->{players}->{$name}->{MP_dateupdated} : $searchinfo->{dateupdated}->{MP};
	$result->{thresholds} = \%{$searchinfo->{thresholds}};
	print &encodeJSON(\%{$result});
	my $searchdetails = "\"JSON=" . $qjson . "\" found 1 result (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	&logMessage("$searchdetails");
}

sub resultsName {
	my (@cachedresults) = @_;
	my $cachedresultscount = scalar @cachedresults;
	my $resultscounttext = "";
	if ($cachedresultscount > 1) {
		$resultscounttext = "$cachedresultscount results";
	}
	elsif ($cachedresultscount == 1) {
		$resultscounttext = "$cachedresultscount result";
	}
	else {
		return;
	}
	
	
	&readIPRCSV();
	
	print "<div id='content'>";
	my $searchdetails = "";
	if ($q && !$team && !$venue) {
		$searchdetails = "\"$q\" found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	elsif ($default) {
		if ($default eq "playerinfo") {
			$searchdetails = "$default found $resultscounttext (" . &timeElapsed() . " seconds) saved " . $searchinfo->{dateupdated}->{IFPA} . " (MP=" . $searchinfo->{dateupdated}->{MP} . ")";
		}
		else {
			$searchdetails = "$default found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
		}
	}
	elsif ($team) {
		my $teamIPR = 0;
		foreach my $playername (@cachedresults) {
			$teamIPR = $teamIPR + $searchinfo->{players}->{$playername}->{IPR};
		}
		if ($team ne "MNP") {
			$searchdetails = "Team $team=" . $teaminfo->{team}->{$team}->{name} . " (IPR total=$teamIPR) found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
		}
		else {
			$searchdetails = "$team (legacy players) found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
		}
	}
	elsif ($venue) {
		$searchdetails = "Venue $venue=" . $teaminfo->{venue}->{$venue}->{name} . " found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	elsif ($missingipr) {
		$searchdetails = "$resultscounttext for roster players not in playerinfo.csv! (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	elsif ($iprlower) {
		$searchdetails = "MNP players with IPR<=$iprlower found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	elsif ($ipr) {
		$searchdetails = "MNP players with IPR=$ipr found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	else {
		$searchdetails = "found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	if ($NWPAS) {
		print "<table class=\"table sortable\"><caption>$searchdetails</caption> <tr class=\"header-row\"><th></th> <th>Name</th> <th class=\"text-xs-center\">IPR</th> <th class=\"text-xs-center\">Matchplay LB</th> <th class=\"text-xs-center\">IFPA Rank</th> <th class=\"text-xs-center\">MNP Team</th> <th class=\"text-xs-center\">MNP Venue</th> <th class=\"text-xs-center\">NWPAS Eligibility</th></tr>";
	}
	else {
		print "<table class=\"table sortable\"><caption>$searchdetails</caption> <tr class=\"header-row\"><th></th> <th>Name</th> <th class=\"text-xs-center\">IPR</th> <th class=\"text-xs-center\">Matchplay LB</th> <th class=\"text-xs-center\">IFPA Rank</th> <th class=\"text-xs-center\">MNP Team</th> <th class=\"text-xs-center\">MNP Venue</th></tr>";
	}
	
	foreach my $playername (@cachedresults) {
		my $name = $playername;
		my $IFPAid = $searchinfo->{players}->{$name}->{IFPA_ID} ;
		my $IPR = "<span class='badge'></span>";
		if ($searchinfo->{players}->{$name}->{IPR}) {
			$IPR = "<a href=\"http://pinballstats.info/search/iprsearch.pl?ipr=" . $searchinfo->{players}->{$name}->{IPR} . "\"><span class='badge badge-" . $searchinfo->{players}->{$name}->{IPR} . "'>" . $searchinfo->{players}->{$name}->{IPR} . "</span></a>";
		}
		my $lb = $searchinfo->{players}->{$name}->{MP_LB};
		my $sparklinempr = "";
		if ($lb && ($lb > 0)) {
			my $plusorminus = $searchinfo->{players}->{$name}->{MP_RD} * 2;
			$sparklinempr = "<a href=\"https://matchplay.events/live/ratings/search?query=$name\"><span class=\"inlinempr\">1000,$lb," . ($lb+$plusorminus) . "," . ($lb+($plusorminus*2)) . ",2000</span>";
			$sparklinempr .= "<br/><span>$lb</span></a>";
		}
		else {
			$sparklinempr = "";
			$lb = "";
		}
		my $rank = $searchinfo->{players}->{$name}->{IFPA_RANK};
		my $sparklinerank = "";
		if ($rank && ($rank < 32767)) {
			$sparklinerank = "<a href=\"https://www.ifpapinball.com/player.php?p=$IFPAid\"><span class=\"inlinerank\">32767,1,".(32767-$rank)."</span>";
			$sparklinerank .= "<br/><span>$rank</span></a>";
		}
		else {
			$sparklinerank = "";
			$rank = "";
		}
		my $MNPteam = "";
		my $MNPvenue = "";
		if ($teaminfo->{player}->{lc($playername)}->{teamcode}) {
			if ($teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{name}) {
				if (($teaminfo->{player}->{lc($playername)}->{role} && 
					($teaminfo->{player}->{lc($playername)}->{role} eq "C" ||
					$teaminfo->{player}->{lc($playername)}->{role} eq "A" ||
					$teaminfo->{player}->{lc($playername)}->{role} eq "V" ||	# C
					$teaminfo->{player}->{lc($playername)}->{role} eq "T" ||	# A
					$teaminfo->{player}->{lc($playername)}->{role} eq "P")) || 
					$teaminfo->{player}->{lc($playername)}->{teamcode} eq "MNP") {
					$MNPteam = "<a href=\"http://pinballstats.info/search/iprsearch.pl?team=" . $teaminfo->{player}->{lc($playername)}->{teamcode} . "\">" . $teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{name} . "</a>";
					if ($teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{venuecode}) {
						$MNPvenue = "<a href=\"http://pinballstats.info/search/iprsearch.pl?venue=" . $teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{venuecode} . "\">" . $teaminfo->{venue}->{$teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{venuecode}}->{name} . "</a>";
					}
				}
				else {
					if (!$teaminfo->{player}->{lc($playername)}->{mnpipr}) {
						$name = "TODO:<br/>" . $playername;
					}
					$MNPteam = "<a href=\"http://pinballstats.info/search/iprsearch.pl?team=" . $teaminfo->{player}->{lc($playername)}->{teamcode} . "\">W" . $teaminfo->{player}->{lc($playername)}->{lastplayedweek} . " SUB for " . $teaminfo->{team}->{$teaminfo->{player}->{lc($playername)}->{teamcode}}->{name} . "</a>";
				}
			}
		}
		if ($NWPAS) {
			print "<tr><td class=\"text-xs-center\"; bgcolor=\"#FFFFFF\"><img image-rendering=\"pixelated\" height=\"32\" src=\"" . &getPicture($IFPAid, $name) . "\" width=\"32\" /></td> <td>$name</td> <td class=\"text-xs-center\">$IPR</td> <td class=\"text-xs-center\">$sparklinempr</td> <td class=\"text-xs-center\">$sparklinerank</td> <td class=\"text-xs-center\">$MNPteam</td> <td class=\"text-xs-center\">$MNPvenue</td> <td class=\"text-xs-center\">" . &eligibilityNWPAS($lb, $rank) . "</td></tr>";
		}
		else {
			print "<tr><td class=\"text-xs-center\"; bgcolor=\"#FFFFFF\"><img image-rendering=\"pixelated\" height=\"32\" src=\"" . &getPicture($IFPAid, $name) . "\" width=\"32\" /></td> <td>$name</td> <td class=\"text-xs-center\">$IPR</td> <td class=\"text-xs-center\">$sparklinempr</td> <td class=\"text-xs-center\">$sparklinerank</td> <td class=\"text-xs-center\">$MNPteam</td> <td class=\"text-xs-center\">$MNPvenue</td></tr>";
		}
	}
	print "</table></div>";
	print br;
	&logMessage("$searchdetails");
}

sub resultsNameJson {
	my (@cachedresults) = @_;
	my $cachedresultscount = scalar @cachedresults;
	my $resultscounttext = "";
	if ($cachedresultscount > 1) {
		$resultscounttext = "$cachedresultscount results";
	}
	elsif ($cachedresultscount == 1) {
		$resultscounttext = "$cachedresultscount result";
	}
	else {
		return;
	}
	my $searchdetails = "\"JSON=$qjson\" found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	my $result = {};	
	foreach my $playername (@cachedresults) {
		my $name = $playername;
		my $IFPAid = $searchinfo->{players}->{$name}->{IFPA_ID} ;
		$result->{IFPA}->{$IFPAid} = $name;
		$result->{players}->{$name} = \%{$searchinfo->{players}->{$name}};
		$result->{players}->{$name}->{IFPA_dateupdated} = ($searchinfo->{players}->{$name}->{IFPA_dateupdated}) ? $searchinfo->{players}->{$name}->{IFPA_dateupdated} : $searchinfo->{dateupdated}->{IFPA};
		$result->{players}->{$name}->{MP_dateupdated} = ($searchinfo->{players}->{$name}->{MP_dateupdated}) ? $searchinfo->{players}->{$name}->{MP_dateupdated} : $searchinfo->{dateupdated}->{MP};
		$result->{thresholds} = \%{$searchinfo->{thresholds}};
	}
	print &encodeJSON(\%{$result});
	&logMessage("$searchdetails");
}

sub resultsNameBasic {
	my (@cachedresults) = @_;
	my $cachedresultscount = scalar @cachedresults;
	my $resultscounttext = "";
	if ($cachedresultscount > 1) {
		$resultscounttext = "$cachedresultscount results";
	}
	elsif ($cachedresultscount == 1) {
		$resultscounttext = "$cachedresultscount result";
	}
	else {
		return;
	}
		
	print "<div id='content'>";
	my $searchdetails = "";
	if ($default) {
		$searchdetails = "$default found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	else {
		$searchdetails = "found $resultscounttext (" . &timeElapsed() . " seconds) [MPR: $ratingsdate]";
	}
	print "<table class=\"table sortable\"><caption>$searchdetails</caption> <tr class=\"header-row\"><th></th> <th>Name</th> <th class=\"text-xs-center\">IPR</th> <th class=\"text-xs-center\">Matchplay LB</th> <th class=\"text-xs-center\">Matchplay Date</th> <th class=\"text-xs-center\">IFPA Rank</th> <th class=\"text-xs-center\">IFPA Date</th></tr>";
	
	foreach my $playername (@cachedresults) {
		my $name = $playername;
		my $IFPAid = $searchinfo->{players}->{$name}->{IFPA_ID} ;
		my $IPR = "<span class='badge badge-" . $searchinfo->{players}->{$name}->{IPR} . "'>" . $searchinfo->{players}->{$name}->{IPR} . "</span>";
		my $lb = $searchinfo->{players}->{$name}->{MP_LB};
		my $sparklinempr = "";
		if ($lb && ($lb > 0)) {
			$sparklinempr = "<a href=\"https://matchplay.events/live/ratings/search?query=$name\">";
			$sparklinempr .= "<span>$lb</span></a>";
		}
		else {
			$sparklinempr = "";
			$lb = "";
		}
		my $rank = $searchinfo->{players}->{$name}->{IFPA_RANK};
		my $sparklinerank = "";
		if ($rank && ($rank < 32767)) {
			$sparklinerank = "<a href=\"https://www.ifpapinball.com/player.php?p=$IFPAid\">";
			$sparklinerank .= "<span>$rank</span>";
		}
		else {
			$sparklinerank = "";
			$rank = "";
		}
		my $MP_date = ($searchinfo->{players}->{$name}->{MP_dateupdated}) ? $searchinfo->{players}->{$name}->{MP_dateupdated} : "";
		my $IFPA_date = ($searchinfo->{players}->{$name}->{IFPA_dateupdated}) ? $searchinfo->{players}->{$name}->{IFPA_dateupdated} : "";
		
		print "<tr><td class=\"text-xs-center\"; bgcolor=\"#FFFFFF\"><img image-rendering=\"pixelated\" height=\"32\" src=\"" . &getPicture($IFPAid, $name) . "\" width=\"32\" /></td> <td>$name</td> <td class=\"text-xs-center\">$IPR</td> <td class=\"text-xs-center\">$sparklinempr</td> <td class=\"text-xs-center\">$MP_date</td> <td class=\"text-xs-center\">$sparklinerank</td> <td class=\"text-xs-center\">$IFPA_date</td></tr>";
	}
	print "</table></div>";
	print br;
	&logMessage("$searchdetails");
}

sub eligibilityNWPAS {
	my $lb = $_[0];
	my $rank = $_[1];
	my $infoNWPAS = "";
	
	$infoNWPAS .= "<a href=\"http://nwpas.wapinball.net/matchplay.html\" style=\"color:red\">A</a>"; # everyone is eligible for A-Divison
	if ((!$lb || ($lb <= 1575)) && (!$rank || ($rank > 250))) {
		$infoNWPAS .= ",&nbsp;<a href=\"http://nwpas.wapinball.net/matchplay.html\" style=\"color:blue\">B</a>";
	}
	if ((!$lb || ($lb < 1400)) && (!$rank || ($rank > 2000))) {
		$infoNWPAS .= ",&nbsp;<a href=\"http://nwpas.wapinball.net/rookie.html\" style=\"color:green\">Rookie</a>";
	}
	
	return $infoNWPAS;
}
