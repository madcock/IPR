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
use Data::Dumper;
use DateTime;
use DateTime::Duration;
use JSON::XS;
use utf8;
use POSIX qw(floor);
use File::Slurp qw(read_file write_file);
use URL::Encode qw(url_encode);
use strict;
use warnings;

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
my $debugmode = $query->param('d');
# if no valid search term, bounce them back to search page
if (!$q) {
	print $query->redirect('/search/');
    exit 1;
}

print $query->header; # create the HTTP header
print $query->start_html(-title=>'MNP Search Results',
							-script=>[{-type=>'javascript', -src=>'jquery-3.3.1.min.js'},{-type=>'javascript', -src=>'jquery.sparkline.min.js'}],
);
			   
# turn off buffering for standard output
select(STDOUT);
$| = 1;

# setup LWP and Scraper 
my $ua = LWP::UserAgent->new;
my $res = "";

$q =~ s/^\s+|\s+$//g; # trim leading/trailing spaces

my $playerinfo = &loadJSON("playerinfo.json");

# check parameters and go
if ($q =~ /^\d+?$/) {
	my $IFPAid = int($q);
	
	print "IFPA ID:$IFPAid\n";
	
	# check against loaded playerinfo.json, if found, print that info and quit
	if ($playerinfo->{IFPA}->{$IFPAid}) {
		my $name = $playerinfo->{IFPA}->{$IFPAid};
		my $lb = $playerinfo->{players}->{$name}->{MP_LB};
		my $rank = $playerinfo->{players}->{$name}->{IFPA_RANK};
		my $IPR = $playerinfo->{players}->{$name}->{IPR};
		
		print "name:$name  LB:$lb  IFPA Rank:$rank  IPR:$IPR  \n";
		
	}
	else {
		# TODO: search for target IFPA ID at IFPA site and Matchplay site
		my $IFPAURL = "https://api.ifpapinball.com/v1/player/$IFPAid?api_key=6655c7e371c30c5cecda4a6c8ad520a4";
	}
}
else {
	my $namesearch = $q;
	
	print "name:$namesearch\n";
	
	# TODO: check against loaded playerinfo.json, if any match found, print that info and continue
	
	# get Matchplay ratings for player names
	my $searchPage = "";
	my $searchURL = "https://matchplay.events/live/ratings/search?query=" . &url_encode($namesearch);
	$res = $ua->request(HTTP::Request->new(GET => $searchURL));
	if ($debugmode){ print("GET " . $searchURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$searchPage = $res->decoded_content;
	}
	else { print("ERROR [" . $searchURL . "]: " . $res->status_line . "\n"); exit 1; }

	my $scraper = scraper { process '//tr/td[1]/a', 'links[]' => '@href';
							process '//tr/td[1]/a', 'names[]' => 'TEXT';
							process '//tr/td[2]', 'ratings[]' => 'TEXT';
						};
	my $playertemp  = $scraper->scrape($searchPage);

	my $i = 0;
	if ($playertemp->{links}) {
		while ($i < @{$playertemp->{links}}) {
			if ($playertemp->{links}[$i]) {
				my $tempid = substr($playertemp->{links}[$i], rindex($playertemp->{links}[$i], "/") + 1);
				if ($playertemp->{names} && $playertemp->{names}[$i] && $playertemp->{ratings} && $playertemp->{ratings}[$i]) {
					my $name = $playertemp->{names}[$i];
					my ($rating, $delta) = split / ±/, $playertemp->{ratings}[$i];
					
					print "name:$name  ($tempid)  LB:" . ($rating-$delta) . "\n";

					# TODO: if name already in playerinfo.json then skip to next name...
					
					# $players->{$namesearch}->{MP}->{date_collected} = $ratingsdate;
					# $players->{$namesearch}->{MP}->{rating} = int($rating);
					# $players->{$namesearch}->{MP}->{rd} = floor($delta/2);
					# $players->{$namesearch}->{MP}->{lower_bound} = $rating - $delta;
					# $players->{$namesearch}->{MP}->{upper_bound} = $rating + $delta;
					
				}
			}
			$i++;
		}
	}
	else {
		print "$namesearch not found in Matchplay Ratings.\n";
		if ($debugmode){ print("GET " . $searchURL . ": " . $res->status_line . "\n"); }
	}
	
	my $IFPAURL = "https://api.ifpapinball.com/v1/player/search?api_key=6655c7e371c30c5cecda4a6c8ad520a4&q=$namesearch";
	my $IFPAPage = "";
	$res = $ua->request(HTTP::Request->new(GET => $IFPAURL));
	if ($debugmode){ print("GET " . $IFPAURL . ": " . $res->status_line . "\n"); }
	if ($res->is_success) {
		$IFPAPage = $res->decoded_content;
		my $IFPAresponse = &decodeJSON($IFPAPage);
		if ($debugmode){ print Dumper $IFPAresponse};
		
		print Dumper $IFPAresponse;

		foreach my $player (@{$IFPAresponse->{search}}) {
		
			# TODO: if name already in playerinfo.json then skip to next name...
		
			# $players->{$oldplayername}->{IFPA}->{date_collected} = $currentdate;
			# $players->{$oldplayername}->{IFPA}->{player}->{player_id} = $player->{player_id};
			# $players->{$oldplayername}->{IFPA}->{player}->{first_name} = $player->{first_name};
			# $players->{$oldplayername}->{IFPA}->{player}->{last_name} = $player->{last_name};
			my $playername = $player->{first_name} . " " . $player->{last_name};
			$playername =~ s/^\s+|\s+$//g; # trim leading/trailing spaces
			my $playerid = $player->{player_id};
			my $playerrank = $player->{wppr_rank};
			print "$playername  $playerid  $playerrank\n";
			
			# $players->{$oldplayername}->{IFPA}->{player}->{city} = $player->{city};
			# $players->{$oldplayername}->{IFPA}->{player}->{state} = $player->{state};
			# $players->{$oldplayername}->{IFPA}->{player}->{country_code} = $player->{country_code};
			# $players->{$oldplayername}->{IFPA}->{player}->{country_name} = $player->{country_name};
			# $players->{$oldplayername}->{IFPA}->{player_stats}->{current_wppr_rank} = $player->{wppr_rank};
		}
	}
	else { print("IFPA [GET " . $IFPAURL . "]: " . $res->status_line . "\n"); }
	
}

print $query->end_html; # end the HTML

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
