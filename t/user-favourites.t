use strict;
use warnings;
use Test::More;
use FindBin;
use JSON::XS ();

# Only the LMS runtime services are doubled; both plugin modules and track parsing are real.
BEGIN {
	package Slim::Plugin::OPMLBased;
	sub initPlugin {}
	sub _pluginDataFor { 1 }
	$INC{'Slim/Plugin/OPMLBased.pm'} = __FILE__;

	package Slim::Player::Protocols::HTTPS;
	sub new {}
	$INC{'Slim/Player/Protocols/HTTPS.pm'} = __FILE__;

	package Slim::Utils::Strings;
	use Exporter 'import';
	our @EXPORT_OK = qw(string cstring);
	sub string { $_[0] }
	sub cstring { $_[1] }
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Slim::Utils::Prefs;
	use Exporter 'import';
	our @EXPORT = qw(preferences);
	our %prefs;
	sub preferences { $prefs{$_[0]} ||= bless {}, __PACKAGE__ }
	sub init { my ($self, $values) = @_; %$self = (%$values, %$self) }
	sub get { $_[0]->{$_[1]} }
	sub set { $_[0]->{$_[1]} = $_[2] }
	sub setChange {}
	$INC{'Slim/Utils/Prefs.pm'} = __FILE__;

	package Slim::Utils::Log;
	use Exporter 'import';
	our @EXPORT = qw(logger);
	our @errors;
	sub logger { bless {}, __PACKAGE__ }
	sub addLogCategory { logger() }
	sub debug {}
	sub info {}
	sub warn {}
	sub error { push @errors, $_[1] }
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package Slim::Utils::Cache;
	our %values;
	sub new { bless {}, __PACKAGE__ }
	sub get { $values{$_[1]} }
	sub set { $values{$_[1]} = $_[2] }
	sub clear { %values = () }
	$INC{'Slim/Utils/Cache.pm'} = __FILE__;

	package Slim::Utils::Errno;
	$INC{'Slim/Utils/Errno.pm'} = __FILE__;

	package Slim::Player::ProtocolHandlers;
	our %handlers;
	sub registerURLHandler {}
	sub registerHandler { $handlers{$_[1]} = $_[2] }
	sub iconHandlerForURL { undef }

	package Slim::Formats::RemoteMetadata;
	sub registerProvider {}

	package Slim::Networking::SimpleAsyncHTTP;
	our (@responses, @requests);
	sub new { bless { success => $_[1], failure => $_[2], params => $_[3] }, $_[0] }
	sub get {
		my ($self, $url) = @_;
		push @requests, $url;
		my $response = shift @responses or die "Unexpected HTTP request: $url";
		if ($response->{error}) {
			$self->{failure}->($self, $response->{error});
		} else {
			$self->{content} = exists $response->{raw}
				? $response->{raw} : JSON::XS::encode_json($response);
			$self->{success}->($self);
		}
	}
	sub content { $_[0]->{content} }
}

our $noweb = 1;
our $VERSION = '9.2.0';

require "$FindBin::Bin/../ProtocolHandler.pm";
$INC{'Plugins/MixCloud/ProtocolHandler.pm'} = "$FindBin::Bin/../ProtocolHandler.pm";
require "$FindBin::Bin/../Plugin.pm";

my $plugin = 'Plugins::MixCloud::Plugin';
my $handler = 'Plugins::MixCloud::ProtocolHandler';
my $prefs = Slim::Utils::Prefs::preferences('plugin.mixcloud');
$plugin->initPlugin;

sub upload {
	my ($number, $exclusive) = @_;
	return {
		key => "/test-user/mix-$number/",
		name => "Mix $number",
		user => { name => 'Test User', username => 'test-user', key => '/test-user/' },
		audio_length => 3600,
		created_time => '2026-11-16T12:00:00Z',
		is_exclusive => $exclusive || 0,
		tags => [],
		pictures => { large => 'https://example.test/cover.jpg' },
	};
}

