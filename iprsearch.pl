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
my $dtDuration = DateTime::Duration->new( days => 8 );	
my $dtQuery = $dtCurrent->subtract_duration($dtDuration);
if(!$ratingsdate) {
	$ratingsdate = $dtQuery->ymd;
}

# json utility object
my $json = new JSON::XS;
$json->canonical(1);

my $query = CGI->new; # create new CGI object
my $q = $query->param('q');
my $qjson = $query->param('json');
my $default = $query->param('default');
my $debugmode = $query->param('d');

if (!$qjson && ($q || $default)) {
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
my $addedtocache = 0;

if ($default && $default eq "pics") {
	&resultsPictures();
}
elsif ($default && $default eq "playerinfo") {
	&resultsPlayerinfo();
}
elsif ($default && $default eq "searchinfo") {
	&resultsSearchinfo();
}
elsif ($qjson && $qjson =~ /^\d+?$/) {
	my $IFPAid = int($qjson);

	# check IFPA ID against loaded searchinfo.json, if found, print that info and quit
	if ($searchinfo->{IFPA}->{$IFPAid}) {
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
		my $searchdetails = "\"JSON=$qjson\" found 0 results (" . &timeElapsed() . " seconds)";
		&logMessage("$searchdetails");
		exit 0;
	}
}
elsif ($q && $q =~ /^\d+?$/) {
	my $IFPAid = int($q);
	# check IFPA ID against loaded searchinfo.json, if found, print that info and quit
	if ($searchinfo->{IFPA}->{$IFPAid}) {
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
	my $searchdetails = "\"JSON=$qjson\" found 0 results (" . &timeElapsed() . " seconds)";
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
		my $content = read_file("index.html", binmode => ':utf8');
		my $prepiccontent = substr($content, 0, (index($content, "pics/") + 5));
		my $postpiccontent = substr($content, (index($content, ".png")));
		$content = "$prepiccontent$IFPAid$postpiccontent";
		open(my $fh, '>:encoding(UTF-8)', "index.html");
		print $fh $content;
		close($fh);
		return "pics/$IFPAid.png";
	}
	elsif (-e "pics/$name.png") {
		my $content = read_file("index.html", binmode => ':utf8');
		my $prepiccontent = substr($content, 0, (index($content, "pics/") + 5));
		my $postpiccontent = substr($content, (index($content, ".png")));
		$content = "$prepiccontent$name$postpiccontent";
		open(my $fh, '>:encoding(UTF-8)', "index.html");
		print $fh $content;
		close($fh);
		return "pics/$name.png";
	}
	else {
		return "pics/blank.png";
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
	foreach my $playername (sort keys(%{$searchinfo->{players}})) {
		if (index(lc($playername), lc($namematch)) > -1) {
			push @cachedresults, $playername;	# found a match
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
				my $searchdetails = "\"JSON=$qjson\" found 0 results (" . &timeElapsed() . " seconds)";
				&logMessage("$searchdetails");
			}
			else {
				&noResults();
				print $query->end_html; # end the HTML
			}
			exit 0;
		}
	}
	else {
		print("IFPA [GET " . $IFPAURL . "]: " . $res->status_line . "\n");
	}
	
	# get Matchplay ratings for IFPA ID
	my $matchplayPage = "";
	my $matchplayURL = "https://matchplay.events/data/ifpa/ratings/$ratingsdate/$IFPAid";
	$res = $ua->request(HTTP::Request->new(GET => $matchplayURL));
	if ($debugmode){ print("DEBUG: GET " . $matchplayURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$matchplayPage = $res->decoded_content;
		my $matchplayresponse = &decodeJSON($matchplayPage);
		$searchinfo->{players}->{$playername}->{MP_dateupdated} = $ratingsdate;
		$searchinfo->{players}->{$playername}->{MP_LB} = $matchplayresponse->{$IFPAid}->{lower_bound};
		$searchinfo->{players}->{$playername}->{MP_RD} = $matchplayresponse->{$IFPAid}->{rd};
	}
	else { print("IFPA [GET " . $matchplayURL . "]: " . $res->status_line . "\n"); }		
	
	&calculateIPR($playername);
	$addedtocache = 1;
}

# query externally for player name
sub queryName {
	my $namematch = $_[0];
	
	# get IFPA ratings for player names
	my $IFPAURL = "https://api.ifpapinball.com/v1/player/search?api_key=6655c7e371c30c5cecda4a6c8ad520a4&q=$namematch";
	my $IFPAPage = "";
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
					$res = $ua->request(HTTP::Request->new(GET => $matchplayURL));
					if ($debugmode){ print("DEBUG: GET " . $matchplayURL . ": " . $res->status_line . "\n"); }
					if ($res->is_success) {
						$matchplayPage = $res->decoded_content;
						my $matchplayresponse = &decodeJSON($matchplayPage);
						$searchinfo->{players}->{$playername}->{MP_dateupdated} = $ratingsdate;
						$searchinfo->{players}->{$playername}->{MP_LB} = $matchplayresponse->{$IFPAid}->{lower_bound};
						$searchinfo->{players}->{$playername}->{MP_RD} = $matchplayresponse->{$IFPAid}->{rd};
					}
					else { print("Name [GET " . $matchplayURL . "]: " . $res->status_line . "\n"); }		

					&calculateIPR($playername);
					$addedtocache++;
				}
			}
		}
	}
	else { print("Name [GET " . $IFPAURL . "]: " . $res->status_line . "\n"); }
	
	
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
				#my $tempid = substr($playertemp->{links}[$i], rindex($playertemp->{links}[$i], "/") + 1);
				if ($playertemp->{names} && $playertemp->{names}[$i] && $playertemp->{ratings} && $playertemp->{ratings}[$i]) {
					my $mpplayername = $playertemp->{names}[$i];
					# look for name in searchinfo.json
					my $found = 0;
					foreach my $cachedname (keys(%{$searchinfo->{players}})) {
						if (lc($cachedname) eq lc($mpplayername)) {
							$found = 1;
						}
					}
					# if name not found in searchinfo.json, add it to $mpnewplayers
					if ($found == 0) {
						my ($rating, $delta) = split / ±/, $playertemp->{ratings}[$i];
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
		else { print("Name [GET " . $IFPAURL . "]: " . $res->status_line . "\n"); }
	}
}

