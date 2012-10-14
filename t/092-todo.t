use strict;
use warnings;
use Test::More;
use Data::Dumper;

plan skip_all => 'Author test. Set $ENV{TEST_AUTHOR} to a true value to run.' unless $ENV{TEST_AUTHOR};

my $cmds = [
  "grep -nr 'TODO' lib/. templates/. plugins/plugins-available/. root/.",
];

# find all TODOs
for my $cmd (@{$cmds}) {
  open(my $ph, '-|', $cmd.' 2>&1') or die('cmd '.$cmd.' failed: '.$!);
  ok($ph, 'cmd started');
  while(<$ph>) {
    my $line = $_;
    chomp($line);

    # skip those
    if(   $line =~ m|/dojo/dojo\.js|mx
       or $line =~ m|readme\.txt|mx
       or $line =~ m|Unicode/Encoding\.pm|mx
       or $line =~ m|/excanvas.js|mx
       or $line =~ m|jquery\.mobile\-.*.js|mx
       or $line =~ m|extjs\-.*\.js|mx
       or $line =~ m|extjs\-.*\.css|mx
    ) {
      next;
    }

    # mark those as todo
    if(   $line =~ m|Provider/Mongodb.pm|mx
    ) {
      TODO: {
        local $TODO = ' ';
        fail($line);
      };
    } else {
        # let them really fail
        fail($line);
    }
  }
  close($ph);
}


done_testing();
