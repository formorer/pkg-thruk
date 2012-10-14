use strict;
use warnings;
use Data::Dumper;
use Test::More;
$Data::Dumper::Sortkeys = 1;

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}
use Catalyst::Test 'Thruk';

plan skip_all => 'internal test only' if defined $ENV{'CATALYST_SERVER'};

my($res, $c) = ctx_request('/thruk/side.html');
if($c->stash->{'enable_shinken_features'}) {
    plan tests => 51;
} else {
    plan skip_all => 'pure shinken backend required'
}

# get a problem host
my($host,$service) = TestUtils::get_test_service();

my $pages = [
    '/thruk/cgi-bin/status.cgi?hostgroup=all&style=hostdetail',
    '/thruk/cgi-bin/status.cgi?host=all',
    '/thruk/cgi-bin/cmd.cgi?cmd_typ=33&host='.$host,
    '/thruk/cgi-bin/cmd.cgi?cmd_typ=34&host='.$host.'&service='.$service,
];
for my $url (@{$pages}) {
    TestUtils::test_page(
        'url'     => $url,
        'like'    => 'Use Expire Time:',
    );
}
