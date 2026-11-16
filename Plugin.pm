package Plugins::MixCloud::Plugin;

# Plugin to stream audio from Mixcloud
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by Christian Mueller (first release), 
#   Daniel Vijge (improvements),
#   KwarkLabs (added functionality)
#
# See file LICENSE for full license details

use strict;

use base qw(Slim::Plugin::OPMLBased);
use utf8;

use URI::Escape;
use JSON::XS qw(decode_json);

use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);
use Date::Parse;
use Data::Dump qw(dump);
use HTTP::Request;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Favorites;
use Slim::Utils::PluginManager;
use Slim::Plugin::OPMLBased;

use Plugins::MixCloud::ProtocolHandler;

my $CLIENT_ID = "2aB9WjPEAButp4HSxY";
my $CLIENT_SECRET = "scDXfRbbTyDHHGgDhhSccHpNgYUa7QAW";
my $token = "";
my $cache;

use constant TOKEN_CACHE_TTL => 3600; # cache access token for 1 hour

my $prefs = preferences('plugin.mixcloud');
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.mixcloud',
	'defaultLevel' => 'ERROR',
	'description'  => string('PLUGIN_MIXCLOUD'),
});

$prefs->init({ apiKey => "", useBuffered => 1, helper_application => 'bundled', helper_application_custom_path => "", hide_exclusive => 1 });

sub getToken {
	$log->debug('getToken started');
	my ($callback) = shift;
	if ($cache->get('token') ne '') {
		$log->debug('Returning cached access token');
		$token = $cache->get('token');
		$callback->({token=>$token});
		return;
	}
	if ($prefs->get('apiKey')) {
		my $tokenurl = "https://www.mixcloud.com/oauth/access_token?client_id=".$CLIENT_ID."&redirect_uri=https://danielvijge.github.io/lms_mixcloud/app.html&client_secret=".$CLIENT_SECRET."&code=".$prefs->get('apiKey');
		my $request = HTTP::Request->new( 'GET' => $tokenurl );
		$request->protocol('HTTP/1.1');	# Force request because, since May 2026, seen destination rejecting HTTP/1.0 which is LMS default
		my $params->{request} = $request;
		my %headers;
		$headers{'Connection'} = 'close';	# BAD BAD force close to try to prevent keep-alive in http/1.1
		
		$log->info("Mixcloud OAuth call to ".$tokenurl);

		Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $http = shift;				
					my $json = eval { decode_json($http->content) };
					$log->warn($@) if $@;
					if ($json->{"access_token"}) {
						$token = $json->{"access_token"};
						$log->debug("Access token: ".$token);
						$cache->set('token', $token, TOKEN_CACHE_TTL);
					}else{
						$log->error("Error: Failed to extract access token from response");
						$log->error("Response received: " . $http->content);
					}
					$callback->({token=>$token});
				},
				sub {
					$log->error("Error: $_[1]");
					$callback->({});
				},
				$params
		)->get($tokenurl, %headers);
	}else{
		$log->warn('No authentication, using anonymous browsing. Log in on the settings page');
		$callback->({});
	}
	$log->debug('getToken ended');
}

sub _provider {
	$log->debug('_provider started');
	my ($client, $url, $args) = @_;
	return Plugins::MixCloud::ProtocolHandler->getMetadataFor($client, $url, $args);
}

sub _parseTracks {
	$log->debug('_partTracks started');
	my ($client, $json, $menu) = @_;
	my $args = { params => {isPlugin => 1}};
	my $data = $json->{'data'}; 
	for my $entry (@$data) {
		if ($prefs->get('hide_exclusive') eq 1 && $entry->{'is_exclusive'} eq 1) { next; }
		push @$menu, Plugins::MixCloud::ProtocolHandler::makeCacheItem($client, $entry, $args);
	}
	$log->debug('_partTracks ended');
}