sub noResults {
	print "<div id='content'>";
	my $searchdetails = '"' . $q . '" found 0 results (' . &timeElapsed() . ' seconds)';
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
			push @cachedresults, $playername;	# found a player from original playerinfo.json
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
			push @cachedresults, $playername;	# found a player that was added by search
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
	my @files = <pics/*.png>;
	my @cachedresults;
	foreach my $file (@files) {
		my $filename = substr($file, (index($file, "/") + 1), rindex($file, ".")-(index($file, "/") + 1));
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

sub resultsIFPA {
	my $IFPAid = $_[0];
	my $name = $searchinfo->{IFPA}->{$IFPAid};
	my $IPR = "<span class='badge badge-" . $searchinfo->{players}->{$name}->{IPR} . "'>" . $searchinfo->{players}->{$name}->{IPR} . "</span>";
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
	
	print "<div id='content'>";
	my $searchdetails = 'IFPA ID = ' . $q . ' found 1 result (' . &timeElapsed() . ' seconds)';
	print table({-class=>'table sortable'}, caption($searchdetails),
		Tr({-class=>'header-row'},
			th(""), th("Name"), th({-class=>'text-xs-center'}, "IPR"), th({-class=>'text-xs-center'}, "Matchplay LB"), th({-class=>'text-xs-center'}, "IFPA Rank")),
		Tr(td(img{src=>&getPicture($IFPAid, $name),height=>32,width=>32}),
			td($name),
			td({-class=>'text-xs-center'}, $IPR),
			td({-class=>'text-xs-center'}, $sparklinempr),
			td({-class=>'text-xs-center'}, $sparklinerank)
		));
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
	my $searchdetails = '"JSON=' . $qjson . '" found 1 result (' . &timeElapsed() . ' seconds)';
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
		
	print "<div id='content'>";
	my $searchdetails = "";
	if ($q) {
		$searchdetails = "\"$q\" found $resultscounttext (" . &timeElapsed() . " seconds)";
	}
	elsif ($default) {
		if ($default eq "playerinfo") {
			$searchdetails = "$default found $resultscounttext (" . &timeElapsed() . " seconds) saved " . $searchinfo->{dateupdated}->{IFPA} . " (MP=" . $searchinfo->{dateupdated}->{MP} . ")";
		}
		else {
			$searchdetails = "$default found $resultscounttext (" . &timeElapsed() . " seconds)";
		}
	}
	else {
		$searchdetails = "found $resultscounttext (" . &timeElapsed() . " seconds)";
	}
	print "<table class=\"table sortable\"><caption>$searchdetails</caption> <tr class=\"header-row\"><th></th> <th>Name</th> <th class=\"text-xs-center\">IPR</th> <th class=\"text-xs-center\">Matchplay LB</th> <th class=\"text-xs-center\">IFPA Rank</th></tr>";
	
	foreach my $playername (@cachedresults) {
		my $name = $playername;
		my $IFPAid = $searchinfo->{players}->{$name}->{IFPA_ID} ;
		my $IPR = "<span class='badge badge-" . $searchinfo->{players}->{$name}->{IPR} . "'>" . $searchinfo->{players}->{$name}->{IPR} . "</span>";
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
			$sparklinerank .= "<br/><span>$rank</span>";
		}
		else {
			$sparklinerank = "";
			$rank = "";
		}
		
		print "<tr><td class=\"text-xs-center\"; bgcolor=\"#FFFFFF\"><img height=\"32\" src=\"" . &getPicture($IFPAid, $name) . "\" width=\"32\" /></td> <td>$name</td> <td class=\"text-xs-center\">$IPR</td> <td class=\"text-xs-center\">$sparklinempr</td> <td class=\"text-xs-center\">$sparklinerank</td></tr>";
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
	my $searchdetails = "\"JSON=$qjson\" found $resultscounttext (" . &timeElapsed() . " seconds)";
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
	if ($q) {
		$searchdetails = "\"$q\" found $resultscounttext (" . &timeElapsed() . " seconds)";
	}
	elsif ($default) {
		$searchdetails = "$default found $resultscounttext (" . &timeElapsed() . " seconds)";
	}
	else {
		$searchdetails = "found $resultscounttext (" . &timeElapsed() . " seconds)";
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
		
		print "<tr><td class=\"text-xs-center\"; bgcolor=\"#FFFFFF\"><img height=\"32\" src=\"" . &getPicture($IFPAid, $name) . "\" width=\"32\" /></td> <td>$name</td> <td class=\"text-xs-center\">$IPR</td> <td class=\"text-xs-center\">$sparklinempr</td> <td class=\"text-xs-center\">$MP_date</td> <td class=\"text-xs-center\">$sparklinerank</td> <td class=\"text-xs-center\">$IFPA_date</td></tr>";
	}
	print "</table></div>";
	print br;
	&logMessage("$searchdetails");
}