sub open_favourite {
	my (@responses) = @_;
	@Slim::Networking::SimpleAsyncHTTP::responses = @responses;
	@Slim::Networking::SimpleAsyncHTTP::requests = ();
	my ($result, $calls);
	$handler->explodePlaylist(undef, 'mixclouduser://test-user/', sub {
		$result = shift;
		$calls++;
	});
	is($calls, 1, 'feed completes exactly once');
	return $result;
}

subtest 'native favourite context and restart-safe routing' => sub {
	my $users = [];
	Plugins::MixCloud::Plugin::_parseUsers(undef, { data => [{
		name => 'Test User', username => 'Test-User', key => '/test-user/',
		pictures => { large => 'https://example.test/avatar.jpg' },
	}] }, $users);
	is($users->[0]->{favorites_url}, 'mixclouduser://test-user/', 'canonical durable favourite URL');
	is($users->[0]->{favorites_type}, 'link', 'favourite opens as a browsable feed, not audio');
	is($users->[0]->{image}, 'https://example.test/avatar.jpg', 'native favourite action has artwork');
	is($users->[0]->{url}, \&Plugins::MixCloud::Plugin::tracksHandler, 'normal user browsing unchanged');
	is($users->[0]->{passthrough}->[0]->{parser}, \&Plugins::MixCloud::Plugin::_parseUser, 'normal user submenu retained');

	%Slim::Player::ProtocolHandlers::handlers = ();
	$plugin->initPlugin;
	is($Slim::Player::ProtocolHandlers::handlers{mixclouduser}, $handler, 'feed handler registered on startup');
	ok($handler->isPlaylistURL($users->[0]->{favorites_url}), 'saved user recognized as playlist');
	ok(!$handler->isPlaylistURL('mixcloud://test-user/mix-1/'), 'individual track remains a track');
};

subtest 'latest 100 uploads across API pages' => sub {
	my $next = 'https://api.mixcloud.com/test-user/cloudcasts/?offset=60&limit=100';
	my $feed = open_favourite(
		{ data => [ map { upload($_) } 1..60 ], paging => { next => $next } },
		{ data => [ map { upload($_) } 61..150 ], paging => { next => "$next&more=1" } },
	);
	is($feed->{type}, 'opml', 'full parsed feed returned to Lyrion');
	is(scalar @{$feed->{items}}, 100, 'hard limit remains 100 even if a page is oversized');
	is($feed->{total}, 100, 'total describes visible bounded list');
	is($feed->{items}->[0]->{play}, 'mixcloud://test-user/mix-1/', 'latest track order retained');
	is($feed->{items}->[99]->{play}, 'mixcloud://test-user/mix-100/', 'hundredth track playable through existing handler');
	is($feed->{items}->[0]->{duration}, 3600, 'real track parser retains metadata');
	is($feed->{items}->[0]->{image}, 'https://example.test/cover.jpg', 'real track parser retains artwork');
	is(scalar @Slim::Networking::SimpleAsyncHTTP::requests, 2, 'does not fetch older uploads after limit');
	like($Slim::Networking::SimpleAsyncHTTP::requests[0], qr{/test-user/cloudcasts/\?limit=100$}, 'fetches user uploads, not favourites or reposts');
};

subtest 'short, empty, refreshed and filtered feeds' => sub {
	my $feed = open_favourite({ data => [upload(1), upload(2)] });
	is(scalar @{$feed->{items}}, 2, 'all uploads when fewer than 100');
	$feed = open_favourite({ data => [] });
	is_deeply($feed->{items}, [], 'empty account is a valid empty feed');
	$feed = open_favourite({ data => [upload(3)] });
	is($feed->{items}->[0]->{play}, 'mixcloud://test-user/mix-3/', 'reopening refetches new uploads');
	$feed = open_favourite({ data => [map { upload($_, $_ == 1) } 1..100], paging => {
		next => 'https://api.mixcloud.com/test-user/cloudcasts/?offset=100',
	} });
	is(scalar @{$feed->{items}}, 99, 'existing hide-exclusive preference respected');
	is(scalar @Slim::Networking::SimpleAsyncHTTP::requests, 1, 'does not backfill beyond latest 100 uploads');
	$prefs->set('hide_exclusive', 0);
	$feed = open_favourite({ data => [upload(1, 1)] });
	is(scalar @{$feed->{items}}, 1, 'exclusive upload shown when preference disabled');
	$prefs->set('hide_exclusive', 1);
};