sub tracksHandler {
	$log->debug('tracksHandler started');
	my ($client, $callback, $args, $passDict) = @_;

	my $index    = ($args->{'index'} || 0); # ie, offset
    
	my $quantity = $args->{'quantity'} || 200;
	my $total = $args->{'total'} || '';
	my $searchType = $passDict->{'type'};

	my $parser = $passDict->{'parser'} || \&_parseTracks;
	my $params = $passDict->{'params'} || '';

	$params =~ s/\/$//;     # Strip possible trailing / because one always added below

	$log->debug('search type: ' . $searchType);
	$log->debug("index: " . $index);
	$log->debug("quantity: " . $quantity);
	$log->debug("params: " . $params);

	my $menu = [];

	my $max = min($quantity - scalar @$menu, 200); # api allows max of 200 items per response
	$log->debug("max: " . $max);
	my $method = "https";
	my $uid = $passDict->{'uid'} || '';
	my $resource = "";
	if ($searchType =~ /^categories/) {
		# limit on categories API call is not honored.
		if ($params eq "") {
			$resource = "categories";
		}else{
			# This gets the contents of a category.
			# Only categories 1 to 40 will be returned regardless of offset and limit parameters.
			$resource = $params;
			$params = "";
		}			
	}
	
	if ($searchType eq 'search') {
		$resource = "search";
		$params = "&q=".$args->{'search'}."&type=cloudcast"; 
	}
	
	if ($searchType eq 'usersearch') {
		$resource = "search";
		$params = "&q=".$args->{'search'}."&type=user"; 
	}
	
	if ($searchType eq 'tags') {
		if ($params eq "") {
			$resource = "search";
			$params = "&q=".$args->{'search'}."&type=tag";
		}else{
			$resource = $params;
			$params = "";
		}			 
	}
	if ($searchType eq 'following' || $searchType eq 'favorites' || $searchType eq 'cloudcasts' || $searchType eq 'user') {
		$resource = $params;
		$params = '';
		if (substr($resource,0,2) eq 'me') {
			if ($token ne "") {
				$method = "https";
				$params = "";
			}				
		}		
	}
	
	my $queryUrl;
	if ($quantity == 1) {
        $queryUrl = "$method://api.mixcloud.com/$resource/?offset=$index&limit=$quantity" . $params;
	} else {
		$queryUrl = "$method://api.mixcloud.com/$resource/?limit=$quantity" . $params;
	}
    
	# Adding the token to the end of each request returns more details
	if ($token ne '') {
		$queryUrl .=   "&access_token=" . $token;
	}
	
	_getTracks($client, $searchType, $index, $quantity, $queryUrl, 0, $parser, $callback, $menu, $total);
	$log->debug('tracksHandler ended');
}
		
