use strict;
use warnings;
use Test::More;
use Data::Dumper;
use File::Temp qw/ tempfile /;

BEGIN {
    plan skip_all => 'Author test. Set $ENV{TEST_AUTHOR} to a true value to run.' unless $ENV{TEST_AUTHOR};
    eval "use Test::JavaScript";
    plan skip_all => 'Test::JavaScript required' if $@;
    plan skip_all => 'backends required' if(!-f 'thruk_local.conf' and !defined $ENV{'CATALYST_SERVER'});

    use lib('t');
    require TestUtils;
    import TestUtils;
}

#################################################
# create minimal window object
js_ok("
var window = {
  navigator: {userAgent:'test'},
  document:  {
    createElement:function(){
        return({
            getElementsByTagName:function(){ return([])},
            appendChild:function(){},
            setAttribute:function(){}
        });
    },
    createDocumentFragment:function(){return({})},
    createComment:function(){},
    getElementById:function(){},
    getElementsByTagName:function(){ return([])},
    documentElement:{
        style: {},
        insertBefore:function(){},
        removeChild:function(){}
    },
    addEventListener: function(){},
    removeEventListener: function(){}
  },
  location: {},
  addEventListener: function(){},
  removeEventListener: function(){}
};
var navigator = window.navigator;
var document  = window.document;
setTimeout    = function() {};
setInterval   = function() {};
", 'set window object') or BAIL_OUT("failed to create window object");
my @jsfiles = glob('plugins/plugins-available/panorama/root/extjs-*/ext-all-debug.js');
ok($jsfiles[0], $jsfiles[0]);
js_eval_ok($jsfiles[0]) or BAIL_OUT("failed to load extjs");

#################################################
my $tst = TestUtils::test_page(
    'url'           => '/thruk/cgi-bin/panorama.cgi?js=1',
    'like'          => 'BLANK_IMAGE_URL',
    'content_type'  => 'text/javascript; charset=UTF-8',
);
my($fh, $filename) = tempfile();
print $fh $tst->{'content'};
close($fh);
js_eval_ok($filename);
unlink($filename);

done_testing();
