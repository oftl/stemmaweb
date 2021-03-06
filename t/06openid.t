use warnings;
use strict;

use FindBin;
use lib ("$FindBin::Bin/lib");

use stemmaweb::Test::Common;

use stemmaweb;
use LWP::Protocol::PSGI;
use Test::WWW::Mechanize;

use Test::More;
use HTML::TreeBuilder;
use Data::Dumper;

use stemmaweb::Test::DB;

my $dir = stemmaweb::Test::DB->new_db;

# NOTE: this test uses Text::Tradition::Directory
# to check user accounts really have been created.
# It'll need to be changed once that is replaced...

my $scope = $dir->new_scope;

LWP::Protocol::PSGI->register(stemmaweb->psgi_app);

my $ua = Test::WWW::Mechanize->new;

$ua->get_ok('http://localhost/login');

# Trying a user that already exists

local *Catalyst::Authentication::Credential::OpenID::authenticate = sub {
    my ( $self, $c, $realm, $authinfo ) = @_;

    return $realm->find_user({ url => 'http://localhost/' }, $c);
};

$ua->submit_form(
    form_number => 2,
    fields => {
        openid_identifier => 'http://localhost',
    },
);

$ua->content_contains('You have logged in.', 'Openid login works');

$ua->get('/');

$ua->content_contains('Hello! http://localhost/!', 'We are logged in.');

$ua->get('/logout');

# Trying a user that doesn't already exist

local *Catalyst::Authentication::Credential::OpenID::authenticate = sub {
    my ( $self, $c, $realm, $authinfo ) = @_;

    return $realm->find_user({ url => 'http://example.org/' }, $c);
};


ok !$dir->find_user({ url => 'http://example.org/' }), 'No such user, yet.';

$ua->get_ok('http://localhost/login');

$ua->submit_form(
    form_number => 2,
    fields => {
        openid_identifier => 'http://example.org',
    },
);

$ua->content_contains('You have logged in.', 'Openid login works');

$ua->get('/');

$ua->content_contains('Hello! http://example.org/!', 'We are logged in.');

ok $dir->find_user({ url => 'http://example.org/' }), 'User now exists.';

$ua->get('/logout');

$ua->get_ok('http://localhost/login');

$ua->submit_form(
    form_number => 2,
    fields => {
        openid_identifier => 'http://example.org',
    },
);

$ua->content_contains('You have logged in.', 'We can now log in to our created user');

$ua->get('/');

$ua->content_contains('Hello! http://example.org/!', 'We are logged in.');

done_testing;