sub _getTracks {
	$log->debug('_getTracks started');
	my ($client, $searchType, $index, $quantity, $queryUrl, $cursor, $parser, $callback, $menu, $total, $remaining, $seen) = @_;
	
	my $request = HTTP::Request->new( 'GET' => $queryUrl );
	$request->protocol('HTTP/1.1');	# Force request because, since May 2026, seen destination rejecting HTTP/1.0 which is LMS default
	my $params->{request} = $request;
	my %headers;
	$headers{'Connection'} = 'close';	# BAD BAD force close to try to prevent keep-alive in http/1.1

	$log->info("Mixcloud API call to ".$queryUrl);

	Slim::Networking::SimpleAsyncHTTP->new(
		
		sub {
			my $http = shift;				
			my $json = eval { decode_json($http->content) };
			if ($@ || ref $json ne 'HASH' || (defined $remaining && ref $json->{data} ne 'ARRAY')) {
				$log->error('Invalid Mixcloud API response: ' . ($@ || 'unexpected response structure'));
				$callback->([ { name => string('PLUGIN_MIXCLOUD_FEED_FAILED'), type => 'text' } ]);
				return;
			}

			# Count uploads, not visible tracks: exclusive uploads still belong to the latest 100.
			if (defined $remaining) {
				my $count = min(scalar @{$json->{data}}, $remaining);
				splice @{$json->{data}}, $count;
				$parser->($client, $json, $menu, $searchType);
				$remaining -= $count;
				my $next = $json->{paging}->{next};
				if ($remaining > 0 && $next) {
					if (!$count || $next !~ m{^https://api\.mixcloud\.com/} || $seen->{$next}++) {
						$log->error('Invalid or repeated Mixcloud pagination page');
						$callback->([ { name => string('PLUGIN_MIXCLOUD_FEED_FAILED'), type => 'text' } ]);
						return;
					}
					_getTracks($client, $searchType, $index, $quantity, $next, 0, $parser, $callback, $menu, $total, $remaining, $seen);
				} else {
					_callbackTracks($menu, $index, $quantity, $callback);
				}
				return;
			}
			
			my $nextPage = $json->{'paging'}->{'next'} || '';
			$log->debug('_getTracks next page: ' . $nextPage);

			$parser->($client, $json, $menu, $searchType);

			if ($total eq '') {
				# This limits search results to 400
				$total = 400;
			} elsif ($searchType =~ /^categories/) {
				$total = @$menu;
			} elsif (scalar @$menu <= $quantity ) {
				$total = $index + @$menu;
				$log->debug("short page, truncate total to $total");
			}
			
			$log->debug("this page: " . scalar @$menu . " total: $total" . " quantity: " . $quantity);
			
			# Unless fetching just one track then we need to recursively call _getTracks to calculate the total number.
			if ((($total >= $quantity || $total % $quantity != 0) && $nextPage eq '') || $quantity == 1 || scalar @$menu >= $total) {
				if ($searchType eq 'user') {
					$callback->($menu);
				}else{
					_callbackTracks($menu, $index, $quantity, $callback);
				}
			} else {
				$cursor = $total + 1;
				_getTracks($client, $searchType, $index, $quantity, $nextPage, $cursor, $parser, $callback, $menu, $total);
			}
		},			
		sub {
			$log->error("Error: $_[1]");
			$callback->([ { name => $_[1], type => 'text' } ]);
		},
		$params
		
	)->get($queryUrl, %headers);
	
	$log->debug('_getTracks ended');
}

sub _callbackTracks {
	$log->debug('_callbackTracks started');
	my ( $menu, $index, $quantity, $callback ) = @_;

	my $total = scalar @$menu;
	if ($quantity ne 1) {
        $quantity = min($quantity, $total - $index);
    }	
	
	my $returnMenu = [];
	
	if (scalar @$menu == 1) {
        $returnMenu = $menu;
    } else {	
		my $i = 0;
		my $count = 0;
		for my $entry (@$menu) {
			if ($i >= $index && $count < $quantity) {
				push @$returnMenu, $entry;
				$count++;
			}
			$i++;
		}
	}
	$callback->({
		items  => $returnMenu,
		offset => $index,
		total  => $total,
	});
    $log->debug('_callbackTracks ended');
}

sub urlHandler {
	$log->debug('urlHandler started');
	my ($client, $callback, $args) = @_;

	my $url = $args->{'search'};
	
	$url =~ s/ com/.com/;
	$url =~ s/www /www./;
	$url =~ s/http:\/\/ /https:\/\//;
	my ($id) = $url =~ m{^https://(?:www|m).mixcloud.com/(.*)$};
	my $queryUrl = "https://api.mixcloud.com/" . $id ;
	return unless $id;

	my $request = HTTP::Request->new( 'GET' => $queryUrl );
	$request->protocol('HTTP/1.1');	# Force request because, since May 2026, seen destination rejecting HTTP/1.0 which is LMS default
	my $params->{request} = $request;
	my %headers;
	$headers{'Connection'} = 'close';	# BAD BAD force close to try to prevent keep-alive in http/1.1

	$log->info("Mixcloud API call to ".$queryUrl);

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $item = eval { decode_json($http->content) };
				$log->warn($@) if $@;
				my $args = { params => {isPlugin => 1}};
				$callback->( { items => [ Plugins::MixCloud::ProtocolHandler::makeCacheItem($client, $item, $args) ] } );
			},
			sub {
				$log->error("Error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
			$params
		)->get($queryUrl, %headers);
	};
		
	$fetch->();
	$log->debug('urlHandler ended');
}

sub _parseCategories {
	$log->debug('_parseCategories started');
	my ($client, $json, $menu, $searchType) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	# Ensure that categories are sorted by name.
	$data = [ sort { uc($a->{name}) cmp uc($b->{name}) } @$data ];
	for my $entry (@$data) {
		my $format = $entry->{'format'};
		if ($searchType =~ /$format$/) {
			my $name = $entry->{'name'};
			my $slug = $entry->{'slug'};
			my $url = $entry->{'url'};
			my $key = substr($entry->{'key'},1)."cloudcasts/";
	
			push @$menu, {
				name => $name,
				type => 'link',
				url => \&tracksHandler,
				passthrough => [ { type => 'categories', params => $key} ]
			};
        }        
	}
	$log->debug('_parseCategories ended');
}

sub _parseTags {
	$log->debug('_parseTags started');
	my ($client, $json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};	
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $format = $entry->{'format'};
		my $slug = $entry->{'slug'};
		my $url = $entry->{'url'};
		my $key = substr($entry->{'key'},1);
		push @$menu, {
			name => $name,
			type => 'link',
			url => \&_tagHandler,
			passthrough => [ { params => $key} ]
		};
	}
	$log->debug('_parseTags ended');
}

