use strict;
use warnings;
use Test::More;
use Data::Dumper;

eval "use Test::Cmd";
plan skip_all => 'Test::Cmd required' if $@;
BEGIN {
    plan skip_all => 'backends required' if(!-s 'thruk_local.conf' and !defined $ENV{'CATALYST_SERVER'});
}

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}

my $BIN = defined $ENV{'THRUK_BIN'} ? $ENV{'THRUK_BIN'} : './script/thruk';
$BIN    = $BIN.' --local' unless defined $ENV{'CATALYST_SERVER'};
$BIN    = $BIN.' --remote-url="'.$ENV{'CATALYST_SERVER'}.'"' if defined $ENV{'CATALYST_SERVER'};

my $cronuser = '';
$cronuser = ' -u '.$ENV{'THRUK_USER'} if defined $ENV{'THRUK_USER'};

# get test host
my $test = { cmd  => $BIN.' -a listhosts' };
TestUtils::test_command($test);
my $host = (split(/\n/mx, $test->{'stdout'}))[0];
isnt($host, undef, 'got test hosts') or BAIL_OUT("need test host");

# list backends
TestUtils::test_command({
    cmd  => $BIN.' -l',
    like => ['/\s+\*\s*\w{5}\s*\w+/',
             '/Def\s+Key\s+Name/'
            ],
});

# create recurring downtime
TestUtils::test_command({
    cmd  => $BIN.' "/thruk/cgi-bin/extinfo.cgi?type=6&recurring=save&host='.$host.'&duration=5&send_type_1=day&send_hour_1=5&send_minute_1=0"',
    like => ['/^OK - recurring downtime saved$/'],
});
TestUtils::test_command({
    cmd  => '/usr/bin/crontab -l '.$cronuser.' | grep "THIS PART IS WRITTEN BY THRUK" | wc -l',
    like => ['/^\s*1$/' ],
});

# update crontab
TestUtils::test_command({
    cmd  => $BIN.' "reports2.cgi?action=updatecron"',
    like => ['/^OK - updated crontab$/'],
});
TestUtils::test_command({
    cmd  => '/usr/bin/crontab -l '.$cronuser.' | grep "THIS PART IS WRITTEN BY THRUK" | wc -l',
    like => ['/^\s*1$/' ],
});

# remove recurring downtime
TestUtils::test_command({
    cmd  => $BIN.' "/thruk/cgi-bin/extinfo.cgi?type=6&recurring=remove&host='.$host.'"',
    like => ['/^OK - recurring downtime removed$/'],
});

# Excel export
TestUtils::test_command({
    cmd  => '/bin/sh -c \''.$BIN.' -A thrukadmin -a "url=status.cgi?view_mode=xls&host=all" > /tmp/allservices.xls\'',
});
TestUtils::test_command({
    cmd  => '/usr/bin/file /tmp/allservices.xls',
    like => ['/(Microsoft Office|CDF V2|Composite Document File V2) Document/' ],
});
unlink('/tmp/allservices.xls');

# remove crontab
TestUtils::test_command({
    cmd  => $BIN.' -a uninstallcron',
    like => ['/^cron entries removed/'],
});
TestUtils::test_command({
    cmd  => '/usr/bin/crontab -l '.$cronuser.' | grep "THIS PART IS WRITTEN BY THRUK" | wc -l',
    like => ['/^\s*0$/' ],
});

done_testing();