subtest 'errors are visible, including failed later pages' => sub {
	for my $response (
		{ error => 'Connection failed' },
		{ raw => '{not json' },
		{ error_description => 'API denied request' },
		{ data => 'not a track list' },
	) {
		my $feed = open_favourite($response);
		is($feed->{items}->[0]->{type}, 'text', 'failure shown as an informational error, not playable JSON');
		ok($feed->{items}->[0]->{name}, 'failure includes a message');
	}
	my $feed = open_favourite(
		{ data => [upload(1)], paging => { next => 'https://api.mixcloud.com/test-user/cloudcasts/?offset=1' } },
		{ error => 'Later page failed' },
	);
	is($feed->{items}->[0]->{name}, 'Later page failed', 'does not present a partial list as successful');
	for my $next (
		'https://example.test/steal-token',
		'https://api.mixcloud.com/test-user/cloudcasts/?limit=100',
	) {
		$feed = open_favourite({ data => [upload(1)], paging => { next => $next } });
		is($feed->{items}->[0]->{type}, 'text', 'unsafe or looping pagination fails explicitly');
		is(scalar @Slim::Networking::SimpleAsyncHTTP::requests, 1, 'bad next URL never requested');
	}
	$feed = open_favourite({ data => [], paging => {
		next => 'https://api.mixcloud.com/test-user/cloudcasts/?offset=1',
	} });
	is($feed->{items}->[0]->{type}, 'text', 'empty pages cannot cause unbounded pagination');
	my $result;
	$handler->explodePlaylist(undef, 'mixclouduser://bad/user/', sub { $result = shift });
	is($result->{items}->[0]->{type}, 'text', 'malformed favourite fails explicitly');
	ok(@Slim::Utils::Log::errors, 'errors are also logged');
};

subtest 'metadata provider passes class and client correctly' => sub {
	open_favourite({ data => [upload(1)] });
	my $metadata = Plugins::MixCloud::Plugin::_provider(undef, 'mixcloud://test-user/mix-1/', {});
	is($metadata->{duration}, 3600, 'provider retrieves cached track metadata without shifting arguments');
	is_deeply(Plugins::MixCloud::Plugin::_provider(undef, 'mixclouduser://test-user/', {}), {
		icon => 'html/images/radio.png',
	}, 'feed metadata never treats a URL as a client or fetches a cloudcast');
};

subtest 'existing track browsing and playback URLs remain unchanged' => sub {
	my $result;
	@Slim::Networking::SimpleAsyncHTTP::responses = ({ data => [upload(1), upload(2)] });
	Plugins::MixCloud::Plugin::tracksHandler(undef, sub { $result = shift }, {
		quantity => 2,
	}, { type => 'cloudcasts', params => 'test-user/cloudcasts' });
	is($result->{items}->[1]->{play}, 'mixcloud://test-user/mix-2/', 'ordinary Tracks entry still uses the real parser');
	$handler->explodePlaylist(undef, 'mixcloud://test-user/mix-1/', sub { $result = shift });
	is_deeply($result, ['mixcloud://test-user/mix-1/'], 'individual mixcloud URL is not expanded as a user feed');
	@Slim::Networking::SimpleAsyncHTTP::responses = (upload(1));
	$handler->explodePlaylist(undef, 'https://www.mixcloud.com/test-user/mix-1/', sub { $result = shift });
	is_deeply($result, ['mixcloud://test-user/mix-1/'], 'existing public track URLs still resolve through urlHandler');
};

subtest 'direct favourites initialize authentication without visiting plugin home' => sub {
	$Slim::Utils::Cache::values{token} = 'cached-token';
	open_favourite({ data => [upload(1)] });
	like($Slim::Networking::SimpleAsyncHTTP::requests[0], qr{&access_token=cached-token$}, 'direct favourite initializes token without visiting plugin home');
};

done_testing;