sub _parseUsers {
	$log->debug('_parseUsers started');
	my ($client, $json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $username = $entry->{'username'};
		my $key = substr($entry->{'key'},1);
		my $icon = "";
		if (defined $entry->{'pictures'}->{'large'}) {
			$icon = $entry->{'pictures'}->{'large'};
		}else{
			if (defined $entry->{'pictures'}->{'medium'}) {
				$icon = $entry->{'pictures'}->{'medium'};
			}
		}
		push @$menu, {
			name => $name,
			type => 'link',
			url => \&tracksHandler,
			icon => $icon,
			image => $icon,
			cover => $icon,
			favorites_url => 'mixclouduser://' . lc($username) . '/',
			favorites_type => 'link',
			itemActions => {
				info => {
					command => [ 'mixcloud', 'items' ],
					fixedParams => { mixcloud_user => $username },
				},
			},
			passthrough => [ { type=>'user', params => $key, parser=>\&_parseUser} ]
		};
	}
	$log->debug('_parseUsers ended');
}

sub _parseUser {
	$log->debug('_parseUser started');
	my ($client, $json, $menu) = @_;
	my $key = substr($json->{'key'},1);
	my $isCurrentUser = $json->{'is_current_user'};

	if ($json->{'following_count'} > 0) {
		push(@$menu, 
			{ name => string('PLUGIN_MIXCLOUD_FOLLOWING'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { total => $json->{'following_count'},type => 'following',params => $key."following",parser => \&_parseUsers } ] }
		);
	}

	if ($json->{'favorite_count'} > 0) {
		push(@$menu, 
			{ name => string('PLUGIN_MIXCLOUD_FAVORITES'), type => 'playlist',
				url  => \&tracksHandler, passthrough => [ { total => $json->{'favorite_count'},type => 'favorites',params => $key."favorites" } ] }
		);
	}

	if ($json->{'cloudcast_count'} > 0) {
		push(@$menu, 
			{ name => string('PLUGIN_MIXCLOUD_CLOUDCASTS'), type => 'playlist',
				url  => \&tracksHandler, passthrough => [ { total => $json->{'cloudcast_count'},type => 'cloudcasts',params => $key."cloudcasts"} ] }
		);
	}

	if (!$isCurrentUser) {
		push @$menu, {
			name => string('PLUGIN_MIXCLOUD_ADD_USER_FAVOURITE'),
			type => 'link',
			url => \&addUserFavourite,
			passthrough => [ {
				key => $json->{key},
				name => $json->{name},
				icon => $json->{pictures}->{large} || $json->{pictures}->{medium},
			} ],
		};
	}
	$log->debug('_parseUser ended');
}

