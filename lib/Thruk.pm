package Thruk;

=head1 NAME

Thruk - Catalyst based monitoring web interface

=head1 DESCRIPTION

Catalyst based monitoring web interface for Nagios, Icinga and Shinken

=cut

use 5.008000;
use strict;
use warnings;

use utf8;
use Carp;
use GD;
use POSIX qw(tzset);
use Log::Log4perl::Catalyst;
use Digest::MD5 qw(md5_hex);
use File::Slurp qw(read_file);
use Data::Dumper;
use Thruk::Config;
use Thruk::Backend::Manager;
use Thruk::Utils;
use Thruk::Utils::Auth;
use Thruk::Utils::Filter;
use Thruk::Utils::IO;
use Thruk::Utils::Menu;
use Thruk::Utils::Avail;
use Thruk::Utils::External;
use Catalyst::Runtime '5.70';

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");
$Data::Dumper::Sortkeys = 1;

###################################################
# Set flags and add plugins for the application
#
#         -Debug: activates the debug mode for very useful log messages
#         StackTrace

use parent qw/Catalyst/;
use Catalyst qw/
                Thruk::ConfigLoader
                Unicode::Encoding
                Compress
                Authentication
                Authorization::ThrukRoles
                CustomErrorMessage
                Static::Simple
                Redirect
                Cache
                Thruk::RemoveNastyCharsFromHttpParam
                /;

###################################################
our $VERSION = '1.52';

###################################################
# load config loader
__PACKAGE__->config(%Thruk::Config::config);

###################################################
# Start the application and make __PACKAGE__->config
# accessible
# override config in Catalyst::Plugin::Thruk::ConfigLoader
__PACKAGE__->setup();

###################################################
# save pid
Thruk::Utils::IO::mkdir(__PACKAGE__->config->{'tmp_path'});
my $pidfile  = __PACKAGE__->config->{'tmp_path'}.'/thruk.pid';
sub _remove_pid {
    if(defined $ENV{'THRUK_SRC'} and $ENV{'THRUK_SRC'} eq 'FastCGI') {
        if(-f $pidfile) {
            my $pid = read_file($pidfile);
            chomp($pid);
            unlink($pidfile) if $pid == $$;
        }
    }
    return;
}
if(defined $ENV{'THRUK_SRC'} and $ENV{'THRUK_SRC'} eq 'FastCGI') {
    open(my $fh, '>', $pidfile) || warn("cannot write $pidfile: $!");
    print $fh $$."\n";
    Thruk::Utils::IO::close($fh, $pidfile);
    $SIG{INT}  = sub { _remove_pid();  exit; };
    $SIG{TERM} = sub { _remove_pid(); exit; };
}
END {
    _remove_pid();
};

###################################################
# create secret file
if(!defined $ENV{'THRUK_SRC'} or $ENV{'THRUK_SRC'} ne 'SCRIPTS') {
    my $var_path   = __PACKAGE__->config->{'var_path'} or die("no var path!");
    my $secretfile = $var_path.'/secret.key';
    unless(-s $secretfile) {
        my $digest = md5_hex(rand(1000).time());
        chomp($digest);
        open(my $fh, ">$secretfile") or warn("cannot write to $secretfile: $!");
        if(defined $fh) {
            print $fh $digest;
            Thruk::Utils::IO::close($fh, $secretfile);
        }
        __PACKAGE__->config->{'secret_key'} = $digest;
    } else {
        my $secret_key = read_file($secretfile);
        chomp($secret_key);
        __PACKAGE__->config->{'secret_key'} = $secret_key;
    }
}

###################################################
# set timezone
my $timezone = __PACKAGE__->config->{'use_timezone'};
if(defined $timezone) {
    $ENV{'TZ'} = $timezone;
    POSIX::tzset();
}

###################################################
# set installed server side includes
my $ssi_dir = __PACKAGE__->config->{'ssi_path'};
my (%ssi, $dh);
if(!-e $ssi_dir) {
    warn("cannot access ssi_path $ssi_dir: $!");
} else {
    opendir( $dh, $ssi_dir) or die "can't opendir '$ssi_dir': $!";
    for my $entry (readdir($dh)) {
        next if $entry eq '.' or $entry eq '..';
        next if $entry !~ /\.ssi$/mx;
        $ssi{$entry} = { name => $entry }
    }
    closedir $dh;
}
__PACKAGE__->config->{'ssi_includes'} = \%ssi;
__PACKAGE__->config->{'ssi_path'}     = $ssi_dir;

###################################################
# load and parse cgi.cfg into $c->config
if(exists __PACKAGE__->config->{'cgi_cfg'}) {
    warn("cgi_cfg option is deprecated and has been renamed to cgi.cfg!");
    __PACKAGE__->config->{'cgi.cfg'} = __PACKAGE__->config->{'cgi_cfg'};
    delete __PACKAGE__->config->{'cgi_cfg'};
}
unless(Thruk::Utils::read_cgi_cfg(undef, __PACKAGE__->config, __PACKAGE__->log)) {
    die("\n\n*****\nfailed to load cgi config: ".__PACKAGE__->config->{'cgi.cfg'}."\n*****\n\n");
}


###################################################
# Logging
my $log4perl_conf;
if(!defined $ENV{'THRUK_SRC'} or ($ENV{'THRUK_SRC'} ne 'CLI' and $ENV{'THRUK_SRC'} ne 'SCRIPTS')) {
    if(defined __PACKAGE__->config->{'log4perl_conf'} and ! -s __PACKAGE__->config->{'log4perl_conf'} ) {
        die("\n\n*****\nfailed to load log4perl config: ".__PACKAGE__->config->{'log4perl_conf'}.": ".$!."\n*****\n\n");
    }
    $log4perl_conf = __PACKAGE__->config->{'log4perl_conf'} || __PACKAGE__->config->{'home'}.'/log4perl.conf';
}
if(defined $log4perl_conf and -s $log4perl_conf) {
    __PACKAGE__->log(Log::Log4perl::Catalyst->new($log4perl_conf));
}
elsif(!__PACKAGE__->debug) {
    __PACKAGE__->log->levels( 'info', 'warn', 'error', 'fatal' );
}

###################################################

=head1 METHODS

=head2 check_user_roles_wrapper

  check_user_roles_wrapper()

wrapper to avoid undef values in TT

=cut
sub check_user_roles_wrapper {
    my $self = shift;
    if($self->check_user_roles(@_)) {
        return 1;
    }
    return 0;
}

=head1 SEE ALSO

L<Thruk::Controller::Root>, L<Catalyst>

=head1 AUTHOR

Sven Nierlein, 2010-2012, <nierlein@cpan.org>

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
