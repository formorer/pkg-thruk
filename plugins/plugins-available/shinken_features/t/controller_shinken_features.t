use strict;
use warnings;
use Data::Dumper;
use Test::More;
$Data::Dumper::Sortkeys = 1;

BEGIN {
    plan skip_all => 'backends required' if(!-f 'thruk_local.conf' and !defined $ENV{'CATALYST_SERVER'});

    use lib('t');
    require TestUtils;
    import TestUtils;
}
use Catalyst::Test 'Thruk';

plan skip_all => 'internal test only' if defined $ENV{'CATALYST_SERVER'};

my($res, $c) = ctx_request('/thruk/side.html');
if($c->stash->{'enable_shinken_features'}) {
    plan tests => 52;
} else {
    plan skip_all => 'pure shinken backend required'
}

use_ok 'Thruk::Controller::shinken_features';

my $pages = [
    '/thruk/cgi-bin/outagespbimp.cgi',
];
for my $url (@{$pages}) {
    TestUtils::test_page(
        'url'     => $url,
        'like'    => 'Problems and Impacts',
    );
}


# get a problem host
my($host,$service) = TestUtils::get_test_service();
$pages = [
    '/thruk/cgi-bin/shinken_status.cgi?style=bothtypes&s0_type=impact&s0_op=%3D&s0_value='.$host.'&title=Impacts of '.$host,
    '/thruk/cgi-bin/shinken_status.cgi?style=bothtypes&s0_type=rootproblem&s0_op=%3D&s0_value='.$host.'/'.$service.'&title=Root%20problem%20of%20'.$host.'/'.$service,
];
for my $url (@{$pages}) {
    TestUtils::test_page(
        'url'     => $url,
        'like'    => 'Current Network Status',
    );
}


$pages = [
    '/thruk/cgi-bin/businessview.cgi',
];
for my $url (@{$pages}) {
    TestUtils::test_page(
        'url'     => $url,
        'like'    => 'Business Elements',
    );
}