sub addUserFavourite {
	my ($client, $callback, $args, $user) = @_;
	my ($username) = ($user->{key} || '') =~ m{^/([A-Za-z0-9_-]+)/$};
	my $message = 'PLUGIN_MIXCLOUD_USER_FAVOURITE_FAILED';

	if (!$username || !Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Favorites::Plugin')) {
		$log->error('Cannot save Mixcloud user favourite: invalid user or Favourites plugin disabled');
	} else {
		my $url = 'mixclouduser://' . lc($username) . '/';
		my $saved = eval {
			my $favourites = Slim::Utils::Favorites->new($client);
			my $index = $favourites->findUrl($url);
			if (defined $index && !$favourites->error) {
				$message = 'PLUGIN_MIXCLOUD_USER_FAVOURITE_EXISTS';
			} else {
				if (defined $index) {
					# A failed disk write can leave the entry only in Lyrion's in-memory store.
					$favourites->save;
				} else {
					$index = $favourites->add($url, $user->{name} || $username, 'link', undef, undef, $user->{icon});
				}
				if (defined $index && !$favourites->error) {
					$message = 'PLUGIN_MIXCLOUD_USER_FAVOURITE_ADDED';
				} else {
					$log->error('Cannot save Mixcloud user favourite: ' . ($favourites->error || 'no favourite index returned'));
				}
			}
			1;
		};
		$log->error("Cannot save Mixcloud user favourite: $@") if !$saved;
	}

	$callback->([ { name => string($message), type => 'text' } ]);
}

sub _tagHandler {
	$log->debug('_tagHandler started');
	my ($client, $callback, $args, $passDict) = @_;
	my $params = $passDict->{'params'} || '';
	my $callbacks = [
		{ name => string('PLUGIN_MIXCLOUD_POPULAR'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags', params=>$params.'popular/'} ], },
		
		{ name => string('PLUGIN_MIXCLOUD_LATEST'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags', params=>$params.'latest/' } ], },

	];
	$callback->($callbacks);
	$log->debug('_tagHandler ended');
}

sub userUploadsFeed {
	my ($client, $url, $callback) = @_;
	my ($username) = $url =~ m{^mixclouduser://([A-Za-z0-9_-]+)/$};
	if (!$username) {
		$log->error('Invalid Mixcloud user favourite URL');
		$callback->({ items => [ { name => string('PLUGIN_MIXCLOUD_FEED_FAILED'), type => 'text' } ] });
		return;
	}

	getToken(sub {
		my $queryUrl = "https://api.mixcloud.com/$username/cloudcasts/?limit=100";
		$queryUrl .= '&access_token=' . uri_escape($token) if $token ne '';
		_getTracks($client, 'cloudcasts', 0, 100, $queryUrl, 0, \&_parseTracks, sub {
			my $feed = shift;
			$feed = { items => $feed } if ref $feed eq 'ARRAY';
			$feed->{title} = $username;
			$feed->{type} = 'opml';
			$callback->($feed);
		}, [], '', 100, { $queryUrl => 1 });
	});
}

sub initPlugin {
	$log->debug('initPlugin started');
	my $class = shift;

	$cache = Slim::Utils::Cache->new('mixcloud', $class->_pluginDataFor('cacheVersion'));
	
	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'mixcloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);
	
	# clear the cache when user enters an apiKey
	$prefs->setChange(sub {
		my ($pref, $new, $obj, $old) = @_;
		$cache->clear;
	}, 'apiKey');
	
	if (!$::noweb) {
		require Plugins::MixCloud::Settings;
		Plugins::MixCloud::Settings->new;
	}

	Slim::Formats::RemoteMetadata->registerProvider(
		match => qr/mixcloud/,
		func => \&_provider,
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		mixcloud => 'Plugins::MixCloud::ProtocolHandler'
	);
	Slim::Player::ProtocolHandlers->registerHandler(
		mixclouduser => 'Plugins::MixCloud::ProtocolHandler'
	);

	# Warn about possible incompatible version if LMS < 9.2.0
	# See https://github.com/danielvijge/lms_mixcloud/issues/46
	# Can be removed after LMS 9.2.0 is released and minTarget is set to 9.2
	my ($major, $minor, $patch) = split('\.', $main::VERSION);
	if ($major < 9 or ($major == 9 && $minor < 2)) {
		$log->error("WARNING: Lyrion Media Server 9.2.0 (builds after 18 June 2026) is required for the Mixcloud plugin to work correctly with authentication. See https://github.com/danielvijge/lms_mixcloud/issues/46 for details");
	}

	$log->debug('initPlugin ended');
}

sub shutdownPlugin {
	$log->debug('shutdownPlugin started');
	my $class = shift;
}

sub getDisplayName { 'PLUGIN_MIXCLOUD' }

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub toplevel {
	$log->debug('toplevel started');
	my ($client, $callback, $args) = @_;

	# Material Skin requests a row's explicit "more" action separately from normal browsing.
	if (defined (my $username = $args->{params}->{mixcloud_user})) {
		if ($username !~ /^[A-Za-z0-9_-]+$/) {
			$log->error('Invalid Mixcloud user menu request');
			$callback->([ { name => string('PLUGIN_MIXCLOUD_FEED_FAILED'), type => 'text' } ]);
			return;
		}
		getToken(sub {
			tracksHandler($client, sub {
				$callback->({ items => $_[0], query => { mixcloud_user => $username } });
			}, $args, { type => 'user', params => "$username/", parser => \&_parseUser });
		});
		return;
	}

	my $callbacks = [
		
		{ name => string('PLUGIN_MIXCLOUD_MUSIC') . ' ' . string('PLUGIN_MIXCLOUD_CATEGORIES'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'categories_music', parser => \&_parseCategories } ], },
				 
		{ name => string('PLUGIN_MIXCLOUD_TALK') . ' ' . string('PLUGIN_MIXCLOUD_CATEGORIES'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'categories_talk', parser => \&_parseCategories } ], },
		
		{ name => string('PLUGIN_MIXCLOUD_MYSEARCH'), type => 'link',   
			url  =>sub{
				my ($client, $callback, $args) = @_;
				my $searchcallbacks = [
						{ name => string('PLUGIN_MIXCLOUD_SEARCH'), type => 'search',   
							url  => \&tracksHandler, passthrough => [ { type => 'search' } ], },
				
						{ name => string('PLUGIN_MIXCLOUD_TAGS'), type => 'search',   
							url  => \&tracksHandler, passthrough => [ { type => 'tags',parser => \&_parseTags } ], },
						
						{ name => string('PLUGIN_MIXCLOUD_SEARCH_USER'), type => 'search',   
							url  => \&tracksHandler, passthrough => [ { type => 'usersearch',parser => \&_parseUsers } ], }
				];				
				$callback->($searchcallbacks);							
			}, passthrough => [ { type => 'search' } ], }		
	];
	
	getToken(
			 sub{
				if ($token ne '') {
					unshift(@$callbacks, 
						{ name => string('PLUGIN_MIXCLOUD_MYMIXCLOUD'), type => 'link',
						url  => \&tracksHandler, passthrough => [ { type=>'user', params => 'me/',parser=>\&_parseUser} ] }
					);
					
				}
				push(@$callbacks, 
					{ name => string('PLUGIN_MIXCLOUD_URL'), type => 'search', url  => \&urlHandler }
				);
				$callback->($callbacks);
			}
	);
	$log->debug('toplevel ended');
}

1;
